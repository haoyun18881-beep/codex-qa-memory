# Codex QA Memory

> **让 Codex 不用翻完整 Session，也能自动找回以前的决定、偏好、失败经验、时间和证据位置。**

Codex QA Memory 把全量 QA 日记和小型结构化记忆节点分开保存。日常召回先查小节点，速度快、上下文小；需要原话、日期或 Session（会话）证据时，再通过 CLI 精确定位到对应日记和原始记录。

## 它能帮你得到什么

1. **不用重翻完整 Session**：先从结构化记忆和 QA 日记索引定位答案。
2. **全量 QA 仍然保留**：重要细节没有因为做小节点而丢失。
3. **小节点召回更省上下文**：只把当前任务需要的事实、决定或偏好交给 Agent。
4. **时间和位置可以快速查到**：CLI 能搜索关键词、日期、状态码和来源锚点。
5. **需要时再回原始证据**：先定位，再窄查对应 Session，不做全盘扫描。
6. **每条记忆都能追溯**：节点保留日记、manifest 或其他来源指针。
7. **候选不会自动变成硬规则**：`candidate`、`soft-active`、`active` 三态避免旧记忆直接覆盖当前事实。
8. **自然说话即可自动触发**：说“之前聊过”“你还记得吗”“我们以前怎么处理的”，Codex 会优先走记忆召回。

## 最简单的用法

安装 Skill 后可以直接说：

```text
你还记得我们之前怎么处理这个问题吗
查一下以前关于这个项目的决定
找出当时的日期和证据位置
我要当时的原话和 Session 编号
```

日常自然回忆走 `codex-qa-memory`；需要原话、日期、证据或 Session ID 时，走 `codex-qa-diary-recall`。

CLI 可以快速定位：

```powershell
powershell -ExecutionPolicy Bypass -File .\skills\codex-qa-memory\scripts\qa-mem.ps1 get "关键词"
powershell -ExecutionPolicy Bypass -File .\skills\codex-qa-memory\scripts\qa-mem.ps1 validate -Root .\qa-memory-template
```

## English quick overview

Codex QA Memory combines full local QA diaries with compact structured memory nodes. Codex can retrieve the small relevant fact first, locate dates and source anchors through the CLI, and open the original session only when exact evidence is needed. Natural phrases such as “do you remember?” can trigger the memory skill automatically.

The public package contains no real diary, session, memory node, vector index, log, token, key, cookie, or private project data.

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
