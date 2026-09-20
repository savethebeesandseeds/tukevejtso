$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ui.ps1")

function Get-MenuDimensions {
    try { $width = [Console]::WindowWidth; $height = [Console]::WindowHeight }
    catch { $width = 100; $height = 30 }
    if ($width -lt 1) { $width = 100 }
    if ($height -lt 1) { $height = 30 }
    return @{ Width = [Math]::Max(10, $width - 1); Height = $height }
}

function Format-MenuBorder {
    param([int] $Width, [switch] $Bottom, [switch] $More)
    $left = if ($Bottom) { [char]0x2514 } else { [char]0x250c }
    $right = if ($Bottom) { [char]0x2518 } else { [char]0x2510 }
    $rule = [string][char]0x2500
    $inside = $Width - 2
    $label = if ($Bottom) { '' } else { ' Tools ' }
    $indicator = if ($More) {
        if ($Bottom) { ' ' + [char]0x2193 + ' More below ' }
        else { ' ' + [char]0x2191 + ' More above ' }
    } else { '' }
    $indicator = Format-TuiFit $indicator ([Math]::Max(0, $inside - 2))
    $label = Format-TuiFit $label ([Math]::Max(0, $inside - $indicator.Length - 2))
    $fill = $rule * [Math]::Max(0, $inside - $label.Length - $indicator.Length - 1)
    return (
        (Format-TuiAnsiText ($left + $label + $fill) -Foreground '#606b75' -Background '#202020') +
        $(if ($indicator) { Format-TuiAnsiText $indicator -Foreground '#a8e1e8' -Background '#34454a' -Bold }) +
        (Format-TuiAnsiText ($rule + $right) -Foreground '#606b75' -Background '#202020')
    )
}

function Get-MenuGroupColors {
    param([string] $Group)
    switch ($Group) {
        'Files & media'         { return @{ Accent = '#78c9f2'; Selection = '#253f51' } }
        'Voice & text'          { return @{ Accent = '#c4a5ef'; Selection = '#42314f' } }
        'Containers & services' { return @{ Accent = '#74d4b5'; Selection = '#23493f' } }
        'System & security'     { return @{ Accent = '#e7be72'; Selection = '#4a3e29' } }
        'Help & demos'          { return @{ Accent = '#efaa90'; Selection = '#4a3330' } }
        default                { return @{ Accent = '#aab4bf'; Selection = '#34404a' } }
    }
}

function Format-MenuRow {
    param($Row, [array] $Items, [int] $Selected, [int] $Width)
    $inside = $Width - 2
    $colors = Get-MenuGroupColors $Row.Group
    $edge = Format-TuiAnsiText ([string][char]0x2502) -Foreground '#606b75' -Background '#202020'
    if ($Row.Index -lt 0) {
        $heading = (Format-TuiFit ('   ' + $Row.Group.ToUpperInvariant()) ($inside - 1)).PadRight($inside)
        return $edge + (Format-TuiAnsiText $heading -Foreground $colors.Accent -Background '#202020' -Bold) + $edge
    }
    $item = $Items[$Row.Index]
    $active = $Row.Index -eq $Selected
    $marker = if ($active) { [string][char]0x203a } else { ' ' }
    $number = ' {0} {1,2}  ' -f $marker, ($Row.Index + 1)
    $label = Format-TuiFit $item.Label ([Math]::Max(0, $inside - $number.Length - 1))
    if ($active) {
        $body = (Format-TuiAnsiText $number -Foreground $colors.Accent -Background $colors.Selection -Bold) +
            (Format-TuiAnsiText $label.PadRight($inside - $number.Length) -Foreground '#f3f7fa' -Background $colors.Selection -Bold)
    } else {
        $body = (Format-TuiAnsiText $number -Foreground $colors.Accent -Background '#202020') +
            (Format-TuiAnsiText $label.PadRight($inside - $number.Length) -Foreground '#d5d9df' -Background '#202020')
    }
    return $edge + $body + $edge
}

function Get-MenuFrame {
    param([array] $Items, [int] $Selected)
    $dimensions = Get-MenuDimensions
    $width = $dimensions.Width
    $size = [Math]::Max(1, $dimensions.Height - 9)
    $logo = $null
    if ($width -ge 94 -and $size -ge 8) {
        $logo = New-TuiImageRender -Path (Get-TuiResourcePath 'waajacamaya.png') -WidthCells 24 -MaxHeightRows ([Math]::Min(18, $size))
    }
    $menuWidth = if ($logo) { [Math]::Min(68, $width - $logo.WidthCells - 5) } else { $width }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $group = $null
    $activeRow = 0
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($Items[$i].Group -ne $group) {
            $group = $Items[$i].Group
            $rows.Add(@{ Index = -1; Group = $group })
        }
        if ($i -eq $Selected) { $activeRow = $rows.Count }
        $rows.Add(@{ Index = $i; Group = $group })
    }
    $script:MenuScrollTop = [Math]::Max(0, [Math]::Min($script:MenuScrollTop, [Math]::Max(0, $rows.Count - $size)))
    if ($activeRow -lt $script:MenuScrollTop) { $script:MenuScrollTop = $activeRow }
    elseif ($activeRow -ge $script:MenuScrollTop + $size) { $script:MenuScrollTop = $activeRow - $size + 1 }
    # Keep the first section heading visible when returning to the first tool.
    if ($Selected -eq 0 -and $size -gt 1) { $script:MenuScrollTop = 0 }
    $start = $script:MenuScrollTop
    $panel = New-Object 'System.Collections.Generic.List[string]'
    $panel.Add((Format-MenuBorder -Width $menuWidth -More:($start -gt 0)))
    for ($row = $start; $row -lt [Math]::Min($rows.Count, $start + $size); $row++) {
        $panel.Add((Format-MenuRow -Row $rows[$row] -Items $Items -Selected $Selected -Width $menuWidth))
    }
    $panel.Add((Format-MenuBorder -Width $menuWidth -Bottom -More:($start + $size -lt $rows.Count)))
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if ($width -ge 21) {
        $lines.Add((Format-TuiAnsiText ' tukevejtso' -Foreground '#92d5df' -Bold) + (Format-TuiAnsiText ' / Windows' -Foreground '#e4e8ed'))
    } else {
        $lines.Add((Format-TuiAnsiText (Format-TuiFit ' tukevejtso / Windows' $width) -Foreground '#92d5df' -Bold))
    }
    $lines.Add((Format-TuiAnsiText (Format-TuiFit ' Tools for files, voice, containers and your workstation.' $width) -Foreground '#9aa4ae'))
    $lines.Add('')
    $logoOffset = if ($logo) { [Math]::Max(0, [int][Math]::Floor(($panel.Count - $logo.Lines.Count) / 2.0)) } else { 0 }
    for ($row = 0; $row -lt $panel.Count; $row++) {
        $line = $panel[$row]
        if ($logo -and $row -ge $logoOffset -and $row -lt $logoOffset + $logo.Lines.Count) {
            $line += (' ' * 5) + $logo.Lines[$row - $logoOffset]
        }
        $lines.Add($line)
    }
    $lines.Add('')
    $lines.Add((Format-TuiAnsiText (Format-TuiFit (' ' + $Items[$Selected].Detail) $width) -Foreground '#b6bfc8'))
    $help = if ($width -ge 79) { " Up/Down Move   Enter Open   1-$($Items.Count) Jump   Home/End First/last   Q/Esc Quit" }
        else { " Up/Down Move   Enter Open   1-$($Items.Count) Jump   Q/Esc Quit" }
    $lines.Add((Format-TuiAnsiText (Format-TuiFit $help $width) -Foreground '#8ab8c0'))
    return $lines.ToArray()
}

$items = @(
    @{ Group = 'Files & media'; Label = 'Join PDFs'; Detail = 'Select, order, and combine PDFs from a folder.'; ExitCode = 29 },
    @{ Group = 'Files & media'; Label = 'Compress PDF'; Detail = 'Tune PDF quality and size; save a copy or replace the original.'; ExitCode = 30 },
    @{ Group = 'Files & media'; Label = 'Remove image backgrounds'; Detail = 'Turn image backgrounds into transparent PNGs.'; ExitCode = 28 },
    @{ Group = 'Voice & text'; Label = 'Live transcription'; Detail = 'Transcribe microphone or system audio with optional AI insights.'; ExitCode = 23 },
    @{ Group = 'Voice & text'; Label = 'Enhanced typing'; Detail = 'Dictate and refine text, then copy or type it into an app.'; ExitCode = 26 },
    @{ Group = 'Voice & text'; Label = 'OpenAI API key'; Detail = 'Set the API key used by tools with OpenAI access.'; ExitCode = 24 },
    @{ Group = 'Containers & services'; Label = 'tukevejtso Linux shell'; Detail = "Open the toolkit's Debian utility environment."; ExitCode = 27 },
    @{ Group = 'Containers & services'; Label = 'cuwacunu shell'; Detail = 'Open the cuwacunu development environment.'; ExitCode = 20 },
    @{ Group = 'Containers & services'; Label = 'robotics-learning shell'; Detail = 'Open the robotics-learning development environment.'; ExitCode = 21 },
    @{ Group = 'Containers & services'; Label = 'OpenSim muscle lab'; Detail = 'Start the local muscle simulation app.'; Script = Join-Path $PSScriptRoot 'docker-opensim-muscles.ps1' },
    @{ Group = 'Containers & services'; Label = 'Caatuu server'; Detail = 'Start, stop, or inspect the server and shared tunnel.'; Script = Join-Path $PSScriptRoot 'caatuu-start.ps1' },
    @{ Group = 'Containers & services'; Label = 'Storage & sharing'; Detail = 'Manage the file-sharing service and check its status.'; Script = Join-Path $PSScriptRoot 'storage-and-sharing-services.ps1' },
    @{ Group = 'Containers & services'; Label = 'Open container shell'; Detail = 'Choose an existing Docker container and open its shell.'; Script = Join-Path $PSScriptRoot 'docker-bash.ps1' },
    @{ Group = 'Containers & services'; Label = 'Create container'; Detail = 'Choose an image, name, ports, and mounts for a new Docker container.'; Script = Join-Path $PSScriptRoot 'docker-new.ps1' },
    @{ Group = 'System & security'; Label = 'Generate password'; Detail = 'Create a password locally without saving it.'; ExitCode = 25 },
    @{ Group = 'System & security'; Label = 'Review executables'; Detail = 'Review executable signatures, scripts, and startup entries.'; Script = Join-Path $PSScriptRoot 'review-executables.ps1' },
    @{ Group = 'System & security'; Label = 'Windows Update reboot guard'; Detail = 'Control automatic restarts while you are logged in.'; Script = Join-Path $PSScriptRoot 'windows-update-reboots.ps1' },
    @{ Group = 'System & security'; Label = 'Terminal transparency'; Detail = "Adjust the current terminal window's opacity."; ExitCode = 22 },
    @{ Group = 'Help & demos'; Label = 'Codex cookbook'; Detail = 'Open the local Codex reference in your browser.'; Script = Join-Path $PSScriptRoot 'open-codex-cookbook.ps1' },
    @{ Group = 'Help & demos'; Label = 'Terminal color test'; Detail = 'Display foreground and background color samples.'; Script = Join-Path $PSScriptRoot 'ansi-color-test.ps1' },
    @{ Group = 'Help & demos'; Label = 'Interface demo'; Detail = 'Preview panels, statuses, charts, and terminal artwork.'; Script = Join-Path $PSScriptRoot 'ui-demo.ps1' },
    @{ Group = ''; Label = 'Quit'; Detail = 'Close the toolkit menu.'; Script = $null }
)

if ($MyInvocation.InvocationName -eq '.') { return }

while ($true) {
    $script:MenuScrollTop = 0
    $choice = Select-TuiItem -Title 'Windows' -Items $items -FormatFrame ${function:Get-MenuFrame}

    if ($null -eq $choice) {
        Clear-Host
        exit 0
    }

    if ($choice.ContainsKey('ExitCode')) {
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
        Write-Host 'Command failed' -ForegroundColor Red
        Write-Host $_.Exception.Message
    }
    Write-Host ''
    Write-Host 'Press any key to return to the menu...' -ForegroundColor DarkGray
    [void][Console]::ReadKey($true)
}
