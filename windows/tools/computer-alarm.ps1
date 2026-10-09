[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateSet('menu', 'status', 'logs', 'preview', 'arm', 'help')]
    [string] $Action = 'menu',
    [ValidateSet('loud')]
    [string] $Output = 'loud',
    [string] $EndpointId
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'computer-alarm-ui.ps1')
Set-StrictMode -Version 2.0
$script:AlarmDirectory = Join-Path $env:LOCALAPPDATA 'tukevejtso'
$script:AlarmStatePath = Join-Path $script:AlarmDirectory 'computer-alarm-state.json'
$script:AlarmEventsPath = Join-Path $script:AlarmDirectory 'computer-alarm-events.jsonl'

function Show-AlarmHelp {
    Write-Host 'Computer alarm - two seconds after AC loss while Windows is locked' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'tk alarm                       Open the alarm dashboard'
    Write-Host 'tk alarm status                Show power/lock flags and the latest alarm report'
    Write-Host 'tk alarm logs                  Browse the saved event journal'
    Write-Host 'tk alarm preview               Show a static interface preview'
    Write-Host 'tk alarm arm                   Confirm and enable the siren and spoken warning'
    Write-Host ''
    Write-Host 'The alarm requires Windows locked and AC absent for two seconds.'
    Write-Host 'Reconnecting AC or unlocking Windows stops it and resets the delay.'
    Write-Host 'Only AC availability is used. A genuine outage can also trigger it.'
    Write-Host 'The dashboard shows Enabled, Windows locked, AC online, Battery present, Countdown pending, and Alarm active flags.'
    Write-Host 'Opening the dashboard only reads power and lock state. It does not enable the alarm.'
    Write-Host 'The alarm alternates siren bursts with a spoken instruction to reconnect power.'
    Write-Host 'The police-notification sentence is a deterrent message only; no call is made.'
    Write-Host 'Keep this monitor open. Q/Esc while unlocked, or Ctrl+C, disables it.'
    Write-Host 'The console is hidden by the Windows lock screen; inspect the event times after unlocking.'
    Write-Host 'There is no automatic startup or installed service.'
}

function Show-AlarmStatus {
    $observer = $null; $observationFailure = ''
    try {
        try { $observer = New-AlarmObserver } catch { $observationFailure = $_.Exception.Message }
        $observation = Get-AlarmObservation $observer $observationFailure
        Write-AlarmUiDashboard -Report (Get-AlarmUiReport $script:AlarmStatePath) -Observation $observation -Events @(Get-AlarmUiEvents $script:AlarmEventsPath) -LogsOnly -StatusOnly
    } finally {
        if ($null -ne $observer) { try { $observer.Dispose() } catch { } }
        Show-TuiCursor
    }
    Write-Host ''
    Write-Host ('Event journal: ' + $script:AlarmEventsPath) -ForegroundColor DarkGray
}

function Show-AlarmPreview {
    $report = [pscustomobject]@{ Version = 2; Preview = $true; Running = $false; Output = 'loud'; Phase = 'Disabled'; AlarmActive = $false; Ac = 'Online'; LockState = 'Unlocked'; BatteryKnown = $true; HasBattery = $true; TriggerCount = 0; UpdatedUtc = ''; LastTriggerUtc = ''; Error = '' }
    $observation = [pscustomobject]@{ Source = 'sample'; ObservedUtc = ''; LockState = 'Unlocked'; Ac = 'Online'; BatteryKnown = $true; HasBattery = $true; Failure = '' }
    $events = @(
        [pscustomobject]@{ Version = 2; AtUtc = ''; Event = 'Sample: AC connected'; Ac = ''; LockState = '' },
        [pscustomobject]@{ Version = 2; AtUtc = ''; Event = 'Sample: Windows unlocked'; Ac = ''; LockState = '' },
        [pscustomobject]@{ Version = 2; AtUtc = ''; Event = 'Sample: monitoring disabled'; Ac = ''; LockState = '' }
    )
    try { Write-AlarmUiDashboard -Report $report -Observation $observation -Events $events }
    finally { Show-TuiCursor }
    Write-Host ''
}

function Show-AlarmJournal {
    $offset = 0; $refresh = $true
    try {
        while ($true) {
            if ($refresh) {
                $report = Get-AlarmUiReport $script:AlarmStatePath
                $events = @(Get-AlarmUiEvents $script:AlarmEventsPath)
                $offset = [Math]::Min($offset, [Math]::Max(0, $events.Count - 1))
                $refresh = $false
            }
            Write-AlarmUiDashboard -Report $report -Events $events -LogsOnly -LogOffset $offset
            if ([Console]::IsInputRedirected) { return }
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'Q' { return }
                'Escape' { return }
                'UpArrow' { $offset = [Math]::Min([Math]::Max(0, $events.Count - 1), $offset + 1) }
                'DownArrow' { $offset = [Math]::Max(0, $offset - 1) }
                'Home' { $offset = [Math]::Max(0, $events.Count - 1) }
                'End' { $offset = 0 }
                'R' { $refresh = $true }
            }
        }
    } finally { Show-TuiCursor }
}

function Show-AlarmMenu {
    $selected = 0; $notice = ''; $observer = $null; $observationFailure = ''
    $clock = [Diagnostics.Stopwatch]::StartNew(); $lastDraw = -10.0; $lastJournal = -10.0
    try {
        try { $observer = New-AlarmObserver } catch { $observationFailure = $_.Exception.Message }
        $events = @()
        while ($true) {
            $now = $clock.Elapsed.TotalSeconds
            if ($now - $lastDraw -ge 0.4) {
                $report = Get-AlarmUiReport $script:AlarmStatePath
                if ($now - $lastJournal -ge 2) { $events = @(Get-AlarmUiEvents $script:AlarmEventsPath); $lastJournal = $now }
                $observation = Get-AlarmObservation $observer $observationFailure
                Write-AlarmUiDashboard -Report $report -Observation $observation -Events $events -Selected $selected -Notice $notice
                $lastDraw = $now
            }
            if ([Console]::IsInputRedirected) { return }
            if (-not [Console]::KeyAvailable) { Start-Sleep -Milliseconds 100; continue }
            $key = [Console]::ReadKey($true)
            $action = ''
            switch ($key.Key) {
                'Q' { return }
                'Escape' { return }
                'UpArrow' { $selected = ($selected + 1) % 2 }
                'DownArrow' { $selected = ($selected + 1) % 2 }
                'Home' { $selected = 0 }
                'End' { $selected = 1 }
                'R' { $notice = ''; $lastJournal = -10.0 }
                'S' { $notice = ''; $lastJournal = -10.0 }
                'A' { $action = 'loud' }
                'L' { $action = 'loud' }
                'J' { $action = 'journal' }
                'Enter' { $action = @('loud', 'journal')[$selected] }
                'H' {
                    Show-TuiCursor; Clear-Host; Show-AlarmHelp
                    Write-Host ''; Write-Host 'Press any key to return...'
                    [void][Console]::ReadKey($true)
                    $script:AlarmUiDrawn = $false
                }
            }
            if ($action -eq 'journal') { Show-AlarmJournal }
            elseif ($action) {
                Show-TuiCursor; Clear-Host; $script:AlarmUiDrawn = $false
                # The passive observer is independent of the armed monitor.
                if ($null -ne $observer) { $observer.Dispose(); $observer = $null }
                try { Start-ComputerAlarm; $notice = 'Monitor is disabled. Review recent events below.' }
                catch { $notice = $_.Exception.Message }
                $observationFailure = ''
                try { $observer = New-AlarmObserver } catch { $observationFailure = $_.Exception.Message }
            }
            $lastDraw = -10.0; $lastJournal = -10.0
        }
    } finally {
        if ($null -ne $observer) { try { $observer.Dispose() } catch { } }
        Show-TuiCursor
    }
}

function New-AlarmObserver {
    # Read-only Windows notifications: no decision engine, audio, or awake request.
    Import-AlarmRuntime
    return New-Object ComputerAlarmNative.SessionMonitor
}

function Get-AlarmObservation {
    param([object] $Observer, [string] $Failure = '')
    $lock = 'Unknown'; $ac = 'Unknown'; $batteryKnown = $false; $hasBattery = $false
    if ($null -ne $Observer) {
        if ($Observer.Failure) { $Failure = $Observer.Failure }
        else { $lock = $Observer.State.ToString() }
    }
    try {
        $power = [ComputerAlarmNative.Power]::ReadStatus()
        $ac = $power.Ac.ToString(); $batteryKnown = $power.BatteryKnown; $hasBattery = $power.HasBattery
    } catch { $Failure = $_.Exception.Message }
    return [pscustomobject]@{ Source = 'live'; ObservedUtc = [DateTimeOffset]::UtcNow.ToString('o'); LockState = $lock; Ac = $ac; BatteryKnown = $batteryKnown; HasBattery = $hasBattery; Failure = $Failure }
}

function Import-AlarmRuntime {
    if ($null -eq ('ComputerAlarmLogic.AlarmEngine' -as [type])) {
        $assemblyPath = Join-Path $PSScriptRoot 'computer-alarm\bin\ComputerAlarm.dll'
        if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
            throw 'The compiled alarm helper is missing. Build it in the managed Debian container as described in computer-alarm.md.'
        }
        # Load the container-built assembly. Never compile on the Windows host.
        [void][Reflection.Assembly]::LoadFrom($assemblyPath)
    }
}

function Write-AlarmEvent {
    param([string] $Event, [double] $Now, [string] $LockState, [string] $Ac, [object] $Snapshot)
    [void][IO.Directory]::CreateDirectory($script:AlarmDirectory)
    $item = [ordered]@{
        Version = 2; AtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        ProcessId = $PID; Output = $Output; Event = $Event
        ElapsedSeconds = [Math]::Round($Now, 3); LockState = $LockState; Ac = $Ac
        AlarmActive = $Snapshot.AlarmActive; DelayRemainingSeconds = $Snapshot.DelayRemainingSeconds
    }
    Add-AlarmUiEvent ([pscustomobject]$item)
    if (-not $script:AlarmUiActive -or $script:AlarmUiFailed) {
        $color = if ($Snapshot.AlarmActive) { 'Yellow' } else { 'Cyan' }
        Write-Host ('[{0:HH:mm:ss.fff} UTC] {1} | AC: {2} | Windows: {3}' -f [DateTimeOffset]::UtcNow, $Event, $Ac, $LockState) -ForegroundColor $color
    }
    $item | ConvertTo-Json -Compress | Add-Content -LiteralPath $script:AlarmEventsPath -Encoding UTF8
}

function Save-AlarmReport {
    param([string] $Phase, [bool] $Running, [bool] $AlarmActive, [string] $LockState, [string] $Ac,
        [int] $TriggerCount, [string] $LastTriggerUtc, [double] $LastTriggerDelay, [string] $Failure,
        [object] $PowerStatus, [object] $DelayRemaining)
    [void][IO.Directory]::CreateDirectory($script:AlarmDirectory)
    [ordered]@{
        Version = 2; UpdatedUtc = [DateTimeOffset]::UtcNow.ToString('o'); ProcessId = $PID
        Running = $Running; Output = $Output; Phase = $Phase; AlarmActive = $AlarmActive
        LockState = $LockState; Ac = $Ac; DelaySeconds = 2; TriggerCount = $TriggerCount
        BatteryKnown = $null -ne $PowerStatus -and $PowerStatus.BatteryKnown
        HasBattery = $null -ne $PowerStatus -and $PowerStatus.HasBattery
        DelayRemainingSeconds = $DelayRemaining
        LastTriggerUtc = $LastTriggerUtc; LastTriggerDelaySeconds = $LastTriggerDelay; Error = $Failure
    } | ConvertTo-Json | Set-Content -LiteralPath $script:AlarmStatePath -Encoding UTF8
}

function Start-ComputerAlarm {
    if ([Console]::IsInputRedirected) { throw 'Enable the alarm from an interactive terminal so you can confirm it manually.' }
    $session = $null; $audio = $null; $mutex = $null
    $ownsMutex = $false; $awake = $false; $audioPlaying = $false; $enabled = $false
    $speakerId = ''; $failure = ''; $lastTriggerUtc = ''; $lastTriggerDelay = 0.0
    $triggerCount = 0; $lockState = 'Unknown'; $ac = 'Unknown'
    $power = $null
    $script:AlarmUiActive = $false; $script:AlarmUiFailed = $false
    try {
        Import-AlarmRuntime
        $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        $mutex = New-Object Threading.Mutex($false, ('Local\tukevejtso-computer-alarm-' + $sessionId))
        try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { throw 'A monitor is already enabled in this Windows session. Disable it from its window first.' }
        $session = New-Object ComputerAlarmNative.SessionMonitor
        $lockState = $session.State.ToString()
        $power = [ComputerAlarmNative.Power]::ReadStatus(); $ac = $power.Ac.ToString()
        if ($lockState -ne 'Unlocked') { throw 'Enable from an unlocked Windows session.' }
        if ($ac -ne 'Online') { throw 'Connect the charger before enabling so the monitor can observe a real AC-loss transition.' }
        if (-not $power.BatteryKnown -or -not $power.HasBattery) { throw 'A known battery is required to keep the monitor running after AC loss.' }

        if ($Output -eq 'loud') {
            $endpoints = @([ComputerAlarmNative.Audio]::ListEndpoints() | Where-Object { $_.IsSpeakers })
            if ($endpoints.Count -eq 0) { throw 'No active Speakers output was found.' }
            if ($EndpointId) {
                $matches = @($endpoints | Where-Object { $_.Id -eq $EndpointId })
                if ($matches.Count -ne 1) { throw 'EndpointId must identify one active Speakers output.' }
                $speaker = $matches[0]
            } elseif ($endpoints.Count -eq 1) { $speaker = $endpoints[0] }
            else {
                for ($i = 0; $i -lt $endpoints.Count; $i++) { Write-Host ('{0}. {1}' -f ($i + 1), $endpoints[$i].Name) }
                $choice = 0
                if (-not [int]::TryParse((Read-Host 'Speaker number; blank cancels'), [ref]$choice) -or $choice -lt 1 -or $choice -gt $endpoints.Count) { return }
                $speaker = $endpoints[$choice - 1]
            }
            $speakerId = $speaker.Id
            Write-Host ('Full-volume siren and spoken warning: ' + $speaker.Name) -ForegroundColor Yellow
            Write-Host 'A genuine power outage while locked can trigger this alarm.'
            Write-Host ([ComputerAlarmNative.Audio]::WarningText)
            Write-Host 'The police-notification sentence is a bluff; this tool does not contact anyone.' -ForegroundColor DarkGray
            if ((Read-Host 'Type ARM LOUD ALARM to enable; anything else cancels') -cne 'ARM LOUD ALARM') { return }
            $audio = New-Object ComputerAlarmNative.Audio
            Write-Host 'Preparing the spoken warning in memory. No sound is played while enabling.' -ForegroundColor DarkGray
            $audio.PrepareVoice()
            Write-Host ('Prepared English voice: ' + $audio.VoiceName) -ForegroundColor DarkGray
        }
        $lockState = $session.State.ToString()
        $power = [ComputerAlarmNative.Power]::ReadStatus(); $ac = $power.Ac.ToString()
        if ($lockState -ne 'Unlocked' -or $ac -ne 'Online' -or -not $power.BatteryKnown -or -not $power.HasBattery) {
            throw 'Windows lock, AC, or battery state changed during confirmation. Unlock and reconnect with a known battery before enabling.'
        }
        $engine = New-Object ComputerAlarmLogic.AlarmEngine($lockState, $ac, $session.UnlockGeneration)
        [ComputerAlarmNative.Power]::KeepAwake(); $awake = $true
        $enabled = $true
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $previousPhase = ''; $previousLock = ''; $previousAc = ''; $previousActive = $false
        $lastReport = -10.0; $lastAwake = 0.0; $logWarning = $false; $lastUi = -10.0
        $script:AlarmUiEvents.Clear()
        foreach ($item in @(Get-AlarmUiEvents $script:AlarmEventsPath)) { Add-AlarmUiEvent $item }
        $script:AlarmUiActive = -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
        $script:AlarmUiDrawn = $false
        Write-Host ('ENABLED - {0}. Lock Windows, unplug for more than two seconds, then reconnect.' -f $Output.ToUpperInvariant()) -ForegroundColor Green
        Write-Host 'Unlock afterward to inspect the timestamped results. Q/Esc or Ctrl+C disables the monitor.'
        while ($true) {
            $now = $clock.Elapsed.TotalSeconds
            if ($session.Failure) { throw ('Windows lock monitoring failed: ' + $session.Failure) }
            $lockState = $session.State.ToString()
            $power = [ComputerAlarmNative.Power]::ReadStatus(); $ac = $power.Ac.ToString()
            $snapshot = $engine.Update($now, $lockState, $ac, $session.UnlockGeneration)
            if (-not $snapshot.AlarmActive -and $audioPlaying) {
                $audio.Stop(); $audioPlaying = $false
                if ($audio.Failure) { $failure = $audio.Failure; Write-Warning $failure }
            }
            if ($snapshot.AlarmActive -and -not $previousActive) {
                $recordTrigger = $false
                if ($Output -eq 'loud') {
                    if ($audio.Start($speakerId, $session)) { $audioPlaying = $true; $recordTrigger = $true }
                    else {
                        $engine.Invalidate()
                        $now = $clock.Elapsed.TotalSeconds
                        $lockState = $session.State.ToString()
                        $power = [ComputerAlarmNative.Power]::ReadStatus(); $ac = $power.Ac.ToString()
                        $snapshot = $engine.Update($now, $lockState, $ac, $session.UnlockGeneration)
                    }
                }
                if ($recordTrigger) {
                    $triggerCount++
                    $lastTriggerUtc = [DateTimeOffset]::UtcNow.ToString('o')
                    $lastTriggerDelay = $clock.Elapsed.TotalSeconds - $snapshot.PendingSinceSeconds
                }
            }
            if ($audioPlaying) {
                if ($audio.Failure) { throw ('Speaker playback failed: ' + $audio.Failure) }
                if (-not $audio.IsPlaying) {
                    # The speaker worker can observe a reconnect/unlock between
                    # controller polls. Reflect its stop in the alarm flags too.
                    $audio.Stop(); $audioPlaying = $false
                    if ($audio.Failure) { $failure = $audio.Failure; Write-Warning $failure }
                    $engine.Invalidate()
                    $now = $clock.Elapsed.TotalSeconds
                    $lockState = $session.State.ToString()
                    $power = [ComputerAlarmNative.Power]::ReadStatus(); $ac = $power.Ac.ToString()
                    $snapshot = $engine.Update($now, $lockState, $ac, $session.UnlockGeneration)
                } else { $audio.EnsureVolume() }
            }
            $event = $snapshot.Phase
            if ($snapshot.Phase -ne $previousPhase -or $lockState -ne $previousLock -or $ac -ne $previousAc) {
                try { Write-AlarmEvent $event $now $lockState $ac $snapshot }
                catch { if (-not $logWarning) { Write-Warning 'Event/report writing failed; console monitoring continues.'; $logWarning = $true } }
            }
            if ($now - $lastReport -ge 0.5) {
                try { Save-AlarmReport $event $true $snapshot.AlarmActive $lockState $ac $triggerCount $lastTriggerUtc $lastTriggerDelay $failure $power $snapshot.DelayRemainingSeconds }
                catch { if (-not $logWarning) { Write-Warning 'Event/report writing failed; console monitoring continues.'; $logWarning = $true } }
                $lastReport = $now
            }
            if ($script:AlarmUiActive -and ($now - $lastUi -ge 0.2)) {
                $uiReport = [pscustomobject]@{
                    Version = 2; UpdatedUtc = [DateTimeOffset]::UtcNow.ToString('o')
                    Running = $true; Output = $Output; Phase = $snapshot.Phase; AlarmActive = $snapshot.AlarmActive
                    LockState = $lockState; Ac = $ac; TriggerCount = $triggerCount; LastTriggerUtc = $lastTriggerUtc
                    BatteryKnown = $power.BatteryKnown; HasBattery = $power.HasBattery
                    DelayRemainingSeconds = $snapshot.DelayRemainingSeconds; Error = $failure
                }
                $uiNotice = if ($logWarning) { 'Saving events/status failed; live monitoring continues.' } else { '' }
                Update-AlarmUiLive $uiReport -Notice $uiNotice
                $lastUi = $now
            }
            if (-not [Console]::IsInputRedirected -and $lockState -eq 'Unlocked' -and [Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Q -or $key.Key -eq [ConsoleKey]::Escape) { break }
            }
            if ($now - $lastAwake -ge 20) { [ComputerAlarmNative.Power]::KeepAwake(); $lastAwake = $now }
            $previousPhase = $snapshot.Phase; $previousLock = $lockState; $previousAc = $ac; $previousActive = $snapshot.AlarmActive
            Start-Sleep -Milliseconds 100
        }
    } catch { $failure = $_.Exception.Message; Write-Host $failure -ForegroundColor Red; throw }
    finally {
        if ($null -ne $audio) {
            try { $audio.Dispose() } catch { $failure = $_.Exception.Message; Write-Warning ('Audio cleanup: ' + $failure) }
            if ($audio.Failure) { $failure = $audio.Failure; Write-Warning ('Audio report: ' + $failure) }
        }
        if ($null -ne $session) { try { $session.Dispose() } catch { Write-Warning 'Lock monitor cleanup failed.' } }
        if ($awake) { try { [ComputerAlarmNative.Power]::AllowSleep() } catch { Write-Warning 'Could not release the awake request.' } }
        if ($ownsMutex) {
            try { Save-AlarmReport 'Disabled' $false $false $lockState $ac $triggerCount $lastTriggerUtc $lastTriggerDelay $failure $power $null } catch { Write-Warning 'Could not save the disabled state.' }
            try { $mutex.ReleaseMutex() } catch { Write-Warning 'Could not release the monitor mutex.' }
        }
        if ($null -ne $mutex) { $mutex.Dispose() }
        if ($enabled) {
            # Record the shutdown without changing the last running heartbeat.
            try {
                $item = [pscustomobject]@{ Version = 2; AtUtc = [DateTimeOffset]::UtcNow.ToString('o'); ProcessId = $PID; Output = $Output; Event = 'Disabled'; LockState = $lockState; Ac = $ac; AlarmActive = $false }
                Add-AlarmUiEvent $item
                $item | ConvertTo-Json -Compress | Add-Content -LiteralPath $script:AlarmEventsPath -Encoding UTF8
            } catch { }
        }
        $uiReport = [pscustomobject]@{ Version = 2; UpdatedUtc = [DateTimeOffset]::UtcNow.ToString('o'); Running = $false; Output = $Output; Phase = 'Disabled'; AlarmActive = $false; LockState = $lockState; Ac = $ac; BatteryKnown = $null -ne $power -and $power.BatteryKnown; HasBattery = $null -ne $power -and $power.HasBattery; TriggerCount = $triggerCount; LastTriggerUtc = $lastTriggerUtc; Error = $failure }
        Update-AlarmUiLive $uiReport
        $script:AlarmUiActive = $false
        try { Show-TuiCursor } catch { }
        Write-Host ''
        Write-Host ('DISABLED. Trigger count: {0}; last observed delay: {1:0.000}s' -f $triggerCount, $lastTriggerDelay)
    }
}

switch ($Action) {
    'help' { Show-AlarmHelp }
    'status' { Show-AlarmStatus }
    'logs' { Show-AlarmJournal }
    'preview' { Show-AlarmPreview }
    'arm' { Start-ComputerAlarm }
    'menu' { Show-AlarmMenu }
}
