from __future__ import annotations

from datetime import datetime, timezone
from typing import Literal
from uuid import uuid4

import numpy as np
import pandas as pd
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from .features import FEATURE_COLUMNS, summarize_session
from .feature_store import feature_store, symptom_labels

app = FastAPI(title="Parkinson's movement processing", version="1.0.0")
GRAVITY_M_S2 = 9.80665
MIN_SAMPLE_RATE_HZ = 50.0


class Sample(BaseModel):
    timestamp_ms: int
    x: float
    y: float
    z: float


class ProcessRequest(BaseModel):
    task_type: Literal["tremor", "gait", "monitoring"]
    watch_side: Literal["left", "right"] = "left"
    patient_id: str | None = None
    session_id: str | None = None
    start_time_ms: int | None = None
    timestamp_ms: int | None = None
    local_date: str | None = None
    accelerometer: list[Sample] | None = Field(default=None, min_length=2)
    gyroscope: list[Sample] = Field(min_length=2)


def _sensor_frame(samples: list[Sample], prefix: str) -> pd.DataFrame:
    frame = pd.DataFrame([sample.model_dump() for sample in samples])
    frame = frame.sort_values("timestamp_ms").drop_duplicates("timestamp_ms", keep="last")
    frame = frame.rename(columns={"x": f"{prefix}_x", "y": f"{prefix}_y", "z": f"{prefix}_z"})
    frame["time"] = (frame["timestamp_ms"] - frame["timestamp_ms"].iloc[0]) / 1000.0
    return frame[["timestamp_ms", "time", f"{prefix}_x", f"{prefix}_y", f"{prefix}_z"]]


def _sampling_rate(frame: pd.DataFrame) -> float:
    intervals = np.diff(frame["timestamp_ms"].to_numpy(dtype=float)) / 1000.0
    intervals = intervals[intervals > 0]
    return float(1.0 / np.median(intervals)) if len(intervals) else 0.0


def prepare_imu(request: ProcessRequest) -> tuple[pd.DataFrame, float]:
    gyro = _sensor_frame(request.gyroscope, "gyroscope")
    if request.task_type in {"gait", "monitoring"} and request.accelerometer is None:
        raise ValueError("The ParaDigMa gait pipeline requires accelerometer data.")
    accel = (
        _sensor_frame(request.accelerometer, "accelerometer")
        if request.accelerometer is not None
        else None
    )
    rate = min(_sampling_rate(accel), _sampling_rate(gyro)) if accel is not None else _sampling_rate(gyro)
    if rate < MIN_SAMPLE_RATE_HZ:
        raise ValueError(f"Sensor rate {rate:.1f} Hz is below ParaDigMa's 50 Hz requirement.")

    # Align separately clocked Flutter streams to nearest accelerometer sample.
    if accel is not None:
        aligned = pd.merge_asof(
            accel.sort_values("timestamp_ms"),
            gyro.drop(columns="time").sort_values("timestamp_ms"),
            on="timestamp_ms",
            direction="nearest",
            tolerance=max(20, int(500 / rate)),
        ).dropna()
    else:
        aligned = gyro.copy()
    if len(aligned) < 2:
        raise ValueError("Accelerometer and gyroscope streams could not be aligned.")

    # Android SensorManager reports accelerometer in m/s² and gyroscope in rad/s;
    # ParaDigMa's documented standard input units are g and degrees/second.
    for axis in "xyz":
        if accel is not None:
            aligned[f"accelerometer_{axis}"] /= GRAVITY_M_S2
        aligned[f"gyroscope_{axis}"] = np.rad2deg(aligned[f"gyroscope_{axis}"])
    aligned["time"] = (aligned["timestamp_ms"] - aligned["timestamp_ms"].iloc[0]) / 1000.0
    aligned = aligned.drop(columns="timestamp_ms").sort_values("time").reset_index(drop=True)
    if aligned["time"].duplicated().any() or not np.isfinite(aligned.select_dtypes(include=[np.number])).all().all():
        raise ValueError("Sensor timestamps or values are invalid.")
    return aligned, rate


def run_paradigma_pipeline(imu: pd.DataFrame, task_type: str, watch_side: str) -> dict:
    """Run ParaDigMa's documented pipeline stages and return their real outputs."""
    if task_type == "monitoring":
        tremor = run_paradigma_pipeline(imu, "tremor", watch_side)
        gait = run_paradigma_pipeline(imu, "gait", watch_side)
        return {**tremor, **gait}
    from importlib.resources import files

    from paradigma.classification import ClassifierPackage
    from paradigma.config import GaitConfig, IMUConfig, TremorConfig
    from paradigma.constants import DataColumns
    from paradigma.pipelines.gait_pipeline import (
        detect_gait,
        extract_arm_activity_features,
        extract_gait_features,
        filter_gait,
        quantify_arm_swing,
    )
    from paradigma.pipelines.tremor_pipeline import (
        detect_tremor,
        extract_tremor_features,
    )
    from paradigma.preprocessing import preprocess_imu_data
    from paradigma.util import merge_predictions_with_timestamps

    imu_config = IMUConfig()
    sensor = "gyroscope" if task_type == "tremor" else "both"
    prepared = preprocess_imu_data(imu, imu_config, sensor=sensor, watch_side=watch_side)
    assets = files("paradigma") / "assets"

    if task_type == "tremor":
        config = TremorConfig()
        config._set_sampling_frequency_detected(imu_config.sampling_frequency)
        tremor_features = extract_tremor_features(prepared, config)
        predictions = detect_tremor(
            tremor_features, config, assets / "tremor_detection_clf_package.pkl"
        )
        # ParaDigMa's tremor quantification excludes power from non-tremor
        # windows; mirror its documented quantification step before summary.
        predictions = predictions.copy()
        predictions.loc[
            predictions[DataColumns.PRED_TREMOR_CHECKED] == 0,
            DataColumns.TREMOR_POWER,
        ] = np.nan
        return {"tremor_predictions": predictions}

    gait_config = GaitConfig(step="gait")
    gait_config._set_sampling_frequency_detected(imu_config.sampling_frequency)
    gait = extract_gait_features(prepared, gait_config)
    gait_classifier = ClassifierPackage.load(assets / "gait_detection_clf_package.pkl")
    gait[DataColumns.PRED_GAIT_PROBA] = detect_gait(gait, gait_classifier)

    gait_samples = merge_predictions_with_timestamps(
        df_ts=prepared,
        df_predictions=gait,
        pred_proba_colname=DataColumns.PRED_GAIT_PROBA,
        window_length_s=gait_config.window_length_s,
        fs=gait_config.sampling_frequency,
    )
    gait_samples[DataColumns.PRED_GAIT] = (
        gait_samples[DataColumns.PRED_GAIT_PROBA] >= gait_classifier.threshold
    ).astype(int)
    gait_samples = gait_samples.loc[gait_samples[DataColumns.PRED_GAIT] == 1].reset_index(drop=True)
    if gait_samples.empty:
        return {
            "gait_predictions": gait,
            "arm_swing": pd.DataFrame(columns=["range_of_motion", "peak_velocity"]),
        }

    arm_config = GaitConfig(step="arm_activity")
    arm_config._set_sampling_frequency_detected(imu_config.sampling_frequency)
    arm = extract_arm_activity_features(gait_samples, arm_config)
    if arm.empty:
        return {
            "gait_predictions": gait,
            "arm_swing": pd.DataFrame(columns=["range_of_motion", "peak_velocity"]),
        }
    arm_classifier = ClassifierPackage.load(assets / "gait_filtering_clf_package.pkl")
    arm[DataColumns.PRED_NO_OTHER_ARM_ACTIVITY_PROBA] = filter_gait(arm, arm_classifier)
    arm_samples = merge_predictions_with_timestamps(
        df_ts=prepared,
        df_predictions=arm,
        pred_proba_colname=DataColumns.PRED_NO_OTHER_ARM_ACTIVITY_PROBA,
        window_length_s=arm_config.window_length_s,
        fs=arm_config.sampling_frequency,
    )
    arm_samples[DataColumns.PRED_NO_OTHER_ARM_ACTIVITY] = (
        arm_samples[DataColumns.PRED_NO_OTHER_ARM_ACTIVITY_PROBA] >= arm_classifier.threshold
    ).astype(int)
    arm_samples = arm_samples.loc[
        arm_samples[DataColumns.PRED_NO_OTHER_ARM_ACTIVITY] == 1
    ].reset_index(drop=True)
    try:
        arm_swing, _ = quantify_arm_swing(
            df=arm_samples,
            fs=arm_config.sampling_frequency,
            filtered=True,
            max_segment_gap_s=arm_config.max_segment_gap_s,
            min_segment_length_s=arm_config.min_segment_length_s,
        )
    except ValueError as error:
        if "All segments were removed" not in str(error):
            raise
        arm_swing = pd.DataFrame(columns=["range_of_motion", "peak_velocity"])
    return {"gait_predictions": gait, "arm_swing": arm_swing}


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/process-session")
def process_session(request: ProcessRequest) -> dict:
    try:
        imu, rate = prepare_imu(request)
        duration_s = float(imu["time"].iloc[-1] - imu["time"].iloc[0])
        if duration_s < 10:
            raise ValueError("A session must contain at least 10 seconds of aligned data.")
        results = run_paradigma_pipeline(imu, request.task_type, request.watch_side)
        features = summarize_session(results, request.task_type, imu)
        required = (
            ("tremor_probability", "gait_probability")
            if request.task_type == "monitoring"
            else ("tremor_probability",)
            if request.task_type == "tremor"
            else ("gait_probability",)
        )
        quality_passed = all(features[name] is not None for name in required)
        quality_message = (
            "ParaDigMa outputs passed the session checks."
            if quality_passed
            else f"ParaDigMa returned no required outputs: {required}."
        )
        session_id = request.session_id or str(uuid4())
        timestamp_ms = request.timestamp_ms or int(datetime.now(timezone.utc).timestamp() * 1000)
        timestamp = datetime.fromtimestamp(timestamp_ms / 1000, tz=timezone.utc).isoformat()
        local_date = request.local_date or timestamp[:10]
        history = feature_store.baseline(request.patient_id) if request.patient_id else {}
        labels = symptom_labels(features, history)
        baseline = None
        if request.patient_id:
            feature_store.upsert({
                "patient_id": request.patient_id,
                "session_id": session_id,
                "task_type": request.task_type,
                "start_time_ms": request.start_time_ms or timestamp_ms - int(duration_s * 1000),
                "timestamp_ms": timestamp_ms,
                "timestamp": timestamp,
                "local_date": local_date,
                "duration_s": duration_s,
                "sample_rate_hz": rate,
                "quality_passed": quality_passed,
                "baseline_status": "included" if quality_passed else "excluded",
                "symptom_labels": labels,
                "features": {name: features[name] for name in FEATURE_COLUMNS},
            })
            # Each valid monitoring interval immediately updates the patient baseline.
            baseline = feature_store.baseline(request.patient_id)
        return {
            "session_id": session_id,
            "timestamp": timestamp,
            "features": {name: features[name] for name in FEATURE_COLUMNS},
            "quality_passed": quality_passed,
            "quality_message": quality_message,
            "symptom_labels": labels,
            "baseline": baseline,
            "quality": {
                "sample_rate_hz": rate,
                "duration_s": duration_s,
                "aligned_sample_count": len(imu),
            },
        }
    except (ImportError, ValueError) as error:
        raise HTTPException(status_code=422, detail=str(error)) from error
    except Exception as error:  # ParaDigMa/data errors are reported as a failed session.
        raise HTTPException(status_code=500, detail=f"Session processing failed: {error}") from error


@app.get("/patients/{patient_id}/daily-report")
def patient_daily_report(patient_id: str, date: str | None = None) -> dict:
    from datetime import date as date_type

    report_date = date_type.fromisoformat(date) if date else datetime.now().date()
    return feature_store.day_report(patient_id, report_date)


@app.get("/patients/{patient_id}/feature-vectors")
def patient_feature_vectors(
    patient_id: str,
    after_timestamp_ms: int = 0,
    limit: int = 500,
) -> list[dict]:
    return feature_store.page_sessions(
        patient_id,
        after_timestamp_ms=after_timestamp_ms,
        limit=limit,
    )
