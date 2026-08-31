param(
    [int]$PollSeconds = 120,
    [int]$SupervisorPollSeconds = 10,
    [string]$TaskName = "Codex QA Diary Watcher",
    [string]$TaskPath = "\Codex\",
    [string]$HealthTaskName = "Codex QA Diary Health",
    [string]$HealthLauncher = (Join-Path $env:USERPROFILE ".codex\skills\codex-qa-diary-recall\scripts\run_qa_diary_health_hidden.vbs"),
    [int]$HealthIntervalMinutes = 30,
    [int]$RecoveryIntervalMinutes = 5
)

$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "codex_qa_diary_supervisor.ps1"
$launcherPath = Join-Path $PSScriptRoot "run_codex_qa_diary_supervisor_hidden.vbs"
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Supervisor script not found: $scriptPath"
}
if (-not (Test-Path -LiteralPath $launcherPath)) {
    throw "Hidden supervisor launcher not found: $launcherPath"
}
$healthScriptPath = Join-Path (Split-Path -Parent $HealthLauncher) "qa_diary_health.ps1"
if (-not (Test-Path -LiteralPath $HealthLauncher)) {
    throw "Hidden health launcher not found: $HealthLauncher"
}
if (-not (Test-Path -LiteralPath $healthScriptPath)) {
    throw "Health script not found next to launcher: $healthScriptPath"
}

$wscript = Join-Path $env:SystemRoot "System32\wscript.exe"
if (-not (Test-Path -LiteralPath $wscript)) {
    throw "Windows Script Host not found: $wscript"
}

$argument = "//B //NoLogo `"$launcherPath`" $SupervisorPollSeconds $PollSeconds"
$action = New-ScheduledTaskAction -Execute $wscript -Argument $argument
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn
$recoveryTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes ([Math]::Max(5, $RecoveryIntervalMinutes))) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
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
    -Trigger @($logonTrigger, $recoveryTrigger) `
    -Settings $settings `
    -Description "Start the Codex QA diary supervisor without a console window and periodically recover it if interrupted." `
    -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath

$healthArgument = "//B //NoLogo `"$HealthLauncher`""
$healthAction = New-ScheduledTaskAction -Execute $wscript -Argument $healthArgument
$healthTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes ([Math]::Max(5, $HealthIntervalMinutes))) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$healthSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 1 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew
$healthSettings.Hidden = $true

Stop-ScheduledTask -TaskName $HealthTaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
Register-ScheduledTask `
    -TaskName $HealthTaskName `
    -TaskPath $TaskPath `
    -Action $healthAction `
    -Trigger $healthTrigger `
    -Settings $healthSettings `
    -Description "Detect a broken Codex QA diary task, stale heartbeat, or diary/manifest mismatch." `
    -Force | Out-Null
Start-ScheduledTask -TaskName $HealthTaskName -TaskPath $TaskPath

Get-ScheduledTask -TaskName @($TaskName, $HealthTaskName) -TaskPath $TaskPath |
    Select-Object TaskName,TaskPath,State
