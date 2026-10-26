"""Shared provider-neutral session model and dashboard response contract."""
from dataclasses import asdict, dataclass, field
from typing import Any


@dataclass
class Session:
    provider: str
    id: str
    title: str = "Untitled session"
    task: str = ""
    cwd: str = ""
    project: str = "Unknown project"
    parent_id: str | None = None
    role: str = "agent"
    model: str | None = None
    status: str = "unknown"
    status_source: str = "unknown"
    last_event_at: str | None = None
    last_activity: str = "No observed activity"
    tokens: int | None = None
    suggested_name: str = ""

    def to_dict(self) -> dict[str, Any]:
        value = asdict(self)
        value["key"] = f"{self.provider}:{self.id}"
        value["parent_key"] = f"{self.provider}:{self.parent_id}" if self.parent_id else None
        value["display_name"] = self.suggested_name or self.title
        return value


@dataclass
class Snapshot:
    sessions: list[Session] = field(default_factory=list)
    providers: list[dict[str, Any]] = field(default_factory=list)
    updated_at: str = ""

    def to_dict(self) -> dict[str, Any]:
        sessions = [item.to_dict() for item in self.sessions]
        counts = {key: sum(s.status == key for s in self.sessions) for key in
                  ("running", "waiting", "completed", "failed", "interrupted", "stale", "unknown")}
        return {"sessions": sessions, "providers": self.providers, "updated_at": self.updated_at,
                "counts": counts, "total": len(sessions)}
