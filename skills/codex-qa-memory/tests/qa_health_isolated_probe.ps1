param()

$ErrorActionPreference = 'Stop'
$scriptsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
$maintain = Join-Path $scriptsDir 'qa_memory_maintain.ps1'
$health = Join-Path $scriptsDir 'qa_diary_health.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-qa-health-$([guid]::NewGuid().ToString('N'))"
$diaryRoot = Join-Path $tempRoot 'qa-diary'
$memoryRoot = Join-Path $tempRoot 'qa-memory'
$watcherDir = Join-Path $diaryRoot '_watcher'
$sessionPath = Join-Path $tempRoot 'rollout-main.jsonl'
$today = (Get-Date).ToString('yyyy-MM-dd')
$yesterday = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')

function Write-SessionFixture {
  param([ValidateSet('complete','tool-only','large-gap','parallel-notification','large-gap-parallel')] [string]$Kind)
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add(([ordered]@{ timestamp = "$yesterday`T01:00:00+08:00"; type = 'session_meta'; payload = @{ id = 'fixture-main'; thread_source = 'user' } } | ConvertTo-Json -Compress -Depth 8))
  # Simulate a watcher that committed only the metadata row, then stopped.
  Set-Content -LiteralPath $sessionPath -Encoding UTF8 -Value $lines
  $committedLength = (Get-Item -LiteralPath $sessionPath).Length
  $appended = New-Object System.Collections.Generic.List[string]
  if ($Kind -in @('complete','large-gap','parallel-notification','large-gap-parallel')) {
    $appended.Add(([ordered]@{ timestamp = "$yesterday`T02:00:00+08:00"; type = 'event_msg'; payload = @{ type = 'user_message'; message = '隔离问题' } } | ConvertTo-Json -Compress -Depth 8))
    if ($Kind -in @('large-gap','large-gap-parallel')) {
      $appended.Add(([ordered]@{ timestamp = "$yesterday`T02:00:30+08:00"; type = 'response_item'; payload = @{ type = 'tool_output'; blob = ('x' * (5MB)) } } | ConvertTo-Json -Compress -Depth 8))
    }
    if ($Kind -in @('parallel-notification','large-gap-parallel')) {
      $appended.Add(([ordered]@{ timestamp = "$yesterday`T02:00:30+08:00"; type = 'event_msg'; payload = @{ type = 'user_message'; message = '<subagent_notification>child done</subagent_notification>' } } | ConvertTo-Json -Compress -Depth 8))
    }
    $appended.Add(([ordered]@{ timestamp = "$yesterday`T02:01:00+08:00"; type = 'event_msg'; payload = @{ type = 'agent_message'; phase = 'final_answer'; message = '隔离回答' } } | ConvertTo-Json -Compress -Depth 8))
  } else {
    $appended.Add(([ordered]@{ timestamp = "$yesterday`T02:00:00+08:00"; type = 'event_msg'; payload = @{ type = 'user_message'; message = '<environment_context>machine</environment_context>' } } | ConvertTo-Json -Compress -Depth 8))
    $appended.Add(([ordered]@{ timestamp = "$yesterday`T02:01:00+08:00"; type = 'event_msg'; payload = @{ type = 'agent_message'; phase = 'final_answer'; message = 'machine response' } } | ConvertTo-Json -Compress -Depth 8))
    $appended.Add(([ordered]@{ timestamp = "$yesterday`T02:02:00+08:00"; type = 'event_msg'; payload = @{ type = 'tool_event'; message = 'tool only' } } | ConvertTo-Json -Compress -Depth 8))
  }
  Add-Content -LiteralPath $sessionPath -Encoding UTF8 -Value $appended
  $file = Get-Item -LiteralPath $sessionPath
  $files = [ordered]@{}
  $files[$sessionPath.ToLowerInvariant()] = [ordered]@{
    committed_offset = $committedLength
    size = $committedLength
    mtime_ns = ([datetimeoffset]::Now.ToUnixTimeMilliseconds() - 60000) * 1000000
    pending_turn = $false
    session_id = 'fixture-main'
    thread_source = 'user'
  }
  [ordered]@{ version = 1; files = $files } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $watcherDir 'scan-state.json') -Encoding UTF8
}

function Invoke-MaintainProbe {
  $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $maintain `
    -Date $yesterday -DiaryRoot $diaryRoot -ScanStatePath (Join-Path $watcherDir 'scan-state.json') `
    -MemoryRoot $memoryRoot -NoWrite -SkipValidation 2>&1)
  return [pscustomobject]@{ exit_code = $LASTEXITCODE; output = (($output | ForEach-Object { "$_" }) -join "`n") | ConvertFrom-Json }
}

try {
  New-Item -ItemType Directory -Force -Path $watcherDir | Out-Null

  # 1. Tool/machine events alone do not become main-thread Q/A evidence.
  Write-SessionFixture -Kind 'tool-only'
  $toolOnly = Invoke-MaintainProbe
  if ($toolOnly.exit_code -ne 0 -or $toolOnly.output.status -ne 'no_diary_index') {
    throw "tool-only probe expected exit 0/no_diary_index, got $($toolOnly.exit_code)/$($toolOnly.output.status)"
  }

  # 2. A bounded-tail user_message -> final_answer pair makes a missing index non-zero.
  Write-SessionFixture -Kind 'complete'
  $complete = Invoke-MaintainProbe
  if ($complete.exit_code -ne 2 -or $complete.output.status -ne 'no_diary_index_with_main_activity') {
    throw "complete probe expected exit 2/no_diary_index_with_main_activity, got $($complete.exit_code)/$($complete.output.status)"
  }
  if ([long]$complete.output.date_qa_activity.bytes_examined -gt 4MB) {
    throw 'bounded probe read more than 4 MiB for one fixture session'
  }

  # 3. A >4 MiB tool event may hide the user line; final alone is still
  # positive main-thread activity evidence, while the read remains bounded.
  Write-SessionFixture -Kind 'large-gap'
  $largeGap = Invoke-MaintainProbe
  if ($largeGap.exit_code -ne 2 -or $largeGap.output.status -ne 'no_diary_index_with_main_activity') {
    throw "large-gap probe expected exit 2/no_diary_index_with_main_activity, got $($largeGap.exit_code)/$($largeGap.output.status)"
  }
  if ([long]$largeGap.output.date_qa_activity.bytes_examined -gt 4MB) {
    throw 'large-gap probe exceeded the 4 MiB file-tail bound'
  }

  Write-SessionFixture -Kind 'parallel-notification'
  $parallel = Invoke-MaintainProbe
  if ($parallel.exit_code -ne 2 -or $parallel.output.status -ne 'no_diary_index_with_main_activity') {
    throw "parallel notification probe expected activity/2, got $($parallel.exit_code)/$($parallel.output.status)"
  }

  Write-SessionFixture -Kind 'large-gap-parallel'
  $largeGapParallel = Invoke-MaintainProbe
  if ($largeGapParallel.exit_code -ne 2 -or $largeGapParallel.output.status -ne 'no_diary_index_with_main_activity') {
    throw "large-gap parallel probe expected activity/2, got $($largeGapParallel.exit_code)/$($largeGapParallel.output.status)"
  }

  # 4. Health checks both days and escalates a confirmed previous-day gap.
  $todayDir = Join-Path $diaryRoot $today
  New-Item -ItemType Directory -Force -Path (Join-Path $todayDir '_meta'),(Join-Path $todayDir 'projects') | Out-Null
  Set-Content -LiteralPath (Join-Path $todayDir '_index.md') -Encoding UTF8 -Value "# $today"
  Set-Content -LiteralPath (Join-Path $todayDir 'projects\fixture.md') -Encoding UTF8 -Value '## Q {#q-a1b2c3d4}'
  ([ordered]@{ anchor = 'q-a1b2c3d4'; question_time = "$today`T01:00:00+08:00"; target = 'projects\fixture.md' } | ConvertTo-Json -Compress) |
    Set-Content -LiteralPath (Join-Path $todayDir '_meta\manifest.jsonl') -Encoding UTF8
  [ordered]@{ timestamp = (Get-Date).ToString('o'); status = 'ok'; exit_code = 0 } | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $watcherDir 'heartbeat.json') -Encoding UTF8

  $firstHealthOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $health -DiaryRoot $diaryRoot -FailuresBeforeCritical 2 -SkipTaskCheck 2>&1)
  $firstExit = $LASTEXITCODE
  $firstHealth = (($firstHealthOutput | ForEach-Object { "$_" }) -join "`n") | ConvertFrom-Json
  $secondHealthOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $health -DiaryRoot $diaryRoot -FailuresBeforeCritical 2 -SkipTaskCheck 2>&1)
  $secondExit = $LASTEXITCODE
  $secondHealth = (($secondHealthOutput | ForEach-Object { "$_" }) -join "`n") | ConvertFrom-Json
  if ($firstExit -ne 0 -or $firstHealth.status -ne 'warning') { throw "first health run expected warning/0, got $($firstHealth.status)/$firstExit" }
  if ($secondExit -ne 2 -or $secondHealth.status -ne 'critical') { throw "second health run expected critical/2, got $($secondHealth.status)/$secondExit" }
  if (@($secondHealth.days_checked).Count -ne 2 -or "completed_main_qa_without_index:$yesterday" -notin @($secondHealth.reasons)) {
    throw 'health did not check both days or report the previous-day gap'
  }

  # 5. Repairing yesterday clears ALERT and records recovered.
  $yesterdayDir = Join-Path $diaryRoot $yesterday
  New-Item -ItemType Directory -Force -Path (Join-Path $yesterdayDir '_meta'),(Join-Path $yesterdayDir 'projects') | Out-Null
  Set-Content -LiteralPath (Join-Path $yesterdayDir '_index.md') -Encoding UTF8 -Value "# $yesterday"
  Set-Content -LiteralPath (Join-Path $yesterdayDir 'projects\fixture.md') -Encoding UTF8 -Value '## Q {#q-e5f6a7b8}'
  ([ordered]@{ anchor = 'q-e5f6a7b8'; question_time = "$yesterday`T02:00:00+08:00"; target = 'projects\fixture.md' } | ConvertTo-Json -Compress) |
    Set-Content -LiteralPath (Join-Path $yesterdayDir '_meta\manifest.jsonl') -Encoding UTF8
  $recoveryOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $health -DiaryRoot $diaryRoot -FailuresBeforeCritical 2 -SkipTaskCheck 2>&1)
  $recoveryExit = $LASTEXITCODE
  $recovery = (($recoveryOutput | ForEach-Object { "$_" }) -join "`n") | ConvertFrom-Json
  if ($recoveryExit -ne 0 -or $recovery.status -ne 'recovered') { throw "recovery expected recovered/0, got $($recovery.status)/$recoveryExit" }
  if (Test-Path -LiteralPath (Join-Path $watcherDir 'ALERT.json')) { throw 'recovery did not remove ALERT.json' }

  [pscustomobject]@{
    status = 'PASS'
    tool_only = "$($toolOnly.exit_code)/$($toolOnly.output.status)"
    completed_qa = "$($complete.exit_code)/$($complete.output.status)"
    large_gap = "$($largeGap.exit_code)/$($largeGap.output.status)"
    parallel_notification = "$($parallel.exit_code)/$($parallel.output.status)"
    large_gap_parallel = "$($largeGapParallel.exit_code)/$($largeGapParallel.output.status)"
    health_first = "$firstExit/$($firstHealth.status)"
    health_second = "$secondExit/$($secondHealth.status)"
    health_recovery = "$recoveryExit/$($recovery.status)"
    days_checked = @($secondHealth.days_checked).day
  } | ConvertTo-Json -Depth 6
} finally {
  $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
  if ($resolvedTemp.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTemp)) {
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
}
