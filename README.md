# Codex QA Memory

Codex QA Memory is a local-first toolkit for turning Codex conversations into durable QA diaries and then into small, structured memory nodes that an agent can retrieve without rereading full chat history.

It includes:

- `qa-logger`: a Python CLI that scans local Codex session JSONL and writes Markdown QA diaries.
- `scripts`: Windows PowerShell watcher/supervisor helpers for automatic local syncing.
- `skills/codex-qa-memory`: a Codex Skill for structured memory retrieval, candidate generation, validation, and maintenance.
- `skills/codex-qa-diary-recall`: a Codex Skill for evidence lookup when exact wording, dates, session IDs, or diary anchors are needed.
- `qa-memory-template`: a sanitized starter layout for Markdown + JSONL memory storage.

No real diary, session, memory node, vector index, log, token, key, cookie, or private project data is included.

## Why This Exists

Long-running agent work fails when history only exists as giant chat logs. A useful memory system needs both:

- **store（存）**: save the right facts, decisions, preferences, failures, sources, and relationships in small nodes;
- **retrieve（取）**: return only the small relevant slice for the current task.

This project keeps those layers separate:

1. Raw Codex sessions stay private.
2. QA Logger turns user/assistant turns into readable daily Markdown.
3. QA Memory converts selected diary facts into small candidate/active nodes.
4. CLI tools filter, validate, rank, and decode nodes before an LLM sees them.
5. Skills tell Codex when to use memory first and when to fall back to exact diary evidence.

## What Makes It Different

- **Local-first（本地优先）**: defaults to `%USERPROFILE%\.codex`, no hosted service.
- **Evidence-backed（证据可追溯）**: memory nodes keep source pointers back to diaries or manifests.
- **Small-node design（小节点设计）**: retrieval returns compact facts with type/status/scope codes plus Chinese labels.
- **Three-state memory（三态记忆）**: `candidate` is a lead, `soft-active` is low-risk contextual memory, `active` is current usable memory.
- **No automatic rule promotion（不自动提升硬规则）**: automation can generate candidates and indexes, but high-impact rules require human/main-thread review.
- **Skill split（Skill 分工清楚）**: `codex-qa-memory` is the default memory entrance; `codex-qa-diary-recall` is the evidence room.

## Architecture

```text
Codex sessions
  -> qa-logger scan-sessions
  -> qa-diary/YYYY-MM-DD/
  -> qa_memory_maintain.ps1
  -> qa-memory machine/*.jsonl + Markdown records
  -> qa-mem.ps1 get/graph/validate
  -> Codex Skill short recall packet
```

## Install

Clone the repository:

```powershell
git clone https://github.com/haoyun18881-beep/codex-qa-memory.git
cd codex-qa-memory
```

Run the Python logger in dry-run mode first:

```powershell
$env:PYTHONPATH="$PWD\qa-logger\src"
python -m qa_logger scan-sessions --dry-run
```

After reviewing the count, write local diaries:

```powershell
python -m qa_logger scan-sessions
```

Optional archived scan:

```powershell
python -m qa_logger scan-sessions --include-archived --dry-run
python -m qa_logger scan-sessions --include-archived
```

## Default Paths

The Python logger defaults to:

```text
read:  %USERPROFILE%\.codex\sessions
read:  %USERPROFILE%\.codex\archived_sessions  (only with --include-archived)
write: %USERPROFILE%\.codex\qa-diary
```

The QA memory CLI defaults to:

```text
%USERPROFILE%\.codex\qa-memory
```

You can override paths with CLI parameters such as `--sessions-root`, `--diary-root`, `-Root`, `-DiaryRoot`, and `-MemoryRoot`.

## Skills

Copy these folders into your Codex skills directory if you want Codex to use the workflow:

```text
skills/codex-qa-memory
skills/codex-qa-diary-recall
```

Use this split:

- `codex-qa-memory`: natural recall, long-term preferences, rules, failures, project history, small nodes, candidate review.
- `codex-qa-diary-recall`: exact quotes, dates, session/thread IDs, original diary evidence, manifest lookup.

Natural phrases like "do you remember", "we discussed before", or "what did we decide earlier" should hit `codex-qa-memory` first. Exact evidence requests should fall through to `codex-qa-diary-recall`.

## CLI Examples

```powershell
powershell -ExecutionPolicy Bypass -File .\skills\codex-qa-memory\scripts\qa-mem.ps1 get -Root .\qa-memory-template -Mode quick
powershell -ExecutionPolicy Bypass -File .\skills\codex-qa-memory\scripts\qa-mem.ps1 validate -Root .\qa-memory-template
powershell -ExecutionPolicy Bypass -File .\skills\codex-qa-memory\scripts\qa_memory_maintain.ps1 -DiaryRoot "%USERPROFILE%\.codex\qa-diary" -MemoryRoot "%USERPROFILE%\.codex\qa-memory"
```

## Automatic Maintenance

The included PowerShell scripts can run a hidden watcher/supervisor on Windows. They are optional.

- `codex_qa_diary_watcher.ps1`: periodically runs `python -m qa_logger scan-sessions`.
- `codex_qa_diary_supervisor.ps1`: starts the watcher only while Codex is running.
- `install_codex_qa_diary_watcher_task.ps1`: installs a hidden logon scheduled task.
- `stop_codex_qa_diary_watcher_task.ps1`: stops or unregisters it.

The maintenance script does not promote hard rules automatically. It can create candidates, aliases, audit records, and reports; final promotion is still a human/main-thread decision.

## Optional Memory-Recall Extension Pattern

You can extend this toolkit into per-turn memory recall, but it needs your own components:

- a conversation logger or QA diary store;
- an embedding model, local or remote;
- a vector index/database/search service;
- a retrieval step before each model request;
- a small formatter that injects only short, source-marked snippets.

Dynamic memory injection is less prompt-cache friendly than a stable prefix. Use it when recall quality matters more than maximum cache reuse.

## Package Boundary

This repository intentionally excludes:

- real `.codex/qa-diary` content;
- real `.codex/qa-memory` records;
- raw `.codex/sessions` or archived sessions;
- vector indexes and databases;
- watcher logs and heartbeats;
- tokens, cookies, API keys, account files, or private exports.

## Validation

```powershell
npm run test:python
npm run memory:validate
npm pack --dry-run
```

## License

BUSL-1.1. See [LICENSE](LICENSE).
