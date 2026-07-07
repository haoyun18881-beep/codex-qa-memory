param(
  [string]$Root = "$env:USERPROFILE\.codex\qa-memory"
)

$ErrorActionPreference = 'Stop'
$requiredFiles = @('00-总入口.md','01-码表.md','02-模板.md','03-索引.md')
$requiredDirs = @('records','candidates')
$sensitivePattern = '(?i)(api[_-]?key\s*=|authorization:\s*bearer\s+\S{8,}|private key-----|password\s*=|token\s*=\s*\S{8,}|cookie:\s*\S{8,})'
$errors = New-Object System.Collections.Generic.List[string]

if (-not (Test-Path -LiteralPath $Root)) {
  throw "Root not found: $Root"
}

foreach ($file in $requiredFiles) {
  if (-not (Test-Path -LiteralPath (Join-Path $Root $file))) {
    $errors.Add("missing file: $file")
  }
}

foreach ($dir in $requiredDirs) {
  if (-not (Test-Path -LiteralPath (Join-Path $Root $dir))) {
    $errors.Add("missing dir: $dir")
  }
}

$allFiles = Get-ChildItem -LiteralPath $Root -Recurse -File -Include '*.md','*.yaml','*.yml'
foreach ($file in $allFiles) {
  $raw = Get-Content -Raw -LiteralPath $file.FullName
  if ($raw -match $sensitivePattern) {
    $errors.Add("possible sensitive text in $($file.FullName)")
  }
}

$indexPath = Join-Path $Root '03-索引.md'
if (Test-Path -LiteralPath $indexPath) {
  $indexRaw = Get-Content -Raw -LiteralPath $indexPath
  foreach ($required in @('node_id','type_code','status_code','scope_code','source_ref','record_path')) {
    if ($indexRaw -notmatch [regex]::Escape($required)) {
      $errors.Add("index missing column or keyword: $required")
    }
  }
  $nodeRows = Select-String -LiteralPath $indexPath -Pattern '^\|\s*N-\d{8}-\d+'
  if ($nodeRows.Count -eq 0) {
    $errors.Add("index has no node rows")
  }
  foreach ($row in $nodeRows) {
    $cells = $row.Line.Trim() -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    if ($cells.Count -lt 7) {
      $errors.Add("bad index row: $($row.Line)")
      continue
    }
    $content = $cells[4]
    if ($content.Length -gt 140) {
      $errors.Add("node content too long: $($cells[0])")
    }
    $record = Join-Path $Root $cells[6]
    if (-not (Test-Path -LiteralPath $record)) {
      $errors.Add("record_path not found for $($cells[0]): $($cells[6])")
    }
  }
}

$records = Get-ChildItem -LiteralPath (Join-Path $Root 'records') -File -Filter '*.md' -ErrorAction SilentlyContinue
foreach ($record in $records) {
  $raw = Get-Content -Raw -LiteralPath $record.FullName
  foreach ($required in @('event_id:','node_id:','type_code:','status_code:','scope_code:','source_ref:')) {
    if ($raw -notmatch [regex]::Escape($required)) {
      $errors.Add("record missing $required in $($record.FullName)")
    }
  }
}

$nodeFiles = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.md' | Where-Object {
  $_.FullName -match '\\(records|candidates)\\' -and
  $_.FullName -notmatch '\\candidates\\staging\\'
}
foreach ($nodeFile in $nodeFiles) {
  $raw = Get-Content -Raw -LiteralPath $nodeFile.FullName
  $segments = $raw -split '```yaml'
  foreach ($segment in $segments) {
    if ($segment -notmatch '(?m)^\s*node_id:\s*N-') { continue }
    $block = ($segment -split '```')[0]
    foreach ($required in @('node_id:','type_code:','status_code:','status_label:','scope_code:','scope_type:','scope_id:','source_ref:','created_at:','last_hit_at:','risk_type:')) {
      if ($block -notmatch "(?m)^\s*$required") {
        $nodeLabel = if ($block -match '(?m)^\s*node_id:\s*(\S+)') { $Matches[1] } else { 'unknown-node' }
        $errors.Add("node $nodeLabel missing tri-state field $required in $($nodeFile.FullName)")
      }
    }
    if ($block -match '(?m)^\s*status_code:\s*(\d+)') {
      $statusCode = [int]$Matches[1]
      if ($statusCode -eq 302) {
        foreach ($required in @('promoted_by:','promoted_at:','promotion_reason:')) {
          if ($block -notmatch "(?m)^\s*$required") {
            $nodeLabel = if ($block -match '(?m)^\s*node_id:\s*(\S+)') { $Matches[1] } else { 'unknown-node' }
            $errors.Add("active node $nodeLabel missing promotion audit field $required in $($nodeFile.FullName)")
          }
        }
      }
    } else {
      $nodeLabel = if ($block -match '(?m)^\s*node_id:\s*(\S+)') { $Matches[1] } else { 'unknown-node' }
      $errors.Add("node $nodeLabel missing parseable status_code in $($nodeFile.FullName)")
    }
  }
}

if ($errors.Count -gt 0) {
  "QA memory validation: FAIL"
  $errors
  exit 1
}

"QA memory validation: PASS"
"root=$Root"
