param(
    [switch] $Rebuild,
    [switch] $Recreate,
    [switch] $RecreateForGpu,
    [switch] $CpuOnly,
    [switch] $NoShell
)

$ErrorActionPreference = "Stop"

$containerName = "tukevejtso"
$imageName = "tukevejtso:debian-latest"
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$dockerfile = Join-Path $repoRoot "linux\docker\Dockerfile"
$dockerContext = Join-Path $repoRoot "linux\docker"
$dockerDesktopTimeoutSeconds = 90
$dockerTerminalEnv = @(
    "-e", "TERM=xterm-256color",
    "-e", "LANG=C.UTF-8",
    "-e", "LC_ALL=C.UTF-8",
    "-e", "COLORTERM=truecolor",
    "-e", "FORCE_COLOR=1"
)
$useGpu = $false

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

function Test-DockerImage {
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

        & docker image inspect $imageName *> $null
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

function Build-TukevejtsoImageIfNeeded {
    if (-not (Test-Path -LiteralPath $dockerfile)) {
        throw "Dockerfile not found: $dockerfile"
    }

    if ((-not $Rebuild) -and (Test-DockerImage)) {
        return
    }

    Write-Host "Building $imageName from $dockerfile..."
    & docker build -t $imageName -f $dockerfile $dockerContext
    if ($LASTEXITCODE -ne 0) {
        throw "docker build failed with exit code $LASTEXITCODE."
    }
}

function Test-DockerGpuSupport {
    if ($CpuOnly) {
        return $false
    }

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

        & docker run --rm --gpus all $imageName bash -lc "nvidia-smi >/dev/null 2>&1" *> $null
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

function Test-TukevejtsoContainerHasGpu {
    $containerId = Get-ContainerId
    if ([string]::IsNullOrWhiteSpace($containerId)) {
        return $false
    }

    $requests = docker inspect $containerName --format "{{json .HostConfig.DeviceRequests}}"
    if ($LASTEXITCODE -ne 0) {
        throw "docker inspect failed for $containerName with exit code $LASTEXITCODE."
    }

    return (-not [string]::IsNullOrWhiteSpace($requests)) -and
        ($requests -ne "null") -and
        ($requests -match "gpu|nvidia")
}

function Remove-TukevejtsoContainerIfNeeded {
    $containerId = Get-ContainerId
    if ([string]::IsNullOrWhiteSpace($containerId)) {
        return
    }

    $needsGpuRecreate = $RecreateForGpu -and $useGpu -and -not (Test-TukevejtsoContainerHasGpu)
    if (-not $Recreate -and -not $needsGpuRecreate) {
        if ($useGpu -and -not (Test-TukevejtsoContainerHasGpu)) {
            Write-Host "$containerName exists without GPU access. Run with -RecreateForGpu or -Recreate to enable GPU."
        }
        return
    }

    if ($needsGpuRecreate) {
        Write-Host "Recreating $containerName with GPU access..."
    }
    else {
        Write-Host "Recreating $containerName..."
    }

    & docker rm -f $containerName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "docker rm failed for $containerName with exit code $LASTEXITCODE."
    }
}

function New-TukevejtsoContainerIfNeeded {
    $containerId = Get-ContainerId
    if (-not [string]::IsNullOrWhiteSpace($containerId)) {
        return
    }

    Write-Host "Creating $containerName..."
    $dockerGpuArgs = @()
    if ($useGpu) {
        $dockerGpuArgs = @("--gpus", "all")
        Write-Host "GPU access enabled for $containerName."
    }

    & docker create `
        --name $containerName `
        -it `
        @dockerTerminalEnv `
        @dockerGpuArgs `
        -v "${repoRoot}:/workspace/tukevejtso" `
        -v "tukevejtso-cutout-venvs:/opt/tukevejtso-venvs" `
        -w "/workspace/tukevejtso/linux" `
        $imageName `
        sleep infinity | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "docker create failed for $containerName with exit code $LASTEXITCODE."
    }
}

function Start-TukevejtsoContainerIfNeeded {
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
}

Test-DockerCommand
Start-DockerDesktopIfNeeded
Set-ConsoleUtf8IfPossible
Build-TukevejtsoImageIfNeeded
$useGpu = Test-DockerGpuSupport
if ($useGpu) {
    Write-Host "Docker GPU support detected."
}
else {
    Write-Host "Docker GPU support not available; using CPU container."
}
Remove-TukevejtsoContainerIfNeeded
New-TukevejtsoContainerIfNeeded
Start-TukevejtsoContainerIfNeeded

if ($NoShell) {
    Write-Host "$containerName is ready."
    exit 0
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
