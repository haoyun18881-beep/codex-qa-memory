param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$installer = Join-Path $repoRoot 'scripts\install_codex_qa_memory.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-qa-core-install-$([guid]::NewGuid().ToString('N'))"
$codexHome = Join-Path $tempRoot '中文 空格\.codex'

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) {
    throw $Message
  }
}

function Get-TestDigest {
  param([string]$Path)
  $stream = [System.IO.File]::OpenRead($Path)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([System.BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '')
  } finally {
    $sha.Dispose()
    $stream.Dispose()
  }
}

try {
  $dryRun = (& $installer -CodexHome $codexHome -DryRun | Out-String) | ConvertFrom-Json
  Assert-True ($dryRun.ok -and $dryRun.dry_run) 'dry-run did not return an OK result'
  Assert-True ($dryRun.memory_validation -eq 'PASS') 'dry-run did not validate the predicted QA memory state'
  Assert-True (-not (Test-Path -LiteralPath $codexHome)) 'dry-run wrote to the target directory'

  $partialHome = Join-Path $tempRoot 'partial-invalid\.codex'
  $partialMachine = Join-Path $partialHome 'qa-memory\machine'
  New-Item -ItemType Directory -Force -Path $partialMachine | Out-Null
  Set-Content -LiteralPath (Join-Path $partialMachine 'memory_nodes.jsonl') -Encoding UTF8 -Value '{not valid json}'
  $partialDryRun = (& $installer -CodexHome $partialHome -DryRun | Out-String) | ConvertFrom-Json
  Assert-True (-not $partialDryRun.ok -and $partialDryRun.memory_validation -eq 'FAIL') 'dry-run did not report invalid partial QA memory'
  $partialStopped = $false
  try {
    & $installer -CodexHome $partialHome | Out-Null
  } catch {
    $partialStopped = $_.Exception.Message -match 'validation failed before installation'
  }
  Assert-True $partialStopped 'invalid partial QA memory did not stop installation'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $partialHome 'qa-memory\03-索引.md'))) 'failed preflight wrote a missing memory template'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $partialHome 'skills'))) 'failed preflight wrote Skill files'

  $first = (& $installer -CodexHome $codexHome | Out-String) | ConvertFrom-Json
  Assert-True ($first.ok -and $first.validation -eq 'PASS') 'first installation failed'

  foreach ($skillName in @('codex-qa-memory', 'codex-qa-diary-recall')) {
    $installedSkill = Join-Path $codexHome "skills\$skillName\SKILL.md"
    Assert-True (Test-Path -LiteralPath $installedSkill -PathType Leaf) "missing installed Skill: $skillName"
  }
  foreach ($dirName in @('records', 'candidates', 'maintenance', 'machine')) {
    Assert-True (Test-Path -LiteralPath (Join-Path $codexHome "qa-memory\$dirName") -PathType Container) "missing QA memory directory: $dirName"
  }
  foreach ($fileName in @('00-总入口.md', '01-码表.md', '02-模板.md', '03-索引.md')) {
    Assert-True (Test-Path -LiteralPath (Join-Path $codexHome "qa-memory\$fileName") -PathType Leaf) "missing QA memory file: $fileName"
  }

  $second = (& $installer -CodexHome $codexHome | Out-String) | ConvertFrom-Json
  Assert-True ($second.ok -and $second.skill_files_written -eq 0) 'idempotent install rewrote identical Skill files'

  $memoryEntry = Join-Path $codexHome 'qa-memory\00-总入口.md'
  $customMemory = "# 用户自己的记忆入口" + [Environment]::NewLine
  Set-Content -LiteralPath $memoryEntry -Encoding UTF8 -Value $customMemory
  $customMemoryHash = Get-TestDigest $memoryEntry

  $installedSkillPath = Join-Path $codexHome 'skills\codex-qa-memory\SKILL.md'
  Set-Content -LiteralPath $installedSkillPath -Encoding UTF8 -Value '# local modification'

  $conflictPreview = (& $installer -CodexHome $codexHome -DryRun | Out-String) | ConvertFrom-Json
  Assert-True ($conflictPreview.dry_run -and -not $conflictPreview.ok) 'conflicting dry-run did not report a blocked installation'
  Assert-True ($conflictPreview.skill_files_conflicting -gt 0) 'conflicting dry-run did not report the conflict count'
  Assert-True (-not $conflictPreview.write_performed) 'conflicting dry-run wrote to the target directory'

  $conflictStopped = $false
  try {
    & $installer -CodexHome $codexHome | Out-Null
  } catch {
    $conflictStopped = $_.Exception.Message -match 'differ from this package'
  }
  Assert-True $conflictStopped 'conflicting installed Skill was not stopped'

  $invalidMachineRecord = Join-Path $codexHome 'qa-memory\machine\memory_nodes.jsonl'
  Set-Content -LiteralPath $invalidMachineRecord -Encoding UTF8 -Value '{not valid json}'
  $invalidMemoryStopped = $false
  try {
    & $installer -CodexHome $codexHome -Force | Out-Null
  } catch {
    $invalidMemoryStopped = $_.Exception.Message -match 'QA memory validation failed'
  }
  Assert-True $invalidMemoryStopped 'invalid QA memory did not stop installation before Skill replacement'
  Assert-True ((Get-Content -LiteralPath $installedSkillPath -Raw) -match 'local modification') 'Skill was replaced before QA memory validation'
  Remove-Item -LiteralPath $invalidMachineRecord -Force

  $forced = (& $installer -CodexHome $codexHome -Force | Out-String) | ConvertFrom-Json
  Assert-True ($forced.ok -and $forced.validation -eq 'PASS') 'forced Skill refresh failed'
  Assert-True ((Get-TestDigest $installedSkillPath) -eq (Get-TestDigest (Join-Path $repoRoot 'skills\codex-qa-memory\SKILL.md'))) 'forced refresh did not restore the packaged Skill'
  Assert-True ((Get-TestDigest $memoryEntry) -eq $customMemoryHash) 'forced refresh overwrote existing QA memory'

  [pscustomobject]@{
    status = 'PASS'
    dry_run_write_performed = $dryRun.write_performed
    installed_skills = @($first.skills)
    memory_preserved_on_force = $true
    conflict_stopped = $conflictStopped
    conflict_dry_run_reported = ($conflictPreview.skill_files_conflicting -gt 0)
    invalid_memory_stopped_before_skill_write = $invalidMemoryStopped
    partial_memory_dry_run_failed = (-not $partialDryRun.ok)
    partial_memory_stopped_before_target_writes = $partialStopped
  } | ConvertTo-Json -Depth 4
} finally {
  $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
  $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTemp)) {
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
}
