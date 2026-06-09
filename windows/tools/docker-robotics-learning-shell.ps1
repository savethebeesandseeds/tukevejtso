$ErrorActionPreference = "Stop"

$containerName = "robotics-learning-dev"
$oneDriveRoot = if ([string]::IsNullOrWhiteSpace($env:OneDrive)) {
    Join-Path $env:USERPROFILE "OneDrive"
}
else {
    $env:OneDrive
}
$composeProjectPath = Join-Path $oneDriveRoot "Documents\Search Jobs\robotics-learning"
$dockerDesktopTimeoutSeconds = 90
$dockerTerminalEnv = @(
    "-e", "TERM=xterm-256color",
    "-e", "LANG=C.UTF-8",
    "-e", "LC_ALL=C.UTF-8",
    "-e", "COLORTERM=truecolor",
    "-e", "FORCE_COLOR=1"
)

function Set-ConsoleUtf8IfPossible {
    try {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [Console]::InputEncoding = $utf8NoBom
        [Console]::OutputEncoding = $utf8NoBom
        $script:OutputEncoding = $utf8NoBom
        & chcp.com 65001 > $null
    }
    catch {
        # Best effort: Docker env still fixes locale/color negotiation inside the container.
    }
}

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

function Get-ContainerId {
    try {
        $id = docker ps -a --filter "name=^/$containerName$" --format "{{.ID}}"
    }
    catch {
        throw "Could not query Docker containers. Details: $($_.Exception.Message)"
    }

    if ($LASTEXITCODE -ne 0) {
        throw "docker ps failed with exit code $LASTEXITCODE. Check that Docker Desktop is running."
    }

    return $id
}

function Start-RoboticsLearningComposeIfNeeded {
    $containerId = Get-ContainerId
    if (-not [string]::IsNullOrWhiteSpace($containerId)) {
        return
    }

    if (-not (Test-Path $composeProjectPath)) {
        throw "Container not found: $containerName. Compose project path was also not found: $composeProjectPath"
    }

    Write-Host "Container not found. Building and starting robotics-learning from $composeProjectPath..."
    & docker compose --project-directory $composeProjectPath up -d --build

    if ($LASTEXITCODE -ne 0) {
        throw "docker compose up failed for $composeProjectPath with exit code $LASTEXITCODE."
    }

    $containerId = Get-ContainerId
    if ([string]::IsNullOrWhiteSpace($containerId)) {
        throw "Container still not found after compose start: $containerName"
    }
}

Test-DockerCommand
Start-DockerDesktopIfNeeded
Set-ConsoleUtf8IfPossible
Start-RoboticsLearningComposeIfNeeded

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
& docker exec -it @dockerTerminalEnv $containerName /bin/bash

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "/bin/bash failed. Trying /bin/sh..."
    & docker exec -it @dockerTerminalEnv $containerName /bin/sh

    if ($LASTEXITCODE -ne 0) {
        throw "Could not open /bin/bash or /bin/sh in $containerName. Last exit code: $LASTEXITCODE."
    }
}
