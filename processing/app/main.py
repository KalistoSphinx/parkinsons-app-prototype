from __future__ import annotations

from datetime import datetime, timezone
from typing import Literal
from uuid import uuid4

import numpy as np
import pandas as pd
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from .alerts import AlertStore
from .anomaly import detect_context, evaluate as evaluate_anomaly
from .features import FEATURE_COLUMNS, summarize_session
from .feature_store import (
    PARADIGMA_GAIT_THRESHOLD,
    feature_store,
    symptom_labels,
)
from .notes import note_store
from .pairing import pairing_store

app = FastAPI(title="Parkinson's movement processing", version="1.0.0")
alert_store = AlertStore(feature_store)
GRAVITY_M_S2 = 9.80665
MIN_SAMPLE_RATE_HZ = 50.0


class Sample(BaseModel):
    timestamp_ms: int
    x: float
    y: float
    z: float


class ProcessRequest(BaseModel):
    task_type: Literal["tremor", "gait", "monitoring"]
    monitoring_mode: Literal["baseline", "anomaly"] = "baseline"
    watch_side: Literal["left", "right"] = "left"
    patient_id: str | None = None
    session_id: str | None = None
    start_time_ms: int | None = None
    timestamp_ms: int | None = None
    local_date: str | None = None
    accelerometer: list[Sample] | None = Field(default=None, min_length=2)
    gyroscope: list[Sample] = Field(min_length=2)


class PairingGenerateRequest(BaseModel):
    patient_name: str = ""
    ttl_seconds: int = 900


class PairingClaimRequest(BaseModel):
    code: str
    caretaker_name: str = ""


class CaretakerProfileUpdateRequest(BaseModel):
    caretaker_name: str


class AlertDismissRequest(BaseModel):
    reason: str = "false_positive"


class NoteCreateRequest(BaseModel):
    date: str
    text: str
    tags: list[str] = Field(default_factory=list)
    author: str = "Caretaker"


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
    try:
        arm = extract_arm_activity_features(gait_samples, arm_config)
    except (ValueError, Exception):
        return {
            "gait_predictions": gait,
            "arm_swing": pd.DataFrame(columns=["range_of_motion", "peak_velocity"]),
        }
    if arm.empty:
        return {
            "gait_predictions": gait,
            "arm_swing": pd.DataFrame(columns=["range_of_motion", "peak_velocity"]),
        }
    arm_classifier = ClassifierPackage.load(assets / "gait_filtering_clf_package.pkl")
    try:
        arm[DataColumns.PRED_NO_OTHER_ARM_ACTIVITY_PROBA] = filter_gait(arm, arm_classifier)
    except (ValueError, Exception):
        return {
            "gait_predictions": gait,
            "arm_swing": pd.DataFrame(columns=["range_of_motion", "peak_velocity"]),
        }
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
    if arm_samples.empty:
        return {
            "gait_predictions": gait,
            "arm_swing": pd.DataFrame(columns=["range_of_motion", "peak_velocity"]),
        }
    try:
        arm_swing, _ = quantify_arm_swing(
            df=arm_samples,
            fs=arm_config.sampling_frequency,
            filtered=True,
            max_segment_gap_s=arm_config.max_segment_gap_s,
            min_segment_length_s=arm_config.min_segment_length_s,
        )
    except (ValueError, Exception):
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
        if duration_s < 8:
            raise ValueError("A session must contain at least 8 seconds of aligned data.")
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
        baseline_state = None
        anomaly = None
        created_alerts: list[dict] = []
        monitoring_mode = request.monitoring_mode

        state = feature_store.baseline_state(request.patient_id) if request.patient_id else {}
        is_frozen = state.get("state") == "frozen"
        # If the patient's baseline is already frozen, this session MUST be evaluated
        # as an anomaly-monitoring interval. The frozen personal baseline is strictly immutable.
        if is_frozen:
            monitoring_mode = "anomaly"

        if request.patient_id and monitoring_mode == "anomaly":
            if quality_passed and not state.get("ready"):
                raise ValueError(
                    "Personal baseline is not ready. Collect at least "
                    f"{state.get('min_sessions', 5)} quality baseline intervals first."
                )
            if quality_passed and not is_frozen:
                state = feature_store.finalize_baseline(request.patient_id)

            reference = state.get("baseline", {})
            if quality_passed:
                labels = symptom_labels(features, reference)
                anomaly = evaluate_anomaly(
                    features,
                    reference,
                    labels,
                    detect_context(features, PARADIGMA_GAIT_THRESHOLD),
                    feature_store.anomaly_model(request.patient_id),
                )
                recent = feature_store.recent_sessions(request.patient_id, limit=3)
                created_alerts = alert_store.evaluate(
                    patient_id=request.patient_id,
                    session_id=session_id,
                    timestamp_ms=timestamp_ms,
                    created_at=timestamp,
                    anomaly=anomaly,
                    recent_sessions=recent,
                )
            else:
                labels = {
                    name: "insufficient data"
                    for name in ("tremor", "gait", "bradykinesia_proxy")
                }

            feature_store.upsert({
                "patient_id": request.patient_id,
                "session_id": session_id,
                "task_type": request.task_type,
                "monitoring_mode": "anomaly",
                "start_time_ms": request.start_time_ms or timestamp_ms - int(duration_s * 1000),
                "timestamp_ms": timestamp_ms,
                "timestamp": timestamp,
                "local_date": local_date,
                "duration_s": duration_s,
                "sample_rate_hz": rate,
                "quality_passed": quality_passed,
                "baseline_status": "excluded",
                "symptom_labels": labels,
                "anomaly": anomaly,
                "alert_ids": [alert["alert_id"] for alert in created_alerts],
                "features": {name: features[name] for name in FEATURE_COLUMNS},
            })
            baseline = reference
            baseline_state = feature_store.baseline_state(request.patient_id)
        elif request.patient_id:
            labels = symptom_labels(features, history)
            feature_store.upsert({
                "patient_id": request.patient_id,
                "session_id": session_id,
                "task_type": request.task_type,
                "monitoring_mode": "baseline",
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
            baseline = feature_store.baseline(request.patient_id)
            baseline_state = feature_store.baseline_state(request.patient_id)

        return {
            "session_id": session_id,
            "timestamp": timestamp,
            "monitoring_mode": monitoring_mode,
            "features": {name: features[name] for name in FEATURE_COLUMNS},
            "quality_passed": quality_passed,
            "quality_message": quality_message,
            "symptom_labels": labels,
            "baseline": baseline,
            "baseline_state": baseline_state,
            "anomaly": anomaly,
            "alert": created_alerts[0] if created_alerts else None,
            "alerts": created_alerts,
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
    rep_date_str = report_date.isoformat()
    report = feature_store.day_report(patient_id, report_date)

    all_alerts = alert_store.list(patient_id, limit=200)
    day_alerts = []
    for a in all_alerts:
        created_at = a.get("created_at", "")
        ts_ms = a.get("timestamp_ms", 0)
        if created_at.startswith(rep_date_str):
            day_alerts.append(a)
        elif ts_ms:
            a_date = datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc).strftime("%Y-%m-%d")
            if a_date == rep_date_str:
                day_alerts.append(a)

    report["alerts"] = day_alerts
    active_alerts = [
        alert
        for alert in day_alerts
        if alert.get("status") in {"new", "acknowledged"}
    ]
    report["active_alerts"] = active_alerts
    report["notes"] = note_store.list_notes(patient_id, date=rep_date_str)

    has_new_fall = any(
        (a.get("symptom") == "fall" or "fall" in a.get("title", "").lower())
        and a.get("status") == "new"
        for a in active_alerts
    )
    has_ack_fall = any(
        (a.get("symptom") == "fall" or "fall" in a.get("title", "").lower())
        and a.get("status") == "acknowledged"
        for a in active_alerts
    )
    if "symptom_labels" in report:
        if has_new_fall:
            report["symptom_labels"]["fall"] = "critical"
        elif has_ack_fall:
            report["symptom_labels"]["fall"] = "acknowledged"
        else:
            report["symptom_labels"]["fall"] = "normal"

    return report


@app.get("/patients/{patient_id}/history-dates")
def patient_history_dates(patient_id: str) -> dict:
    dates = feature_store.available_dates(patient_id)
    return {
        "patient_id": patient_id,
        "dates": dates,
        "total_dates": len(dates),
    }


@app.get("/patients/{patient_id}/summary")
def patient_period_summary(
    patient_id: str,
    window: Literal["weekly", "monthly"] = "weekly",
    date: str | None = None,
) -> dict:
    from datetime import date as date_type
    end_d = date_type.fromisoformat(date) if date else datetime.now().date()
    days = 7 if window == "weekly" else 30
    return feature_store.period_summary(patient_id, days=days, end_date=end_d)


@app.get("/patients/{patient_id}/notes")
def get_patient_notes(patient_id: str, date: str | None = None) -> dict:
    notes = note_store.list_notes(patient_id, date=date)
    return {
        "patient_id": patient_id,
        "date": date,
        "notes": notes,
        "total_notes": len(notes),
    }


@app.post("/patients/{patient_id}/notes")
def create_patient_note(patient_id: str, request: NoteCreateRequest) -> dict:
    if not request.text.strip():
        raise HTTPException(status_code=400, detail="Note text cannot be empty")
    created = note_store.add_note(
        patient_id,
        date=request.date,
        text=request.text,
        tags=request.tags,
        author=request.author,
    )
    return created


@app.delete("/patients/{patient_id}/notes/{note_id}")
def delete_patient_note(patient_id: str, note_id: str) -> dict:
    success = note_store.delete_note(patient_id, note_id)
    if not success:
        raise HTTPException(status_code=404, detail="Note not found")
    return {"status": "ok", "deleted": True, "note_id": note_id}


@app.get("/patients/{patient_id}/baseline")
def patient_baseline(patient_id: str) -> dict:
    return feature_store.baseline_state(patient_id)


@app.post("/patients/{patient_id}/baseline/finalize")
def finalize_patient_baseline(patient_id: str) -> dict:
    try:
        return feature_store.finalize_baseline(patient_id)
    except ValueError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error


@app.post("/patients/{patient_id}/baseline/reset")
def reset_patient_baseline(patient_id: str) -> dict:
    # Old open alerts belong to the previous reference. Preserve the audit trail
    # but close them so the dashboard does not show stale active warnings.
    resolved_at = datetime.now(timezone.utc).isoformat()
    for alert in alert_store.list(patient_id, limit=500):
        if alert.get("status") in {"new", "acknowledged"}:
            alert_store.set_status(
                patient_id,
                alert["alert_id"],
                "resolved",
                resolved_at=resolved_at,
                resolution="baseline_reset",
            )
    alert_store.clear_state(patient_id)
    return feature_store.reset_baseline(patient_id)


@app.get("/patients/{patient_id}/alerts")
def patient_alerts(
    patient_id: str,
    after_timestamp_ms: int = 0,
    status: str | None = None,
    limit: int = 100,
) -> list[dict]:
    return alert_store.list(
        patient_id,
        after_timestamp_ms=after_timestamp_ms,
        status=status,
        limit=limit,
    )


@app.post("/patients/{patient_id}/alerts/{alert_id}/ack")
def acknowledge_patient_alert(patient_id: str, alert_id: str) -> dict:
    alert = alert_store.acknowledge(patient_id, alert_id)
    if alert is None:
        raise HTTPException(status_code=404, detail="Alert not found")
    return alert


@app.post("/patients/{patient_id}/alerts/{alert_id}/dismiss")
def dismiss_patient_alert(
    patient_id: str,
    alert_id: str,
    request: AlertDismissRequest | None = None,
) -> dict:
    reason = request.reason if request else "false_positive"
    alert = alert_store.dismiss(patient_id, alert_id, reason=reason)
    if alert is None:
        raise HTTPException(status_code=404, detail="Alert not found")
    if reason == "false_positive" and alert.get("session_id"):
        feature_store.clear_session_fall(patient_id, alert["session_id"])
    return alert


@app.post("/patients/{patient_id}/pairing/generate")
def generate_pairing_code(
    patient_id: str,
    request: PairingGenerateRequest | None = None,
) -> dict:
    name = request.patient_name if request else ""
    ttl = request.ttl_seconds if request else 900
    return pairing_store.generate(patient_id=patient_id, patient_name=name, ttl_seconds=ttl)


@app.get("/patients/{patient_id}/pairing/active")
def get_active_pairing_code(patient_id: str) -> dict:
    active = pairing_store.active_for_patient(patient_id)
    return {"active": active is not None, "pairing": active}


@app.post("/pairing/claim")
def claim_pairing_code(request: PairingClaimRequest) -> dict:
    import time
    claimed = pairing_store.claim(request.code)
    if not claimed:
        raise HTTPException(status_code=404, detail="Invalid or expired pairing code")
    patient_id = claimed["patient_id"]
    caretaker_name = request.caretaker_name.strip() or "Caretaker"
    feature_store.save_caretaker(patient_id, {
        "caretaker_name": caretaker_name,
        "paired_at": datetime.now(timezone.utc).isoformat(),
        "paired_at_ms": int(time.time() * 1000),
        "active": True,
    })
    state = feature_store.baseline_state(patient_id)
    from datetime import date
    day_rep = feature_store.day_report(patient_id, date.today())
    return {
        "status": "ok",
        "patient_id": patient_id,
        "patient_name": claimed.get("patient_name", ""),
        "caretaker_name": caretaker_name,
        "baseline_state": state,
        "day_report": day_rep,
    }


@app.get("/patients/{patient_id}/active-status")
def patient_active_status(patient_id: str) -> dict:
    import time
    from datetime import date
    today = date.today()
    day_rep = feature_store.day_report(patient_id, today)
    baseline_st = feature_store.baseline_state(patient_id)
    recent = feature_store.recent_sessions(patient_id, limit=1)
    last_session = recent[0] if recent else None
    last_seen_ms = last_session.get("timestamp_ms") if last_session else None
    now_ms = int(time.time() * 1000)
    # Online if an interval was received within the last 3 minutes
    online = bool(last_seen_ms and (now_ms - last_seen_ms) <= 180_000)

    alerts = alert_store.list(patient_id, limit=20)
    new_alerts = [
        a for a in alerts
        if a.get("status") == "new"
    ]
    active_alert = new_alerts[-1] if new_alerts else None

    has_new_fall = any(
        (a.get("symptom") == "fall" or "fall" in a.get("title", "").lower())
        and a.get("status") == "new"
        for a in alerts
    )
    has_ack_fall = any(
        (a.get("symptom") == "fall" or "fall" in a.get("title", "").lower())
        and a.get("status") == "acknowledged"
        for a in alerts
    )
    symptom_labels = dict(day_rep.get("symptom_labels", {}))
    if has_new_fall:
        symptom_labels["fall"] = "critical"
    elif has_ack_fall:
        symptom_labels["fall"] = "acknowledged"
    else:
        symptom_labels["fall"] = "normal"

    return {
        "patient_id": patient_id,
        "online": online,
        "last_seen_ms": last_seen_ms,
        "active_alert": active_alert,
        "symptom_labels": symptom_labels,
        "fall_incidents": day_rep.get("fall_incidents", 0),
        "day_report": day_rep,
        "baseline_state": baseline_st,
        "caretaker": feature_store.get_caretaker(patient_id),
    }


@app.get("/patients/{patient_id}/caretaker")
def get_patient_caretaker(patient_id: str) -> dict:
    caretaker = feature_store.get_caretaker(patient_id)
    return {"paired": caretaker is not None, "caretaker": caretaker}


@app.post("/patients/{patient_id}/caretaker/unpair")
def unpair_patient_caretaker(patient_id: str) -> dict:
    removed = feature_store.remove_caretaker(patient_id)
    return {"status": "ok", "unpaired": removed}


@app.post("/patients/{patient_id}/caretaker/profile")
def update_patient_caretaker(patient_id: str, request: CaretakerProfileUpdateRequest) -> dict:
    existing = feature_store.get_caretaker(patient_id) or {}
    name = request.caretaker_name.strip() or "Caretaker"
    existing["caretaker_name"] = name
    if "paired_at_ms" not in existing:
        existing["paired_at_ms"] = int(time.time() * 1000)
    existing["active"] = True
    feature_store.save_caretaker(patient_id, existing)
    return {"status": "ok", "caretaker": existing}


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


@app.delete("/patients/{patient_id}")
def delete_patient_endpoint(patient_id: str) -> dict:
    deleted = feature_store.delete_patient(patient_id)
    return {"status": "ok", "deleted": deleted, "patient_id": patient_id}


def _ppp_fetch_function():
    """Resolve the tutorial-data loader in both supported launch layouts.

    Uvicorn is normally started with `--app-dir processing`, which makes `app`
    the top-level package. Tests import this module as `processing.app`, so the
    package-relative layout needs a fallback rather than `..scripts`.
    """
    try:
        from scripts.ingest_ppp_tutorial_data import fetch_ppp_recording
    except ImportError:
        from processing.scripts.ingest_ppp_tutorial_data import fetch_ppp_recording
    return fetch_ppp_recording


@app.post("/patients/{patient_id}/load-test-baseline")
def load_test_baseline(patient_id: str) -> dict:
    """Ingest ParaDigMa's public tutorial recording (7 intervals) to establish
    immediate personal baseline intervals for testing without auto-finalizing.
    """
    needed_samples = 7 * 2000  # 14,000 samples @ 100 Hz (~2.3 minutes)
    times, values = _ppp_fetch_function()(needed_samples)

    sampling_freq = 100.0
    interval_seconds = 20
    samples_per_interval = int(interval_seconds * sampling_freq)
    num_intervals = 7

    # Ensure timestamps are strictly after any baseline reset so all intervals count
    directory = feature_store.patient_directory(patient_id)
    baseline_path = directory / "_baseline.json"
    reset_ms = 0
    if baseline_path.exists():
        try:
            reset_ms = int(json.loads(baseline_path.read_text(encoding="utf-8")).get("reset_at_ms", 0))
        except Exception:
            reset_ms = 0

    base_time_ms = max(int(datetime.now(timezone.utc).timestamp() * 1000), reset_ms + 1000)
    batch_tag = uuid4().hex[:8]
    local_date_str = datetime.now().date().isoformat()

    for i in range(num_intervals):
        start_idx = i * samples_per_interval
        end_idx = start_idx + samples_per_interval
        chunk_times = times[start_idx:end_idx]
        chunk_vals = values[start_idx:end_idx]

        interval_start_ms = base_time_ms + i * interval_seconds * 1000
        interval_end_ms = interval_start_ms + interval_seconds * 1000
        ts_ms = (interval_start_ms + (chunk_times - chunk_times[0]) * 1000).astype(np.int64)

        accel_samples = [
            Sample(
                timestamp_ms=int(t),
                x=float(v[0] * GRAVITY_M_S2),
                y=float(v[1] * GRAVITY_M_S2),
                z=float(v[2] * GRAVITY_M_S2),
            )
            for t, v in zip(ts_ms, chunk_vals)
        ]
        gyro_samples = [
            Sample(
                timestamp_ms=int(t),
                x=float(v[3] * (np.pi / 180.0)),
                y=float(v[4] * (np.pi / 180.0)),
                z=float(v[5] * (np.pi / 180.0)),
            )
            for t, v in zip(ts_ms, chunk_vals)
        ]

        req = ProcessRequest(
            task_type="monitoring",
            watch_side="left",
            patient_id=patient_id,
            session_id=f"test-baseline-ppp-{batch_tag}-{i + 1:02d}",
            start_time_ms=int(interval_start_ms),
            timestamp_ms=int(interval_end_ms),
            local_date=local_date_str,
            accelerometer=accel_samples,
            gyroscope=gyro_samples,
        )
        process_session(req)

    # Return the building baseline state without auto-finalizing it so the user can calibrate manually
    return feature_store.baseline_state(patient_id)
