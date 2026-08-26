[CmdletBinding()]
param(
  [string]$Name = 'codex-qa-memory',
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
  throw 'MCP server name contains unsupported characters.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$serverPath = Join-Path $repoRoot 'mcp\codex_qa_memory_mcp.py'
if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) {
  throw "MCP server file not found: $serverPath"
}
$serverPath = (Resolve-Path -LiteralPath $serverPath).Path

$pythonCommand = Get-Command python -ErrorAction Stop
$codexCommand = Get-Command codex -ErrorAction Stop
$pythonPath = $pythonCommand.Source
$codexPath = $codexCommand.Source

function Test-NormalizedPathEqual {
  param([string]$Left, [string]$Right)
  if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
    return $false
  }
  try {
    $leftPath = [System.IO.Path]::GetFullPath($Left).TrimEnd('\', '/')
    $rightPath = [System.IO.Path]::GetFullPath($Right).TrimEnd('\', '/')
    return [string]::Equals($leftPath, $rightPath, [System.StringComparison]::OrdinalIgnoreCase)
  }
  catch {
    return $false
  }
}

function Test-ExpectedRegistration {
  param($Registration, [string]$ExpectedCommand, [string]$ExpectedServer)
  if ($null -eq $Registration -or $null -eq $Registration.transport) {
    return $false
  }
  $transport = $Registration.transport
  $arguments = @($transport.args)
  return `
    ([string]$transport.type -eq 'stdio') -and `
    (Test-NormalizedPathEqual ([string]$transport.command) $ExpectedCommand) -and `
    ($arguments.Count -eq 1) -and `
    (Test-NormalizedPathEqual ([string]$arguments[0]) $ExpectedServer)
}

& $pythonPath $serverPath --version | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw 'The QA MCP server could not be started with the current Python command.'
}

$previousErrorPreference = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
$existingJson = & $codexPath mcp get $Name --json 2>$null
$getExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorPreference
$alreadyExists = $getExitCode -eq 0
$sameRegistration = $false
if ($alreadyExists) {
  $existingText = ($existingJson -join "`n")
  try {
    $existingRegistration = $existingText | ConvertFrom-Json -ErrorAction Stop
  }
  catch {
    throw "An MCP server named '$Name' exists, but its configuration could not be parsed safely. This installer will not overwrite or remove it."
  }
  $sameRegistration = Test-ExpectedRegistration $existingRegistration $pythonPath $serverPath
  if (-not $sameRegistration) {
    throw "An MCP server named '$Name' already exists with a different command. This installer will not overwrite or remove it."
  }
}

if ($DryRun) {
  [pscustomobject]@{
    ok = $true
    dry_run = $true
    name = $Name
    already_installed = $sameRegistration
    would_install = -not $alreadyExists
    command = $pythonPath
    server = $serverPath
    write_performed = $false
  } | ConvertTo-Json -Depth 3
  exit 0
}

if ($sameRegistration) {
  [pscustomobject]@{
    ok = $true
    installed = $true
    already_installed = $true
    name = $Name
    restart_required = $false
  } | ConvertTo-Json -Depth 3
  exit 0
}

if (-not $alreadyExists) {
  & $codexPath mcp add $Name -- $pythonPath $serverPath | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to register MCP server '$Name'."
  }
}

$installed = & $codexPath mcp get $Name --json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $installed) {
  throw "MCP server '$Name' was added but could not be read back for verification."
}
$installedRegistration = (($installed -join "`n") | ConvertFrom-Json -ErrorAction Stop)
if (-not (Test-ExpectedRegistration $installedRegistration $pythonPath $serverPath)) {
  throw "MCP server '$Name' was added, but its command or arguments do not match the expected read-only server."
}

[pscustomobject]@{
  ok = $true
  installed = $true
  name = $Name
  restart_required = $true
  next_step = 'Restart Codex, then use /mcp to confirm the server is connected.'
} | ConvertTo-Json -Depth 3
