from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable


@dataclass
class SessionMeta:
    session_id: str
    path: Path
    cwd: str | None = None
    originator: str | None = None
    source: str | None = None
    thread_source: str | None = None


@dataclass
class AssistantAnswer:
    timestamp: str
    text: str
    phase: str
    provisional: bool = False


@dataclass
class QaTurn:
    question_time: str
    question: str
    answers: list[AssistantAnswer] = field(default_factory=list)


@dataclass
class SessionDiary:
    meta: SessionMeta
    turns: list[QaTurn]


def iter_session_files(sessions_root: Path) -> Iterable[Path]:
    if not sessions_root.exists():
        return []
    return sorted(sessions_root.rglob("*.jsonl"), key=lambda path: path.stat().st_mtime)


def parse_session_file(path: Path, include_commentary: bool = False) -> SessionDiary | None:
    meta: SessionMeta | None = None
    turns: list[QaTurn] = []
    current: QaTurn | None = None
    commentary_buffer: list[AssistantAnswer] = []

    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            row_type = row.get("type")
            payload = row.get("payload") if isinstance(row.get("payload"), dict) else {}
            timestamp = str(row.get("timestamp", ""))
            if row_type == "session_meta":
                meta = SessionMeta(
                    session_id=str(payload.get("session_id") or payload.get("id") or path.stem),
                    path=path,
                    cwd=payload.get("cwd"),
                    originator=payload.get("originator"),
                    source=payload.get("source"),
                    thread_source=payload.get("thread_source"),
                )
                continue
            if row_type != "event_msg":
                continue
            event_type = payload.get("type")
            if event_type == "user_message":
                current = finish_turn(current, commentary_buffer, turns)
                commentary_buffer = []
                message = str(payload.get("message", "")).strip()
                if should_skip_user_message(message):
                    current = None
                    continue
                current = QaTurn(question_time=timestamp, question=message)
            elif event_type == "agent_message" and current is not None:
                phase = str(payload.get("phase", ""))
                message = str(payload.get("message", "")).strip()
                if not message:
                    continue
                answer = AssistantAnswer(timestamp=timestamp, text=message, phase=phase)
                if phase == "final_answer":
                    current.answers.append(answer)
                elif include_commentary:
                    current.answers.append(answer)
                else:
                    commentary_buffer.append(answer)

    current = finish_turn(current, commentary_buffer, turns)
    if meta is None:
        meta = SessionMeta(session_id=path.stem, path=path)
    if meta.thread_source and meta.thread_source != "user":
        return None
    return SessionDiary(meta=meta, turns=turns)


def finish_turn(
    current: QaTurn | None,
    commentary_buffer: list[AssistantAnswer],
    turns: list[QaTurn],
) -> QaTurn | None:
    if current is None:
        return None
    if not current.answers and commentary_buffer:
        last = commentary_buffer[-1]
        current.answers.append(
            AssistantAnswer(timestamp=last.timestamp, text=last.text, phase=last.phase, provisional=True)
        )
    if current.answers:
        turns.append(current)
    return None


def should_skip_user_message(message: str) -> bool:
    stripped = message.strip()
    if not stripped:
        return True
    if stripped.startswith("<subagent_notification>"):
        return True
    return False

