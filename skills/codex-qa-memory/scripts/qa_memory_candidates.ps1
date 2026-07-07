param(
  [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
  [string]$DiaryRoot = "$env:USERPROFILE\.codex\qa-diary",
  [string]$MemoryRoot = "$env:USERPROFILE\.codex\qa-memory",
  [int]$MaxCandidates = 3,
  [switch]$WriteCandidate
)

$ErrorActionPreference = 'Stop'

$indexPath = Join-Path (Join-Path $DiaryRoot $Date) '_index.md'
if (-not (Test-Path -LiteralPath $indexPath)) {
  throw "QA diary index not found: $indexPath"
}

$month = $Date.Substring(0, 7)
$candidateDir = Join-Path $MemoryRoot 'candidates'
$candidatePath = Join-Path $candidateDir "$month.md"

$patterns = @(
  '记住',
  '以后都按',
  '不要再',
  '这是规则',
  '长期偏好',
  '授权边界',
  '安全禁令',
  '失败经验',
  '已修复',
  '修复完成',
  '已同意',
  '裁决'
)

$lines = Get-Content -LiteralPath $indexPath
$timelineStarted = $false
$hits = @()
foreach ($line in $lines) {
  if ($line -match '^##\s+Script Timeline') {
    $timelineStarted = $true
    continue
  }
  if (-not $timelineStarted) { continue }
  if ($line -notmatch '^\|\s*\d') { continue }
  $cells = $line.Trim() -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
  if ($cells.Count -lt 4) { continue }
  $topic = $cells[2]
  foreach ($pattern in $patterns) {
    if ($topic -match [regex]::Escape($pattern)) {
      $text = $topic.Trim()
      if ($text.Length -gt 0) {
        $hits += [pscustomobject]@{ pattern = $pattern; text = $text; source = $indexPath }
      }
      break
    }
  }
  if ($hits.Count -ge $MaxCandidates) { break }
}

$dateCompact = $Date -replace '-', ''
$output = New-Object System.Collections.Generic.List[string]
$output.Add("# QA memory candidates from $Date")
$output.Add("")
$output.Add("- source_ref: $indexPath")
$output.Add("- status: candidate_only")
$output.Add("- max_candidates: $MaxCandidates")
$output.Add("- note: 候选不等于 active；必须人工复核后才能提升。")
$output.Add("")

if ($hits.Count -eq 0) {
  $output.Add("未从当天 `_index.md` 命中候选触发词。")
} else {
  for ($i = 0; $i -lt $hits.Count; $i++) {
    $n = "{0:D3}" -f ($i + 1)
    $eventId = "EC-$dateCompact-C$n"
    $nodeId = "N-$dateCompact-C$n"
    $raw = $hits[$i].text
    if ($raw.Length -gt 100) { $raw = $raw.Substring(0, 100) + '...' }
    $typeCode = if ($hits[$i].pattern -match '偏好') { 201 } elseif ($hits[$i].pattern -match '授权') { 211 } elseif ($hits[$i].pattern -match '失败') { 206 } elseif ($hits[$i].pattern -match '裁决|同意') { 203 } else { 202 }
    $riskType = if ($hits[$i].pattern -match '授权|安全|禁令') { 'high_requires_review' } else { 'candidate_unknown' }
    $output.Add("## $eventId")
    $output.Add("")
    $output.Add('```yaml')
    $output.Add("event_id: $eventId")
    $output.Add("title: QA 候选记忆 $n")
    $output.Add("time: $Date")
    $output.Add("scope_code: 408")
    $output.Add("summary: $raw")
    $output.Add("source_ref: $indexPath")
    $output.Add("status_code: 300")
    $output.Add("status_label: candidate")
    $output.Add("nodes: [$nodeId]")
    $output.Add("gate_result: candidate_needs_review")
    $output.Add('sensitive: not_scanned_full_diary')
    $output.Add('```')
    $output.Add("")
    $output.Add("### $nodeId")
    $output.Add("")
    $output.Add('```yaml')
    $output.Add("node_id: $nodeId")
    $output.Add("type_code: $typeCode")
    $output.Add("status_code: 300")
    $output.Add("status_label: candidate")
    $output.Add("scope_code: 408")
    $output.Add("scope_type: qa-memory")
    $output.Add("scope_id: global.codex.qa")
    $output.Add("content: $raw")
    $output.Add("source_ref: $indexPath")
    $output.Add("event_id: $eventId")
    $output.Add("created_at: $Date")
    $output.Add('last_hit_at: never')
    $output.Add("risk_type: $riskType")
    $output.Add("confidence: low")
    $output.Add("tags: [candidate, from-index]")
    $output.Add('sensitive: not_scanned_full_diary')
    $output.Add('```')
    $output.Add("")
  }
}

if ($WriteCandidate) {
  New-Item -ItemType Directory -Force -Path $candidateDir | Out-Null
  $output | Set-Content -LiteralPath $candidatePath -Encoding UTF8
  "wrote candidate file: $candidatePath"
} else {
  $output
}
