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

if ($Acrylic -and $Clear) {
    throw "Use either -Acrylic or -Clear, not both."
}

if ($Disable -and ($Acrylic -or $Clear -or $PSBoundParameters.ContainsKey("Opacity"))) {
    throw "Use -Disable by itself."
}

$profileName = "Windows PowerShell"
$profileLabel = "terminal transparency profile"
$profileGuid = "{d79fdc93-b128-43ad-96fb-9db0d567f6f6}"

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

function Get-TerminalBackgroundText {
    param([bool] $UseAcrylic)

    if ($UseAcrylic) {
        return "Acrylic blur and tint"
    }

    return "Clear see-through"
}

function Get-TerminalTransparencyStateText {
    param([bool] $Enabled)

    if ($Enabled) {
        return "Enabled"
    }

    return "Disabled / normal opaque background"
}

function Format-TerminalTransparencyMenuItem {
    param([hashtable] $Item)

    if ([string]::IsNullOrWhiteSpace($Item.Detail)) {
        return $Item.Label
    }

    return "{0,-18} {1}" -f $Item.Label, $Item.Detail
}

function Select-TerminalOpacity {
    param([int] $CurrentOpacity)

    $items = @(
        @{
            Label = "Very transparent"
            Detail = (Get-TerminalOpacityText -Value 30)
            Opacity = 30
        },
        @{
            Label = "Balanced"
            Detail = (Get-TerminalOpacityText -Value 45)
            Opacity = 45
        },
        @{
            Label = "Readable"
            Detail = (Get-TerminalOpacityText -Value 60)
            Opacity = 60
        },
        @{
            Label = "Subtle"
            Detail = (Get-TerminalOpacityText -Value 75)
            Opacity = 75
        },
        @{
            Label = "Custom"
            Detail = "Enter 5-95 percent opaque"
            Custom = $true
        },
        @{
            Label = "Back"
            Detail = ""
            Back = $true
        }
    )

    $choice = Select-TuiItem `
        -Title "Terminal Transparency" `
        -Subtitle ("Opacity is currently " + (Get-TerminalOpacityText -Value $CurrentOpacity) + ".") `
        -Items $items `
        -FormatItem ${function:Format-TerminalTransparencyMenuItem}

    if ($null -eq $choice -or $choice.Back) {
        return $CurrentOpacity
    }

    if ($choice.Custom) {
        while ($true) {
            Write-TuiHeader -Title "Terminal Transparency" -Subtitle "Custom opacity."
            Write-Host ("Current: " + (Get-TerminalOpacityText -Value $CurrentOpacity)) -ForegroundColor DarkGray
            Write-Host ""
            $rawValue = Read-Host "Enter percent opaque, 5-95"

            if ([string]::IsNullOrWhiteSpace($rawValue)) {
                return $CurrentOpacity
            }

            $parsed = 0
            if ([int]::TryParse($rawValue, [ref] $parsed) -and $parsed -ge 5 -and $parsed -le 95) {
                return $parsed
            }

            Write-Host "Use a whole number from 5 to 95." -ForegroundColor Yellow
            Write-Host "Press any key to try again..." -ForegroundColor DarkGray
            [void][Console]::ReadKey($true)
        }
    }

    return [int] $choice.Opacity
}

function Invoke-TerminalTransparencyMenu {
    param(
        [bool] $InitialEnabled,
        [int] $InitialOpacity,
        [bool] $InitialUseAcrylic
    )

    $selectedEnabled = $InitialEnabled
    $selectedOpacity = $InitialOpacity
    $selectedUseAcrylic = $InitialUseAcrylic

    while ($true) {
        $items = @(
            @{
                Label = "State"
                Detail = (Get-TerminalTransparencyStateText -Enabled $selectedEnabled)
                Action = "state"
            },
            @{
                Label = "Opacity"
                Detail = $(if ($selectedEnabled) { Get-TerminalOpacityText -Value $selectedOpacity } else { "Inactive while disabled" })
                Action = "opacity"
            },
            @{
                Label = "Background"
                Detail = $(if ($selectedEnabled) { Get-TerminalBackgroundText -UseAcrylic $selectedUseAcrylic } else { "Inactive while disabled" })
                Action = "background"
            },
            @{
                Label = "Apply"
                Detail = "Save these settings"
                Action = "apply"
            },
            @{
                Label = "Cancel"
                Detail = "Leave settings unchanged"
                Action = "cancel"
            }
        )

        $choice = Select-TuiItem `
            -Title "Terminal Transparency" `
            -Subtitle "Configure the dedicated transparent terminal profile before applying it." `
            -Items $items `
            -FormatItem ${function:Format-TerminalTransparencyMenuItem}

        if ($null -eq $choice -or $choice.Action -eq "cancel") {
            return $null
        }

        switch ($choice.Action) {
            "state" {
                $selectedEnabled = -not $selectedEnabled
            }
            "opacity" {
                $selectedOpacity = Select-TerminalOpacity -CurrentOpacity $selectedOpacity
                $selectedEnabled = $true
            }
            "background" {
                $selectedUseAcrylic = -not $selectedUseAcrylic
                $selectedEnabled = $true
            }
            "apply" {
                return [pscustomobject]@{
                    Enabled = $selectedEnabled
                    Opacity = $selectedOpacity
                    UseAcrylic = $selectedUseAcrylic
                }
            }
        }
    }
}

$settingsPath = Get-TerminalSettingsPath
$settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json

if ($null -eq $settings.profiles -or $null -eq $settings.profiles.list) {
    throw "Windows Terminal settings.json does not contain profiles.list."
}

$profile = @($settings.profiles.list) |
    Where-Object { $_.guid -ieq $profileGuid } |
    Select-Object -First 1

$changed = $false
$selectedEnabled = -not $Disable
$selectedOpacity = $Opacity
$selectedUseAcrylic = [bool] $Acrylic
$hasExplicitTransparencySetting = (
    $PSBoundParameters.ContainsKey("Opacity") -or
    $PSBoundParameters.ContainsKey("Acrylic") -or
    $PSBoundParameters.ContainsKey("Clear")
)

if (-not $Disable -and $hasExplicitTransparencySetting) {
    $selectedEnabled = $true
}
elseif (-not $Disable -and $null -ne $profile) {
    $hasOpacity = $profile.PSObject.Properties.Name -contains "opacity"
    $hasAcrylic = $profile.PSObject.Properties.Name -contains "useAcrylic"
    $selectedEnabled = $hasOpacity -or $hasAcrylic
}

if (-not $PSBoundParameters.ContainsKey("Opacity") -and
    $null -ne $profile -and
    $profile.PSObject.Properties.Name -contains "opacity") {
    $selectedOpacity = [Math]::Max(5, [Math]::Min(95, [int] $profile.opacity))
}

if ($PSBoundParameters.ContainsKey("Clear")) {
    $selectedUseAcrylic = $false
}
elseif (-not $PSBoundParameters.ContainsKey("Acrylic") -and
    $null -ne $profile -and
    $profile.PSObject.Properties.Name -contains "useAcrylic") {
    $selectedUseAcrylic = [bool] $profile.useAcrylic
}

if (-not $NoMenu -and -not $ConfigureOnly -and -not [Console]::IsInputRedirected) {
    $menuChoice = Invoke-TerminalTransparencyMenu `
        -InitialEnabled $selectedEnabled `
        -InitialOpacity $selectedOpacity `
        -InitialUseAcrylic $selectedUseAcrylic

    if ($null -eq $menuChoice) {
        Write-Host "Terminal transparency settings unchanged."
        return
    }

    $selectedEnabled = $menuChoice.Enabled
    $selectedOpacity = $menuChoice.Opacity
    $selectedUseAcrylic = $menuChoice.UseAcrylic
}

if ($null -eq $profile) {
    $profileProperties = [ordered]@{
        commandline = "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
        guid = $profileGuid
        hidden = $false
        name = $profileName
    }

    if ($selectedEnabled) {
        $profileProperties["opacity"] = $selectedOpacity
        $profileProperties["useAcrylic"] = $selectedUseAcrylic
    }

    $profile = [pscustomobject]$profileProperties
    $settings.profiles.list = @($settings.profiles.list) + $profile
    $changed = $true
}
else {
    $properties = [ordered]@{
        commandline = "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
        guid = $profileGuid
        hidden = $false
        name = $profileName
    }

    if ($selectedEnabled) {
        $properties["opacity"] = $selectedOpacity
        $properties["useAcrylic"] = $selectedUseAcrylic
    }

    foreach ($entry in $properties.GetEnumerator()) {
        if (-not (Test-JsonPropertyValue -Object $profile -Name $entry.Key -Value $entry.Value)) {
            Set-JsonProperty -Object $profile -Name $entry.Key -Value $entry.Value
            $changed = $true
        }
    }

    foreach ($propertyToRemove in @("suppressApplicationTitle", "tabTitle")) {
        if (Remove-JsonProperty -Object $profile -Name $propertyToRemove) {
            $changed = $true
        }
    }

    if (-not $selectedEnabled) {
        foreach ($propertyToRemove in @("opacity", "useAcrylic")) {
            if (Remove-JsonProperty -Object $profile -Name $propertyToRemove) {
                $changed = $true
            }
        }
    }
}

if ($changed) {
    $backupPath = "$settingsPath.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Copy-Item -LiteralPath $settingsPath -Destination $backupPath
    $settings | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    if ($selectedEnabled) {
        Write-Host ("Configured {0} at {1} with {2}." -f $profileLabel, (Get-TerminalOpacityText -Value $selectedOpacity), (Get-TerminalBackgroundText -UseAcrylic $selectedUseAcrylic))
    }
    else {
        Write-Host ("Disabled {0}; terminal background will use the normal opaque/default appearance." -f $profileLabel)
    }
    Write-Host "Backup: $backupPath"
}
else {
    if ($selectedEnabled) {
        Write-Host ("The {0} is already configured at {1} with {2}." -f $profileLabel, (Get-TerminalOpacityText -Value $selectedOpacity), (Get-TerminalBackgroundText -UseAcrylic $selectedUseAcrylic))
    }
    else {
        Write-Host ("The {0} is already disabled." -f $profileLabel)
    }
}
