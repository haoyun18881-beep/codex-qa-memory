param(
  [ValidateSet('quick','project','deep')]
  [string]$Mode = 'quick',
  [string]$Root = "$env:USERPROFILE\.codex\qa-memory",
  [int[]]$TypeCode = @(),
  [int[]]$StatusCode = @(302),
  [int[]]$ScopeCode = @(),
  [string]$Query = ''
)

$ErrorActionPreference = 'Stop'

$budgets = @{
  quick = @{ Nodes = 6; Chars = 1200 }
  project = @{ Nodes = 15; Chars = 3000 }
  deep = @{ Nodes = 40; Chars = 8000 }
}

function Convert-IndexRow {
  param([string]$Line)
  $cells = $Line.Trim() -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
  if ($cells.Count -lt 7) { return $null }
  [pscustomobject]@{
    node_id = $cells[0]
    type_code = [int]$cells[1]
    status_code = [int]$cells[2]
    scope_code = [int]$cells[3]
    content = $cells[4]
    source_ref = $cells[5]
    record_path = $cells[6]
  }
}

if (-not (Test-Path -LiteralPath $Root)) {
  throw "QA memory root not found: $Root"
}

$indexPath = Join-Path $Root '03-索引.md'
if (-not (Test-Path -LiteralPath $indexPath)) {
  throw "QA memory index not found: $indexPath"
}

$nodes = Get-Content -LiteralPath $indexPath | Where-Object { $_ -match '^\|\s*N-\d{8}-\d+' } | ForEach-Object {
  Convert-IndexRow -Line $_
} | Where-Object { $null -ne $_ }

if ($TypeCode.Count -gt 0) {
  $nodes = $nodes | Where-Object { $TypeCode -contains $_.type_code }
}
if ($StatusCode.Count -gt 0) {
  $nodes = $nodes | Where-Object { $StatusCode -contains $_.status_code }
}
if ($ScopeCode.Count -gt 0) {
  $nodes = $nodes | Where-Object { $ScopeCode -contains $_.scope_code }
}
if ($Query.Trim().Length -gt 0) {
  $q = [regex]::Escape($Query.Trim())
  $nodes = $nodes | Where-Object { ($_.content -match $q) -or ($_.source_ref -match $q) -or ($_.record_path -match $q) }
}

$budget = $budgets[$Mode]
$selected = @()
$charCount = 0
foreach ($node in $nodes) {
  $line = "- $($node.node_id) [$($node.type_code)/$($node.status_code)/$($node.scope_code)] $($node.content) source=$($node.source_ref) record=$($node.record_path)"
  if ($selected.Count -ge $budget.Nodes) { break }
  if (($charCount + $line.Length) -gt $budget.Chars) { break }
  $selected += $line
  $charCount += $line.Length
}

"QA取回包:"
"mode: $Mode"
"task: 从 QA memory 索引取回最小上下文"
"当前有效事实:"
if ($selected.Count -eq 0) {
  "- 未命中符合条件的小节点。"
} else {
  $selected
}
"适用规则/偏好: 当前用户指令和当前项目文件优先于 QA 记忆。"
"项目/工具边界: 见节点 scope_code 和 source_ref；复杂证据需读 record_path。"
"下一步: 需要原始证据时按 source_ref 查 records、项目历史或 qa-diary。"
"冲突或 review_required: 本脚本不自动裁决冲突；命中冲突状态时交主线程复核。"
"source_refs: $indexPath"
"stopped_by: mode_budget nodes=$($budget.Nodes), chars=$($budget.Chars), selected=$($selected.Count)."
