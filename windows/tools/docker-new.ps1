$ErrorActionPreference = "Stop"

function Test-Docker {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if ($null -eq $docker) {
        throw "Docker was not found on PATH. Install Docker Desktop or add docker.exe to PATH."
    }
}

function Read-Default {
    param(
        [string] $Prompt,
        [string] $Default
    )

    $value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }

    return $value
}

Test-Docker

Write-Host "Create and start a Docker container"
Write-Host ""

$image = Read-Default -Prompt "Image" -Default "ubuntu:latest"
$name = Read-Host "Container name (blank for Docker-generated name)"
$ports = Read-Host "Port mapping, for example 8080:80 (blank for none)"
$volume = Read-Host "Volume mapping, for example C:\work:/work (blank for none)"
$shell = Read-Default -Prompt "Shell command" -Default "/bin/bash"

$args = @("run", "-it")

if (-not [string]::IsNullOrWhiteSpace($name)) {
    $args += @("--name", $name)
}

if (-not [string]::IsNullOrWhiteSpace($ports)) {
    $args += @("-p", $ports)
}

if (-not [string]::IsNullOrWhiteSpace($volume)) {
    $args += @("-v", $volume)
}

$args += @($image, $shell)

Write-Host ""
Write-Host ("Running: docker " + ($args -join " ")) -ForegroundColor DarkGray
& docker @args

if ($LASTEXITCODE -ne 0) {
    throw "docker run failed with exit code $LASTEXITCODE. Check that Docker Desktop is running and that the image/options are valid."
}
