param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$installer = Join-Path $repoRoot 'scripts\install_codex_qa_memory.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-qa-diary-install-$([guid]::NewGuid().ToString('N'))"
$codexHome = Join-Path $tempRoot '中文 空格\.codex'

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
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
  Assert-True (-not (Test-Path -LiteralPath $codexHome)) 'dry-run wrote to the target directory'

  $memoryRoot = Join-Path $codexHome 'qa-memory'
  $memorySkill = Join-Path $codexHome 'skills\codex-qa-memory'
  New-Item -ItemType Directory -Force -Path $memoryRoot,$memorySkill | Out-Null
  $archiveSentinel = Join-Path $memoryRoot 'frozen-sentinel.txt'
  $skillSentinel = Join-Path $memorySkill 'local-sentinel.txt'
  Set-Content -LiteralPath $archiveSentinel -Encoding UTF8 -Value 'frozen archive must not change'
  Set-Content -LiteralPath $skillSentinel -Encoding UTF8 -Value 'retired local skill must not change'
  $archiveHash = Get-TestDigest $archiveSentinel
  $skillHash = Get-TestDigest $skillSentinel

  $first = (& $installer -CodexHome $codexHome | Out-String) | ConvertFrom-Json
  Assert-True ($first.ok -and $first.installed) 'first installation failed'
  Assert-True (Test-Path -LiteralPath (Join-Path $codexHome 'skills\codex-qa-diary-recall\SKILL.md') -PathType Leaf) 'diary Skill was not installed'
  Assert-True ((Get-TestDigest $archiveSentinel) -eq $archiveHash) 'installer changed the frozen QA memory archive'
  Assert-True ((Get-TestDigest $skillSentinel) -eq $skillHash) 'installer changed the retired QA memory Skill'

  $second = (& $installer -CodexHome $codexHome | Out-String) | ConvertFrom-Json
  Assert-True ($second.ok -and $second.skill_files_written -eq 0) 'idempotent install rewrote identical files'

  $installedSkill = Join-Path $codexHome 'skills\codex-qa-diary-recall\SKILL.md'
  Set-Content -LiteralPath $installedSkill -Encoding UTF8 -Value '# local modification'
  $blocked = $false
  try { & $installer -CodexHome $codexHome | Out-Null } catch { $blocked = $_.Exception.Message -match 'differ from this package' }
  Assert-True $blocked 'conflicting diary Skill was not stopped'

  $forced = (& $installer -CodexHome $codexHome -Force | Out-String) | ConvertFrom-Json
  Assert-True ($forced.ok -and $forced.skill_files_written -gt 0) 'forced diary Skill refresh failed'
  Assert-True ((Get-TestDigest $installedSkill) -eq (Get-TestDigest (Join-Path $repoRoot 'skills\codex-qa-diary-recall\SKILL.md'))) 'forced refresh did not restore the packaged diary Skill'
  Assert-True ((Get-TestDigest $archiveSentinel) -eq $archiveHash) 'forced refresh changed the frozen QA memory archive'
  Assert-True ((Get-TestDigest $skillSentinel) -eq $skillHash) 'forced refresh changed the retired QA memory Skill'

  [pscustomobject]@{
    status = 'PASS'
    installed_skill = 'codex-qa-diary-recall'
    frozen_memory_preserved = $true
    retired_skill_preserved = $true
    conflict_stopped = $blocked
  } | ConvertTo-Json -Depth 4
} finally {
  $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
  $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTemp)) {
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
}
