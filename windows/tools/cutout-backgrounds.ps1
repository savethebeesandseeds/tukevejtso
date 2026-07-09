param(
    [Parameter(Position = 0)]
    [string] $InputPath,

    [Parameter(Position = 1)]
    [string] $OutputPath,

    [string] $Pattern = "*.png",
    [string] $Engine = "birefnet",
    [string] $Device = "auto",
    [int] $InputSize = 1024,
    [int] $AlphaFloor = 24,
    [int] $AlphaCeiling = 250,
    [switch] $Recursive,
    [switch] $CleanOutput,
    [switch] $SaveExtras,
    [switch] $KeepStage
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$containerName = "tukevejtso"
$linuxWorkDir = "/workspace/tukevejtso/linux"
$workspaceImages = Join-Path $repoRoot "linux\workspaces\images"
$stageRoot = Join-Path $workspaceImages "cutout-stage"

function Show-Usage {
    Write-Host "Background cutout"
    Write-Host ""
    Write-Host "Usage:"
    Write-Host "  tk cutout INPUT_FOLDER [OUTPUT_FOLDER] [-CleanOutput] [-SaveExtras]"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host '  tk cutout "C:\Work\images\originals"'
    Write-Host '  tk cutout "C:\Work\images\originals" "C:\Work\images\transparent" -CleanOutput'
    Write-Host ""
    Write-Host "Defaults:"
    Write-Host "  engine=birefnet device=auto input-size=1024 alpha-floor=24 alpha-ceiling=250"
    Write-Host "  staging is cleaned automatically after successful copyback"
}

if ([string]::IsNullOrWhiteSpace($InputPath)) {
    Show-Usage
    exit 0
}

function Get-Slug {
    param([string] $Text)

    $safe = [IO.Path]::GetFileName($Text).ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    $safe = $safe.Trim("-")
    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = "input"
    }

    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $hash = ($md5.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
        return "$safe-$($hash.Substring(0, 8))"
    }
    finally {
        $md5.Dispose()
    }
}

function Remove-DirectorySafe {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string[]] $Forbidden
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) {
        throw "Refusing to remove non-directory path: $Path"
    }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to remove reparse-point directory: $Path"
    }

    $resolved = (Resolve-Path -LiteralPath $Path).Path.TrimEnd("\")
    foreach ($forbiddenPath in $Forbidden) {
        if ($resolved -ieq $forbiddenPath.TrimEnd("\")) {
            throw "Refusing to clean unsafe directory: $Path"
        }
    }

    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Get-RelativePathCompat {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BasePath,

        [Parameter(Mandatory = $true)]
        [string] $TargetPath
    )

    $baseFull = [IO.Path]::GetFullPath($BasePath)
    if (-not $baseFull.EndsWith([IO.Path]::DirectorySeparatorChar)) {
        $baseFull += [IO.Path]::DirectorySeparatorChar
    }
    $targetFull = [IO.Path]::GetFullPath($TargetPath)
    $baseUri = [Uri]::new($baseFull)
    $targetUri = [Uri]::new($targetFull)
    return [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace("/", "\")
}

function Convert-ToLinuxWorkspacePath {
    param([string] $WindowsPath)

    $relative = Get-RelativePathCompat -BasePath (Join-Path $repoRoot "linux") -TargetPath $WindowsPath
    return ($relative -replace '\\', '/')
}

$input = (Resolve-Path -LiteralPath $InputPath).Path
if (-not (Test-Path -LiteralPath $input -PathType Container)) {
    throw "InputPath must be a directory for batch cutout: $InputPath"
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $parent = Split-Path -Parent $input
    $leaf = Split-Path -Leaf $input
    $OutputPath = Join-Path $parent "$leaf - transparent"
}

$inputResolved = (Resolve-Path -LiteralPath $input).Path
$outputFull = [IO.Path]::GetFullPath($OutputPath)
$repoResolved = (Resolve-Path -LiteralPath $repoRoot).Path
$workspaceResolved = (Resolve-Path -LiteralPath $workspaceImages).Path

$forbiddenDeletes = @(
    [IO.Path]::GetPathRoot($outputFull),
    $repoResolved,
    (Join-Path $repoResolved "linux"),
    $workspaceResolved,
    $inputResolved
)

if ($CleanOutput) {
    Remove-DirectorySafe -Path $outputFull -Forbidden $forbiddenDeletes
}
New-Item -ItemType Directory -Path $outputFull -Force | Out-Null

$slug = Get-Slug -Text $inputResolved
$stage = Join-Path $stageRoot $slug
$stageInput = Join-Path $stage "input"
$stageOutput = Join-Path $stage "output"

Remove-DirectorySafe -Path $stage -Forbidden $forbiddenDeletes
New-Item -ItemType Directory -Path $stageInput -Force | Out-Null
New-Item -ItemType Directory -Path $stageOutput -Force | Out-Null

$getChildArgs = @{
    LiteralPath = $inputResolved
    File = $true
    Filter = $Pattern
}
if ($Recursive) {
    $getChildArgs.Recurse = $true
}
$files = @(Get-ChildItem @getChildArgs | Sort-Object FullName)
if ($files.Count -eq 0) {
    throw "No files matched $Pattern under $inputResolved"
}

foreach ($file in $files) {
    $relative = Get-RelativePathCompat -BasePath $inputResolved -TargetPath $file.FullName
    $target = Join-Path $stageInput $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $target -Force
}

Write-Host "Staged $($files.Count) file(s)."
Write-Host "Input:  $inputResolved"
Write-Host "Output: $outputFull"

$prepareArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", (Join-Path $PSScriptRoot "docker-tukevejtso-shell.ps1"),
    "-NoShell"
)
if ($Device -ne "cpu") {
    $prepareArgs += "-RecreateForGpu"
}
& powershell.exe @prepareArgs
if ($LASTEXITCODE -ne 0) {
    throw "Could not prepare the tukevejtso Linux container."
}

$linuxInput = Convert-ToLinuxWorkspacePath -WindowsPath $stageInput
$linuxOutput = Convert-ToLinuxWorkspacePath -WindowsPath $stageOutput

$dockerArgs = @(
    "exec",
    "-w", $linuxWorkDir,
    $containerName,
    "./scripts/images/image_tool.sh",
    "cutout",
    "batch",
    $linuxInput,
    $linuxOutput,
    "--glob", $Pattern,
    "--engine", $Engine,
    "--device", $Device,
    "--input-size", "$InputSize",
    "--alpha-floor", "$AlphaFloor",
    "--alpha-ceiling", "$AlphaCeiling",
    "--clean-output"
)
if ($Recursive) {
    $dockerArgs += "--recursive"
}
if ($SaveExtras) {
    $dockerArgs += "--save-extras"
}

& docker @dockerArgs
if ($LASTEXITCODE -ne 0) {
    throw "Cutout batch failed with exit code $LASTEXITCODE."
}

if ($SaveExtras) {
    Get-ChildItem -LiteralPath $stageOutput -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $outputFull -Recurse -Force
    }
}
else {
    $outputs = @(Get-ChildItem -LiteralPath $stageOutput -File -Filter "*.png" | Sort-Object Name)
    foreach ($file in $outputs) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $outputFull $file.Name) -Force
    }
}

Write-Host ""
Write-Host "Transparent PNG output:"
Write-Host $outputFull

if (-not $KeepStage) {
    Remove-DirectorySafe -Path $stage -Forbidden $forbiddenDeletes
}
