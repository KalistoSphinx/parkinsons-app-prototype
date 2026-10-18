"""Compact feature-only document store and immediately updated patient baselines."""

from __future__ import annotations

import json
import os
import random
import tempfile
import threading
from datetime import date
from hashlib import sha256
from pathlib import Path
from typing import Any

import numpy as np

from .features import FEATURE_COLUMNS

_DEFAULT_PATH = Path(__file__).resolve().parents[1] / "data" / "feature_vectors"
_QUANTILE_RESERVOIR_SIZE = 2048


class FeatureStore:
    """One JSON document per session; online stats avoid rescanning raw history."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = path or Path(os.environ.get("FEATURE_STORE_PATH", _DEFAULT_PATH))
        self._lock = threading.RLock()

    def _patient_directory(self, patient_id: str) -> Path:
        key = sha256(patient_id.encode("utf-8")).hexdigest()
        return self.path / key

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

        with self._lock:
            # Idempotent retry: the first committed output for a session is the
            # durable one, and it must not be counted twice in the baseline.
            if list(directory.glob(f"*_{session_key}.json")):
                return
            stats = self._load_or_rebuild_stats(directory)
            if document.get("quality_passed") is True:
                stats["quality_session_count"] += 1
                for column in FEATURE_COLUMNS:
                    value = document.get("features", {}).get(column)
                    if value is not None and np.isfinite(value):
                        self._add_value(stats["features"].setdefault(column, self._empty_feature_stats()), float(value), f"{document['session_id']}:{column}")
            self._write_atomic(document_path, document)
            self._write_atomic(stats_path, stats)

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
        if stats_path.exists():
            return self._read(stats_path)

        stats: dict[str, Any] = {
            "quality_session_count": 0,
            "features": {},
        }
        for path in directory.glob("*.json"):
            if path.name.startswith("_"):
                continue
            item = self._read(path)
            if item.get("quality_passed") is not True:
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

    def _baseline_from_stats(self, stats: dict[str, Any]) -> dict[str, dict[str, float | int]]:
        result = {}
        for column, values in stats["features"].items():
            sample = np.asarray(values["sample"], dtype=float)
            if sample.size == 0:
                continue
            result[column] = {
                "count": int(values["count"]),
                "mean": float(values["mean"]),
                "median": float(np.median(sample)),
                "std": float(np.sqrt(values["m2"] / (values["count"] - 1))) if values["count"] > 1 else 0.0,
                "min": float(values["min"]),
                "max": float(values["max"]),
                "p05": float(np.percentile(sample, 5)),
                "p25": float(np.percentile(sample, 25)),
                "p75": float(np.percentile(sample, 75)),
                "p95": float(np.percentile(sample, 95)),
            }
        return result

    def baseline(self, patient_id: str | None) -> dict[str, dict[str, float | int]]:
        if not patient_id:
            return {}
        directory = self._patient_directory(patient_id)
        if not directory.exists():
            return {}
        with self._lock:
            return self._baseline_from_stats(self._load_or_rebuild_stats(directory))

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
        stats = self._load_or_rebuild_stats(directory) if directory.exists() else {
            "quality_session_count": 0,
            "features": {},
        }
        baseline = self._baseline_from_stats(stats)
        numerical = {}
        for column in FEATURE_COLUMNS:
            values = [
                item["features"].get(column)
                for item in documents
                if item.get("features", {}).get(column) is not None
            ]
            if values:
                numerical[column] = float(np.median(values))

        labels: dict[str, str] = {}
        symptoms = ("tremor", "gait", "bradykinesia_proxy")
        priority = {"normal": 0, "mild": 1, "moderate": 2, "severe": 3}

        if stats["quality_session_count"] < 5:
            labels = {symptom: "baseline building" for symptom in symptoms}
            overall = "baseline building"
        else:
            day_eval = symptom_labels(numerical, baseline)
            session_evals = [
                symptom_labels(item.get("features", {}), baseline)
                for item in documents
            ]
            for symptom in symptoms:
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

        return {
            "patient_id": patient_id,
            "date": day.isoformat(),
            "overall_status": overall,
            "symptom_labels": labels,
            "processed_sessions": len(documents),
            "tremor_intervals": sum(item.get("features", {}).get("tremor_probability") is not None for item in documents),
            "gait_intervals": sum(item.get("features", {}).get("gait_probability") is not None for item in documents),
            "movement_intervals": sum(item.get("features", {}).get("gyro_rms_rad_s") is not None for item in documents),
            "baseline_sessions": stats["quality_session_count"],
            "monitoring_minutes": round(sum(item.get("duration_s", 0) for item in documents) / 60, 1),
            "last_processed": max((item.get("timestamp") for item in documents), default=None),
            "day_features": numerical,
            "baseline": baseline,
            "summary": _summary_text(overall, labels, len(documents)),
        }


def symptom_labels(
    features: dict[str, float | None],
    baseline_before_session: dict[str, dict[str, float | int]],
) -> dict[str, str]:
    """Clinically grounded relative descriptive categories with noise-floor gating."""
    if sum(1 for stats in baseline_before_session.values() if stats.get("count", 0) >= 5) < 1:
        return {name: "baseline building" for name in ("tremor", "gait", "bradykinesia_proxy")}

    def deviation(feature: str, direction: float, min_count: int = 1) -> float | None:
        value = features.get(feature)
        stats = baseline_before_session.get(feature)
        if value is None or stats is None or stats.get("count", 0) < min_count:
            return None
        spread = max(float(stats.get("std", 0.0)), abs(float(stats.get("mean", 0.0))) * 0.15, 1e-6)
        return direction * (float(value) - float(stats["mean"])) / spread

    def z_to_category(score: float | None) -> str:
        if score is None or score < 1.0:
            return "normal"
        if score < 2.0:
            return "mild"
        if score < 3.0:
            return "moderate"
        return "severe"

    priority = {"normal": 0, "mild": 1, "moderate": 2, "severe": 3}

    # 1. Tremor:
    t_prob = features.get("tremor_probability") or 0.0
    t_power = features.get("tremor_power")
    t_time = features.get("tremor_time") or 0.0

    # Clinical noise-floor check:
    # Sensor noise / resting drift is typically power < 1.0 deg^2/s^2 and prob < 0.25.
    has_clinical_tremor = (
        t_prob >= 0.25
        or (t_power is not None and t_power >= 1.0)
    )

    if not has_clinical_tremor:
        tremor_cat = "normal"
    else:
        z_scores = []
        if t_power is not None and t_power >= 1.0:
            z_scores.append(deviation("tremor_power", 1, min_count=1))
        if t_time >= 0.10:
            z_scores.append(deviation("tremor_time", 1, min_count=1))
        if t_prob >= 0.25:
            z_scores.append(deviation("tremor_probability", 1, min_count=1))

        valid_z = [z for z in z_scores if z is not None]
        base_cat = z_to_category(max(valid_z)) if valid_z else "normal"

        if t_prob >= 0.80 or (t_power is not None and t_power >= 20.0) or t_time >= 0.50:
            abs_cat = "severe"
        elif t_prob >= 0.50 or (t_power is not None and t_power >= 5.0) or t_time >= 0.25:
            abs_cat = "moderate"
        elif t_prob >= 0.25 or (t_power is not None and t_power >= 1.0) or t_time >= 0.10:
            abs_cat = "mild"
        else:
            abs_cat = "normal"
        tremor_cat = max((base_cat, abs_cat), key=priority.get)

    # 2. Gait & Arm swing:
    arm_rom = features.get("arm_swing_rom")
    arm_vel = features.get("arm_swing_peak_velocity")
    gait_prob = features.get("gait_probability") or 0.0

    gait_cat: str | None = None
    if arm_rom is not None or arm_vel is not None:
        rom_z = deviation("arm_swing_rom", -1, min_count=1)
        vel_z = deviation("arm_swing_peak_velocity", -1, min_count=1)
        valid_z = [z for z in (rom_z, vel_z) if z is not None]
        base_cat = z_to_category(max(valid_z)) if valid_z else "normal"

        rom_val = arm_rom if arm_rom is not None else 999.0
        if rom_val < 10.0:
            abs_cat = "severe"
        elif rom_val < 18.0:
            abs_cat = "moderate"
        elif rom_val < 25.0:
            abs_cat = "mild"
        else:
            abs_cat = "normal"
        gait_cat = max((base_cat, abs_cat), key=priority.get)
    elif gait_prob >= 0.20:
        gait_z = deviation("gait_probability", 1, min_count=1)
        gait_cat = z_to_category(gait_z)

    # 3. Movement vigor / Bradykinesia proxy:
    accel_rms = features.get("accel_rms_m_s2") or 0.0
    gyro_rms = features.get("gyro_rms_rad_s") or 0.0
    if accel_rms < 0.20 and gyro_rms < 0.05:
        brady_cat = "normal"
    else:
        gyro_z = deviation("gyro_rms_rad_s", -1, min_count=1)
        brady_cat = z_to_category(gyro_z)

    return {
        "tremor": tremor_cat,
        "gait": gait_cat or "insufficient data",
        "bradykinesia_proxy": brady_cat,
    }


def _summary_text(overall: str, labels: dict[str, str], count: int) -> str:
    if count == 0:
        return "No quality-passing monitoring intervals have been processed today."
    if overall == "baseline building":
        return f"Personal baseline building: {count} quality-passing intervals processed today."
    return (
        f"Movement observations are {overall} relative to the current personal baseline. "
        f"Tremor {labels['tremor']}; gait/arm swing {labels['gait']}; "
        f"bradykinesia-compatible movement-vigor proxy {labels['bradykinesia_proxy']}."
    )


feature_store = FeatureStore()
