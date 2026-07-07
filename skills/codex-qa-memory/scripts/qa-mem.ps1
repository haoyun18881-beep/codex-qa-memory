[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('get', 'graph', 'validate', 'put', 'link', 'promote', 'rebuild-index', 'help')]
  [string]$Command = 'get',

  [string]$Root = "$env:USERPROFILE\.codex\qa-memory",
  [string]$Query = '',
  [string[]]$Scope = @(),
  [string[]]$Status = @('active', '302'),
  [string[]]$TypeCode = @(),
  [switch]$IncludeCandidate,
  [ValidateSet('quick', 'project', 'deep')]
  [string]$Mode = 'quick',
  [int]$Limit = 0,
  [ValidateRange(0, 2)]
  [int]$Expand = 1,
  [ValidateSet('llm', 'json')]
  [string]$Format = 'llm',

  [string]$NodeId = '',
  [ValidateRange(1, 2)]
  [int]$Hops = 1,

  [switch]$DryRun,
  [string]$Actor = '',
  [string]$Reason = '',
  [string[]]$Source = @()
)

$ErrorActionPreference = 'Stop'

$script:TypeLabels = @{
  200 = '事实'; 201 = '偏好'; 202 = '规则'; 203 = '决策'; 204 = '任务状态'
  205 = '项目状态'; 206 = '失败经验'; 207 = '工具状态'; 208 = '证据'
  209 = '风险'; 210 = '用户否决'; 211 = '用户授权'; 212 = '历史版本'
  213 = '事件卡'
}
$script:StatusLabels = @{
  300 = 'candidate'; 301 = 'soft-active'; 302 = 'active'; 303 = 'review_required'
  304 = 'conflict'; 305 = 'superseded'; 306 = 'rejected'; 307 = 'stale'
  308 = 'archived'; 309 = 'expired'; 310 = 'verified'; 311 = 'unverified'
}
$script:ScopeLabels = @{
  400 = 'global.codex'; 401 = 'user.preference'; 402 = 'project'; 403 = 'tool'
  404 = 'skill'; 405 = 'thread'; 406 = 'run'; 407 = 'openclaw'; 408 = 'qa-memory'
}
$script:RelationLabels = @{
  100 = '支持'; 101 = '反驳'; 102 = '覆盖'; 103 = '继承'; 104 = '依赖'
  105 = '来源于'; 106 = '适用于'; 107 = '不适用于'; 108 = '同义'
  109 = '冲突'; 110 = '因果'; 111 = '时间先后'; 112 = '项目归属'
  113 = '工具归属'; 114 = '同任务'; 115 = '修正'
}
$script:ModeBudgets = @{
  quick = @{ Nodes = 6; Chars = 1200 }
  project = @{ Nodes = 15; Chars = 3000 }
  deep = @{ Nodes = 40; Chars = 8000 }
}

function Get-CodeLabel {
  param(
    [hashtable]$Table,
    [int]$Code
  )
  if ($Table.ContainsKey($Code)) { return $Table[$Code] }
  return "$Code"
}

function Convert-IndexRow {
  param([string]$Line)

  $cells = $Line.Trim() -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
  if ($cells.Count -lt 7) { return $null }

  [int]$typeCode = 0
  [int]$statusCode = 0
  [int]$scopeCode = 0
  if (-not [int]::TryParse($cells[1], [ref]$typeCode)) { return $null }
  if (-not [int]::TryParse($cells[2], [ref]$statusCode)) { return $null }
  if (-not [int]::TryParse($cells[3], [ref]$scopeCode)) { return $null }

  [pscustomobject]@{
    node_id = $cells[0]
    type_code = $typeCode
    type_label = Get-CodeLabel -Table $script:TypeLabels -Code $typeCode
    status_code = $statusCode
    status_label = Get-CodeLabel -Table $script:StatusLabels -Code $statusCode
    scope_code = $scopeCode
    scope_label = Get-CodeLabel -Table $script:ScopeLabels -Code $scopeCode
    content = $cells[4]
    source_ref = $cells[5]
    record_path = $cells[6]
    origin = 'index'
  }
}

function Read-IndexNodes {
  param([string]$MemoryRoot)

  $indexPath = Join-Path $MemoryRoot '03-索引.md'
  if (-not (Test-Path -LiteralPath $indexPath)) {
    throw "QA memory index not found: $indexPath"
  }

  $nodes = New-Object System.Collections.Generic.List[object]
  foreach ($line in (Get-Content -LiteralPath $indexPath)) {
    if ($line -notmatch '^\|\s*N-\d{8}-') { continue }
    $node = Convert-IndexRow -Line $line
    if ($null -ne $node) { $nodes.Add($node) }
  }
  return $nodes.ToArray()
}

function Resolve-StatusCodes {
  param(
    [string[]]$Values,
    [switch]$AllowCandidate
  )

  $map = @{
    candidate = 300; 'soft-active' = 301; softactive = 301; active = 302
    review_required = 303; review = 303; conflict = 304; superseded = 305
    rejected = 306; stale = 307; archived = 308; expired = 309
    verified = 310; unverified = 311
  }
  $codes = New-Object System.Collections.Generic.List[int]
  foreach ($value in $Values) {
    foreach ($part in ("$value" -split ',')) {
      $token = $part.Trim()
      if ($token.Length -eq 0) { continue }
      $lower = $token.ToLowerInvariant()
      [int]$parsed = 0
      if ([int]::TryParse($token, [ref]$parsed)) {
        $codes.Add($parsed)
      } elseif ($map.ContainsKey($lower)) {
        $codes.Add([int]$map[$lower])
      } else {
        throw "Unknown status filter: $token"
      }
    }
  }
  if ($codes.Count -eq 0) { $codes.Add(302) }
  if ($AllowCandidate -and -not ($codes -contains 300)) { $codes.Add(300) }
  return @($codes.ToArray() | Select-Object -Unique)
}

function Resolve-IntFilters {
  param([string[]]$Values, [string]$Name)

  $codes = New-Object System.Collections.Generic.List[int]
  foreach ($value in $Values) {
    foreach ($part in ("$value" -split ',')) {
      $token = $part.Trim()
      if ($token.Length -eq 0) { continue }
      [int]$parsed = 0
      if (-not [int]::TryParse($token, [ref]$parsed)) {
        throw "Unknown $Name filter: $token"
      }
      $codes.Add($parsed)
    }
  }
  return @($codes.ToArray() | Select-Object -Unique)
}

function Test-ScopeMatch {
  param(
    [object]$Node,
    [string[]]$ScopeFilters
  )

  if ($ScopeFilters.Count -eq 0) { return $true }
  foreach ($scopeValue in $ScopeFilters) {
    foreach ($part in ("$scopeValue" -split ',')) {
      $token = $part.Trim()
      if ($token.Length -eq 0) { continue }
      [int]$asInt = 0
      if ([int]::TryParse($token, [ref]$asInt)) {
        if ($Node.scope_code -eq $asInt) { return $true }
      } else {
        if ($Node.scope_label -like "*$token*") { return $true }
        if ($Node.source_ref -like "*$token*") { return $true }
        if ($Node.record_path -like "*$token*") { return $true }
      }
    }
  }
  return $false
}

function Test-QueryMatch {
  param(
    [object]$Node,
    [string[]]$Needles
  )

  $activeNeedles = @($Needles | Where-Object { $null -ne $_ -and "$_".Trim().Length -gt 0 } | Select-Object -Unique)
  if ($activeNeedles.Count -eq 0) { return $true }

  foreach ($needle in $activeNeedles) {
    $trimmed = "$needle".Trim()
    if (
      $Node.node_id -like "*$trimmed*" -or
      $Node.content -like "*$trimmed*" -or
      $Node.source_ref -like "*$trimmed*" -or
      $Node.record_path -like "*$trimmed*"
    ) {
      return $true
    }
  }
  return $false
}

function Resolve-TextArray {
  param([object]$Value)

  $items = New-Object System.Collections.Generic.List[string]
  if ($null -eq $Value) { return @() }

  if ($Value -is [array]) {
    foreach ($item in $Value) {
      $text = "$item".Trim()
      if ($text.Length -gt 0) { $items.Add($text) }
    }
  } elseif ($Value -is [string]) {
    $raw = $Value.Trim()
    if ($raw.Length -eq 0) { return @() }
    if ($raw.StartsWith('[')) {
      try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($item in @($parsed)) {
          $text = "$item".Trim()
          if ($text.Length -gt 0) { $items.Add($text) }
        }
      } catch {
        $items.Add($raw)
      }
    } else {
      $items.Add($raw)
    }
  } else {
    $items.Add("$Value")
  }

  return @($items.ToArray())
}

function Get-TermExpansion {
  param(
    [string]$MemoryRoot,
    [string]$Needle
  )

  $trimmed = $Needle.Trim()
  $needles = New-Object System.Collections.Generic.List[string]
  if ($trimmed.Length -gt 0) { $needles.Add($trimmed) }
  $targetIds = New-Object System.Collections.Generic.List[string]
  $hits = New-Object System.Collections.Generic.List[object]

  if ($trimmed.Length -eq 0) {
    return [pscustomobject]@{ needles = @($needles.ToArray()); target_ids = @(); hits = @() }
  }

  $termsPath = Join-Path $MemoryRoot 'machine\terms.jsonl'
  if (-not (Test-Path -LiteralPath $termsPath)) {
    return [pscustomobject]@{ needles = @($needles.ToArray()); target_ids = @(); hits = @() }
  }

  $queryLower = $trimmed.ToLowerInvariant()
  $queryVariants = Get-QueryVariants -Text $trimmed
  $lineNo = 0
  foreach ($line in (Get-Content -LiteralPath $termsPath)) {
    $lineNo++
    if ($line.Trim().Length -eq 0) { continue }
    try {
      $term = $line | ConvertFrom-Json -ErrorAction Stop
    } catch {
      continue
    }

    $candidateTexts = New-Object System.Collections.Generic.List[string]
    foreach ($fieldName in @('canonical_zh', 'canonical_en', 'description_zh', 'description')) {
      $value = Get-ObjectPropertyValue -Object $term -Names @($fieldName)
      if ($null -ne $value -and "$value".Trim().Length -gt 0) { $candidateTexts.Add("$value") }
    }
    foreach ($alias in (Resolve-TextArray -Value (Get-ObjectPropertyValue -Object $term -Names @('aliases')))) {
      $candidateTexts.Add($alias)
    }
    foreach ($tag in (Resolve-TextArray -Value (Get-ObjectPropertyValue -Object $term -Names @('tags')))) {
      $candidateTexts.Add($tag)
    }

    $matched = $false
    foreach ($text in @($candidateTexts.ToArray() | Select-Object -Unique)) {
      $candidate = "$text".Trim()
      if ($candidate.Length -lt 2 -or $trimmed.Length -lt 2) { continue }
      $candidateLower = $candidate.ToLowerInvariant()
      $candidateVariants = Get-QueryVariants -Text $candidate
      foreach ($candidateVariant in $candidateVariants) {
        foreach ($queryVariant in $queryVariants) {
          if (Test-TermTextMatch -Candidate $candidateVariant -Query $queryVariant) {
            $matched = $true
            break
          }
        }
        if ($matched) { break }
      }
      if ($matched) { break }
    }

    if (-not $matched) { continue }

    foreach ($text in @($candidateTexts.ToArray() | Select-Object -Unique)) {
      $value = "$text".Trim()
      if ($value.Length -gt 0 -and -not ($needles.Contains($value))) { $needles.Add($value) }
    }

    $termTargets = @(Resolve-TextArray -Value (Get-ObjectPropertyValue -Object $term -Names @('target_ids')))
    foreach ($target in $termTargets) {
      if ($target.Length -gt 0 -and -not ($targetIds.Contains($target))) { $targetIds.Add($target) }
    }

    $hits.Add([pscustomobject]@{
      term_id = if ($null -ne $term.term_id) { "$($term.term_id)" } else { "$($termsPath):$lineNo" }
      canonical = if ($null -ne $term.canonical_zh) { "$($term.canonical_zh)" } else { "$($term.canonical_en)" }
      target_ids = $termTargets
      source_ids = @(Resolve-TextArray -Value (Get-ObjectPropertyValue -Object $term -Names @('source_ids')))
    })
  }

  return [pscustomobject]@{
    needles = @($needles.ToArray() | Select-Object -Unique)
    target_ids = @($targetIds.ToArray() | Select-Object -Unique)
    hits = @($hits.ToArray())
  }
}

function Get-QueryVariants {
  param([string]$Text)

  $raw = "$Text".Trim()
  if ($raw.Length -eq 0) { return @() }

  $variants = New-Object System.Collections.Generic.List[string]
  foreach ($value in @($raw, ($raw -replace '\s+', ''))) {
    $candidate = "$value".Trim().ToLowerInvariant()
    if ($candidate.Length -gt 0 -and -not $variants.Contains($candidate)) { $variants.Add($candidate) }
  }

  $normalized = ($raw -replace '\s+', '').ToLowerInvariant()
  $normalized = $normalized -replace '(怎么来的|怎么定的|怎么定|怎么处理|为什么|是什么|叫什么|怎么办|怎么|为何|吗|呢|啊|的)$', ''
  $normalized = $normalized -replace '(之前|当时|我们|咱们)', ''
  if ($normalized.Length -gt 0 -and -not $variants.Contains($normalized)) { $variants.Add($normalized) }

  return @($variants.ToArray())
}

function Test-TermTextMatch {
  param(
    [string]$Candidate,
    [string]$Query
  )

  $candidateText = "$Candidate".Trim().ToLowerInvariant()
  $queryText = "$Query".Trim().ToLowerInvariant()
  if ($candidateText.Length -lt 2 -or $queryText.Length -lt 2) { return $false }
  if ($candidateText -eq $queryText) { return $true }

  # Two-character aliases such as “调度” are too broad for substring matching.
  if ($candidateText.Length -le 2 -or $queryText.Length -le 2) { return $false }

  return ($candidateText.Contains($queryText) -or $queryText.Contains($candidateText))
}

function Get-MatchReason {
  param(
    [object]$Node,
    [string]$Needle,
    [bool]$AddedByExpansion
  )

  if ($AddedByExpansion) { return '同来源扩展' }
  if ($Needle.Trim().Length -gt 0) { return '查询命中' }
  if ($Node.status_code -eq 302) { return '默认active' }
  if ($Node.status_code -eq 300) { return '显式候选' }
  return '筛选命中'
}

function Test-NaturalRecallQuery {
  param([string]$Text)

  $trimmed = "$Text".Trim()
  if ($trimmed.Length -eq 0) { return $false }

  return ($trimmed -match '(之前聊过|之前我们说过|我们之前说过|我们做过|咱们之前做的|你还记得吗|以前说过|之前定过|之前怎么处理|当时怎么定|旧日记|历史记忆|长期记忆|回忆一下|查一下之前|之前.*聊|之前.*做|之前.*定)')
}

function Select-MemoryNodes {
  param(
    [object[]]$Nodes,
    [string]$Needle,
    [string[]]$ScopeFilters,
    [int[]]$StatusCodes,
    [int[]]$TypeCodes,
    [int]$MaxNodes,
    [int]$ExpandHops,
    [switch]$AllowCandidate,
    [string[]]$QueryNeedles = @(),
    [string[]]$TermTargetIds = @()
  )

  $filtered = @($Nodes | Where-Object {
    $queryMatch = Test-QueryMatch -Node $_ -Needles $QueryNeedles
    $termTargetMatch = $TermTargetIds -contains $_.node_id
    ($StatusCodes -contains $_.status_code) -and
    ($TypeCodes.Count -eq 0 -or $TypeCodes -contains $_.type_code) -and
    (Test-ScopeMatch -Node $_ -ScopeFilters $ScopeFilters) -and
    ($queryMatch -or $termTargetMatch) -and
    ($_.status_code -ne 300 -or $AllowCandidate)
  })

  $selected = New-Object System.Collections.Generic.List[object]
  $seen = @{}
  foreach ($node in $filtered) {
    if ($seen.ContainsKey($node.node_id)) { continue }
    $queryMatch = Test-QueryMatch -Node $node -Needles $QueryNeedles
    $termTargetMatch = $TermTargetIds -contains $node.node_id
    $reason = if ($termTargetMatch -and -not $queryMatch) { '术语target命中' } else { Get-MatchReason -Node $node -Needle $Needle -AddedByExpansion:$false }
    $selected.Add([pscustomobject]@{ node = $node; reason = $reason })
    $seen[$node.node_id] = $true
    if ($selected.Count -ge $MaxNodes) { return $selected.ToArray() }
  }

  if ($ExpandHops -le 0 -or $selected.Count -eq 0) { return $selected.ToArray() }

  $frontier = @($selected | ForEach-Object { $_.node })
  for ($hop = 1; $hop -le $ExpandHops; $hop++) {
    $nextFrontier = New-Object System.Collections.Generic.List[object]
    foreach ($base in $frontier) {
      $related = @($Nodes | Where-Object {
        $_.node_id -ne $base.node_id -and
        $_.source_ref -eq $base.source_ref -and
        ($_.status_code -ne 300 -or $AllowCandidate)
      })
      foreach ($node in $related) {
        if ($seen.ContainsKey($node.node_id)) { continue }
        $selected.Add([pscustomobject]@{ node = $node; reason = "第${hop}跳同source_ref" })
        $seen[$node.node_id] = $true
        $nextFrontier.Add($node)
        if ($selected.Count -ge $MaxNodes) { return $selected.ToArray() }
      }
    }
    $frontier = @($nextFrontier.ToArray())
    if ($frontier.Count -eq 0) { break }
  }

  return $selected.ToArray()
}

function Format-NodeLine {
  param(
    [object]$Node,
    [string]$Reason
  )

  return "$($Node.node_id) [$($Node.type_label)/$($Node.status_label)/$($Node.scope_label)] $($Node.content)；source=$($Node.source_ref)；reason=$Reason"
}

function Get-ObjectPropertyValue {
  param(
    [object]$Object,
    [string[]]$Names
  )

  if ($null -eq $Object) { return $null }
  foreach ($name in $Names) {
    $prop = $Object.PSObject.Properties | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
    if ($null -ne $prop) { return $prop.Value }
  }
  return $null
}

function Convert-ToIntOrZero {
  param([object]$Value)

  if ($null -eq $Value) { return 0 }
  [int]$parsed = 0
  if ([int]::TryParse("$Value", [ref]$parsed)) { return $parsed }
  return 0
}

function Read-MachineJsonl {
  param([string]$MemoryRoot)

  $machineDir = Join-Path $MemoryRoot 'machine'
  $result = [pscustomobject]@{
    machine_dir = $machineDir
    dir_exists = (Test-Path -LiteralPath $machineDir)
    files = @()
    records = @()
    errors = @()
  }

  if (-not $result.dir_exists) { return $result }

  $files = @(Get-ChildItem -LiteralPath $machineDir -File -Filter '*.jsonl' -ErrorAction SilentlyContinue | Sort-Object FullName)
  $result.files = @($files | ForEach-Object { $_.FullName })
  foreach ($file in $files) {
    $lineNo = 0
    foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
      $lineNo++
      if ($line.Trim().Length -eq 0) { continue }
      try {
        $obj = $line | ConvertFrom-Json -ErrorAction Stop
        $result.records += [pscustomobject]@{
          file = $file.FullName
          line = $lineNo
          object = $obj
        }
      } catch {
        $result.errors += "$($file.FullName):$lineNo JSONL解析失败: $($_.Exception.Message)"
      }
    }
  }

  return $result
}

function Resolve-SourceIdList {
  param([object]$Value)

  $tokens = New-Object System.Collections.Generic.List[string]
  if ($null -eq $Value) {
    return [pscustomobject]@{ ok = $false; ids = @(); error = 'source_ids为空' }
  }

  if ($Value -is [array]) {
    foreach ($item in $Value) {
      $text = "$item".Trim()
      if ($text.Length -gt 0) { $tokens.Add($text) }
    }
  } elseif ($Value -is [string]) {
    $raw = $Value.Trim()
    if ($raw.Length -eq 0) {
      return [pscustomobject]@{ ok = $false; ids = @(); error = 'source_ids字符串为空' }
    }
    if ($raw.StartsWith('[')) {
      try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($item in @($parsed)) {
          $text = "$item".Trim()
          if ($text.Length -gt 0) { $tokens.Add($text) }
        }
      } catch {
        return [pscustomobject]@{ ok = $false; ids = @(); error = "source_ids数组字符串不可解析: $($_.Exception.Message)" }
      }
    } else {
      foreach ($part in ($raw -split '[,; ]+')) {
        $text = $part.Trim()
        if ($text.Length -gt 0) { $tokens.Add($text) }
      }
    }
  } else {
    return [pscustomobject]@{ ok = $false; ids = @(); error = "source_ids类型不支持: $($Value.GetType().FullName)" }
  }

  if ($tokens.Count -eq 0) {
    return [pscustomobject]@{ ok = $false; ids = @(); error = 'source_ids未解析出ID' }
  }
  return [pscustomobject]@{ ok = $true; ids = @($tokens.ToArray()); error = '' }
}

function Get-MachineGraph {
  param(
    [object[]]$IndexNodes,
    [object]$Machine
  )

  $nodesById = @{}
  foreach ($node in $IndexNodes) {
    $nodesById[$node.node_id] = $node
  }

  $knownIds = @{}
  foreach ($node in $IndexNodes) { $knownIds[$node.node_id] = $true }

  $edges = New-Object System.Collections.Generic.List[object]

  foreach ($record in $Machine.records) {
    $obj = $record.object
    foreach ($field in @('node_id', 'event_id', 'edge_id', 'id')) {
      $value = Get-ObjectPropertyValue -Object $obj -Names @($field)
      if ($null -ne $value -and "$value".Trim().Length -gt 0) {
        $knownIds["$value"] = $true
      }
    }

    $nodeId = Get-ObjectPropertyValue -Object $obj -Names @('node_id')
    if ($null -ne $nodeId -and "$nodeId" -match '^N-') {
      $typeCode = Get-ObjectPropertyValue -Object $obj -Names @('type_code')
      $statusCode = Get-ObjectPropertyValue -Object $obj -Names @('status_code')
      $scopeCode = Get-ObjectPropertyValue -Object $obj -Names @('scope_code')
      $content = Get-ObjectPropertyValue -Object $obj -Names @('content_zh', 'content', 'summary_zh', 'summary', 'text')
      $sourceRef = Get-ObjectPropertyValue -Object $obj -Names @('source_ref', 'source')
      $nodesById["$nodeId"] = [pscustomobject]@{
        node_id = "$nodeId"
        type_code = Convert-ToIntOrZero -Value $typeCode
        type_label = if ($null -ne $typeCode) { Get-CodeLabel -Table $script:TypeLabels -Code ([int]$typeCode) } else { 'unknown' }
        status_code = Convert-ToIntOrZero -Value $statusCode
        status_label = if ($null -ne $statusCode) { Get-CodeLabel -Table $script:StatusLabels -Code ([int]$statusCode) } else { 'unknown' }
        scope_code = Convert-ToIntOrZero -Value $scopeCode
        scope_label = if ($null -ne $scopeCode) { Get-CodeLabel -Table $script:ScopeLabels -Code ([int]$scopeCode) } else { 'unknown' }
        content = if ($null -ne $content) { "$content" } else { '(machine node)' }
        source_ref = if ($null -ne $sourceRef) { "$sourceRef" } else { "$($record.file):$($record.line)" }
        record_path = $record.file
        origin = 'machine'
      }
    }

    $from = Get-ObjectPropertyValue -Object $obj -Names @('from', 'from_id', 'from_node_id', 'source_node_id', 'src', 'src_id')
    $to = Get-ObjectPropertyValue -Object $obj -Names @('to', 'to_id', 'to_node_id', 'target_node_id', 'dst', 'dst_id')
    if ($null -ne $from -or $null -ne $to) {
      $relationCode = Get-ObjectPropertyValue -Object $obj -Names @('relation_code', 'rel_code')
      $relation = Get-ObjectPropertyValue -Object $obj -Names @('relation', 'relation_label', 'type')
      $edgeId = Get-ObjectPropertyValue -Object $obj -Names @('edge_id', 'id')
      $label = if ($null -ne $relationCode -and "$relationCode" -match '^\d+$') {
        Get-CodeLabel -Table $script:RelationLabels -Code ([int]$relationCode)
      } elseif ($null -ne $relation) {
        "$relation"
      } else {
        '关系'
      }
      $edges.Add([pscustomobject]@{
        edge_id = if ($null -ne $edgeId) { "$edgeId" } else { "$($record.file):$($record.line)" }
        from = if ($null -ne $from) { "$from" } else { '' }
        to = if ($null -ne $to) { "$to" } else { '' }
        relation = $label
        relation_code = if ($null -ne $relationCode) { "$relationCode" } else { '' }
        source = "$($record.file):$($record.line)"
        implicit = $false
      })
    }
  }

  return [pscustomobject]@{
    nodes_by_id = $nodesById
    known_ids = $knownIds
    edges = @($edges.ToArray())
  }
}

function Write-JsonResult {
  param([object]$Value)
  $Value | ConvertTo-Json -Depth 8
}

function Invoke-Get {
  if (-not (Test-Path -LiteralPath $Root)) { throw "QA memory root not found: $Root" }

  $nodes = Read-IndexNodes -MemoryRoot $Root
  $termExpansion = Get-TermExpansion -MemoryRoot $Root -Needle $Query
  $naturalRecallQuery = Test-NaturalRecallQuery -Text $Query
  $targetedQuery = $Query.Trim().Length -gt 0
  $effectiveIncludeCandidate = [bool]$IncludeCandidate
  if ($targetedQuery -and -not $PSBoundParameters.ContainsKey('Status')) {
    $effectiveIncludeCandidate = $true
  }
  $statusCodes = Resolve-StatusCodes -Values $Status -AllowCandidate:$effectiveIncludeCandidate
  $typeCodes = Resolve-IntFilters -Values $TypeCode -Name 'TypeCode'
  $maxNodes = if ($Limit -gt 0) { $Limit } else { [int]$script:ModeBudgets[$Mode].Nodes }
  $selected = @(Select-MemoryNodes -Nodes $nodes -Needle $Query -ScopeFilters $Scope -StatusCodes $statusCodes -TypeCodes $typeCodes -MaxNodes $maxNodes -ExpandHops $Expand -AllowCandidate:$effectiveIncludeCandidate -QueryNeedles $termExpansion.needles -TermTargetIds $termExpansion.target_ids)
  $candidateInDefault = @($selected | Where-Object { $_.node.status_code -eq 300 }).Count

  if ($Format -eq 'json') {
    Write-JsonResult ([pscustomobject]@{
      command = 'get'
      mode = $Mode
      root = $Root
      filters = [pscustomobject]@{
        query = $Query
        expanded_query_terms = $termExpansion.needles
        term_target_ids = $termExpansion.target_ids
        scope = $Scope
        status_codes = $statusCodes
        type_codes = $typeCodes
        include_candidate = [bool]$effectiveIncludeCandidate
        natural_recall_candidate_search = [bool]($naturalRecallQuery -and $effectiveIncludeCandidate)
        targeted_candidate_search = [bool]($targetedQuery -and $effectiveIncludeCandidate)
        expand = $Expand
        limit = $maxNodes
      }
      nodes = @($selected | ForEach-Object {
        [pscustomobject]@{
          node_id = $_.node.node_id
          type_code = $_.node.type_code
          type_label = $_.node.type_label
          status_code = $_.node.status_code
          status_label = $_.node.status_label
          scope_code = $_.node.scope_code
          scope_label = $_.node.scope_label
          content = $_.node.content
          source = $_.node.source_ref
          record_path = $_.node.record_path
          reason = $_.reason
        }
      })
      candidate_in_default_result = $candidateInDefault
      term_hits = $termExpansion.hits
      stopped_by = "mode=$Mode limit=$maxNodes selected=$($selected.Count)"
    })
    return
  }

  "QA memory get"
  "mode=$Mode；status=$($statusCodes -join ',')；limit=$maxNodes；expand=$Expand；include_candidate=$([bool]$effectiveIncludeCandidate)"
  if ($naturalRecallQuery -and $effectiveIncludeCandidate) { "natural_recall_candidate_search=true；说明=自然回忆问题会纳入candidate候选主题，但candidate不等于已生效规则。" }
  elseif ($targetedQuery -and $effectiveIncludeCandidate) { "targeted_candidate_search=true；说明=具体历史主题查询会纳入candidate候选主题，但candidate不等于已生效规则。" }
  if ($Query.Trim().Length -gt 0) { "query=$Query" }
  foreach ($term in $termExpansion.hits) {
    $targets = if ($term.target_ids.Count -gt 0) { $term.target_ids -join ',' } else { 'none' }
    "term=$($term.canonical)；term_id=$($term.term_id)；targets=$targets；reason=术语别名命中"
  }
  if ($selected.Count -eq 0) {
    if ($termExpansion.hits.Count -gt 0) {
      "未命中符合条件的小节点；source=$(Join-Path $Root 'machine\terms.jsonl')；reason=术语已命中但尚未关联可取回 active 小节点"
    } else {
      "未命中符合条件的小节点；source=$(Join-Path $Root '03-索引.md')；reason=筛选后为空"
    }
  } else {
    foreach ($item in $selected) {
      Format-NodeLine -Node $item.node -Reason $item.reason
    }
  }
  "停止原因=mode_budget/limit；selected=$($selected.Count)"
}

function Invoke-Graph {
  if (-not (Test-Path -LiteralPath $Root)) { throw "QA memory root not found: $Root" }
  if ($NodeId.Trim().Length -eq 0) {
    throw "graph requires -NodeId N-..."
  }

  $nodes = Read-IndexNodes -MemoryRoot $Root
  $machine = Read-MachineJsonl -MemoryRoot $Root
  $graph = Get-MachineGraph -IndexNodes $nodes -Machine $machine
  if (-not $graph.nodes_by_id.ContainsKey($NodeId)) {
    throw "NodeId not found: $NodeId"
  }

  $maxNodes = if ($Limit -gt 0) { $Limit } else { 20 }
  $selectedIds = New-Object System.Collections.Generic.List[string]
  $seen = @{}
  $frontier = @($NodeId)
  $seen[$NodeId] = $true
  $selectedIds.Add($NodeId)
  $selectedEdges = New-Object System.Collections.Generic.List[object]

  for ($hop = 1; $hop -le $Hops; $hop++) {
    $next = New-Object System.Collections.Generic.List[string]
    foreach ($current in $frontier) {
      $directEdges = @($graph.edges | Where-Object { $_.from -eq $current -or $_.to -eq $current })
      foreach ($edge in $directEdges) {
        $other = if ($edge.from -eq $current) { $edge.to } else { $edge.from }
        if ($other.Trim().Length -eq 0) { continue }
        $selectedEdges.Add($edge)
        if (-not $seen.ContainsKey($other) -and $graph.nodes_by_id.ContainsKey($other)) {
          $seen[$other] = $true
          $selectedIds.Add($other)
          $next.Add($other)
          if ($selectedIds.Count -ge $maxNodes) { break }
        }
      }
      if ($selectedIds.Count -ge $maxNodes) { break }

      $baseNode = $graph.nodes_by_id[$current]
      if ($null -ne $baseNode.source_ref -and "$($baseNode.source_ref)".Trim().Length -gt 0) {
        $sameSource = @($graph.nodes_by_id.Values | Where-Object {
          $_.node_id -ne $current -and $_.source_ref -eq $baseNode.source_ref
        })
        foreach ($node in $sameSource) {
          $implicitEdge = [pscustomobject]@{
            edge_id = "implicit:same_source:${current}:$($node.node_id)"
            from = $current
            to = $node.node_id
            relation = '同source_ref'
            relation_code = ''
            source = $baseNode.source_ref
            implicit = $true
          }
          $selectedEdges.Add($implicitEdge)
          if (-not $seen.ContainsKey($node.node_id)) {
            $seen[$node.node_id] = $true
            $selectedIds.Add($node.node_id)
            $next.Add($node.node_id)
            if ($selectedIds.Count -ge $maxNodes) { break }
          }
        }
      }
      if ($selectedIds.Count -ge $maxNodes) { break }
    }
    $frontier = @($next.ToArray())
    if ($frontier.Count -eq 0 -or $selectedIds.Count -ge $maxNodes) { break }
  }

  $selectedNodes = @($selectedIds | ForEach-Object { $graph.nodes_by_id[$_] })

  if ($Format -eq 'json') {
    Write-JsonResult ([pscustomobject]@{
      command = 'graph'
      root = $Root
      node_id = $NodeId
      hops = $Hops
      limit = $maxNodes
      machine_jsonl_count = $machine.files.Count
      nodes = $selectedNodes
      edges = @($selectedEdges | Select-Object -Unique edge_id, from, to, relation, relation_code, source, implicit)
      stopped_by = "hops=$Hops limit=$maxNodes selected=$($selectedNodes.Count)"
    })
    return
  }

  "QA memory graph"
  "node=$NodeId；hops=$Hops；limit=$maxNodes；machine_jsonl_count=$($machine.files.Count)"
  foreach ($node in $selectedNodes) {
    $reasonText = if ($node.node_id -eq $NodeId) { '起点' } else { '关系扩展' }
    Format-NodeLine -Node $node -Reason $reasonText
  }
  if ($selectedEdges.Count -eq 0) {
    "关系=未找到显式边或同source_ref邻居；source=$(Join-Path $Root 'machine')"
  } else {
    foreach ($edge in (@($selectedEdges | Select-Object -Unique edge_id, from, to, relation, source) | Select-Object -First $maxNodes)) {
      "R [$($edge.relation)] $($edge.from) -> $($edge.to)；source=$($edge.source)；reason=graph_${Hops}跳"
    }
  }
  "停止原因=hops/limit；selected=$($selectedNodes.Count)"
}

function Invoke-Validate {
  if (-not (Test-Path -LiteralPath $Root)) { throw "QA memory root not found: $Root" }

  $errors = New-Object System.Collections.Generic.List[string]
  $warnings = New-Object System.Collections.Generic.List[string]
  $checks = New-Object System.Collections.Generic.List[object]

  $nodes = Read-IndexNodes -MemoryRoot $Root
  $indexNodeIds = @{}
  foreach ($node in $nodes) {
    if ($indexNodeIds.ContainsKey($node.node_id)) {
      $errors.Add("索引node_id重复: $($node.node_id)")
    } else {
      $indexNodeIds[$node.node_id] = $true
    }
  }
  $checks.Add([pscustomobject]@{ name = 'index_node_id_unique'; status = if ($errors.Count -eq 0) { 'pass' } else { 'fail' }; count = $nodes.Count })

  $defaultStatus = Resolve-StatusCodes -Values @('active', '302') -AllowCandidate:$false
  $defaultNodes = Select-MemoryNodes -Nodes $nodes -Needle '' -ScopeFilters @() -StatusCodes $defaultStatus -TypeCodes @() -MaxNodes 6 -ExpandHops 1
  $candidateDefaultCount = @($defaultNodes | Where-Object { $_.node.status_code -eq 300 }).Count
  if ($candidateDefaultCount -gt 0) {
    $errors.Add("默认取回混入candidate: $candidateDefaultCount")
  }
  $checks.Add([pscustomobject]@{ name = 'candidate_not_in_default_get'; status = if ($candidateDefaultCount -eq 0) { 'pass' } else { 'fail' }; count = $candidateDefaultCount })

  $machine = Read-MachineJsonl -MemoryRoot $Root
  foreach ($err in $machine.errors) { $errors.Add($err) }
  $checks.Add([pscustomobject]@{
    name = 'machine_jsonl_parse'
    status = if ($machine.errors.Count -eq 0) { 'pass' } else { 'fail' }
    files = $machine.files.Count
    records = $machine.records.Count
    machine_dir_exists = $machine.dir_exists
  })

  if (-not $machine.dir_exists) {
    $warnings.Add("machine目录不存在；JSONL校验记为not_applicable")
  } elseif ($machine.files.Count -eq 0) {
    $warnings.Add("machine目录存在但没有*.jsonl；JSONL校验记为not_applicable")
  }

  $graph = Get-MachineGraph -IndexNodes $nodes -Machine $machine
  $ids = @{}
  $duplicateIds = New-Object System.Collections.Generic.List[string]
  $primaryIdFieldsByFile = @{
    'nodes.jsonl' = 'node_id'
    'events.jsonl' = 'event_id'
    'edges.jsonl' = 'edge_id'
    'sources.jsonl' = 'source_id'
    'terms.jsonl' = 'term_id'
    'audit.jsonl' = 'audit_id'
  }

  foreach ($record in $machine.records) {
    $obj = $record.object
    $fileName = [System.IO.Path]::GetFileName($record.file)
    $field = if ($primaryIdFieldsByFile.ContainsKey($fileName)) { $primaryIdFieldsByFile[$fileName] } else { 'id' }
    $value = Get-ObjectPropertyValue -Object $obj -Names @($field)
    if ($null -eq $value -or "$value".Trim().Length -eq 0) {
      $errors.Add("主键缺失: file=$fileName field=$field at $($record.file):$($record.line)")
      continue
    }
    $idText = "$field|$value"
    $location = "$($record.file):$($record.line)"
    if ($ids.ContainsKey($idText)) {
      $duplicateIds.Add("$field=$value at $location duplicates $($ids[$idText])")
    } else {
      $ids[$idText] = $location
    }
  }
  foreach ($dup in $duplicateIds) { $errors.Add("ID重复: $dup") }
  $checks.Add([pscustomobject]@{ name = 'machine_id_unique'; status = if ($duplicateIds.Count -eq 0) { 'pass' } else { 'fail' }; duplicate_count = $duplicateIds.Count })

  $badEdges = 0
  foreach ($edge in $graph.edges) {
    if ($edge.from.Trim().Length -eq 0 -or $edge.to.Trim().Length -eq 0) {
      $errors.Add("edge端点缺失: $($edge.edge_id)")
      $badEdges++
      continue
    }
    if (-not $graph.known_ids.ContainsKey($edge.from)) {
      $errors.Add("edge起点不存在: $($edge.edge_id) from=$($edge.from)")
      $badEdges++
    }
    if (-not $graph.known_ids.ContainsKey($edge.to)) {
      $errors.Add("edge终点不存在: $($edge.edge_id) to=$($edge.to)")
      $badEdges++
    }
  }
  $checks.Add([pscustomobject]@{ name = 'edge_endpoints_exist'; status = if ($badEdges -eq 0) { 'pass' } else { 'fail' }; edge_count = $graph.edges.Count; bad_count = $badEdges })

  $activePromotionMissing = 0
  foreach ($record in $machine.records) {
    $obj = $record.object
    $statusCode = Get-ObjectPropertyValue -Object $obj -Names @('status_code')
    $statusLabel = Get-ObjectPropertyValue -Object $obj -Names @('status_label', 'status')
    $isActive = ($null -ne $statusCode -and "$statusCode" -eq '302') -or ($null -ne $statusLabel -and "$statusLabel".ToLowerInvariant() -eq 'active')
    $nodeId = Get-ObjectPropertyValue -Object $obj -Names @('node_id')
    if (-not $isActive -or $null -eq $nodeId) { continue }
    foreach ($required in @('promoted_by', 'promoted_at', 'promotion_reason')) {
      $value = Get-ObjectPropertyValue -Object $obj -Names @($required)
      if ($null -eq $value -or "$value".Trim().Length -eq 0) {
        $errors.Add("active提升字段缺失: node=$nodeId field=$required at $($record.file):$($record.line)")
        $activePromotionMissing++
      }
    }
  }
  $checks.Add([pscustomobject]@{ name = 'active_promotion_fields'; status = if ($activePromotionMissing -eq 0) { 'pass' } else { 'fail' }; missing_count = $activePromotionMissing })

  $badSourceIds = 0
  $sourceIdFields = 0
  $badBits = 0
  $bitsFields = 0
  $badTerms = 0
  $termCount = 0
  foreach ($record in $machine.records) {
    $obj = $record.object
    $fileName = [System.IO.Path]::GetFileName($record.file)
    $sourceIds = Get-ObjectPropertyValue -Object $obj -Names @('source_ids')
    if ($null -ne $sourceIds) {
      $sourceIdFields++
      $resolved = Resolve-SourceIdList -Value $sourceIds
      if (-not $resolved.ok) {
        $errors.Add("source_ids不可解析: $($record.file):$($record.line) $($resolved.error)")
        $badSourceIds++
      }
    }

    $bits = Get-ObjectPropertyValue -Object $obj -Names @('bits')
    if ($null -ne $bits) {
      $bitsFields++
      if (-not ($bits -is [array])) {
        $errors.Add("bits必须是数组: $($record.file):$($record.line)")
        $badBits++
        continue
      }
      $bitIndex = 0
      foreach ($bit in $bits) {
        $bitIndex++
        if ($bit -is [string]) {
          if ($bit.Trim().Length -eq 0) {
            $errors.Add("bits[$bitIndex]为空字符串: $($record.file):$($record.line)")
            $badBits++
          }
          continue
        }
        $text = Get-ObjectPropertyValue -Object $bit -Names @('content_zh', 'content', 'text', 'summary_zh', 'summary', 'value')
        if ($null -eq $text -or "$text".Trim().Length -eq 0) {
          $errors.Add("bits[$bitIndex]缺少content_zh/content/text/summary_zh/summary/value: $($record.file):$($record.line)")
          $badBits++
        }
        $bitSources = Get-ObjectPropertyValue -Object $bit -Names @('source_ids')
        if ($null -ne $bitSources) {
          $resolved = Resolve-SourceIdList -Value $bitSources
          if (-not $resolved.ok) {
            $errors.Add("bits[$bitIndex].source_ids不可解析: $($record.file):$($record.line) $($resolved.error)")
            $badBits++
          }
        }
      }
    }

    if ($fileName -eq 'terms.jsonl') {
      $termCount++
      $termId = Get-ObjectPropertyValue -Object $obj -Names @('term_id')
      $aliases = @(Resolve-TextArray -Value (Get-ObjectPropertyValue -Object $obj -Names @('aliases')))
      if ($null -eq $termId -or "$termId".Trim().Length -eq 0) {
        $errors.Add("terms缺少term_id: $($record.file):$($record.line)")
        $badTerms++
      }
      if ($aliases.Count -eq 0) {
        $errors.Add("terms缺少aliases: $($record.file):$($record.line)")
        $badTerms++
      }
      $targetProperty = $obj.PSObject.Properties | Where-Object { $_.Name -ieq 'target_ids' } | Select-Object -First 1
      if ($null -eq $targetProperty) {
        $errors.Add("terms缺少target_ids字段: $($record.file):$($record.line)")
        $badTerms++
      } else {
        $targetValue = $targetProperty.Value
        foreach ($target in @(Resolve-TextArray -Value $targetValue)) {
          if ($target.Trim().Length -eq 0) { continue }
          if (-not $graph.known_ids.ContainsKey($target)) {
            $errors.Add("terms target_id不存在: term=$termId target=$target at $($record.file):$($record.line)")
            $badTerms++
          }
        }
      }
    }
  }
  $checks.Add([pscustomobject]@{ name = 'source_ids_parseable'; status = if ($badSourceIds -eq 0) { 'pass' } else { 'fail' }; fields = $sourceIdFields; bad_count = $badSourceIds })
  $checks.Add([pscustomobject]@{ name = 'bits_structure'; status = if ($badBits -eq 0) { 'pass' } else { 'fail' }; fields = $bitsFields; bad_count = $badBits })
  $checks.Add([pscustomobject]@{ name = 'terms_structure'; status = if ($badTerms -eq 0) { 'pass' } else { 'fail' }; terms = $termCount; bad_count = $badTerms })

  $overall = if ($errors.Count -eq 0) { 'PASS' } else { 'FAIL' }
  $payload = [pscustomobject]@{
    command = 'validate'
    result = $overall
    root = $Root
    index_node_count = $nodes.Count
    machine_dir = $machine.machine_dir
    machine_dir_exists = $machine.dir_exists
    machine_jsonl_count = $machine.files.Count
    machine_record_count = $machine.records.Count
    checks = @($checks.ToArray())
    warnings = @($warnings.ToArray())
    errors = @($errors.ToArray())
  }

  if ($Format -eq 'json') {
    Write-JsonResult $payload
  } else {
    "QA memory validate: $overall"
    "root=$Root"
    "index_node_count=$($nodes.Count)"
    "machine_dir_exists=$($machine.dir_exists)；machine_jsonl_count=$($machine.files.Count)；machine_record_count=$($machine.records.Count)"
    foreach ($check in $checks) {
      "check=$($check.name) status=$($check.status)"
    }
    foreach ($warning in $warnings) {
      "warning=$warning"
    }
    foreach ($err in $errors) {
      "error=$err"
    }
  }

  if ($errors.Count -gt 0) { exit 1 }
}

function Invoke-BlockedWriteCommand {
  param([string]$Name)

  $missing = New-Object System.Collections.Generic.List[string]
  if ($Name -eq 'promote') {
    if ($NodeId.Trim().Length -eq 0) { $missing.Add('NodeId') }
    if ($Actor.Trim().Length -eq 0) { $missing.Add('Actor') }
    if ($Reason.Trim().Length -eq 0) { $missing.Add('Reason') }
    if ($Source.Count -eq 0) { $missing.Add('Source') }
  }

  $payload = [pscustomobject]@{
    command = $Name
    result = if ($missing.Count -gt 0) { 'BLOCKED_MISSING_GATE_FIELDS' } else { 'BLOCKED_BY_MAIN_THREAD_GATE' }
    dry_run = $true
    node_id = $NodeId
    actor = if ($Actor.Trim().Length -gt 0) { $Actor } else { $null }
    reason = if ($Reason.Trim().Length -gt 0) { $Reason } else { $null }
    source = $Source
    missing = @($missing.ToArray())
    message = '第一版统一CLI不执行QA memory写入；put/link/promote/rebuild-index只能输出dry-run或阻断信息。active提升必须由主线程复核和执行。'
  }

  if ($Format -eq 'json') {
    Write-JsonResult $payload
    return
  }

  "QA memory $Name"
  "result=$($payload.result)"
  if ($missing.Count -gt 0) { "missing=$($missing -join ',')" }
  "dry_run=true"
  "message=$($payload.message)"
}

function Show-Help {
  @"
qa-mem.ps1 - QA memory v2 unified CLI

Usage:
  powershell -ExecutionPolicy Bypass -File qa-mem.ps1 get [options]
  powershell -ExecutionPolicy Bypass -File qa-mem.ps1 graph -NodeId N-... [options]
  powershell -ExecutionPolicy Bypass -File qa-mem.ps1 validate [-Format llm|json]

Read-only commands:
  get       默认 Mode quick, Status active/302, Limit 6, Expand 1, Format llm
  graph     按 NodeId 展开 1-2跳，支持 -Hops, -Limit, -Format llm|json
  validate  检查索引、machine JSONL、ID唯一、edge端点、source_ids、bits和默认取回候选隔离

Write-gated commands:
  put/link/promote/rebuild-index 第一版只输出dry-run/blocked，不写入。
  promote active 需要 -NodeId -Actor -Reason -Source，但仍不会由子智能体直接执行。
"@
}

try {
  switch ($Command) {
    'get' { Invoke-Get }
    'graph' { Invoke-Graph }
    'validate' { Invoke-Validate }
    'put' { Invoke-BlockedWriteCommand -Name 'put' }
    'link' { Invoke-BlockedWriteCommand -Name 'link' }
    'promote' { Invoke-BlockedWriteCommand -Name 'promote' }
    'rebuild-index' { Invoke-BlockedWriteCommand -Name 'rebuild-index' }
    'help' { Show-Help }
  }
} catch {
  if ($Format -eq 'json') {
    $payload = [pscustomobject]@{
      command = $Command
      result = 'ERROR'
      message = $_.Exception.Message
    }
    if ($env:QA_MEM_DEBUG -eq '1') {
      $payload | Add-Member -NotePropertyName position -NotePropertyValue $_.InvocationInfo.PositionMessage
      $payload | Add-Member -NotePropertyName stack -NotePropertyValue $_.ScriptStackTrace
    }
    Write-JsonResult $payload
  } else {
    "QA memory ${Command}: ERROR"
    "message=$($_.Exception.Message)"
    if ($env:QA_MEM_DEBUG -eq '1') {
      "position=$($_.InvocationInfo.PositionMessage)"
      "stack=$($_.ScriptStackTrace)"
    }
  }
  exit 1
}
