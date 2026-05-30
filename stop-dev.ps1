[CmdletBinding()]
param(
  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This shutdown script closes only the Jellyfish dev windows and child
# processes that were launched for the current repository.
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path -LiteralPath $scriptRoot).Path
$backendDir = Join-Path $repoRoot 'backend'
$frontDir = Join-Path $repoRoot 'front'
$siteDir = Join-Path $repoRoot 'site'
$runStatePath = Join-Path $repoRoot '.jellyfish-dev-processes.json'

# This helper keeps output consistent with the paired startup script.
function Write-Step {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  Write-Host "[Jellyfish] $Message" -ForegroundColor Cyan
}

# This helper deletes the local process-state file once shutdown is complete or
# when the recorded processes are no longer valid.
function Remove-RunState {
  [CmdletBinding()]
  param()

  if (Test-Path -LiteralPath $runStatePath) {
    Remove-Item -LiteralPath $runStatePath
  }
}

# This helper terminates a PowerShell launcher window together with any child
# processes beneath it, which is the safest way to close the repo dev servers.
function Stop-ProcessTreeById {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,
    [Parameter(Mandatory = $true)]
    [string]$Label
  )

  if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
    Write-Step "Tracked $Label process $ProcessId is already stopped."
    return $false
  }

  if ($DryRun) {
    Write-Host "  [dry-run] taskkill /PID $ProcessId /T /F" -ForegroundColor DarkGray
    return $true
  }

  Write-Step "Stopping $Label (PID $ProcessId)..."
  & taskkill.exe /PID $ProcessId /T /F | Out-Null
  return $true
}

# This helper detects Jellyfish dev windows even when the state file is gone,
# using repo-specific command line fragments as a conservative fallback.
function Find-FallbackProcessIds {
  [CmdletBinding()]
  param()

  $escapedRepoRoot = [Regex]::Escape($repoRoot)
  $patterns = @(
    "app\.main:app",
    "init_db\.py",
    "pnpm'\s+'dev",
    "hugo'\s+'server'.*--buildDrafts"
  )

  $matchedIds = @()
  $processes = Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq 'powershell.exe' -and
    $_.CommandLine -match $escapedRepoRoot
  }

  foreach ($process in $processes) {
    foreach ($pattern in $patterns) {
      if ($process.CommandLine -match $pattern) {
        $matchedIds += [int]$process.ProcessId
        break
      }
    }
  }

  return $matchedIds | Sort-Object -Unique
}

$stoppedAny = $false

if (Test-Path -LiteralPath $runStatePath) {
  Write-Step 'Stopping tracked Jellyfish dev processes...'
  $state = Get-Content -LiteralPath $runStatePath -Raw | ConvertFrom-Json
  foreach ($processInfo in $state.processes) {
    $stoppedCurrent = Stop-ProcessTreeById `
      -ProcessId ([int]$processInfo.processId) `
      -Label ([string]$processInfo.title)
    if ($stoppedCurrent) {
      $stoppedAny = $true
    }
  }

  if (-not $DryRun) {
    Remove-RunState
  }
} else {
  Write-Step 'No tracked process state found. Trying repo-specific fallback detection...'
  $fallbackProcessIds = Find-FallbackProcessIds
  foreach ($processId in $fallbackProcessIds) {
    $stoppedCurrent = Stop-ProcessTreeById -ProcessId $processId -Label 'fallback-matched Jellyfish window'
    if ($stoppedCurrent) {
      $stoppedAny = $true
    }
  }
}

if (-not $stoppedAny) {
  Write-Step 'No running Jellyfish dev processes were found.'
} elseif (-not $DryRun) {
  Write-Step 'Shutdown complete.'
}

if ($DryRun) {
  Write-Step 'Dry run finished without stopping processes.'
}
