# Python movement-processing service

This service receives bounded Android monitoring intervals in memory, converts
Android SensorManager units to ParaDigMa's expected units, then calls ParaDigMa's
documented tremor and gait/arm-swing stages. It maps only package outputs such
as `pred_tremor_proba`, `tremor_power`, `pred_tremor_checked`,
`pred_arm_at_rest`, `pred_gait_proba`, `range_of_motion`, and `peak_velocity`.
The additional `gyro_rms_rad_s` measurement is a transparent movement-vigor
proxy, not a ParaDigMa biomarker or clinical bradykinesia score.

Each quality-passing interval immediately updates the patient's statistical
baseline. The service stores one compact JSON feature document per interval in
`processing/data/feature_vectors/`; no accelerometer/gyroscope samples or
ParaDigMa intermediates are written to disk. Set `FEATURE_STORE_PATH` to move
the document store to persistent server storage. Use one Uvicorn worker for this
file-backed prototype store. Mean and standard deviation are updated online;
percentile statistics use a bounded reservoir of up to 2,048 values per feature.

Start from the repository root:

```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r processing\requirements.txt
uvicorn app.main:app --app-dir processing --host 0.0.0.0 --port 8000
```

Endpoints:

- `GET /health`
- `POST /process-session` — monitoring interval upload
- `GET /patients/{patient_id}/daily-report?date=YYYY-MM-DD`
- `GET /patients/{patient_id}/feature-vectors?after_timestamp_ms=...`

Android sensor requirements are checked per upload: accelerometer and
gyroscope, at least 50 Hz, at least 10 seconds of aligned samples, and watch side
`left` or `right`. In the app's normal operation each upload covers three
minutes. Tremor and gait run together because they share the IMU data.
