"""Stable adapter between this application and ParaDigMa's changing API."""

from __future__ import annotations

from typing import Any

import numpy as np
import pandas as pd

FEATURE_COLUMNS = (
    "tremor_probability",
    "tremor_power",
    "tremor_time",
    "gait_probability",
    "arm_swing_rom",
    "arm_swing_peak_velocity",
    "accel_rms_m_s2",
    "gyro_rms_rad_s",
)
FEATURE_COLUMNS_BY_TASK = {
    "tremor": (
        "tremor_probability",
        "tremor_power",
        "tremor_time",
        "gyro_rms_rad_s",
    ),
    "gait": (
        "gait_probability",
        "arm_swing_rom",
        "arm_swing_peak_velocity",
        "accel_rms_m_s2",
        "gyro_rms_rad_s",
    ),
    "monitoring": FEATURE_COLUMNS,
}

def _frames(value: Any) -> list[pd.DataFrame]:
    if isinstance(value, pd.DataFrame):
        return [value]
    if isinstance(value, dict):
        return [frame for item in value.values() for frame in _frames(item)]
    if isinstance(value, (list, tuple)):
        return [frame for item in value for frame in _frames(item)]
    return []


def _summarize(results: dict[str, Any], task_type: str) -> dict[str, float | None]:
    features: dict[str, float | None] = {name: None for name in FEATURE_COLUMNS}
    if task_type == "monitoring":
        features = _summarize(results, "tremor")
        gait_features = _summarize(results, "gait")
        for name in FEATURE_COLUMNS:
            if gait_features[name] is not None:
                features[name] = gait_features[name]
        return features

    columns_by_source = (
        {
            "gait_probability": ("gait_predictions", "pred_gait_proba"),
            "arm_swing_rom": ("arm_swing", "range_of_motion"),
            "arm_swing_peak_velocity": ("arm_swing", "peak_velocity"),
        }
        if task_type == "gait"
        else {
            "tremor_probability": ("tremor_predictions", "pred_tremor_proba"),
            "tremor_power": ("tremor_predictions", "tremor_power"),
            "tremor_time": ("tremor_predictions", "pred_tremor_checked"),
        }
    )
    for feature_name, (source_name, column_name) in columns_by_source.items():
        values: list[float] = []
        for frame in _frames(results.get(source_name)):
            if feature_name == "tremor_time":
                if "pred_arm_at_rest" not in frame or column_name not in frame:
                    continue
                at_rest = frame["pred_arm_at_rest"] == 1
                rest_tremor = pd.to_numeric(frame.loc[at_rest, column_name], errors="coerce")
                rest_tremor = rest_tremor.replace([np.inf, -np.inf], np.nan).dropna()
                if len(rest_tremor):
                    values.append(float(rest_tremor.mean()))
                continue
            if column_name in frame:
                values.extend(
                    pd.to_numeric(frame[column_name], errors="coerce")
                    .replace([np.inf, -np.inf], np.nan)
                    .dropna()
                    .astype(float)
                    .tolist()
                )
        if values:
            # Tremor detection outputs a probability and a checked 0/1 label;
            # median power and arm-swing measures represent typical session values.
            features[feature_name] = float(np.mean(values)) if feature_name in {
                "tremor_probability", "tremor_time", "gait_probability"
            } else float(np.median(values))
    return features


def _supplemental_rms(frame: pd.DataFrame) -> dict[str, float | None]:
    result: dict[str, float | None] = {"accel_rms_m_s2": None, "gyro_rms_rad_s": None}
    for columns, feature, scale in (
        (("accelerometer_x", "accelerometer_y", "accelerometer_z"), "accel_rms_m_s2", 9.80665),
        (("gyroscope_x", "gyroscope_y", "gyroscope_z"), "gyro_rms_rad_s", np.pi / 180.0),
    ):
        if all(name in frame for name in columns):
            values = frame[list(columns)].to_numpy(dtype=float) * scale
            # Remove per-axis DC components (gravity and sensor bias) so this
            # supplemental value reflects dynamic movement rather than posture.
            values -= values.mean(axis=0, keepdims=True)
            magnitude = np.sqrt(np.square(values).sum(axis=1))
            result[feature] = float(np.sqrt(np.mean(np.square(magnitude))))
    return result


def extract_tremor_features(results: dict[str, Any]) -> dict[str, float | None]:
    """Map actual ParaDigMa tremor quantifications to the app's stable schema."""
    return _summarize(results, "tremor")


def extract_gait_features(results: dict[str, Any]) -> dict[str, float | None]:
    """Map ParaDigMa gait probabilities and arm-swing outputs to stable fields."""
    return _summarize(results, "gait")


def summarize_session(
    results: dict[str, Any], task_type: str, prepared_imu: pd.DataFrame
) -> dict[str, float | None]:
    if task_type == "monitoring":
        features = _summarize(results, "monitoring")
    elif task_type == "tremor":
        features = extract_tremor_features(results)
    else:
        features = extract_gait_features(results)
    features.update(_supplemental_rms(prepared_imu))
    return {name: features.get(name) for name in FEATURE_COLUMNS}
