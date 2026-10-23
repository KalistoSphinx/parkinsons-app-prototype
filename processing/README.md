# Python movement-processing service

This service receives bounded Android monitoring intervals in memory, converts
Android SensorManager units to ParaDigMa's expected units, then calls ParaDigMa's
documented tremor and gait/arm-swing stages. It maps only package outputs such
as `pred_tremor_proba`, `tremor_power`, `pred_tremor_checked`,
`pred_arm_at_rest`, `pred_gait_proba`, `range_of_motion`, and `peak_velocity`.
The additional `gyro_rms_rad_s` measurement is a transparent movement-vigor
proxy, not a ParaDigMa biomarker or clinical bradykinesia score.

Continuous monitoring has two explicit modes, selected with
`monitoring_mode` on `POST /process-session`:

- `baseline` collects reference intervals. Quality-passing intervals update the
  online mean, standard deviation, median, MAD, and percentile statistics. No
  alerts are produced.
- `anomaly` compares each interval with the frozen reference baseline and can
  create alerts. These intervals are stored with `baseline_status: excluded` and
  never update the reference baseline.

`POST /patients/{patient_id}/baseline/finalize` freezes the reference snapshot.
Once 20 quality baseline intervals exist, it also fits a per-patient Isolation
Forest. The scorer uses direction-aware robust z-scores as the primary signal,
with the Isolation Forest as corroboration rather than a standalone alert source.
A value already inside the patient's observed baseline min/max is treated as
known variability rather than a new deviation. Absolute ParaDigMa thresholds
remain a safety net for clearly high tremor. Tremor is evaluated during rest,
and arm swing / movement vigor during walking.

The service stores one compact JSON feature document per interval in
`processing/data/feature_vectors/`; no accelerometer/gyroscope samples or
ParaDigMa intermediates are written to disk. Set `FEATURE_STORE_PATH` to move
the document store to persistent server storage. Use one Uvicorn worker for this
file-backed prototype store. Percentile statistics use a bounded reservoir of up
to 2,048 values per feature.

Start from the repository root:

```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r processing\requirements.txt
uvicorn app.main:app --app-dir processing --host 0.0.0.0 --port 8000
```

Endpoints:

- `GET /health`
- `POST /process-session` - monitoring interval upload; accepts `monitoring_mode`
- `GET /patients/{patient_id}/daily-report?date=YYYY-MM-DD`
- `GET /patients/{patient_id}/baseline` - baseline state and active statistics
- `POST /patients/{patient_id}/baseline/finalize` - freeze the reference baseline
- `POST /patients/{patient_id}/baseline/reset` - start a fresh calibration
- `GET /patients/{patient_id}/alerts?after_timestamp_ms=...&status=...`
- `POST /patients/{patient_id}/alerts/{alert_id}/ack`
- `GET /patients/{patient_id}/feature-vectors?after_timestamp_ms=...`

Warnings and critical alerts fire on the first qualifying interval. The same
symptom re-notifies immediately when it becomes materially worse, or after a
one-minute cooldown for an unchanged repeat. An unchanged symptom the patient
has acknowledged stays quiet until it worsens or a new episode starts. A
monitoring gap longer than 90 seconds starts a fresh episode and clears the
previous suppression. Three clear intervals resolve an open alert. They are
stored per patient in `_alerts.jsonl` with rule state in `_alert_state.json`.

Android sensor requirements are checked per upload: accelerometer and
gyroscope, at least 50 Hz, at least 10 seconds of aligned samples, and watch side
`left` or `right`. In the app's normal operation each upload covers 20 seconds.
Tremor and gait run together because they share the IMU data.
