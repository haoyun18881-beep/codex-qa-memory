[CmdletBinding()]
param(
  [string]$DiaryRoot = "$env:USERPROFILE\.codex\qa-diary",
  [string]$TaskName = "Codex QA Diary Watcher",
  [string]$TaskPath = "\Codex\",
  [int]$MaxHeartbeatAgeMinutes = 30,
  [int]$FailuresBeforeCritical = 2,
  [switch]$SkipTaskCheck
)

$ErrorActionPreference = 'Stop'
$target = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\codex-qa-diary-recall\scripts\qa_diary_health.ps1'))
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
  throw "Codex QA Diary health script is missing: $target"
}

$arguments = @{
  DiaryRoot = $DiaryRoot
  TaskName = $TaskName
  TaskPath = $TaskPath
  MaxHeartbeatAgeMinutes = $MaxHeartbeatAgeMinutes
  FailuresBeforeCritical = $FailuresBeforeCritical
}
if ($SkipTaskCheck) { $arguments.SkipTaskCheck = $true }

& $target @arguments
exit $LASTEXITCODE
