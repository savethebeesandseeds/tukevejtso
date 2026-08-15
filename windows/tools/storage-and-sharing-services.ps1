param(
    [ValidateSet("start", "rebuild", "status", "stop")]
    [string] $Action
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ui.ps1")

$serviceRoot = "C:\Work\storage-and-sharing-services"
$composeFile = Join-Path $serviceRoot "compose.yaml"
$containerName = "storage-and-sharing-services"
$defaultPort = 8084
$dockerDesktopTimeoutSeconds = 90
$serviceHealthTimeoutSeconds = 120
$httpTimeoutSeconds = 45

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
    if ($null -eq (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker was not found on PATH. Install Docker Desktop or add docker.exe to PATH."
    }

    if (Test-DockerDaemon) {
        Write-Host "Docker engine is ready." -ForegroundColor Green
        return
    }

    $dockerDesktopPath = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
    $dockerDesktopProcess = Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue
    if ($null -eq $dockerDesktopProcess -and -not (Test-Path -LiteralPath $dockerDesktopPath -PathType Leaf)) {
        throw "Docker Desktop is not running, and Docker Desktop.exe was not found at $dockerDesktopPath."
    }

    if ($null -eq $dockerDesktopProcess) {
        Write-Host "Docker engine is unavailable; starting Docker Desktop..."
        Start-Process -FilePath $dockerDesktopPath -WindowStyle Hidden
    }
    else {
        Write-Host "Docker Desktop is already starting; waiting for its engine..."
    }

    $deadline = (Get-Date).AddSeconds($dockerDesktopTimeoutSeconds)
    $nextProgressAt = (Get-Date).AddSeconds(10)
    do {
        Start-Sleep -Seconds 2
        if (Test-DockerDaemon) {
            Write-Host "Docker Desktop is ready." -ForegroundColor Green
            return
        }

        if ((Get-Date) -ge $nextProgressAt) {
            $remaining = [Math]::Max(0, [Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds))
            Write-Host "Still waiting for Docker ($remaining seconds left)..." -ForegroundColor DarkGray
            $nextProgressAt = (Get-Date).AddSeconds(10)
        }
    } while ((Get-Date) -lt $deadline)

    throw "Docker Desktop did not become ready within $dockerDesktopTimeoutSeconds seconds."
}

function Assert-ServiceWorkspace {
    if (-not (Test-Path -LiteralPath $serviceRoot -PathType Container)) {
        throw "The service workspace was not found at $serviceRoot."
    }

    if (-not (Test-Path -LiteralPath $composeFile -PathType Leaf)) {
        throw "The Docker Compose file was not found at $composeFile."
    }
}

function Invoke-StorageCompose {
    param([string[]] $Arguments)

    Write-Host ("docker compose {0}" -f ($Arguments -join " ")) -ForegroundColor DarkGray

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

        & docker compose --project-directory $serviceRoot --file $composeFile @Arguments
        $composeExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $previousNativePreference
        }
    }

    if ($composeExitCode -ne 0) {
        throw "docker compose failed with exit code $composeExitCode."
    }
}

function Get-ServiceSetting {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [string] $DefaultValue
    )

    $envFile = Join-Path $serviceRoot ".env"
    if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
        return $DefaultValue
    }

    foreach ($line in Get-Content -LiteralPath $envFile) {
        if ($line -notmatch ("^\s*" + [regex]::Escape($Name) + "\s*=")) {
            continue
        }

        $value = ($line -split "=", 2)[1].Trim()
        $commentIndex = $value.IndexOf("#")
        if ($commentIndex -ge 0) {
            $value = $value.Substring(0, $commentIndex).Trim()
        }

        $value = $value.Trim('"').Trim("'")
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return $DefaultValue
}

function Get-ServicePort {
    $portText = Get-ServiceSetting -Name "PORT" -DefaultValue "$defaultPort"
    $port = 0
    if (-not [int]::TryParse($portText, [ref] $port) -or $port -lt 1 -or $port -gt 65535) {
        throw "PORT in $serviceRoot\.env must be a number from 1 to 65535; found '$portText'."
    }

    return $port
}

function Get-LanIPv4Addresses {
    $addresses = New-Object System.Collections.Generic.List[string]

    try {
        foreach ($configuration in @(Get-NetIPConfiguration -ErrorAction Stop)) {
            if ($null -eq $configuration.IPv4DefaultGateway -or $configuration.NetAdapter.Status -ne "Up") {
                continue
            }

            foreach ($entry in @($configuration.IPv4Address)) {
                $address = "$($entry.IPAddress)"
                if ($address -and $address -notmatch '^(127\.|169\.254\.)') {
                    $addresses.Add($address)
                }
            }
        }
    }
    catch {
        foreach ($entry in @(Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction SilentlyContinue)) {
            $address = "$($entry.IPAddress)"
            $alias = "$($entry.InterfaceAlias)"
            if ($address -and
                $address -notmatch '^(127\.|169\.254\.)' -and
                $alias -notmatch '^(vEthernet|Loopback)' -and
                $alias -notmatch '(Docker|WSL|Default Switch)') {
                $addresses.Add($address)
            }
        }
    }

    return [string[]]($addresses | Sort-Object -Unique)
}

function Get-ServiceUrls {
    $port = Get-ServicePort
    $localUrl = "http://127.0.0.1`:$port/"
    $lanUrls = @()

    $bindAddress = Get-ServiceSetting -Name "BIND_ADDRESS" -DefaultValue "0.0.0.0"
    if ($bindAddress -notin @("127.0.0.1", "localhost", "::1")) {
        foreach ($address in @(Get-LanIPv4Addresses)) {
            $lanUrls += "http://$address`:$port/"
        }
    }

    return [pscustomobject]@{
        Local = $localUrl
        Network = [string[]]$lanUrls
        BindAddress = $bindAddress
    }
}

function Write-ServiceUrls {
    $urls = Get-ServiceUrls

    Write-Host ""
    Write-Host "Open on this computer" -ForegroundColor DarkGray
    Write-Host ("  " + $urls.Local) -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Open on another device on this network" -ForegroundColor White

    if ($urls.Network.Count -eq 0) {
        if ($urls.BindAddress -in @("127.0.0.1", "localhost", "::1")) {
            Write-Host "  LAN access is disabled by BIND_ADDRESS=$($urls.BindAddress)." -ForegroundColor Yellow
        }
        else {
            Write-Host "  No active LAN IPv4 address was found." -ForegroundColor Yellow
        }
        return
    }

    foreach ($url in $urls.Network) {
        Write-Host ("  " + $url) -ForegroundColor Green
    }
}

function Get-ContainerRuntime {
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

        $stateLine = (& docker inspect --format "{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" $containerName 2>$null)
        if ($LASTEXITCODE -ne 0) {
            return [pscustomobject]@{ Status = "missing"; Health = "none" }
        }

        $parts = "$stateLine".Trim().Split("|", 2)
        return [pscustomobject]@{
            Status = $parts[0]
            Health = if ($parts.Count -gt 1) { $parts[1] } else { "none" }
        }
    }
    catch {
        return [pscustomobject]@{ Status = "missing"; Health = "none" }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $previousNativePreference
        }
    }
}

function Wait-ServiceHealth {
    Write-Host "Waiting up to $serviceHealthTimeoutSeconds seconds for $containerName..."
    $deadline = (Get-Date).AddSeconds($serviceHealthTimeoutSeconds)
    $lastDisplayState = $null

    do {
        $runtime = Get-ContainerRuntime
        $displayState = if ($runtime.Health -eq "none") {
            $runtime.Status
        }
        else {
            "$($runtime.Status) / $($runtime.Health)"
        }

        if ($displayState -ne $lastDisplayState) {
            Write-Host "$containerName state: $displayState" -ForegroundColor DarkGray
            $lastDisplayState = $displayState
        }

        if ($runtime.Status -eq "running" -and $runtime.Health -in @("healthy", "none")) {
            Write-Host "$containerName is ready." -ForegroundColor Green
            return
        }

        if ($runtime.Status -in @("dead", "exited")) {
            throw "$containerName stopped before becoming ready. Run 'tk storage status' for details."
        }

        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    throw "$containerName did not become ready within $serviceHealthTimeoutSeconds seconds."
}

function Get-HttpEndpointResult {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Url,
        [int] $TimeoutSeconds = 8
    )

    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec $TimeoutSeconds
        return [pscustomobject]@{
            Success = ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400)
            StatusCode = [int]$response.StatusCode
            Error = ""
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            StatusCode = 0
            Error = $_.Exception.Message
        }
    }
}

function Wait-HttpEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Url
    )

    Write-Host "Waiting up to $httpTimeoutSeconds seconds for the HTTP endpoint..."
    $deadline = (Get-Date).AddSeconds($httpTimeoutSeconds)
    $lastResult = $null

    do {
        $remaining = [Math]::Max(1, [Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds))
        $lastResult = Get-HttpEndpointResult -Url $Url -TimeoutSeconds ([Math]::Min(8, $remaining))
        if ($lastResult.Success) {
            Write-Host "Service is reachable (HTTP $($lastResult.StatusCode)): $Url" -ForegroundColor Green
            return
        }

        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    throw "The HTTP endpoint did not become reachable within $httpTimeoutSeconds seconds. Last error: $($lastResult.Error)"
}

function Show-ServiceStatus {
    param([switch] $DockerUnavailable)

    Write-TuiHeader -Title "Storage + sharing" -Subtitle "Local file transfer service; never starts automatically."

    if ($DockerUnavailable) {
        Write-TuiStatus -Label "Docker engine" -State "Warn" -Detail "Unavailable"
        Write-Host "A start action will launch Docker Desktop automatically." -ForegroundColor DarkGray
        Write-ServiceUrls
        return
    }

    Invoke-StorageCompose -Arguments @("ps", "--all")
    $runtime = Get-ContainerRuntime
    Write-Host ""

    if ($runtime.Status -eq "running" -and $runtime.Health -in @("healthy", "none")) {
        Write-TuiStatus -Label "Container" -State "Good" -Detail "$($runtime.Status) / $($runtime.Health)"
    }
    elseif ($runtime.Status -eq "missing" -or $runtime.Status -eq "exited") {
        Write-TuiStatus -Label "Container" -State "Warn" -Detail $runtime.Status
    }
    else {
        Write-TuiStatus -Label "Container" -State "Bad" -Detail "$($runtime.Status) / $($runtime.Health)"
    }

    $urls = Get-ServiceUrls
    if ($runtime.Status -eq "running") {
        $endpoint = Get-HttpEndpointResult -Url ($urls.Local + "healthz")
        if ($endpoint.Success) {
            Write-TuiStatus -Label "HTTP health" -State "Good" -Detail "HTTP $($endpoint.StatusCode)"
        }
        else {
            Write-TuiStatus -Label "HTTP health" -State "Bad" -Detail $endpoint.Error
        }
    }
    else {
        Write-TuiStatus -Label "HTTP health" -State "Warn" -Detail "Not checked; service is stopped"
    }

    Write-ServiceUrls
}

function Invoke-ServiceAction {
    param([string] $RequestedAction)

    Assert-ServiceWorkspace

    if ($RequestedAction -eq "status") {
        if (-not (Test-DockerDaemon)) {
            Show-ServiceStatus -DockerUnavailable
            return
        }

        Show-ServiceStatus
        return
    }

    if ($RequestedAction -eq "stop") {
        if (-not (Test-DockerDaemon)) {
            Write-TuiHeader -Title "Storage + sharing" -Subtitle "Stop service"
            Write-Host "Docker is not running, so the service is already off." -ForegroundColor Green
            return
        }

        Write-TuiHeader -Title "Storage + sharing" -Subtitle "Stop service"
        Invoke-StorageCompose -Arguments @("stop")
        Write-Host ""
        Write-Host "Storage and sharing is off." -ForegroundColor Green
        Write-Host "Its restart policy remains 'no'; it will not start with the computer." -ForegroundColor DarkGray
        return
    }

    Write-TuiHeader -Title "Storage + sharing" -Subtitle "Start a temporary LAN file-transfer service."
    Start-DockerDesktopIfNeeded

    if ($RequestedAction -eq "rebuild") {
        Invoke-StorageCompose -Arguments @("up", "-d", "--build")
    }
    else {
        Invoke-StorageCompose -Arguments @("up", "-d")
    }

    Wait-ServiceHealth
    $urls = Get-ServiceUrls
    Wait-HttpEndpoint -Url ($urls.Local + "healthz")

    Write-Host ""
    Write-Host "Storage and sharing is on." -ForegroundColor Green
    Write-Host "It will remain off after a reboot unless you run this tool again." -ForegroundColor DarkGray
    Write-ServiceUrls
}

function Invoke-ServiceMenu {
    $items = @(
        @{ Label = "Start"; Detail = "Start the existing Docker image"; Action = "start" },
        @{ Label = "Rebuild + start"; Detail = "Rebuild the image, then start it"; Action = "rebuild" },
        @{ Label = "Status"; Detail = "Show the container, health, and current URLs"; Action = "status" },
        @{ Label = "Stop"; Detail = "Turn the sharing service off"; Action = "stop" },
        @{ Label = "Back"; Detail = "Return to the toolkit menu"; Action = "back" }
    )

    $choice = Select-TuiItem `
        -Title "Storage + sharing" `
        -Subtitle "Control C:\Work\storage-and-sharing-services." `
        -Items $items `
        -FormatItem { param($item) "{0,-18} {1}" -f $item.Label, $item.Detail }

    if ($null -eq $choice -or $choice.Action -eq "back") {
        return
    }

    Clear-Host
    Invoke-ServiceAction -RequestedAction $choice.Action
}

if ([string]::IsNullOrWhiteSpace($Action)) {
    Invoke-ServiceMenu
}
else {
    Invoke-ServiceAction -RequestedAction $Action
}
