param(
    [ValidateSet("EnhancedTyping")]
    [string]$Mode = "EnhancedTyping",
    [ValidateSet("tiny", "base", "small", "medium", "tiny.en", "base.en", "small.en", "medium.en")]
    [string]$Model = "medium",
    [string]$Language = "",
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
    [switch]$FullScreen,
    [switch]$Cpu
)

$ErrorActionPreference = "Stop"

$AgentRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsRoot = Split-Path -Parent (Split-Path -Parent $AgentRoot)
$ModelsDir = Join-Path $WindowsRoot "models\whisper"
$TempDir = Join-Path $AgentRoot ".temp"
$TransparencyTool = Join-Path $WindowsRoot "tools\terminal-transparency.ps1"
$OpenAiKeyTool = Join-Path $WindowsRoot "tools\openai-api-key.ps1"
$OpenAiKeyPath = Join-Path $env:APPDATA "tukevejtso\secrets\openai-api-key.dpapi"

$transparencyOpacityProvided = $PSBoundParameters.ContainsKey("TransparencyOpacity")
$modelProvided = $PSBoundParameters.ContainsKey("Model")

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

function Add-TerminalKeyNativeType {
    if ("Tukevejtso.TerminalKeys" -as [type]) {
        return
    }

    Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace Tukevejtso {
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public static class TerminalKeys {
        [DllImport("kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll")]
        public static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern IntPtr GetAncestor(IntPtr hWnd, uint gaFlags);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maxCount);

        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hWnd, out Rect rect);

        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

        [DllImport("user32.dll")]
        public static extern bool IsZoomed(IntPtr hWnd);
    }
}
"@
}

function Get-RootWindowHandle {
    param([IntPtr]$WindowHandle)

    Add-TerminalKeyNativeType
    if ($WindowHandle -eq [IntPtr]::Zero) {
        return [IntPtr]::Zero
    }

    $GA_ROOT = 2
    $root = [Tukevejtso.TerminalKeys]::GetAncestor($WindowHandle, $GA_ROOT)
    if ($root -eq [IntPtr]::Zero) {
        return $WindowHandle
    }

    return $root
}

function Get-WindowClassName {
    param([IntPtr]$WindowHandle)

    Add-TerminalKeyNativeType
    if ($WindowHandle -eq [IntPtr]::Zero) {
        return ""
    }

    $builder = [Text.StringBuilder]::new(256)
    [void] [Tukevejtso.TerminalKeys]::GetClassName($WindowHandle, $builder, $builder.Capacity)
    return $builder.ToString()
}

function Test-TerminalWindowHandle {
    param([IntPtr]$WindowHandle)

    Add-TerminalKeyNativeType
    if ($WindowHandle -eq [IntPtr]::Zero -or -not [Tukevejtso.TerminalKeys]::IsWindowVisible($WindowHandle)) {
        return $false
    }

    $className = Get-WindowClassName -WindowHandle $WindowHandle
    return $className -in @("ConsoleWindowClass", "CASCADIA_HOSTING_WINDOW_CLASS")
}

function Get-ForegroundTerminalWindowHandle {
    Add-TerminalKeyNativeType

    $foregroundWindow = Get-RootWindowHandle -WindowHandle ([Tukevejtso.TerminalKeys]::GetForegroundWindow())
    if (Test-TerminalWindowHandle -WindowHandle $foregroundWindow) {
        return $foregroundWindow
    }

    return [IntPtr]::Zero
}

function Get-CurrentTerminalWindowHandle {
    Add-TerminalKeyNativeType

    $consoleWindow = Get-RootWindowHandle -WindowHandle ([Tukevejtso.TerminalKeys]::GetConsoleWindow())
    if (Test-TerminalWindowHandle -WindowHandle $consoleWindow) {
        return $consoleWindow
    }

    if (-not [string]::IsNullOrWhiteSpace($env:WT_SESSION)) {
        return Get-ForegroundTerminalWindowHandle
    }

    return [IntPtr]::Zero
}

function Invoke-OptionalFullScreen {
    if ($Mode -ne "EnhancedTyping" -or -not $FullScreen -or [Console]::IsInputRedirected) {
        return
    }

    Add-TerminalKeyNativeType
    if ((Get-ForegroundTerminalWindowHandle) -eq [IntPtr]::Zero) {
        return
    }

    $KEYEVENTF_KEYUP = 0x2
    $VK_F11 = 0x7A

    [Tukevejtso.TerminalKeys]::keybd_event([byte] $VK_F11, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 40
    [Tukevejtso.TerminalKeys]::keybd_event([byte] $VK_F11, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 250
}

function Get-TerminalRestoreSnapshot {
    if ($Mode -ne "EnhancedTyping") {
        return $null
    }

    $snapshot = [ordered]@{
        Width = $null
        Height = $null
        WindowHandle = [IntPtr]::Zero
        Left = 0
        Top = 0
        PixelWidth = 0
        PixelHeight = 0
        Maximized = $false
    }

    try {
        $snapshot.Width = [Console]::WindowWidth
        $snapshot.Height = [Console]::WindowHeight
    }
    catch {
    }

    try {
        Add-TerminalKeyNativeType
        $hwnd = Get-CurrentTerminalWindowHandle
        if ($hwnd -ne [IntPtr]::Zero) {
            $rect = [Tukevejtso.Rect]::new()
            if ([Tukevejtso.TerminalKeys]::GetWindowRect($hwnd, [ref] $rect)) {
                $snapshot.WindowHandle = $hwnd
                $snapshot.Left = $rect.Left
                $snapshot.Top = $rect.Top
                $snapshot.PixelWidth = $rect.Right - $rect.Left
                $snapshot.PixelHeight = $rect.Bottom - $rect.Top
                $snapshot.Maximized = [Tukevejtso.TerminalKeys]::IsZoomed($hwnd)
            }
        }
    }
    catch {
    }

    return [pscustomobject]$snapshot
}

function Restore-TerminalSnapshot {
    param($Snapshot)

    if ($null -eq $Snapshot) {
        return
    }

    try {
        if ($Snapshot.Width -and $Snapshot.Height) {
            [Console]::Out.Write("$([char]27)[8;$($Snapshot.Height);$($Snapshot.Width)t")
            [Console]::Out.Flush()
        }
    }
    catch {
    }

    try {
        Add-TerminalKeyNativeType
        if ($Snapshot.WindowHandle -ne [IntPtr]::Zero -and $Snapshot.PixelWidth -gt 0 -and $Snapshot.PixelHeight -gt 0) {
            $SW_RESTORE = 9
            $SW_MAXIMIZE = 3
            $SWP_NOZORDER = 0x0004
            $SWP_NOACTIVATE = 0x0010
            [void] [Tukevejtso.TerminalKeys]::ShowWindow($Snapshot.WindowHandle, $SW_RESTORE)
            [void] [Tukevejtso.TerminalKeys]::SetWindowPos(
                $Snapshot.WindowHandle,
                [IntPtr]::Zero,
                $Snapshot.Left,
                $Snapshot.Top,
                $Snapshot.PixelWidth,
                $Snapshot.PixelHeight,
                ($SWP_NOZORDER -bor $SWP_NOACTIVATE)
            )
            if ($Snapshot.Maximized) {
                [void] [Tukevejtso.TerminalKeys]::ShowWindow($Snapshot.WindowHandle, $SW_MAXIMIZE)
            }
        }
    }
    catch {
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

function ConvertTo-WhisperLanguage {
    param([string]$Value)

    $language = $Value.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($language)) {
        return "en"
    }

    switch ($language) {
        "english" { return "en" }
        "eng" { return "en" }
        "spanish" { return "es" }
        "espanol" { return "es" }
        default { return $language }
    }
}

function Read-LanguageOption {
    while ($true) {
        $raw = Read-Host "Language code [en, use auto for auto-detect]"
        $language = ConvertTo-WhisperLanguage -Value $raw
        if ($language -eq "auto" -or $language -match "^[a-z]{2,3}(-[a-z0-9]+)?$") {
            return $language
        }
        Write-Host "Use a Whisper language code like en or es, or auto." -ForegroundColor Yellow
    }
}

function Resolve-LanguageOption {
    if (-not [string]::IsNullOrWhiteSpace($Language)) {
        return ConvertTo-WhisperLanguage -Value $Language
    }

    if ($Mode -eq "Transcription" -and -not [Console]::IsInputRedirected) {
        return Read-LanguageOption
    }

    return "en"
}

function Resolve-DefaultModelForLanguage {
    param([string]$LanguageName)

    if ($LanguageName -eq "en") {
        return "medium.en"
    }

    return "medium"
}

function Move-LegacyWhisperModels {
    $agentsRoot = Join-Path $WindowsRoot "agents"
    if (-not (Test-Path -LiteralPath $agentsRoot -PathType Container)) {
        return
    }

    Get-ChildItem -LiteralPath $agentsRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            $legacyModelsDir = Join-Path $_.FullName "models"
            if (Test-Path -LiteralPath $legacyModelsDir -PathType Container) {
                Get-ChildItem -LiteralPath $legacyModelsDir -File -Filter "ggml-*.bin" -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        $destination = Join-Path $ModelsDir $_.Name
                        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
                            Move-Item -LiteralPath $_.FullName -Destination $destination -Force
                        }
                        else {
                            $sharedModel = Get-Item -LiteralPath $destination
                            if ($sharedModel.Length -eq $_.Length) {
                                $legacyHash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                                $sharedHash = (Get-FileHash -LiteralPath $sharedModel.FullName -Algorithm SHA256).Hash
                                if ($legacyHash -eq $sharedHash) {
                                    Remove-Item -LiteralPath $_.FullName -Force
                                }
                            }
                        }
                    }
            }
        }
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

    $transparencyArgs = @{
        Opacity = $TransparencyOpacity
        ConfigureOnly = $true
        NoMenu = $true
    }

    & $TransparencyTool @transparencyArgs
}

function Import-OpenAiApiKey {
    if ($NoAgent -and $Mode -ne "EnhancedTyping") {
        return
    }

    if (-not (Test-Path -LiteralPath $OpenAiKeyTool)) {
        return
    }

    if ($SetupOpenAiKey) {
        & $OpenAiKeyTool -Set
    }

    if ($Mode -eq "EnhancedTyping" -and -not $SetupOpenAiKey) {
        $plainKey = Get-StoredOpenAiApiKey
        if (-not [string]::IsNullOrWhiteSpace($plainKey)) {
            $env:OPENAI_API_KEY = $plainKey.Trim()
        }
        $plainKey = $null
        return
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

if ($Mode -ne "EnhancedTyping" -or $Transparency) {
    Invoke-OptionalTransparencySetup
}
Invoke-OptionalFullScreen
$terminalRestoreSnapshot = Get-TerminalRestoreSnapshot
Import-OpenAiApiKey

$resolvedLanguage = Resolve-LanguageOption
if (-not $modelProvided) {
    $Model = Resolve-DefaultModelForLanguage -LanguageName $resolvedLanguage
}

New-Item -ItemType Directory -Force -Path $ModelsDir | Out-Null
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
Move-LegacyWhisperModels

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

$cargoArgs += @("--", "--model", $modelInfo.Path, "--mode", $Mode.Replace("EnhancedTyping", "enhanced-typing").Replace("Transcription", "transcription"), "--temp-dir", $TempDir, "--fade-seconds", $FadeSeconds, "--language", $resolvedLanguage, "--agent-root", $AgentRoot)
if ($terminalRestoreSnapshot -and $terminalRestoreSnapshot.WindowHandle -ne [IntPtr]::Zero) {
    $cargoArgs += @("--terminal-window-handle", $terminalRestoreSnapshot.WindowHandle.ToInt64().ToString())
}

if ($NoAgent) {
    $cargoArgs += "--agent-disabled"
}
else {
    $cargoArgs += @("--agent-model", $AgentModel)
}

if ($Mode -ne "EnhancedTyping") {
    Write-Host "Starting Enchanted transcription agent..." -ForegroundColor Cyan
    Write-Host "Model: $($modelInfo.Path)" -ForegroundColor DarkGray
    Write-Host "Language: $resolvedLanguage" -ForegroundColor DarkGray
    Write-Host "Whisper backend: $(if ($Cpu) { "CPU" } else { "CUDA" })" -ForegroundColor DarkGray
    Write-Host "OpenAI model: $(if ($NoAgent) { "disabled" } else { $AgentModel })" -ForegroundColor DarkGray
    Write-Host ""
}

$agentExitCode = 0
try {
    & $cargo @cargoArgs
    if ($null -ne $LASTEXITCODE) {
        $agentExitCode = $LASTEXITCODE
    }
}
finally {
    Restore-TerminalSnapshot -Snapshot $terminalRestoreSnapshot
}

if ($agentExitCode -ne 0) {
    exit $agentExitCode
}
