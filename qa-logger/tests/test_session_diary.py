import json
import tempfile
import unittest
from pathlib import Path

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
