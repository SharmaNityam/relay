"""Local aliases for sessions. Source provider stores are never modified."""
from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from threading import RLock
from typing import Any


class Store:
    def __init__(self, state_dir: Path):
        self.state_dir = Path(state_dir)
        self.path = self.state_dir / "aliases.json"
        self._lock = RLock()

    def _read(self) -> dict[str, str]:
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
            if isinstance(raw, dict) and isinstance(raw.get("aliases", raw), dict):
                src = raw.get("aliases", raw)
                return {str(k): str(v) for k, v in src.items() if isinstance(v, str)}
        except (OSError, ValueError, TypeError):
            pass
        return {}

    def _write(self, aliases: dict[str, str]) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        fd, temp_name = tempfile.mkstemp(prefix=".aliases-", suffix=".tmp", dir=self.state_dir)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as file:
                json.dump({"aliases": aliases}, file, ensure_ascii=False, sort_keys=True)
                file.flush()
                os.fsync(file.fileno())
            os.replace(temp_name, self.path)
            os.chmod(self.path, 0o600)
        finally:
            try:
                os.unlink(temp_name)
            except FileNotFoundError:
                pass

    @staticmethod
    def _key(provider: str, session_id: str) -> str:
        return f"{provider}:{session_id}"

    def get_alias(self, provider: str, session_id: str) -> str | None:
        with self._lock:
            return self._read().get(self._key(provider, session_id))

    def set_alias(self, provider: str, session_id: str, name: str) -> None:
        key = self._key(provider, session_id)
        with self._lock:
            aliases = self._read()
            if name.strip():
                aliases[key] = name.strip()[:120]
            else:
                aliases.pop(key, None)
            self._write(aliases)

    def apply(self, snapshot: dict[str, Any]) -> dict[str, Any]:
        """Return a decorated snapshot; user aliases take precedence over suggestions."""
        result = dict(snapshot)
        sessions = [dict(item) for item in snapshot.get("sessions", [])]
        with self._lock:
            aliases = self._read()
        # Avoid duplicate automatic names while preserving explicit aliases.
        automatic: dict[str, list[int]] = {}
        for index, item in enumerate(sessions):
            key = self._key(str(item.get("provider", "")), str(item.get("id", "")))
            if key not in aliases:
                name = str(item.get("suggested_name") or item.get("title") or "Coding session")
                automatic.setdefault(name.casefold(), []).append(index)
        for index, item in enumerate(sessions):
            provider, session_id = str(item.get("provider", "")), str(item.get("id", ""))
            key = self._key(provider, session_id)
            alias = aliases.get(key)
            base = str(item.get("suggested_name") or item.get("title") or "Coding session")
            if alias:
                item["alias"] = alias
                item["display_name"] = alias
            else:
                item.pop("alias", None)
                collision = automatic.get(base.casefold(), [])
                if len(collision) > 1:
                    ids = [str(sessions[i].get("id", "")).replace("-", "") or str(i + 1)
                           for i in collision]
                    width = min(6, min(map(len, ids)))
                    while width < max(map(len, ids)) and len({value[-width:] for value in ids}) != len(ids):
                        width = min(max(map(len, ids)), width + 2)
                    suffixes = [value[-width:] for value in ids]
                    # Identical provider IDs can only be separated by their stable snapshot position.
                    if len(set(suffixes)) != len(suffixes):
                        suffixes = [f"{suffix}-{i + 1}" for i, suffix in enumerate(suffixes)]
                    short_id = suffixes[collision.index(index)]
                    item["display_name"] = f"{base} · {short_id}"
                else:
                    item["display_name"] = base
        result["sessions"] = sessions
        return result
