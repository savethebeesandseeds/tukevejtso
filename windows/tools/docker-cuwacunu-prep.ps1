$ErrorActionPreference = "Stop"

$containerName = "cuwacunu-dev"

$docker = Get-Command docker -ErrorAction SilentlyContinue
if ($null -eq $docker) {
    throw "Docker was not found on PATH. Install Docker Desktop or add docker.exe to PATH."
}

try {
    $containerId = docker ps -a --filter "name=^/$containerName$" --format "{{.ID}}"
}
catch {
    throw "Could not query Docker containers. Check that Docker Desktop is running. Details: $($_.Exception.Message)"
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
