param(
  [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
  [string]$DiaryRoot = "$env:USERPROFILE\.codex\qa-diary",
  [string]$ScanStatePath = '',
  [string]$MemoryRoot = "$env:USERPROFILE\.codex\qa-memory",
  [int]$MaxCandidates = 40,
  [switch]$NoWrite,
  [switch]$SkipValidation,
  [switch]$RequireCodexRunning
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $PSCommandPath
$dateCompact = $Date -replace '-', ''
$runId = "qa_memory_daily_maintain_$dateCompact"
if ([string]::IsNullOrWhiteSpace($ScanStatePath)) {
  $ScanStatePath = Join-Path $DiaryRoot '_watcher\scan-state.json'
}

if ($RequireCodexRunning) {
  $codexProcess = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -ieq 'Codex' -or
    ($_.ProcessName -ieq 'codex' -and $_.Path -match '\\OpenAI\\Codex\\|\\WindowsApps\\OpenAI\.Codex_')
  })
  if ($codexProcess.Count -eq 0) {
    [pscustomobject]@{
      run_id = $runId
      status = 'skipped_codex_not_running'
      message = 'Codex process not found; no files changed.'
      date = $Date
    } | ConvertTo-Json -Depth 4
    exit 0
  }
}

function Get-ShortHash {
  param([string]$Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = $sha.ComputeHash($bytes)
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 8).ToUpperInvariant()
  } finally {
    $sha.Dispose()
  }
}

function ConvertTo-JsonLine {
  param([object]$Object)
  return ($Object | ConvertTo-Json -Depth 20 -Compress)
}

function Read-Jsonl {
  param([string]$Path)
  $items = @()
  if (-not (Test-Path -LiteralPath $Path)) { return $items }
  $lineNo = 0
  foreach ($line in Get-Content -LiteralPath $Path) {
    $lineNo++
    if ($line.Trim().Length -eq 0) { continue }
    try {
      $items += ($line | ConvertFrom-Json)
    } catch {
      throw "Invalid JSONL at ${Path}:${lineNo}: $($_.Exception.Message)"
    }
  }
  return $items
}

function Get-ObjectValue {
  param([object]$Object, [string]$Name)
  if ($null -eq $Object) { return $null }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Read-JsonSafe {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  # scan-state should be small; refuse unexpected growth instead of reading it unbounded.
  if ((Get-Item -LiteralPath $Path).Length -gt 16MB) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $null }
}

function Test-SkippedUserMessage {
  param([string]$Message)
  $text = "$Message".Trim()
  if ($text.Length -eq 0) { return $true }
  foreach ($prefix in @('<subagent_notification>','<environment_context>','<recommended_plugins>','<turn_aborted>')) {
    if ($text.StartsWith($prefix, [StringComparison]::Ordinal)) { return $true }
  }
  return $false
}

function Test-BlockingMachineUserMessage {
  param([string]$Message)
  $text = "$Message".Trim()
  if ($text.Length -eq 0) { return $true }
  foreach ($prefix in @('<environment_context>','<recommended_plugins>','<turn_aborted>')) {
    if ($text.StartsWith($prefix, [StringComparison]::Ordinal)) { return $true }
  }
  # subagent_notification is transparent: it can be inserted inside a real
  # main-thread turn and must never suppress the later main final.
  return $false
}

function ConvertTo-LocalDaySafe {
  param([string]$Timestamp)
  try { return ([datetimeoffset]::Parse($Timestamp)).LocalDateTime.ToString('yyyy-MM-dd') } catch { return $null }
}

function Read-BoundedSessionTail {
  param([string]$Path)
  # Hard safety gate: never inspect more than 4 MiB from one session file.
  $maxBytes = 4MB
  $stream = $null
  try {
    $stream = [System.IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    # Read to the real EOF. scan-state may be stale precisely because the
    # watcher stopped before a newly appended Q/A was committed.
    $boundedEnd = [long]$stream.Length
    if ($boundedEnd -le 0) { return [pscustomobject]@{ text = ''; bytes = 0 } }
    $start = [Math]::Max([long]0, $boundedEnd - $maxBytes)
    [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
    $length = [int]($boundedEnd - $start)
    $buffer = New-Object byte[] $length
    $read = 0
    while ($read -lt $length) {
      $count = $stream.Read($buffer, $read, $length - $read)
      if ($count -le 0) { break }
      $read += $count
    }
    $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
    if ($start -gt 0) {
      $firstNewline = $text.IndexOf("`n", [StringComparison]::Ordinal)
      $text = if ($firstNewline -ge 0) { $text.Substring($firstNewline + 1) } else { '' }
    }
    return [pscustomobject]@{ text = $text; bytes = $read }
  } finally {
    if ($null -ne $stream) { $stream.Dispose() }
  }
}

function Test-BoundedTailHasCompletedQaForDay {
  param([string]$Text, [string]$TargetDay)
  $currentQuestionDay = $null
  $blockedBySkippedUser = $false
  foreach ($line in @($Text -split "`r?`n")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line.IndexOf('user_message', [StringComparison]::Ordinal) -lt 0 -and
      $line.IndexOf('agent_message', [StringComparison]::Ordinal) -lt 0) { continue }
    try { $row = $line | ConvertFrom-Json } catch { continue }
    if ("$($row.type)" -ne 'event_msg') { continue }
    $eventType = "$($row.payload.type)"
    if ($eventType -eq 'user_message') {
      if (Test-SkippedUserMessage -Message "$($row.payload.message)") {
        # A subagent/environment injection inside a real turn is transparent.
        # Only suppress final-only fallback when no real user is already known.
        if ($null -eq $currentQuestionDay -and (Test-BlockingMachineUserMessage -Message "$($row.payload.message)")) {
          $blockedBySkippedUser = $true
        }
        continue
      }
      $currentQuestionDay = ConvertTo-LocalDaySafe -Timestamp "$($row.timestamp)"
      $blockedBySkippedUser = $false
      continue
    }
    if ($eventType -eq 'agent_message' -and "$($row.payload.phase)" -eq 'final_answer' -and
      -not [string]::IsNullOrWhiteSpace("$($row.payload.message)")) {
      if ($null -ne $currentQuestionDay) {
        if ($currentQuestionDay -eq $TargetDay) { return $true }
      } elseif (-not $blockedBySkippedUser) {
        # A large tool result can push the user event outside the 4 MiB window.
        # In a scan-state-confirmed main thread, a non-empty final answer is
        # still positive activity evidence for its local day. A skipped machine
        # user event seen in-window suppresses this fallback.
        $answerDay = ConvertTo-LocalDaySafe -Timestamp "$($row.timestamp)"
        if ($answerDay -eq $TargetDay) { return $true }
      }
      $currentQuestionDay = $null
      $blockedBySkippedUser = $false
    }
  }
  return $false
}

function Get-BoundedSessionQaEvidence {
  param([string]$TargetDay)
  # Hard safety gate: inspect at most eight scan-state-confirmed main sessions.
  $maxFiles = 8
  $scanState = Read-JsonSafe -Path $ScanStatePath
  if ($null -eq $scanState -or $null -eq $scanState.files) {
    return [pscustomobject]@{ has_qa = $false; source = 'scan_state_unavailable'; sessions_checked = 0; bytes_examined = 0; evidence = $null }
  }
  $available = New-Object System.Collections.Generic.List[object]
  foreach ($property in $scanState.files.PSObject.Properties) {
    if ("$($property.Value.thread_source)" -ne 'user') { continue }
    $path = "$($property.Name)"
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $file = Get-Item -LiteralPath $path
    $available.Add([pscustomobject]@{ path = $file.FullName; last_write_utc = $file.LastWriteTimeUtc })
  }
  $candidates = @(
    $available |
      Sort-Object last_write_utc -Descending |
      Select-Object -First $maxFiles
  )
  $checked = 0
  $bytesExamined = 0L
  foreach ($candidate in $candidates) {
    $path = "$($candidate.path)"
    $checked++
    $tail = Read-BoundedSessionTail -Path $path
    $bytesExamined += [long]$tail.bytes
    if (Test-BoundedTailHasCompletedQaForDay -Text $tail.text -TargetDay $TargetDay) {
      return [pscustomobject]@{
        has_qa = $true
        source = 'scan_state_main_realtime_bounded_tail'
        sessions_checked = $checked
        bytes_examined = $bytesExamined
        evidence = $path
      }
    }
  }
  return [pscustomobject]@{ has_qa = $false; source = 'bounded_evidence_absent'; sessions_checked = $checked; bytes_examined = $bytesExamined; evidence = $null }
}

function Get-DateQaActivity {
  param([string]$TargetDay)
  $manifestPath = Join-Path (Join-Path (Join-Path $DiaryRoot $TargetDay) '_meta') 'manifest.jsonl'
  if (Test-Path -LiteralPath $manifestPath) {
    foreach ($line in Get-Content -LiteralPath $manifestPath -TotalCount 32) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try {
        $record = $line | ConvertFrom-Json
        if (-not [string]::IsNullOrWhiteSpace("$($record.question_time)")) {
          return [pscustomobject]@{ has_qa = $true; source = 'manifest'; sessions_checked = 0; bytes_examined = 0; evidence = $manifestPath }
        }
      } catch { continue }
    }
  }
  return Get-BoundedSessionQaEvidence -TargetDay $TargetDay
}

function Append-JsonlUnique {
  param(
    [string]$Path,
    [object[]]$Objects,
    [string]$IdField
  )

  if ($NoWrite -or $Objects.Count -eq 0) { return 0 }

  $existingIds = @{}
  foreach ($item in Read-Jsonl -Path $Path) {
    $id = Get-ObjectValue -Object $item -Name $IdField
    if ($null -ne $id -and "$id".Length -gt 0) { $existingIds["$id"] = $true }
  }

  $newLines = New-Object System.Collections.Generic.List[string]
  foreach ($object in $Objects) {
    $id = Get-ObjectValue -Object $object -Name $IdField
    if ($null -eq $id -or "$id".Length -eq 0) { throw "Object missing id field $IdField for $Path" }
    if ($existingIds.ContainsKey("$id")) { continue }
    $existingIds["$id"] = $true
    $newLines.Add((ConvertTo-JsonLine -Object $object))
  }

  if ($newLines.Count -gt 0) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    Add-Content -LiteralPath $Path -Encoding UTF8 -Value $newLines
  }
  return $newLines.Count
}

function Test-HighSignalTopic {
  param([string]$Topic)
  $t = $Topic.Trim()
  if ($t.Length -lt 4) { return $false }
  if ($t -match '^(嗯|好|好的|可以|行|继续|收到|稍等|等消息|发给你看看)[。.!！\s]*$') { return $false }

  $patterns = @(
    '记住|以后|长期|偏好|习惯|规则|规矩|红线|边界|授权|禁止|不要|必须|默认',
    '自动|全局|AGENTS|SKILL|skill|QA|日记|记忆|候选|active|candidate|提升|召回|索引|维护',
    '策略|方案|裁决|同意|不同意|否决|确认|整改|迁移|复核|检查|审查',
    '修复|BUG|失败|问题|根因|风险|阻塞|完成|验证|压缩|交接|五件套|三件套',
    '外部智能体|本地助手|assistant integration|local assistant|Codex|subagent|子智能体|worktree|工具|脚本'
  )

  foreach ($pattern in $patterns) {
    if ($t -match $pattern) { return $true }
  }
  return $false
}

function Get-TypeInfo {
  param([string]$Topic)
  if ($Topic -match '偏好|习惯') { return @{ code = 201; label = '偏好' } }
  if ($Topic -match '规则|规矩|红线|必须|默认|禁止|不要|边界') { return @{ code = 202; label = '规则' } }
  if ($Topic -match '同意|不同意|裁决|确认|否决|决定|授权') { return @{ code = 203; label = '决策' } }
  if ($Topic -match '失败|BUG|根因|修复|问题') { return @{ code = 206; label = '失败经验' } }
  if ($Topic -match '工具|脚本|服务|端口|运行') { return @{ code = 207; label = '工具状态' } }
  return @{ code = 213; label = '事件卡' }
}

function Get-ScopeInfo {
  param([string]$Topic, [string]$Scope, [string]$File)
  if ($Topic -match 'QA|日记|记忆|candidate|active|召回|terms|qa-memory') {
    return @{ code = 408; label = 'qa-memory（QA 存取系统自身范围）'; type = 'qa-memory'; id = 'global.codex.qa' }
  }
  if ($Topic -match '外部智能体|本地助手|assistant integration|local assistant') {
    return @{ code = 407; label = 'assistant-integration（外部智能体或本地助手集成范围）'; type = 'assistant-integration'; id = 'assistant.integration' }
  }
  if ($Topic -match 'SKILL|skill') {
    return @{ code = 404; label = 'skill（某 skill 范围）'; type = 'skill'; id = 'codex.skills' }
  }
  if ($Topic -match '工具|脚本|服务|端口|运行') {
    return @{ code = 403; label = 'tool（工具范围）'; type = 'tool'; id = 'codex.local-tools' }
  }
  if ($Scope -match 'Project') {
    $projectId = [IO.Path]::GetFileNameWithoutExtension($File)
    if ([string]::IsNullOrWhiteSpace($projectId)) { $projectId = 'unknown-project' }
    return @{ code = 402; label = 'project（项目范围）'; type = 'project'; id = "qa-diary.$projectId" }
  }
  return @{ code = 400; label = 'global.codex（全局 Codex 偏好或规则）'; type = 'global'; id = 'global.codex' }
}

function Get-SensitiveInfo {
  param([string]$Topic)
  if ($Topic -match '(key|token|cookie|Authorization|Bearer|密码|凭据|账号|private key)') {
    return @{ sensitive = 'redacted'; risk = 'review_required_context' }
  }
  if ($Topic -match '(授权|发布|删除|服务|重启|全局|AGENTS|外部智能体真实生效区)') {
    return @{ sensitive = 'none'; risk = 'review_required_context' }
  }
  return @{ sensitive = 'none'; risk = 'recall_topic' }
}

function Get-Aliases {
  param([string]$Title, [string]$Topic)
  $aliases = New-Object System.Collections.Generic.List[string]
  foreach ($value in @($Title, $Topic, ($Title -replace '[\s，。、“”‘’：:；;（）()【】\[\]<>《》/\\|-]', ''))) {
    $v = "$value".Trim()
    if ($v.Length -gt 0 -and -not $aliases.Contains($v)) { $aliases.Add($v) }
  }
  $question1 = "之前聊过$Title吗"
  $question2 = "$Title 当时怎么定的"
  foreach ($value in @($question1, $question2)) {
    if ($value.Length -le 80 -and -not $aliases.Contains($value)) { $aliases.Add($value) }
  }
  return @($aliases.ToArray())
}

function Parse-Timeline {
  param([string]$IndexPath)
  $items = New-Object System.Collections.Generic.List[object]
  $timelineStarted = $false
  foreach ($line in Get-Content -LiteralPath $IndexPath) {
    if ($line -match '^##\s+Script Timeline') {
      $timelineStarted = $true
      continue
    }
    if (-not $timelineStarted) { continue }
    if ($line -notmatch '^\|') { continue }
    $cells = $line.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() }
    if ($cells.Count -lt 4) { continue }
    if ($cells[0] -eq 'Time' -or $cells[0] -match '^-+$') { continue }
    $topic = $cells[2]
    if (-not (Test-HighSignalTopic -Topic $topic)) { continue }
    $items.Add([pscustomobject]@{
      time = $cells[0]
      scope = $cells[1]
      topic = $topic
      file = ($cells[3] -replace '^`|`$', '')
    })
  }
  return @($items.ToArray())
}

$candidateDir = Join-Path $MemoryRoot 'candidates'
$machineDir = Join-Path $MemoryRoot 'machine'
$maintenanceDir = Join-Path $MemoryRoot 'maintenance'
$indexPath = Join-Path (Join-Path $DiaryRoot $Date) '_index.md'
$month = $Date.Substring(0, 7)
$candidatePath = Join-Path $candidateDir "$month.md"
$memoryIndexPath = Join-Path $MemoryRoot '03-索引.md'
$reportPath = Join-Path $maintenanceDir "$Date.md"

$eventsPath = Join-Path $machineDir 'events.jsonl'
$nodesPath = Join-Path $machineDir 'nodes.jsonl'
$edgesPath = Join-Path $machineDir 'edges.jsonl'
$sourcesPath = Join-Path $machineDir 'sources.jsonl'
$termsPath = Join-Path $machineDir 'terms.jsonl'
$auditPath = Join-Path $machineDir 'audit.jsonl'

foreach ($dir in @($candidateDir, $machineDir, $maintenanceDir)) {
  if (-not $NoWrite) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
}

$status = 'ok'
$reason = ''
$timeline = @()
$timelineTotal = 0
$timelinePendingBeforeLimit = 0
$dateQaActivity = $null
if (Test-Path -LiteralPath $indexPath) {
  $allTimeline = @(Parse-Timeline -IndexPath $indexPath)
  $timelineTotal = $allTimeline.Count
  $existingNodeIds = @{}
  foreach ($existingNode in Read-Jsonl -Path $nodesPath) {
    $existingNodeId = Get-ObjectValue -Object $existingNode -Name 'node_id'
    if ($null -ne $existingNodeId -and "$existingNodeId".Length -gt 0) {
      $existingNodeIds["$existingNodeId"] = $true
    }
  }
  $pendingNodeIds = @{}
  $pendingTimeline = @($allTimeline | Where-Object {
    $sourceKey = "$Date|$($_.time)|$($_.file)|$($_.topic)"
    $candidateNodeId = "N-$dateCompact-A$(Get-ShortHash -Text $sourceKey)"
    if ($existingNodeIds.ContainsKey($candidateNodeId) -or $pendingNodeIds.ContainsKey($candidateNodeId)) {
      return $false
    }
    $pendingNodeIds[$candidateNodeId] = $true
    return $true
  })
  $timelinePendingBeforeLimit = $pendingTimeline.Count
  $timeline = @($pendingTimeline | Select-Object -First $MaxCandidates)
} else {
  $dateQaActivity = Get-DateQaActivity -TargetDay $Date
  $status = if ($dateQaActivity.has_qa) { 'no_diary_index_with_main_activity' } else { 'no_diary_index' }
  $reason = "missing $indexPath"
}

$candidateSections = New-Object System.Collections.Generic.List[string]
$eventObjects = New-Object System.Collections.Generic.List[object]
$nodeObjects = New-Object System.Collections.Generic.List[object]
$edgeObjects = New-Object System.Collections.Generic.List[object]
$sourceObjects = New-Object System.Collections.Generic.List[object]
$termObjects = New-Object System.Collections.Generic.List[object]
$sourceIds = New-Object System.Collections.Generic.List[string]

foreach ($item in $timeline) {
  $sourceKey = "$Date|$($item.time)|$($item.file)|$($item.topic)"
  $hash = Get-ShortHash -Text $sourceKey
  $eventId = "EC-$dateCompact-A$hash"
  $nodeId = "N-$dateCompact-A$hash"
  $edgeId = "R-$dateCompact-A$hash"
  $sourceId = "SRC-AUTO-$dateCompact-$hash"
  $termId = "TERM-$dateCompact-A$hash"

  $title = $item.topic.Trim()
  if ($title.Length -gt 36) { $title = $title.Substring(0, 36) }
  $summary = $item.topic.Trim()
  if ($summary.Length -gt 180) { $summary = $summary.Substring(0, 180) + '...' }

  $type = Get-TypeInfo -Topic $item.topic
  $scope = Get-ScopeInfo -Topic $item.topic -Scope $item.scope -File $item.file
  $sensitive = Get-SensitiveInfo -Topic $item.topic
  $aliases = Get-Aliases -Title $title -Topic $item.topic
  $sourcePointer = "qa-diary/$Date/$($item.file)#timeline-$($item.time)-$hash"

  $sourceIds.Add($sourceId)

  $candidateSections.Add("")
  $candidateSections.Add("### $nodeId - $title")
  $candidateSections.Add("")
  $candidateSections.Add('```yaml')
  $candidateSections.Add("event_id: $eventId")
  $candidateSections.Add("title: $title")
  $candidateSections.Add("time: $Date $($item.time)")
  $candidateSections.Add("scope_code: $($scope.code)")
  $candidateSections.Add("scope_label: $($scope.label)")
  $candidateSections.Add("scope: $($scope.id)")
  $candidateSections.Add("summary: $summary")
  $candidateSections.Add("source_ref: $sourceId")
  $candidateSections.Add("status_code: 300")
  $candidateSections.Add("status_label: candidate（候选，未生效）")
  $candidateSections.Add("nodes:")
  $candidateSections.Add("  - $nodeId")
  $candidateSections.Add("query_aliases:")
  foreach ($alias in $aliases) { $candidateSections.Add("  - $alias") }
  $candidateSections.Add("sensitive: $($sensitive.sensitive)")
  $candidateSections.Add("created_at: $Date")
  $candidateSections.Add("updated_at: $Date")
  $candidateSections.Add('```')
  $candidateSections.Add("")
  $candidateSections.Add('```yaml')
  $candidateSections.Add("node_id: $nodeId")
  $candidateSections.Add("type_code: $($type.code)")
  $candidateSections.Add("type_label: $($type.label)")
  $candidateSections.Add("status_code: 300")
  $candidateSections.Add("status_label: candidate（候选，未生效）")
  $candidateSections.Add("scope_code: $($scope.code)")
  $candidateSections.Add("scope_label: $($scope.label)")
  $candidateSections.Add("scope_type: $($scope.type)")
  $candidateSections.Add("scope_id: $($scope.id)")
  $candidateSections.Add("content: $title：$summary")
  $candidateSections.Add("source_ref: $sourceId")
  $candidateSections.Add("event_id: $eventId")
  $candidateSections.Add("created_at: $Date")
  $candidateSections.Add("updated_at: $Date")
  $candidateSections.Add("last_hit_at: never")
  $candidateSections.Add("risk_type: $($sensitive.risk)")
  $candidateSections.Add("confidence: low")
  $candidateSections.Add("tags: [daily-maintain, recall-topic, candidate]")
  $candidateSections.Add("sensitive: $($sensitive.sensitive)")
  $candidateSections.Add('```')

  $eventObjects.Add([pscustomobject]@{
    event_id = $eventId
    schema_version = 'qa-memory-machine-v2.0'
    title = $title
    time = $Date
    scope_code = $scope.code
    scope_label = $scope.label
    scope_type = $scope.type
    scope_id = $scope.id
    summary_zh = $summary
    source_ids = @($sourceId)
    status_code = 300
    status_label = 'candidate'
    node_ids = @($nodeId)
    gate_result = 'candidate_daily_maintenance_no_active_promotion'
    sensitive = $sensitive.sensitive
    created_at = $Date
    updated_at = $Date
    source_ref = $sourcePointer
    run_id = $runId
  })

  $nodeObjects.Add([pscustomobject]@{
    node_id = $nodeId
    schema_version = 'qa-memory-machine-v2.0'
    type_code = $type.code
    type_label = $type.label
    status_code = 300
    status_label = 'candidate'
    scope_code = $scope.code
    scope_label = $scope.label
    scope_type = $scope.type
    scope_id = $scope.id
    content_zh = "$title：$summary"
    source_ids = @($sourceId)
    source_ref = $sourceId
    event_id = $eventId
    confidence = 'low'
    risk_type = $sensitive.risk
    sensitive = $sensitive.sensitive
    created_at = $Date
    updated_at = $Date
    last_hit_at = 'never'
    tags = @('daily-maintain','recall-topic','candidate')
    cross_project_allowed = 0
    cross_project_label = '候选主题默认不跨项目自动生效'
    temporary_authorization = 0
    temporary_authorization_label = '不是临时授权'
    runtime_state = 0
    runtime_state_label = '不是运行态状态'
    run_id = $runId
  })

  $edgeObjects.Add([pscustomobject]@{
    edge_id = $edgeId
    schema_version = 'qa-memory-machine-v2.0'
    from = $nodeId
    to = $eventId
    rel_code = 105
    rel_label = '来源于（A 来源于 B）'
    status_code = 310
    status_label = 'verified'
    source_ref = $sourceId
    sensitive = $sensitive.sensitive
    created_at = $Date
    updated_at = $Date
    run_id = $runId
  })

  $sourceObjects.Add([pscustomobject]@{
    source_id = $sourceId
    schema_version = 'qa-memory-machine-v2.0'
    path = $indexPath
    source_type = 'qa_diary_index_timeline'
    date = $Date
    hash_or_anchor = "sha256:$hash#timeline-$($item.time)"
    sensitive = $sensitive.sensitive
    source_ref = $sourcePointer
    run_id = $runId
  })

  $termObjects.Add([pscustomobject]@{
    term_id = $termId
    schema_version = 'qa-memory-machine-v2.0'
    canonical_zh = $title
    canonical_en = 'daily recall topic'
    aliases = @($aliases)
    description_zh = "自动维护候选召回主题：$title"
    scope_type = $scope.type
    scope_id = $scope.id
    status_code = 300
    status_label = 'candidate-term'
    target_ids = @($nodeId)
    source_ids = @($sourceId)
    sensitive = $sensitive.sensitive
    tags = @('daily-maintain','recall-topic')
    updated_at = $Date
  })
}

$changed = [ordered]@{
  candidates_md = 0
  index_md = 0
  events_jsonl = 0
  nodes_jsonl = 0
  edges_jsonl = 0
  sources_jsonl = 0
  terms_jsonl = 0
  audit_jsonl = 0
  report_md = 0
}

if (-not $NoWrite -and $candidateSections.Count -gt 0) {
  $existingText = if (Test-Path -LiteralPath $candidatePath) { Get-Content -LiteralPath $candidatePath -Raw } else { "# QA 记忆候选 $month`r`n" }
  $seenCandidateIds = @{}
  foreach ($match in [regex]::Matches($existingText, '(?m)^###\s+(N-\S+)')) {
    $seenCandidateIds[$match.Groups[1].Value] = $true
  }
  $appendLines = New-Object System.Collections.Generic.List[string]
  $blockLines = New-Object System.Collections.Generic.List[string]
  $blockNode = $null

  foreach ($line in $candidateSections) {
    if ($line -match '^###\s+(N-\S+)') {
      if ($null -ne $blockNode -and -not $seenCandidateIds.ContainsKey($blockNode)) {
        foreach ($blockLine in $blockLines) { $appendLines.Add($blockLine) }
        $seenCandidateIds[$blockNode] = $true
      }
      $blockNode = $Matches[1]
      $blockLines = New-Object System.Collections.Generic.List[string]
    }
    if ($null -ne $blockNode) { $blockLines.Add($line) }
  }
  if ($null -ne $blockNode -and -not $seenCandidateIds.ContainsKey($blockNode)) {
    foreach ($blockLine in $blockLines) { $appendLines.Add($blockLine) }
    $seenCandidateIds[$blockNode] = $true
  }

  $newCandidateLines = New-Object System.Collections.Generic.List[string]
  if ($appendLines.Count -gt 0) {
    $newCandidateLines.Add("")
    $newCandidateLines.Add("## 自动维护批次 $Date")
    $newCandidateLines.Add("")
    $newCandidateLines.Add('```yaml')
    $newCandidateLines.Add("run_id: $runId")
    $newCandidateLines.Add("created_at: $Date")
    $newCandidateLines.Add("status: candidate_daily_maintenance")
    $newCandidateLines.Add("source: $indexPath")
    $newCandidateLines.Add("active_promotion: none")
    $newCandidateLines.Add("policy: 自动维护只写候选和别名，不提升 active。")
    $newCandidateLines.Add("candidate_count: $($appendLines | Where-Object { $_ -match '^### N-' } | Measure-Object | Select-Object -ExpandProperty Count)")
    $newCandidateLines.Add('```')
    foreach ($line in $appendLines) { $newCandidateLines.Add($line) }
  }

  if ($newCandidateLines.Count -gt 0) {
    if (-not (Test-Path -LiteralPath $candidatePath)) {
      Set-Content -LiteralPath $candidatePath -Encoding UTF8 -Value "# QA 记忆候选 $month"
    }
    Add-Content -LiteralPath $candidatePath -Encoding UTF8 -Value $newCandidateLines
    $changed.candidates_md = $newCandidateLines.Count
  }
}

if (-not $NoWrite -and $nodeObjects.Count -gt 0 -and (Test-Path -LiteralPath $memoryIndexPath)) {
  $indexText = Get-Content -LiteralPath $memoryIndexPath -Raw
  $seenIndexNodeIds = @{}
  foreach ($match in [regex]::Matches($indexText, '(?m)^\|\s*(N-\S+)\s*\|')) {
    $seenIndexNodeIds[$match.Groups[1].Value] = $true
  }
  $indexLines = New-Object System.Collections.Generic.List[string]
  foreach ($node in $nodeObjects) {
    if ($seenIndexNodeIds.ContainsKey("$($node.node_id)")) { continue }
    $content = "$($node.content_zh)" -replace '\|', '/'
    if ($content.Length -gt 180) { $content = $content.Substring(0, 180) + '...' }
    $recordPath = "candidates\$month.md"
    $indexLines.Add("| $($node.node_id) | $($node.type_code) | $($node.status_code) | $($node.scope_code) | $content | $($node.source_ref) | $recordPath |")
    $seenIndexNodeIds["$($node.node_id)"] = $true
  }
  if ($indexLines.Count -gt 0) {
    Add-Content -LiteralPath $memoryIndexPath -Encoding UTF8 -Value $indexLines
    $changed.index_md = $indexLines.Count
  }
  $updatedIndexText = Get-Content -LiteralPath $memoryIndexPath -Raw
  $candidateCount = ([regex]::Matches($updatedIndexText, '(?m)^\|\s*N-\d{8}-\S+\s+\|\s+\d+\s+\|\s+300\s+\|')).Count
  if ($candidateCount -gt 0) {
    $newText = [regex]::Replace($updatedIndexText, '- candidate 历史召回主题：\d+ 条。', "- candidate 历史召回主题：$candidateCount 条。")
    if ($newText -ne $updatedIndexText) {
      Set-Content -LiteralPath $memoryIndexPath -Encoding UTF8 -Value $newText
    }
  }
}

$changed.events_jsonl = Append-JsonlUnique -Path $eventsPath -Objects @($eventObjects.ToArray()) -IdField 'event_id'
$changed.nodes_jsonl = Append-JsonlUnique -Path $nodesPath -Objects @($nodeObjects.ToArray()) -IdField 'node_id'
$changed.edges_jsonl = Append-JsonlUnique -Path $edgesPath -Objects @($edgeObjects.ToArray()) -IdField 'edge_id'
$changed.sources_jsonl = Append-JsonlUnique -Path $sourcesPath -Objects @($sourceObjects.ToArray()) -IdField 'source_id'
$changed.terms_jsonl = Append-JsonlUnique -Path $termsPath -Objects @($termObjects.ToArray()) -IdField 'term_id'

$validateQaMemExit = $null
$validateQaMemOutput = @()
$validateStrictExit = $null
$validateStrictOutput = @()
if (-not $SkipValidation) {
  $qaMemPath = Join-Path $scriptRoot 'qa-mem.ps1'
  $strictPath = Join-Path $scriptRoot 'qa_memory_validate.ps1'
  if (Test-Path -LiteralPath $qaMemPath) {
    $validateQaMemOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $qaMemPath validate 2>&1
    $validateQaMemExit = $LASTEXITCODE
  }
  if (Test-Path -LiteralPath $strictPath) {
    $validateStrictOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $strictPath 2>&1
    $validateStrictExit = $LASTEXITCODE
  }
}

$auditStatus = if ($status -ne 'ok') { $status } elseif (($validateQaMemExit -ne $null -and $validateQaMemExit -ne 0) -or ($validateStrictExit -ne $null -and $validateStrictExit -ne 0)) { 'validate_failed' } else { 'ok' }
$audit = [pscustomobject]@{
  # Keep one record per state transition. A no_diary_index run followed by a
  # successful recovery must not be hidden behind the original daily ID.
  audit_id = "AUD-$dateCompact-$(Get-ShortHash -Text "$runId|$auditStatus")"
  schema_version = 'qa-memory-machine-v2.0'
  run_id = $runId
  action = 'daily-maintain'
  status = $auditStatus
  actor = 'qa_memory_maintain.ps1'
  source_ids = @($sourceIds.ToArray())
  changed_files = @($candidatePath,$eventsPath,$nodesPath,$edgesPath,$sourcesPath,$termsPath,$reportPath)
  created_at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
}
$changed.audit_jsonl = Append-JsonlUnique -Path $auditPath -Objects @($audit) -IdField 'audit_id'
if (-not $NoWrite) { $changed.report_md = 1 }

$report = New-Object System.Collections.Generic.List[string]
$report.Add("# QA memory daily maintenance - $Date")
$report.Add("")
$report.Add("- run_id: $runId")
$report.Add("- status: $auditStatus")
if ($reason.Length -gt 0) { $report.Add("- reason: $reason") }
$report.Add("- index: $indexPath")
$report.Add("- max_candidates: $MaxCandidates")
$report.Add("- timeline_hits: $($timeline.Count)")
$report.Add("- timeline_total: $timelineTotal")
$report.Add("- timeline_pending_before_limit: $timelinePendingBeforeLimit")
$report.Add("- timeline_pending_after_run: $([Math]::Max(0, $timelinePendingBeforeLimit - $timeline.Count))")
$report.Add("- active_promotion: none")
$report.Add("- global_agents_write: none")
$report.Add("")
$report.Add("## Changed")
foreach ($key in $changed.Keys) { $report.Add("- ${key}: $($changed[$key])") }
$report.Add("")
$report.Add("## Candidate Nodes")
if ($nodeObjects.Count -eq 0) {
  $report.Add("- none")
} else {
  foreach ($node in $nodeObjects) {
    $report.Add("- $($node.node_id): $($node.content_zh)")
  }
}
$report.Add("")
$report.Add("## Validation")
$report.Add("- qa-mem validate exit: $validateQaMemExit")
if ($validateQaMemOutput.Count -gt 0) {
  $report.Add('```text')
  foreach ($line in $validateQaMemOutput) { $report.Add("$line") }
  $report.Add('```')
}
$report.Add("- qa_memory_validate exit: $validateStrictExit")
if ($validateStrictOutput.Count -gt 0) {
  $report.Add('```text')
  foreach ($line in $validateStrictOutput) { $report.Add("$line") }
  $report.Add('```')
}

if (-not $NoWrite) {
  Set-Content -LiteralPath $reportPath -Encoding UTF8 -Value $report
  $changed.report_md = 1
}

$result = [pscustomobject]@{
  run_id = $runId
  status = $auditStatus
  index = $indexPath
  report = $reportPath
  candidates = $nodeObjects.Count
  changed = $changed
  validate_qa_mem_exit = $validateQaMemExit
  validate_strict_exit = $validateStrictExit
  date_qa_activity = $dateQaActivity
}

$result | ConvertTo-Json -Depth 20

if ($auditStatus -eq 'validate_failed') { exit 1 }
if ($auditStatus -eq 'no_diary_index_with_main_activity') { exit 2 }
exit 0
