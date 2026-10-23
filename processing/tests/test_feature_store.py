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

    def test_paradigma_thresholds_for_tremor_and_gait(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = FeatureStore(Path(temporary) / "vectors.json")
            day = date(2026, 10, 7).isoformat()

            # Build 5 baseline intervals with physiological resting floor
            for index in range(5):
                store.upsert({
                    "patient_id": "test-patient",
                    "session_id": f"init-{index}",
                    "task_type": "monitoring",
                    "timestamp_ms": 1791331200000 + index * 60_000,
                    "timestamp": f"2026-10-07T00:0{index}:00+00:00",
                    "local_date": day,
                    "duration_s": 60,
                    "quality_passed": True,
                    "features": {
                        "tremor_probability": 0.00015,
                        "tremor_power": None,
                        "tremor_time": 0.0,
                        "gait_probability": 0.00002,
                        "arm_swing_rom": None,
                        "arm_swing_peak_velocity": None,
                        "accel_rms_m_s2": 0.035,
                        "gyro_rms_rad_s": 0.0035,
                    },
                })

            baseline = store.baseline("test-patient")

            # 1. Patient 2 tutorial case: prob = 0.013 < PARADIGMA_TREMOR_THRESHOLD (0.02957)
            tut_eval = symptom_labels({
                "tremor_probability": 0.013,
                "tremor_power": None,
                "tremor_time": 0.0,
                "gait_probability": 0.00002,
            }, baseline)
            self.assertEqual(tut_eval["tremor"], "normal")
            self.assertEqual(tut_eval["gait"], "insufficient data")

            # 2. Hard shaking / severe action tremor: prob = 0.887 >= PARADIGMA_TREMOR_THRESHOLD
            shake_eval = symptom_labels({
                "tremor_probability": 0.887,
                "tremor_power": None,
                "tremor_time": None,
                "gait_probability": 0.05,
            }, baseline)
            self.assertEqual(shake_eval["tremor"], "severe")


    def test_observed_range_and_missing_power_keep_day_report_normal(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = FeatureStore(Path(temporary) / "vectors")
            day = date(2026, 10, 7).isoformat()
            normal = {
                "tremor_probability": 0.000168,
                "tremor_power": None,
                "tremor_time": 0.0,
                "gait_probability": 0.00002,
                "arm_swing_rom": None,
                "arm_swing_peak_velocity": None,
                "accel_rms_m_s2": 0.035,
                "gyro_rms_rad_s": 0.0035,
            }
            tremorous = {
                **normal,
                "tremor_probability": 0.090885,
                "tremor_power": 0.399123,
                "tremor_time": 0.222222,
                "gait_probability": 0.0237,
                "gyro_rms_rad_s": 0.6951,
            }
            baseline_features = [tremorous] + [normal] * 6
            for index, features in enumerate(baseline_features):
                store.upsert({
                    "patient_id": "patient-range",
                    "session_id": f"baseline-{index}",
                    "task_type": "monitoring",
                    "monitoring_mode": "baseline",
                    "timestamp_ms": 1791331200000 + index * 60_000,
                    "timestamp": f"2026-10-07T00:{index:02d}:00+00:00",
                    "local_date": day,
                    "duration_s": 60,
                    "quality_passed": True,
                    "baseline_status": "included",
                    "features": features,
                })

            store.finalize_baseline("patient-range")
            reference = store.reference_baseline("patient-range")
            observed = {**normal, "tremor_probability": 0.059925}
            high = {**normal, "tremor_probability": 0.20}
            within_range_tremor = {
                **normal,
                "tremor_probability": 0.090885,
                "tremor_power": 0.399123,
                "tremor_time": 0.222222,
            }

            self.assertEqual(symptom_labels(observed, reference)["tremor"], "normal")
            self.assertEqual(
                symptom_labels(within_range_tremor, reference)["tremor"], "normal"
            )
            self.assertEqual(symptom_labels(high, reference)["tremor"], "severe")

            anomaly_features = [
                observed,
                {**normal, "tremor_probability": 0.000268},
            ]
            for index, features in enumerate(anomaly_features):
                stamp = 1791331200000 + (len(baseline_features) + index) * 60_000
                store.upsert({
                    "patient_id": "patient-range",
                    "session_id": f"anomaly-{index}",
                    "task_type": "monitoring",
                    "monitoring_mode": "anomaly",
                    "timestamp_ms": stamp,
                    "timestamp": f"2026-10-07T00:{len(baseline_features) + index:02d}:00+00:00",
                    "local_date": day,
                    "duration_s": 60,
                    "quality_passed": True,
                    "baseline_status": "excluded",
                    "features": features,
                })

            report = store.day_report("patient-range", date.fromisoformat(day))
            self.assertEqual(report["baseline_sessions"], 7)
            self.assertEqual(report["anomaly_intervals"], 2)
            self.assertEqual(report["symptom_labels"]["tremor"], "normal")
            self.assertEqual(report["overall_status"], "normal")

    def test_anomaly_intervals_never_enter_the_reference_baseline(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = FeatureStore(Path(temporary) / "vectors")
            day = date(2026, 10, 7).isoformat()
            baseline_features = {column: 1.0 for column in FEATURE_COLUMNS}

            for index in range(5):
                store.upsert({
                    "patient_id": "patient-mode",
                    "session_id": f"baseline-{index}",
                    "task_type": "monitoring",
                    "monitoring_mode": "baseline",
                    "timestamp_ms": 1791331200000 + index * 60_000,
                    "timestamp": f"2026-10-07T00:0{index}:00+00:00",
                    "local_date": day,
                    "duration_s": 60,
                    "quality_passed": True,
                    "baseline_status": "included",
                    "features": baseline_features,
                })

            state = store.finalize_baseline("patient-mode")
            self.assertEqual(state["state"], "frozen")
            self.assertEqual(state["reference_sessions"], 5)

            store.upsert({
                "patient_id": "patient-mode",
                "session_id": "anomaly-1",
                "task_type": "monitoring",
                "monitoring_mode": "anomaly",
                "timestamp_ms": 1791331200000 + 6 * 60_000,
                "timestamp": "2026-10-07T00:06:00+00:00",
                "local_date": day,
                "duration_s": 60,
                "quality_passed": True,
                "baseline_status": "excluded",
                "features": {**baseline_features, "tremor_probability": 99.0},
            })

            reference = store.reference_baseline("patient-mode")
            self.assertEqual(reference["tremor_probability"]["count"], 5)
            self.assertEqual(store.baseline("patient-mode")["tremor_probability"]["count"], 5)
            self.assertEqual(store.baseline_state("patient-mode")["reference_sessions"], 5)

            # Even if an upload arrives marked as "baseline", once frozen it CANNOT enter baseline
            store.upsert({
                "patient_id": "patient-mode",
                "session_id": "post-freeze-attempt",
                "task_type": "monitoring",
                "monitoring_mode": "baseline",
                "timestamp_ms": 1791331200000 + 7 * 60_000,
                "timestamp": "2026-10-07T00:07:00+00:00",
                "local_date": day,
                "duration_s": 60,
                "quality_passed": True,
                "baseline_status": "included",
                "features": {**baseline_features, "tremor_probability": 88.0},
            })

            reference2 = store.reference_baseline("patient-mode")
            self.assertEqual(reference2["tremor_probability"]["count"], 5)
            self.assertEqual(store.baseline("patient-mode")["tremor_probability"]["count"], 5)
            self.assertEqual(store.baseline_state("patient-mode")["building_sessions"], 5)
            self.assertEqual(store.baseline_state("patient-mode")["reference_sessions"], 5)

    def test_reset_starts_a_fresh_calibration_without_deleting_history(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = FeatureStore(Path(temporary) / "vectors")
            day = date(2026, 10, 7).isoformat()
            features = {column: 1.0 for column in FEATURE_COLUMNS}

            for index in range(5):
                store.upsert({
                    "patient_id": "patient-reset",
                    "session_id": f"baseline-{index}",
                    "task_type": "monitoring",
                    "monitoring_mode": "baseline",
                    "timestamp_ms": 1791331200000 + index * 60_000,
                    "timestamp": f"2026-10-07T00:0{index}:00+00:00",
                    "local_date": day,
                    "duration_s": 60,
                    "quality_passed": True,
                    "baseline_status": "included",
                    "features": features,
                })
            store.finalize_baseline("patient-reset")
            self.assertEqual(store.baseline_state("patient-reset")["state"], "frozen")

            state = store.reset_baseline("patient-reset")

            self.assertEqual(state["state"], "building")
            self.assertEqual(state["building_sessions"], 0)
            self.assertFalse(state["can_monitor"])
            self.assertEqual(len(store.page_sessions("patient-reset")), 5)

    def test_twenty_baseline_intervals_enable_the_isolation_forest(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = FeatureStore(Path(temporary) / "vectors")
            day = date(2026, 10, 7).isoformat()

            for index in range(20):
                features = {column: 1.0 for column in FEATURE_COLUMNS}
                features["tremor_probability"] = 0.01 + index * 0.001
                store.upsert({
                    "patient_id": "patient-model",
                    "session_id": f"baseline-{index}",
                    "task_type": "monitoring",
                    "monitoring_mode": "baseline",
                    "timestamp_ms": 1791331200000 + index * 60_000,
                    "timestamp": f"2026-10-07T00:{index:02d}:00+00:00",
                    "local_date": day,
                    "duration_s": 60,
                    "quality_passed": True,
                    "baseline_status": "included",
                    "features": features,
                })

            state = store.finalize_baseline("patient-model")

            self.assertEqual(state["model"], "robust_z+isolation_forest")
            self.assertIsNotNone(store.anomaly_model("patient-model"))


if __name__ == "__main__":
    unittest.main()
