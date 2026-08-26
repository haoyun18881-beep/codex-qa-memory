from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SERVER_PATH = Path(__file__).resolve().parents[1] / "codex_qa_memory_mcp.py"
SPEC = importlib.util.spec_from_file_location("codex_qa_memory_mcp", SERVER_PATH)
assert SPEC and SPEC.loader
MCP = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MCP
SPEC.loader.exec_module(MCP)


class QaMcpFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.memory_root = self.root / ".codex" / "qa-memory"
        self.diary_root = self.root / ".codex" / "qa-diary"
        self.memory_root.mkdir(parents=True)
        self.diary_root.mkdir(parents=True)
        self.config = MCP.ServerConfig(self.memory_root, self.diary_root)

        private_source = self.memory_root / "records" / "2026-08.md"
        rows = [
            "# QA Memory Index",
            "",
            "| node_id | type_code | status_code | scope_code | content | source_ref | record_path |",
            "| --- | ---: | ---: | ---: | --- | --- | --- |",
            f"| N-20260826-001 | 203 | 302 | 400 | Keep memory evidence-backed. | {private_source}#n1 | records/2026-08.md |",
            "| N-20260826-002 | 202 | 300 | 408 | Candidate memory rule. | qa-diary/2026-08-26/general/general.md#candidate | candidates/2026-08.md |",
            "| N-20260826-003 | 204 | 302 | 400 | Temporary task status. | qa-diary/2026-08-26/general/general.md#task | records/2026-08.md |",
            "| N-20260826-004 | 203 | 302 | 402 | Project Atlas decided to use MCP. | projects/atlas.md#mcp | records/2026-08.md |",
            "| N-20260826-005 | 202 | 302 | 400 | Value with escaped \\| pipe and token=super-secret. | qa-memory/records/2026-08.md#pipe | records/2026-08.md |",
            "| N-20260826-006 | 203 | 302 | 402 | collision-marker for a different project. | projects/atlas-secret.md#decision | records/2026-08.md |",
            "| N-20260826-ghp_secretidentifier123 | 203 | 302 | 400 | unsafe-node-id-marker. | qa-memory/records/2026-08.md#unsafe | records/2026-08.md |",
        ]
        (self.memory_root / "03-索引.md").write_text("\n".join(rows) + "\n", encoding="utf-8")

        day = self.diary_root / "2026-08-26"
        target = day / "projects" / "atlas.md"
        target.parent.mkdir(parents=True)
        target.write_text(
            "# Atlas\n\n"
            "## Q 10:00 {#q-demo}\n\n"
            "Q [10:00]:\n\nWhere is the launch evidence?\n\n"
            "A1 [10:01]:\n\nThe launch evidence is here. token=private-value C:\\Users\\Example\\secret.txt\n\n",
            encoding="utf-8",
        )
        meta = day / "_meta"
        meta.mkdir(parents=True)
        good = {
            "session": {
                "id": "019-demo-session",
                "path": "C:\\Users\\Private\\.codex\\sessions\\secret.jsonl",
                "cwd": "C:\\PrivateProject",
            },
            "question_time": "2026-08-26T10:00:00+08:00",
            "answer_times": ["2026-08-26T10:01:00+08:00"],
            "target": "projects/atlas.md",
            "anchor": "q-demo",
            "turn_fingerprint": "demo",
        }
        traversal = {
            "session": {"id": "019-bad-session", "path": "C:\\private.jsonl", "cwd": "C:\\"},
            "question_time": "2026-08-26T11:00:00+08:00",
            "answer_times": [],
            "target": "../outside.md",
            "anchor": "q-bad",
            "turn_fingerprint": "bad",
        }
        (meta / "manifest.jsonl").write_text(
            json.dumps(good, ensure_ascii=False) + "\n" + json.dumps(traversal, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        (day / "_index.md").write_text(
            "# 2026-08-26\n\n## Script Timeline\n\n"
            "| Time | Scope | Topic | File |\n| --- | --- | --- | --- |\n"
            "| 10:00 | Project | launch evidence | `projects/atlas.md` |\n",
            encoding="utf-8",
        )
        sessions = self.root / ".codex" / "sessions"
        sessions.mkdir(parents=True)
        (sessions / "sentinel.jsonl").write_text("RAW_SESSION_SENTINEL launch evidence", encoding="utf-8")

    def tearDown(self) -> None:
        self.temp.cleanup()


class MemoryToolTests(QaMcpFixture):
    def test_recall_defaults_to_safe_active_memory(self) -> None:
        result = MCP.qa_memory_recall({"query": "memory", "mode": "quick"}, self.config)
        ids = {node["node_id"] for node in result["nodes"]}
        self.assertIn("N-20260826-001", ids)
        self.assertNotIn("N-20260826-002", ids)
        self.assertNotIn("N-20260826-003", ids)
        self.assertNotIn("N-20260826-004", ids)
        self.assertLessEqual(result["selected_count"], 6)
        self.assertLessEqual(result["selected_chars"], 1200)
        self.assertEqual(result["source_refs"], ["03-索引.md"])

    def test_candidate_requires_explicit_opt_in(self) -> None:
        result = MCP.qa_memory_recall(
            {"query": "Candidate memory", "mode": "quick", "include_candidates": True}, self.config
        )
        self.assertEqual(result["nodes"][0]["status_label"], "candidate")
        self.assertEqual(result["nodes"][0]["authority"], "candidate_lead_only")

    def test_project_scope_requires_matching_hint(self) -> None:
        hidden = MCP.qa_memory_recall({"query": "Atlas MCP", "mode": "quick"}, self.config)
        self.assertEqual(hidden["nodes"], [])
        broad_hint = MCP.qa_memory_recall(
            {"query": "Atlas MCP", "mode": "quick", "project_hint": "MCP"}, self.config
        )
        self.assertEqual(broad_hint["nodes"], [])
        generic_path_hint = MCP.qa_memory_recall(
            {"query": "Atlas MCP", "mode": "quick", "project_hint": "records"}, self.config
        )
        self.assertEqual(generic_path_hint["nodes"], [])
        visible = MCP.qa_memory_recall(
            {"query": "Atlas MCP", "mode": "quick", "project_hint": "Atlas"}, self.config
        )
        self.assertEqual([node["node_id"] for node in visible["nodes"]], ["N-20260826-004"])
        collision = MCP.qa_memory_recall(
            {"query": "collision-marker", "mode": "quick", "project_hint": "Atlas"}, self.config
        )
        self.assertEqual(collision["nodes"], [])

    def test_first_oversized_node_is_truncated_to_quick_budget(self) -> None:
        index_path = self.memory_root / "03-索引.md"
        with index_path.open("a", encoding="utf-8") as handle:
            handle.write(
                "| N-20260826-999 | 203 | 302 | 400 | oversize-marker "
                + ("x" * 5000)
                + " | qa-memory/records/oversize.md#n | records/oversize.md |\n"
            )
        result = MCP.qa_memory_recall({"query": "oversize-marker", "mode": "quick"}, self.config)
        self.assertEqual(result["selected_count"], 1)
        self.assertTrue(result["nodes"][0]["truncated"])
        self.assertLessEqual(result["selected_chars"], result["budget"]["max_chars"])

    def test_output_redaction_covers_common_credential_shapes(self) -> None:
        raw = (
            "Authorization: Bearer abcdefghijkl\n"
            "Authorization: \"Bearer quoted-auth-secret\"\n"
            "{\"Authorization\":\"Basic json-basic-secret\"}\n"
            "Cookie: sid=cookie-first-secret; csrf=cookie-second-secret\n"
            "access_token=topsecret secret=abcdefghi\n"
            "\"refresh_token\":\"refresh-secret\" \"pwd\":\"pwd-secret\"\n"
            "OPENAI_API_KEY=openai-prefixed-secret \"aws_secret_access_key\":\"aws-prefixed-secret\"\n"
            "passwd=passwd-secret Bearer standalone-secret\n"
            "-----BEGIN PRIVATE KEY-----\nprivate-material\n-----END PRIVATE KEY-----"
        )
        redacted = MCP._redact_output_text(raw)
        for secret in (
            "abcdefghijkl",
            "quoted-auth-secret",
            "json-basic-secret",
            "cookie-first-secret",
            "cookie-second-secret",
            "topsecret",
            "abcdefghi",
            "refresh-secret",
            "pwd-secret",
            "openai-prefixed-secret",
            "aws-prefixed-secret",
            "passwd-secret",
            "standalone-secret",
            "private-material",
        ):
            self.assertNotIn(secret, redacted)

    def test_recall_redacts_secrets_and_absolute_paths(self) -> None:
        result = MCP.qa_memory_recall({"query": "escaped pipe", "mode": "quick"}, self.config)
        serialized = json.dumps(result, ensure_ascii=False)
        self.assertIn("Value with escaped | pipe", serialized)
        self.assertNotIn("super-secret", serialized)
        self.assertNotIn(str(self.memory_root), serialized)
        safe_ref = MCP._safe_reference(
            str(self.memory_root / "records" / "access_token=path-secret.md"), self.config
        )
        self.assertNotIn("path-secret", safe_ref)
        unsafe_id = MCP.qa_memory_recall({"query": "unsafe-node-id-marker", "mode": "quick"}, self.config)
        self.assertEqual(unsafe_id["nodes"], [])

    def test_tool_rejects_hidden_path_arguments(self) -> None:
        with self.assertRaises(MCP.ToolInputError):
            MCP.tool_call("qa_memory_recall", {"root": "C:\\private"}, self.config)

    def test_echoed_query_is_redacted(self) -> None:
        result = MCP.qa_memory_recall({"query": "token=query-secret", "mode": "quick"}, self.config)
        self.assertNotIn("query-secret", json.dumps(result, ensure_ascii=False))


class DiaryToolTests(QaMcpFixture):
    def test_query_returns_sanitized_diary_evidence_only(self) -> None:
        result = MCP.qa_diary_search({"query": "launch evidence", "limit": 5}, self.config)
        serialized = json.dumps(result, ensure_ascii=False)
        self.assertGreaterEqual(result["result_count"], 1)
        self.assertIn("projects/atlas.md", serialized)
        self.assertNotIn("private-value", serialized)
        self.assertNotIn("C:\\Users", serialized)
        self.assertNotIn("RAW_SESSION_SENTINEL", serialized)
        self.assertFalse(result["raw_sessions_scanned"])
        self.assertFalse(result["raw_session_fallback"]["supported"])

    def test_session_lookup_never_returns_manifest_private_paths(self) -> None:
        result = MCP.qa_diary_search({"session_id": "019-demo-session"}, self.config)
        serialized = json.dumps(result, ensure_ascii=False)
        self.assertEqual(result["result_count"], 1)
        self.assertIn("019-demo-session", serialized)
        self.assertNotIn("secret.jsonl", serialized)
        self.assertNotIn("PrivateProject", serialized)

    def test_thread_id_alias_and_source_ref_route(self) -> None:
        by_thread = MCP.qa_diary_search({"thread_id": "019-demo-session"}, self.config)
        self.assertEqual(by_thread["result_count"], 1)
        by_source = MCP.qa_diary_search(
            {"source_ref": "qa-diary/2026-08-26/projects/atlas.md#q-demo"}, self.config
        )
        self.assertEqual(by_source["route"], "source_ref_manifest")
        self.assertEqual(by_source["results"][0]["anchor"], "q-demo")

    def test_source_ref_rejects_absolute_and_conflicting_date(self) -> None:
        with self.assertRaises(MCP.ToolInputError):
            MCP.qa_diary_search({"source_ref": "C:/private.md#q-demo"}, self.config)
        with self.assertRaises(MCP.ToolInputError):
            MCP.qa_diary_search({"source_ref": "//server/share/private.md#q-demo"}, self.config)
        with self.assertRaises(MCP.ToolInputError):
            MCP.qa_diary_search(
                {"source_ref": "qa-diary/2026-08-26/projects/atlas.md:stream#q-demo"}, self.config
            )
        with self.assertRaises(MCP.ToolInputError):
            MCP.qa_diary_search(
                {"source_ref": "qa-diary/2026-08-26/projects/atlas.md#ghp_secretanchor123"}, self.config
            )
        with self.assertRaises(MCP.ToolInputError):
            MCP.qa_diary_search(
                {
                    "source_ref": "qa-diary/2026-08-26/projects/atlas.md#q-demo",
                    "date": "2026-08-25",
                },
                self.config,
            )

    def test_manifest_parent_traversal_is_ignored(self) -> None:
        result = MCP.qa_diary_search({"session_id": "019-bad-session"}, self.config)
        self.assertEqual(result["results"], [])

    def test_invalid_date_cannot_traverse(self) -> None:
        with self.assertRaises(MCP.ToolInputError):
            MCP.qa_diary_search({"date": "../2026-08-26"}, self.config)

    def test_safe_child_rejects_in_root_symlink_component(self) -> None:
        day = self.diary_root / "2026-08-26"
        linked = day / "linked-projects"
        try:
            linked.symlink_to(day / "projects", target_is_directory=True)
        except OSError as exc:
            self.skipTest(f"symlink creation unavailable: {exc}")
        with self.assertRaises(MCP.ToolInputError):
            MCP._safe_child(day, "linked-projects/atlas.md")

    def test_health_is_read_only_and_hides_root_paths(self) -> None:
        before = sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*"))
        result = MCP.qa_memory_health(self.config)
        after = sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*"))
        self.assertEqual(before, after)
        self.assertFalse(result["write_performed"])
        self.assertNotIn(str(self.root), json.dumps(result, ensure_ascii=False))

    def test_manifest_output_fields_are_strictly_sanitized(self) -> None:
        manifest = self.diary_root / "2026-08-26" / "_meta" / "manifest.jsonl"
        records = [json.loads(line) for line in manifest.read_text(encoding="utf-8").splitlines()]
        records[0]["session"]["id"] = "access_token:MANIFEST-SECRET-123"
        records[0]["question_time"] = "access_token=manifest-secret"
        records[0]["answer_times"] = ["pwd=answer-secret", "2026-08-26T10:01:00+08:00"]
        manifest.write_text(
            "\n".join(json.dumps(record, ensure_ascii=False) for record in records) + "\n",
            encoding="utf-8",
        )
        result = MCP.qa_diary_search(
            {"source_ref": "qa-diary/2026-08-26/projects/atlas.md#q-demo"}, self.config
        )
        serialized = json.dumps(result, ensure_ascii=False)
        self.assertIsNone(result["results"][0]["session_id"])
        self.assertIsNone(result["results"][0]["question_time"])
        self.assertEqual(result["results"][0]["answer_times"], ["2026-08-26T10:01:00+08:00"])
        self.assertNotIn("manifest-secret", serialized)
        self.assertNotIn("answer-secret", serialized)
        self.assertNotIn("MANIFEST-SECRET-123", serialized)

    def test_session_and_health_routes_enforce_scan_byte_budget(self) -> None:
        with mock.patch.object(MCP, "MAX_SCAN_BYTES", 1):
            session_result = MCP.qa_diary_search({"session_id": "019-demo-session"}, self.config)
            health_result = MCP.qa_memory_health(self.config)
        self.assertEqual(session_result["stopped_by"], "byte_budget")
        self.assertTrue(health_result["diary"]["scan_truncated"])
        self.assertEqual(health_result["diary"]["scan_stopped_by"], "byte_budget")

    def test_health_not_ready_when_index_cannot_be_parsed(self) -> None:
        with mock.patch.object(MCP, "MAX_INDEX_BYTES", 1):
            result = MCP.qa_memory_health(self.config)
        self.assertFalse(result["ready"])
        self.assertIsNotNone(result["memory"]["error"])

    def test_health_not_ready_when_index_is_symlink(self) -> None:
        index_path = self.memory_root / "03-索引.md"
        target = self.memory_root / "linked-index.md"
        target.write_text(index_path.read_text(encoding="utf-8"), encoding="utf-8")
        index_path.unlink()
        try:
            index_path.symlink_to(target)
        except OSError as exc:
            self.skipTest(f"symlink creation unavailable: {exc}")
        result = MCP.qa_memory_health(self.config)
        self.assertFalse(result["ready"])
        self.assertFalse(result["memory"]["index_exists"])
        self.assertIsNotNone(result["memory"]["error"])


class RpcTests(QaMcpFixture):
    def _initialized_server(self):
        server = MCP.McpServer(self.config)
        response = server.handle(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {"protocolVersion": "2025-11-25"},
            }
        )
        self.assertEqual(response["result"]["protocolVersion"], "2025-11-25")
        server.handle({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        return server

    def test_initialize_negotiates_only_supported_versions(self) -> None:
        server = MCP.McpServer(self.config)
        response = server.handle(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {"protocolVersion": "2099-01-01"},
            }
        )
        self.assertEqual(response["result"]["protocolVersion"], MCP.LATEST_PROTOCOL_VERSION)
        self.assertIn("read-only", response["result"]["instructions"])

    def test_invalid_json_value_does_not_crash_handler(self) -> None:
        server = MCP.McpServer(self.config)
        response = server.handle([])
        self.assertEqual(response["error"]["code"], -32600)
        ping = server.handle({"jsonrpc": "2.0", "id": 2, "method": "ping", "params": {}})
        self.assertEqual(ping["result"], {})

    def test_tools_are_all_annotated_read_only(self) -> None:
        server = self._initialized_server()
        response = server.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        self.assertEqual(len(response["result"]["tools"]), 3)
        for tool in response["result"]["tools"]:
            self.assertTrue(tool["annotations"]["readOnlyHint"])
            self.assertFalse(tool["annotations"]["destructiveHint"])
            self.assertNotIn("root", tool["inputSchema"].get("properties", {}))

    def test_stdio_server_survives_invalid_request(self) -> None:
        process = subprocess.Popen(
            [
                sys.executable,
                str(SERVER_PATH),
                "--memory-root",
                str(self.memory_root),
                "--diary-root",
                str(self.diary_root),
                "serve",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        )
        assert process.stdin and process.stdout
        process.stdin.write("[]\n")
        process.stdin.flush()
        invalid = json.loads(process.stdout.readline())
        self.assertEqual(invalid["error"]["code"], -32600)

        process.stdin.write(("x" * (MCP.MAX_REQUEST_CHARS + 10)) + "\n")
        process.stdin.flush()
        oversized = json.loads(process.stdout.readline())
        self.assertEqual(oversized["error"]["code"], -32700)

        process.stdin.write(
            json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": {"protocolVersion": "2025-11-25"},
                }
            )
            + "\n"
        )
        process.stdin.flush()
        initialized = json.loads(process.stdout.readline())
        self.assertEqual(initialized["result"]["serverInfo"]["name"], MCP.SERVER_NAME)
        process.stdin.write(
            json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}) + "\n"
        )
        process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}) + "\n")
        process.stdin.flush()
        tools = json.loads(process.stdout.readline())
        self.assertEqual(len(tools["result"]["tools"]), 3)
        process.stdin.close()
        process.wait(timeout=5)
        process.stdout.close()
        assert process.stderr
        process.stderr.close()
        self.assertEqual(process.returncode, 0)


if __name__ == "__main__":
    unittest.main()
