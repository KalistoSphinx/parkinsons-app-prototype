from __future__ import annotations

import json
import os
import tempfile
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


class NoteStore:
    """Durable clinical & caretaker notes attached to specific dates."""

    def __init__(self, feature_store: Any) -> None:
        self.feature_store = feature_store
        self._lock = threading.RLock()

    def _notes_path(self, patient_id: str) -> Path:
        return self.feature_store.patient_directory(patient_id) / "_notes.json"

    def list_notes(self, patient_id: str, date: str | None = None) -> list[dict[str, Any]]:
        path = self._notes_path(patient_id)
        if not path.exists():
            return []
        with self._lock:
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
                if not isinstance(data, list):
                    return []
            except (OSError, json.JSONDecodeError):
                return []

        if date:
            target_date = str(date).strip()
            data = [n for n in data if n.get("date") == target_date]

        # Sort newest first
        data.sort(key=lambda n: n.get("created_at", ""), reverse=True)
        return data

    def add_note(
        self,
        patient_id: str,
        *,
        date: str,
        text: str,
        tags: list[str] | None = None,
        author: str = "Caretaker",
    ) -> dict[str, Any]:
        path = self._notes_path(patient_id)
        path.parent.mkdir(parents=True, exist_ok=True)

        note_id = str(uuid.uuid4())
        created_at = datetime.now(timezone.utc).isoformat()
        clean_tags = [t.strip() for t in (tags or []) if t.strip()]

        new_note = {
            "note_id": note_id,
            "patient_id": patient_id,
            "date": str(date).strip(),
            "created_at": created_at,
            "author": author.strip() or "Caretaker",
            "text": text.strip(),
            "tags": clean_tags,
        }

        with self._lock:
            notes = []
            if path.exists():
                try:
                    notes = json.loads(path.read_text(encoding="utf-8"))
                    if not isinstance(notes, list):
                        notes = []
                except (OSError, json.JSONDecodeError):
                    notes = []
            notes.append(new_note)

            temp_path = None
            try:
                with tempfile.NamedTemporaryFile(
                    mode="w",
                    encoding="utf-8",
                    dir=path.parent,
                    delete=False,
                    suffix=".tmp",
                ) as target:
                    json.dump(notes, target, allow_nan=False, indent=2)
                    target.flush()
                    os.fsync(target.fileno())
                    temp_path = Path(target.name)
                os.replace(temp_path, path)
            finally:
                if temp_path and temp_path.exists():
                    temp_path.unlink()

        return new_note

    def delete_note(self, patient_id: str, note_id: str) -> bool:
        path = self._notes_path(patient_id)
        if not path.exists():
            return False

        with self._lock:
            try:
                notes = json.loads(path.read_text(encoding="utf-8"))
                if not isinstance(notes, list):
                    return False
            except (OSError, json.JSONDecodeError):
                return False

            original_len = len(notes)
            notes = [n for n in notes if n.get("note_id") != note_id]
            if len(notes) == original_len:
                return False

            temp_path = None
            try:
                with tempfile.NamedTemporaryFile(
                    mode="w",
                    encoding="utf-8",
                    dir=path.parent,
                    delete=False,
                    suffix=".tmp",
                ) as target:
                    json.dump(notes, target, allow_nan=False, indent=2)
                    target.flush()
                    os.fsync(target.fileno())
                    temp_path = Path(target.name)
                os.replace(temp_path, path)
            finally:
                if temp_path and temp_path.exists():
                    temp_path.unlink()

        return True


from .feature_store import feature_store
note_store = NoteStore(feature_store)
