[CmdletBinding()]
param(
  [string]$CodexHome = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'),
  [switch]$Force,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceSkill = Join-Path $repoRoot 'skills\codex-qa-diary-recall'
$targetSkillsRoot = Join-Path $CodexHome 'skills'
$targetSkill = Join-Path $targetSkillsRoot 'codex-qa-diary-recall'
$retiredSkill = Join-Path $targetSkillsRoot 'codex-qa-memory'
$frozenMemoryRoot = Join-Path $CodexHome 'qa-memory'

if (-not (Test-Path -LiteralPath (Join-Path $sourceSkill 'SKILL.md') -PathType Leaf)) {
  throw "Skill source is incomplete: $sourceSkill"
}

function Get-FileDigest {
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

function Get-TreeCopyPlan {
  param([string]$SourceRoot, [string]$DestinationRoot)

  $resolvedSource = (Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\')
  $items = New-Object System.Collections.Generic.List[object]
  foreach ($sourceFile in Get-ChildItem -LiteralPath $resolvedSource -Recurse -File | Sort-Object FullName) {
    $relative = $sourceFile.FullName.Substring($resolvedSource.Length).TrimStart('\')
    $destination = Join-Path $DestinationRoot $relative
    $state = 'missing'
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
      $state = if ((Get-FileDigest $sourceFile.FullName) -eq (Get-FileDigest $destination)) { 'same' } else { 'conflict' }
    }
    $items.Add([pscustomobject]@{
      source = $sourceFile.FullName
      destination = $destination
      relative = $relative
      state = $state
    })
  }
  return $items
}

$copyPlan = @(Get-TreeCopyPlan -SourceRoot $sourceSkill -DestinationRoot $targetSkill)
$conflicts = @($copyPlan | Where-Object { $_.state -eq 'conflict' })
$legacyTaskPresent = $false
if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
  $legacyTaskPresent = $null -ne (Get-ScheduledTask -TaskPath '\Codex\' -TaskName 'Codex QA Memory Hourly Maintenance' -ErrorAction SilentlyContinue)
}

$result = [ordered]@{
  ok = ($conflicts.Count -eq 0 -or $Force)
  dry_run = [bool]$DryRun
  codex_home = $CodexHome
  skill = 'codex-qa-diary-recall'
  skill_files_missing = @($copyPlan | Where-Object { $_.state -eq 'missing' }).Count
  skill_files_same = @($copyPlan | Where-Object { $_.state -eq 'same' }).Count
  skill_files_conflicting = $conflicts.Count
  conflicting_files = @($conflicts | ForEach-Object { $_.destination })
  retired_memory_skill_present = (Test-Path -LiteralPath $retiredSkill -PathType Container)
  frozen_memory_archive_present = (Test-Path -LiteralPath $frozenMemoryRoot -PathType Container)
  legacy_memory_task_present = $legacyTaskPresent
  legacy_memory_modified = $false
  write_performed = $false
}

if ($DryRun) {
  $result | ConvertTo-Json -Depth 4
  return
}

if ($conflicts.Count -gt 0 -and -not $Force) {
  throw "Installed diary Skill files differ from this package. Re-run with -Force only if you intend to replace them: $(@($conflicts | ForEach-Object { $_.destination }) -join '; ')"
}

New-Item -ItemType Directory -Force -Path $targetSkillsRoot | Out-Null
$filesWritten = 0
foreach ($item in $copyPlan) {
  if ($item.state -eq 'same') { continue }
  $parent = Split-Path -Parent $item.destination
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  Copy-Item -LiteralPath $item.source -Destination $item.destination -Force
  $filesWritten++
}

$result.ok = $true
$result.installed = $true
$result.skill_files_written = $filesWritten
$result.write_performed = ($filesWritten -gt 0)
$result.next_step = 'Restart Codex. Run the QA logger and watcher installers separately when you are ready to create local QA diaries.'
if ($result.retired_memory_skill_present -or $result.frozen_memory_archive_present -or $legacyTaskPresent) {
  $result.legacy_note = 'Existing QA memory files and scheduled tasks were detected but were not modified. If the legacy maintenance task is enabled, it can continue writing candidates; disable it explicitly after you decide to retire it.'
}
$result | ConvertTo-Json -Depth 4
