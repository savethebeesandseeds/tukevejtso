[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$Port = 8080,

    [ValidateRange(1, 128)]
    [int]$BuildJobs = 4
)

$ErrorActionPreference = "Stop"

$projectRoot = "C:\Work\medical\muscles"
$projectLauncher = Join-Path $projectRoot "run.ps1"

if (-not (Test-Path -LiteralPath $projectLauncher -PathType Leaf)) {
    throw "The OpenSim launcher was not found: $projectLauncher"
}

if ($null -eq (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker was not found on PATH. Install or start Docker Desktop, then try again."
}

$powerShellPath = (Get-Process -Id $PID).Path
if ([string]::IsNullOrWhiteSpace($powerShellPath)) {
    throw "Could not determine the current PowerShell executable."
}

& $powerShellPath `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $projectLauncher `
    -Port $Port `
    -BuildJobs $BuildJobs

if ($LASTEXITCODE -ne 0) {
    throw "The OpenSim launcher failed with exit code $LASTEXITCODE."
}
