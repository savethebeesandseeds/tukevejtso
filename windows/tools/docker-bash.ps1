$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ui.ps1")

function Test-Docker {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if ($null -eq $docker) {
        throw "Docker was not found on PATH. Install Docker Desktop or add docker.exe to PATH."
    }
}

function Select-Container {
    param(
        [array] $Containers
    )

    Select-TuiItem `
        -Title "Docker Containers" `
        -Subtitle "Pick a container to open an interactive shell." `
        -Items $Containers `
        -FormatItem {
            param($container)
            "{0,-24} {1,-22} {2}" -f $container.Names, $container.Image, $container.Status
        }
}

Test-Docker

try {
    $containers = docker ps -a --format '{{json .}}' | ForEach-Object { $_ | ConvertFrom-Json }
}
catch {
    throw "Could not list Docker containers. Check that Docker Desktop is running. Details: $($_.Exception.Message)"
}

if ($LASTEXITCODE -ne 0) {
    throw "docker ps failed with exit code $LASTEXITCODE. Check that Docker Desktop is running."
}

if ($null -eq $containers -or $containers.Count -eq 0) {
    Write-Host "No containers found." -ForegroundColor Yellow
    Write-Host "Start one first, or use the create-container option."
    exit 0
}

if ($containers -isnot [array]) {
    $containers = @($containers)
}

$container = Select-Container -Containers $containers
if ($null -eq $container) {
    exit 0
}

Write-Host ""
if ($container.State -ne "running") {
    Write-Host "Starting $($container.Names)..."
    & docker start $container.Names | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "docker start failed for $($container.Names) with exit code $LASTEXITCODE."
    }
}

Write-Host "Opening /bin/bash in $($container.Names)..."
& docker exec -it $container.Names /bin/bash

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "/bin/bash failed. Trying /bin/sh..." -ForegroundColor Yellow
    & docker exec -it $container.Names /bin/sh

    if ($LASTEXITCODE -ne 0) {
        throw "Could not open /bin/bash or /bin/sh in $($container.Names). Last exit code: $LASTEXITCODE."
    }
}
