param(
    [ValidateSet("local", "tunnel", "status", "verify", "stop", "stop-tunnel")]
    [string] $Action
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ui.ps1")

$caatuuRoot = "C:\Work\caatuu"
$composeFile = Join-Path $caatuuRoot "compose.yaml"
$tunnelTokenFile = Join-Path $caatuuRoot "secrets\cloudflared-token"
$dockerDesktopTimeoutSeconds = 90
$serviceHealthTimeoutSeconds = 120
$localHttpTimeoutSeconds = 45
$publicHttpTimeoutSeconds = 75
$localUrl = "http://127.0.0.1:8765/"
$publicUrl = "https://caatuu.waajacu.com/"

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
    if ($null -eq $dockerDesktopProcess -and -not (Test-Path -LiteralPath $dockerDesktopPath)) {
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

function Invoke-CaatuuCompose {
    param([string[]] $Arguments)

    Write-Host ("docker compose {0}" -f ($Arguments -join " ")) -ForegroundColor DarkGray
    & docker compose --project-directory $caatuuRoot --file $composeFile @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose failed with exit code $LASTEXITCODE."
    }
}

function Get-CaatuuContainerState {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ContainerName
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $state = (& docker inspect --format "{{.State.Status}}" $ContainerName 2>$null)
        if ($LASTEXITCODE -ne 0) {
            return "missing"
        }

        return "$state".Trim()
    }
    catch {
        return "missing"
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Wait-CaatuuServiceHealth {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ContainerName
    )

    Write-Host "Waiting up to $serviceHealthTimeoutSeconds seconds for $ContainerName..."
    $deadline = (Get-Date).AddSeconds($serviceHealthTimeoutSeconds)
    $lastDisplayState = $null
    do {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $stateLine = (& docker inspect --format "{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" $ContainerName 2>$null)
            $inspectSucceeded = ($LASTEXITCODE -eq 0)
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($inspectSucceeded) {
            $stateParts = "$stateLine".Trim().Split("|", 2)
            $containerStatus = $stateParts[0]
            $healthStatus = if ($stateParts.Count -gt 1) { $stateParts[1] } else { "none" }
            $displayState = if ($healthStatus -eq "none") {
                $containerStatus
            }
            else {
                "$containerStatus / $healthStatus"
            }

            if ($displayState -ne $lastDisplayState) {
                Write-Host "$ContainerName state: $displayState" -ForegroundColor DarkGray
                $lastDisplayState = $displayState
            }

            if ($containerStatus -eq "running" -and $healthStatus -in @("healthy", "none")) {
                Write-Host "$ContainerName is ready." -ForegroundColor Green
                return
            }

            if ($containerStatus -in @("exited", "dead")) {
                throw "$ContainerName entered state '$containerStatus'. Run 'docker logs $ContainerName' for details."
            }
        }

        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    $lastStateText = if ([string]::IsNullOrWhiteSpace($lastDisplayState)) { "not found" } else { $lastDisplayState }
    throw "$ContainerName did not become ready within $serviceHealthTimeoutSeconds seconds. Last state: $lastStateText. Run 'docker logs $ContainerName' for details."
}

function Get-HttpEndpointResult {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Url,
        [ValidateRange(1, 60)]
        [int] $TimeoutSeconds = 12
    )

    try {
        $response = Invoke-WebRequest `
            -Uri $Url `
            -UseBasicParsing `
            -MaximumRedirection 5 `
            -TimeoutSec $TimeoutSeconds

        return [pscustomobject] @{
            Success = ([int] $response.StatusCode -ge 200 -and [int] $response.StatusCode -lt 400)
            StatusCode = [int] $response.StatusCode
            Detail = $response.StatusDescription
        }
    }
    catch {
        $statusCode = $null
        if ($null -ne $_.Exception.Response) {
            try {
                $statusCode = [int] $_.Exception.Response.StatusCode
            }
            catch {
                $statusCode = $null
            }
        }

        return [pscustomobject] @{
            Success = $false
            StatusCode = $statusCode
            Detail = $_.Exception.Message
        }
    }
}

function Format-HttpEndpointFailure {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Result
    )

    if ($null -ne $Result.StatusCode) {
        return "HTTP $($Result.StatusCode): $($Result.Detail)"
    }

    return $Result.Detail
}

function Wait-HttpEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Label,
        [Parameter(Mandatory = $true)]
        [string] $Url,
        [Parameter(Mandatory = $true)]
        [int] $TimeoutSeconds
    )

    Write-Host "Waiting up to $TimeoutSeconds seconds for $Label..."
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastResult = $null
    do {
        $remaining = [Math]::Max(1, [Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds))
        $requestTimeout = [Math]::Min(8, $remaining)
        $lastResult = Get-HttpEndpointResult -Url $Url -TimeoutSeconds $requestTimeout
        if ($lastResult.Success) {
            Write-Host "$Label is reachable (HTTP $($lastResult.StatusCode)): $Url" -ForegroundColor Green
            return
        }

        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    $failure = Format-HttpEndpointFailure -Result $lastResult
    throw "$Label did not become reachable within $TimeoutSeconds seconds. Last result: $failure"
}

function Write-HttpEndpointStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Label,
        [Parameter(Mandatory = $true)]
        [string] $Url
    )

    $result = Get-HttpEndpointResult -Url $Url
    if ($result.Success) {
        Write-Host ("{0,-8} HTTP {1}  {2}" -f $Label, $result.StatusCode, $Url) -ForegroundColor Green
        return $true
    }

    $failure = Format-HttpEndpointFailure -Result $result
    Write-Host ("{0,-8} unavailable  {1}" -f $Label, $failure) -ForegroundColor Yellow
    return $false
}

function Show-CaatuuStatus {
    param(
        [switch] $CheckEndpoints,
        [switch] $DockerUnavailable
    )

    Write-TuiHeader -Title "Caatuu" -Subtitle "Runtime server and shared Cloudflare tunnel."
    if ($DockerUnavailable) {
        Write-Host "Docker engine is unavailable; container state cannot be read." -ForegroundColor Yellow
        Write-Host "A start action will launch Docker Desktop automatically." -ForegroundColor DarkGray
    }
    else {
        Invoke-CaatuuCompose -Arguments @("ps", "--all")
    }
    Write-Host ""
    Write-Host "Local:  $localUrl" -ForegroundColor Cyan
    Write-Host "Public: $publicUrl" -ForegroundColor Cyan

    if (-not $CheckEndpoints) {
        return
    }

    Write-Host ""
    Write-Host "Endpoint checks" -ForegroundColor DarkGray
    [void] (Write-HttpEndpointStatus -Label "Local" -Url $localUrl)

    if ($DockerUnavailable) {
        [void] (Write-HttpEndpointStatus -Label "Public" -Url $publicUrl)
    }
    elseif ((Get-CaatuuContainerState -ContainerName "caatuu-tunnel") -eq "running") {
        [void] (Write-HttpEndpointStatus -Label "Public" -Url $publicUrl)
    }
    else {
        Write-Host "Public   skipped; caatuu-tunnel is not running." -ForegroundColor DarkGray
    }
}

function Invoke-CaatuuAction {
    param([string] $RequestedAction)

    if (-not (Test-Path -LiteralPath $composeFile -PathType Leaf)) {
        throw "Caatuu workspace was not found at $caatuuRoot."
    }

    if ($RequestedAction -in @("local", "tunnel")) {
        Start-DockerDesktopIfNeeded
    }
    elseif (-not (Test-DockerDaemon)) {
        if ($RequestedAction -eq "status") {
            Show-CaatuuStatus -CheckEndpoints -DockerUnavailable
            return
        }

        if ($RequestedAction -eq "verify") {
            throw "Docker is not running, so Caatuu cannot be verified. Start it with 'tk caatuu local' or 'tk caatuu tunnel'."
        }

        Write-TuiHeader -Title "Caatuu" -Subtitle "Runtime server and shared Cloudflare tunnel."
        Write-Host "Docker is not running; there is nothing to stop or inspect." -ForegroundColor Yellow
        return
    }

    # Caatuu's current sideload installs use the explicitly published debug
    # channel until a separately signed stable release lineage is introduced.
    $env:CAATUU_ENABLE_ANDROID_DEBUG_DOWNLOADS = "1"

    switch ($RequestedAction) {
        "local" {
            Write-Host "Starting the Caatuu server without changing the shared tunnel..."
            Invoke-CaatuuCompose -Arguments @("up", "-d", "caatuu")
            Wait-CaatuuServiceHealth -ContainerName "caatuu"
            Wait-HttpEndpoint -Label "Caatuu local server" -Url $localUrl -TimeoutSeconds $localHttpTimeoutSeconds
        }
        "tunnel" {
            if (-not (Test-Path -LiteralPath $tunnelTokenFile -PathType Leaf) -or
                (Get-Item -LiteralPath $tunnelTokenFile).Length -eq 0) {
                throw "Cloudflare tunnel token is missing or empty: $tunnelTokenFile"
            }

            Write-Host "Starting Caatuu with the Cloudflare tunnel..."
            Invoke-CaatuuCompose -Arguments @("up", "-d", "caatuu")
            Wait-CaatuuServiceHealth -ContainerName "caatuu"
            Invoke-CaatuuCompose -Arguments @("--profile", "tunnel", "up", "-d", "caatuu-tunnel")
            Wait-CaatuuServiceHealth -ContainerName "caatuu-tunnel"
            Wait-HttpEndpoint -Label "Caatuu local server" -Url $localUrl -TimeoutSeconds $localHttpTimeoutSeconds
            Wait-HttpEndpoint -Label "Caatuu public site" -Url $publicUrl -TimeoutSeconds $publicHttpTimeoutSeconds
        }
        "status" {
            Show-CaatuuStatus -CheckEndpoints
            return
        }
        "verify" {
            Wait-HttpEndpoint -Label "Caatuu local server" -Url $localUrl -TimeoutSeconds $localHttpTimeoutSeconds
            if ((Get-CaatuuContainerState -ContainerName "caatuu-tunnel") -eq "running") {
                Wait-HttpEndpoint -Label "Caatuu public site" -Url $publicUrl -TimeoutSeconds $publicHttpTimeoutSeconds
            }
            else {
                Write-Host "Public check skipped because caatuu-tunnel is not running." -ForegroundColor DarkGray
            }
        }
        "stop" {
            Write-Host "Stopping the Caatuu server. The shared Minerals tunnel will stay running..."
            Invoke-CaatuuCompose -Arguments @("stop", "caatuu")
        }
        "stop-tunnel" {
            Write-Warning "Stopping the shared tunnel also takes minerals.waajacu.com offline."
            Invoke-CaatuuCompose -Arguments @("--profile", "tunnel", "stop", "caatuu-tunnel")
        }
        default {
            throw "Unknown Caatuu action: $RequestedAction"
        }
    }

    Write-Host ""
    Show-CaatuuStatus
}

function Invoke-CaatuuMenu {
    $items = @(
        @{ Label = "Start server"; Detail = "Port 8765; leave the shared tunnel as-is"; Action = "local" },
        @{ Label = "Start + tunnel"; Detail = "Caatuu public; preserve Minerals forwarding"; Action = "tunnel" },
        @{ Label = "Status"; Detail = "Show containers and check reachable endpoints"; Action = "status" },
        @{ Label = "Verify"; Detail = "Wait for local and active public endpoints"; Action = "verify" },
        @{ Label = "Stop Caatuu"; Detail = "Keep the shared Minerals tunnel running"; Action = "stop" },
        @{ Label = "Stop shared tunnel"; Detail = "Also takes Minerals public ingress offline"; Action = "stop-tunnel" },
        @{ Label = "Back"; Detail = "Return to the toolkit menu"; Action = "back" }
    )

    $choice = Select-TuiItem `
        -Title "Caatuu" `
        -Subtitle "Choose how to run the language-learning server." `
        -Items $items `
        -FormatItem { param($item) "{0,-17} {1}" -f $item.Label, $item.Detail }

    if ($null -eq $choice -or $choice.Action -eq "back") {
        return
    }

    Clear-Host
    Invoke-CaatuuAction -RequestedAction $choice.Action
}

if ([string]::IsNullOrWhiteSpace($Action)) {
    Invoke-CaatuuMenu
}
else {
    Invoke-CaatuuAction -RequestedAction $Action
}
