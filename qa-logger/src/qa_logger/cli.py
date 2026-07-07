from __future__ import annotations

import argparse
import json
import time
from datetime import datetime
from pathlib import Path

from .diary import write_session_diary
from .history_compactor import compact_diary
from .session_reader import iter_session_files, parse_session_file


DEFAULT_SESSIONS_ROOT = Path.home() / ".codex" / "sessions"
DEFAULT_ARCHIVED_ROOT = Path.home() / ".codex" / "archived_sessions"
DEFAULT_DIARY_ROOT = Path.home() / ".codex" / "qa-diary"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="qa_logger", description="Local Codex QA Diary prototype")
    subcommands = parser.add_subparsers(dest="command", required=True)

    scan = subcommands.add_parser("scan-sessions", help="Scan Codex session JSONL and append main-agent Q/A diary")
    scan.add_argument("--sessions-root", type=Path, default=DEFAULT_SESSIONS_ROOT)
    scan.add_argument("--archived-root", type=Path, default=DEFAULT_ARCHIVED_ROOT)
    scan.add_argument("--include-archived", action="store_true")
    scan.add_argument("--diary-root", type=Path, default=DEFAULT_DIARY_ROOT)
    scan.add_argument("--include-commentary", action="store_true")
    scan.add_argument("--dry-run", action="store_true")

    compact = subcommands.add_parser("compact-diary", help="Compact existing QA diary answer bodies")
    compact.add_argument("--diary-root", type=Path, default=DEFAULT_DIARY_ROOT)
    compact.add_argument("--start-day", required=True)
    compact.add_argument("--end-day", required=True)
    compact.add_argument("--dry-run", action="store_true")
    compact.add_argument("--backup-root", type=Path)

    watch = subcommands.add_parser("watch", help="Poll Codex sessions and append diary entries")
    watch.add_argument("--sessions-root", type=Path, default=DEFAULT_SESSIONS_ROOT)
    watch.add_argument("--archived-root", type=Path, default=DEFAULT_ARCHIVED_ROOT)
    watch.add_argument("--include-archived", action="store_true")
    watch.add_argument("--diary-root", type=Path, default=DEFAULT_DIARY_ROOT)
    watch.add_argument("--include-commentary", action="store_true")
    watch.add_argument("--poll-seconds", type=int, default=15)

    args = parser.parse_args(argv)
    if args.command == "scan-sessions":
        summary = scan_sessions(
            sessions_root=args.sessions_root,
            diary_root=args.diary_root,
            archived_root=args.archived_root,
            include_archived=args.include_archived,
            include_commentary=args.include_commentary,
            dry_run=args.dry_run,
        )
        print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
        return 0
    if args.command == "compact-diary":
        summary = compact_diary(
            diary_root=args.diary_root,
            start_day=args.start_day,
            end_day=args.end_day,
            dry_run=args.dry_run,
            backup_root=args.backup_root,
        )
        print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
        return 0
    if args.command == "watch":
        while True:
            summary = scan_sessions(
                sessions_root=args.sessions_root,
                diary_root=args.diary_root,
                archived_root=args.archived_root,
                include_archived=args.include_archived,
                include_commentary=args.include_commentary,
                dry_run=False,
            )
            print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
            time.sleep(max(args.poll_seconds, 5))
    parser.error("unknown command")
    return 2


def scan_sessions(
    sessions_root: Path,
    diary_root: Path,
    archived_root: Path | None = None,
    include_archived: bool = False,
    include_commentary: bool = False,
    dry_run: bool = False,
) -> dict[str, object]:
    roots = [("sessions", sessions_root)]
    if include_archived and archived_root is not None:
        roots.append(("archived_sessions", archived_root))
    parsed = []
    turn_count = 0
    written_paths: set[str] = set()
    root_stats: list[dict[str, object]] = []
    seen_paths: set[Path] = set()
    for label, root in roots:
        files = [path for path in iter_session_files(root) if path not in seen_paths]
        seen_paths.update(files)
        root_with_qa = 0
        root_turns = 0
        root_first: str | None = None
        root_last: str | None = None
        for path in files:
            session = parse_session_file(path, include_commentary=include_commentary)
            if session is None:
                continue
            if not session.turns:
                continue
            parsed.append(session)
            root_with_qa += 1
            root_turns += len(session.turns)
            turn_count += len(session.turns)
            for turn in session.turns:
                day = local_day(turn.question_time)
                root_first = day if root_first is None or day < root_first else root_first
                root_last = day if root_last is None or day > root_last else root_last
            if not dry_run:
                for written in write_session_diary(diary_root, session):
                    written_paths.add(str(written))
        root_stats.append(
            {
                "label": label,
                "root": str(root),
                "sessions_seen": len(files),
                "sessions_with_qa": root_with_qa,
                "turns_seen": root_turns,
                "first_day": root_first,
                "last_day": root_last,
            }
        )
    return {
        "sessions_root": str(sessions_root),
        "archived_root": str(archived_root) if archived_root is not None else None,
        "diary_root": str(diary_root),
        "include_archived": include_archived,
        "roots": root_stats,
        "sessions_seen": sum(int(item["sessions_seen"]) for item in root_stats),
        "sessions_with_qa": len(parsed),
        "turns_seen": turn_count,
        "written_files": sorted(written_paths),
        "dry_run": dry_run,
    }


def local_day(timestamp: str) -> str:
    return datetime.fromisoformat(timestamp.replace("Z", "+00:00")).astimezone().date().isoformat()
