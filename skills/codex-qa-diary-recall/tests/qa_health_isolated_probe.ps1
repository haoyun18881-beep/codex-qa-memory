param()

$ErrorActionPreference = 'Stop'
$health = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\qa_diary_health.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-qa-diary-health-$([guid]::NewGuid().ToString('N'))"
$diaryRoot = Join-Path $tempRoot 'qa-diary'
$watcherDir = Join-Path $diaryRoot '_watcher'
$sessionPath = Join-Path $tempRoot 'rollout-main.jsonl'
$today = (Get-Date).ToString('yyyy-MM-dd')
$yesterday = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')

function Write-ValidDiaryDay {
  param([string]$Day, [string]$Anchor)
  $dayDir = Join-Path $diaryRoot $Day
  New-Item -ItemType Directory -Force -Path (Join-Path $dayDir '_meta'),(Join-Path $dayDir 'projects') | Out-Null
  Set-Content -LiteralPath (Join-Path $dayDir '_index.md') -Encoding UTF8 -Value "# $Day"
  Set-Content -LiteralPath (Join-Path $dayDir 'projects\fixture.md') -Encoding UTF8 -Value "## Q {#$Anchor}"
  ([ordered]@{ anchor = $Anchor; question_time = "$Day`T01:00:00+08:00"; target = 'projects\fixture.md' } | ConvertTo-Json -Compress) |
    Set-Content -LiteralPath (Join-Path $dayDir '_meta\manifest.jsonl') -Encoding UTF8
}

try {
  New-Item -ItemType Directory -Force -Path $watcherDir | Out-Null
  Write-ValidDiaryDay -Day $today -Anchor 'q-a1b2c3d4'

  $rows = @(
    ([ordered]@{ timestamp = "$yesterday`T02:00:00+08:00"; type = 'event_msg'; payload = @{ type = 'user_message'; message = '隔离问题' } } | ConvertTo-Json -Compress -Depth 8),
    ([ordered]@{ timestamp = "$yesterday`T02:01:00+08:00"; type = 'event_msg'; payload = @{ type = 'agent_message'; phase = 'final_answer'; message = '隔离回答' } } | ConvertTo-Json -Compress -Depth 8)
  )
  Set-Content -LiteralPath $sessionPath -Encoding UTF8 -Value $rows
  $files = [ordered]@{}
  $files[$sessionPath.ToLowerInvariant()] = [ordered]@{ thread_source = 'user' }
  [ordered]@{ version = 1; files = $files } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $watcherDir 'scan-state.json') -Encoding UTF8
  [ordered]@{ timestamp = (Get-Date).ToString('o'); status = 'ok'; exit_code = 0 } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $watcherDir 'heartbeat.json') -Encoding UTF8

  $firstText = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $health -DiaryRoot $diaryRoot -FailuresBeforeCritical 2 -SkipTaskCheck 2>&1)
  $firstExit = $LASTEXITCODE
  $first = (($firstText | ForEach-Object { "$_" }) -join "`n") | ConvertFrom-Json
  $secondText = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $health -DiaryRoot $diaryRoot -FailuresBeforeCritical 2 -SkipTaskCheck 2>&1)
  $secondExit = $LASTEXITCODE
  $second = (($secondText | ForEach-Object { "$_" }) -join "`n") | ConvertFrom-Json

  if ($firstExit -ne 0 -or $first.status -ne 'warning') { throw "first health run expected warning/0, got $($first.status)/$firstExit" }
  if ($secondExit -ne 2 -or $second.status -ne 'critical') { throw "second health run expected critical/2, got $($second.status)/$secondExit" }
  if ("completed_main_qa_without_index:$yesterday" -notin @($second.reasons)) { throw 'missing previous-day diary gap was not detected' }

  Write-ValidDiaryDay -Day $yesterday -Anchor 'q-e5f6a7b8'
  $recoveryText = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $health -DiaryRoot $diaryRoot -FailuresBeforeCritical 2 -SkipTaskCheck 2>&1)
  $recoveryExit = $LASTEXITCODE
  $recovery = (($recoveryText | ForEach-Object { "$_" }) -join "`n") | ConvertFrom-Json
  if ($recoveryExit -ne 0 -or $recovery.status -ne 'recovered') { throw "recovery expected recovered/0, got $($recovery.status)/$recoveryExit" }
  if (Test-Path -LiteralPath (Join-Path $watcherDir 'ALERT.json')) { throw 'recovery did not remove ALERT.json' }

  [pscustomobject]@{
    status = 'PASS'
    first = "$firstExit/$($first.status)"
    second = "$secondExit/$($second.status)"
    recovery = "$recoveryExit/$($recovery.status)"
    days_checked = @($second.days_checked).day
  } | ConvertTo-Json -Depth 5
} finally {
  $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
  $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTemp)) {
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
}
