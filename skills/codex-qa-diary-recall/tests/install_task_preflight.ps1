param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$installer = Join-Path $repoRoot 'scripts\install_codex_qa_diary_watcher_task.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-qa-install-$([guid]::NewGuid().ToString('N'))"
$healthDir = Join-Path $tempRoot 'health'
$healthLauncher = Join-Path $healthDir 'run_qa_diary_health_hidden.vbs'
$healthScript = Join-Path $healthDir 'qa_diary_health.ps1'
$global:CodexQaInstallTestMutations = New-Object System.Collections.Generic.List[string]
$global:CodexQaInstallTestActions = New-Object System.Collections.Generic.List[object]

function New-ScheduledTaskAction {
  [CmdletBinding()]
  param([string]$Execute, [string]$Argument)
  $value = [pscustomobject]@{ Execute = $Execute; Arguments = $Argument }
  $global:CodexQaInstallTestActions.Add($value)
  return $value
}

function New-ScheduledTaskTrigger {
  [CmdletBinding()]
  param(
    [switch]$AtLogOn,
    [switch]$Once,
    [datetime]$At,
    [timespan]$RepetitionInterval,
    [timespan]$RepetitionDuration
  )
  return [pscustomobject]@{ AtLogOn = $AtLogOn; Once = $Once; At = $At }
}

function New-ScheduledTaskSettingsSet {
  [CmdletBinding()]
  param(
    [switch]$AllowStartIfOnBatteries,
    [switch]$DontStopIfGoingOnBatteries,
    [switch]$StartWhenAvailable,
    [int]$RestartCount,
    [timespan]$RestartInterval,
    [string]$MultipleInstances
  )
  return [pscustomobject]@{ Hidden = $false }
}

function Stop-ScheduledTask {
  [CmdletBinding()]
  param([string]$TaskName, [string]$TaskPath)
  $global:CodexQaInstallTestMutations.Add("stop:$TaskName")
}

function Register-ScheduledTask {
  [CmdletBinding()]
  param(
    [string]$TaskName,
    [string]$TaskPath,
    [object]$Action,
    [object[]]$Trigger,
    [object]$Settings,
    [string]$Description,
    [switch]$Force
  )
  $global:CodexQaInstallTestMutations.Add("register:$TaskName")
}

function Start-ScheduledTask {
  [CmdletBinding()]
  param([string]$TaskName, [string]$TaskPath)
  $global:CodexQaInstallTestMutations.Add("start:$TaskName")
}

function Get-ScheduledTask {
  [CmdletBinding()]
  param([string[]]$TaskName, [string]$TaskPath)
  return @($TaskName | ForEach-Object { [pscustomobject]@{ TaskName = $_; TaskPath = $TaskPath; State = 'Ready' } })
}

try {
  New-Item -ItemType Directory -Force -Path $healthDir | Out-Null

  $missingLauncher = Join-Path $healthDir 'missing.vbs'
  $failedAsExpected = $false
  try {
    & $installer -TaskName 'Fixture Watcher' -HealthTaskName 'Fixture Health' -HealthLauncher $missingLauncher
  } catch {
    $failedAsExpected = $_.Exception.Message -match 'Hidden health launcher not found'
  }
  if (-not $failedAsExpected) { throw 'missing health launcher did not fail during preflight' }
  if ($global:CodexQaInstallTestMutations.Count -ne 0) { throw 'preflight failure performed a scheduled-task mutation' }

  Set-Content -LiteralPath $healthLauncher -Encoding UTF8 -Value "' fixture launcher"
  $failedAsExpected = $false
  try {
    & $installer -TaskName 'Fixture Watcher' -HealthTaskName 'Fixture Health' -HealthLauncher $healthLauncher
  } catch {
    $failedAsExpected = $_.Exception.Message -match 'Health script not found next to launcher'
  }
  if (-not $failedAsExpected) { throw 'missing adjacent health script did not fail during preflight' }
  if ($global:CodexQaInstallTestMutations.Count -ne 0) { throw 'health-script preflight failure performed a scheduled-task mutation' }

  Set-Content -LiteralPath $healthScript -Encoding UTF8 -Value "# fixture health script"
  $global:CodexQaInstallTestActions.Clear()
  & $installer -TaskName 'Fixture Watcher' -HealthTaskName 'Fixture Health' -HealthLauncher $healthLauncher | Out-Null

  $expectedMutations = @(
    'stop:Fixture Watcher',
    'register:Fixture Watcher',
    'start:Fixture Watcher',
    'stop:Fixture Health',
    'register:Fixture Health',
    'start:Fixture Health'
  )
  if ((@($global:CodexQaInstallTestMutations) -join '|') -ne ($expectedMutations -join '|')) {
    throw "unexpected mutation sequence: $(@($global:CodexQaInstallTestMutations) -join '|')"
  }
  if ($global:CodexQaInstallTestActions.Count -ne 2) { throw 'installer did not build both scheduled-task actions' }
  if ($global:CodexQaInstallTestActions[1].Arguments -notmatch [regex]::Escape($healthLauncher)) {
    throw 'health action does not point to the requested launcher'
  }

  [pscustomobject]@{
    status = 'PASS'
    preflight_mutations = 0
    successful_mutation_sequence = @($global:CodexQaInstallTestMutations)
    health_launcher = $healthLauncher
  } | ConvertTo-Json -Depth 5
} finally {
  $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
  if ($resolvedTemp.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTemp)) {
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
  Remove-Variable -Name CodexQaInstallTestMutations -Scope Global -ErrorAction SilentlyContinue
  Remove-Variable -Name CodexQaInstallTestActions -Scope Global -ErrorAction SilentlyContinue
}
