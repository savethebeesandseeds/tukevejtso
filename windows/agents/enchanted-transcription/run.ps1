param(
    [ValidateSet("Transcription")]
    [string]$Mode = "Transcription",
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
    [switch]$TranscriptDump,
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
$SettingsPath = Join-Path $env:APPDATA "tukevejtso\enchanted-transcription-settings.json"
$RestartExitCode = 75

$transparencyOpacityProvided = $PSBoundParameters.ContainsKey("TransparencyOpacity")
$modelProvided = $PSBoundParameters.ContainsKey("Model")
$languageProvided = $PSBoundParameters.ContainsKey("Language")
$fadeSecondsProvided = $PSBoundParameters.ContainsKey("FadeSeconds")
$agentModelProvided = $PSBoundParameters.ContainsKey("AgentModel")
$noAgentProvided = $PSBoundParameters.ContainsKey("NoAgent")

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

function Get-ForegroundHostWindowHandle {
    Add-TerminalKeyNativeType

    $foregroundWindow = Get-RootWindowHandle -WindowHandle ([Tukevejtso.TerminalKeys]::GetForegroundWindow())
    if ($foregroundWindow -ne [IntPtr]::Zero -and [Tukevejtso.TerminalKeys]::IsWindowVisible($foregroundWindow)) {
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

    return Get-ForegroundHostWindowHandle
}

# Capture the visible foreground host immediately. Exact tab/pane identity is not
# required for the API grace-period safeguard and made startup unnecessarily brittle.
$terminalWindowHandle = Get-CurrentTerminalWindowHandle

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

function Test-WhisperModelName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    $normalized = $Name.Trim().ToLowerInvariant()
    $builtIn = @("tiny", "base", "small", "medium", "tiny.en", "base.en", "small.en", "medium.en")
    if ($builtIn -contains $normalized) {
        return $true
    }
    if ($normalized -notmatch '^[a-z0-9][a-z0-9._-]{0,99}$') {
        return $false
    }

    return Test-Path -LiteralPath (Join-Path $ModelsDir "ggml-$normalized.bin") -PathType Leaf
}

function Resolve-CompatibleWhisperModel {
    param(
        [string]$Name,
        [string]$LanguageName
    )

    $resolved = $Name.Trim().ToLowerInvariant()
    $builtIn = @("tiny", "base", "small", "medium", "tiny.en", "base.en", "small.en", "medium.en")
    $isBuiltIn = $builtIn -contains $resolved
    $isEnglishOnly = $resolved -match '\.en($|[-_])'
    if ($LanguageName -eq "en" -and $isBuiltIn -and -not $isEnglishOnly) {
        return "$resolved.en"
    }
    if ($LanguageName -ne "en" -and $isBuiltIn -and $isEnglishOnly) {
        return $resolved.Substring(0, $resolved.Length - 3)
    }
    if ($LanguageName -ne "en" -and -not $isBuiltIn -and $isEnglishOnly) {
        return Resolve-DefaultModelForLanguage -LanguageName $LanguageName
    }

    return $resolved
}

function Get-DefaultTranscriptionSettings {
    [pscustomobject]@{
        sources = @("microphone", "system-output")
        language = "en"
        model = "medium.en"
        chunk_seconds = 12
        fade_seconds = 70
        agent_enabled = $true
        agent_model = "gpt-5.4-nano"
        include_microphone = $false
        transparency_label = $null
    }
}

function Read-TranscriptionSettings {
    param([switch]$IncludeSessionChoices)

    $settings = Get-DefaultTranscriptionSettings
    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        return $settings
    }

    try {
        $saved = Get-Content -Raw -LiteralPath $SettingsPath | ConvertFrom-Json
        if ($IncludeSessionChoices -and $saved.language) {
            $settings.language = ConvertTo-WhisperLanguage -Value ([string]$saved.language)
        }
        if ($IncludeSessionChoices -and $saved.model -and (Test-WhisperModelName -Name ([string]$saved.model))) {
            $settings.model = [string]$saved.model
        }
        if ($null -ne $saved.fade_seconds -and [int]$saved.fade_seconds -ge 5 -and [int]$saved.fade_seconds -le 180) {
            $settings.fade_seconds = [int]$saved.fade_seconds
        }
        if ($null -ne $saved.agent_enabled) {
            $settings.agent_enabled = [bool]$saved.agent_enabled
        }
        if ($saved.agent_model -and -not [string]::IsNullOrWhiteSpace([string]$saved.agent_model)) {
            $settings.agent_model = [string]$saved.agent_model
        }
        if ($saved.transparency_label -and -not [string]::IsNullOrWhiteSpace([string]$saved.transparency_label)) {
            $settings.transparency_label = [string]$saved.transparency_label
        }
    }
    catch {
        Write-Host "Ignoring unreadable transcription settings: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    return $settings
}

function Resolve-LanguageOption {
    param($Settings)

    if ($languageProvided -and -not [string]::IsNullOrWhiteSpace($Language)) {
        return ConvertTo-WhisperLanguage -Value $Language
    }

    if ($Settings -and $Settings.language) {
        return ConvertTo-WhisperLanguage -Value ([string]$Settings.language)
    }

    return "en"
}

function Resolve-ModelOption {
    param(
        $Settings,
        [string]$LanguageName
    )

    if ($modelProvided) {
        if (-not (Test-WhisperModelName -Name $Model)) {
            throw "Unknown Whisper model '$Model'. Use a built-in model or place ggml-$Model.bin in $ModelsDir."
        }
        return Resolve-CompatibleWhisperModel -Name $Model -LanguageName $LanguageName
    }
    if ($Settings -and $Settings.model -and (Test-WhisperModelName -Name ([string]$Settings.model))) {
        return Resolve-CompatibleWhisperModel -Name ([string]$Settings.model) -LanguageName $LanguageName
    }
    return Resolve-DefaultModelForLanguage -LanguageName $LanguageName
}

function Resolve-FadeSecondsOption {
    param($Settings)

    if ($fadeSecondsProvided) {
        return $FadeSeconds
    }
    if ($Settings -and $null -ne $Settings.fade_seconds) {
        $value = [int]$Settings.fade_seconds
        if ($value -ge 5 -and $value -le 180) {
            return $value
        }
    }
    return 70
}

function Resolve-AgentModelOption {
    param($Settings)

    if ($agentModelProvided) {
        return $AgentModel
    }
    if ($Settings -and $Settings.agent_model -and -not [string]::IsNullOrWhiteSpace([string]$Settings.agent_model)) {
        return [string]$Settings.agent_model
    }
    return "gpt-5.4-nano"
}

function Resolve-AgentDisabledOption {
    param($Settings)

    if ($noAgentProvided) {
        return [bool]$NoAgent
    }
    if ($Settings -and $null -ne $Settings.agent_enabled) {
        return -not [bool]$Settings.agent_enabled
    }
    return $false
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
            MinimumBytes = 70MB
        }
        "base" = @{
            File = "ggml-base.bin"
            Url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
            MinimumBytes = 130MB
        }
        "small" = @{
            File = "ggml-small.bin"
            Url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
            MinimumBytes = 450MB
        }
        "medium" = @{
            File = "ggml-medium.bin"
            Url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin"
            MinimumBytes = 1400MB
        }
        "tiny.en" = @{
            File = "ggml-tiny.en.bin"
            Url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin"
            MinimumBytes = 70MB
        }
        "base.en" = @{
            File = "ggml-base.en.bin"
            Url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
            MinimumBytes = 130MB
        }
        "small.en" = @{
            File = "ggml-small.en.bin"
            Url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
            MinimumBytes = 450MB
        }
        "medium.en" = @{
            File = "ggml-medium.en.bin"
            Url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin"
            MinimumBytes = 1400MB
        }
    }

    $entry = $models[$Name]
    if ($entry) {
        $file = $entry.File
        $url = $entry.Url
        $minimumBytes = [long]$entry.MinimumBytes
    }
    else {
        $file = "ggml-$Name.bin"
        $url = $null
        $minimumBytes = 1MB
    }
    $path = Join-Path $ModelsDir $file
    if (-not $entry -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Custom Whisper model file was not found: $path"
    }
    [pscustomobject]@{
        Name = $Name
        Path = $path
        Url = $url
        MinimumBytes = $minimumBytes
    }
}

function Test-WhisperModelFile {
    param(
        [string]$Path,
        [long]$MinimumBytes
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        $file = Get-Item -LiteralPath $Path
        if ($file.Length -lt $MinimumBytes) {
            return $false
        }

        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $magic = New-Object byte[] 4
            if ($stream.Read($magic, 0, $magic.Length) -ne $magic.Length) {
                return $false
            }

            return $magic[0] -eq 0x6c -and
                $magic[1] -eq 0x6d -and
                $magic[2] -eq 0x67 -and
                $magic[3] -eq 0x67
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        return $false
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
    param($Settings)

    if (-not (Test-Path -LiteralPath $TransparencyTool)) {
        if ($Transparency -or $Settings.transparency_label) {
            Write-Warning "Terminal transparency tool was not found: $TransparencyTool"
        }
        return
    }

    $transparencyArgs = @{
        ConfigureOnly = $true
        NoMenu = $true
    }

    if ($Transparency) {
        $transparencyArgs.Opacity = $TransparencyOpacity
        $transparencyArgs[$TransparencyBackground] = $true
    }
    else {
        switch (([string]$Settings.transparency_label).Trim().ToLowerInvariant()) {
            "opaque" { $transparencyArgs.Disable = $true }
            "clear 85%" { $transparencyArgs.Opacity = 85; $transparencyArgs.Clear = $true }
            "clear 70%" { $transparencyArgs.Opacity = 70; $transparencyArgs.Clear = $true }
            "clear 55%" { $transparencyArgs.Opacity = 55; $transparencyArgs.Clear = $true }
            "blurry 85%" { $transparencyArgs.Opacity = 85; $transparencyArgs.Acrylic = $true }
            "blurry 70%" { $transparencyArgs.Opacity = 70; $transparencyArgs.Acrylic = $true }
            "blurry 55%" { $transparencyArgs.Opacity = 55; $transparencyArgs.Acrylic = $true }
            "glass 45%" { $transparencyArgs.Opacity = 45; $transparencyArgs.Acrylic = $true }
            default { return }
        }
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

Invoke-OptionalFullScreen
$terminalRestoreSnapshot = Get-TerminalRestoreSnapshot
$transcriptDumpEnvironmentExisted = Test-Path Env:TUKEVEJTSO_TRANSCRIPT_DUMP
$previousTranscriptDumpEnvironment = $env:TUKEVEJTSO_TRANSCRIPT_DUMP
$openAiApiKeyEnvironmentExisted = Test-Path Env:OPENAI_API_KEY
$previousOpenAiApiKeyEnvironment = $env:OPENAI_API_KEY
$restartStatePath = $null
$agentExitCode = 0
$continuingSession = $false

try {
if ($TranscriptDump) {
    $env:TUKEVEJTSO_TRANSCRIPT_DUMP = "1"
}
Import-OpenAiApiKey

New-Item -ItemType Directory -Force -Path $ModelsDir | Out-Null
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
Move-LegacyWhisperModels
$restartStatePath = Join-Path $TempDir ("restart-state-{0}.json" -f [Guid]::NewGuid().ToString("N"))

$cargo = Get-CargoPath
$manifest = Join-Path $AgentRoot "Cargo.toml"

while ($true) {
    $agentExitCode = 0
    $settings = Read-TranscriptionSettings -IncludeSessionChoices:$continuingSession
    Invoke-OptionalTransparencySetup -Settings $settings
    $resolvedLanguage = Resolve-LanguageOption -Settings $settings
    $resolvedModel = Resolve-ModelOption -Settings $settings -LanguageName $resolvedLanguage
    $resolvedFadeSeconds = Resolve-FadeSecondsOption -Settings $settings
    $resolvedAgentModel = Resolve-AgentModelOption -Settings $settings
    $agentDisabled = Resolve-AgentDisabledOption -Settings $settings

    $modelInfo = Resolve-Model -Name $resolvedModel
    if (-not (Test-WhisperModelFile -Path $modelInfo.Path -MinimumBytes $modelInfo.MinimumBytes)) {
        if ([string]::IsNullOrWhiteSpace([string]$modelInfo.Url)) {
            throw "Custom Whisper model $($modelInfo.Name) is incomplete or invalid: $($modelInfo.Path)"
        }
        if (Test-Path -LiteralPath $modelInfo.Path -PathType Leaf) {
            Write-Host "Cached Whisper model $($modelInfo.Name) is incomplete; downloading it again..." -ForegroundColor Yellow
        }
        else {
            Write-Host "Downloading Whisper model $($modelInfo.Name)..." -ForegroundColor Cyan
        }
        $tmp = "$($modelInfo.Path).download"
        try {
            if (Test-Path -LiteralPath $tmp) {
                Remove-Item -LiteralPath $tmp -Force
            }
            Invoke-WebRequest -Uri $modelInfo.Url -OutFile $tmp
            if (-not (Test-WhisperModelFile -Path $tmp -MinimumBytes $modelInfo.MinimumBytes)) {
                throw "The Whisper model download was incomplete or invalid. Please run the command again to retry."
            }
            Move-Item -LiteralPath $tmp -Destination $modelInfo.Path -Force
        }
        finally {
            if (Test-Path -LiteralPath $tmp) {
                Remove-Item -LiteralPath $tmp -Force
            }
        }
    }

    $cargoArgs = @("run", "--release", "--manifest-path", $manifest)

    if (-not $Cpu) {
        $cargoArgs += @("--features", "cuda")
    }

    $cargoArgs += @("--", "--model", $modelInfo.Path, "--mode", $Mode.Replace("EnhancedTyping", "enhanced-typing").Replace("Transcription", "transcription"), "--temp-dir", $TempDir, "--restart-state", $restartStatePath, "--fade-seconds", $resolvedFadeSeconds, "--language", $resolvedLanguage, "--agent-root", $AgentRoot)
    if ($terminalWindowHandle -ne [IntPtr]::Zero) {
        $cargoArgs += @("--terminal-window-handle", $terminalWindowHandle.ToInt64().ToString())
    }

    if ($agentDisabled) {
        $cargoArgs += "--agent-disabled"
    }
    else {
        $cargoArgs += @("--agent-model", $resolvedAgentModel)
    }

    if ($Mode -ne "EnhancedTyping") {
        Write-Host "Starting Enchanted transcription agent..." -ForegroundColor Cyan
        Write-Host "Model: $($modelInfo.Path)" -ForegroundColor DarkGray
        Write-Host "Language: $resolvedLanguage" -ForegroundColor DarkGray
        Write-Host "Whisper backend: $(if ($Cpu) { "CPU" } else { "CUDA" })" -ForegroundColor DarkGray
        Write-Host "OpenAI model: $(if ($agentDisabled) { "disabled" } else { $resolvedAgentModel })" -ForegroundColor DarkGray
        Write-Host ""
    }

    try {
        & $cargo @cargoArgs
        if ($null -ne $LASTEXITCODE) {
            $agentExitCode = $LASTEXITCODE
        }
    }
    finally {
        Restore-TerminalSnapshot -Snapshot $terminalRestoreSnapshot
    }

    if ($agentExitCode -eq $RestartExitCode) {
        Write-Host "Restarting Enchanted transcription with saved settings..." -ForegroundColor Cyan
        # Command-line overrides are intentionally one-shot. After F9 saves settings,
        # the restarted worker must consume those saved values instead of reapplying
        # the launcher's original arguments.
        $modelProvided = $false
        $languageProvided = $false
        $fadeSecondsProvided = $false
        $agentModelProvided = $false
        $noAgentProvided = $false
        $NoAgent = $false
        $SetupOpenAiKey = $false
        $Transparency = $false
        $continuingSession = $true
        Import-OpenAiApiKey
        $agentExitCode = 0
        continue
    }

    break
}
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($restartStatePath) -and
        (Test-Path -LiteralPath $restartStatePath -PathType Leaf)) {
        Remove-Item -LiteralPath $restartStatePath -Force -ErrorAction SilentlyContinue
    }
    if ($TranscriptDump) {
        if ($transcriptDumpEnvironmentExisted) {
            $env:TUKEVEJTSO_TRANSCRIPT_DUMP = $previousTranscriptDumpEnvironment
        }
        else {
            Remove-Item Env:TUKEVEJTSO_TRANSCRIPT_DUMP -ErrorAction SilentlyContinue
        }
    }
    if ($openAiApiKeyEnvironmentExisted) {
        $env:OPENAI_API_KEY = $previousOpenAiApiKeyEnvironment
    }
    else {
        Remove-Item Env:OPENAI_API_KEY -ErrorAction SilentlyContinue
    }
}

if ($agentExitCode -ne 0) {
    exit $agentExitCode
}
