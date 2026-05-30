[CmdletBinding()]
param(
  [switch]$IncludeSite,
  [switch]$SkipInstall,
  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This launcher prepares the local Jellyfish development environment and starts
# each long-running service in its own PowerShell window for one-click startup.
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path -LiteralPath $scriptRoot).Path
$backendDir = Join-Path $repoRoot 'backend'
$frontDir = Join-Path $repoRoot 'front'
$siteDir = Join-Path $repoRoot 'site'
$runStatePath = Join-Path $repoRoot '.jellyfish-dev-processes.json'

# This helper keeps launcher output consistent so setup and startup progress is
# easy to follow from a single terminal window.
function Write-Step {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  Write-Host "[Jellyfish] $Message" -ForegroundColor Cyan
}

# This helper fails early when a required CLI tool is missing, which avoids
# partial startup and gives the user a clear next action.
function Assert-CommandAvailable {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$CommandName,
    [Parameter(Mandatory = $true)]
    [string]$InstallHint
  )

  if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
    throw "Missing required command '$CommandName'. $InstallHint"
  }
}

# This helper resolves a logical tool name to the executable and prefix
# arguments that should actually be invoked in this environment.
function Resolve-CommandRunner {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$LogicalName
  )

  $directCommand = Get-Command $LogicalName -ErrorAction SilentlyContinue
  if ($directCommand) {
    return [PSCustomObject]@{
      LogicalName = $LogicalName
      DisplayName = $LogicalName
      FilePath = $LogicalName
      PrefixArguments = @()
    }
  }

  if ($LogicalName -eq 'pnpm') {
    $corepackCommand = Get-Command 'corepack' -ErrorAction SilentlyContinue
    if ($corepackCommand) {
      return [PSCustomObject]@{
        LogicalName = $LogicalName
        DisplayName = 'pnpm (via corepack)'
        FilePath = 'corepack'
        PrefixArguments = @('pnpm')
      }
    }
  }

  return $null
}

# This helper creates a local config file from the checked-in example when the
# destination does not exist yet, which removes a manual first-run step.
function Ensure-FileFromTemplate {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$TemplatePath
  )

  if (Test-Path -LiteralPath $Path) {
    return
  }

  if ($DryRun) {
    Write-Step "Would create $(Split-Path -Leaf $Path) from template."
    return
  }

  Copy-Item -LiteralPath $TemplatePath -Destination $Path
  Write-Step "Created $(Split-Path -Leaf $Path) from template."
}

# This helper writes launcher-owned process metadata to disk so the matching
# shutdown script can close exactly the dev windows created for this repo.
function Save-RunState {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Processes
  )

  $state = [PSCustomObject]@{
    repoRoot = $repoRoot
    updatedAt = (Get-Date).ToString('o')
    processes = $Processes
  }

  $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $runStatePath -Encoding UTF8
}

# This helper removes the persisted process state once no tracked Jellyfish dev
# processes should still be considered active.
function Remove-RunState {
  [CmdletBinding()]
  param()

  if (Test-Path -LiteralPath $runStatePath) {
    Remove-Item -LiteralPath $runStatePath
  }
}

# This helper warns about an existing tracked session before another start run
# creates duplicate backend/frontend windows for the same repository.
function Test-TrackedRunStateActive {
  [CmdletBinding()]
  param()

  if (-not (Test-Path -LiteralPath $runStatePath)) {
    return $false
  }

  $state = Get-Content -LiteralPath $runStatePath -Raw | ConvertFrom-Json
  foreach ($processInfo in $state.processes) {
    if (Get-Process -Id $processInfo.processId -ErrorAction SilentlyContinue) {
      return $true
    }
  }

  Remove-RunState
  return $false
}

# This helper safely quotes a value for inline PowerShell command text so the
# generated startup commands work even when the repo path contains spaces.
function ConvertTo-SingleQuotedLiteral {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Value
  )

  return "'" + $Value.Replace("'", "''") + "'"
}

# This helper turns an executable plus arguments into an external PowerShell
# invocation string that can be reused for setup commands and new console windows.
function New-ExternalCommandText {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [string[]]$Arguments = @()
  )

  $quotedArguments = $Arguments | ForEach-Object { ConvertTo-SingleQuotedLiteral -Value $_ }
  $commandParts = @((ConvertTo-SingleQuotedLiteral -Value $FilePath)) + $quotedArguments
  return '& ' + ($commandParts -join ' ')
}

# This helper runs setup commands in the current window so dependency failures
# are visible before background dev servers are launched elsewhere.
function Invoke-SetupCommand {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$WorkingDirectory,
    [Parameter(Mandatory = $true)]
    [string]$Description,
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [string[]]$Arguments = @()
  )

  $commandText = @"
Set-Location -LiteralPath $(ConvertTo-SingleQuotedLiteral -Value $WorkingDirectory)
$(New-ExternalCommandText -FilePath $FilePath -Arguments $Arguments)
"@

  Write-Step $Description

  if ($DryRun) {
    Write-Host "  [dry-run] $commandText" -ForegroundColor DarkGray
    return
  }

  & ([ScriptBlock]::Create($commandText))
}

# This helper opens a dedicated PowerShell window for a long-running dev server
# so backend, frontend, and docs logs remain separate and easy to monitor.
function Start-DevWindow {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Title,
    [Parameter(Mandatory = $true)]
    [string]$WorkingDirectory,
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [string[]]$Arguments = @()
  )

  $commandText = @"
`$Host.UI.RawUI.WindowTitle = $(ConvertTo-SingleQuotedLiteral -Value $Title)
Set-Location -LiteralPath $(ConvertTo-SingleQuotedLiteral -Value $WorkingDirectory)
$(New-ExternalCommandText -FilePath $FilePath -Arguments $Arguments)
"@
  $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($commandText))

  if ($DryRun) {
    Write-Host "  [dry-run] window='$Title' command=$commandText" -ForegroundColor DarkGray
    return [PSCustomObject]@{
      Title = $Title
      WorkingDirectory = $WorkingDirectory
      FilePath = $FilePath
      Arguments = $Arguments
      ProcessId = 0
    }
  }

  $process = Start-Process -FilePath 'powershell.exe' `
    -WorkingDirectory $WorkingDirectory `
    -ArgumentList @('-NoExit', '-EncodedCommand', $encodedCommand) `
    -PassThru

  return [PSCustomObject]@{
    Title = $Title
    WorkingDirectory = $WorkingDirectory
    FilePath = $FilePath
    Arguments = $Arguments
    ProcessId = $process.Id
  }
}

Write-Step 'Checking required tools...'
Assert-CommandAvailable -CommandName 'uv' -InstallHint 'Install uv from https://docs.astral.sh/uv/getting-started/installation/.'
if ($IncludeSite) {
  Assert-CommandAvailable -CommandName 'hugo' -InstallHint 'Install Hugo Extended from https://gohugo.io/installation/.'
}

$uvRunner = Resolve-CommandRunner -LogicalName 'uv'
$pnpmRunner = Resolve-CommandRunner -LogicalName 'pnpm'

if (-not $pnpmRunner) {
  throw "Missing required command 'pnpm'. Install pnpm from https://pnpm.io/installation/, or enable it with corepack."
}

Write-Step 'Preparing local environment files...'
Ensure-FileFromTemplate `
  -Path (Join-Path $backendDir '.env') `
  -TemplatePath (Join-Path $backendDir '.env.example')

if (Test-TrackedRunStateActive) {
  throw "Detected an existing Jellyfish dev session for this repo. Run .\\stop-dev.bat first, or close the tracked windows before starting again."
}

if (-not $SkipInstall) {
  Invoke-SetupCommand `
    -WorkingDirectory $backendDir `
    -Description 'Syncing backend dependencies with uv...' `
    -FilePath $uvRunner.FilePath `
    -Arguments ($uvRunner.PrefixArguments + @('sync'))

  Invoke-SetupCommand `
    -WorkingDirectory $frontDir `
    -Description "Installing frontend dependencies with $($pnpmRunner.DisplayName) (frozen lockfile)..." `
    -FilePath $pnpmRunner.FilePath `
    -Arguments ($pnpmRunner.PrefixArguments + @('install', '--frozen-lockfile'))

  if ($IncludeSite) {
    Invoke-SetupCommand `
      -WorkingDirectory $siteDir `
      -Description 'Tidying Hugo modules for the documentation site...' `
      -FilePath 'hugo' `
      -Arguments @('mod', 'tidy')
  }
} else {
  Write-Step 'Skipping dependency installation by request.'
}

Invoke-SetupCommand `
  -WorkingDirectory $backendDir `
  -Description 'Initializing backend database schema...' `
  -FilePath $uvRunner.FilePath `
  -Arguments ($uvRunner.PrefixArguments + @('run', 'python', 'init_db.py'))

Write-Step 'Starting backend and frontend dev servers...'
$startedProcesses = @()
$startedProcesses += Start-DevWindow `
  -Title 'Jellyfish Backend' `
  -WorkingDirectory $backendDir `
  -FilePath $uvRunner.FilePath `
  -Arguments ($uvRunner.PrefixArguments + @('run', 'uvicorn', 'app.main:app', '--reload', '--host', '0.0.0.0', '--port', '8000'))

$startedProcesses += Start-DevWindow `
  -Title 'Jellyfish Frontend' `
  -WorkingDirectory $frontDir `
  -FilePath $pnpmRunner.FilePath `
  -Arguments ($pnpmRunner.PrefixArguments + @('dev'))

if ($IncludeSite) {
  Write-Step 'Starting the documentation site preview...'
  $startedProcesses += Start-DevWindow `
    -Title 'Jellyfish Site' `
    -WorkingDirectory $siteDir `
    -FilePath 'hugo' `
    -Arguments @('server', '--buildDrafts', '--disableFastRender')
}

if (-not $DryRun) {
  Save-RunState -Processes ($startedProcesses | ForEach-Object {
    [PSCustomObject]@{
      title = $_.Title
      workingDirectory = $_.WorkingDirectory
      processId = $_.ProcessId
      command = @($_.FilePath) + $_.Arguments
    }
  })
}

Write-Step 'Launch complete.'
Write-Host '  Frontend: http://localhost:7788' -ForegroundColor Green
Write-Host '  Backend:  http://localhost:8000' -ForegroundColor Green
Write-Host '  Swagger:  http://localhost:8000/docs' -ForegroundColor Green
if ($IncludeSite) {
  Write-Host '  Site:     http://localhost:1313' -ForegroundColor Green
}

if ($DryRun) {
  Write-Step 'Dry run finished without launching new windows.'
}
