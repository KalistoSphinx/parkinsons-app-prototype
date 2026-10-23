import tempfile
import unittest
from pathlib import Path

from processing.app.alerts import AlertStore, COOLDOWN_MS, EPISODE_GAP_MS
from processing.app.feature_store import FeatureStore


def anomaly(symptoms, drivers=None, severity="warning", score=0.8):
    return {
        "score": score,
        "severity": severity,
        "model": "robust_z",
        "stat_z": 2.8,
        "if_score": None,
        "context": "rest",
        "drivers": drivers
        or [
            {
                "feature": "tremor_probability",
                "z": 2.8,
                "value": 0.4,
                "baseline_median": 0.05,
                "direction": "high",
                "symptom": "tremor",
            }
        ],
        "symptoms": symptoms,
    }


def tremor_anomaly(severity, z, score=0.8):
    return anomaly(
        {"tremor": severity},
        drivers=[
            {
                "feature": "tremor_probability",
                "z": z,
                "value": 0.4,
                "baseline_median": 0.05,
                "direction": "high",
                "symptom": "tremor",
            }
        ],
        severity=severity,
        score=score,
    )


class AlertRuleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.store = FeatureStore(Path(self.temporary.name) / "vectors")
        self.alerts = AlertStore(self.store)

    def tearDown(self):
        self.temporary.cleanup()

    def _evaluate(self, session_id, timestamp_ms, payload, recent=None):
        return self.alerts.evaluate(
            patient_id="patient-1",
            session_id=session_id,
            timestamp_ms=timestamp_ms,
            created_at="2026-10-22T10:00:00+00:00",
            anomaly=payload,
            recent_sessions=recent or [],
        )

    def test_warning_fires_immediately(self):
        created = self._evaluate("s1", 1_000, tremor_anomaly("warning", 2.8))

        self.assertEqual(len(created), 1)
        self.assertEqual(created[0]["severity"], "warning")

    def test_critical_fires_immediately(self):
        created = self._evaluate(
            "s1",
            1_000,
            tremor_anomaly("critical", 2.8, score=0.95),
        )

        self.assertEqual(len(created), 1)
        self.assertEqual(created[0]["severity"], "critical")
        self.assertTrue(created[0]["title"].startswith("Urgent:"))

    def test_repeat_within_cooldown_is_suppressed(self):
        first = self._evaluate("s1", 1_000, tremor_anomaly("critical", 2.8, 0.95))
        repeat = self._evaluate(
            "s2",
            1_000 + 30_000,
            tremor_anomaly("critical", 2.8, 0.95),
        )

        self.assertEqual(len(first), 1)
        self.assertEqual(repeat, [])

    def test_materially_worse_same_severity_re_notifies_immediately(self):
        first = self._evaluate("s1", 1_000, tremor_anomaly("critical", 2.8, 0.95))
        worse = self._evaluate(
            "s2",
            1_000 + 30_000,
            tremor_anomaly("critical", 5.0, 1.0),
        )

        self.assertEqual(len(worse), 1)
        self.assertEqual(worse[0]["severity"], "critical")
        previous = self.alerts.get("patient-1", first[0]["alert_id"])
        self.assertEqual(previous["status"], "resolved")
        self.assertEqual(previous["resolution"], "worsened")

    def test_same_severity_re_notifies_after_cooldown(self):
        first = self._evaluate("s1", 1_000, tremor_anomaly("critical", 2.8, 0.95))
        repeat = self._evaluate(
            "s2",
            1_000 + COOLDOWN_MS + 1,
            tremor_anomaly("critical", 2.8, 0.95),
        )

        self.assertEqual(len(repeat), 1)
        previous = self.alerts.get("patient-1", first[0]["alert_id"])
        self.assertEqual(previous["status"], "resolved")
        self.assertEqual(previous["resolution"], "recurrence")

    def test_acknowledged_alert_allows_subsequent_test_to_alert(self):
        first = self._evaluate("s1", 1_000, tremor_anomaly("critical", 2.8, 0.95))
        self.assertEqual(len(first), 1)
        self.alerts.acknowledge("patient-1", first[0]["alert_id"])

        # Once the user acknowledges, performing another tremor test creates a new alert
        subsequent = self._evaluate(
            "s2",
            1_000 + 10_000,
            tremor_anomaly("critical", 2.8, 0.95),
        )

        self.assertEqual(len(subsequent), 1)
        self.assertEqual(subsequent[0]["severity"], "critical")
        self.assertEqual(subsequent[0]["status"], "new")

    def test_monitoring_gap_starts_a_fresh_alert_episode(self):
        first = self._evaluate("s1", 1_000, tremor_anomaly("critical", 2.8, 0.95))
        restarted = self._evaluate(
            "s2",
            1_000 + EPISODE_GAP_MS + 1,
            tremor_anomaly("critical", 2.8, 0.95),
        )

        self.assertEqual(len(restarted), 1)
        previous = self.alerts.get("patient-1", first[0]["alert_id"])
        self.assertEqual(previous["status"], "resolved")
        self.assertEqual(previous["resolution"], "monitoring_restarted")

    def test_escalation_resolves_the_lower_severity_alert(self):
        warning = tremor_anomaly("warning", 2.8)
        critical = tremor_anomaly("critical", 5.0, 0.95)
        created_warning = self._evaluate("s1", 1_000, warning)
        created_critical = self._evaluate("s2", 2_000, critical)

        self.assertEqual(len(created_warning), 1)
        self.assertEqual(len(created_critical), 1)
        first = self.alerts.get("patient-1", created_warning[0]["alert_id"])
        self.assertEqual(first["status"], "resolved")
        self.assertEqual(first["resolution"], "escalated")
        self.assertEqual(created_critical[0]["severity"], "critical")

    def test_acknowledge_and_resolution(self):
        created = self._evaluate(
            "s1",
            1_000,
            anomaly({"tremor": "critical"}, severity="critical", score=0.95),
        )
        alert_id = created[0]["alert_id"]

        acknowledged = self.alerts.acknowledge("patient-1", alert_id)
        self.assertEqual(acknowledged["status"], "acknowledged")

        clear = anomaly({"tremor": "normal"}, severity="normal", score=0.1)
        self._evaluate("s2", 2_000, clear)
        self._evaluate("s3", 3_000, clear)
        self._evaluate("s4", 4_000, clear)

        resolved = self.alerts.get("patient-1", alert_id)
        self.assertEqual(resolved["status"], "resolved")

    def test_alert_store_is_scoped_per_patient(self):
        self._evaluate(
            "s1",
            1_000,
            anomaly({"tremor": "critical"}, severity="critical", score=0.95),
        )

        self.assertEqual(len(self.alerts.list("patient-1")), 1)
        self.assertEqual(self.alerts.list("patient-2"), [])

    def test_fall_creates_critical_alert_and_bypasses_cooldown(self):
        fall_anomaly = anomaly(
            {"fall": "critical"},
            drivers=[
                {
                    "feature": "fall_impact_g",
                    "z": 5.6,
                    "value": 3.8,
                    "baseline_median": 1.0,
                    "direction": "high",
                    "symptom": "fall",
                }
            ],
            severity="critical",
            score=1.0,
        )
        created = self._evaluate("s1", 1_000, fall_anomaly)
        self.assertEqual(len(created), 1)
        self.assertEqual(created[0]["symptom"], "fall")
        self.assertEqual(created[0]["severity"], "critical")
        self.assertEqual(created[0]["title"], "Urgent: Sudden fall detected")

        # Second fall within standard cooldown ms should NOT be suppressed
        second = self._evaluate("s2", 1_000 + 10_000, fall_anomaly)
        self.assertEqual(len(second), 1)
        self.assertEqual(second[0]["symptom"], "fall")


if __name__ == "__main__":
    unittest.main()
