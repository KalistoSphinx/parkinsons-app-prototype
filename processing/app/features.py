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
    "fall_detected",
    "fall_impact_g",
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


def detect_fall(imu: pd.DataFrame) -> dict[str, float]:
    """Robust clinical 3-stage fall detection with orientation shift analysis.

    Biomechanics:
    1. Sustained free-fall weightlessness: |a| < 0.55g sustained for at least 2 samples in the 0.8s prior to impact.
    2. High impact deceleration shock: |a| >= 3.0g and angular tumble velocity >= 2.0 rad/s (~115 deg/s).
    3. Posture/orientation shift: angle between pre-impact orientation and post-impact orientation >= 35 degrees.
    4. Post-impact immobility: quiescent motion (std(|a|) < 0.35g and mean(|omega|) < 1.2 rad/s).
    """
    if imu is None or len(imu) < 15:
        return {"fall_detected": 0.0, "fall_impact_g": 0.0}

    accel_cols = ["accelerometer_x", "accelerometer_y", "accelerometer_z"]
    gyro_cols = ["gyroscope_x", "gyroscope_y", "gyroscope_z"]
    if not all(col in imu.columns for col in accel_cols):
        return {"fall_detected": 0.0, "fall_impact_g": 0.0}

    has_gyro = all(col in imu.columns for col in gyro_cols)

    t = imu["time"].to_numpy(dtype=float)
    ax = imu["accelerometer_x"].to_numpy(dtype=float)
    ay = imu["accelerometer_y"].to_numpy(dtype=float)
    az = imu["accelerometer_z"].to_numpy(dtype=float)
    a_mag = np.sqrt(ax**2 + ay**2 + az**2)

    if has_gyro:
        gx = imu["gyroscope_x"].to_numpy(dtype=float)
        gy = imu["gyroscope_y"].to_numpy(dtype=float)
        gz = imu["gyroscope_z"].to_numpy(dtype=float)
        g_mag_rad = np.deg2rad(np.sqrt(gx**2 + gy**2 + gz**2))
    else:
        g_mag_rad = np.zeros_like(a_mag)

    # 1. Candidate impact peaks: |a| >= 3.0g
    impact_indices = np.where(a_mag >= 3.0)[0]
    if len(impact_indices) == 0:
        return {"fall_detected": 0.0, "fall_impact_g": 0.0}

    peak_indices: list[int] = []
    current_peak = impact_indices[0]
    for idx in impact_indices[1:]:
        if t[idx] - t[current_peak] < 0.5:
            if a_mag[idx] > a_mag[current_peak]:
                current_peak = idx
        else:
            peak_indices.append(current_peak)
            current_peak = idx
    peak_indices.append(current_peak)

    max_impact = 0.0
    for peak_idx in peak_indices:
        t_peak = t[peak_idx]
        impact_val = float(a_mag[peak_idx])

        # Stage 1: Sustained free fall dip in [t_peak - 0.8s, t_peak]
        pre_mask = (t >= t_peak - 0.8) & (t < t_peak)
        if not np.any(pre_mask):
            continue
        pre_a = a_mag[pre_mask]
        if np.sum(pre_a < 0.55) < 2:
            continue

        # Stage 2: Tumble angular velocity around impact [t_peak - 0.5s, t_peak + 0.5s]
        if has_gyro:
            tumble_mask = (t >= t_peak - 0.5) & (t <= t_peak + 0.5)
            max_gyro = np.max(g_mag_rad[tumble_mask]) if np.any(tumble_mask) else 0.0
            if max_gyro < 2.0:
                continue

        # Stage 3: Post-impact immobility in [t_peak + 0.5s, t_peak + 2.5s]
        post_mask = (t >= t_peak + 0.5) & (t <= t_peak + 2.5)
        if not np.any(post_mask):
            post_mask = (t >= t_peak + 0.2)
        if np.sum(post_mask) >= 5:
            post_accel_std = np.std(a_mag[post_mask])
            post_gyro_mean = np.mean(g_mag_rad[post_mask]) if has_gyro else 0.0
            if post_accel_std > 0.35 or post_gyro_mean > 1.2:
                continue

        # Stage 4: Orientation shift before vs after impact
        pre_orient_mask = (t >= t_peak - 1.5) & (t <= t_peak - 0.3)
        post_orient_mask = (t >= t_peak + 0.5) & (t <= t_peak + 2.0)
        if np.sum(pre_orient_mask) >= 5 and np.sum(post_orient_mask) >= 5:
            v_pre = np.array([np.mean(ax[pre_orient_mask]), np.mean(ay[pre_orient_mask]), np.mean(az[pre_orient_mask])])
            v_post = np.array([np.mean(ax[post_orient_mask]), np.mean(ay[post_orient_mask]), np.mean(az[post_orient_mask])])
            norm_pre = np.linalg.norm(v_pre)
            norm_post = np.linalg.norm(v_post)
            if norm_pre > 0.1 and norm_post > 0.1:
                cos_theta = np.clip(np.dot(v_pre, v_post) / (norm_pre * norm_post), -1.0, 1.0)
                # If cos_theta > 0.82 (angle < 35 degrees), orientation did not change (e.g. setting phone on table)
                if cos_theta > 0.82:
                    continue

        if impact_val > max_impact:
            max_impact = impact_val

    if max_impact > 0.0:
        return {"fall_detected": 1.0, "fall_impact_g": round(max_impact, 2)}
    return {"fall_detected": 0.0, "fall_impact_g": 0.0}


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
    features.update(detect_fall(prepared_imu))
    return {name: features.get(name) for name in FEATURE_COLUMNS}
