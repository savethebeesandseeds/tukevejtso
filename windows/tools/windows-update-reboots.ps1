param(
    [ValidateSet("status", "disable", "enable", "toggle")]
    [string] $Action
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ui.ps1")

$policyRootPath = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate"
$automaticUpdatesPath = Join-Path $policyRootPath "AU"
$statePath = "HKCU:\Software\tukevejtso\WindowsUpdateRebootGuard"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RegistryValue {
    param(
        [string] $Path,
        [string] $Name
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $null
    }

    $property = $item.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-AutoRebootGuardStatus {
    $noAutoReboot = Get-RegistryValue -Path $automaticUpdatesPath -Name "NoAutoRebootWithLoggedOnUsers"
    $auOptions = Get-RegistryValue -Path $automaticUpdatesPath -Name "AUOptions"
    $hasPendingWindowsUpdateRestart = Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    $hasPendingComponentRestart = Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
    $hasPendingFileRename = $null -ne (Get-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations")

    [pscustomobject]@{
        NoAutoRebootPolicySet = ($noAutoReboot -eq 1)
        GuardDisabledAutoReboot = ($noAutoReboot -eq 1 -and $auOptions -eq 4)
        NoAutoRebootValue = $noAutoReboot
        AUOptions = $auOptions
        PolicyCanApply = ($auOptions -eq 4)
        PendingRestart = ($hasPendingWindowsUpdateRestart -or $hasPendingComponentRestart -or $hasPendingFileRename)
        PendingWindowsUpdateRestart = $hasPendingWindowsUpdateRestart
        PendingComponentRestart = $hasPendingComponentRestart
        PendingFileRename = $hasPendingFileRename
    }
}

function Get-AutoRebootGuardPresentation {
    param([object] $Status)

    if ($Status.GuardDisabledAutoReboot) {
        return [pscustomobject]@{
            Name = "ON"
            State = "Good"
            Summary = "Windows Update cannot restart the machine while you are logged in."
            ToggleLabel = "Turn guard off"
            ToggleDetail = "Allow automatic restarts again"
            ToggleColor = [ConsoleColor]::Yellow
        }
    }

    if ($Status.NoAutoRebootPolicySet) {
        return [pscustomobject]@{
            Name = "PARTIAL"
            State = "Warn"
            Summary = "The reboot policy is incomplete; turning the guard on will repair it."
            ToggleLabel = "Repair guard"
            ToggleDetail = "Block automatic restarts while logged in"
            ToggleColor = [ConsoleColor]::Yellow
        }
    }

    return [pscustomobject]@{
        Name = "OFF"
        State = "Bad"
            Summary = "Windows Update can restart the machine outside active hours."
        ToggleLabel = "Turn guard on"
        ToggleDetail = "Block automatic restarts while logged in"
        ToggleColor = [ConsoleColor]::Green
    }
}

function Show-AutoRebootGuardStatus {
    param(
        [object] $Status = $null,
        [object] $Presentation = $null
    )

    if ($null -eq $Status) {
        $Status = Get-AutoRebootGuardStatus
    }
    if ($null -eq $Presentation) {
        $Presentation = Get-AutoRebootGuardPresentation -Status $Status
    }

    Write-TuiHeader -Title "Reboot Guard" -Subtitle "Control Windows Update automatic restarts."

    Write-TuiStatus -Label "Auto reboot guard" -State $Presentation.State -Detail $Presentation.Name
    Write-Host ("  " + $Presentation.Summary) -ForegroundColor Gray

    Write-Host ""
    if ($Status.PendingRestart) {
        Write-TuiStatus -Label "Pending restart" -State Warn -Detail "Yes"
        Write-Host "  Windows already has a restart queued; finish it manually when ready." -ForegroundColor Gray
    }
    else {
        Write-TuiStatus -Label "Pending restart" -State Good -Detail "No"
    }

    Write-Host ""
    Write-Host "Updates stay enabled. This only controls automatic restarts while you are logged in." -ForegroundColor DarkGray
}

function Save-PreviousPolicyState {
    New-Item -Path $statePath -Force | Out-Null

    if ($null -eq (Get-RegistryValue -Path $statePath -Name "StateSaved")) {
        $auOptions = Get-RegistryValue -Path $automaticUpdatesPath -Name "AUOptions"
        $noAutoReboot = Get-RegistryValue -Path $automaticUpdatesPath -Name "NoAutoRebootWithLoggedOnUsers"

        New-ItemProperty -Path $statePath -Name "HadAUOptions" -PropertyType DWord -Value $(if ($null -eq $auOptions) { 0 } else { 1 }) -Force | Out-Null
        New-ItemProperty -Path $statePath -Name "AUOptions" -PropertyType DWord -Value $(if ($null -eq $auOptions) { 0 } else { $auOptions }) -Force | Out-Null
        New-ItemProperty -Path $statePath -Name "HadNoAutoRebootWithLoggedOnUsers" -PropertyType DWord -Value $(if ($null -eq $noAutoReboot) { 0 } else { 1 }) -Force | Out-Null
        New-ItemProperty -Path $statePath -Name "NoAutoRebootWithLoggedOnUsers" -PropertyType DWord -Value $(if ($null -eq $noAutoReboot) { 0 } else { $noAutoReboot }) -Force | Out-Null
        New-ItemProperty -Path $statePath -Name "StateSaved" -PropertyType DWord -Value 1 -Force | Out-Null
    }
}

function Restore-PreviousPolicyState {
    $stateSaved = Get-RegistryValue -Path $statePath -Name "StateSaved"

    if ($stateSaved -eq 1) {
        $hadAuOptions = Get-RegistryValue -Path $statePath -Name "HadAUOptions"
        $auOptions = Get-RegistryValue -Path $statePath -Name "AUOptions"
        $hadNoAutoReboot = Get-RegistryValue -Path $statePath -Name "HadNoAutoRebootWithLoggedOnUsers"
        $noAutoReboot = Get-RegistryValue -Path $statePath -Name "NoAutoRebootWithLoggedOnUsers"

        if ($hadAuOptions -eq 1) {
            New-ItemProperty -Path $automaticUpdatesPath -Name "AUOptions" -PropertyType DWord -Value $auOptions -Force | Out-Null
        }
        else {
            Remove-ItemProperty -Path $automaticUpdatesPath -Name "AUOptions" -ErrorAction SilentlyContinue
        }

        if ($hadNoAutoReboot -eq 1) {
            New-ItemProperty -Path $automaticUpdatesPath -Name "NoAutoRebootWithLoggedOnUsers" -PropertyType DWord -Value $noAutoReboot -Force | Out-Null
        }
        else {
            Remove-ItemProperty -Path $automaticUpdatesPath -Name "NoAutoRebootWithLoggedOnUsers" -ErrorAction SilentlyContinue
        }

        Remove-Item -Path $statePath -Recurse -Force -ErrorAction SilentlyContinue
        return
    }

    Remove-ItemProperty -Path $automaticUpdatesPath -Name "NoAutoRebootWithLoggedOnUsers" -ErrorAction SilentlyContinue
}

function Start-Elevated {
    param([string] $Action)

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-Action", $Action
    )

    Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -Verb RunAs -Wait
}

function Disable-AutoRebootGuard {
    if (-not (Test-Administrator)) {
        Write-Host "Administrator permission is required to change Windows Update reboot policy." -ForegroundColor Yellow
        Write-Host "Opening an elevated PowerShell prompt..."
        Start-Elevated -Action "disable"
        return
    }

    New-Item -Path $automaticUpdatesPath -Force | Out-Null
    Save-PreviousPolicyState
    New-ItemProperty -Path $automaticUpdatesPath -Name "AUOptions" -PropertyType DWord -Value 4 -Force | Out-Null
    New-ItemProperty -Path $automaticUpdatesPath -Name "NoAutoRebootWithLoggedOnUsers" -PropertyType DWord -Value 1 -Force | Out-Null

    Write-Host "Reboot guard is on." -ForegroundColor Green
}

function Enable-AutoRebootGuard {
    if (-not (Test-Administrator)) {
        Write-Host "Administrator permission is required to change Windows Update reboot policy." -ForegroundColor Yellow
        Write-Host "Opening an elevated PowerShell prompt..."
        Start-Elevated -Action "enable"
        return
    }

    New-Item -Path $automaticUpdatesPath -Force | Out-Null
    Restore-PreviousPolicyState

    Write-Host "Reboot guard is off." -ForegroundColor Yellow
}

function Invoke-Action {
    param([string] $RequestedAction)

    switch ($RequestedAction) {
        "status" {
            Show-AutoRebootGuardStatus
        }
        "disable" {
            Disable-AutoRebootGuard
            Write-Host ""
            Show-AutoRebootGuardStatus
        }
        "enable" {
            Enable-AutoRebootGuard
            Write-Host ""
            Show-AutoRebootGuardStatus
        }
        "toggle" {
            $status = Get-AutoRebootGuardStatus
            if ($status.GuardDisabledAutoReboot) {
                Invoke-Action -RequestedAction "enable"
            }
            else {
                Invoke-Action -RequestedAction "disable"
            }
        }
        default {
            throw "Unknown action: $RequestedAction"
        }
    }
}

function Get-RebootGuardHelpLine {
    return (
        " " +
        (Format-TuiAnsiText -Text "Up/Down" -Foreground "#5dd9e8" -Bold) +
        (Format-TuiAnsiText -Text " move   " -Foreground "#777777") +
        (Format-TuiAnsiText -Text "Enter" -Foreground "#5dd9e8" -Bold) +
        (Format-TuiAnsiText -Text " choose   " -Foreground "#777777") +
        (Format-TuiAnsiText -Text "R" -Foreground "#5dd9e8" -Bold) +
        (Format-TuiAnsiText -Text " refresh   " -Foreground "#777777") +
        (Format-TuiAnsiText -Text "Q/Esc" -Foreground "#5dd9e8" -Bold) +
        (Format-TuiAnsiText -Text " back" -Foreground "#777777")
    )
}

function Write-RebootGuardOption {
    param(
        [object] $Item,
        [int] $Index,
        [bool] $Selected
    )

    $number = "$($Index + 1)."
    if ($Selected) {
        Write-Host ("  {0,-3} {1,-18} {2}" -f $number, $Item.Label, $Item.Detail) -ForegroundColor Black -BackgroundColor Cyan
        return
    }

    Write-Host ("  {0,-3} " -f $number) -NoNewline -ForegroundColor DarkGray
    Write-Host ("{0,-18} " -f $Item.Label) -NoNewline -ForegroundColor $Item.Color
    Write-Host $Item.Detail -ForegroundColor DarkGray
}

function Select-RebootGuardAction {
    param(
        [object] $Status,
        [object] $Presentation
    )

    $items = @(
        [pscustomobject]@{
            Label = $Presentation.ToggleLabel
            Detail = $Presentation.ToggleDetail
            Action = "toggle"
            Color = $Presentation.ToggleColor
        },
        [pscustomobject]@{
            Label = "Refresh"
            Detail = "Read the current Windows policy again"
            Action = "refresh"
            Color = [ConsoleColor]::Cyan
        },
        [pscustomobject]@{
            Label = "Back"
            Detail = "Return to the toolkit menu"
            Action = "back"
            Color = [ConsoleColor]::DarkGray
        }
    )

    $selected = 0
    while ($true) {
        Show-AutoRebootGuardStatus -Status $Status -Presentation $Presentation
        Write-Host ""

        for ($i = 0; $i -lt $items.Count; $i++) {
            Write-RebootGuardOption -Item $items[$i] -Index $i -Selected ($i -eq $selected)
        }

        Write-Host ""
        Write-Host (Get-RebootGuardHelpLine)

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
            "UpArrow" {
                $selected--
                if ($selected -lt 0) { $selected = $items.Count - 1 }
            }
            "DownArrow" {
                $selected++
                if ($selected -ge $items.Count) { $selected = 0 }
            }
            "Home" {
                $selected = 0
            }
            "End" {
                $selected = $items.Count - 1
            }
            "Enter" {
                return $items[$selected]
            }
            "Escape" {
                return $null
            }
            "Q" {
                return $null
            }
            "R" {
                return [pscustomobject]@{ Action = "refresh" }
            }
            default {
                if ($key.KeyChar -match "^[1-3]$") {
                    $index = [int]::Parse($key.KeyChar.ToString()) - 1
                    return $items[$index]
                }
            }
        }
    }
}

function Invoke-InteractiveMenu {
    if ([Console]::IsInputRedirected) {
        Show-AutoRebootGuardStatus
        return
    }

    while ($true) {
        $status = Get-AutoRebootGuardStatus
        $presentation = Get-AutoRebootGuardPresentation -Status $status
        $choice = Select-RebootGuardAction -Status $status -Presentation $presentation

        if ($null -eq $choice -or $choice.Action -eq "back") {
            Clear-Host
            return
        }

        if ($choice.Action -eq "refresh") {
            continue
        }

        Clear-Host
        Invoke-Action -RequestedAction $choice.Action
        Write-Host ""
        Write-Host "Press any key to continue..." -ForegroundColor DarkGray
        [void][Console]::ReadKey($true)
    }
}

if ([string]::IsNullOrWhiteSpace($Action)) {
    Invoke-InteractiveMenu
}
else {
    Invoke-Action -RequestedAction $Action
}
