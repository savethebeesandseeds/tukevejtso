# Presentation only: no native runtime, hardware queries, or monitor activation.
if ($null -eq (Get-Variable -Name TuiImageRenderCache -Scope Script -ErrorAction SilentlyContinue)) {
    $script:TuiImageRenderCache = @{}
}
. (Join-Path $PSScriptRoot 'ui.ps1')
$script:AlarmUiEvents = New-Object 'System.Collections.Generic.List[object]'
$script:AlarmUiActive = $false
$script:AlarmUiFailed = $false
$script:AlarmUiDrawn = $false

function ConvertTo-AlarmUiText {
    param([object] $Value)
    # Journal strings must never become terminal commands.
    return [regex]::Replace([string]$Value, '[\x00-\x1f\x7f-\x9f]', ' ')
}

function Get-AlarmUiValue {
    param([object] $Item, [string] $Name, [object] $Default = '')
    if ($Item -is [System.Collections.IDictionary] -and $Item.Contains($Name)) { return $Item[$Name] }
    if ($null -ne $Item -and $null -ne $Item.PSObject.Properties[$Name]) { return $Item.$Name }
    return $Default
}

function Get-AlarmUiReport {
    param([string] $Path)
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $report = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            if ((Get-AlarmUiValue $report 'Version' 0) -eq 2) { return $report }
        }
    } catch { }
    return $null
}

function Get-AlarmUiEvents {
    param([string] $Path, [int] $Count = 40)
    $events = New-Object 'System.Collections.Generic.List[object]'
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            foreach ($line in (Get-Content -LiteralPath $Path -Tail 160)) {
                try {
                    $item = $line | ConvertFrom-Json
                    if ($null -ne $item -and (Get-AlarmUiValue $item 'Version' 0) -eq 2 -and
                        (Get-AlarmUiValue $item 'Event') -and (Get-AlarmUiValue $item 'AtUtc')) {
                        $events.Add($item)
                    }
                } catch { } # A concurrent journal append can leave the last line incomplete.
            }
        } catch { }
    }
    return @($events | Select-Object -Last $Count)
}

function Add-AlarmUiEvent {
    param([object] $Item)
    $script:AlarmUiEvents.Add($Item)
    while ($script:AlarmUiEvents.Count -gt 40) { $script:AlarmUiEvents.RemoveAt(0) }
}

function Get-AlarmUiTime {
    param([object] $Value)
    try { return [DateTimeOffset]::Parse([string]$Value).ToLocalTime().ToString('HH:mm:ss') }
    catch { return '--:--:--' }
}

function Get-AlarmUiDimensions {
    try { $width = [Console]::WindowWidth; $height = [Console]::WindowHeight }
    catch { $width = 100; $height = 30 }
    if ($width -lt 1) { $width = 100 }
    if ($height -lt 1) { $height = 30 }
    return @{ Width = [Math]::Max(1, [Math]::Min(120, $width - 1)); Height = [Math]::Max(1, $height - 1) }
}

function Get-AlarmUiPadlock {
    param([string] $Color = '#e7be72')
    # Half-block cells: the empty shackle, keyhole, and surrounding space retain
    # the terminal's default background. No bitmap or image dependency is needed.
    $pixels = @(
        '       ######       ', '     ##########     ',
        '    ###      ###    ', '    ##        ##    ',
        '    ##        ##    ', '    ##        ##    ',
        '    ##        ##    ', '    ##        ##    ',
        '  ################  ', ' ################## ',
        ' ################## ', ' #######    ####### ',
        ' #######    ####### ', ' ########  ######## ',
        ' ########  ######## ', ' ########  ######## ',
        ' ################## ', ' ################## ',
        ' ################## ', '  ################  '
    )
    $lines = New-Object 'System.Collections.Generic.List[string]'
    for ($row = 0; $row -lt $pixels.Count; $row += 2) {
        $text = ''
        for ($col = 0; $col -lt 20; $col++) {
            $top = $pixels[$row][$col] -eq '#'
            $bottom = $pixels[$row + 1][$col] -eq '#'
            $text += $(if ($top -and $bottom) { [char]0x2588 }
                elseif ($top) { [char]0x2580 }
                elseif ($bottom) { [char]0x2584 } else { ' ' })
        }
        $lines.Add((Format-TuiAnsiText $text -Foreground $Color))
    }
    return $lines.ToArray()
}

function ConvertTo-AlarmUiFlag {
    param([object] $Value)
    if ($Value -is [bool]) { if ($Value) { return 'TRUE' }; return 'FALSE' }
    return 'UNKNOWN'
}

function Get-AlarmUiPresentation {
    param([object] $Report, [switch] $Live, [object] $Observation)
    # Live belongs only to the controller which owns the alarm. Hardware
    # observations never make a saved alarm report authoritative.
    $preview = (Get-AlarmUiValue $Report 'Preview' $false) -eq $true
    $running = Get-AlarmUiValue $Report 'Running' $null
    $phaseValue = [string](Get-AlarmUiValue $Report 'Phase')
    $phaseKnown = $phaseValue -in @('Armed', 'Pending', 'Alarm', 'WaitingForPower', 'Unknown', 'Disabled')
    $phase = if ($phaseKnown) { $phaseValue } else { 'Unknown' }
    $fresh = $false
    try {
        $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse([string](Get-AlarmUiValue $Report 'UpdatedUtc'))).TotalSeconds
        $fresh = $age -ge 0 -and $age -lt 10
    } catch { }
    $stopped = $running -is [bool] -and -not $running
    $known = $running -is [bool] -and ($Live -or $preview -or $fresh -or $stopped)
    $current = $known -and $running
    $flags = [ordered]@{
        Enabled = 'UNKNOWN'; WindowsLocked = 'UNKNOWN'; AcOnline = 'UNKNOWN'
        BatteryPresent = 'UNKNOWN'; CountdownPending = 'UNKNOWN'; AlarmActive = 'UNKNOWN'
    }
    if ($known) {
        $flags.Enabled = ConvertTo-AlarmUiFlag $running
        $flags.CountdownPending = if (-not $running) { 'FALSE' }
            elseif ($phaseKnown) { ConvertTo-AlarmUiFlag ([bool]($phase -eq 'Pending')) }
            else { 'UNKNOWN' }
        $flags.AlarmActive = if ($running) { ConvertTo-AlarmUiFlag (Get-AlarmUiValue $Report 'AlarmActive' $null) } else { 'FALSE' }
    }
    $reportTime = Get-AlarmUiTime (Get-AlarmUiValue $Report 'UpdatedUtc')
    $alarmSource = if ($Live) { 'Alarm flags / LIVE controller' }
        elseif ($preview) { 'Alarm flags / SAMPLE data' }
        elseif ($stopped) { 'Alarm flags / REPORTED STOPPED at ' + $reportTime }
        elseif ($known) { 'Alarm flags / REPORTED at ' + $reportTime }
        elseif ($Report) { 'Alarm flags / STALE or incomplete report at ' + $reportTime }
        else { 'Alarm flags / no monitor report' }

    $hardware = $null
    $hardwareSource = 'Hardware flags / unavailable'
    $observationSource = [string](Get-AlarmUiValue $Observation 'Source')
    $observationFresh = $false
    if ($observationSource -eq 'live') {
        try {
            $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse([string](Get-AlarmUiValue $Observation 'ObservedUtc'))).TotalSeconds
            $observationFresh = $age -ge 0 -and $age -lt 10
        } catch { }
    }
    if ($observationSource -eq 'sample') {
        $hardware = $Observation; $hardwareSource = 'Hardware flags / SAMPLE data'
    } elseif ($observationFresh) {
        $hardware = $Observation
        $hardwareSource = 'Hardware flags / CURRENT READ-ONLY at ' + (Get-AlarmUiTime (Get-AlarmUiValue $Observation 'ObservedUtc'))
    } elseif ($Report) {
        $hardware = $Report
        $hardwareSource = if ($preview) { 'Hardware flags / SAMPLE data' }
            elseif ($Live) { 'Hardware flags / LIVE controller at ' + $reportTime }
            else { 'Hardware flags / LAST OBSERVED at ' + $reportTime }
    }
    if ($hardware) {
        $lockState = [string](Get-AlarmUiValue $hardware 'LockState')
        $ac = [string](Get-AlarmUiValue $hardware 'Ac')
        $flags.WindowsLocked = switch ($lockState) { 'Locked' { 'TRUE' } 'Unlocked' { 'FALSE' } default { 'UNKNOWN' } }
        $flags.AcOnline = switch ($ac) { 'Online' { 'TRUE' } 'Offline' { 'FALSE' } default { 'UNKNOWN' } }
        if ((Get-AlarmUiValue $hardware 'BatteryKnown' $false) -eq $true) {
            $flags.BatteryPresent = ConvertTo-AlarmUiFlag (Get-AlarmUiValue $hardware 'HasBattery' $null)
        }
    }
    $label = 'NO MONITOR REPORT'; $color = '#9aa4ae'; $hint = 'Choose Enable alarm; explicit confirmation is required.'
    if ($known -and -not $running) { $label = 'DISABLED' }
    elseif ($current) {
        $label = 'ENABLED'; $color = '#74d4b5'; $hint = 'Watching new AC loss while Windows is locked.'
        if ($flags.AlarmActive -eq 'TRUE') {
            $label = 'ALARM ACTIVE'; $color = '#f08b7c'; $hint = 'Reconnect AC or unlock Windows to stop.'
        } elseif (-not $phaseKnown) {
            $label = 'INCOMPLETE STATE'; $color = '#e7be72'; $hint = 'Incomplete report; countdown and alarm state may be unknown.'
        } elseif ($phase -eq 'Pending') {
            $label = 'COUNTDOWN'; $color = '#e7be72'; $hint = 'Reconnect AC or unlock to cancel the countdown.'
        } elseif ($phase -eq 'WaitingForPower') {
            $label = 'WAITING FOR AC'; $color = '#e7be72'; $hint = 'Reconnect AC before a new removal can trigger.'
        } elseif ($phase -eq 'Unknown') {
            $label = 'STATE UNKNOWN'; $color = '#e7be72'; $hint = 'Alarm stopped; waiting for confirmed Windows and AC state.'
        }
        if (-not $Live) {
            $label = 'REPORTED ' + $label
            if ($phaseKnown) { $hint = 'Saved alarm state; refresh to check its timestamp.' }
        }
    } elseif ($Report) {
        $label = 'STALE REPORT'; $color = '#e7be72'; $hint = 'Alarm flags are unknown; this report cannot establish protection.'
    }
    $remainingText = ''
    if ($flags.CountdownPending -eq 'TRUE') {
        $remaining = Get-AlarmUiValue $Report 'DelayRemainingSeconds' $null
        try {
            if ($remaining -is [ValueType] -and -not ($remaining -is [bool])) {
                $seconds = [double]$remaining
                if (-not [double]::IsNaN($seconds) -and -not [double]::IsInfinity($seconds) -and $seconds -ge 0) {
                    $remainingText = '{0:0.0}s remaining' -f $seconds
                    $label += '  ' + $remainingText
                }
            }
        } catch { }
    }
    if (Get-AlarmUiValue $Report 'Error') { $hint = 'Error: ' + (ConvertTo-AlarmUiText (Get-AlarmUiValue $Report 'Error')) }
    $hardwareFailure = [string](Get-AlarmUiValue $Observation 'Failure')
    if ($hardwareFailure) { $hardwareSource += ' / reading failed' }
    return @{ Current = $current; Label = $label; Color = $color; Hint = $hint; Output = 'loud'; Phase = $phase
        Flags = $flags; AlarmSource = $alarmSource; HardwareSource = $hardwareSource; RemainingText = $remainingText
        HardwareFailure = (ConvertTo-AlarmUiText $hardwareFailure) }
}

function Get-AlarmUiFlagRows {
    param([object] $Presentation, [int] $Width, [switch] $Hardware)
    $names = if ($Hardware) { @('Windows locked', 'AC online', 'Battery present') }
        else { @('Enabled', 'Countdown pending', 'Alarm active') }
    $keys = if ($Hardware) { @('WindowsLocked', 'AcOnline', 'BatteryPresent') }
        else { @('Enabled', 'CountdownPending', 'AlarmActive') }
    $rows = New-Object 'System.Collections.Generic.List[string]'
    if ($Width -ge 55) {
        $rows.Add(('{0,-18} {1,-7}   {2,-18} {3}' -f $names[0], $Presentation.Flags[$keys[0]], $names[1], $Presentation.Flags[$keys[1]]))
        $rows.Add(('{0,-18} {1}' -f $names[2], $Presentation.Flags[$keys[2]]))
    } else {
        for ($index = 0; $index -lt $names.Count; $index++) {
            $value = [string]$Presentation.Flags[$keys[$index]]
            $labelWidth = [Math]::Max(0, $Width - $value.Length - 1)
            $name = Format-TuiFit $names[$index] $labelWidth
            $rows.Add((Format-TuiFit ($name.PadRight($labelWidth) + ' ' + $value) $Width))
        }
    }
    return $rows.ToArray()
}

function Get-AlarmUiBorder {
    param([int] $Width, [string] $Title = '', [switch] $Bottom)
    $left = if ($Bottom) { [char]0x2514 } else { [char]0x250c }
    $right = if ($Bottom) { [char]0x2518 } else { [char]0x2510 }
    $label = if ($Title -and -not $Bottom) { Format-TuiFit (' ' + $Title + ' ') ($Width - 2) } else { '' }
    return Format-TuiAnsiText ($left + $label + ([string][char]0x2500 * [Math]::Max(0, $Width - 2 - $label.Length)) + $right) -Foreground '#606b75'
}

function Get-AlarmUiRow {
    param([int] $Width, [string] $Text, [string] $Color = '#cbd2da', [switch] $Bold)
    $edge = Format-TuiAnsiText ([string][char]0x2502) -Foreground '#606b75'
    $body = (Format-TuiFit (ConvertTo-AlarmUiText $Text) ($Width - 4)).PadRight($Width - 4)
    return $edge + ' ' + (Format-TuiAnsiText $body -Foreground $Color -Bold:$Bold) + ' ' + $edge
}

function Get-AlarmUiEventText {
    param([object] $Item)
    $event = [string](Get-AlarmUiValue $Item 'Event')
    $message = switch -Wildcard ($event) {
        'Armed' { 'Monitoring enabled' }
        'Pending' { 'AC lost while locked; countdown started' }
        'SILENT ALARM*' { 'Historical two-second condition recorded' }
        'Alarm' { 'Two seconds elapsed; alarm activated' }
        'WaitingForPower' { 'Waiting for AC reconnection' }
        'Unknown' { 'Windows or AC unknown; alarm stopped' }
        'Disabled' { 'Monitoring disabled' }
        default { $event }
    }
    $ac = [string](Get-AlarmUiValue $Item 'Ac')
    $lock = [string](Get-AlarmUiValue $Item 'LockState')
    if ($ac -or $lock) { $message += ('  |  {0}, {1}' -f $ac, $lock) }
    return (Get-AlarmUiTime (Get-AlarmUiValue $Item 'AtUtc')) + '  ' + (ConvertTo-AlarmUiText $message)
}

function Get-AlarmUiFrame {
    param([object] $Report, [object[]] $Events = @(), [int] $Selected = 0,
        [int] $Width = 100, [int] $Height = 29, [switch] $Live, [switch] $LogsOnly,
        [int] $LogOffset = 0, [string] $Notice = '', [object] $Observation, [switch] $StatusOnly)
    $Width = [Math]::Max(1, $Width); $Height = [Math]::Max(1, $Height)
    $Selected = [Math]::Max(0, [Math]::Min(1, $Selected))
    $Events = @($Events | Where-Object { $null -ne $_ })
    $p = Get-AlarmUiPresentation $Report -Live:$Live -Observation $Observation
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add((Format-TuiAnsiText (Format-TuiFit ' tukevejtso / Computer alarm' $Width) -Foreground '#92d5df' -Bold))
    $preview = (Get-AlarmUiValue $Report 'Preview' $false) -eq $true
    $subtitle = if ($preview) { ' INTERFACE PREVIEW / sample data / monitor disabled' } else { ' Locked Windows + new AC loss + 2 seconds' }
    if ($Height -ge 14) { $lines.Add((Format-TuiAnsiText (Format-TuiFit $subtitle $Width) -Foreground '#9aa4ae')) }
    $menu = -not $Live -and -not $LogsOnly -and -not $StatusOnly
    $compact = $Width -lt 60 -or $Height -lt 25
    $graphic = -not $compact -and -not $LogsOnly -and $Width -ge 86
    $delay = 'Delay: 2.0s | Triggers: ' + (Get-AlarmUiValue $Report 'TriggerCount' 0)
    if ($p.RemainingText) { $delay += ' | ' + $p.RemainingText }
    $last = if (Get-AlarmUiValue $Report 'LastTriggerUtc') {
        (Get-AlarmUiTime (Get-AlarmUiValue $Report 'LastTriggerUtc')) + ' (local)'
    } else { 'none' }
    $delayWidth = if ($compact) { $Width - 1 } elseif ($graphic) { $Width - 28 } else { $Width - 4 }
    $delayWithLast = $delay + ' | Last alarm: ' + $last
    if ((ConvertTo-AlarmUiText $delayWithLast).Length -le $delayWidth) { $delay = $delayWithLast }
    if ($compact) {
        $lines.Add((Format-TuiAnsiText (Format-TuiFit (ConvertTo-AlarmUiText (' ' + $p.Label)) $Width) -Foreground $p.Color -Bold))
        if ($Height -ge 12) { $lines.Add((Format-TuiFit ' Output: soft start; max in 15s' $Width)) }
        foreach ($row in @(Get-AlarmUiFlagRows $p ([Math]::Max(1, $Width - 1)))) {
            $lines.Add((Format-TuiFit (' ' + $row) $Width))
        }
        $lines.Add((Format-TuiAnsiText (Format-TuiFit (ConvertTo-AlarmUiText (' ' + $p.AlarmSource)) $Width) -Foreground '#9aa4ae'))
        foreach ($row in @(Get-AlarmUiFlagRows $p ([Math]::Max(1, $Width - 1)) -Hardware)) {
            $lines.Add((Format-TuiFit (' ' + $row) $Width))
        }
        $lines.Add((Format-TuiAnsiText (Format-TuiFit (ConvertTo-AlarmUiText (' ' + $p.HardwareSource)) $Width) -Foreground '#9aa4ae'))
        $lines.Add((Format-TuiFit (ConvertTo-AlarmUiText (' ' + $delay)) $Width))
        $lines.Add((Format-TuiFit (ConvertTo-AlarmUiText (' ' + $p.Hint)) $Width))
        if ($p.HardwareFailure -and -not $Notice) { $Notice = 'Hardware: ' + $p.HardwareFailure }
        if ($Notice) { $lines.Add((Format-TuiFit (ConvertTo-AlarmUiText (' ' + $Notice)) $Width)) }
        $lines.Add((Format-TuiFit ' Recent events (local time)' $Width))
        $reserved = if ($Live -or $menu) { 2 } else { 1 }
        $logRows = [Math]::Max(0, $Height - $lines.Count - $reserved)
        $logRows = [Math]::Min($(if ($LogsOnly) { 40 } else { 6 }), $logRows)
        $end = [Math]::Min($Events.Count, [Math]::Max($logRows, $Events.Count - $LogOffset))
        $start = [Math]::Max(0, $end - $logRows)
        for ($index = $start; $index -lt $end; $index++) {
            $lines.Add((Format-TuiFit (' ' + (Get-AlarmUiEventText $Events[$index])) $Width))
        }
        if ($Events.Count -eq 0 -and $logRows -gt 0) { $lines.Add((Format-TuiFit ' No recorded events.' $Width)) }
        if ($menu) {
            $action = @('A Enable alarm', 'J Saved journal')[$Selected]
            $lines.Add((Format-TuiAnsiText (Format-TuiFit (' > ' + $action + '   [A/J]') $Width) -Foreground '#e7be72' -Bold))
        }
    } else {
        $lines.Add('')
        $panelWidth = if ($graphic) { $Width - 24 } else { $Width }
        $panel = New-Object 'System.Collections.Generic.List[string]'
        $panel.Add((Get-AlarmUiBorder $panelWidth 'Protection'))
        $panel.Add((Get-AlarmUiRow $panelWidth $p.Label $p.Color -Bold))
        $panel.Add((Get-AlarmUiRow $panelWidth 'Output / soft start; max in 15s / siren + voice'))
        foreach ($row in @(Get-AlarmUiFlagRows $p ($panelWidth - 4))) {
            $panel.Add((Get-AlarmUiRow $panelWidth $row))
        }
        $panel.Add((Get-AlarmUiRow $panelWidth $p.AlarmSource '#9aa4ae'))
        foreach ($row in @(Get-AlarmUiFlagRows $p ($panelWidth - 4) -Hardware)) {
            $panel.Add((Get-AlarmUiRow $panelWidth $row))
        }
        $panel.Add((Get-AlarmUiRow $panelWidth $p.HardwareSource '#9aa4ae'))
        $panel.Add((Get-AlarmUiRow $panelWidth $delay))
        $panel.Add((Get-AlarmUiRow $panelWidth $p.Hint $p.Color))
        $panel.Add((Get-AlarmUiBorder $panelWidth -Bottom))
        $icon = @()
        if ($graphic) { $icon = @(Get-AlarmUiPadlock $p.Color) }
        for ($row = 0; $row -lt $panel.Count; $row++) {
            $line = $panel[$row]
            if ($row -lt $icon.Count) { $line += '    ' + $icon[$row] }
            $lines.Add($line)
        }
        if ($p.HardwareFailure -and -not $Notice) { $Notice = 'Hardware: ' + $p.HardwareFailure }
        if ($Notice) { $lines.Add((Format-TuiAnsiText (Format-TuiFit (' ' + (ConvertTo-AlarmUiText $Notice)) $Width) -Foreground '#e7be72')) }
        $lines.Add('')
        $reserved = if ($Live) { 2 } elseif ($menu) { 5 } else { 1 }
        $logRows = [Math]::Max(1, $Height - $lines.Count - $reserved - 2)
        $logRows = [Math]::Min($(if ($LogsOnly) { 40 } else { 6 }), $logRows)
        $lines.Add((Get-AlarmUiBorder $Width 'Recent events / local time'))
        $end = [Math]::Min($Events.Count, [Math]::Max($logRows, $Events.Count - $LogOffset))
        $start = [Math]::Max(0, $end - $logRows)
        if ($Events.Count -eq 0) { $lines.Add((Get-AlarmUiRow $Width 'No recorded events. Opening this screen does not enable the alarm.' '#9aa4ae')) }
        else {
            for ($index = $start; $index -lt $end; $index++) {
                $color = if ((Get-AlarmUiValue $Events[$index] 'Event') -match 'ALARM|^Alarm$') { '#f08b7c' } else { '#b6bfc8' }
                $lines.Add((Get-AlarmUiRow $Width (Get-AlarmUiEventText $Events[$index]) $color))
            }
        }
        $lines.Add((Get-AlarmUiBorder $Width -Bottom))
        if ($menu) {
            $lines.Add('')
            $actions = @('[A] Enable alarm', '[J] View saved journal')
            for ($index = 0; $index -lt $actions.Count; $index++) {
                $prefix = if ($index -eq $Selected) { ' > ' } else { '   ' }
                $lines.Add((Format-TuiAnsiText (Format-TuiFit ($prefix + $actions[$index]) $Width) -Foreground $(if ($index -eq $Selected) { '#e7be72' } else { '#cbd2da' }) -Bold:($index -eq $Selected)))
            }
            $detail = @('Soft start; max in 15s. Typed confirmation required.', 'Browse saved events without enabling the alarm.')[$Selected]
            $lines.Add((Format-TuiAnsiText (Format-TuiFit (' ' + $detail) $Width) -Foreground '#9aa4ae'))
        }
    }
    if ($Live) {
        $lines.Add((Format-TuiAnsiText (Format-TuiFit ' Reconnect AC or unlock to stop. Keep this window open.' $Width) -Foreground '#9aa4ae'))
    }
    $keys = if ($StatusOnly) { ' tk alarm Open dashboard   tk alarm logs Browse saved events' }
        elseif ($Live) { ' Q/Esc Disable (while unlocked)   Ctrl+C Stop' }
        elseif ($LogsOnly) { ' Up/Down Scroll   Home/End Oldest/newest   R Refresh   Q/Esc Back' }
        else { ' Up/Down Select   Enter Open   A/J   R Refresh   H Help   Q/Esc Back' }
    if ($Width -lt 70) {
        $keys = if ($StatusOnly) { ' tk alarm Open  tk alarm logs Journal' }
            elseif ($Live) { ' Q/Esc Disable (unlocked)  Ctrl+C Stop' }
            elseif ($LogsOnly) { ' Up/Down Scroll  R Refresh  Q Back' }
            else { ' A/J Open  R Refresh  Q/Esc Back' }
    }
    $lines.Add((Format-TuiAnsiText (Format-TuiFit $keys $Width) -Foreground '#8ab8c0'))
    # Preserve the controls on exceptionally small terminals.
    if ($lines.Count -gt $Height) {
        $visible = @($lines | Select-Object -First ([Math]::Max(0, $Height - 1)))
        return @($visible) + @($lines[$lines.Count - 1])
    }
    return $lines.ToArray()
}

function Write-AlarmUiDashboard {
    param([object] $Report, [object[]] $Events = @(), [int] $Selected = 0,
        [switch] $Live, [switch] $LogsOnly, [int] $LogOffset = 0, [string] $Notice = '',
        [object] $Observation, [switch] $StatusOnly)
    $dimensions = Get-AlarmUiDimensions
    $frame = Get-AlarmUiFrame -Report $Report -Events $Events -Selected $Selected -Width $dimensions.Width -Height $dimensions.Height -Live:$Live -LogsOnly:$LogsOnly -LogOffset $LogOffset -Notice $Notice -Observation $Observation -StatusOnly:$StatusOnly
    if ([Console]::IsOutputRedirected) {
        foreach ($line in $frame) { Write-Host (Remove-TuiAnsi $line) }
    } else {
        Write-TuiFrame -Lines $frame -Initial:(-not $script:AlarmUiDrawn)
        $script:AlarmUiDrawn = $true
    }
}

function Update-AlarmUiLive {
    param([object] $Report, [string] $Notice = '', [object] $Observation)
    if (-not $script:AlarmUiActive -or $script:AlarmUiFailed) { return }
    try { Write-AlarmUiDashboard -Report $Report -Events $script:AlarmUiEvents.ToArray() -Live -Notice $Notice -Observation $Observation }
    catch {
        $script:AlarmUiFailed = $true
        try { Show-TuiCursor } catch { }
        try { Write-Warning 'Dashboard unavailable; plain event logging continues.' } catch { }
    }
}
