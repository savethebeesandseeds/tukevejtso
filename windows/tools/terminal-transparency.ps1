param(
    [ValidateRange(5, 95)]
    [int] $Opacity = 45,

    [switch] $Acrylic,

    [switch] $Clear,

    [switch] $Disable,

    [switch] $ConfigureOnly,

    [switch] $NoMenu
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ui.ps1")

if ($Disable -and $PSBoundParameters.ContainsKey("Opacity")) {
    throw "Use -Disable by itself."
}

$dedicatedProfileName = "Transparent PowerShell"
$dedicatedProfileGuid = "{d79fdc93-b128-43ad-96fb-9db0d567f6f6}"
$profileLabel = "current terminal window"

function Test-TerminalGuidEqual {
    param(
        [string] $Left,
        [string] $Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }

    return $Left.Trim([char[]]"{}").Equals($Right.Trim([char[]]"{}"), [StringComparison]::OrdinalIgnoreCase)
}

function Get-TerminalSettingsPath {
    $paths = @(
        (Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"),
        (Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\settings.json")
    )

    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    throw "Windows Terminal settings.json was not found."
}

function Set-JsonProperty {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Object,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        $Value
    )

    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
        return
    }

    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
}

function Remove-JsonProperty {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Object,

        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.PSObject.Properties.Remove($Name)
        return $true
    }

    return $false
}

function Add-TerminalWindowNativeType {
    if ("Tukevejtso.TerminalWindowNative" -as [type]) {
        return
    }

    Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace Tukevejtso {
    [StructLayout(LayoutKind.Sequential)]
    public struct AccentPolicy {
        public int AccentState;
        public int AccentFlags;
        public int GradientColor;
        public int AnimationId;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WindowCompositionAttributeData {
        public int Attribute;
        public IntPtr Data;
        public int SizeOfData;
    }

    public static class TerminalWindowNative {
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern IntPtr GetAncestor(IntPtr hWnd, uint gaFlags);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern int GetWindowThreadProcessId(IntPtr hWnd, out int processId);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maxCount);

        [DllImport("user32.dll")]
        public static extern int GetWindowLong(IntPtr hWnd, int index);

        [DllImport("user32.dll")]
        public static extern int SetWindowLong(IntPtr hWnd, int index, int value);

        [DllImport("user32.dll")]
        public static extern bool SetLayeredWindowAttributes(IntPtr hWnd, uint colorKey, byte alpha, uint flags);

        [DllImport("user32.dll")]
        public static extern int SetWindowCompositionAttribute(IntPtr hWnd, ref WindowCompositionAttributeData data);

        [DllImport("user32.dll")]
        public static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);
    }
}
"@
}

function Get-WindowClassName {
    param([IntPtr] $WindowHandle)

    Add-TerminalWindowNativeType
    if ($WindowHandle -eq [IntPtr]::Zero) {
        return ""
    }

    $builder = [Text.StringBuilder]::new(256)
    [void][Tukevejtso.TerminalWindowNative]::GetClassName($WindowHandle, $builder, $builder.Capacity)
    return $builder.ToString()
}

function Get-WindowProcessId {
    param([IntPtr] $WindowHandle)

    Add-TerminalWindowNativeType
    $processId = 0
    [void][Tukevejtso.TerminalWindowNative]::GetWindowThreadProcessId($WindowHandle, [ref] $processId)
    return $processId
}

function Get-RootWindowHandle {
    param([IntPtr] $WindowHandle)

    Add-TerminalWindowNativeType
    if ($WindowHandle -eq [IntPtr]::Zero) {
        return [IntPtr]::Zero
    }

    $GA_ROOT = 2
    $root = [Tukevejtso.TerminalWindowNative]::GetAncestor($WindowHandle, $GA_ROOT)
    if ($root -eq [IntPtr]::Zero) {
        return $WindowHandle
    }

    return $root
}

function Test-TerminalWindowHandle {
    param(
        [IntPtr] $WindowHandle,
        [switch] $WindowsTerminalOnly
    )

    Add-TerminalWindowNativeType
    if ($WindowHandle -eq [IntPtr]::Zero -or -not [Tukevejtso.TerminalWindowNative]::IsWindowVisible($WindowHandle)) {
        return $false
    }

    $className = Get-WindowClassName -WindowHandle $WindowHandle
    if ($WindowsTerminalOnly -and $className -ne "CASCADIA_HOSTING_WINDOW_CLASS") {
        return $false
    }

    if ($className -in @("ConsoleWindowClass", "CASCADIA_HOSTING_WINDOW_CLASS")) {
        return $true
    }

    $processId = Get-WindowProcessId -WindowHandle $WindowHandle
    if ($processId -le 0) {
        return $false
    }

    try {
        $processName = (Get-Process -Id $processId -ErrorAction Stop).ProcessName
        if ($WindowsTerminalOnly) {
            return $processName -in @("WindowsTerminal", "WindowsTerminalPreview")
        }

        return $processName -in @("OpenConsole", "powershell", "pwsh", "cmd")
    }
    catch {
        return $false
    }
}

function Get-CurrentTerminalWindowHandle {
    Add-TerminalWindowNativeType

    $consoleWindow = Get-RootWindowHandle -WindowHandle ([Tukevejtso.TerminalWindowNative]::GetConsoleWindow())
    if (Test-TerminalWindowHandle -WindowHandle $consoleWindow) {
        return $consoleWindow
    }

    if (-not [string]::IsNullOrWhiteSpace($env:WT_SESSION)) {
        $foregroundWindow = Get-RootWindowHandle -WindowHandle ([Tukevejtso.TerminalWindowNative]::GetForegroundWindow())
        if (Test-TerminalWindowHandle -WindowHandle $foregroundWindow -WindowsTerminalOnly) {
            return $foregroundWindow
        }
    }

    return [IntPtr]::Zero
}

function Set-TerminalWindowOpacity {
    param(
        [IntPtr] $WindowHandle,

        [ValidateRange(5, 100)]
        [int] $Opacity
    )

    Add-TerminalWindowNativeType
    if ($WindowHandle -eq [IntPtr]::Zero) {
        throw "Could not find the current terminal window."
    }

    $GWL_EXSTYLE = -20
    $WS_EX_LAYERED = 0x80000
    $LWA_ALPHA = 0x2

    $style = [Tukevejtso.TerminalWindowNative]::GetWindowLong($WindowHandle, $GWL_EXSTYLE)
    [void][Tukevejtso.TerminalWindowNative]::SetWindowLong($WindowHandle, $GWL_EXSTYLE, ($style -bor $WS_EX_LAYERED))

    $alpha = [byte][Math]::Round(255 * ($Opacity / 100.0))
    if (-not [Tukevejtso.TerminalWindowNative]::SetLayeredWindowAttributes($WindowHandle, 0, $alpha, $LWA_ALPHA)) {
        throw "Windows rejected the opacity change for the current terminal window."
    }
}

function Set-TerminalWindowBlur {
    param(
        [IntPtr] $WindowHandle,

        [bool] $Enabled
    )

    Add-TerminalWindowNativeType
    if ($WindowHandle -eq [IntPtr]::Zero) {
        throw "Could not find the current terminal window."
    }

    $ACCENT_DISABLED = 0
    $ACCENT_ENABLE_ACRYLICBLURBEHIND = 4
    $WCA_ACCENT_POLICY = 19
    $accent = [Tukevejtso.AccentPolicy]::new()
    $accent.AccentState = if ($Enabled) { $ACCENT_ENABLE_ACRYLICBLURBEHIND } else { $ACCENT_DISABLED }
    $accent.AccentFlags = 2
    $accent.GradientColor = 0x66000000
    $accent.AnimationId = 0

    $size = [Runtime.InteropServices.Marshal]::SizeOf([type][Tukevejtso.AccentPolicy])
    $accentPtr = [Runtime.InteropServices.Marshal]::AllocHGlobal($size)
    try {
        [Runtime.InteropServices.Marshal]::StructureToPtr($accent, $accentPtr, $false)
        $data = [Tukevejtso.WindowCompositionAttributeData]::new()
        $data.Attribute = $WCA_ACCENT_POLICY
        $data.Data = $accentPtr
        $data.SizeOfData = $size
        [void][Tukevejtso.TerminalWindowNative]::SetWindowCompositionAttribute($WindowHandle, [ref] $data)
    }
    finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($accentPtr)
    }
}

function Send-TerminalOpacityHotkey {
    Add-TerminalWindowNativeType

    $KEYEVENTF_KEYUP = 0x2
    $VK_CONTROL = 0x11
    $VK_SHIFT = 0x10
    $VK_MENU = 0x12
    $VK_F24 = 0x87

    foreach ($key in @($VK_CONTROL, $VK_SHIFT, $VK_MENU, $VK_F24)) {
        [Tukevejtso.TerminalWindowNative]::keybd_event([byte] $key, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 25
    }

    foreach ($key in @($VK_F24, $VK_MENU, $VK_SHIFT, $VK_CONTROL)) {
        [Tukevejtso.TerminalWindowNative]::keybd_event([byte] $key, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 25
    }
}

function Set-WindowsTerminalOpacityAction {
    param(
        [ValidateRange(5, 100)]
        [int] $Opacity
    )

    $settingsPath = Get-TerminalSettingsPath
    $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
    $actionId = "Tukevejtso.TerminalTransparency.Apply"
    $hotkey = "ctrl+shift+alt+f24"

    $existingActions = @()
    if ($settings.PSObject.Properties.Name -contains "actions" -and $null -ne $settings.actions) {
        $existingActions = @($settings.actions) | Where-Object { $_.id -ne $actionId }
    }

    $existingKeybindings = @()
    if ($settings.PSObject.Properties.Name -contains "keybindings" -and $null -ne $settings.keybindings) {
        $existingKeybindings = @($settings.keybindings) | Where-Object { $_.id -ne $actionId }
    }

    $action = [pscustomobject][ordered]@{
        command = [pscustomobject][ordered]@{
            action = "adjustOpacity"
            opacity = $Opacity
            relative = $false
        }
        id = $actionId
    }

    $keybinding = [pscustomobject][ordered]@{
        id = $actionId
        keys = $hotkey
    }

    Set-JsonProperty -Object $settings -Name "actions" -Value (@($existingActions) + $action)
    Set-JsonProperty -Object $settings -Name "keybindings" -Value (@($existingKeybindings) + $keybinding)
    $settings | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $settingsPath -Encoding UTF8

    return $hotkey
}

function Invoke-WindowsTerminalOpacityAction {
    param(
        [ValidateRange(5, 100)]
        [int] $Opacity
    )

    if ([string]::IsNullOrWhiteSpace($env:WT_SESSION)) {
        return $false
    }

    $windowHandle = Get-CurrentTerminalWindowHandle
    if ($windowHandle -ne [IntPtr]::Zero) {
        [void][Tukevejtso.TerminalWindowNative]::SetForegroundWindow($windowHandle)
        Start-Sleep -Milliseconds 150
    }

    [void](Set-WindowsTerminalOpacityAction -Opacity $Opacity)
    Start-Sleep -Milliseconds 1200
    Send-TerminalOpacityHotkey
    Start-Sleep -Milliseconds 350
    Send-TerminalOpacityHotkey
    Start-Sleep -Milliseconds 500
    return $true
}

function Clear-ToolManagedTerminalProfileTransparency {
    $settingsPath = $null
    try {
        $settingsPath = Get-TerminalSettingsPath
    }
    catch {
        return
    }

    $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
    if ($null -eq $settings.profiles -or $null -eq $settings.profiles.list) {
        return
    }

    $changed = $false
    $profile = @($settings.profiles.list) |
        Where-Object { Test-TerminalGuidEqual -Left $_.guid -Right $dedicatedProfileGuid } |
        Select-Object -First 1

    if ($null -ne $profile) {
        foreach ($propertyToRemove in @("opacity", "useAcrylic")) {
            if (Remove-JsonProperty -Object $profile -Name $propertyToRemove) {
                $changed = $true
            }
        }
    }

    if ($changed) {
        $backupPath = "$settingsPath.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Copy-Item -LiteralPath $settingsPath -Destination $backupPath
        $settings | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
        Write-Host "Removed profile-level transparency from '$dedicatedProfileName'."
        Write-Host "Backup: $backupPath"
    }
}

function Test-JsonPropertyValue {
    param(
        [psobject] $Object,
        [string] $Name,
        $Value
    )

    if (-not ($Object.PSObject.Properties.Name -contains $Name)) {
        return $false
    }

    return $Object.$Name -eq $Value
}

function Get-TerminalOpacityText {
    param([int] $Value)

    return "{0}% opaque / {1}% see-through" -f $Value, (100 - $Value)
}

function Get-TerminalTransparencyStateText {
    param([bool] $Enabled)

    if ($Enabled) {
        return "Enabled"
    }

    return "Disabled / normal opaque background"
}

function Get-TerminalOpacityColor {
    param([int] $Value)

    if ($Value -le 35) {
        return "#37d99e"
    }
    if ($Value -le 55) {
        return "#5dd9e8"
    }
    if ($Value -le 75) {
        return "#ffd45a"
    }

    return "#ff6b63"
}

function Get-TerminalOpacityBar {
    param(
        [int] $Value,
        [int] $Width = 32
    )

    $ratio = [Math]::Max(0.0, [Math]::Min(1.0, $Value / 100.0))
    $filled = [int][Math]::Round($ratio * $Width)
    $filledText = ([char]0x2588).ToString() * $filled
    $emptyText = ([char]0x2591).ToString() * ($Width - $filled)
    return (
        (Format-TuiAnsiText -Text $filledText -Foreground (Get-TerminalOpacityColor -Value $Value)) +
        (Format-TuiAnsiText -Text $emptyText -Foreground "#333333")
    )
}

function Get-TerminalTransparencyFrameLines {
    param(
        [bool] $Enabled,
        [int] $Opacity
    )

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-TuiHeaderLines -Title "Terminal Transparency" -Subtitle "Current window only.")) {
        $lines.Add($line)
    }

    $stateColor = if ($Enabled) { "#37d99e" } else { "#ff6b63" }
    $stateText = if ($Enabled) { "ENABLED" } else { "DISABLED" }
    $opacityColor = Get-TerminalOpacityColor -Value $Opacity

    $lines.Add(
        (Format-TuiAnsiText -Text " State    " -Foreground "#777777") +
        (Format-TuiAnsiText -Text (" {0} " -f $stateText) -Foreground "#000000" -Background $stateColor -Bold)
    )
    $lines.Add("")
    $lines.Add(
        (Format-TuiAnsiText -Text " Opacity  " -Foreground "#777777") +
        (Format-TuiAnsiText -Text "< " -Foreground "#777777") +
        (Format-TuiAnsiText -Text ("{0,2}% opaque" -f $Opacity) -Foreground $opacityColor -Bold) +
        (Format-TuiAnsiText -Text (" / {0,2}% see-through" -f (100 - $Opacity)) -Foreground "#d7d7d7") +
        (Format-TuiAnsiText -Text " >" -Foreground "#777777")
    )
    $lines.Add("          " + (Get-TerminalOpacityBar -Value $Opacity -Width 34))
    $lines.Add("")
    $lines.Add(
        (Format-TuiAnsiText -Text " Left/Right" -Foreground "#5dd9e8" -Bold) +
        (Format-TuiAnsiText -Text " adjust   " -Foreground "#777777") +
        (Format-TuiAnsiText -Text "Space" -Foreground "#5dd9e8" -Bold) +
        (Format-TuiAnsiText -Text " toggle   " -Foreground "#777777") +
        (Format-TuiAnsiText -Text "Enter" -Foreground "#5dd9e8" -Bold) +
        (Format-TuiAnsiText -Text " apply   " -Foreground "#777777") +
        (Format-TuiAnsiText -Text "Esc/Q" -Foreground "#5dd9e8" -Bold) +
        (Format-TuiAnsiText -Text " cancel" -Foreground "#777777")
    )

    return [string[]]$lines
}

function Invoke-TerminalTransparencyMenu {
    param(
        [bool] $InitialEnabled,
        [int] $InitialOpacity
    )

    $selectedEnabled = $InitialEnabled
    $selectedOpacity = $InitialOpacity
    $renderedOnce = $false

    try {
        while ($true) {
            Write-TuiFrame `
                -Lines (Get-TerminalTransparencyFrameLines -Enabled $selectedEnabled -Opacity $selectedOpacity) `
                -Initial:(-not $renderedOnce)
            $renderedOnce = $true

            if ([Console]::IsInputRedirected) {
                return $null
            }

            try {
                $key = [Console]::ReadKey($true)
            }
            catch {
                return $null
            }

            switch ($key.Key) {
                "LeftArrow" {
                    $selectedOpacity = [Math]::Max(5, $selectedOpacity - 5)
                    $selectedEnabled = $true
                }
                "RightArrow" {
                    $selectedOpacity = [Math]::Min(95, $selectedOpacity + 5)
                    $selectedEnabled = $true
                }
                "Home" {
                    $selectedOpacity = 5
                    $selectedEnabled = $true
                }
                "End" {
                    $selectedOpacity = 95
                    $selectedEnabled = $true
                }
                "Spacebar" {
                    $selectedEnabled = -not $selectedEnabled
                }
                "Enter" {
                    return [pscustomobject]@{
                        Enabled = $selectedEnabled
                        Opacity = $selectedOpacity
                    }
                }
                "Escape" {
                    return $null
                }
                "Q" {
                    return $null
                }
            }
        }
    }
    finally {
        Show-TuiCursor
    }
}

$selectedEnabled = -not $Disable
$selectedOpacity = $Opacity
if (-not $Disable -and -not $NoMenu -and -not $ConfigureOnly -and -not [Console]::IsInputRedirected) {
    $menuChoice = Invoke-TerminalTransparencyMenu `
        -InitialEnabled $selectedEnabled `
        -InitialOpacity $selectedOpacity

    if ($null -eq $menuChoice) {
        Write-Host "Terminal transparency settings unchanged."
        return
    }

    $selectedEnabled = $menuChoice.Enabled
    $selectedOpacity = $menuChoice.Opacity
}

Clear-ToolManagedTerminalProfileTransparency

$windowHandle = Get-CurrentTerminalWindowHandle
if ($selectedEnabled) {
    $usedWindowsTerminalAction = Invoke-WindowsTerminalOpacityAction -Opacity $selectedOpacity
    if (-not $usedWindowsTerminalAction) {
        Set-TerminalWindowOpacity -WindowHandle $windowHandle -Opacity $selectedOpacity
    }

    $backgroundText = "current background"
    if ($Acrylic) {
        Set-TerminalWindowBlur -WindowHandle $windowHandle -Enabled $true
        $backgroundText = "blurry background"
    }
    elseif ($Clear) {
        Set-TerminalWindowBlur -WindowHandle $windowHandle -Enabled $false
        $backgroundText = "clear background"
    }

    Write-Host ("Configured {0} at {1} with {2}." -f $profileLabel, (Get-TerminalOpacityText -Value $selectedOpacity), $backgroundText)
}
else {
    $usedWindowsTerminalAction = Invoke-WindowsTerminalOpacityAction -Opacity 100
    if (-not $usedWindowsTerminalAction) {
        Set-TerminalWindowOpacity -WindowHandle $windowHandle -Opacity 100
    }
    Set-TerminalWindowBlur -WindowHandle $windowHandle -Enabled $false

    Write-Host ("Disabled {0}; this window is now fully opaque." -f $profileLabel)
}
