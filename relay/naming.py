"""Deterministic, privacy-conscious session name suggestions."""
from __future__ import annotations

import re

from .contracts import Session

_SECRET_PATTERNS = [
    re.compile(r"(?i)\b(?:bearer\s+)[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(r"\b(?:sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{8,})\b"),
    re.compile(r"(?i)\b(password|passwd|token|api[_ -]?key)\s*[:=]\s*[^\s,;]+"),
    re.compile(r"\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b"),
]


def clean_text(value: str, limit: int = 240) -> str:
    """Strip markup/noise and obvious secrets from a short human text field."""
    text = str(value or "")
    # These metadata blocks are useful to the adapter but make poor task titles.
    text = re.sub(r"(?is)<environment_context\b[^>]*>.*?</environment_context\s*>", " ", text)
    text = re.sub(r"(?is)<system-reminder\b[^>]*>.*?</system-reminder\s*>", " ", text)
    text = re.sub(r"```.*?```", " ", text, flags=re.S)
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"!\[[^]]*\]\([^)]*\)", " ", text)
    text = re.sub(r"\[([^]]+)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"<[^>]+>", " ", text)
    for pattern in _SECRET_PATTERNS:
        text = pattern.sub("[redacted]", text)
    text = re.sub(r"\s+", " ", text).strip(" \t\r\n-—:;,.#")
    return text[:limit].rstrip()


def suggest_name(session: Session) -> str:
    """Build a stable concise title from project, role, and initial task text."""
    project = clean_text(session.project, 48)
    role = clean_text(session.role, 32)
    task = clean_text(session.task, 100)
    # Task descriptions often begin with boilerplate; retain the first useful sentence.
    task = re.split(r"(?<=[.!?])\s+", task, maxsplit=1)[0].strip()
    if not task:
        title = clean_text(session.title, 100)
        if title.casefold() not in {"untitled session", "main session", "agent session"}:
            task = title
    parts = [p for p in (project if project and project != "Unknown project" else "",
                         role if role and role.lower() not in {"agent", "main", "user"} else "",
                         task) if p]
    name = " · ".join(parts) or "Coding session"
    return name[:120].rstrip(" ·")
