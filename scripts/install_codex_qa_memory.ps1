[CmdletBinding()]
param(
  [string]$CodexHome = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'),
  [switch]$Force,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceSkillsRoot = Join-Path $repoRoot 'skills'
$targetSkillsRoot = Join-Path $CodexHome 'skills'
$memoryRoot = Join-Path $CodexHome 'qa-memory'
$templateRoot = Join-Path $repoRoot 'qa-memory-template'
$skillNames = @('codex-qa-memory', 'codex-qa-diary-recall')
$templateFiles = @('00-总入口.md', '01-码表.md', '02-模板.md', '03-索引.md', '03-索引.sample.md')
$memoryDirs = @('records', 'candidates', 'maintenance', 'machine')

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
  param(
    [string]$SourceRoot,
    [string]$DestinationRoot
  )

  $resolvedSource = (Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\')
  $items = New-Object System.Collections.Generic.List[object]
  foreach ($sourceFile in Get-ChildItem -LiteralPath $resolvedSource -Recurse -File | Sort-Object FullName) {
    $relative = $sourceFile.FullName.Substring($resolvedSource.Length).TrimStart('\')
    $destination = Join-Path $DestinationRoot $relative
    $state = 'missing'
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
      if ((Get-FileDigest $sourceFile.FullName) -eq (Get-FileDigest $destination)) {
        $state = 'same'
      } else {
        $state = 'conflict'
      }
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

function Invoke-MemoryValidation {
  param(
    [string]$Validator,
    [string]$ExistingMemoryRoot,
    [string]$TemplateMemoryRoot
  )

  $validationRoot = $ExistingMemoryRoot
  $stageRoot = $null
  if (-not (Test-Path -LiteralPath $ExistingMemoryRoot -PathType Container)) {
    $validationRoot = $TemplateMemoryRoot
  } elseif (-not (Test-Path -LiteralPath (Join-Path $ExistingMemoryRoot '03-索引.md') -PathType Leaf)) {
    $stageRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-qa-memory-preflight-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $TemplateMemoryRoot '03-索引.md') -Destination (Join-Path $stageRoot '03-索引.md')
    $existingMachine = Join-Path $ExistingMemoryRoot 'machine'
    if (Test-Path -LiteralPath $existingMachine -PathType Container) {
      Copy-Item -LiteralPath $existingMachine -Destination (Join-Path $stageRoot 'machine') -Recurse
    } else {
      New-Item -ItemType Directory -Force -Path (Join-Path $stageRoot 'machine') | Out-Null
    }
    $validationRoot = $stageRoot
  }

  try {
    $powerShell = (Get-Command powershell -ErrorAction Stop).Source
    $output = @(& $powerShell -NoProfile -ExecutionPolicy Bypass -File $Validator validate -Root $validationRoot 2>&1)
    return [pscustomobject]@{
      ok = ($LASTEXITCODE -eq 0)
      output = $output
    }
  } finally {
    if ($null -ne $stageRoot) {
      $resolvedStage = [IO.Path]::GetFullPath($stageRoot)
      $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
      if ($resolvedStage.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedStage)) {
        Remove-Item -LiteralPath $resolvedStage -Recurse -Force
      }
    }
  }
}

foreach ($skillName in $skillNames) {
  $source = Join-Path $sourceSkillsRoot $skillName
  if (-not (Test-Path -LiteralPath (Join-Path $source 'SKILL.md') -PathType Leaf)) {
    throw "Skill source is incomplete: $source"
  }
}
foreach ($fileName in $templateFiles) {
  if (-not (Test-Path -LiteralPath (Join-Path $templateRoot $fileName) -PathType Leaf)) {
    throw "QA memory template file is missing: $fileName"
  }
}

$copyPlan = New-Object System.Collections.Generic.List[object]
foreach ($skillName in $skillNames) {
  $source = Join-Path $sourceSkillsRoot $skillName
  $destination = Join-Path $targetSkillsRoot $skillName
  foreach ($item in Get-TreeCopyPlan -SourceRoot $source -DestinationRoot $destination) {
    $copyPlan.Add($item)
  }
}

$conflicts = @($copyPlan | Where-Object { $_.state -eq 'conflict' })

$memoryFilesToCreate = New-Object System.Collections.Generic.List[object]
$memoryFilesPreserved = New-Object System.Collections.Generic.List[string]
foreach ($fileName in $templateFiles) {
  $source = Join-Path $templateRoot $fileName
  $destination = Join-Path $memoryRoot $fileName
  if (Test-Path -LiteralPath $destination) {
    $memoryFilesPreserved.Add($destination)
  } else {
    $memoryFilesToCreate.Add([pscustomobject]@{ source = $source; destination = $destination })
  }
}

$validator = Join-Path $sourceSkillsRoot 'codex-qa-memory\scripts\qa-mem.ps1'
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
  throw "Packaged validator not found: $validator"
}
$preflightValidation = Invoke-MemoryValidation -Validator $validator -ExistingMemoryRoot $memoryRoot -TemplateMemoryRoot $templateRoot

if ($DryRun) {
  [pscustomobject]@{
    ok = (($conflicts.Count -eq 0 -or $Force) -and $preflightValidation.ok)
    dry_run = $true
    codex_home = $CodexHome
    skill_files_missing = @($copyPlan | Where-Object { $_.state -eq 'missing' }).Count
    skill_files_same = @($copyPlan | Where-Object { $_.state -eq 'same' }).Count
    skill_files_conflicting = $conflicts.Count
    conflicting_files = @($conflicts | ForEach-Object { $_.destination })
    memory_files_to_create = $memoryFilesToCreate.Count
    memory_files_preserved = $memoryFilesPreserved.Count
    memory_validation = if ($preflightValidation.ok) { 'PASS' } else { 'FAIL' }
    write_performed = $false
  } | ConvertTo-Json -Depth 4
  return
}

if ($conflicts.Count -gt 0 -and -not $Force) {
  $relativeConflicts = @($conflicts | ForEach-Object { $_.destination })
  throw "Installed Skill files differ from this package. Re-run with -Force only if you intend to replace them: $($relativeConflicts -join '; ')"
}
if (-not $preflightValidation.ok) {
  throw "QA memory validation failed before installation: $($preflightValidation.output -join ' ')"
}

New-Item -ItemType Directory -Force -Path $targetSkillsRoot | Out-Null
New-Item -ItemType Directory -Force -Path $memoryRoot | Out-Null
foreach ($dirName in $memoryDirs) {
  New-Item -ItemType Directory -Force -Path (Join-Path $memoryRoot $dirName) | Out-Null
}

foreach ($item in $memoryFilesToCreate) {
  Copy-Item -LiteralPath $item.source -Destination $item.destination
}

$powerShell = (Get-Command powershell -ErrorAction Stop).Source
$validationOutput = @(& $powerShell -NoProfile -ExecutionPolicy Bypass -File $validator validate -Root $memoryRoot 2>&1)
if ($LASTEXITCODE -ne 0) {
  throw "QA memory validation failed: $($validationOutput -join ' ')"
}

$skillFilesWritten = 0
foreach ($item in $copyPlan) {
  if ($item.state -eq 'same') {
    continue
  }
  $parent = Split-Path -Parent $item.destination
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  Copy-Item -LiteralPath $item.source -Destination $item.destination -Force
  $skillFilesWritten += 1
}

[pscustomobject]@{
  ok = $true
  installed = $true
  codex_home = $CodexHome
  skills = $skillNames
  skill_files_written = $skillFilesWritten
  memory_root = $memoryRoot
  memory_files_created = $memoryFilesToCreate.Count
  memory_files_preserved = $memoryFilesPreserved.Count
  validation = 'PASS'
  next_step = 'Restart Codex. Run the QA logger separately when you are ready to create local diaries.'
} | ConvertTo-Json -Depth 4
