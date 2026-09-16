param(
    [ValidateSet("start", "rebuild", "status", "stop")]
    [string] $Action
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ui.ps1")

$serviceRoot = "C:\Work\storage-and-sharing-services"
$setupFile = Join-Path $serviceRoot "setup.sh"
$containerName = "storage-and-sharing-services"
$containerImage = "debian:latest"
$containerPort = 8084
$runtimeRoot = "/opt/storage-and-sharing-services"
$runtimeHome = "/var/lib/storage-and-sharing-services"
$runtimeUid = 10001
$runtimeGid = 10001
$managedLabel = "org.tukevejtso.storage-and-sharing-services.managed"
$configurationLabel = "org.tukevejtso.storage-and-sharing-services.configuration"
$provisionRevision = "1"
$defaultPort = 8084
$defaultBindAddress = "0.0.0.0"
$defaultMaximumFileSizeMb = 1024
$dockerDesktopTimeoutSeconds = 90
$serviceHealthTimeoutSeconds = 900
$httpTimeoutSeconds = 45

function Invoke-Docker {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments,
        [switch] $Quiet
    )

    Write-Host ("docker {0}" -f ($Arguments -join " ")) -ForegroundColor DarkGray

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

        $output = @(& docker @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $previousNativePreference
        }
    }

    if ($exitCode -ne 0) {
        $detail = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = "No diagnostic output was returned."
        }
        throw ("docker {0} failed with exit code {1}.{2}{3}" -f ($Arguments -join " "), $exitCode, [Environment]::NewLine, $detail)
    }

    if (-not $Quiet) {
        $output
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

    $requiredFiles = @(
        $setupFile,
        (Join-Path $serviceRoot "package.json"),
        (Join-Path $serviceRoot "package-lock.json"),
        (Join-Path $serviceRoot "server.js")
    )
    foreach ($requiredFile in $requiredFiles) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "Required service file was not found: $requiredFile"
        }
    }

    $requiredDirectories = @(
        (Join-Path $serviceRoot "public"),
        (Join-Path $serviceRoot "shared\received"),
        (Join-Path $serviceRoot "shared\available")
    )
    foreach ($requiredDirectory in $requiredDirectories) {
        if (-not (Test-Path -LiteralPath $requiredDirectory -PathType Container)) {
            throw "Required service directory was not found: $requiredDirectory"
        }
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

function Get-ServiceConfiguration {
    $portText = Get-ServiceSetting -Name "PORT" -DefaultValue "$defaultPort"
    $port = 0
    if (-not [int]::TryParse($portText, [ref] $port) -or $port -lt 1 -or $port -gt 65535) {
        throw "PORT in $serviceRoot\.env must be a number from 1 to 65535; found '$portText'."
    }

    $maximumFileSizeText = Get-ServiceSetting -Name "MAX_FILE_SIZE_MB" -DefaultValue "$defaultMaximumFileSizeMb"
    $maximumFileSizeMb = 0
    if (-not [int]::TryParse($maximumFileSizeText, [ref] $maximumFileSizeMb) -or
        $maximumFileSizeMb -lt 1 -or $maximumFileSizeMb -gt 10240) {
        throw "MAX_FILE_SIZE_MB must be a number from 1 to 10240; found '$maximumFileSizeText'."
    }

    $bindAddressText = Get-ServiceSetting -Name "BIND_ADDRESS" -DefaultValue $defaultBindAddress
    if ($bindAddressText -notin @("0.0.0.0", "127.0.0.1")) {
        throw "BIND_ADDRESS must be exactly 0.0.0.0 or 127.0.0.1; found '$bindAddressText'."
    }

    return [pscustomobject]@{
        Port = $port
        BindAddress = $bindAddressText
        MaximumFileSizeMb = $maximumFileSizeMb
    }
}

function Get-ConfigurationFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Configuration
    )

    $payload = @(
        $provisionRevision,
        $containerImage,
        $serviceRoot.ToLowerInvariant(),
        $Configuration.BindAddress,
        "$($Configuration.Port)",
        "$($Configuration.MaximumFileSizeMb)",
        "$containerPort",
        ("{0}:{1}" -f $runtimeUid, $runtimeGid)
    ) -join [Environment]::NewLine

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        $hash = $algorithm.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-ContainerRuntime {
    param([string] $Identity = $containerName)

    $previousErrorActionPreference = $ErrorActionPreference
    $hasNativePreference = Test-Path Variable:PSNativeCommandUseErrorActionPreference
    if ($hasNativePreference) {
        $previousNativePreference = $PSNativeCommandUseErrorActionPreference
    }

    $inspectionOutput = @()
    $inspectExitCode = $null
    $invocationError = $null
    try {
        $ErrorActionPreference = "Continue"
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $false
        }

        $inspectionOutput = @(& docker container inspect $Identity 2>&1)
        $inspectExitCode = $LASTEXITCODE
    }
    catch {
        $invocationError = $_.Exception
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $previousNativePreference
        }
    }

    if ($null -ne $invocationError) {
        throw "Could not inspect container '$Identity': $($invocationError.Message)"
    }

    if ($inspectExitCode -ne 0) {
        $detail = ($inspectionOutput | ForEach-Object { "$_" }) -join [Environment]::NewLine
        if ($detail -match '(?i)\bno such (?:container|object)\b') {
            return [pscustomobject]@{
                Status = "missing"
                Health = "none"
                Managed = $false
                Configuration = ""
                Image = ""
                Id = ""
            }
        }

        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = "No diagnostic output was returned."
        }
        throw "Could not inspect container '$Identity'. Docker exited with code $inspectExitCode. $detail"
    }

    try {
        $parsed = (($inspectionOutput | ForEach-Object { "$_" }) -join [Environment]::NewLine) | ConvertFrom-Json
        $inspection = @($parsed)[0]
    }
    catch {
        throw "Docker returned invalid inspection JSON for '$Identity': $($_.Exception.Message)"
    }

    if ($null -eq $inspection -or $null -eq $inspection.State -or $null -eq $inspection.Config) {
        throw "Docker returned incomplete inspection data for '$Identity'."
    }

    $health = "none"
    if ($null -ne $inspection.State.Health -and -not [string]::IsNullOrWhiteSpace("$($inspection.State.Health.Status)")) {
        $health = "$($inspection.State.Health.Status)"
    }

    $managedValue = ""
    $configurationValue = ""
    if ($null -ne $inspection.Config.Labels) {
        $managedProperty = $inspection.Config.Labels.PSObject.Properties[$managedLabel]
        if ($null -ne $managedProperty) {
            $managedValue = "$($managedProperty.Value)"
        }
        $configurationProperty = $inspection.Config.Labels.PSObject.Properties[$configurationLabel]
        if ($null -ne $configurationProperty) {
            $configurationValue = "$($configurationProperty.Value)"
        }
    }

    return [pscustomobject]@{
        Status = "$($inspection.State.Status)"
        Health = $health
        Managed = ($managedValue -eq "true")
        Configuration = $configurationValue
        Image = "$($inspection.Config.Image)"
        Id = "$($inspection.Id)"
    }
}

function Test-ContainerImage {
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

        & docker image inspect $containerImage *> $null
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

function Ensure-ContainerImage {
    param([switch] $PullLatest)

    if ($PullLatest -or -not (Test-ContainerImage)) {
        Invoke-Docker -Arguments @("image", "pull", $containerImage) | Out-Host
    }
}

function Assert-ManagedContainer {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Runtime
    )

    if (-not $Runtime.Managed) {
        throw "Container '$containerName' exists but is not labeled as managed by Tukevejtso. It has been preserved. Do not remove it without inspecting it and approving that exact deletion."
    }
}

function New-StorageContainer {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Configuration
    )

    $fingerprint = Get-ConfigurationFingerprint -Configuration $Configuration
    $receivedPath = Join-Path $serviceRoot "shared\received"
    $availablePath = Join-Path $serviceRoot "shared\available"
    $publishedPort = "$($Configuration.BindAddress):$($Configuration.Port):$containerPort"
    # Keep this quote-free so Windows PowerShell 5.1 passes it to docker.exe as
    # one native argument rather than splitting JavaScript punctuation.
    $healthCommand = "curl --fail --silent --show-error http://127.0.0.1:8084/healthz"
    $bootstrapCommand = "bash /workspace/setup.sh && exec setpriv --reuid=$runtimeUid --regid=$runtimeGid --clear-groups --no-new-privs --bounding-set=-all --inh-caps=-all --ambient-caps=-all env HOME=$runtimeHome NODE_ENV=production NODE_PATH=$runtimeRoot/node_modules node /workspace/server.js"

    $arguments = @(
        "container", "create",
        "--name", $containerName,
        "--hostname", $containerName,
        "--label", "$managedLabel=true",
        "--label", "$configurationLabel=$fingerprint",
        "--init",
        "--restart", "no",
        "--stop-timeout", "15",
        "--security-opt", "no-new-privileges:true",
        "--tmpfs", "/tmp:rw,nosuid,nodev,size=64m",
        "--publish", $publishedPort,
        "--mount", "type=bind,source=$serviceRoot,target=/workspace,readonly",
        "--mount", "type=bind,source=$receivedPath,target=/data/received",
        "--mount", "type=bind,source=$availablePath,target=/data/available,readonly",
        "--env", "HOST=0.0.0.0",
        "--env", "PORT=$containerPort",
        "--env", "UPLOAD_DIR=/data/received",
        "--env", "DOWNLOAD_DIR=/data/available",
        "--env", "MAX_FILE_SIZE_MB=$($Configuration.MaximumFileSizeMb)",
        "--health-cmd", $healthCommand,
        "--health-interval", "30s",
        "--health-timeout", "3s",
        "--health-start-period", "10m",
        "--health-retries", "3",
        $containerImage,
        "bash", "-lc", $bootstrapCommand
    )

    $createOutput = @(Invoke-Docker -Arguments $arguments)
    $createdId = $createOutput |
        ForEach-Object { "$($_)".Trim() } |
        Where-Object { $_ -match '^[0-9a-f]{12,64}$' } |
        Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($createdId)) {
        throw "Docker did not return the ID of the newly created '$containerName' container. Nothing will be removed automatically."
    }
    Write-Host "Created only container '$containerName' from $containerImage." -ForegroundColor Green
    return "$createdId"
}

function Assert-ContainerConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Runtime,
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Configuration
    )

    Assert-ManagedContainer -Runtime $Runtime
    $expected = Get-ConfigurationFingerprint -Configuration $Configuration
    if ($Runtime.Configuration -ne $expected) {
        throw "Container '$containerName' has different immutable settings. It has been preserved. Run 'tk storage rebuild' only when you intend to replace this exact container."
    }
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
    $configuration = Get-ServiceConfiguration
    $localUrl = "http://127.0.0.1:{0}/" -f $configuration.Port
    $lanUrls = @()

    if ($configuration.BindAddress -ne "127.0.0.1") {
        foreach ($address in @(Get-LanIPv4Addresses)) {
            if (-not [string]::IsNullOrWhiteSpace("$address")) {
                $lanUrls += "http://{0}:{1}/" -f $address, $configuration.Port
            }
        }
    }

    return [pscustomobject]@{
        Local = $localUrl
        Network = [string[]] $lanUrls
        BindAddress = $configuration.BindAddress
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
        if ($urls.BindAddress -eq "127.0.0.1") {
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
            StatusCode = [int] $response.StatusCode
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

function Wait-ServiceHealth {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ContainerId
    )

    Write-Host "Waiting up to $serviceHealthTimeoutSeconds seconds for $containerName..."
    $deadline = (Get-Date).AddSeconds($serviceHealthTimeoutSeconds)
    $lastDisplayState = $null

    do {
        $runtime = Get-ContainerRuntime -Identity $ContainerId
        if ($runtime.Status -eq "missing") {
            throw "$containerName disappeared while readiness was being checked. No other container will be modified."
        }
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

        if ($runtime.Status -eq "running" -and $runtime.Health -eq "healthy") {
            Write-Host "$containerName is ready." -ForegroundColor Green
            return
        }

        if ($runtime.Status -in @("dead", "exited")) {
            Write-Host ""
            try {
                Invoke-Docker -Arguments @("container", "logs", "--tail", "80", $ContainerId) | Out-Host
            }
            catch {
                Write-Host "Could not read container logs: $($_.Exception.Message)" -ForegroundColor Yellow
            }
            throw "$containerName stopped before becoming healthy. The container has been preserved."
        }

        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    throw "$containerName did not become healthy within $serviceHealthTimeoutSeconds seconds. The container has been preserved."
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
        Write-Host "A start action can launch Docker Desktop; status and stop never do." -ForegroundColor DarkGray
        Write-ServiceUrls
        return
    }

    $runtime = Get-ContainerRuntime
    if ($runtime.Status -eq "missing") {
        Write-TuiStatus -Label "Container" -State "Warn" -Detail "missing"
        Write-TuiStatus -Label "HTTP health" -State "Warn" -Detail "Not checked; service is absent"
        Write-ServiceUrls
        return
    }

    if (-not $runtime.Managed) {
        Write-TuiStatus -Label "Container" -State "Warn" -Detail "$($runtime.Status); unmanaged and preserved"
        Write-TuiStatus -Label "HTTP health" -State "Warn" -Detail "Not checked; container is not managed by this tool"
        Write-Host "The existing container and its settings have been preserved for inspection." -ForegroundColor Yellow
        return
    }

    $configuration = Get-ServiceConfiguration
    $expectedFingerprint = Get-ConfigurationFingerprint -Configuration $configuration
    if ($runtime.Configuration -ne $expectedFingerprint) {
        Write-TuiStatus -Label "Container" -State "Warn" -Detail "$($runtime.Status); settings changed"
        Write-TuiStatus -Label "HTTP health" -State "Warn" -Detail "Not checked; container uses earlier settings"
        Write-Host "Run 'tk storage rebuild' to apply the current .env; the container has been preserved." -ForegroundColor Yellow
        return
    }

    if ($runtime.Status -eq "running" -and $runtime.Health -eq "healthy") {
        Write-TuiStatus -Label "Container" -State "Good" -Detail "$($runtime.Status) / $($runtime.Health)"
    }
    elseif ($runtime.Status -in @("created", "exited")) {
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

function Start-StorageService {
    Assert-ServiceWorkspace
    Start-DockerDesktopIfNeeded
    $configuration = Get-ServiceConfiguration
    $runtime = Get-ContainerRuntime
    $activeContainerId = ""

    if ($runtime.Status -eq "missing") {
        Ensure-ContainerImage
        $activeContainerId = New-StorageContainer -Configuration $configuration
        Invoke-Docker -Arguments @("container", "start", $activeContainerId) -Quiet
    }
    else {
        Assert-ContainerConfiguration -Runtime $runtime -Configuration $configuration
        $activeContainerId = $runtime.Id
        if ([string]::IsNullOrWhiteSpace($activeContainerId)) {
            throw "Docker inspection did not return the immutable ID of '$containerName'. The container has been preserved."
        }
        if ($runtime.Status -eq "running") {
            Write-Host "$containerName is already running; preserving it." -ForegroundColor Green
        }
        elseif ($runtime.Status -in @("created", "exited")) {
            Invoke-Docker -Arguments @("container", "start", $activeContainerId) -Quiet
        }
        else {
            throw "Container '$containerName' is in state '$($runtime.Status)'. It has been preserved for inspection."
        }
    }

    Wait-ServiceHealth -ContainerId $activeContainerId
    $urls = Get-ServiceUrls
    Wait-HttpEndpoint -Url ($urls.Local + "healthz")

    Write-Host ""
    Write-Host "Storage and sharing is on." -ForegroundColor Green
    Write-Host "The service remains off after reboot until this tool starts it." -ForegroundColor DarkGray
    Write-ServiceUrls
}

function Rebuild-StorageService {
    Assert-ServiceWorkspace
    Start-DockerDesktopIfNeeded
    $configuration = Get-ServiceConfiguration
    $runtime = Get-ContainerRuntime

    # Fetch the requested base before touching an existing container. A failed
    # pull therefore leaves the old environment completely intact.
    Ensure-ContainerImage -PullLatest

    if ($runtime.Status -ne "missing") {
        Assert-ManagedContainer -Runtime $runtime
        $targetContainerId = $runtime.Id
        if ([string]::IsNullOrWhiteSpace($targetContainerId)) {
            throw "Docker inspection did not return the immutable ID of '$containerName'. The container has been preserved."
        }
        Write-Host "Replacing only inspected container '$containerName' ($($targetContainerId.Substring(0, 12))); host files and Docker volumes are not removed." -ForegroundColor Yellow

        if ($runtime.Status -eq "paused") {
            Invoke-Docker -Arguments @("container", "unpause", $targetContainerId) -Quiet
            Invoke-Docker -Arguments @("container", "stop", "--time", "15", $targetContainerId) -Quiet
        }
        elseif ($runtime.Status -in @("running", "restarting")) {
            Invoke-Docker -Arguments @("container", "stop", "--time", "15", $targetContainerId) -Quiet
        }
        Invoke-Docker -Arguments @("container", "rm", $targetContainerId) -Quiet
    }

    $createdContainerId = New-StorageContainer -Configuration $configuration
    Invoke-Docker -Arguments @("container", "start", $createdContainerId) -Quiet
    Wait-ServiceHealth -ContainerId $createdContainerId

    $urls = Get-ServiceUrls
    Wait-HttpEndpoint -Url ($urls.Local + "healthz")
    Write-Host ""
    Write-Host "Fresh Debian environment created and storage sharing is on." -ForegroundColor Green
    Write-ServiceUrls
}

function Stop-StorageService {
    Assert-ServiceWorkspace
    Write-TuiHeader -Title "Storage + sharing" -Subtitle "Stop service and preserve its container."

    if (-not (Test-DockerDaemon)) {
        Write-Host "Docker is not running, so the service is already off." -ForegroundColor Green
        return
    }

    $runtime = Get-ContainerRuntime
    if ($runtime.Status -eq "missing") {
        Write-Host "The container is absent; nothing was removed or created." -ForegroundColor Green
        return
    }

    Assert-ManagedContainer -Runtime $runtime
    if ($runtime.Status -in @("created", "exited")) {
        Write-Host "The existing container is already stopped and has been preserved." -ForegroundColor Green
        return
    }

    if ($runtime.Status -notin @("running", "paused", "restarting")) {
        throw "Container '$containerName' is in state '$($runtime.Status)' and has been preserved for inspection."
    }

    if ([string]::IsNullOrWhiteSpace($runtime.Id)) {
        throw "Docker inspection did not return the immutable ID of '$containerName'. The container has been preserved."
    }
    if ($runtime.Status -eq "paused") {
        Invoke-Docker -Arguments @("container", "unpause", $runtime.Id) -Quiet
    }
    Invoke-Docker -Arguments @("container", "stop", "--time", "15", $runtime.Id) -Quiet
    Write-Host ""
    Write-Host "Storage and sharing is off. The stopped container and all host files remain intact." -ForegroundColor Green
}

function Invoke-ServiceAction {
    param([string] $RequestedAction)

    switch ($RequestedAction) {
        "status" {
            Assert-ServiceWorkspace
            if (-not (Test-DockerDaemon)) {
                Show-ServiceStatus -DockerUnavailable
            }
            else {
                Show-ServiceStatus
            }
        }
        "stop" {
            Stop-StorageService
        }
        "rebuild" {
            Rebuild-StorageService
        }
        default {
            Start-StorageService
        }
    }
}

function Invoke-ServiceMenu {
    $items = @(
        @{ Label = "Start"; Detail = "Reuse/start the existing container, or create it if absent"; Action = "start" },
        @{ Label = "Recreate"; Detail = "Replace only this container with fresh debian:latest"; Action = "rebuild" },
        @{ Label = "Status"; Detail = "Show container, health, and current URLs"; Action = "status" },
        @{ Label = "Stop"; Detail = "Stop while preserving the container and host files"; Action = "stop" },
        @{ Label = "Back"; Detail = "Return to the toolkit menu"; Action = "back" }
    )

    $choice = Select-TuiItem -Title "Storage + sharing" -Subtitle "Control C:\Work\storage-and-sharing-services." -Items $items -FormatItem { param($item) "{0,-18} {1}" -f $item.Label, $item.Detail }

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
