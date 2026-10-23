# Parkinson's movement monitoring prototype

## Continuous monitoring

On Android, select a patient and start monitoring from the dashboard. Continuous
monitoring has two separate modes:

1. **Personal baseline** collects reference intervals. These intervals update the
   patient's baseline statistics and never generate an alert.
2. **Anomaly monitoring** compares each new interval with the frozen personal
   baseline. It generates in-app and Android notifications when movement changes,
   and these intervals are excluded from the baseline.

Finalize or recalibrate the baseline from the baseline screen. Anomaly monitoring
is unavailable until at least five quality baseline intervals exist. Switching
modes stops and restarts the Android service so baseline and anomaly samples are
never mixed.

The Android foreground health service collects only accelerometer and gyroscope
samples while its persistent notification is active. It uploads bounded
20-second batches, processes them in Python, and discards the raw sample batch.
The upload includes no GPS, camera, or microphone data. Stop monitoring from the
dashboard to end collection. The dashboard also refreshes its in-app alert banner
every 15 seconds while it is open.

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
sensor samples. Baseline-mode intervals update online mean, standard deviation,
median, MAD, and percentile statistics; anomaly-mode intervals are excluded.
Finalizing the baseline freezes a reference snapshot and, once 20 quality
intervals exist, fits a per-patient Isolation Forest. Anomaly monitoring uses
direction-aware robust z-scores as the primary explainable signal, with the
Isolation Forest as corroboration rather than a standalone alert source.
A value already inside the patient's observed baseline range is treated as known
variability, not a new deviation. Absolute ParaDigMa thresholds remain a safety
net for clearly high tremor. Activity context matters: tremor is compared during
rest, while arm swing and movement vigor are compared during walking. `FEATURE_STORE_PATH` can select
another persistent directory for the server document store. Flutter syncs compact feature
vectors into Hive CE while the app is open; the server remains the source of
truth when the app has been closed.

The dashboard retrieves the day's interval totals, movement summaries, personal
baseline, and descriptive symptom labels. Labels (`normal`, `mild`, `moderate`,
`severe`) are changes relative to the patient's own statistics, not clinical
diagnoses. Early intervals show “baseline building.” The bradykinesia-compatible
label is explicitly a passive movement-vigor proxy, not a validated
bradykinesia measure.

Warnings and critical alerts fire on the first qualifying interval. The same
symptom is re-notified immediately when it becomes materially worse, or after a
short one-minute cooldown for an unchanged repeat. An unchanged symptom the
patient has acknowledged stays quiet until it becomes materially worse or a new
monitoring episode starts. A monitoring gap longer than 90 seconds starts that
fresh episode and clears the previous suppression. Three clear intervals resolve
an open alert. Alerts are stored per patient and can be acknowledged in the app
without clearing the underlying open-alert tracking.

Mean and standard deviation are updated online. Percentiles use a bounded
reservoir of up to 2,048 values per feature to keep memory usage predictable.
