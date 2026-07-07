# Codex QA Logger

Python CLI for converting local Codex session JSONL into readable Markdown QA diaries.

## What It Does

- Reads local Codex session files.
- Extracts main user questions and assistant answers.
- Skips common sub-agent notifications and tool/log noise.
- Writes daily Markdown diaries plus a manifest for dedupe and evidence lookup.
- Applies basic redaction for common secret shapes before persistence.

## Dry Run

```powershell
$env:PYTHONPATH="$PWD\qa-logger\src"
python -m qa_logger scan-sessions --dry-run
```

## Write Diaries

```powershell
python -m qa_logger scan-sessions
```

Defaults:

```text
read:  %USERPROFILE%\.codex\sessions
read:  %USERPROFILE%\.codex\archived_sessions  (only with --include-archived)
write: %USERPROFILE%\.codex\qa-diary
```

## Compact Old Diaries

```powershell
python -m qa_logger compact-diary --start-day 2026-01-01 --end-day 2026-01-31 --dry-run
python -m qa_logger compact-diary --start-day 2026-01-01 --end-day 2026-01-31
```

Real compaction creates a backup before rewriting selected days.
