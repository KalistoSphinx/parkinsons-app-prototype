"""Alert rule engine and durable, append-only alert store.

Rules favor timely alerts without notifying on every single interval:

* warning and critical symptoms fire on the first qualifying interval;
* the same symptom is re-notified immediately when it becomes materially worse;
* a short per-symptom cooldown suppresses unchanged repeats, and an
  acknowledged unchanged symptom stays quiet until it worsens or a new episode
  begins;
* a monitoring gap starts a new episode and clears the previous suppression;
* three clear intervals resolve an open alert.
"""

from __future__ import annotations

import json
import os
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SEVERITY_RANK = {"normal": 0, "watch": 1, "warning": 2, "critical": 3}
# Re-notify an unchanged ongoing symptom at most once per minute. A materially
# worse interval bypasses this cooldown so a stronger tremor is not hidden
# behind the previous alert.
COOLDOWN_MS = 60 * 1000
# No upload for this long means the patient stopped/restarted monitoring.
# Treat that as a fresh episode so a new alert is not blocked by the old one.
EPISODE_GAP_MS = 90 * 1000
# A same-severity alert is materially worse when the top driver z-score rises
# by at least this ratio and this many robust standard deviations.
ESCALATION_Z_RATIO = 1.20
ESCALATION_Z_DELTA = 1.0

SYMPTOM_COPY = {
    "tremor": (
        "Tremor above personal baseline",
        "Rest tremor was higher than this patient's usual range.",
    ),
    "gait": (
        "Arm swing below personal baseline",
        "Arm swing was lower than this patient's usual walking pattern.",
    ),
    "bradykinesia_proxy": (
        "Movement vigor below personal baseline",
        "Movement vigor during walking was lower than this patient's usual range.",
    ),
    "fall": (
        "Sudden fall detected",
        "A sudden fall impact and post-fall immobility pattern was detected. Check on the patient immediately.",
    ),
}

class AlertStore:
    """Persist alerts as JSONL and keep small per-patient rule state."""

    def __init__(self, feature_store: Any) -> None:
        self.feature_store = feature_store
        self._lock = threading.RLock()

    def _alerts_path(self, patient_id: str) -> Path:
        return self.feature_store.patient_directory(patient_id) / "_alerts.jsonl"

    def _state_path(self, patient_id: str) -> Path:
        return self.feature_store.patient_directory(patient_id) / "_alert_state.json"

    def list(
        self,
        patient_id: str,
        *,
        after_timestamp_ms: int = 0,
        status: str | None = None,
        limit: int = 100,
    ) -> list[dict[str, Any]]:
        path = self._alerts_path(patient_id)
        if not path.exists():
            return []
        alerts: list[dict[str, Any]] = []
        with self._lock:
            for line in path.read_text(encoding="utf-8").splitlines():
                if not line.strip():
                    continue
                try:
                    item = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if int(item.get("timestamp_ms", 0)) <= after_timestamp_ms:
                    continue
                if status is not None and item.get("status") != status:
                    continue
                alerts.append(item)
        alerts.sort(key=lambda item: int(item.get("timestamp_ms", 0)))
        return alerts[-max(1, min(limit, 500)):]

    def get(self, patient_id: str, alert_id: str | None) -> dict[str, Any] | None:
        if not alert_id:
            return None
        for item in self.list(patient_id, limit=500):
            if item.get("alert_id") == alert_id:
                return item
        return None

    def _append(self, patient_id: str, alert: dict[str, Any]) -> None:
        path = self._alerts_path(patient_id)
        path.parent.mkdir(parents=True, exist_ok=True)
        line = json.dumps(alert, allow_nan=False, separators=(",", ":"))
        with self._lock:
            with path.open("a", encoding="utf-8") as target:
                target.write(line + "\n")
                target.flush()
                os.fsync(target.fileno())

    def _rewrite(self, patient_id: str, alerts: list[dict[str, Any]]) -> None:
        path = self._alerts_path(patient_id)
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(".tmp")
        with self._lock:
            with temporary.open("w", encoding="utf-8") as target:
                for item in alerts:
                    target.write(
                        json.dumps(item, allow_nan=False, separators=(",", ":")) + "\n"
                    )
                target.flush()
                os.fsync(target.fileno())
            os.replace(temporary, path)

    def set_status(
        self,
        patient_id: str,
        alert_id: str,
        status: str,
        **changes: Any,
    ) -> dict[str, Any] | None:
        alerts = self.list(patient_id, limit=500)
        updated = None
        for item in alerts:
            if item.get("alert_id") == alert_id:
                item["status"] = status
                item.update(changes)
                updated = item
        if updated is not None:
            self._rewrite(patient_id, alerts)
        return updated

    def acknowledge(self, patient_id: str, alert_id: str) -> dict[str, Any] | None:
        current = self.get(patient_id, alert_id)
        if current is None:
            return None
        if current.get("status") == "resolved":
            return current
        now = datetime.now(timezone.utc).isoformat()
        return self.set_status(
            patient_id,
            alert_id,
            "acknowledged",
            acknowledged_at=now,
        )

    def resolve(self, patient_id: str, alert_id: str, resolved_at_ms: int) -> None:
        self.set_status(
            patient_id,
            alert_id,
            "resolved",
            resolved_at=datetime.fromtimestamp(
                resolved_at_ms / 1000,
                tz=timezone.utc,
            ).isoformat(),
        )

    def dismiss(
        self,
        patient_id: str,
        alert_id: str,
        *,
        reason: str = "false_positive",
    ) -> dict[str, Any] | None:
        current = self.get(patient_id, alert_id)
        if current is None:
            return None
        now = datetime.now(timezone.utc).isoformat()
        updated = self.set_status(
            patient_id,
            alert_id,
            "resolved",
            resolved_at=now,
            resolution=reason,
            dismissed_at=now,
        )
        state = self.state(patient_id)
        open_alerts = state.get("open_alert_by_symptom", {})
        symptom = current.get("symptom")
        if symptom and open_alerts.get(symptom) == alert_id:
            del open_alerts[symptom]
            self.save_state(patient_id, state)
        return updated

    def state(self, patient_id: str) -> dict[str, Any]:
        path = self._state_path(patient_id)
        if not path.exists():
            return {}
        with self._lock:
            try:
                return json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                return {}

    def save_state(self, patient_id: str, state: dict[str, Any]) -> None:
        path = self._state_path(patient_id)
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(".tmp")
        with self._lock:
            temporary.write_text(
                json.dumps(state, allow_nan=False, separators=(",", ":")),
                encoding="utf-8",
            )
            os.replace(temporary, path)

    def clear_state(self, patient_id: str) -> None:
        path = self._state_path(patient_id)
        if path.exists():
            path.unlink()

    def evaluate(
        self,
        *,
        patient_id: str,
        session_id: str,
        timestamp_ms: int,
        created_at: str,
        anomaly: dict[str, Any],
        recent_sessions: list[dict[str, Any]],
    ) -> list[dict[str, Any]]:
        state = self.state(patient_id)
        last_session_ms = int(state.get("last_session_ms", 0))
        if not last_session_ms and recent_sessions:
            # Older alert state predates the episode marker. Seed it from the
            # most recent stored interval so a long pause is still detected.
            last_session_ms = max(
                (int(document.get("timestamp_ms", 0)) for document in recent_sessions),
                default=0,
            )
        if last_session_ms and timestamp_ms - last_session_ms > EPISODE_GAP_MS:
            self._start_new_episode(patient_id, state, created_at)
        state["last_session_ms"] = max(last_session_ms, timestamp_ms)

        symptoms = {
            symptom: severity
            for symptom, severity in (anomaly.get("symptoms") or {}).items()
            if SEVERITY_RANK.get(severity, 0) >= SEVERITY_RANK["warning"]
        }

        self._update_clear_streaks(state, anomaly)
        self._resolve_clear_alerts(patient_id, state, timestamp_ms)

        created: list[dict[str, Any]] = []
        ordered = sorted(
            symptoms.items(),
            key=lambda item: SEVERITY_RANK.get(item[1], 0),
            reverse=True,
        )
        for symptom, severity in ordered:
            last_ms = int(state.get("last_alert_ms_by_symptom", {}).get(symptom, 0))
            open_id = state.get("open_alert_by_symptom", {}).get(symptom)
            existing = self.get(patient_id, open_id)
            if existing is not None:
                new_rank = SEVERITY_RANK.get(severity, 0)
                old_rank = SEVERITY_RANK.get(existing.get("severity", "normal"), 0)
                if new_rank < old_rank:
                    continue
                worse = new_rank == old_rank and self._materially_worse(
                    existing, anomaly, symptom
                )
                is_ack = existing.get("status") == "acknowledged"

                # If an ongoing alert is unacknowledged, throttle duplicate notifications within cooldown.
                # Once acknowledged, a subsequent tremor test or episode resolves the previous
                # alert and immediately generates a fresh alert.
                # Sudden falls are acute physical emergencies and bypass routine cooldown.
                if symptom != "fall" and new_rank == old_rank and not worse and not is_ack:
                    if timestamp_ms - last_ms < COOLDOWN_MS:
                        continue

                resolution = (
                    "escalated"
                    if new_rank > old_rank
                    else "worsened"
                    if worse
                    else "acknowledged_recurrence"
                    if is_ack
                    else "recurrence"
                )
                self.set_status(
                    patient_id,
                    open_id,
                    "resolved",
                    resolved_at=created_at,
                    resolution=resolution,
                )
            elif symptom != "fall" and last_ms > 0 and timestamp_ms - last_ms < COOLDOWN_MS:
                continue

            alert = self._build_alert(
                patient_id=patient_id,
                session_id=session_id,
                timestamp_ms=timestamp_ms,
                created_at=created_at,
                symptom=symptom,
                severity=severity,
                anomaly=anomaly,
                recent_sessions=recent_sessions,
            )
            self._append(patient_id, alert)
            state.setdefault("last_alert_ms_by_symptom", {})[symptom] = timestamp_ms
            state.setdefault("open_alert_by_symptom", {})[symptom] = alert["alert_id"]
            state.setdefault("clear_streak_by_symptom", {})[symptom] = 0
            created.append(alert)

        self.save_state(patient_id, state)
        return created

    def _start_new_episode(
        self,
        patient_id: str,
        state: dict[str, Any],
        resolved_at: str,
    ) -> None:
        """Close stale open alerts after a monitoring gap and reset throttles."""
        for alert_id in list(state.get("open_alert_by_symptom", {}).values()):
            self.set_status(
                patient_id,
                alert_id,
                "resolved",
                resolved_at=resolved_at,
                resolution="monitoring_restarted",
            )
        state["open_alert_by_symptom"] = {}
        state["clear_streak_by_symptom"] = {}
        state["last_alert_ms_by_symptom"] = {}

    @staticmethod
    def _top_driver_z(payload: dict[str, Any], symptom: str) -> float:
        values = [
            float(driver.get("z", 0.0))
            for driver in payload.get("drivers", [])
            if driver.get("symptom") == symptom
        ]
        return max(values, default=0.0)

    @staticmethod
    def _materially_worse(
        existing: dict[str, Any],
        anomaly: dict[str, Any],
        symptom: str,
    ) -> bool:
        old_z = AlertStore._top_driver_z(existing, symptom)
        new_z = AlertStore._top_driver_z(anomaly, symptom)
        if old_z > 0 and new_z > 0:
            return (
                new_z >= old_z * ESCALATION_Z_RATIO
                and new_z - old_z >= ESCALATION_Z_DELTA
            )
        old_score = float(existing.get("score", 0.0))
        new_score = float(anomaly.get("score", 0.0))
        return (
            old_score > 0
            and new_score >= old_score * ESCALATION_Z_RATIO
            and new_score - old_score >= 0.10
        )

    def _update_clear_streaks(
        self,
        state: dict[str, Any],
        anomaly: dict[str, Any],
    ) -> None:
        open_alerts = state.get("open_alert_by_symptom", {})
        if not open_alerts:
            return
        current_symptoms = anomaly.get("symptoms") or {}
        streaks = state.setdefault("clear_streak_by_symptom", {})
        for symptom in open_alerts:
            current = SEVERITY_RANK.get(
                current_symptoms.get(symptom, "normal"), 0
            )
            if current >= SEVERITY_RANK["warning"]:
                streaks[symptom] = 0
            else:
                streaks[symptom] = int(streaks.get(symptom, 0)) + 1

    def _resolve_clear_alerts(
        self,
        patient_id: str,
        state: dict[str, Any],
        timestamp_ms: int,
    ) -> None:
        open_alerts = state.get("open_alert_by_symptom", {})
        if not open_alerts:
            return
        streaks = state.setdefault("clear_streak_by_symptom", {})
        for symptom, alert_id in list(open_alerts.items()):
            if int(streaks.get(symptom, 0)) < 3:
                continue
            self.resolve(patient_id, alert_id, timestamp_ms)
            del open_alerts[symptom]
            streaks.pop(symptom, None)

    def _build_alert(
        self,
        *,
        patient_id: str,
        session_id: str,
        timestamp_ms: int,
        created_at: str,
        symptom: str,
        severity: str,
        anomaly: dict[str, Any],
        recent_sessions: list[dict[str, Any]],
    ) -> dict[str, Any]:
        title, message = SYMPTOM_COPY.get(
            symptom,
            (
                "Movement pattern change",
                "A movement pattern changed relative to the personal baseline.",
            ),
        )
        if severity == "critical":
            title = f"Urgent: {title}"

        drivers = [
            driver
            for driver in anomaly.get("drivers", [])
            if driver.get("symptom") == symptom
            and float(driver.get("z", 0.0)) >= 2.0
        ][:3]
        if drivers:
            top = drivers[0]
            message = (
                f"{message} {top['feature'].replace('_', ' ')} was "
                f"{top['z']:.1f} robust SD {top['direction']} of the personal median."
            )

        evidence = [
            document.get("session_id")
            for document in recent_sessions[-2:]
            if document.get("session_id")
        ]
        evidence.append(session_id)

        return {
            "alert_id": str(uuid.uuid4()),
            "patient_id": patient_id,
            "session_id": session_id,
            "created_at": created_at,
            "timestamp_ms": int(timestamp_ms),
            "severity": severity,
            "status": "new",
            "symptom": symptom,
            "title": title,
            "message": message,
            "score": float(anomaly.get("score", 0.0)),
            "model": anomaly.get("model", "robust_z"),
            "context": anomaly.get("context", "unknown"),
            "drivers": drivers,
            "evidence_session_ids": evidence,
        }

