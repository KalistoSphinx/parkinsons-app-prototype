"""Compact feature-only document store and immediately updated patient baselines."""

from __future__ import annotations

import json
import os
import random
import tempfile
import threading
import time
from datetime import date, datetime, timezone
from hashlib import sha256
from pathlib import Path
from typing import Any

import numpy as np

from .anomaly import (
    fit_isolation_model,
    load_model,
    save_model,
    within_observed_range,
)
from .features import FEATURE_COLUMNS

from importlib.resources import files
from paradigma.classification import ClassifierPackage
from paradigma.config import TremorConfig, GaitConfig

_assets = files("paradigma") / "assets"
try:
    PARADIGMA_TREMOR_THRESHOLD = float(
        ClassifierPackage.load(_assets / "tremor_detection_clf_package.pkl").threshold
    )
except Exception:
    PARADIGMA_TREMOR_THRESHOLD = 0.029570239921802

try:
    PARADIGMA_GAIT_THRESHOLD = float(
        ClassifierPackage.load(_assets / "gait_detection_clf_package.pkl").threshold
    )
except Exception:
    PARADIGMA_GAIT_THRESHOLD = 0.20992421195731484

try:
    PARADIGMA_GAIT_FILTER_THRESHOLD = float(
        ClassifierPackage.load(_assets / "gait_filtering_clf_package.pkl").threshold
    )
except Exception:
    PARADIGMA_GAIT_FILTER_THRESHOLD = 0.4691878519863539

_tremor_cfg = TremorConfig()
PARADIGMA_MOVEMENT_THRESHOLD = float(_tremor_cfg.movement_threshold)  # 50.0
PARADIGMA_REST_TREMOR_FMIN = float(_tremor_cfg.fmin_rest_tremor)      # 3.0 Hz
PARADIGMA_REST_TREMOR_FMAX = float(_tremor_cfg.fmax_rest_tremor)      # 7.0 Hz

_DEFAULT_PATH = Path(__file__).resolve().parents[1] / "data" / "feature_vectors"
_QUANTILE_RESERVOIR_SIZE = 2048
MIN_BASELINE_INTERVALS = 5
MIN_IFOREST_INTERVALS = 20


class FeatureStore:
    """One JSON document per session; online stats avoid rescanning raw history."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = path or Path(os.environ.get("FEATURE_STORE_PATH", _DEFAULT_PATH))
        self._lock = threading.RLock()

    def _patient_directory(self, patient_id: str) -> Path:
        key = sha256(patient_id.encode("utf-8")).hexdigest()
        return self.path / key

    def patient_directory(self, patient_id: str) -> Path:
        return self._patient_directory(patient_id)

    @staticmethod
    def _write_atomic(path: Path, document: dict[str, Any]) -> None:
        temporary_path = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w", encoding="utf-8", dir=path.parent,
                delete=False, suffix=".tmp",
            ) as target:
                json.dump(document, target, allow_nan=False, separators=(",", ":"))
                target.flush()
                os.fsync(target.fileno())
                temporary_path = Path(target.name)
            os.replace(temporary_path, path)
        finally:
            if temporary_path and temporary_path.exists():
                temporary_path.unlink()

    @staticmethod
    def _read(path: Path) -> dict[str, Any]:
        return json.loads(path.read_text(encoding="utf-8"))

    def upsert(self, document: dict[str, Any]) -> None:
        directory = self._patient_directory(document["patient_id"])
        directory.mkdir(parents=True, exist_ok=True)
        session_key = sha256(document["session_id"].encode("utf-8")).hexdigest()
        timestamp_ms = int(document["timestamp_ms"])
        document_path = directory / (
            f"{document['local_date']}_{timestamp_ms:013d}_{session_key}.json"
        )
        stats_path = directory / "_baseline.json"
        monitoring_mode = document.get("monitoring_mode", "baseline")

        with self._lock:
            # Idempotent retry: the first committed output for a session is the
            # durable one, and it must not be counted twice in the baseline.
            if list(directory.glob(f"*_{session_key}.json")):
                return

            reference_path = directory / "_reference_baseline.json"
            is_frozen = reference_path.exists()
            stats = None

            # If the patient's baseline is already frozen, this session CANNOT modify the baseline.
            # It must strictly be recorded as an anomaly monitoring session excluded from baseline.
            if is_frozen:
                document["monitoring_mode"] = "anomaly"
                document["baseline_status"] = "excluded"
            # Only baseline-building intervals can ever enter the reference
            # baseline. Anomaly-monitoring intervals are explicitly excluded so
            # that abnormal movement cannot teach the model to call it normal.
            elif (
                monitoring_mode == "baseline"
                and document.get("quality_passed") is True
                and document.get("baseline_status", "included") != "excluded"
            ):
                stats = self._load_or_rebuild_stats(directory)
                if timestamp_ms > int(stats.get("reset_at_ms", 0)):
                    stats["quality_session_count"] += 1
                    for column in FEATURE_COLUMNS:
                        if column in {"fall_detected", "fall_impact_g"}:
                            continue
                        value = document.get("features", {}).get(column)
                        if value is not None and np.isfinite(value):
                            self._add_value(
                                stats["features"].setdefault(
                                    column, self._empty_feature_stats()
                                ),
                                float(value),
                                f"{document['session_id']}:{column}",
                            )

            self._write_atomic(document_path, document)
            if stats is not None and not is_frozen:
                self._write_atomic(stats_path, stats)

    @staticmethod
    def _is_baseline_document(document: dict[str, Any]) -> bool:
        return (
            document.get("monitoring_mode", "baseline") == "baseline"
            and document.get("baseline_status", "included") != "excluded"
        )

    @staticmethod
    def _empty_feature_stats() -> dict[str, Any]:
        return {"count": 0, "mean": 0.0, "m2": 0.0, "min": None, "max": None, "sample": []}

    @staticmethod
    def _add_value(stats: dict[str, Any], value: float, seed: str) -> None:
        count = int(stats["count"]) + 1
        delta = value - float(stats["mean"])
        stats["mean"] = float(stats["mean"]) + delta / count
        stats["m2"] = float(stats["m2"]) + delta * (value - float(stats["mean"]))
        stats["count"] = count
        stats["min"] = value if stats["min"] is None else min(float(stats["min"]), value)
        stats["max"] = value if stats["max"] is None else max(float(stats["max"]), value)

        sample = stats["sample"]
        if len(sample) < _QUANTILE_RESERVOIR_SIZE:
            sample.append(value)
        else:
            position = random.Random(seed).randrange(count)
            if position < _QUANTILE_RESERVOIR_SIZE:
                sample[position] = value

    def _load_or_rebuild_stats(self, directory: Path) -> dict[str, Any]:
        stats_path = directory / "_baseline.json"
        reference_path = directory / "_reference_baseline.json"

        # If a reference baseline is already frozen, stats are locked to the reference.
        if reference_path.exists():
            ref = self._read(reference_path)
            if stats_path.exists():
                stats = self._read(stats_path)
                stats.setdefault("reset_at_ms", 0)
                stats.setdefault("quality_session_count", int(ref.get("session_count", 0)))
                stats.setdefault("features", {})
                return stats

        if stats_path.exists():
            stats = self._read(stats_path)
            stats.setdefault("reset_at_ms", 0)
            stats.setdefault("quality_session_count", 0)
            stats.setdefault("features", {})
            return stats

        stats: dict[str, Any] = {
            "reset_at_ms": 0,
            "quality_session_count": 0,
            "features": {},
        }
        allowed_session_ids = None
        if reference_path.exists():
            allowed_session_ids = set(self._read(reference_path).get("session_ids", []))

        for path in sorted(directory.glob("*.json")):
            if path.name.startswith("_"):
                continue
            item = self._read(path)
            if allowed_session_ids is not None and item.get("session_id") not in allowed_session_ids:
                continue
            if not self._is_baseline_document(item):
                continue
            if item.get("quality_passed") is not True:
                continue
            if int(item.get("timestamp_ms", 0)) <= int(stats["reset_at_ms"]):
                continue
            stats["quality_session_count"] += 1
            for column in FEATURE_COLUMNS:
                value = item.get("features", {}).get(column)
                if value is not None and np.isfinite(value):
                    self._add_value(
                        stats["features"].setdefault(column, self._empty_feature_stats()),
                        float(value),
                        f"{item.get('session_id')}:{column}",
                    )
        self._write_atomic(directory / "_baseline.json", stats)
        return stats

    def _baseline_from_stats(
        self, stats: dict[str, Any]
    ) -> dict[str, dict[str, float | int]]:
        result = {}
        for column, values in stats["features"].items():
            sample = np.asarray(values["sample"], dtype=float)
            if sample.size == 0:
                continue
            median = float(np.median(sample))
            result[column] = {
                "count": int(values["count"]),
                "mean": float(values["mean"]),
                "median": median,
                "std": float(np.sqrt(values["m2"] / (values["count"] - 1)))
                if values["count"] > 1
                else 0.0,
                "mad": float(np.median(np.abs(sample - median))),
                "min": float(values["min"]),
                "max": float(values["max"]),
                "p01": float(np.percentile(sample, 1)),
                "p05": float(np.percentile(sample, 5)),
                "p25": float(np.percentile(sample, 25)),
                "p75": float(np.percentile(sample, 75)),
                "p95": float(np.percentile(sample, 95)),
                "p99": float(np.percentile(sample, 99)),
            }
        return result

    def baseline(self, patient_id: str | None) -> dict[str, dict[str, float | int]]:
        if not patient_id:
            return {}
        directory = self._patient_directory(patient_id)
        if not directory.exists():
            return {}
        with self._lock:
            reference_path = directory / "_reference_baseline.json"
            if reference_path.exists():
                ref = self._read(reference_path)
                if ref.get("baseline"):
                    return ref["baseline"]
            return self._baseline_from_stats(self._load_or_rebuild_stats(directory))

    def patient_directory(self, patient_id: str) -> Path:
        return self._patient_directory(patient_id)

    def _baseline_state_payload(
        self,
        patient_id: str,
        stats: dict[str, Any],
        reference: dict[str, Any] | None,
    ) -> dict[str, Any]:
        frozen = reference is not None
        building_count = int(stats.get("quality_session_count", 0))
        active_baseline = (
            reference.get("baseline", {})
            if frozen
            else self._baseline_from_stats(stats)
        )
        return {
            "patient_id": patient_id,
            "state": "frozen" if frozen else "building",
            "ready": frozen or building_count >= MIN_BASELINE_INTERVALS,
            "can_finalize": building_count >= MIN_BASELINE_INTERVALS,
            "can_monitor": frozen or building_count >= MIN_BASELINE_INTERVALS,
            "building_sessions": building_count,
            "reference_sessions": int(reference.get("session_count", 0))
            if frozen
            else 0,
            "min_sessions": MIN_BASELINE_INTERVALS,
            "min_iforest_sessions": MIN_IFOREST_INTERVALS,
            "frozen_at": reference.get("frozen_at") if frozen else None,
            "model": reference.get("model", "robust_z") if frozen else "robust_z",
            "baseline": active_baseline,
        }

    def baseline_state(self, patient_id: str) -> dict[str, Any]:
        directory = self._patient_directory(patient_id)
        if not directory.exists():
            return self._baseline_state_payload(
                patient_id,
                {"reset_at_ms": 0, "quality_session_count": 0, "features": {}},
                None,
            )
        with self._lock:
            stats = self._load_or_rebuild_stats(directory)
            reference_path = directory / "_reference_baseline.json"
            reference = self._read(reference_path) if reference_path.exists() else None
            return self._baseline_state_payload(patient_id, stats, reference)

    def reference_baseline(
        self, patient_id: str
    ) -> dict[str, dict[str, float | int]]:
        state = self.baseline_state(patient_id)
        return state.get("baseline", {}) if state.get("state") == "frozen" else {}

    def reference_state(self, patient_id: str) -> dict[str, Any]:
        path = self._patient_directory(patient_id) / "_reference_baseline.json"
        if not path.exists():
            return {}
        with self._lock:
            return self._read(path)

    def anomaly_model(self, patient_id: str) -> dict[str, Any] | None:
        if self.baseline_state(patient_id).get("state") != "frozen":
            return None
        return load_model(
            self._patient_directory(patient_id) / "_anomaly_model.joblib"
        )

    def finalize_baseline(self, patient_id: str) -> dict[str, Any]:
        directory = self._patient_directory(patient_id)
        directory.mkdir(parents=True, exist_ok=True)
        with self._lock:
            stats = self._load_or_rebuild_stats(directory)
            count = int(stats.get("quality_session_count", 0))
            if count < MIN_BASELINE_INTERVALS:
                raise ValueError(
                    "At least "
                    f"{MIN_BASELINE_INTERVALS} quality baseline intervals are required."
                )

            rows: list[dict[str, Any]] = []
            session_ids: list[str] = []
            for path in sorted(directory.glob("*.json")):
                if path.name.startswith("_"):
                    continue
                item = self._read(path)
                if not self._is_baseline_document(item):
                    continue
                if item.get("quality_passed") is not True:
                    continue
                if int(item.get("timestamp_ms", 0)) <= int(stats.get("reset_at_ms", 0)):
                    continue
                rows.append(item.get("features", {}))
                session_ids.append(item.get("session_id"))

            bundle = (
                fit_isolation_model(rows) if len(rows) >= MIN_IFOREST_INTERVALS else None
            )
            model_path = directory / "_anomaly_model.joblib"
            if bundle is not None:
                save_model(bundle, model_path)
            elif model_path.exists():
                model_path.unlink()

            reference = {
                "patient_id": patient_id,
                "frozen_at": datetime.now(timezone.utc).isoformat(),
                "frozen_at_ms": int(time.time() * 1000),
                "session_count": count,
                "session_ids": session_ids,
                "baseline": self._baseline_from_stats(stats),
                "model": "robust_z+isolation_forest" if bundle else "robust_z",
            }
            self._write_atomic(directory / "_reference_baseline.json", reference)
            return self._baseline_state_payload(patient_id, stats, reference)

    def reset_baseline(self, patient_id: str) -> dict[str, Any]:
        """Start a fresh calibration without deleting historical session files."""
        directory = self._patient_directory(patient_id)
        directory.mkdir(parents=True, exist_ok=True)
        now_ms = int(time.time() * 1000)
        with self._lock:
            stats: dict[str, Any] = {
                "reset_at_ms": now_ms,
                "quality_session_count": 0,
                "features": {},
            }
            self._write_atomic(directory / "_baseline.json", stats)
            for name in ("_reference_baseline.json", "_anomaly_model.joblib"):
                path = directory / name
                if path.exists():
                    path.unlink()
            return self._baseline_state_payload(patient_id, stats, None)

    def recent_sessions(self, patient_id: str, limit: int = 10) -> list[dict[str, Any]]:
        directory = self._patient_directory(patient_id)
        if not directory.exists():
            return []
        with self._lock:
            paths = [
                path
                for path in directory.glob("*.json")
                if not path.name.startswith("_")
            ]
            paths.sort(reverse=True)
            documents: list[dict[str, Any]] = []
            for path in paths[: max(1, min(limit, 100))]:
                try:
                    documents.append(self._read(path))
                except (OSError, json.JSONDecodeError):
                    continue
            return list(reversed(documents))

    def delete_patient(self, patient_id: str) -> bool:
        if not patient_id:
            return False
        import shutil
        directory = self._patient_directory(patient_id)
        with self._lock:
            if not directory.exists():
                return False
            shutil.rmtree(directory)
            return True

    def clear_session_fall(self, patient_id: str, session_id: str) -> bool:
        directory = self._patient_directory(patient_id)
        if not directory.exists():
            return False
        with self._lock:
            for path in directory.glob("*.json"):
                if path.name.startswith("_"):
                    continue
                try:
                    doc = self._read(path)
                    if doc.get("session_id") == session_id:
                        if "features" in doc and isinstance(doc["features"], dict):
                            doc["features"]["fall_detected"] = 0.0
                            doc["features"]["fall_impact_g"] = 0.0
                        if "symptom_labels" in doc and isinstance(doc["symptom_labels"], dict):
                            doc["symptom_labels"]["fall"] = "normal"
                        self._write_atomic(path, doc)
                        return True
                except Exception:
                    continue
            return False

    def save_caretaker(self, patient_id: str, caretaker_info: dict[str, Any]) -> None:
        directory = self._patient_directory(patient_id)
        directory.mkdir(parents=True, exist_ok=True)
        with self._lock:
            path = directory / "_caretaker.json"
            self._write_atomic(path, caretaker_info)

    def get_caretaker(self, patient_id: str) -> dict[str, Any] | None:
        directory = self._patient_directory(patient_id)
        path = directory / "_caretaker.json"
        if not path.exists():
            return None
        with self._lock:
            try:
                return self._read(path)
            except Exception:
                return None

    def remove_caretaker(self, patient_id: str) -> bool:
        directory = self._patient_directory(patient_id)
        path = directory / "_caretaker.json"
        with self._lock:
            if path.exists():
                path.unlink()
                return True
            return False

    def page_sessions(
        self,
        patient_id: str,
        *,
        after_timestamp_ms: int = 0,
        limit: int = 500,
    ) -> list[dict[str, Any]]:
        directory = self._patient_directory(patient_id)
        if not directory.exists():
            return []
        page = []
        for path in sorted(directory.glob("*.json")):
            if path.name.startswith("_"):
                continue
            try:
                timestamp_ms = int(path.name.split("_")[1])
            except (ValueError, IndexError):
                continue
            if timestamp_ms <= after_timestamp_ms:
                continue
            page.append(self._read(path))
            if len(page) >= max(1, min(limit, 500)):
                break
        return page

    def day_report(self, patient_id: str, day: date) -> dict[str, Any]:
        directory = self._patient_directory(patient_id)
        documents: list[dict[str, Any]] = []
        if directory.exists():
            for path in directory.glob(f"{day.isoformat()}_*.json"):
                item = self._read(path)
                if item.get("quality_passed") is True:
                    documents.append(item)

        state = self.baseline_state(patient_id)
        baseline = state.get("baseline", {})
        baseline_sessions = (
            state.get("reference_sessions", 0)
            if state.get("state") == "frozen"
            else state.get("building_sessions", 0)
        )
        baseline_intervals = sum(
            1
            for item in documents
            if item.get("monitoring_mode", "baseline") == "baseline"
        )
        anomaly_intervals = len(documents) - baseline_intervals
        # Once a baseline is frozen, today's clinical labels and numerical observations
        # should describe anomaly-monitoring intervals, not the older intervals used to build
        # the reference itself.
        frozen = state.get("state") == "frozen"
        label_documents = (
            [
                item
                for item in documents
                if item.get("monitoring_mode", "baseline") == "anomaly"
            ]
            if frozen
            else documents
        )
        target_documents = label_documents if (frozen and label_documents) else documents
        numerical = {}
        for column in FEATURE_COLUMNS:
            values = [
                item["features"].get(column)
                for item in target_documents
                if item.get("features", {}).get(column) is not None
            ]
            if values:
                numerical[column] = float(np.median(values))

        labels: dict[str, str] = {}
        symptoms = ("tremor", "gait", "bradykinesia_proxy", "fall")
        priority = {"normal": 0, "mild": 1, "moderate": 2, "severe": 3, "critical": 4}
        label_features: dict[str, float] = {}
        for column in FEATURE_COLUMNS:
            values = []
            for item in label_documents:
                value = item.get("features", {}).get(column)
                if value is None and column in {"tremor_power", "tremor_time"}:
                    # A missing power/time means no quantified tremor. Treat it
                    # as zero so one detected interval cannot become the
                    # day-level median.
                    value = 0.0
                if value is not None:
                    values.append(value)
            if values:
                label_features[column] = float(np.median(values))

        fall_detected_today = any(
            item.get("features", {}).get("fall_detected") == 1.0
            for item in documents
        )

        if baseline_sessions < 5:
            labels = {symptom: "baseline building" for symptom in ("tremor", "gait", "bradykinesia_proxy")}
            labels["fall"] = "critical" if fall_detected_today else "normal"
            overall = "critical" if fall_detected_today else "baseline building"
        elif not label_documents:
            labels = {symptom: "insufficient data" for symptom in ("tremor", "gait", "bradykinesia_proxy")}
            labels["fall"] = "critical" if fall_detected_today else "normal"
            overall = "critical" if fall_detected_today else "insufficient data"
        else:
            day_eval = symptom_labels(label_features, baseline)
            session_evals = [
                symptom_labels(item.get("features", {}), baseline)
                for item in label_documents
            ]
            for symptom in symptoms:
                if symptom == "fall":
                    labels["fall"] = "critical" if (fall_detected_today or any(ev.get("fall") == "critical" for ev in session_evals)) else "normal"
                    continue
                candidates = [
                    ev[symptom]
                    for ev in session_evals
                    if ev.get(symptom) in priority
                ]
                if not candidates:
                    labels[symptom] = day_eval.get(symptom, "insufficient data")
                    continue
                med_label = day_eval.get(symptom, "normal")
                elevated = [c for c in candidates if priority.get(c, 0) > 0]
                elevated_ratio = len(elevated) / len(candidates)
                if priority.get(med_label, 0) > 0:
                    labels[symptom] = max(candidates, key=priority.get)
                elif elevated_ratio >= 0.20 and len(elevated) >= 1:
                    labels[symptom] = max(elevated, key=priority.get)
                else:
                    labels[symptom] = med_label

            severity = max((priority.get(value, -1) for value in labels.values()), default=-1)
            overall = next((name for name, rank in priority.items() if rank == severity), "insufficient data")

        accel_rms_val = numerical.get("accel_rms_m_s2", 0.0)
        base_accel_median = baseline.get("accel_rms_m_s2", {}).get("median", 0.0)
        vigor_ratio = round(accel_rms_val / base_accel_median, 2) if (base_accel_median and base_accel_median > 0) else 1.0

        tremor_count = sum(
            1 for item in target_documents
            if (item.get("features", {}).get("tremor_probability", 0.0) or 0.0) >= 0.05
        )
        tremor_burden_pct = round((tremor_count / max(1, len(target_documents))) * 100, 1) if target_documents else 0.0

        active_count = sum(
            1 for item in target_documents
            if (item.get("features", {}).get("gyro_rms_rad_s", 0.0) or 0.0) >= 0.05
        )
        active_ratio = round((active_count / max(1, len(target_documents))) * 100, 1) if target_documents else 0.0

        additional_readings = {
            "tremor_burden_pct": tremor_burden_pct,
            "movement_vigor_ratio": vigor_ratio,
            "active_movement_pct": active_ratio,
            "rest_pct": round(100.0 - active_ratio, 1),
            "fall_count": sum(item.get("features", {}).get("fall_detected") == 1.0 for item in documents),
            "total_intervals": len(documents),
        }

        return {
            "patient_id": patient_id,
            "date": day.isoformat(),
            "overall_status": overall,
            "symptom_labels": labels,
            "processed_sessions": len(documents),
            "fall_incidents": sum(item.get("features", {}).get("fall_detected") == 1.0 for item in documents),
            "tremor_intervals": sum(item.get("features", {}).get("tremor_probability") is not None for item in documents),
            "gait_intervals": sum(item.get("features", {}).get("gait_probability") is not None for item in documents),
            "movement_intervals": sum(item.get("features", {}).get("gyro_rms_rad_s") is not None for item in documents),
            "baseline_sessions": baseline_sessions,
            "baseline_state": state.get("state", "building"),
            "baseline_ready": state.get("ready", False),
            "can_finalize_baseline": state.get("can_finalize", False),
            "monitoring_model": state.get("model", "robust_z"),
            "baseline_intervals": baseline_intervals,
            "anomaly_intervals": anomaly_intervals,
            "monitoring_minutes": round(sum(item.get("duration_s", 0) for item in documents) / 60, 1),
            "last_processed": max((item.get("timestamp") for item in documents), default=None),
            "day_features": numerical,
            "baseline": baseline,
            "caretaker": self.get_caretaker(patient_id),
            "summary": _summary_text(overall, labels, len(documents)),
            "additional_readings": additional_readings,
        }

    def available_dates(self, patient_id: str) -> list[str]:
        directory = self._patient_directory(patient_id)
        if not directory.exists():
            return [date.today().isoformat()]
        dates: set[str] = set()
        for path in directory.glob("*.json"):
            name = path.name
            if name.startswith("_"):
                continue
            parts = name.split("_")
            if len(parts) >= 2:
                d_str = parts[0]
                if len(d_str) == 10 and d_str.count("-") == 2:
                    dates.add(d_str)

        notes_path = directory / "_notes.json"
        if notes_path.exists():
            try:
                notes_data = json.loads(notes_path.read_text(encoding="utf-8"))
                for n in notes_data:
                    nd = n.get("date")
                    if nd and len(nd) == 10 and nd.count("-") == 2:
                        dates.add(nd)
            except Exception:
                pass

        dates.add(date.today().isoformat())
        return sorted(dates, reverse=True)

    def period_summary(
        self,
        patient_id: str,
        days: int = 7,
        end_date: date | None = None,
    ) -> dict[str, Any]:
        from datetime import timedelta
        end = end_date or date.today()
        start = end - timedelta(days=days - 1)

        daily_breakdown: list[dict[str, Any]] = []
        days_monitored = 0
        total_monitoring_minutes = 0.0
        total_fall_incidents = 0
        days_with_tremor = 0
        days_with_gait_issues = 0
        days_with_vigor_reduction = 0
        total_notes = 0

        notes_by_date: dict[str, list[dict]] = {}
        notes_path = self._patient_directory(patient_id) / "_notes.json"
        if notes_path.exists():
            try:
                all_notes = json.loads(notes_path.read_text(encoding="utf-8"))
                for n in all_notes:
                    d_key = n.get("date", "")
                    notes_by_date.setdefault(d_key, []).append(n)
            except Exception:
                pass

        cur = start
        while cur <= end:
            cur_iso = cur.isoformat()
            rep = self.day_report(patient_id, cur)
            sessions_count = rep.get("processed_sessions", 0)
            is_monitored = sessions_count > 0
            if is_monitored:
                days_monitored += 1

            dur_min = rep.get("monitoring_minutes", 0.0)
            total_monitoring_minutes += dur_min

            falls = rep.get("fall_incidents", 0)
            total_fall_incidents += falls

            sym_labels = rep.get("symptom_labels", {})
            tremor_lbl = sym_labels.get("tremor", "normal")
            gait_lbl = sym_labels.get("gait", "normal")
            vigor_lbl = sym_labels.get("bradykinesia_proxy", "normal")

            if tremor_lbl in {"mild", "moderate", "severe", "critical", "warning", "watch"}:
                days_with_tremor += 1
            if gait_lbl in {"mild", "moderate", "severe", "critical", "warning", "watch"}:
                days_with_gait_issues += 1
            if vigor_lbl in {"mild", "moderate", "severe", "critical", "warning", "watch"}:
                days_with_vigor_reduction += 1

            day_notes = notes_by_date.get(cur_iso, [])
            total_notes += len(day_notes)

            day_features = rep.get("day_features", {})
            tremor_prob = day_features.get("tremor_probability", 0.0)
            tremor_time = day_features.get("tremor_time", 0.0)
            accel_rms = day_features.get("accel_rms_m_s2", 0.0)

            daily_breakdown.append({
                "date": cur_iso,
                "day_name": cur.strftime("%a"),
                "monitored": is_monitored,
                "overall_status": rep.get("overall_status", "insufficient data" if not is_monitored else "normal"),
                "symptom_labels": sym_labels,
                "processed_sessions": sessions_count,
                "monitoring_minutes": dur_min,
                "fall_incidents": falls,
                "tremor_probability": round(float(tremor_prob), 4) if tremor_prob else 0.0,
                "tremor_time": round(float(tremor_time), 3) if tremor_time else 0.0,
                "accel_rms_m_s2": round(float(accel_rms), 3) if accel_rms else 0.0,
                "notes_count": len(day_notes),
            })
            cur += timedelta(days=1)

        adherence_pct = round((days_monitored / max(1, days)) * 100, 1)

        if total_fall_incidents > 0:
            trajectory = "Elevated Fall Risk"
            trajectory_severity = "critical"
        elif days_with_tremor >= max(1, days_monitored // 2) and days_monitored > 0:
            trajectory = "Elevated Tremor Activity"
            trajectory_severity = "warning"
        elif days_with_gait_issues >= max(1, days_monitored // 2) and days_monitored > 0:
            trajectory = "Gait / Arm Swing Irregularity"
            trajectory_severity = "warning"
        elif days_with_vigor_reduction >= max(1, days_monitored // 2) and days_monitored > 0:
            trajectory = "Reduced Movement Vigor"
            trajectory_severity = "warning"
        elif days_monitored == 0:
            trajectory = "No Recent Monitoring"
            trajectory_severity = "normal"
        else:
            trajectory = "Stable Motor Function"
            trajectory_severity = "normal"

        period_label = f"past {days} days ({start.strftime('%b %d')} - {end.strftime('%b %d')})"
        if days_monitored == 0:
            narrative = f"No active monitoring sessions were recorded during the {period_label}. Ongoing monitoring is recommended to evaluate current motor state."
        else:
            hrs = round(total_monitoring_minutes / 60, 1)
            time_str = f"{hrs} hour{'s' if hrs != 1.0 else ''}" if hrs >= 1.0 else f"{int(total_monitoring_minutes)} minutes"
            fall_str = f"{total_fall_incidents} fall incident{'s' if total_fall_incidents != 1 else ''}" if total_fall_incidents > 0 else "no sudden falls"
            tremor_str = f"tremor observed on {days_with_tremor} of {days_monitored} active days" if days_with_tremor > 0 else "rest tremor within personal baseline"
            notes_str = f" {total_notes} clinical note{'s' if total_notes != 1 else ''} recorded." if total_notes > 0 else ""
            narrative = (
                f"Across the {period_label}, the patient recorded {days_monitored} active monitoring day{'s' if days_monitored != 1 else ''} "
                f"({time_str} total). Overall motor trajectory: {trajectory.lower()}, with {tremor_str} and {fall_str}.{notes_str}"
            )

        return {
            "patient_id": patient_id,
            "window": "weekly" if days <= 7 else "monthly",
            "days_in_window": days,
            "start_date": start.isoformat(),
            "end_date": end.isoformat(),
            "days_monitored": days_monitored,
            "adherence_pct": adherence_pct,
            "total_monitoring_minutes": round(total_monitoring_minutes, 1),
            "total_fall_incidents": total_fall_incidents,
            "days_with_tremor": days_with_tremor,
            "days_with_gait_issues": days_with_gait_issues,
            "days_with_vigor_reduction": days_with_vigor_reduction,
            "total_notes": total_notes,
            "trajectory": trajectory,
            "trajectory_severity": trajectory_severity,
            "clinical_narrative": narrative,
            "daily_breakdown": daily_breakdown,
        }


def symptom_labels(
    features: dict[str, float | None],
    baseline_before_session: dict[str, dict[str, float | int]],
) -> dict[str, str]:
    """Classify movement observations using ParaDigMa's official classifier thresholds
    combined with personal baseline Z-score deviation analysis.
    """
    fall_cat = "critical" if features.get("fall_detected") == 1.0 else "normal"
    if sum(1 for stats in baseline_before_session.values() if stats.get("count", 0) >= 5) < 1:
        res = {name: "baseline building" for name in ("tremor", "gait", "bradykinesia_proxy")}
        res["fall"] = fall_cat
        return res

    def deviation(feature: str, direction: float, noise_floor: float = 1e-4) -> float | None:
        value = features.get(feature)
        stats = baseline_before_session.get(feature)
        if value is None or stats is None or stats.get("count", 0) < 5:
            return None
        numeric = float(value)
        # A value already seen in the patient's baseline is variability, not a
        # new deviation. This matters most for zero-inflated tremor features.
        if within_observed_range(feature, numeric, stats):
            return None
        # Median/MAD is resistant to a few unusual intervals. Fall back to the
        # online standard deviation for older baselines without a MAD value.
        spread = 1.4826 * float(stats.get("mad", 0.0) or 0.0)
        if spread <= 0:
            spread = float(stats.get("std", 0.0))
        spread = max(spread, noise_floor, 1e-6)
        center = float(stats.get("median", stats.get("mean", 0.0)))
        return direction * (numeric - center) / spread

    def z_to_category(score: float | None) -> str:
        if score is None or score < 1.0:
            return "normal"
        if score < 2.0:
            return "mild"
        if score < 3.0:
            return "moderate"
        return "severe"

    category_rank = {"normal": 0, "mild": 1, "moderate": 2, "severe": 3}

    # 1. Tremor:
    # Uses ParaDigMa's trained classifier threshold (PARADIGMA_TREMOR_THRESHOLD = 0.02957).
    # A session is positive for tremor if:
    # - pred_tremor_proba >= PARADIGMA_TREMOR_THRESHOLD, or
    # - ParaDigMa confirmed rest tremor (tremor_time > 0 or tremor_power > 0).
    t_prob = features.get("tremor_probability")
    t_power = features.get("tremor_power")
    t_time = features.get("tremor_time")

    has_detected_tremor = (
        (t_prob is not None and t_prob >= PARADIGMA_TREMOR_THRESHOLD)
        or (t_time is not None and t_time > 0.0)
        or (t_power is not None and t_power > 0.0)
    )

    if not has_detected_tremor:
        tremor_cat = "normal"
    else:
        # Tremor is detected above ParaDigMa's threshold.
        # Standardized deviation relative to personal baseline:
        z_scores: list[float] = []
        if t_prob is not None and t_prob >= PARADIGMA_TREMOR_THRESHOLD:
            z_prob = deviation("tremor_probability", 1.0, noise_floor=PARADIGMA_TREMOR_THRESHOLD)
            if z_prob is not None:
                z_scores.append(z_prob)
        if t_time is not None and t_time > 0.0:
            z_time = deviation("tremor_time", 1.0, noise_floor=PARADIGMA_TREMOR_THRESHOLD)
            if z_time is not None:
                z_scores.append(z_time)
        if t_power is not None and t_power > 0.0:
            z_power = deviation("tremor_power", 1.0, noise_floor=1.0)
            if z_power is not None:
                z_scores.append(z_power)

        base_cat = z_to_category(max(z_scores)) if z_scores else "normal"

        # Absolute thresholds remain a safety net for clearly high tremor,
        # even when the patient's personal baseline is already elevated. A
        # borderline time ratio alone is not enough: require a clearly high
        # probability or spectral power before overriding the personal range.
        has_clinical_tremor = (
            (t_prob is not None and t_prob >= 0.25)
            or (t_power is not None and t_power >= 1.0)
        )
        if not has_clinical_tremor:
            absolute_cat = "normal"
        elif (
            (t_prob is not None and t_prob >= 0.80)
            or (t_power is not None and t_power >= 20.0)
            or (t_time is not None and t_time >= 0.50)
        ):
            absolute_cat = "severe"
        elif (
            (t_prob is not None and t_prob >= 0.50)
            or (t_power is not None and t_power >= 5.0)
            or (t_time is not None and t_time >= 0.25)
        ):
            absolute_cat = "moderate"
        elif (
            (t_prob is not None and t_prob >= 0.25)
            or (t_power is not None and t_power >= 1.0)
            or (t_time is not None and t_time >= 0.10)
        ):
            absolute_cat = "mild"
        else:
            absolute_cat = "normal"
        tremor_cat = max((base_cat, absolute_cat), key=category_rank.get)

    # 2. Gait & Arm swing:
    # Uses ParaDigMa's gait classifier threshold (PARADIGMA_GAIT_THRESHOLD = 0.2099).
    # If no gait detected and no arm swing was quantified, participant was stationary.
    gait_prob = features.get("gait_probability")
    arm_rom = features.get("arm_swing_rom")
    arm_vel = features.get("arm_swing_peak_velocity")

    has_detected_gait = (
        (gait_prob is not None and gait_prob >= PARADIGMA_GAIT_THRESHOLD)
        or arm_rom is not None
    )

    if not has_detected_gait:
        gait_cat = "insufficient data"
    else:
        # Gait occurred. If arm swing was quantified, evaluate arm swing reduction (hypokinesia)
        if arm_rom is not None or arm_vel is not None:
            rom_z = deviation("arm_swing_rom", -1.0, noise_floor=2.0)
            vel_z = deviation("arm_swing_peak_velocity", -1.0, noise_floor=10.0)
            valid_z = [z for z in (rom_z, vel_z) if z is not None]
            base_cat = z_to_category(max(valid_z)) if valid_z else "normal"
            if arm_rom is not None and arm_rom < 10.0:
                absolute_cat = "severe"
            elif arm_rom is not None and arm_rom < 18.0:
                absolute_cat = "moderate"
            elif arm_rom is not None and arm_rom < 25.0:
                absolute_cat = "mild"
            else:
                absolute_cat = "normal"
            gait_cat = max((base_cat, absolute_cat), key=category_rank.get)
        else:
            gait_cat = "normal"

    # 3. Movement vigor / Bradykinesia proxy:
    # Evaluates reduction in dynamic motion relative to baseline:
    gyro_z = deviation("gyro_rms_rad_s", -1.0, noise_floor=0.05)
    brady_cat = z_to_category(gyro_z)

    return {
        "tremor": tremor_cat,
        "gait": gait_cat,
        "bradykinesia_proxy": brady_cat,
        "fall": fall_cat,
    }


def _summary_text(overall: str, labels: dict[str, str], count: int) -> str:
    if count == 0:
        return "No quality-passing monitoring intervals have been processed today."
    if overall == "baseline building":
        return f"Personal baseline building: {count} quality-passing intervals processed today."
    if overall == "insufficient data":
        return (
            "The personal baseline is frozen. No anomaly-monitoring intervals "
            "have been processed today yet."
        )
    fall_warning = " [URGENT: Sudden fall detected today!]" if labels.get("fall") == "critical" else ""
    return (
        f"Movement observations are {overall} relative to the current personal baseline{fall_warning}. "
        f"Tremor {labels.get('tremor', 'normal')}; gait/arm swing {labels.get('gait', 'normal')}; "
        f"bradykinesia-compatible movement-vigor proxy {labels.get('bradykinesia_proxy', 'normal')}."
    )


feature_store = FeatureStore()
