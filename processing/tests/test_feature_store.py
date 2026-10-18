import tempfile
import unittest
from datetime import date
from pathlib import Path

from processing.app.feature_store import FeatureStore, symptom_labels
from processing.app.features import FEATURE_COLUMNS


class FeatureStoreTests(unittest.TestCase):
    def test_valid_monitoring_uploads_form_baseline_and_day_report_automatically(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = FeatureStore(Path(temporary) / "vectors.json")
            features = {column: 1.0 for column in FEATURE_COLUMNS}
            features["tremor_power"] = None
            day = date(2026, 10, 7).isoformat()

            for index in range(5):
                before = store.baseline("patient-1")
                labels = symptom_labels(features, before)
                store.upsert({
                    "patient_id": "patient-1",
                    "session_id": f"chunk-{index}",
                    "task_type": "monitoring",
                    "timestamp_ms": 1791331200000 + index * 60_000,
                    "timestamp": f"2026-10-07T00:0{index}:00+00:00",
                    "local_date": day,
                    "duration_s": 180,
                    "quality_passed": True,
                    "symptom_labels": labels,
                    "features": features,
                })

            baseline = store.baseline("patient-1")
            report = store.day_report("patient-1", date.fromisoformat(day))

            self.assertEqual(baseline["tremor_probability"]["count"], 5)
            self.assertNotIn("tremor_power", baseline)
            self.assertEqual(report["processed_sessions"], 5)
            self.assertEqual(report["monitoring_minutes"], 15.0)
            self.assertEqual(report["baseline_sessions"], 5)
            self.assertEqual(report["gait_intervals"], 5)

    def test_gait_and_arm_swing_observations_are_evaluated_when_present(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = FeatureStore(Path(temporary) / "vectors.json")
            day = date(2026, 10, 7).isoformat()

            # Calibration sessions
            for index in range(5):
                store.upsert({
                    "patient_id": "patient-gait",
                    "session_id": f"calib-{index}",
                    "task_type": "monitoring",
                    "timestamp_ms": 1791331200000 + index * 60_000,
                    "timestamp": f"2026-10-07T00:0{index}:00+00:00",
                    "local_date": day,
                    "duration_s": 60,
                    "quality_passed": True,
                    "features": {
                        "tremor_probability": 0.01,
                        "tremor_power": None,
                        "tremor_time": 0.0,
                        "gait_probability": 0.05,
                        "arm_swing_rom": 45.0,
                        "arm_swing_peak_velocity": 200.0,
                        "accel_rms_m_s2": 1.0,
                        "gyro_rms_rad_s": 0.5,
                    },
                })

            report = store.day_report("patient-gait", date.fromisoformat(day))
            self.assertEqual(report["symptom_labels"]["gait"], "normal")
            self.assertIn("arm_swing_rom", report["baseline"])
            self.assertEqual(report["baseline"]["arm_swing_rom"]["count"], 5)


if __name__ == "__main__":
    unittest.main()

