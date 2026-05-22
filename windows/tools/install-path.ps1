$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$currentPath = [Environment]::GetEnvironmentVariable("Path", "User")

if ([string]::IsNullOrWhiteSpace($currentPath)) {
    $parts = @()
}
else {
    $parts = $currentPath -split ";"
}

$alreadyInstalled = $parts | Where-Object {
    $_.TrimEnd("\") -ieq $root.TrimEnd("\")
}

if ($alreadyInstalled) {
    Write-Host "Already on user PATH:"
    Write-Host $root
    exit 0
}

$newPath = if ([string]::IsNullOrWhiteSpace($currentPath)) {
    $root
}
else {
    $currentPath.TrimEnd(";") + ";" + $root
}

[Environment]::SetEnvironmentVariable("Path", $newPath, "User")

Write-Host "Added to user PATH:"
Write-Host $root
Write-Host ""
Write-Host "Open a new Command Prompt or Windows Terminal tab, then run: tk"
