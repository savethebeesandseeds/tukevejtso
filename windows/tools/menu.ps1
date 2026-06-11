$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ui.ps1")

function Get-MenuCategoryColor {
    param([string] $Label)

    switch ($Label) {
        "Docker" { return "#4aa3ff" }
        "Open" { return "#ffd45a" }
        "Security" { return "#ff6b63" }
        "Windows" { return "#37d99e" }
        "Terminal" { return "#d65cff" }
        "Agent" { return "#37d99e" }
        default { return "#777777" }
    }
}

function Format-MenuItem {
    param(
        [hashtable] $Item,
        [int] $Index,
        [bool] $Selected,
        [string] $Number
    )

    $category = $Item.Label
    $detail = $Item.Detail
    $text = if ([string]::IsNullOrWhiteSpace($detail)) {
        "{0,-10}" -f $category
    }
    else {
        "{0,-10} {1}" -f $category, $detail
    }

    $rowWidth = 52
    $numberText = "  {0,-3} " -f $Number

    if ($Selected) {
        $selectedText = ($numberText + $text).PadRight($rowWidth)
        return Format-TuiAnsiText -Text $selectedText -Foreground "#f8fbff" -Background "#236f9f" -Bold
    }

    return (
        (Format-TuiAnsiText -Text $numberText -Foreground "#777777") +
        (Format-TuiAnsiText -Text ("{0,-10} " -f $category) -Foreground (Get-MenuCategoryColor -Label $category) -Bold) +
        (Format-TuiAnsiText -Text $detail -Foreground "#d7d7d7")
    )
}

$items = @(
    @{
        Label = "Docker"
        Detail = "New container"
        Script = Join-Path $PSScriptRoot "docker-new.ps1"
    },
    @{
        Label = "Docker"
        Detail = "Open shell"
        Script = Join-Path $PSScriptRoot "docker-bash.ps1"
    },
    @{
        Label = "Docker"
        Detail = "cuwacunu-dev shell"
        ExitCode = 20
    },
    @{
        Label = "Docker"
        Detail = "robotics-learning shell"
        ExitCode = 21
    },
    @{
        Label = "Terminal"
        Detail = "Transparency"
        ExitCode = 22
    },
    @{
        Label = "Agent"
        Detail = "Enchanted transcription"
        ExitCode = 23
    },
    @{
        Label = "Agent"
        Detail = "Enhanced typing"
        ExitCode = 26
    },
    @{
        Label = "Agent"
        Detail = "Set OpenAI API key"
        ExitCode = 24
    },
    @{
        Label = "Security"
        Detail = "Password generator"
        ExitCode = 25
    },
    @{
        Label = "Open"
        Detail = "Codex cookbook"
        Script = Join-Path $PSScriptRoot "open-codex-cookbook.ps1"
    },
    @{
        Label = "Security"
        Detail = "Review user executables"
        Script = Join-Path $PSScriptRoot "review-executables.ps1"
    },
    @{
        Label = "Windows"
        Detail = "Auto reboot guard"
        Script = Join-Path $PSScriptRoot "windows-update-reboots.ps1"
    },
    @{
        Label = "Terminal"
        Detail = "ANSI color test"
        Script = Join-Path $PSScriptRoot "ansi-color-test.ps1"
    },
    @{
        Label = "Terminal"
        Detail = "Interface primitives demo"
        Script = Join-Path $PSScriptRoot "ui-demo.ps1"
    },
    @{
        Label = "Quit"
        Detail = ""
        Script = $null
    }
)

while ($true) {
    $choice = Select-TuiItem `
        -Title "Windows" `
        -Subtitle "Local workstation tools." `
        -Items $items `
        -ShowLogo `
        -FormatStyledItem ${function:Format-MenuItem} `
        -FormatItem {
            param($item)
            if ([string]::IsNullOrWhiteSpace($item.Detail)) {
                return $item.Label
            }

            return "{0,-10} {1}" -f $item.Label, $item.Detail
        }

    if ($null -eq $choice) {
        Clear-Host
        exit 0
    }

    if ($choice.ContainsKey("ExitCode")) {
        Clear-Host
        exit $choice.ExitCode
    }

    if ($null -eq $choice.Script) {
        Clear-Host
        exit 0
    }

    Clear-Host
    try {
        & $choice.Script
    }
    catch {
        Write-Host "Command failed" -ForegroundColor Red
        Write-Host $_.Exception.Message
    }
    Write-Host ""
    Write-Host "Press any key to return to the menu..." -ForegroundColor DarkGray
    [void][Console]::ReadKey($true)
}

