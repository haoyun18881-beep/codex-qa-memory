param(
    [int]$PollSeconds = 15,
    [string]$PythonExe = "python",
    [string]$QaLoggerSrc = (Join-Path (Split-Path -Parent $PSScriptRoot) "qa-logger\src"),
    [string]$LogDir = (Join-Path $env:USERPROFILE ".codex\qa-diary\_watcher"),
    [switch]$IncludeArchived,
    [switch]$IncludeCommentary,
    [switch]$Once
)

$ErrorActionPreference = "Stop"

if ($PollSeconds -lt 5) {
    $PollSeconds = 5
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$mutex = [System.Threading.Mutex]::new($false, "Global\CodexQaDiaryWatcher")
$hasLock = $mutex.WaitOne(0)
if (-not $hasLock) {
    $record = [ordered]@{
        timestamp = (Get-Date).ToString("o")
        pid = $PID
        status = "already_running"
    }
    $logPath = Join-Path $LogDir ("watcher-{0}.jsonl" -f (Get-Date -Format "yyyy-MM-dd"))
    Add-Content -LiteralPath $logPath -Value ($record | ConvertTo-Json -Compress)
    exit 0
}

$lastPeriodicLog = Get-Date "2000-01-01"
$env:PYTHONPATH = $QaLoggerSrc

try {
    while ($true) {
        $started = Get-Date
        $args = @("-m", "qa_logger", "scan-sessions")
        if ($IncludeArchived) {
            $args += "--include-archived"
        }
        if ($IncludeCommentary) {
            $args += "--include-commentary"
        }

        $outputLines = @(& $PythonExe @args 2>&1)
        $exitCode = $LASTEXITCODE
        $finished = Get-Date
        $outputText = ($outputLines | Out-String).Trim()

        $summary = $null
        if ($outputText) {
            try {
                $summary = $outputText | ConvertFrom-Json
            } catch {
                $summary = $null
            }
        }

        $writtenCount = 0
        if ($summary -and $summary.written_files) {
            $writtenCount = @($summary.written_files).Count
        }

        $heartbeat = [ordered]@{
            timestamp = $finished.ToString("o")
            pid = $PID
            status = $(if ($exitCode -eq 0) { "ok" } else { "error" })
            exit_code = $exitCode
            poll_seconds = $PollSeconds
            duration_ms = [int](($finished - $started).TotalMilliseconds)
            sessions_seen = $(if ($summary) { $summary.sessions_seen } else { $null })
            sessions_with_qa = $(if ($summary) { $summary.sessions_with_qa } else { $null })
            turns_seen = $(if ($summary) { $summary.turns_seen } else { $null })
            written_files_count = $writtenCount
            written_files = $(if ($summary) { $summary.written_files } else { @() })
        }

        $heartbeatPath = Join-Path $LogDir "heartbeat.json"
        $heartbeat | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $heartbeatPath -Encoding UTF8

        $shouldLog = $exitCode -ne 0 -or $writtenCount -gt 0 -or (($finished - $lastPeriodicLog).TotalMinutes -ge 5)
        if ($shouldLog) {
            $logPath = Join-Path $LogDir ("watcher-{0}.jsonl" -f (Get-Date -Format "yyyy-MM-dd"))
            $record = [ordered]@{
                timestamp = $finished.ToString("o")
                pid = $PID
                exit_code = $exitCode
                duration_ms = [int](($finished - $started).TotalMilliseconds)
                written_files_count = $writtenCount
                summary = $summary
                raw_output = $(if ($summary) { $null } else { $outputText })
            }
            Add-Content -LiteralPath $logPath -Value ($record | ConvertTo-Json -Compress -Depth 8)
            $lastPeriodicLog = $finished
        }

        if ($exitCode -eq 0) {
            if ($Once) {
                break
            }
            Start-Sleep -Seconds $PollSeconds
        } else {
            if ($Once) {
                break
            }
            Start-Sleep -Seconds ([Math]::Max($PollSeconds, 30))
        }
    }
} finally {
    if ($hasLock) {
        $mutex.ReleaseMutex() | Out-Null
    }
    $mutex.Dispose()
}
