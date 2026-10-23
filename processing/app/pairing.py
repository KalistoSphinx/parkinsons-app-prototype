"""Pairing code store for linking caretakers with patients over long range."""

from __future__ import annotations

import json
import os
import random
import threading
import time
from pathlib import Path
from typing import Any

_DEFAULT_PATH = Path(__file__).resolve().parents[1] / "data" / "pairing_codes.json"


class PairingStore:
    def __init__(self, path: Path | None = None) -> None:
        self.path = path or _DEFAULT_PATH
        self._lock = threading.RLock()
        self._cache: dict[str, dict[str, Any]] = {}
        self._load()

    def _load(self) -> None:
        with self._lock:
            if self.path.exists():
                try:
                    self._cache = json.loads(self.path.read_text(encoding="utf-8"))
                except Exception:
                    self._cache = {}
            else:
                self._cache = {}

    def _save(self) -> None:
        with self._lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temp = self.path.with_suffix(".tmp")
            temp.write_text(
                json.dumps(self._cache, indent=2),
                encoding="utf-8",
            )
            temp.replace(self.path)

    def _cleanup_expired(self, now_ms: int) -> None:
        to_delete = [
            code
            for code, data in self._cache.items()
            if int(data.get("expires_at_ms", 0)) <= now_ms
        ]
        for code in to_delete:
            del self._cache[code]

    def generate(
        self,
        patient_id: str,
        patient_name: str = "",
        ttl_seconds: int = 900,
    ) -> dict[str, Any]:
        with self._lock:
            now_ms = int(time.time() * 1000)
            self._cleanup_expired(now_ms)

            # Invalidate any older code for this patient
            for code, data in list(self._cache.items()):
                if data.get("patient_id") == patient_id:
                    del self._cache[code]

            # Generate collision-free 6-digit numeric code
            for _ in range(100):
                code = f"{random.randint(100000, 999999)}"
                if code not in self._cache:
                    break

            expires_at_ms = now_ms + ttl_seconds * 1000
            entry = {
                "code": code,
                "patient_id": patient_id,
                "patient_name": patient_name,
                "created_at_ms": now_ms,
                "expires_at_ms": expires_at_ms,
                "expires_in_seconds": ttl_seconds,
            }
            self._cache[code] = entry
            self._save()
            return entry

    def active_for_patient(self, patient_id: str) -> dict[str, Any] | None:
        with self._lock:
            now_ms = int(time.time() * 1000)
            self._cleanup_expired(now_ms)
            for data in self._cache.values():
                if data.get("patient_id") == patient_id:
                    remaining_s = max(0, int((data["expires_at_ms"] - now_ms) / 1000))
                    result = dict(data)
                    result["expires_in_seconds"] = remaining_s
                    return result
            return None

    def claim(self, code_input: str) -> dict[str, Any] | None:
        cleaned = code_input.strip().replace("-", "").replace(" ", "")
        with self._lock:
            now_ms = int(time.time() * 1000)
            self._cleanup_expired(now_ms)
            entry = self._cache.get(cleaned)
            if not entry:
                return None
            if int(entry.get("expires_at_ms", 0)) <= now_ms:
                del self._cache[cleaned]
                self._save()
                return None

            entry["claimed_at_ms"] = now_ms
            self._save()
            return {
                "patient_id": entry["patient_id"],
                "patient_name": entry.get("patient_name", ""),
                "code": cleaned,
                "claimed_at_ms": now_ms,
            }


pairing_store = PairingStore()
