import unittest

from processing.app.anomaly import (
    detect_context,
    evaluate,
    fit_isolation_model,
    robust_drivers,
)


BASE = {
    "tremor_probability": 0.02,
    "tremor_power": 0.5,
    "tremor_time": 0.0,
    "gait_probability": 0.01,
    "arm_swing_rom": 40.0,
    "arm_swing_peak_velocity": 180.0,
    "accel_rms_m_s2": 1.0,
    "gyro_rms_rad_s": 0.5,
}


def baseline_stats(value: float, spread: float = 0.01, count: int = 10):
    return {
        "count": count,
        "mean": value,
        "median": value,
        "mad": spread,
        "std": spread,
    }


class AnomalyTests(unittest.TestCase):
    def test_context_separates_rest_from_walking(self):
        resting = {name: None for name in BASE}
        resting["gait_probability"] = 0.01
        self.assertEqual(detect_context(resting, 0.2099), "rest")

        walking = {name: None for name in BASE}
        walking["gait_probability"] = 0.9
        self.assertEqual(detect_context(walking, 0.2099), "walking")

        arm_swing = {name: None for name in BASE}
        arm_swing["arm_swing_rom"] = 30.0
        self.assertEqual(detect_context(arm_swing, 0.2099), "walking")

    def test_high_tremor_is_a_rest_driver_but_not_a_walking_driver(self):
        baseline = {"tremor_probability": baseline_stats(0.02)}
        high = {**BASE, "tremor_probability": 0.8}

        rest_drivers = robust_drivers(high, baseline, "rest")
        walking_drivers = robust_drivers(high, baseline, "walking")

        self.assertEqual(rest_drivers[0]["feature"], "tremor_probability")
        self.assertEqual(rest_drivers[0]["direction"], "high")
        self.assertTrue(rest_drivers[0]["z"] > 3.0)
        self.assertEqual(walking_drivers, [])

    def test_low_arm_swing_is_only_scored_while_walking(self):
        baseline = {"arm_swing_rom": baseline_stats(40.0, spread=2.0)}
        low = {**BASE, "arm_swing_rom": 5.0}

        self.assertEqual(robust_drivers(low, baseline, "rest"), [])
        drivers = robust_drivers(low, baseline, "walking")
        self.assertEqual(drivers[0]["feature"], "arm_swing_rom")
        self.assertEqual(drivers[0]["direction"], "low")
        self.assertGreater(drivers[0]["z"], 2.0)

    def test_observed_range_prevents_false_tremor_driver(self):
        baseline = {
            "tremor_probability": {
                **baseline_stats(0.000168, spread=2.79e-05, count=7),
                "min": 0.00014,
                "max": 0.0909,
            }
        }
        observed = {**BASE, "tremor_probability": 0.0599}

        self.assertEqual(robust_drivers(observed, baseline, "rest"), [])
        result = evaluate(observed, baseline, {}, "rest")
        self.assertEqual(result["severity"], "normal")
        self.assertEqual(result["symptoms"], {})

        new_high = {**BASE, "tremor_probability": 0.20}
        drivers = robust_drivers(new_high, baseline, "rest")
        self.assertEqual(drivers[0]["feature"], "tremor_probability")
        self.assertGreater(drivers[0]["z"], 3.0)

    def test_missing_features_do_not_break_scoring(self):
        baseline = {"tremor_probability": baseline_stats(0.02)}
        features = {name: None for name in BASE}
        features["tremor_probability"] = 0.8

        result = evaluate(features, baseline, {}, "rest")

        self.assertEqual(result["severity"], "critical")
        self.assertEqual(result["drivers"][0]["feature"], "tremor_probability")

    def test_absolute_severe_label_still_alerts_with_a_flat_baseline(self):
        baseline = {"tremor_probability": baseline_stats(0.8, spread=0.01)}
        features = {**BASE, "tremor_probability": 0.82}

        result = evaluate(
            features,
            baseline,
            {"tremor": "severe", "gait": "insufficient data", "bradykinesia_proxy": "normal"},
            "rest",
        )

        self.assertEqual(result["symptoms"]["tremor"], "critical")

    def test_isolation_forest_requires_twenty_rows_and_scores(self):
        rows = [{**BASE, "tremor_probability": 0.02 + index * 0.001} for index in range(25)]

        bundle = fit_isolation_model(rows)

        self.assertIsNotNone(bundle)
        self.assertEqual(bundle["count"], 25)
        result = evaluate(
            {**BASE, "tremor_probability": 0.9},
            {"tremor_probability": baseline_stats(0.02)},
            {},
            "rest",
            bundle,
        )
        self.assertIn(result["model"], {"robust_z", "robust_z+isolation_forest"})

    def test_isolation_forest_falls_back_with_small_baseline(self):
        self.assertIsNone(fit_isolation_model([BASE] * 5))

    def test_fall_detection_evaluation(self):
        fall_features = {
            **BASE,
            "fall_detected": 1.0,
            "fall_impact_g": 3.8,
        }
        res = evaluate(
            fall_features,
            {},
            {"tremor": "normal", "gait": "normal", "fall": "critical"},
            "rest",
        )
        self.assertEqual(res["severity"], "critical")
        self.assertEqual(res["symptoms"].get("fall"), "critical")
        self.assertEqual(res["score"], 1.0)
        self.assertEqual(res["drivers"][0]["feature"], "fall_impact_g")
        self.assertEqual(res["drivers"][0]["symptom"], "fall")
        self.assertGreaterEqual(res["drivers"][0]["value"], 3.8)


if __name__ == "__main__":
    unittest.main()
