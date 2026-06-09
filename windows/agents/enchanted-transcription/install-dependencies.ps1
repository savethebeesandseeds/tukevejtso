param(
    [switch]$SkipCuda,
    [switch]$SkipVisualStudio,
    [switch]$SkipRust,
    [switch]$SkipCMake,
    [switch]$SkipNinja,
    [switch]$SkipLLVM
)

$ErrorActionPreference = "Stop"

function Assert-Winget {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget was not found. Install App Installer from Microsoft Store or install dependencies manually."
    }
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Version,
        [string]$Override,
        [string]$DisplayName = $Id
    )

    $args = @(
        "install",
        "--id", $Id,
        "--exact",
        "--accept-source-agreements",
        "--accept-package-agreements",
        "--disable-interactivity"
    )

    if ($Version) {
        $args += @("--version", $Version)
    }

    if ($Override) {
        $args += @("--override", $Override)
    }
    else {
        $args += "--silent"
    }

    Write-Host ""
    Write-Host "==> Installing $DisplayName"
    & winget @args
    if ($LASTEXITCODE -ne 0) {
        throw "winget install failed for $DisplayName with exit code $LASTEXITCODE."
    }
}

function Show-CommandVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @("--version")
    )

    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Warning "$Command was not found on PATH in this shell. Open a new terminal if it was just installed."
        return
    }

    Write-Host ""
    Write-Host "==> $Command"
    & $cmd.Source @Arguments
}

function Show-VisualStudioBuildTools {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) {
        Write-Warning "Visual Studio vswhere.exe was not found."
        return
    }

    $installPath = & $vswhere -all -products * -requires Microsoft.VisualStudio.Workload.VCTools -property installationPath
    if (-not $installPath) {
        Write-Warning "Visual Studio Build Tools with the C++ workload was not found."
        return
    }

    Write-Host ""
    Write-Host "==> Visual Studio C++ Build Tools"
    Write-Host $installPath

    $cl = Get-ChildItem -LiteralPath (Join-Path $installPath "VC\Tools\MSVC") -Recurse -Filter cl.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*\bin\Hostx64\x64\cl.exe" } |
        Select-Object -First 1
    if ($cl) {
        Write-Host $cl.FullName
    }
}

function Update-CurrentProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = (@($machinePath, $userPath) | Where-Object { $_ }) -join ";"

    $llvmBin = "C:\Program Files\LLVM\bin"
    if (Test-Path -LiteralPath $llvmBin) {
        $env:Path = "$llvmBin;$env:Path"
        $env:LIBCLANG_PATH = $llvmBin
    }
}

Assert-Winget

if (-not $SkipRust) {
    Install-WingetPackage -Id "Rustlang.Rustup" -DisplayName "Rustup / Rust toolchain"
}

if (-not $SkipVisualStudio) {
    Install-WingetPackage `
        -Id "Microsoft.VisualStudio.2022.BuildTools" `
        -DisplayName "Visual Studio Build Tools 2022 with C++ workload" `
        -Override "--wait --quiet --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
}

if (-not $SkipCMake) {
    Install-WingetPackage -Id "Kitware.CMake" -DisplayName "CMake"
}

if (-not $SkipNinja) {
    Install-WingetPackage -Id "Ninja-build.Ninja" -DisplayName "Ninja"
}

if (-not $SkipLLVM) {
    Install-WingetPackage -Id "LLVM.LLVM" -DisplayName "LLVM / libclang for Rust bindgen"
}

if (-not $SkipCuda) {
    Install-WingetPackage -Id "Nvidia.CUDA" -Version "12.8" -DisplayName "NVIDIA CUDA Toolkit 12.8"
}

Update-CurrentProcessPath

Write-Host ""
Write-Host "==> Verification"
Show-VisualStudioBuildTools
Show-CommandVersion -Command "rustc"
Show-CommandVersion -Command "cargo"
Show-CommandVersion -Command "cmake"
Show-CommandVersion -Command "ninja"
Show-CommandVersion -Command "clang"
Show-CommandVersion -Command "nvidia-smi"
Show-CommandVersion -Command "nvcc"

Write-Host ""
Write-Host "Done. Open a new terminal before building Rust/CUDA projects so PATH changes are loaded."
