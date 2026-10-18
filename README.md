# Parkinson's movement monitoring prototype

## Continuous monitoring

On Android, select a patient and start **all-day monitoring** from the dashboard.
The Android foreground health service collects only accelerometer and gyroscope
samples while its persistent notification is active. It uploads bounded
three-minute batches, processes them in Python, and discards the raw sample
batch. The upload includes no GPS, camera, or microphone data. Stop monitoring
from the dashboard to end collection.

Continuous 50 Hz sensor capture uses a partial wake lock and can use substantial
battery. Leave the ongoing notification enabled, avoid force-stopping the app,
and keep the phone secured in a consistent wrist orientation. Android may still
stop services under manufacturer-specific battery policies; reopen the app and
check the monitor status if a gap occurs. Monitoring does not automatically
restart after a device reboot.

This implementation provides continuous background capture on Android. iOS
suspends ordinary app sensor streams shortly after backgrounding, so its
15-minute background refresh is not suitable for continuous all-day IMU capture.
The app reports this platform limitation rather than claiming continuous iOS
coverage.

## Backend

Python 3.11 or newer is required. ParaDigMa 1.1.2 performs tremor and gait/arm
swing processing. A separate gyroscope movement-vigor proxy is included in the
report as a bradykinesia-compatible observation; it is not a ParaDigMa feature
or a clinical bradykinesia assessment.

```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r processing\requirements.txt
uvicorn app.main:app --app-dir processing --host 0.0.0.0 --port 8000
```

The app now automatically discovers your computer's IP address on the local Wi-Fi
network (and supports `http://10.0.2.2:8000` on Android emulator and `http://127.0.0.1:8000`
over `adb reverse`). The wrist position is fixed to `left`.

You can simply run:

```powershell
flutter run
```

The app will scan the Wi-Fi subnet for port 8000 on launch, connect to the
Python server automatically, and display the connected server status in the dashboard.
You can also manually edit or rescan the IP directly from the app interface anytime.

## Features, baseline, and report

The service runs ParaDigMa's tremor and gait pipelines for each monitoring
interval, adds a compact movement-vigor proxy, and stores one metadata/feature
document per interval under `processing/data/feature_vectors/`. It stores no raw
sensor samples. The baseline is statistical and automatically incorporates each
quality-passing interval immediately. `FEATURE_STORE_PATH` can select another
persistent directory for the server document store. Flutter syncs compact feature
vectors into Hive CE while the app is open; the server remains the source of
truth when the app has been closed.

The dashboard retrieves the day's interval totals, movement summaries, personal
baseline, and descriptive symptom labels. Labels (`normal`, `mild`, `moderate`,
`severe`) are changes relative to the patient's own statistics, not clinical
diagnoses. Early intervals show “baseline building.” The bradykinesia-compatible
label is explicitly a passive movement-vigor proxy, not a validated
bradykinesia measure. Isolation Forest remains unimplemented.

Mean and standard deviation are updated online. Percentiles use a bounded
reservoir of up to 2,048 values per feature to keep memory usage predictable.
