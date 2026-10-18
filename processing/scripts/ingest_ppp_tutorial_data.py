"""Ingest public Personalized Parkinson Project (PPP) tutorial recording from ParaDigMa.

Fetches genuine Verily Study Watch IMU data from the biomarkersParkinson/paradigma
repository, processes consecutive intervals through the ParaDigMa pipeline,
establishes the patient's personal baseline, and updates daily clinical observations.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import numpy as np

# Gravity constant used for conversion to Android m/s^2 units
GRAVITY_M_S2 = 9.80665
DEG_TO_RAD = math.pi / 180.0

DATA_DIR = Path(__file__).resolve().parents[1] / "data"
CACHE_FILE = DATA_DIR / "ppp_tutorial_cache.npz"

# Git LFS Object IDs for ParaDigMa example_data/verily/imu/imu_segment0001
LFS_BATCH_URL = "https://github.com/biomarkersParkinson/paradigma.git/info/lfs/objects/batch"
TIME_OID = "73485c78f6e97e0ff7066884987d173fe410de7591c50a15cbe98ec0c7e9d279"
TIME_SIZE = 27642648
VALUES_OID = "9f3e3dd2f76f5f4191fc1bba5d0c18a2c4e460afeb62fbf92b672cb407d90b83"
VALUES_SIZE = 165855888


def get_lfs_download_urls() -> tuple[str, str]:
    """Request presigned download URLs from GitHub's Git LFS Batch API."""
    payload = {
        "operation": "download",
        "transfers": ["basic"],
        "objects": [
            {"oid": TIME_OID, "size": TIME_SIZE},
            {"oid": VALUES_OID, "size": VALUES_SIZE},
        ],
    }
    req = urllib.request.Request(
        LFS_BATCH_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Accept": "application/vnd.git-lfs+json",
            "Content-Type": "application/vnd.git-lfs+json",
            "User-Agent": "git-lfs/3.0.0",
        },
    )
    with urllib.request.urlopen(req) as response:
        data = json.loads(response.read().decode("utf-8"))
    time_url = data["objects"][0]["actions"]["download"]["href"]
    values_url = data["objects"][1]["actions"]["download"]["href"]
    return time_url, values_url


def fetch_ppp_recording(total_samples: int = 60_000) -> tuple[np.ndarray, np.ndarray]:
    """Fetch or load cached PPP tutorial recording slice.
    
    total_samples: default 60,000 is ~10 minutes at ~100 Hz.
    """
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if CACHE_FILE.exists():
        print(f"[cache] Loading cached PPP tutorial recording from {CACHE_FILE}")
        with np.load(CACHE_FILE) as data:
            times = data["times"]
            values = data["values"]
            if len(times) >= total_samples:
                return times[:total_samples], values[:total_samples]

    print(f"[download] Requesting {total_samples} samples from ParaDigMa Git LFS...")
    time_url, values_url = get_lfs_download_urls()

    # Float64 (8 bytes per scalar):
    time_bytes_len = total_samples * 8
    val_bytes_len = total_samples * 6 * 8

    print(f"[download] Downloading {time_bytes_len / 1024:.1f} KB time stream...")
    req_time = urllib.request.Request(time_url, headers={"Range": f"bytes=0-{time_bytes_len - 1}"})
    with urllib.request.urlopen(req_time) as resp:
        time_bytes = resp.read()

    print(f"[download] Downloading {val_bytes_len / (1024 * 1024):.2f} MB values stream (accel + gyro)...")
    req_val = urllib.request.Request(values_url, headers={"Range": f"bytes=0-{val_bytes_len - 1}"})
    with urllib.request.urlopen(req_val) as resp:
        val_bytes = resp.read()

    times = np.frombuffer(time_bytes, dtype="<f8")
    values = np.frombuffer(val_bytes, dtype="<f8").reshape(-1, 6)

    np.savez_compressed(CACHE_FILE, times=times, values=values)
    print(f"[cache] Saved {len(times)} samples to {CACHE_FILE}")
    return times, values


def post_session(server_url: str, request_data: dict[str, Any]) -> dict[str, Any]:
    url = f"{server_url.rstrip('/')}/process-session"
    body = json.dumps(request_data).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode("utf-8"))


def get_daily_report(server_url: str, patient_id: str) -> dict[str, Any]:
    url = f"{server_url.rstrip('/')}/patients/{patient_id}/daily-report"
    with urllib.request.urlopen(url) as resp:
        return json.loads(resp.read().decode("utf-8"))


def ingest_for_patient(
    patient_id: str,
    server_url: str,
    times: np.ndarray,
    values: np.ndarray,
    num_intervals: int = 7,
    interval_seconds: int = 60,
    sampling_freq: float = 100.0,
) -> None:
    print(f"\n=======================================================")
    print(f" Processing PPP Tutorial Recording for Patient: {patient_id}")
    print(f"=======================================================")

    samples_per_interval = int(interval_seconds * sampling_freq)
    total_needed = num_intervals * samples_per_interval
    if len(times) < total_needed:
        raise ValueError(f"Recording has {len(times)} samples, need {total_needed}")

    # Set timestamps so that sessions fall under today's date, spaced out
    now_ms = int(datetime.now(timezone.utc).timestamp() * 1000)

    for i in range(num_intervals):
        start_idx = i * samples_per_interval
        end_idx = start_idx + samples_per_interval
        chunk_times = times[start_idx:end_idx]
        chunk_vals = values[start_idx:end_idx]

        # Shift relative time to millisecond timestamps for today
        # Interval i ends at now_ms - (num_intervals - 1 - i) * interval_seconds * 1000
        interval_end_ms = now_ms - (num_intervals - 1 - i) * interval_seconds * 1000
        interval_start_ms = interval_end_ms - int((chunk_times[-1] - chunk_times[0]) * 1000)

        # Convert chunk_times relative offsets to ms
        ts_ms = (interval_start_ms + (chunk_times - chunk_times[0]) * 1000).astype(np.int64)

        # Convert values:
        # PPP values: col 0..2 are accel in g -> multiply by 9.80665 to get m/s^2 for Android adapter
        # PPP values: col 3..5 are gyro in deg/s -> multiply by DEG_TO_RAD to get rad/s for Android adapter
        accel_samples = [
            {
                "timestamp_ms": int(t),
                "x": float(v[0] * GRAVITY_M_S2),
                "y": float(v[1] * GRAVITY_M_S2),
                "z": float(v[2] * GRAVITY_M_S2),
            }
            for t, v in zip(ts_ms, chunk_vals)
        ]
        gyro_samples = [
            {
                "timestamp_ms": int(t),
                "x": float(v[3] * DEG_TO_RAD),
                "y": float(v[4] * DEG_TO_RAD),
                "z": float(v[5] * DEG_TO_RAD),
            }
            for t, v in zip(ts_ms, chunk_vals)
        ]

        local_date_str = datetime.now().date().isoformat()
        payload = {
            "task_type": "monitoring",
            "watch_side": "left",
            "patient_id": patient_id,
            "session_id": f"ppp-tutorial-seg01-{i + 1:02d}",
            "start_time_ms": int(interval_start_ms),
            "timestamp_ms": int(interval_end_ms),
            "local_date": local_date_str,
            "accelerometer": accel_samples,
            "gyroscope": gyro_samples,
        }

        print(f"\n[Interval {i + 1}/{num_intervals}] Duration: {interval_seconds}s ({len(accel_samples)} samples)...")
        result = post_session(server_url, payload)
        passed = result.get("quality_passed")
        symptom_labels = result.get("symptom_labels", {})
        baseline_info = result.get("baseline", {})

        print(f"  -> Quality passed: {passed}")
        print(f"  -> Symptom observations: {symptom_labels}")
        if baseline_info:
            n_features = len(baseline_info)
            sample_counts = [v.get("count", 0) for v in baseline_info.values() if isinstance(v, dict)]
            max_count = max(sample_counts) if sample_counts else 0
            print(f"  -> Baseline updated: {n_features} features, sample count: {max_count}")

    # Fetch and display final daily report
    report = get_daily_report(server_url, patient_id)
    print("\n-------------------------------------------------------")
    print(f" FINAL REPORT for {patient_id} ({report.get('date')}):")
    print(f" Overall status:    {report.get('overall_status')}")
    print(f" Symptom labels:    {report.get('symptom_labels')}")
    print(f" Baseline sessions: {report.get('baseline_sessions')}")
    print(f" Processed today:   {report.get('processed_sessions')}")
    print(f" Monitoring min:    {report.get('monitoring_minutes')} min")
    print(f" Summary:           {report.get('summary')}")
    print("-------------------------------------------------------")


def main() -> None:
    parser = argparse.ArgumentParser(description="Ingest ParaDigMa public PPP tutorial recording.")
    parser.add_argument("--server", default="http://localhost:8000", help="FastAPI backend URL")
    parser.add_argument("--patient-id", default="27a1a971-bdc3-4f22-85b8-449a928ad135", help="Patient ID to process for")
    parser.add_argument("--intervals", type=int, default=7, help="Number of 60s intervals to process (>=5 for baseline)")
    parser.add_argument("--also-demo", action="store_true", help="Also ingest for paradigma-public-ppp-demo")
    args = parser.parse_args()

    # 1. Fetch PPP data (e.g. 7 intervals * 60s * 100 Hz = 42,000 samples)
    needed_samples = max(args.intervals * 6000, 60000)
    times, values = fetch_ppp_recording(needed_samples)

    # 2. Ingest for target patient
    ingest_for_patient(
        patient_id=args.patient_id,
        server_url=args.server,
        times=times,
        values=values,
        num_intervals=args.intervals,
    )

    # 3. Optionally also ingest for demo patient
    if args.also_demo:
        ingest_for_patient(
            patient_id="paradigma-public-ppp-demo",
            server_url=args.server,
            times=times,
            values=values,
            num_intervals=args.intervals,
        )


if __name__ == "__main__":
    main()
