import unittest

import numpy as np
import pandas as pd

from processing.app.features import FEATURE_COLUMNS, extract_gait_features, extract_tremor_features
from processing.app.main import ProcessRequest, Sample, prepare_imu


class ProcessingAdapterTests(unittest.TestCase):
    def test_android_sensor_units_are_converted_for_paradigma(self):
        timestamps = np.arange(0, 20_000, 20)
        request = ProcessRequest(
            task_type="gait",
            accelerometer=[Sample(timestamp_ms=int(t), x=0, y=0, z=9.80665) for t in timestamps],
            gyroscope=[Sample(timestamp_ms=int(t), x=0, y=0, z=np.pi) for t in timestamps],
        )

        frame, rate = prepare_imu(request)

        self.assertAlmostEqual(rate, 50.0)
        self.assertTrue(np.allclose(frame["accelerometer_z"], 1.0))
        self.assertTrue(np.allclose(frame["gyroscope_z"], 180.0))
        self.assertEqual(list(frame.columns)[0], "time")

    def test_tremor_request_uses_only_gyroscope_data(self):
        timestamps = np.arange(0, 20_000, 20)
        request = ProcessRequest(
            task_type="tremor",
            gyroscope=[Sample(timestamp_ms=int(t), x=0, y=0, z=0.1) for t in timestamps],
        )

        frame, rate = prepare_imu(request)

        self.assertAlmostEqual(rate, 50.0)
        self.assertNotIn("accelerometer_x", frame)
        self.assertTrue(np.allclose(frame["gyroscope_z"], np.rad2deg(0.1)))

    def test_tremor_adapter_maps_only_real_quantification_outputs(self):
        result = extract_tremor_features({
            "tremor_predictions": pd.DataFrame({
                "pred_tremor_proba": [0.2, 0.8],
                "tremor_power": [1.0, 3.0],
                "pred_tremor_checked": [1, 1],
                "pred_arm_at_rest": [1, 0],
            })
        })

        self.assertEqual(list(result), list(FEATURE_COLUMNS))
        self.assertAlmostEqual(result["tremor_probability"], 0.5)
        self.assertAlmostEqual(result["tremor_power"], 2.0)
        self.assertAlmostEqual(result["tremor_time"], 1.0)
        self.assertIsNone(result["gait_probability"])

    def test_gait_adapter_maps_real_prediction_and_arm_swing_columns(self):
        result = extract_gait_features({
            "gait_predictions": pd.DataFrame({"pred_gait_proba": [0.4, 0.8]}),
            "arm_swing": pd.DataFrame({
                "range_of_motion": [20.0, 40.0],
                "peak_velocity": [100.0, 120.0],
            }),
        })

        self.assertAlmostEqual(result["gait_probability"], 0.6)
        self.assertAlmostEqual(result["arm_swing_rom"], 30.0)
        self.assertAlmostEqual(result["arm_swing_peak_velocity"], 110.0)
        self.assertIsNone(result["tremor_probability"])


if __name__ == "__main__":
    unittest.main()
