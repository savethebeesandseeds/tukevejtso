$ErrorActionPreference = "Stop"

$containerName = "cuwacunu-dev"
$dockerDesktopTimeoutSeconds = 90

function Test-DockerCommand {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if ($null -eq $docker) {
        throw "Docker was not found on PATH. Install Docker Desktop or add docker.exe to PATH."
    }
}

function Test-DockerDaemon {
    $previousErrorActionPreference = $ErrorActionPreference
    $hasNativePreference = Test-Path Variable:PSNativeCommandUseErrorActionPreference
    if ($hasNativePreference) {
        $previousNativePreference = $PSNativeCommandUseErrorActionPreference
    }

    try {
        $ErrorActionPreference = "Continue"
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $false
        }

        & docker info --format "{{.ServerVersion}}" *> $null
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $previousNativePreference
        }
    }
}

function Start-DockerDesktopIfNeeded {
    if (Test-DockerDaemon) {
        return
    }

    $dockerDesktopPath = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
    if (-not (Test-Path $dockerDesktopPath)) {
        throw "Docker Desktop is not running, and Docker Desktop.exe was not found at $dockerDesktopPath. Start Docker Desktop and try again."
    }

    Write-Host "Starting Docker Desktop..."
    Start-Process -FilePath $dockerDesktopPath -WindowStyle Hidden

    $deadline = (Get-Date).AddSeconds($dockerDesktopTimeoutSeconds)
    do {
        Start-Sleep -Seconds 2
        if (Test-DockerDaemon) {
            Write-Host "Docker Desktop is ready."
            return
        }
    } while ((Get-Date) -lt $deadline)

    throw "Docker Desktop was started, but the Docker daemon did not become ready within $dockerDesktopTimeoutSeconds seconds."
}

Test-DockerCommand
Start-DockerDesktopIfNeeded

try {
    $containerId = docker ps -a --filter "name=^/$containerName$" --format "{{.ID}}"
}
catch {
    throw "Could not query Docker containers. Details: $($_.Exception.Message)"
}

if ($LASTEXITCODE -ne 0) {
    throw "docker ps failed with exit code $LASTEXITCODE. Check that Docker Desktop is running."
}

if ([string]::IsNullOrWhiteSpace($containerId)) {
    throw "Container not found: $containerName"
}

try {
    $state = docker inspect -f "{{.State.Running}}" $containerName
}
catch {
    throw "Could not inspect container $containerName. Details: $($_.Exception.Message)"
}

if ($LASTEXITCODE -ne 0) {
    throw "docker inspect failed for $containerName with exit code $LASTEXITCODE."
}

if ($state -ne "true") {
    Write-Host "Starting $containerName..."
    docker start $containerName | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "docker start failed for $containerName with exit code $LASTEXITCODE."
    }
}

Write-Host "Opening /bin/bash in $containerName..."
docker exec -it $containerName /bin/bash

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "/bin/bash failed. Trying /bin/sh..."
    docker exec -it $containerName /bin/sh

    if ($LASTEXITCODE -ne 0) {
        throw "Could not open /bin/bash or /bin/sh in $containerName. Last exit code: $LASTEXITCODE."
    }
}

