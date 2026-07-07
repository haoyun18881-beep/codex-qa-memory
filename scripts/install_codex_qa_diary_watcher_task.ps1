param(
    [int]$PollSeconds = 15,
    [int]$SupervisorPollSeconds = 10,
    [string]$TaskName = "Codex QA Diary Watcher",
    [string]$TaskPath = "\Codex\"
)

$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "codex_qa_diary_supervisor.ps1"
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Supervisor script not found: $scriptPath"
}

$powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

$argument = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -PollSeconds $SupervisorPollSeconds -WatcherPollSeconds $PollSeconds"
$action = New-ScheduledTaskAction -Execute $powershell -Argument $argument
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew
$settings.Hidden = $true

Stop-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue

Register-ScheduledTask `
    -TaskName $TaskName `
    -TaskPath $TaskPath `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Description "Start a hidden supervisor that runs the Codex QA diary watcher only while Codex is open." `
    -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath

Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath | Select-Object TaskName,TaskPath,State
