param(
  [string]$DiaryRoot = "$env:USERPROFILE\.codex\qa-diary",
  [string]$TaskName = "Codex QA Diary Watcher",
  [string]$TaskPath = "\Codex\",
  [int]$MaxHeartbeatAgeMinutes = 30,
  [int]$FailuresBeforeCritical = 2,
  [switch]$SkipTaskCheck
)

$ErrorActionPreference = 'Stop'
$watcherDir = Join-Path $DiaryRoot '_watcher'
$healthPath = Join-Path $watcherDir 'health.json'
$alertPath = Join-Path $watcherDir 'ALERT.json'
$scanStatePath = Join-Path $watcherDir 'scan-state.json'
$maintainPath = Join-Path $PSScriptRoot 'qa_memory_maintain.ps1'
New-Item -ItemType Directory -Force -Path $watcherDir | Out-Null

function Read-JsonSafe {
  param([string]$Path, [long]$MaxBytes = 16MB)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  if ((Get-Item -LiteralPath $Path).Length -gt $MaxBytes) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $null }
}

function Write-JsonAtomic {
  param([string]$Path, [object]$Value)
  $temp = "$Path.tmp"
  $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding UTF8
  Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Read-DayManifest {
  param([string]$DayDir)
  $path = Join-Path $DayDir '_meta\manifest.jsonl'
  if (-not (Test-Path -LiteralPath $path)) {
    return [pscustomobject]@{ exists = $false; ok = $true; path = $path; records = @(); reason = $null }
  }
  $file = Get-Item -LiteralPath $path
  if ($file.Length -gt 32MB) {
    return [pscustomobject]@{ exists = $true; ok = $false; path = $path; records = @(); reason = 'manifest_exceeds_32mb_bound' }
  }
  $records = New-Object System.Collections.Generic.List[object]
  $lineNo = 0
  foreach ($line in Get-Content -LiteralPath $path -ReadCount 1) {
    $lineNo++
    if ($lineNo -gt 20000) {
      return [pscustomobject]@{ exists = $true; ok = $false; path = $path; records = @($records.ToArray()); reason = 'manifest_exceeds_20000_line_bound' }
    }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $records.Add(($line | ConvertFrom-Json)) } catch {
      return [pscustomobject]@{ exists = $true; ok = $false; path = $path; records = @($records.ToArray()); reason = "manifest_invalid_json_line_$lineNo" }
    }
  }
  return [pscustomobject]@{ exists = $true; ok = $true; path = $path; records = @($records.ToArray()); reason = $null }
}

function Test-DayAnchorParity {
  param([string]$DayDir, [object]$Manifest)
  if (-not $Manifest.exists -or -not $Manifest.ok) {
    return [pscustomobject]@{ checked = $false; ok = $Manifest.ok; reason = $Manifest.reason }
  }
  $manifestAnchors = @($Manifest.records | ForEach-Object { "$($_.anchor)" } | Where-Object { $_ } | Sort-Object -Unique)
  # Enumerate the two writer-owned content folders as well as the day root so
  # an orphan Markdown append (crash before manifest write) is detected too.
  # The enumeration is non-recursive and hard-bounded.
  $files = New-Object System.Collections.Generic.List[object]
  foreach ($dir in @($DayDir, (Join-Path $DayDir 'general'), (Join-Path $DayDir 'projects'))) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $dir -File -Filter '*.md' -ErrorAction SilentlyContinue) {
      if ($file.Name -eq '_index.md') { continue }
      $files.Add($file)
      if ($files.Count -gt 512) {
        return [pscustomobject]@{ checked = $true; ok = $false; reason = 'markdown_files_exceed_512_bound'; manifest_anchors = $manifestAnchors.Count }
      }
    }
  }
  $markdownAnchors = New-Object System.Collections.Generic.List[string]
  $totalBytes = 0L
  foreach ($file in $files) {
    if ($file.Length -gt 16MB -or ($totalBytes + $file.Length) -gt 64MB) {
      return [pscustomobject]@{ checked = $true; ok = $false; reason = 'markdown_exceeds_health_read_bound'; manifest_anchors = $manifestAnchors.Count }
    }
    $totalBytes += $file.Length
    $text = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($match in [regex]::Matches($text, '\{#(q-[a-f0-9]+)\}')) { $markdownAnchors.Add($match.Groups[1].Value) }
  }
  $markdown = @($markdownAnchors.ToArray() | Sort-Object -Unique)
  $missingMarkdown = @($manifestAnchors | Where-Object { $_ -notin $markdown })
  $missingManifest = @($markdown | Where-Object { $_ -notin $manifestAnchors })
  return [pscustomobject]@{
    checked = $true
    ok = $missingMarkdown.Count -eq 0 -and $missingManifest.Count -eq 0
    reason = $null
    manifest_anchors = $manifestAnchors.Count
    markdown_anchors = $markdown.Count
    missing_markdown = $missingMarkdown.Count
    missing_manifest = $missingManifest.Count
    bytes_examined = $totalBytes
  }
}

function Invoke-MissingIndexProbe {
  param([string]$Day)
  if (-not (Test-Path -LiteralPath $maintainPath)) {
    return [pscustomobject]@{ exit_code = 1; status = 'maintain_script_missing'; source = $null; sessions_checked = 0; bytes_examined = 0 }
  }
  $unusedMemoryRoot = Join-Path $watcherDir '_health-memory-unused'
  $escapeLiteral = {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
  }
  $probeCommand = @(
    '& ' + (& $escapeLiteral $maintainPath)
    '-Date ' + (& $escapeLiteral $Day)
    '-DiaryRoot ' + (& $escapeLiteral $DiaryRoot)
    '-ScanStatePath ' + (& $escapeLiteral $scanStatePath)
    '-MemoryRoot ' + (& $escapeLiteral $unusedMemoryRoot)
    '-NoWrite -SkipValidation'
  ) -join ' '
  $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeCommand))
  $startInfo = New-Object Diagnostics.ProcessStartInfo
  $startInfo.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $startInfo.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = New-Object Diagnostics.Process
  $process.StartInfo = $startInfo
  try {
    if (-not $process.Start()) { throw 'missing_index_probe_start_failed' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
  } finally {
    $process.Dispose()
  }
  $parsed = $null
  try {
    if (-not [string]::IsNullOrWhiteSpace($stdout)) { $parsed = $stdout | ConvertFrom-Json }
  } catch { $parsed = $null }
  return [pscustomobject]@{
    exit_code = $exitCode
    status = if ($null -ne $parsed) { "$($parsed.status)" } else { 'probe_output_invalid' }
    source = if ($null -ne $parsed -and $null -ne $parsed.date_qa_activity) { "$($parsed.date_qa_activity.source)" } else { $null }
    sessions_checked = if ($null -ne $parsed -and $null -ne $parsed.date_qa_activity) { [int]$parsed.date_qa_activity.sessions_checked } else { 0 }
    bytes_examined = if ($null -ne $parsed -and $null -ne $parsed.date_qa_activity) { [long]$parsed.date_qa_activity.bytes_examined } else { 0 }
    stderr_present = -not [string]::IsNullOrWhiteSpace($stderr)
  }
}

function Test-DiaryDay {
  param([string]$Day)
  $dayDir = Join-Path $DiaryRoot $Day
  $indexPath = Join-Path $dayDir '_index.md'
  $manifest = Read-DayManifest -DayDir $dayDir
  $reasons = New-Object System.Collections.Generic.List[string]
  $immediate = $false
  $probe = $null
  $parity = $null

  if ($manifest.exists -and -not $manifest.ok) {
    $reasons.Add("manifest_invalid_or_over_bound:$Day")
    $immediate = $true
  } elseif (Test-Path -LiteralPath $indexPath) {
    if (-not $manifest.exists) {
      $reasons.Add("manifest_missing_for_index_day:$Day")
      $immediate = $true
    } else {
      $parity = Test-DayAnchorParity -DayDir $dayDir -Manifest $manifest
      if (-not $parity.ok) {
        $reasons.Add("manifest_markdown_anchor_mismatch:$Day")
        $immediate = $true
      }
    }
  } else {
    $probe = Invoke-MissingIndexProbe -Day $Day
    if ($probe.status -eq 'no_diary_index_with_main_activity') {
      $reasons.Add("completed_main_qa_without_index:$Day")
    } elseif ($probe.status -eq 'probe_output_invalid' -or $probe.exit_code -ne 0) {
      $reasons.Add("bounded_missing_index_probe_failed:$Day")
    }
  }

  return [pscustomobject]@{
    day = $Day
    index_exists = (Test-Path -LiteralPath $indexPath)
    manifest_exists = $manifest.exists
    manifest_records = @($manifest.records).Count
    parity = $parity
    missing_index_probe = $probe
    reasons = @($reasons)
    immediate_critical = $immediate
  }
}

$now = Get-Date
$previous = Read-JsonSafe -Path $healthPath
$reasons = New-Object System.Collections.Generic.List[string]
$immediateCritical = $false

$taskActionPath = $null
if (-not $SkipTaskCheck) {
  $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
  if ($null -eq $task) {
    $reasons.Add('watcher_task_missing')
    $immediateCritical = $true
  } else {
    $executePath = "$($task.Actions[0].Execute)"
    $arguments = "$($task.Actions[0].Arguments)"
    if ($arguments -match '-File\s+"([^"]+)"') { $taskActionPath = $Matches[1] }
    elseif ($arguments -match '"([^"]+\.vbs)"') { $taskActionPath = $Matches[1] }
    if ([string]::IsNullOrWhiteSpace($executePath) -or -not (Test-Path -LiteralPath $executePath) -or
      [string]::IsNullOrWhiteSpace($taskActionPath) -or -not (Test-Path -LiteralPath $taskActionPath)) {
      $reasons.Add('watcher_action_path_missing')
      $immediateCritical = $true
    }
  }
}

$codexRunning = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
  $_.ProcessName -ieq 'Codex' -or
  ($_.ProcessName -ieq 'codex' -and $_.Path -match '\\OpenAI\\Codex\\|\\WindowsApps\\OpenAI\.Codex_')
}).Count -gt 0

$heartbeatPath = Join-Path $watcherDir 'heartbeat.json'
$heartbeat = Read-JsonSafe -Path $heartbeatPath
$heartbeatTime = $null
if ($null -ne $heartbeat -and $heartbeat.timestamp) {
  try { $heartbeatTime = [datetimeoffset]::Parse("$($heartbeat.timestamp)").LocalDateTime } catch { $heartbeatTime = $null }
}
if ($null -ne $heartbeat -and (("$($heartbeat.status)" -eq 'error') -or ([int]$heartbeat.exit_code -ne 0))) {
  $reasons.Add('watcher_reports_error')
}
# Heartbeat freshness is independent of session file mtime. Tool-only events
# can change a session file and must never be mistaken for a missing Q/A diary.
if ($codexRunning -and ($null -eq $heartbeatTime -or ($now - $heartbeatTime).TotalMinutes -gt $MaxHeartbeatAgeMinutes)) {
  $reasons.Add('watcher_heartbeat_missing_or_stale')
}
if ($codexRunning -and $null -eq (Read-JsonSafe -Path $scanStatePath)) {
  $reasons.Add('scan_state_missing_or_invalid')
}

$days = @($now.Date, $now.Date.AddDays(-1)) | ForEach-Object { $_.ToString('yyyy-MM-dd') }
$dayChecks = @($days | ForEach-Object { Test-DiaryDay -Day $_ })
foreach ($check in $dayChecks) {
  foreach ($reason in $check.reasons) { $reasons.Add("$reason") }
  if ($check.immediate_critical) { $immediateCritical = $true }
}

$failed = $reasons.Count -gt 0
$previousFailures = if ($null -ne $previous -and $previous.consecutive_failures) { [int]$previous.consecutive_failures } else { 0 }
$consecutiveFailures = if ($failed) { $previousFailures + 1 } else { 0 }
$critical = $failed -and ($immediateCritical -or $consecutiveFailures -ge [Math]::Max(1, $FailuresBeforeCritical))
$status = if ($critical) { 'critical' } elseif ($failed) { 'warning' } elseif ($null -ne $previous -and $previous.status -in @('warning','critical')) { 'recovered' } else { 'ok' }

$result = [ordered]@{
  timestamp = $now.ToString('o')
  status = $status
  consecutive_failures = $consecutiveFailures
  reasons = @($reasons)
  codex_running = $codexRunning
  task_action_path = $taskActionPath
  watcher_heartbeat = if ($null -ne $heartbeatTime) { $heartbeatTime.ToString('o') } else { $null }
  scan_state_path = $scanStatePath
  days_checked = $dayChecks
}

Write-JsonAtomic -Path $healthPath -Value $result
if ($critical) {
  Write-JsonAtomic -Path $alertPath -Value $result
} elseif (Test-Path -LiteralPath $alertPath) {
  Remove-Item -LiteralPath $alertPath -Force
}

$result | ConvertTo-Json -Depth 12
if ($critical) { exit 2 }
exit 0
