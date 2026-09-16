param(
    [switch] $Rebuild,
    [switch] $Recreate,
    [switch] $RecreateForGpu,
    [switch] $CpuOnly,
    [switch] $NoShell
)

$ErrorActionPreference = "Stop"

$containerName = "tukevejtso"
$containerImage = "debian:latest"
$volumeName = "tukevejtso-cutout-venvs"
$managedLabel = "org.tukevejtso.linux.managed"
$configurationLabel = "org.tukevejtso.linux.configuration"
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$setupFile = Join-Path $repoRoot "setup.sh"
$containerRepoRoot = "/workspace/tukevejtso"
$containerWorkDir = "/workspace/tukevejtso/linux"
$containerVolumeTarget = "/opt/tukevejtso-venvs"
$readyMarker = "/var/lib/tukevejtso/setup-complete"
$dockerDesktopTimeoutSeconds = 90
$setupTimeoutSeconds = 1800
$bootstrapCommand = "if [ ! -f $readyMarker ]; then bash $containerRepoRoot/setup.sh && mkdir -p /var/lib/tukevejtso && touch $readyMarker; fi && exec sleep infinity"
$dockerTerminalEnv = @(
    "--env", "TERM=xterm-256color",
    "--env", "LANG=C.UTF-8",
    "--env", "LC_ALL=C.UTF-8",
    "--env", "COLORTERM=truecolor",
    "--env", "FORCE_COLOR=1"
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
        # Best effort: Docker environment variables still configure the container.
    }
}

function Test-DockerCommand {
    if ($null -eq (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker was not found on PATH. Install Docker Desktop or add docker.exe to PATH."
    }
}

function Invoke-Docker {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments,

        [switch] $Quiet
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $hasNativePreference = Test-Path Variable:PSNativeCommandUseErrorActionPreference
    if ($hasNativePreference) {
        $previousNativePreference = $PSNativeCommandUseErrorActionPreference
    }

    $output = @()
    $exitCode = $null
    $invocationError = $null
    try {
        $ErrorActionPreference = "Continue"
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $false
        }

        $output = @(& docker @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
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
        throw "Could not run 'docker $($Arguments -join ' ')': $($invocationError.Message)"
    }

    if ($exitCode -ne 0) {
        $detail = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = "No diagnostic output was returned."
        }
        throw "docker $($Arguments -join ' ') failed with exit code $exitCode. $detail"
    }

    if (-not $Quiet) {
        return $output
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
    if (-not (Test-Path -LiteralPath $dockerDesktopPath)) {
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

function Assert-Workspace {
    if (-not (Test-Path -LiteralPath $setupFile -PathType Leaf)) {
        throw "Dependency setup file not found: $setupFile"
    }
}

function Test-ContainerImage {
    try {
        Invoke-Docker -Arguments @("image", "inspect", $containerImage) -Quiet
        return $true
    }
    catch {
        return $false
    }
}

function Assert-LocalContainerImage {
    if (-not (Test-ContainerImage)) {
        throw "Required base image '$containerImage' is not available locally. It has not been pulled automatically; obtain explicit approval before downloading it."
    }
}

function Get-PersistentVolume {
    $previousErrorActionPreference = $ErrorActionPreference
    $hasNativePreference = Test-Path Variable:PSNativeCommandUseErrorActionPreference
    if ($hasNativePreference) {
        $previousNativePreference = $PSNativeCommandUseErrorActionPreference
    }

    $output = @()
    $exitCode = $null
    try {
        $ErrorActionPreference = "Continue"
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $false
        }
        $output = @(& docker volume inspect $volumeName 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $previousNativePreference
        }
    }

    if ($exitCode -ne 0) {
        throw "Required existing volume '$volumeName' was not found. No empty replacement will be created automatically. Stop and confirm the recovery path before continuing."
    }

    try {
        $parsed = (($output | ForEach-Object { "$_" }) -join [Environment]::NewLine) | ConvertFrom-Json
        $volume = @($parsed)[0]
    }
    catch {
        throw "Docker returned invalid volume inspection data for '$volumeName': $($_.Exception.Message)"
    }

    if ($null -eq $volume -or "$($volume.Name)" -ne $volumeName -or [string]::IsNullOrWhiteSpace("$($volume.CreatedAt)")) {
        throw "Docker returned incomplete or mismatched inspection data for volume '$volumeName'."
    }

    return [pscustomobject]@{
        Name = "$($volume.Name)"
        CreatedAt = "$($volume.CreatedAt)"
        Driver = "$($volume.Driver)"
        Mountpoint = "$($volume.Mountpoint)"
    }
}

function Assert-VolumeIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Expected
    )

    $current = Get-PersistentVolume
    if ($current.Name -ne $Expected.Name -or
        $current.CreatedAt -ne $Expected.CreatedAt -or
        $current.Driver -ne $Expected.Driver -or
        $current.Mountpoint -ne $Expected.Mountpoint) {
        throw "Persistent volume '$volumeName' changed identity during recovery. All Docker objects have been preserved for inspection."
    }
}

function Test-DockerGpuSupportReadOnly {
    if ($CpuOnly) {
        return $false
    }

    if ($null -eq (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
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

        & nvidia-smi -L *> $null
        if ($LASTEXITCODE -ne 0) {
            return $false
        }

        $runtimeJson = (& docker info --format "{{json .Runtimes}}" 2>$null) -join ""
        if ($LASTEXITCODE -ne 0) {
            return $false
        }

        return ($runtimeJson -match '"nvidia"')
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

function Get-ConfigurationFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Volume
    )

    $setupHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $setupFile).Hash.ToLowerInvariant()
    $payload = @(
        $containerImage,
        $repoRoot.ToLowerInvariant(),
        $containerRepoRoot,
        $containerWorkDir,
        $Volume.Name,
        $Volume.CreatedAt,
        $containerVolumeTarget,
        $bootstrapCommand,
        $setupHash
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

    $output = @()
    $exitCode = $null
    try {
        $ErrorActionPreference = "Continue"
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $false
        }
        $output = @(& docker container inspect $Identity 2>&1)
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
        if ($detail -match '(?i)\bno such (?:container|object)\b') {
            return [pscustomobject]@{
                Status = "missing"
                Managed = $false
                Configuration = ""
                Image = ""
                Id = ""
                HasGpu = $false
                Mounts = @()
                WorkingDir = ""
                Command = @()
            }
        }
        throw "Could not inspect container '$Identity'. Docker exited with code $exitCode. $detail"
    }

    try {
        $parsed = (($output | ForEach-Object { "$_" }) -join [Environment]::NewLine) | ConvertFrom-Json
        $inspection = @($parsed)[0]
    }
    catch {
        throw "Docker returned invalid inspection JSON for '$Identity': $($_.Exception.Message)"
    }

    if ($null -eq $inspection -or $null -eq $inspection.State -or $null -eq $inspection.Config) {
        throw "Docker returned incomplete inspection data for '$Identity'."
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

    $deviceRequestsJson = ""
    if ($null -ne $inspection.HostConfig.DeviceRequests) {
        $deviceRequestsJson = $inspection.HostConfig.DeviceRequests | ConvertTo-Json -Compress -Depth 8
    }

    return [pscustomobject]@{
        Status = "$($inspection.State.Status)"
        Managed = ($managedValue -eq "true")
        Configuration = $configurationValue
        Image = "$($inspection.Config.Image)"
        Id = "$($inspection.Id)"
        HasGpu = ($deviceRequestsJson -match '(?i)gpu|nvidia')
        Mounts = @($inspection.Mounts)
        WorkingDir = "$($inspection.Config.WorkingDir)"
        Command = @($inspection.Config.Cmd)
    }
}

function Assert-ManagedContainer {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Runtime
    )

    if (-not $Runtime.Managed) {
        throw "Container '$containerName' exists but is not labeled as managed by this launcher. It has been preserved. Do not remove it without inspecting and approving that exact deletion."
    }
    if ([string]::IsNullOrWhiteSpace($Runtime.Id)) {
        throw "Docker did not return the immutable ID of '$containerName'. It has been preserved."
    }
}

function Assert-ContainerConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Runtime,

        [Parameter(Mandatory = $true)]
        [string] $ExpectedFingerprint
    )

    Assert-ManagedContainer -Runtime $Runtime
    if ($Runtime.Configuration -ne $ExpectedFingerprint) {
        throw "Container '$containerName' has different immutable settings. It has been preserved. Use an explicit recreate only when you intend to replace this exact managed container."
    }
    if ($Runtime.Image -ne $containerImage -or $Runtime.WorkingDir -ne $containerWorkDir) {
        throw "Container '$containerName' does not match the expected image or working directory. It has been preserved."
    }

    $repoMount = @($Runtime.Mounts | Where-Object { "$($_.Destination)" -eq $containerRepoRoot })
    $volumeMount = @($Runtime.Mounts | Where-Object { "$($_.Destination)" -eq $containerVolumeTarget })
    if ($repoMount.Count -ne 1 -or "$($repoMount[0].Type)" -ne "bind" -or $repoMount[0].RW -ne $true) {
        throw "Container '$containerName' does not have the expected read/write repository bind mount. It has been preserved."
    }
    if ($volumeMount.Count -ne 1 -or "$($volumeMount[0].Type)" -ne "volume" -or "$($volumeMount[0].Name)" -ne $volumeName -or $volumeMount[0].RW -ne $true) {
        throw "Container '$containerName' is not attached to the expected persistent volume. It has been preserved."
    }
}

function New-TukevejtsoContainer {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Volume,

        [Parameter(Mandatory = $true)]
        [string] $Fingerprint,

        [Parameter(Mandatory = $true)]
        [bool] $EnableGpu
    )

    Assert-VolumeIdentity -Expected $Volume

    $arguments = @(
        "container", "create",
        "--name", $containerName,
        "--hostname", $containerName,
        "--label", "$managedLabel=true",
        "--label", "$configurationLabel=$Fingerprint",
        "--interactive",
        "--tty",
        "--restart", "no"
    )
    $arguments += $dockerTerminalEnv
    $arguments += @(
        "--mount", "type=bind,source=$repoRoot,target=$containerRepoRoot",
        "--mount", "type=volume,source=$volumeName,target=$containerVolumeTarget,volume-nocopy",
        "--workdir", $containerWorkDir
    )
    if ($EnableGpu) {
        $arguments += @("--gpus", "all")
    }
    $arguments += @($containerImage, "bash", "-lc", $bootstrapCommand)

    Write-Host "Creating one missing managed container; no existing Docker object will be removed." -ForegroundColor Yellow
    Write-Host "  Container: $containerName"
    Write-Host "  Base image: $containerImage (already local)"
    Write-Host "  Command: dependency-only setup.sh once, then sleep infinity"
    Write-Host "  Repository: $repoRoot -> $containerRepoRoot (read/write)"
    Write-Host "  Existing volume: $volumeName [$($Volume.CreatedAt)] -> $containerVolumeTarget (read/write, no copy)"
    Write-Host "  Ports: none; restart policy: no; GPU access: $EnableGpu"

    $createOutput = @(Invoke-Docker -Arguments $arguments)
    $createdId = $createOutput |
        ForEach-Object { "$($_)".Trim() } |
        Where-Object { $_ -match '^[0-9a-f]{12,64}$' } |
        Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($createdId)) {
        throw "Docker did not return the ID of the newly created '$containerName' container. Nothing will be removed automatically."
    }

    Assert-VolumeIdentity -Expected $Volume
    $runtime = Get-ContainerRuntime -Identity $createdId
    if ($runtime.Id -ne $createdId) {
        throw "Docker inspection did not return the newly created immutable ID. The container and volume have been preserved for inspection."
    }
    Assert-ContainerConfiguration -Runtime $runtime -ExpectedFingerprint $Fingerprint
    if ($EnableGpu -and -not $runtime.HasGpu) {
        throw "The new container does not show the requested GPU device access. It has been preserved for inspection."
    }

    Write-Host "Created only container '$containerName' ($($createdId.Substring(0, 12))) from already-local $containerImage." -ForegroundColor Green
    Write-Host "Reattached existing volume '$volumeName' created $($Volume.CreatedAt); it was not copied or reinitialized." -ForegroundColor Green
    return "$createdId"
}

function Remove-ExplicitlySelectedContainer {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Runtime
    )

    Assert-ManagedContainer -Runtime $Runtime
    $targetId = $Runtime.Id
    Write-Host "Replacing only inspected managed container '$containerName' ($($targetId.Substring(0, 12))). The named volume and host files will not be removed." -ForegroundColor Yellow

    if ($Runtime.Status -eq "paused") {
        Invoke-Docker -Arguments @("container", "unpause", $targetId) -Quiet
        Invoke-Docker -Arguments @("container", "stop", "--time", "15", $targetId) -Quiet
    }
    elseif ($Runtime.Status -in @("running", "restarting")) {
        Invoke-Docker -Arguments @("container", "stop", "--time", "15", $targetId) -Quiet
    }
    elseif ($Runtime.Status -notin @("created", "exited", "dead")) {
        throw "Container '$containerName' is in state '$($Runtime.Status)' and has been preserved for inspection."
    }

    Invoke-Docker -Arguments @("container", "rm", $targetId) -Quiet
}

function Test-SetupReady {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ContainerId
    )

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
        & docker container exec $ContainerId bash -lc "test -f $readyMarker" *> $null
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

function Wait-TukevejtsoSetup {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ContainerId
    )

    Write-Host "Waiting for dependency-only setup.sh to finish; the persistent cutout volume is not modified by setup.sh..."
    $deadline = (Get-Date).AddSeconds($setupTimeoutSeconds)
    $lastStatus = ""
    do {
        $runtime = Get-ContainerRuntime -Identity $ContainerId
        if ($runtime.Status -ne $lastStatus) {
            Write-Host "$containerName state: $($runtime.Status)" -ForegroundColor DarkGray
            $lastStatus = $runtime.Status
        }
        if ($runtime.Status -eq "running" -and (Test-SetupReady -ContainerId $ContainerId)) {
            Write-Host "$containerName dependency setup is ready." -ForegroundColor Green
            return
        }
        if ($runtime.Status -in @("exited", "dead")) {
            $logs = @(Invoke-Docker -Arguments @("container", "logs", "--tail", "80", $ContainerId))
            $detail = ($logs | ForEach-Object { "$_" }) -join [Environment]::NewLine
            throw "$containerName stopped before setup completed. It and '$volumeName' were preserved. Recent logs: $detail"
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    throw "$containerName did not complete setup within $setupTimeoutSeconds seconds. It and '$volumeName' were preserved for inspection."
}

function Start-TukevejtsoContainer {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Runtime
    )

    if ($Runtime.Status -eq "running") {
        Write-Host "$containerName is already running; preserving it." -ForegroundColor Green
    }
    elseif ($Runtime.Status -in @("created", "exited")) {
        Invoke-Docker -Arguments @("container", "start", $Runtime.Id) -Quiet
    }
    else {
        throw "Container '$containerName' is in state '$($Runtime.Status)' and has been preserved for inspection."
    }

    Wait-TukevejtsoSetup -ContainerId $Runtime.Id
}

if ($CpuOnly -and $RecreateForGpu) {
    throw "-CpuOnly and -RecreateForGpu cannot be used together."
}
if ($Rebuild) {
    Write-Host "-Rebuild is retained as an explicit compatibility alias for replacing only the managed '$containerName' container; no image build is performed." -ForegroundColor Yellow
    $Recreate = $true
}

Assert-Workspace
Test-DockerCommand
Start-DockerDesktopIfNeeded
Set-ConsoleUtf8IfPossible
Assert-LocalContainerImage
$preservedVolume = Get-PersistentVolume
$fingerprint = Get-ConfigurationFingerprint -Volume $preservedVolume
$useGpu = Test-DockerGpuSupportReadOnly
if ($useGpu) {
    Write-Host "NVIDIA GPU support detected through read-only host and Docker runtime inspection."
}
else {
    Write-Host "GPU support was not selected; using a CPU container."
}

$runtime = Get-ContainerRuntime
if ($RecreateForGpu) {
    if (-not $useGpu) {
        throw "-RecreateForGpu was requested, but read-only checks did not find both a host NVIDIA GPU and Docker's NVIDIA runtime. Nothing was removed."
    }
    if ($runtime.Status -ne "missing" -and -not $runtime.HasGpu) {
        $Recreate = $true
    }
}

if ($Recreate -and $runtime.Status -ne "missing") {
    Assert-VolumeIdentity -Expected $preservedVolume
    Remove-ExplicitlySelectedContainer -Runtime $runtime
    Assert-VolumeIdentity -Expected $preservedVolume
    $runtime = Get-ContainerRuntime
}

if ($runtime.Status -eq "missing") {
    $createdId = New-TukevejtsoContainer -Volume $preservedVolume -Fingerprint $fingerprint -EnableGpu $useGpu
    $runtime = Get-ContainerRuntime -Identity $createdId
}
else {
    Assert-ContainerConfiguration -Runtime $runtime -ExpectedFingerprint $fingerprint
    if ($useGpu -and -not $runtime.HasGpu) {
        Write-Host "$containerName exists without GPU access and has been preserved. Use explicit -RecreateForGpu if you choose to replace only this managed container." -ForegroundColor Yellow
    }
}

Start-TukevejtsoContainer -Runtime $runtime
Assert-VolumeIdentity -Expected $preservedVolume

if ($NoShell) {
    Write-Host "$containerName is ready."
    exit 0
}

Write-Host "Opening /bin/bash in $containerName..."
& docker container exec -it @dockerTerminalEnv $runtime.Id /bin/bash
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "/bin/bash failed. Trying /bin/sh..."
    & docker container exec -it @dockerTerminalEnv $runtime.Id /bin/sh
    if ($LASTEXITCODE -ne 0) {
        throw "Could not open /bin/bash or /bin/sh in $containerName. Last exit code: $LASTEXITCODE."
    }
}
