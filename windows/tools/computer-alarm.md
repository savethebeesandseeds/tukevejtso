# Computer alarm

`tk alarm` opens the alarm dashboard in **System & security**. It shows six
status flags, the two-second countdown, trigger count, last alarm, and recent
events. Opening the dashboard observes power and lock state; it does not enable
the alarm, initialize audio, create an alarm engine, or request that Windows
stay awake.

The padlock uses foreground terminal characters and preserves the terminal's
existing background. Narrow or short terminals use a compact layout.

## Commands and controls

```cmd
tk alarm
tk alarm arm
tk alarm arm -EndpointId "EXACT_AUDIO_ENDPOINT_ID"
tk alarm status
tk alarm logs
tk alarm preview
tk alarm help
```

| Command or option | Behavior |
| --- | --- |
| `tk alarm` | Open the dashboard with current power and lock readings without enabling the alarm. |
| `tk alarm arm` | Offer to enable the audible alarm; requires typing `ARM LOUD ALARM`. |
| `-EndpointId` | Select one exact speaker endpoint for the alarm. |
| `-Output loud` | Accepted for compatibility; audible output is already the only output. |
| `tk alarm status` | Read power and lock hardware once, alongside saved controller flags; does not enable the alarm or initialize audio. |
| `tk alarm logs` | Browse the saved event journal without hardware queries, enabling the alarm, or writing reports. |
| `tk alarm preview` | Show a fixed sample dashboard without native runtime loading, hardware queries, audio, arming, or report writes. |

The dashboard offers **A / Enable alarm** and **J / Saved journal**. Use
**Up/Down** and **Enter** to select an action. **L** also opens Enable alarm as a
compatibility shortcut. **R** or **S** refreshes, **H** opens help, and **Q/Esc**
returns. In the journal, **Up/Down** scrolls, **Home/End** jumps to the
oldest/newest displayed entry, **R** reloads saved events, and **Q/Esc** returns.

Enabling requires Windows to report AC power connected and a battery present.
Unknown power or battery information prevents enabling. After speaker selection
and the typed confirmation, keep the foreground controller running. Closing it
disables protection. There is no persistent enabled setting, automatic startup,
scheduled task, or installed service.

## Status flags and reading sources

Each flag can be **TRUE**, **FALSE**, or **UNKNOWN**. Unknown means the tool lacks
reliable current evidence; it must not be read as False.

| Flag | Meaning |
| --- | --- |
| Enabled | The alarm controller is enabled. |
| Windows locked | The controller's Windows session is locked, as with Win+L. |
| AC online | Windows reports external power available. |
| Battery present | Windows reports a battery present. |
| Countdown pending | A valid locked-session disconnection started the two-second countdown. |
| Alarm active | The controller has activated the siren and spoken warning. |

**Hardware source** identifies **live**, **saved**, or **sample** readings.
The menu dashboard uses a read-only power and session watcher for current
Windows locked, AC online, and battery present flags. This watcher is scoped to
the dashboard and disposed when it closes. It does not create audio, an alarm
engine, or an awake request. If hardware cannot be read, unknown or saved
readings remain explicitly labeled rather than being presented as live.

Enabled, countdown pending, and alarm active belong to the controller. During
operation they come from that live controller. Elsewhere, a fresh saved report
labels them **reported**, with its report time. A stale running or unavailable
report shows **UNKNOWN** rather than asserting current protection. A stopped
report shows the controller flags as **FALSE**, labeled **reported stopped**.
Current hardware
readings alongside a saved controller report do not prove the controller is
running.

The static preview labels all data as sample. The saved journal remains a
history view. Recent events use local display time; the journal viewer loads up
to 40 valid recent entries, while the dashboard shows the entries that fit its
layout. UTC timestamps remain in the journal file.

## Trigger and stop behavior

1. Explicitly enable the alarm while AC power is connected.
2. Lock the same Windows session, for example with **Win+L**.
3. A confirmed AC-connected to AC-disconnected transition while the session is
   locked starts the fixed **two-second** countdown.
4. If the session remains locked and AC remains disconnected for the entire
   countdown, the siren and spoken warning start.
5. **Reconnect AC power or unlock the session to stop the alarm.** Either action
   also cancels a pending countdown. The controller stays enabled so a later
   valid locked-session disconnection can start a new countdown.

Unplugging while unlocked does not start the countdown. Locking an already
disconnected computer does not count as a new disconnection. Reconnect before
another locked-session removal. An unknown power or lock state cancels the
countdown and stops an active alarm.

While unlocked, press **Q** or **Esc** in the running controller to disable it.
**Ctrl+C** also requests shutdown and cleanup. Console controls are unavailable
through the Windows lock screen; reconnect AC or unlock to stop the alarm
there. The lock screen hides the terminal, so review timestamped events after
unlocking.

Saved state is local to the user in
`%LOCALAPPDATA%\tukevejtso\computer-alarm-state.json`. The local journal is
`%LOCALAPPDATA%\tukevejtso\computer-alarm-events.jsonl`. No event data is sent to
a service.

## Siren and spoken warning

The alarm repeats a **1.6-second siren burst**, a **0.2-second pause**, the
complete English warning, and a **0.4-second pause**. The siren pauses during
speech so the instruction can be understood:

> Attention. This computer has been disconnected from power. Please reconnect
> the charger to stop the alarm. If the alarm continues, the police will be
> notified.

The police-notification sentence is a deterrent bluff. The tool makes no call
or notification and does not accuse anyone of stealing.

After the typed confirmation, an installed Microsoft English desktop Windows
voice prepares the message locally into an in-memory PCM clip. Preparation does
not play it or change speaker volume. If an English voice is unavailable or
preparation fails, enabling fails with an error. No voice package is installed
automatically.

Speech and siren share the selected speaker stream and reconnect/unlock stop
checks. Speech uses Windows' [SAPI memory stream](https://learn.microsoft.com/en-ie/previous-versions/windows/desktop/ms722573%28v%3Dvs.85%29),
assigned before synthesis according to the
[SAPI output-stream documentation](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/ms723597%28v%3Dvs.85%29).

On activation, the alarm unmutes the selected speaker endpoint and raises its
master and alarm-session volumes to full. Other sound using that endpoint can
become louder. Reconnecting AC, unlocking, or normal shutdown stops playback and
attempts to restore the original endpoint volume and mute state.

Windows' speaker metadata does not establish that an output is physically
internal; combination headphone jacks can route a speaker endpoint externally.
Actual loudness depends on the hardware and Windows audio system. A crash,
forced termination, shutdown, removed hardware, or audio failure can prevent
volume restoration.

## Power signal and limitations

Windows' AC-online status is the only disconnection signal, combined with the
armed session's lock state. There are no motion modes, accelerometer checks,
acoustic Doppler probes, microphone capture, webcam checks, or Wi-Fi sensing.

AC status cannot distinguish unplugging from a building outage, failed charger,
or switched-off socket. Any can trigger after two seconds while locked. The
delay filters brief interruptions but does not establish why power disappeared.

Only the enabled controller requests that Windows remain awake. Forced sleep,
hibernation, shutdown, an exhausted battery, or terminating the controller can
defeat the alarm. It is an audible deterrent, not a hardware theft lock.

## Build and verification

The Windows PowerShell 5.1 launcher loads a prebuilt native .NET helper using
the .NET Framework included with Windows. Compile it only in the existing
managed Debian development container. From the Windows repository root:

```powershell
docker exec --user root tukevejtso bash /workspace/tukevejtso/windows/tools/setup-computer-alarm.sh
docker exec tukevejtso bash /workspace/tukevejtso/windows/tools/build-computer-alarm.sh
New-Item -ItemType Directory -Force -Path windows/tools/computer-alarm/bin | Out-Null
docker cp tukevejtso:/opt/tukevejtso-alarm-build/ComputerAlarm.dll windows/tools/computer-alarm/bin/ComputerAlarm.dll
```

Dependency setup runs as root inside Debian and installs Mono's compiler,
runtime, and Windows Forms references there. The build compiles the helper to
`/opt/tukevejtso-alarm-build/ComputerAlarm.dll` and runs decision and synthetic
sample-data tests inside the container. Those tests use numeric dummy data;
they do not execute Windows speech synthesis, native monitoring, or playback.
The Windows launcher does not compile C# or install Mono. Generated DLL output
is ignored by Git.

Historical quiet validation on 8–9 October 2026:

- The helper compiled without warnings in the managed Debian container. All
  **53 data-only checks** passed: 28 deterministic decision tests and 25
  synthetic sample-data tests for clip decoding, sequence boundaries,
  resampling, and silence gaps. No device or speech engine was used by them.
- The earlier container-built DLL loaded in Windows PowerShell 5.1. A read-only
  check reported session 1 unlocked, battery present, and AC offline; the
  session watcher disposed cleanly. No audio object was created.
- Source review confirmed memory-stream binding before speech preparation and
  shared speaker-stream/cancellation handling for speech and siren. Windows
  voice enumeration, speech preparation, playback, and volume changes were not
  executed for the voice update.

The user deferred the real **Win+L → unplug → reconnect** test and intends to
try the finished alarm later. These historical checks do not establish live
transition timing, lock-screen behavior, current voice availability, Windows
COM behavior, intelligibility, or audible cancellation. No audible tests have
been performed or authorized for Codex.
