param(
    [int]$PollSeconds = 10,
    [int]$WatcherPollSeconds = 120,
    [string]$WatcherScript = (Join-Path $PSScriptRoot "codex_qa_diary_watcher.ps1"),
    [string]$LogDir = (Join-Path $env:USERPROFILE ".codex\qa-diary\_watcher"),
    [switch]$Once
)

$ErrorActionPreference = "Stop"

if ($PollSeconds -lt 5) {
    $PollSeconds = 5
}

if ($WatcherPollSeconds -lt 5) {
    $WatcherPollSeconds = 5
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$mutex = [System.Threading.Mutex]::new($false, "Global\CodexQaDiarySupervisor")
$hasLock = $mutex.WaitOne(0)
if (-not $hasLock) {
    $record = [ordered]@{
        timestamp = (Get-Date).ToString("o")
        pid = $PID
        status = "already_running"
    }
    $logPath = Join-Path $LogDir ("supervisor-{0}.jsonl" -f (Get-Date -Format "yyyy-MM-dd"))
    Add-Content -LiteralPath $logPath -Value ($record | ConvertTo-Json -Compress)
    exit 0
}

function Write-SupervisorLog {
    param(
        [string]$Status,
        [hashtable]$Extra = @{}
    )

    $record = [ordered]@{
        timestamp = (Get-Date).ToString("o")
        pid = $PID
        status = $Status
    }

    foreach ($key in $Extra.Keys) {
        $record[$key] = $Extra[$key]
    }

    $logPath = Join-Path $LogDir ("supervisor-{0}.jsonl" -f (Get-Date -Format "yyyy-MM-dd"))
    Add-Content -LiteralPath $logPath -Value ($record | ConvertTo-Json -Compress -Depth 5)
}

function Get-CodexProcess {
    @(Get-CimInstance Win32_Process -Filter "Name = 'codex.exe'" -ErrorAction SilentlyContinue)
}

function Get-WatcherProcess {
    $escaped = $WatcherScript.Replace('\', '\\')
    @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            ($_.CommandLine -like "*codex_qa_diary_watcher.ps1*" -or $_.CommandLine -like "*$escaped*")
        })
}

function Get-PowerShellExe {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh -and $pwsh.Source) {
        return $pwsh.Source
    }

    return (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe")
}

function Start-Watcher {
    if (-not (Test-Path -LiteralPath $WatcherScript)) {
        Write-SupervisorLog -Status "watcher_missing" -Extra @{ watcher_script = $WatcherScript }
        return
    }

    $psExe = Get-PowerShellExe
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$WatcherScript`" -PollSeconds $WatcherPollSeconds"
    $proc = Start-Process -FilePath $psExe -ArgumentList $args -WindowStyle Hidden -PassThru
    Write-SupervisorLog -Status "watcher_started" -Extra @{ watcher_pid = $proc.Id; codex_running = $true }
}

function Stop-Watcher {
    param([array]$WatcherProcesses)

    foreach ($proc in $WatcherProcesses) {
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            Write-SupervisorLog -Status "watcher_stopped" -Extra @{ watcher_pid = $proc.ProcessId; codex_running = $false }
        } catch {
            Write-SupervisorLog -Status "watcher_stop_failed" -Extra @{ watcher_pid = $proc.ProcessId; error = $_.Exception.Message }
        }
    }
}

try {
    Write-SupervisorLog -Status "supervisor_started" -Extra @{
        poll_seconds = $PollSeconds
        watcher_poll_seconds = $WatcherPollSeconds
        watcher_script = $WatcherScript
    }

    while ($true) {
        $codexProcesses = Get-CodexProcess
        $watcherProcesses = Get-WatcherProcess
        $codexRunning = @($codexProcesses).Count -gt 0
        $watcherRunning = @($watcherProcesses).Count -gt 0

        if ($codexRunning -and -not $watcherRunning) {
            Start-Watcher
        } elseif (-not $codexRunning -and $watcherRunning) {
            Stop-Watcher -WatcherProcesses $watcherProcesses
        }

        $heartbeat = [ordered]@{
            timestamp = (Get-Date).ToString("o")
            pid = $PID
            status = "ok"
            poll_seconds = $PollSeconds
            watcher_poll_seconds = $WatcherPollSeconds
            codex_running = $codexRunning
            codex_pids = @($codexProcesses | Select-Object -ExpandProperty ProcessId)
            watcher_running = $watcherRunning
            watcher_pids = @($watcherProcesses | Select-Object -ExpandProperty ProcessId)
        }
        $heartbeat | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $LogDir "supervisor-heartbeat.json") -Encoding UTF8

        if ($Once) {
            break
        }

        Start-Sleep -Seconds $PollSeconds
    }
} finally {
    if ($hasLock) {
        $mutex.ReleaseMutex() | Out-Null
    }
    $mutex.Dispose()
}
