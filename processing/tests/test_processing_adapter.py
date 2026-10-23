import unittest

import numpy as np
import pandas as pd

from processing.app.features import FEATURE_COLUMNS, detect_fall, extract_gait_features, extract_tremor_features
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

    def test_detect_fall_distinguishes_fall_from_tremor_and_rest(self):
        times = np.linspace(0, 10, 500)
        # Normal rest
        rest_frame = pd.DataFrame({
            "time": times,
            "accelerometer_x": np.zeros_like(times),
            "accelerometer_y": np.zeros_like(times),
            "accelerometer_z": np.ones_like(times),
            "gyroscope_x": np.zeros_like(times),
            "gyroscope_y": np.zeros_like(times),
            "gyroscope_z": np.zeros_like(times),
        })
        self.assertEqual(detect_fall(rest_frame)["fall_detected"], 0.0)

        # Violent hand shaking / tremor (continuous oscillation without free fall or post-immobility)
        shake_frame = pd.DataFrame({
            "time": times,
            "accelerometer_x": 1.5 * np.sin(2 * np.pi * 5 * times),
            "accelerometer_y": 1.5 * np.cos(2 * np.pi * 5 * times),
            "accelerometer_z": 1.0 + 1.5 * np.sin(2 * np.pi * 5 * times),
            "gyroscope_x": 200.0 * np.sin(2 * np.pi * 5 * times),
            "gyroscope_y": 200.0 * np.cos(2 * np.pi * 5 * times),
            "gyroscope_z": 200.0 * np.sin(2 * np.pi * 5 * times),
        })
        self.assertEqual(detect_fall(shake_frame)["fall_detected"], 0.0)

        # 3-Stage Sudden Fall
        ax = np.zeros(len(times))
        ay = np.zeros(len(times))
        az = np.ones(len(times))
        gx = np.zeros(len(times))
        gy = np.zeros(len(times))
        gz = np.zeros(len(times))
        # Free fall dip at t=3.0 to 3.3s
        ff_idx = (times >= 3.0) & (times <= 3.3)
        az[ff_idx] = 0.2
        # Impact at t=3.35s
        impact_idx = np.argmin(np.abs(times - 3.35))
        az[impact_idx] = 4.2
        gx[impact_idx] = 180.0
        # Post-fall immobility on ground
        post_idx = times > 3.4
        az[post_idx] = 0.05
        ay[post_idx] = 0.98

        fall_frame = pd.DataFrame({
            "time": times,
            "accelerometer_x": ax,
            "accelerometer_y": ay,
            "accelerometer_z": az,
            "gyroscope_x": gx,
            "gyroscope_y": gy,
            "gyroscope_z": gz,
        })
        res = detect_fall(fall_frame)
        self.assertEqual(res["fall_detected"], 1.0)
        self.assertAlmostEqual(res["fall_impact_g"], 4.2, places=1)

    def test_run_paradigma_pipeline_handles_short_gait_segments_without_error(self):
        from processing.app.main import run_paradigma_pipeline
        times = np.linspace(0, 12, 600)
        df = pd.DataFrame({
            "time": times,
            "accelerometer_x": np.zeros(600),
            "accelerometer_y": np.ones(600),
            "accelerometer_z": np.zeros(600),
            "gyroscope_x": np.zeros(600),
            "gyroscope_y": np.zeros(600),
            "gyroscope_z": np.zeros(600),
        })
        results = run_paradigma_pipeline(df, "monitoring", "left")
        self.assertIn("tremor_predictions", results)
        self.assertIn("gait_predictions", results)
        self.assertIn("arm_swing", results)
        self.assertTrue(isinstance(results["arm_swing"], pd.DataFrame))


if __name__ == "__main__":
    unittest.main()
