param(
    [ValidateSet("tiny", "base", "small", "medium", "tiny.en", "base.en", "small.en", "medium.en")]
    [string]$Model = "small",
    [ValidateRange(5, 180)]
    [int]$FadeSeconds = 70,
    [switch]$Transparency,
    [switch]$NoTransparencyPrompt,
    [ValidateRange(5, 95)]
    [int]$TransparencyOpacity = 45,
    [ValidateSet("Clear", "Acrylic")]
    [string]$TransparencyBackground = "Clear",
    [string]$AgentModel = "gpt-5.4-nano",
    [switch]$NoAgent,
    [switch]$SetupOpenAiKey,
    [switch]$Cpu
)

$ErrorActionPreference = "Stop"

$AgentRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsRoot = Split-Path -Parent (Split-Path -Parent $AgentRoot)
$ModelsDir = Join-Path $AgentRoot "models"
$TempDir = Join-Path $AgentRoot ".temp"
$TransparencyTool = Join-Path $WindowsRoot "tools\terminal-transparency.ps1"
$OpenAiKeyTool = Join-Path $WindowsRoot "tools\openai-api-key.ps1"
$OpenAiKeyPath = Join-Path $env:APPDATA "tukevejtso\secrets\openai-api-key.dpapi"

$transparencyOpacityProvided = $PSBoundParameters.ContainsKey("TransparencyOpacity")
$transparencyBackgroundProvided = $PSBoundParameters.ContainsKey("TransparencyBackground")

function Update-CurrentProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = (@($machinePath, $userPath) | Where-Object { $_ }) -join ";"
}

function Import-VisualStudioBuildEnvironment {
    $vcvars = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
    if (-not (Test-Path -LiteralPath $vcvars)) {
        Write-Warning "Visual Studio vcvars64.bat was not found. Cargo may fail to compile native dependencies."
        return
    }

    cmd.exe /d /s /c "`"$vcvars`" >nul && set" | ForEach-Object {
        if ($_ -match "^(.*?)=(.*)$") {
            Set-Item -Path "env:$($matches[1])" -Value $matches[2]
        }
    }
}

function Get-CargoPath {
    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
    if ($cargo) {
        return $cargo.Source
    }

    $fallback = Join-Path $env:USERPROFILE ".cargo\bin\cargo.exe"
    if (Test-Path -LiteralPath $fallback) {
        return $fallback
    }

    throw "cargo.exe was not found. Run install-dependencies.ps1 first."
}

function Resolve-Model {
    param([string]$Name)

    $models = @{
        "tiny" = @{
            File = "ggml-tiny.bin"
            Url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin"
        }
        "base" = @{
            File = "ggml-base.bin"
            Url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
        }
        "small" = @{
            File = "ggml-small.bin"
            Url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
        }
        "medium" = @{
            File = "ggml-medium.bin"
            Url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin"
        }
        "tiny.en" = @{
            File = "ggml-tiny.en.bin"
            Url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin"
        }
        "base.en" = @{
            File = "ggml-base.en.bin"
            Url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
        }
        "small.en" = @{
            File = "ggml-small.en.bin"
            Url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
        }
        "medium.en" = @{
            File = "ggml-medium.en.bin"
            Url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin"
        }
    }

    $entry = $models[$Name]
    $path = Join-Path $ModelsDir $entry.File
    [pscustomobject]@{
        Name = $Name
        Path = $path
        Url = $entry.Url
    }
}

function Read-BooleanOption {
    param(
        [string]$Prompt,
        [bool]$Default
    )

    $suffix = if ($Default) { "[Y/n]" } else { "[y/N]" }
    while ($true) {
        $raw = Read-Host "$Prompt $suffix"
        $value = $raw.Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $Default
        }
        if ($value -in @("y", "yes")) {
            return $true
        }
        if ($value -in @("n", "no")) {
            return $false
        }
        Write-Host "Please answer y or n." -ForegroundColor Yellow
    }
}

function Read-OpacityOption {
    param([int]$Default)

    while ($true) {
        $raw = Read-Host "Transparency opacity percent opaque [$Default]"
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $Default
        }

        $value = 0
        if ([int]::TryParse($raw, [ref]$value) -and $value -ge 5 -and $value -le 95) {
            return $value
        }

        Write-Host "Use a whole number from 5 to 95." -ForegroundColor Yellow
    }
}

function Read-TransparencyBackgroundOption {
    param([string]$Default)

    while ($true) {
        $raw = Read-Host "Transparency background clear/acrylic [$Default]"
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $Default
        }

        $value = $raw.Trim().ToLowerInvariant()
        if ($value -in @("c", "clear")) {
            return "Clear"
        }
        if ($value -in @("a", "acrylic")) {
            return "Acrylic"
        }

        Write-Host "Use clear or acrylic." -ForegroundColor Yellow
    }
}

function ConvertFrom-SecureStringToPlainText {
    param([securestring]$SecureValue)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Invoke-OptionalTransparencySetup {
    if (-not $Transparency -and -not $NoTransparencyPrompt -and -not [Console]::IsInputRedirected) {
        $script:Transparency = Read-BooleanOption -Prompt "Enable terminal transparency" -Default $false
    }

    if (-not $Transparency) {
        return
    }

    if (-not (Test-Path -LiteralPath $TransparencyTool)) {
        Write-Warning "Terminal transparency tool was not found: $TransparencyTool"
        return
    }

    if (-not $transparencyOpacityProvided -and -not [Console]::IsInputRedirected) {
        $script:TransparencyOpacity = Read-OpacityOption -Default $TransparencyOpacity
    }

    if (-not $transparencyBackgroundProvided -and -not [Console]::IsInputRedirected) {
        $script:TransparencyBackground = Read-TransparencyBackgroundOption -Default $TransparencyBackground
    }

    $transparencyArgs = @{
        Opacity = $TransparencyOpacity
        ConfigureOnly = $true
        NoMenu = $true
    }

    if ($TransparencyBackground -eq "Acrylic") {
        $transparencyArgs.Acrylic = $true
    }
    else {
        $transparencyArgs.Clear = $true
    }

    & $TransparencyTool @transparencyArgs
}

function Import-OpenAiApiKey {
    if ($NoAgent) {
        return
    }

    if (-not (Test-Path -LiteralPath $OpenAiKeyTool)) {
        return
    }

    if ($SetupOpenAiKey) {
        & $OpenAiKeyTool -Set
    }

    $plainKey = Get-StoredOpenAiApiKey
    if ([string]::IsNullOrWhiteSpace($plainKey) -and -not [Console]::IsInputRedirected) {
        $shouldSet = Read-BooleanOption -Prompt "OpenAI API key is not stored. Store it now for agent insights" -Default $false
        if ($shouldSet) {
            & $OpenAiKeyTool -Set
            $plainKey = Get-StoredOpenAiApiKey
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($plainKey)) {
        $env:OPENAI_API_KEY = $plainKey.Trim()
    }
    $plainKey = $null
}

function Get-StoredOpenAiApiKey {
    try {
        if (-not (Test-Path -LiteralPath $OpenAiKeyPath -PathType Leaf)) {
            return $null
        }

        $encrypted = (Get-Content -LiteralPath $OpenAiKeyPath -Raw).Trim()
        if ([string]::IsNullOrWhiteSpace($encrypted)) {
            return $null
        }

        $secureKey = ConvertTo-SecureString -String $encrypted
        $plainKey = ConvertFrom-SecureStringToPlainText -SecureValue $secureKey
        if (-not [string]::IsNullOrWhiteSpace($plainKey)) {
            return $plainKey.Trim()
        }
    }
    catch {
        return $null
    }
    finally {
        $plainKey = $null
    }

    return $null
}

Update-CurrentProcessPath
Import-VisualStudioBuildEnvironment

$cudaRoot = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.8"
if (Test-Path -LiteralPath $cudaRoot) {
    $env:CUDA_PATH = "$cudaRoot\"
    $env:CUDA_PATH_V12_8 = "$cudaRoot\"
    $env:CudaToolkitDir = "$cudaRoot\"
    $env:Path = "$cudaRoot\bin;$cudaRoot\libnvvp;$env:Path"
}

$llvmBin = "C:\Program Files\LLVM\bin"
if (Test-Path -LiteralPath $llvmBin) {
    $env:LIBCLANG_PATH = $llvmBin
    $env:Path = "$llvmBin;$env:Path"
}

Invoke-OptionalTransparencySetup
Import-OpenAiApiKey

New-Item -ItemType Directory -Force -Path $ModelsDir | Out-Null
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

$modelInfo = Resolve-Model -Name $Model
if (-not (Test-Path -LiteralPath $modelInfo.Path)) {
    Write-Host "Downloading Whisper model $($modelInfo.Name)..." -ForegroundColor Cyan
    $tmp = "$($modelInfo.Path).download"
    if (Test-Path -LiteralPath $tmp) {
        Remove-Item -LiteralPath $tmp -Force
    }
    Invoke-WebRequest -Uri $modelInfo.Url -OutFile $tmp
    Move-Item -LiteralPath $tmp -Destination $modelInfo.Path -Force
}

$cargo = Get-CargoPath
$manifest = Join-Path $AgentRoot "Cargo.toml"
$cargoArgs = @("run", "--release", "--manifest-path", $manifest)

if (-not $Cpu) {
    $cargoArgs += @("--features", "cuda")
}

$cargoArgs += @("--", "--model", $modelInfo.Path, "--temp-dir", $TempDir, "--fade-seconds", $FadeSeconds)

if ($NoAgent) {
    $cargoArgs += "--agent-disabled"
}
else {
    $cargoArgs += @("--agent-model", $AgentModel)
}

Write-Host "Starting Enchanted transcription agent..." -ForegroundColor Cyan
Write-Host "Model: $($modelInfo.Path)" -ForegroundColor DarkGray
Write-Host "Whisper backend: $(if ($Cpu) { "CPU" } else { "CUDA" })" -ForegroundColor DarkGray
Write-Host "Agent model: $(if ($NoAgent) { "disabled" } else { $AgentModel })" -ForegroundColor DarkGray
Write-Host ""

& $cargo @cargoArgs
