import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import pandas as pd
from fastapi import HTTPException

from processing.app import main
from processing.app.alerts import AlertStore
from processing.app.feature_store import FeatureStore
from processing.app.main import ProcessRequest, Sample


class BaselineAndAnomalyApiTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.store = FeatureStore(Path(self.temporary.name) / "vectors")
        self.alerts = AlertStore(self.store)
        self.store_patch = patch.object(main, "feature_store", self.store)
        self.alert_patch = patch.object(main, "alert_store", self.alerts)
        self.pipeline_patch = patch.object(main, "run_paradigma_pipeline")
        self.store_patch.start()
        self.alert_patch.start()
        self.pipeline = self.pipeline_patch.start()
        self.values = {"tremor": 0.02, "gait": 0.01, "rom": None}
        self.pipeline.side_effect = self._fake_pipeline

    def tearDown(self):
        self.pipeline_patch.stop()
        self.alert_patch.stop()
        self.store_patch.stop()
        self.temporary.cleanup()

    def _fake_pipeline(self, imu, task_type, watch_side):
        gait_frame = pd.DataFrame({"pred_gait_proba": [self.values["gait"]]})
        arm_swing = (
            pd.DataFrame(
                {
                    "range_of_motion": [self.values["rom"]],
                    "peak_velocity": [180.0],
                }
            )
            if self.values["rom"] is not None
            else pd.DataFrame(columns=["range_of_motion", "peak_velocity"])
        )
        return {
            "tremor_predictions": pd.DataFrame(
                {
                    "pred_tremor_proba": [self.values["tremor"]],
                    "tremor_power": [1.0],
                    "pred_tremor_checked": [0.0],
                    "pred_arm_at_rest": [1],
                }
            ),
            "gait_predictions": gait_frame,
            "arm_swing": arm_swing,
        }

    def _request(self, mode, session_id, timestamp_ms):
        accel = []
        gyro = []
        for index in range(501):
            stamp = timestamp_ms + index * 20
            accel.append(
                Sample(
                    timestamp_ms=stamp,
                    x=0.0,
                    y=0.0,
                    z=9.80665,
                )
            )
            gyro.append(Sample(timestamp_ms=stamp, x=0.0, y=0.0, z=0.01))
        return ProcessRequest(
            task_type="monitoring",
            monitoring_mode=mode,
            patient_id="api-patient",
            session_id=session_id,
            timestamp_ms=timestamp_ms + 10_000,
            local_date="2026-10-22",
            accelerometer=accel,
            gyroscope=gyro,
        )

    def test_baseline_then_finalize_then_anomaly_alert(self):
        for index in range(5):
            response = main.process_session(
                self._request("baseline", f"baseline-{index}", 1_000_000 + index * 60_000)
            )
            self.assertEqual(response["monitoring_mode"], "baseline")
            self.assertIsNone(response["anomaly"])
            self.assertIsNone(response["alert"])

        before = main.patient_baseline("api-patient")
        self.assertTrue(before["can_finalize"])
        self.assertEqual(before["state"], "building")

        frozen = main.finalize_patient_baseline("api-patient")
        self.assertEqual(frozen["state"], "frozen")
        self.assertEqual(frozen["reference_sessions"], 5)

        self.values["tremor"] = 0.8
        anomaly_response = main.process_session(
            self._request("anomaly", "anomaly-1", 1_400_000)
        )

        self.assertEqual(anomaly_response["monitoring_mode"], "anomaly")
        self.assertEqual(anomaly_response["anomaly"]["severity"], "critical")
        self.assertIsNotNone(anomaly_response["alert"])
        self.assertEqual(anomaly_response["alert"]["symptom"], "tremor")

        alerts = main.patient_alerts("api-patient")
        self.assertEqual(len(alerts), 1)
        alert_id = alerts[0]["alert_id"]
        acknowledged = main.acknowledge_patient_alert("api-patient", alert_id)
        self.assertEqual(acknowledged["status"], "acknowledged")

        after = main.patient_baseline("api-patient")
        self.assertEqual(after["reference_sessions"], 5)
        self.assertEqual(after["state"], "frozen")

    def test_post_freeze_baseline_upload_never_modifies_personal_baseline_and_triggers_alert(self):
        # 1. Calibrate 5 baseline sessions and freeze
        for index in range(5):
            main.process_session(
                self._request("baseline", f"baseline-{index}", 1_000_000 + index * 60_000)
            )
        frozen_state = main.finalize_patient_baseline("api-patient")
        self.assertEqual(frozen_state["state"], "frozen")
        reference_before = dict(frozen_state["baseline"])

        # 2. Simulate continuous monitoring or manual test sending severe tremor
        # Even if the request passes monitoring_mode="baseline", the system must
        # enforce anomaly monitoring, evaluate alerts against the frozen baseline,
        # and NEVER mutate the personal baseline.
        self.values["tremor"] = 0.95
        response = main.process_session(
            self._request("baseline", "post-freeze-shake", 1_400_000)
        )

        self.assertEqual(response["monitoring_mode"], "anomaly")
        self.assertEqual(response["anomaly"]["severity"], "critical")
        self.assertIsNotNone(response["alert"])
        self.assertEqual(response["alert"]["symptom"], "tremor")

        # 3. Assert baseline is 100% bit-identical and unmodified
        after_state = main.patient_baseline("api-patient")
        self.assertEqual(after_state["state"], "frozen")
        self.assertEqual(after_state["reference_sessions"], 5)
        self.assertEqual(after_state["building_sessions"], 5)
        self.assertEqual(after_state["baseline"], reference_before)

    def test_anomaly_mode_requires_a_ready_baseline(self):
        with self.assertRaises(HTTPException) as context:
            main.process_session(
                self._request("anomaly", "too-early", 2_000_000)
            )

        self.assertEqual(context.exception.status_code, 422)
        self.assertIn("Personal baseline is not ready", context.exception.detail)

    def test_ppp_loader_imports_in_package_layout(self):
        self.assertTrue(callable(main._ppp_fetch_function()))

    def test_ppp_loader_imports_in_app_dir_layout(self):
        processing_dir = Path(__file__).resolve().parents[1]
        code = (
            "import sys; "
            f"sys.path.insert(0, {str(processing_dir)!r}); "
            "import app.main; "
            "assert callable(app.main._ppp_fetch_function()); "
            "print('ok')"
        )
        result = subprocess.run(
            [sys.executable, "-c", code],
            cwd=processing_dir,
            capture_output=True,
            text=True,
            timeout=120,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ok", result.stdout)


if __name__ == "__main__":
    unittest.main()
