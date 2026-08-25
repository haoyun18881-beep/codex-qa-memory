import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from qa_logger.cli import scan_sessions
from qa_logger.diary import compact_answer_text
from qa_logger.history_compactor import compact_diary
from qa_logger.session_reader import parse_session_file


class SessionDiaryTests(unittest.TestCase):
    def test_parse_main_session_turns_and_skip_subagent_notification(self):
        fixture = Path(__file__).parents[1] / "samples" / "session.safe.jsonl"
        session = parse_session_file(fixture)

        self.assertIsNotNone(session)
        assert session is not None
        self.assertEqual(session.meta.thread_source, "user")
        self.assertEqual(len(session.turns), 2)
        self.assertEqual(len(session.turns[0].answers), 1)
        self.assertEqual(session.turns[0].answers[0].phase, "final_answer")
        self.assertTrue(session.turns[1].answers[0].provisional)

    def test_scan_writes_daily_project_diary_and_index_without_duplicates(self):
        fixture = Path(__file__).parents[1] / "samples" / "session.safe.jsonl"
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            sessions_dir = root / "sessions" / "2026" / "06" / "27"
            sessions_dir.mkdir(parents=True)
            (sessions_dir / "rollout-demo.jsonl").write_text(fixture.read_text(encoding="utf-8"), encoding="utf-8")
            diary_root = root / "qa-diary"

            first = scan_sessions(sessions_dir, diary_root)
            second = scan_sessions(sessions_dir, diary_root)

            self.assertEqual(first["turns_seen"], 2)
            self.assertEqual(second["turns_seen"], 2)
            self.assertEqual(second["written_files"], [])
            project_files = list((diary_root / "2026-06-27" / "projects").glob("*.md"))
            self.assertEqual(len(project_files), 1)
            rendered = project_files[0].read_text(encoding="utf-8")
            self.assertEqual(rendered.count("## Q "), 2)
            self.assertIn("provisional", rendered)
            index_path = diary_root / "2026-06-27" / "_index.md"
            index = index_path.read_text(encoding="utf-8")
            self.assertIn("## Main-Agent Summary", index)
            self.assertIn("## Script Timeline", index)
            self.assertIn("我们要把 Codex QA 日记设计成什么样？", index)
            index_path.write_text(
                index.replace(
                    "<!-- 手动让主 Agent 在这里写当天复盘摘要；脚本不会改这一节。 -->",
                    "今天确认 Codex QA 日记采用自动提取 Q/A。",
                ),
                encoding="utf-8",
            )
            scan_sessions(sessions_dir, diary_root)
            preserved = index_path.read_text(encoding="utf-8")
            self.assertIn("今天确认 Codex QA 日记采用自动提取 Q/A。", preserved)
            before_mtime = index_path.stat().st_mtime_ns
            scan_sessions(sessions_dir, diary_root)
            self.assertEqual(index_path.stat().st_mtime_ns, before_mtime)
            manifest_lines = (diary_root / "2026-06-27" / "_meta" / "manifest.jsonl").read_text(
                encoding="utf-8"
            ).splitlines()
            records = [json.loads(line) for line in manifest_lines]
            self.assertEqual(len(records), 2)

    def test_cross_session_fork_dedupes_by_original_turn_identity(self):
        fixture = Path(__file__).parents[1] / "samples" / "session.safe.jsonl"
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            sessions_dir = root / "sessions"
            sessions_dir.mkdir()
            original = fixture.read_text(encoding="utf-8")
            (sessions_dir / "rollout-one.jsonl").write_text(original, encoding="utf-8")
            forked = original.replace(
                "00000000-0000-0000-0000-000000000001",
                "00000000-0000-0000-0000-000000000099",
            )
            (sessions_dir / "rollout-two.jsonl").write_text(forked, encoding="utf-8")

            diary_root = root / "qa-diary"
            scan_sessions(sessions_dir, diary_root)

            manifest = diary_root / "2026-06-27" / "_meta" / "manifest.jsonl"
            self.assertEqual(len(manifest.read_text(encoding="utf-8").splitlines()), 2)

    def test_first_session_meta_remains_authoritative_for_subagent(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "subagent.jsonl"
            rows = [
                {
                    "timestamp": "2026-07-16T10:00:00+08:00",
                    "type": "session_meta",
                    "payload": {
                        "id": "subagent-id",
                        "thread_source": "subagent",
                        "source": {"subagent": {"depth": 1}},
                    },
                },
                {
                    "timestamp": "2026-07-16T10:00:01+08:00",
                    "type": "session_meta",
                    "payload": {"id": "parent-id", "thread_source": "user", "source": "vscode"},
                },
                {
                    "timestamp": "2026-07-16T10:01:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "user_message", "message": "delegated task"},
                },
                {
                    "timestamp": "2026-07-16T10:02:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "agent_message", "message": "done", "phase": "final_answer"},
                },
            ]
            path.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
            self.assertIsNone(parse_session_file(path))

    def test_incremental_state_reads_only_new_tail(self):
        fixture = Path(__file__).parents[1] / "samples" / "session.safe.jsonl"
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            sessions_dir = root / "sessions"
            sessions_dir.mkdir()
            session_path = sessions_dir / "rollout-incremental.jsonl"
            lines = fixture.read_text(encoding="utf-8").splitlines()
            session_path.write_text("\n".join(lines[:4]) + "\n", encoding="utf-8")
            diary_root = root / "qa-diary"
            state_path = root / "state" / "scan-state.json"

            first = scan_sessions(sessions_dir, diary_root, state_path=state_path)
            second = scan_sessions(sessions_dir, diary_root, state_path=state_path)
            self.assertEqual(first["turns_seen"], 1)
            self.assertEqual(second["sessions_processed"], 0)

            appended = [
                {
                    "timestamp": "2026-06-27T20:07:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "user_message", "message": "增量问题"},
                },
                {
                    "timestamp": "2026-06-27T20:08:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "agent_message", "message": "增量答案", "phase": "final_answer"},
                },
            ]
            with session_path.open("a", encoding="utf-8") as handle:
                for row in appended:
                    handle.write(json.dumps(row, ensure_ascii=False) + "\n")

            third = scan_sessions(sessions_dir, diary_root, state_path=state_path)
            self.assertEqual(third["turns_seen"], 1)
            manifest = diary_root / "2026-06-27" / "_meta" / "manifest.jsonl"
            self.assertEqual(len(manifest.read_text(encoding="utf-8").splitlines()), 2)

    def test_incremental_state_does_not_commit_partial_jsonl_tail(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            sessions_dir = root / "sessions"
            sessions_dir.mkdir()
            session_path = sessions_dir / "rollout-partial.jsonl"
            rows = [
                {
                    "timestamp": "2026-07-16T10:00:00+08:00",
                    "type": "session_meta",
                    "payload": {"id": "main-id", "thread_source": "user"},
                },
                {
                    "timestamp": "2026-07-16T10:01:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "user_message", "message": "partial tail question"},
                },
            ]
            final_row = {
                "timestamp": "2026-07-16T10:02:00+08:00",
                "type": "event_msg",
                "payload": {"type": "agent_message", "message": "complete final answer", "phase": "final_answer"},
            }
            prefix = ("\n".join(json.dumps(row) for row in rows) + "\n").encode("utf-8")
            final_bytes = json.dumps(final_row).encode("utf-8")
            split_at = len(final_bytes) // 2
            session_path.write_bytes(prefix + final_bytes[:split_at])

            diary_root = root / "qa-diary"
            state_path = root / "state" / "scan-state.json"
            first = scan_sessions(
                sessions_dir,
                diary_root,
                state_path=state_path,
                provisional_after_seconds=0,
            )

            self.assertEqual(first["turns_seen"], 0)
            self.assertFalse((diary_root / "2026-07-16" / "_meta" / "manifest.jsonl").exists())
            state = json.loads(state_path.read_text(encoding="utf-8"))
            file_state = next(iter(state["files"].values()))
            self.assertLess(file_state["committed_offset"], session_path.stat().st_size)
            unchanged = scan_sessions(sessions_dir, diary_root, state_path=state_path)
            self.assertEqual(unchanged["sessions_processed"], 0)

            with session_path.open("ab") as handle:
                handle.write(final_bytes[split_at:] + b"\n")

            second = scan_sessions(sessions_dir, diary_root, state_path=state_path)
            third = scan_sessions(sessions_dir, diary_root, state_path=state_path)
            manifest = diary_root / "2026-07-16" / "_meta" / "manifest.jsonl"
            rendered = (diary_root / "2026-07-16" / "general" / "general.md").read_text(encoding="utf-8")
            self.assertEqual(second["turns_seen"], 1)
            self.assertEqual(third["sessions_processed"], 0)
            self.assertEqual(len(manifest.read_text(encoding="utf-8").splitlines()), 1)
            self.assertIn("complete final answer", rendered)

    def test_incremental_waits_for_delayed_final_instead_of_writing_provisional(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            sessions_dir = root / "sessions"
            sessions_dir.mkdir()
            session_path = sessions_dir / "rollout-delayed-final.jsonl"
            rows = [
                {
                    "timestamp": "2026-07-16T11:00:00+08:00",
                    "type": "session_meta",
                    "payload": {"id": "main-id", "thread_source": "user"},
                },
                {
                    "timestamp": "2026-07-16T11:01:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "user_message", "message": "delayed final question"},
                },
                {
                    "timestamp": "2026-07-16T11:02:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "agent_message", "message": "temporary commentary", "phase": "commentary"},
                },
            ]
            session_path.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")

            diary_root = root / "qa-diary"
            state_path = root / "state" / "scan-state.json"
            first = scan_sessions(
                sessions_dir,
                diary_root,
                state_path=state_path,
                provisional_after_seconds=0,
            )

            self.assertEqual(first["turns_seen"], 0)
            self.assertFalse((diary_root / "2026-07-16" / "_meta" / "manifest.jsonl").exists())

            final_row = {
                "timestamp": "2026-07-16T11:08:00+08:00",
                "type": "event_msg",
                "payload": {"type": "agent_message", "message": "delayed final answer", "phase": "final_answer"},
            }
            with session_path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(final_row) + "\n")

            second = scan_sessions(sessions_dir, diary_root, state_path=state_path)
            third = scan_sessions(sessions_dir, diary_root, state_path=state_path)
            manifest = diary_root / "2026-07-16" / "_meta" / "manifest.jsonl"
            rendered = (diary_root / "2026-07-16" / "general" / "general.md").read_text(encoding="utf-8")
            self.assertEqual(second["turns_seen"], 1)
            self.assertEqual(third["sessions_processed"], 0)
            self.assertEqual(len(manifest.read_text(encoding="utf-8").splitlines()), 1)
            self.assertIn("delayed final answer", rendered)
            self.assertNotIn("temporary commentary", rendered)
            self.assertNotIn("provisional", rendered)

    def test_incremental_accepts_complete_final_without_trailing_newline(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            sessions_dir = root / "sessions"
            sessions_dir.mkdir()
            session_path = sessions_dir / "rollout-no-final-lf.jsonl"
            rows = [
                {
                    "timestamp": "2026-07-16T12:00:00+08:00",
                    "type": "session_meta",
                    "payload": {"id": "main-id", "thread_source": "user"},
                },
                {
                    "timestamp": "2026-07-16T12:01:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "user_message", "message": "no LF question"},
                },
                {
                    "timestamp": "2026-07-16T12:02:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "agent_message", "message": "no LF final", "phase": "final_answer"},
                },
            ]
            session_path.write_text("\n".join(json.dumps(row) for row in rows), encoding="utf-8")

            diary_root = root / "qa-diary"
            state_path = root / "state" / "scan-state.json"
            first = scan_sessions(sessions_dir, diary_root, state_path=state_path)
            second = scan_sessions(sessions_dir, diary_root, state_path=state_path)

            manifest = diary_root / "2026-07-16" / "_meta" / "manifest.jsonl"
            rendered = (diary_root / "2026-07-16" / "general" / "general.md").read_text(encoding="utf-8")
            self.assertEqual(first["turns_seen"], 1)
            self.assertEqual(second["sessions_processed"], 0)
            self.assertEqual(len(manifest.read_text(encoding="utf-8").splitlines()), 1)
            self.assertIn("no LF final", rendered)

    def test_legacy_pending_state_is_migrated_even_when_file_is_unchanged(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            sessions_dir = root / "sessions"
            sessions_dir.mkdir()
            session_path = sessions_dir / "rollout-legacy-state.jsonl"
            rows = [
                {
                    "timestamp": "2026-07-16T12:10:00+08:00",
                    "type": "session_meta",
                    "payload": {"id": "main-id", "thread_source": "user"},
                },
                {
                    "timestamp": "2026-07-16T12:11:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "user_message", "message": "legacy pending question"},
                },
                {
                    "timestamp": "2026-07-16T12:12:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "agent_message", "message": "legacy final", "phase": "final_answer"},
                },
            ]
            encoded = [json.dumps(row).encode("utf-8") for row in rows]
            session_path.write_bytes(b"\n".join(encoded))
            stat = session_path.stat()
            user_offset = len(encoded[0]) + 1
            state_path = root / "state" / "scan-state.json"
            state_path.parent.mkdir()
            state_path.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "files": {
                            str(session_path.resolve()).lower(): {
                                "committed_offset": user_offset,
                                "size": stat.st_size,
                                "mtime_ns": stat.st_mtime_ns,
                                "pending_turn": True,
                                "thread_source": "user",
                            }
                        },
                    }
                ),
                encoding="utf-8",
            )

            diary_root = root / "qa-diary"
            result = scan_sessions(sessions_dir, diary_root, state_path=state_path)
            migrated = json.loads(state_path.read_text(encoding="utf-8"))
            file_state = next(iter(migrated["files"].values()))

            self.assertEqual(result["turns_seen"], 1)
            self.assertEqual(file_state["incremental_version"], 2)
            self.assertEqual(file_state["committed_offset"], stat.st_size)
            self.assertFalse(file_state["pending_turn"])

    def test_pending_reload_failure_is_fail_closed(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            sessions_dir = root / "sessions"
            sessions_dir.mkdir()
            session_path = sessions_dir / "rollout-reload-bound.jsonl"
            rows = [
                {
                    "timestamp": "2026-07-16T12:20:00+08:00",
                    "type": "session_meta",
                    "payload": {"id": "main-id", "thread_source": "user"},
                },
                {
                    "timestamp": "2026-07-16T12:21:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "user_message", "message": "q" * 512},
                },
            ]
            encoded = [json.dumps(row).encode("utf-8") for row in rows]
            initial = b"\n".join(encoded) + b"\n"
            session_path.write_bytes(initial)
            state_path = root / "state" / "scan-state.json"
            state_path.parent.mkdir()
            user_offset = len(encoded[0]) + 1
            state = {
                "version": 1,
                "files": {
                    str(session_path.resolve()).lower(): {
                        "committed_offset": len(initial),
                        "size": len(initial),
                        "mtime_ns": session_path.stat().st_mtime_ns,
                        "pending_turn": True,
                        "pending_turn_offset": user_offset,
                        "pending_commentary_offset": None,
                        "thread_source": "user",
                        "incremental_version": 2,
                    }
                },
            }
            state_path.write_text(json.dumps(state), encoding="utf-8")
            final_row = {
                "timestamp": "2026-07-16T12:22:00+08:00",
                "type": "event_msg",
                "payload": {"type": "agent_message", "message": "must not be lost", "phase": "final_answer"},
            }
            with session_path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(final_row) + "\n")

            diary_root = root / "qa-diary"
            before_state = state_path.read_text(encoding="utf-8")
            with patch("qa_logger.session_reader.MAX_PENDING_EVENT_BYTES", 128):
                with self.assertRaises(RuntimeError):
                    scan_sessions(sessions_dir, diary_root, state_path=state_path)
            self.assertEqual(state_path.read_text(encoding="utf-8"), before_state)
            self.assertFalse((diary_root / "2026-07-16" / "_meta" / "manifest.jsonl").exists())

    def test_pending_tool_tail_advances_cursor_and_unchanged_scan_is_zero(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            sessions_dir = root / "sessions"
            sessions_dir.mkdir()
            session_path = sessions_dir / "rollout-long-pending.jsonl"
            rows = [
                {
                    "timestamp": "2026-07-16T13:00:00+08:00",
                    "type": "session_meta",
                    "payload": {"id": "main-id", "thread_source": "user"},
                },
                {
                    "timestamp": "2026-07-16T13:01:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "user_message", "message": "long pending question"},
                },
                {
                    "timestamp": "2026-07-16T13:02:00+08:00",
                    "type": "response_item",
                    "payload": {"type": "tool_output", "blob": "x" * (2 * 1024 * 1024)},
                },
            ]
            session_path.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")

            diary_root = root / "qa-diary"
            state_path = root / "state" / "scan-state.json"
            first = scan_sessions(sessions_dir, diary_root, state_path=state_path)
            second = scan_sessions(sessions_dir, diary_root, state_path=state_path)
            state = json.loads(state_path.read_text(encoding="utf-8"))
            file_state = next(iter(state["files"].values()))

            self.assertEqual(first["turns_seen"], 0)
            self.assertGreater(first["bytes_read"], 2 * 1024 * 1024)
            self.assertEqual(second["sessions_processed"], 0)
            self.assertEqual(second["bytes_read"], 0)
            self.assertEqual(file_state["committed_offset"], session_path.stat().st_size)
            self.assertTrue(file_state["pending_turn"])
            self.assertIsInstance(file_state["pending_turn_offset"], int)

    def test_pending_commentary_is_reloaded_when_next_user_closes_turn(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            sessions_dir = root / "sessions"
            sessions_dir.mkdir()
            session_path = sessions_dir / "rollout-pending-commentary.jsonl"
            initial = [
                {
                    "timestamp": "2026-07-16T14:00:00+08:00",
                    "type": "session_meta",
                    "payload": {"id": "main-id", "thread_source": "user"},
                },
                {
                    "timestamp": "2026-07-16T14:01:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "user_message", "message": "abandoned question"},
                },
                {
                    "timestamp": "2026-07-16T14:02:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "agent_message", "message": "last useful commentary", "phase": "commentary"},
                },
            ]
            session_path.write_text("\n".join(json.dumps(row) for row in initial) + "\n", encoding="utf-8")
            diary_root = root / "qa-diary"
            state_path = root / "state" / "scan-state.json"
            first = scan_sessions(sessions_dir, diary_root, state_path=state_path)
            self.assertEqual(first["turns_seen"], 0)

            appended = [
                {
                    "timestamp": "2026-07-16T14:03:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "user_message", "message": "next question"},
                },
                {
                    "timestamp": "2026-07-16T14:04:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "agent_message", "message": "next final", "phase": "final_answer"},
                },
            ]
            with session_path.open("a", encoding="utf-8") as handle:
                for row in appended:
                    handle.write(json.dumps(row) + "\n")

            second = scan_sessions(sessions_dir, diary_root, state_path=state_path)
            manifest = diary_root / "2026-07-16" / "_meta" / "manifest.jsonl"
            rendered = (diary_root / "2026-07-16" / "general" / "general.md").read_text(encoding="utf-8")
            self.assertEqual(second["turns_seen"], 2)
            self.assertEqual(len(manifest.read_text(encoding="utf-8").splitlines()), 2)
            self.assertIn("last useful commentary", rendered)
            self.assertIn("provisional", rendered)
            self.assertIn("next final", rendered)

    def test_subagent_notification_does_not_close_pending_main_turn(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            sessions_dir = root / "sessions"
            sessions_dir.mkdir()
            session_path = sessions_dir / "rollout-parallel-notification.jsonl"
            initial = [
                {
                    "timestamp": "2026-07-16T15:00:00+08:00",
                    "type": "session_meta",
                    "payload": {"id": "main-id", "thread_source": "user"},
                },
                {
                    "timestamp": "2026-07-16T15:01:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "user_message", "message": "parallel main question"},
                },
                {
                    "timestamp": "2026-07-16T15:02:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "agent_message", "message": "working", "phase": "commentary"},
                },
            ]
            session_path.write_text("\n".join(json.dumps(row) for row in initial) + "\n", encoding="utf-8")
            diary_root = root / "qa-diary"
            state_path = root / "state" / "scan-state.json"
            first = scan_sessions(sessions_dir, diary_root, state_path=state_path)
            self.assertEqual(first["turns_seen"], 0)

            appended = [
                {
                    "timestamp": "2026-07-16T15:03:00+08:00",
                    "type": "event_msg",
                    "payload": {
                        "type": "user_message",
                        "message": "<subagent_notification>child done</subagent_notification>",
                    },
                },
                {
                    "timestamp": "2026-07-16T15:04:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "agent_message", "message": "authoritative main final", "phase": "final_answer"},
                },
            ]
            with session_path.open("a", encoding="utf-8") as handle:
                for row in appended:
                    handle.write(json.dumps(row) + "\n")

            second = scan_sessions(sessions_dir, diary_root, state_path=state_path)
            full = parse_session_file(session_path)
            manifest = diary_root / "2026-07-16" / "_meta" / "manifest.jsonl"
            rendered = (diary_root / "2026-07-16" / "general" / "general.md").read_text(encoding="utf-8")
            self.assertEqual(second["turns_seen"], 1)
            self.assertEqual(len(manifest.read_text(encoding="utf-8").splitlines()), 1)
            self.assertIn("authoritative main final", rendered)
            self.assertNotIn(" provisional", rendered)
            self.assertIsNotNone(full)
            assert full is not None
            self.assertEqual(len(full.turns), 1)
            self.assertEqual(full.turns[0].answers[-1].phase, "final_answer")

    def test_machine_injected_environment_message_is_skipped(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "environment.jsonl"
            rows = [
                {
                    "timestamp": "2026-07-16T10:00:00+08:00",
                    "type": "session_meta",
                    "payload": {"id": "main-id", "thread_source": "user"},
                },
                {
                    "timestamp": "2026-07-16T10:01:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "user_message", "message": "<environment_context>machine</environment_context>"},
                },
                {
                    "timestamp": "2026-07-16T10:02:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "agent_message", "message": "ignored", "phase": "final_answer"},
                },
                {
                    "timestamp": "2026-07-16T10:03:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "user_message", "message": "真实问题"},
                },
                {
                    "timestamp": "2026-07-16T10:04:00+08:00",
                    "type": "event_msg",
                    "payload": {"type": "agent_message", "message": "真实回答", "phase": "final_answer"},
                },
            ]
            path.write_text("\n".join(json.dumps(row, ensure_ascii=False) for row in rows) + "\n", encoding="utf-8")
            session = parse_session_file(path)
            self.assertIsNotNone(session)
            assert session is not None
            self.assertEqual([turn.question for turn in session.turns], ["真实问题"])

    def test_scan_can_include_archived_root(self):
        fixture = Path(__file__).parents[1] / "samples" / "session.safe.jsonl"
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            sessions_dir = root / "sessions"
            archived_dir = root / "archived_sessions"
            sessions_dir.mkdir()
            archived_dir.mkdir()
            (sessions_dir / "rollout-current.jsonl").write_text(fixture.read_text(encoding="utf-8"), encoding="utf-8")
            archived_text = fixture.read_text(encoding="utf-8").replace(
                "00000000-0000-0000-0000-000000000001",
                "00000000-0000-0000-0000-000000000002",
            )
            (archived_dir / "rollout-archived.jsonl").write_text(archived_text, encoding="utf-8")
            diary_root = root / "qa-diary"

            current_only = scan_sessions(sessions_dir, diary_root, archived_root=archived_dir, dry_run=True)
            with_archived = scan_sessions(
                sessions_dir,
                diary_root,
                archived_root=archived_dir,
                include_archived=True,
                dry_run=True,
            )

            self.assertEqual(current_only["sessions_seen"], 1)
            self.assertEqual(current_only["turns_seen"], 2)
            self.assertEqual(with_archived["sessions_seen"], 2)
            self.assertEqual(with_archived["turns_seen"], 4)
            self.assertEqual(with_archived["roots"][1]["label"], "archived_sessions")

    def test_compact_answer_text_keeps_head_tail_and_marks_omission(self):
        long_answer = "\n".join(f"line {index:03d}" for index in range(80))

        compact = compact_answer_text(long_answer)
        compact_provisional = compact_answer_text(long_answer, provisional=True)

        self.assertIn("line 000", compact)
        self.assertIn("line 079", compact)
        self.assertIn("Diary retention", compact)
        self.assertLess(len(compact), len(long_answer))
        self.assertIn("line 000", compact_provisional)
        self.assertIn("line 079", compact_provisional)
        self.assertIn("Diary retention", compact_provisional)
        self.assertLess(len(compact_provisional), len(compact))

    def test_compact_diary_dry_run_backup_and_preserve_index(self):
        long_answer = "\n".join(f"line {index:03d}" for index in range(80))
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            day_dir = root / "qa-diary" / "2026-06-27"
            project_dir = day_dir / "projects"
            project_dir.mkdir(parents=True)
            project_path = project_dir / "Demo.md"
            project_path.write_text(
                "# Demo\n\n"
                "## Q 10:00 {#q-demo}\n\n"
                "Q [10:00]:\n\n"
                "测试历史压缩\n\n"
                "A1 [10:01]:\n\n"
                f"{long_answer}\n\n",
                encoding="utf-8",
            )
            index_path = day_dir / "_index.md"
            index_path.write_text(
                "# 2026-06-27\n\n"
                "## Main-Agent Summary\n\n"
                "手写摘要。\n\n"
                "## Script Timeline\n\n"
                "| Time | Scope | Topic | File |\n",
                encoding="utf-8",
            )

            dry = compact_diary(root / "qa-diary", "2026-06-27", "2026-06-27", dry_run=True)
            self.assertEqual(dry["files_changed"], 1)
            self.assertEqual(dry["answers_changed"], 1)
            self.assertNotIn("Diary retention", project_path.read_text(encoding="utf-8"))

            backup_root = root / "backup"
            real = compact_diary(
                root / "qa-diary",
                "2026-06-27",
                "2026-06-27",
                dry_run=False,
                backup_root=backup_root,
            )

            rendered = project_path.read_text(encoding="utf-8")
            self.assertIn("Diary retention", rendered)
            self.assertIn("line 000", rendered)
            self.assertIn("line 079", rendered)
            self.assertEqual(index_path.read_text(encoding="utf-8").count("手写摘要。"), 1)
            self.assertTrue((backup_root / "2026-06-27" / "projects" / "Demo.md").exists())
            self.assertEqual(real["files_changed"], 1)

            second_dry = compact_diary(root / "qa-diary", "2026-06-27", "2026-06-27", dry_run=True)
            self.assertEqual(second_dry["files_changed"], 0)


if __name__ == "__main__":
    unittest.main()
