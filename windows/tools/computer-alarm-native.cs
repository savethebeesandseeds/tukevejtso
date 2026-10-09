// Build this helper inside the managed Linux development container. Windows
// PowerShell loads the prebuilt .NET Framework DLL; it does not compile source.
// Silent mode never constructs Audio or writes any speaker setting.
// No installation, startup task, default-output changes, microphone, or network use.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace ComputerAlarmNative
{
    public enum AcState { Unknown, Online, Offline }
    public enum LockState { Unknown, Locked, Unlocked }

    public sealed class PowerStatus
    {
        public AcState Ac { get; internal set; }
        public bool BatteryKnown { get; internal set; }
        public bool HasBattery { get; internal set; }
        public int BatteryPercent { get; internal set; }
    }

    public static class Power
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct SystemPowerStatus
        {
            public byte AcLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag;
            public uint BatteryLifeTime, BatteryFullLifeTime;
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetSystemPowerStatus(out SystemPowerStatus status);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint SetThreadExecutionState(uint flags);

        public static PowerStatus ReadStatus()
        {
            SystemPowerStatus status;
            if (!GetSystemPowerStatus(out status))
                return new PowerStatus { Ac = AcState.Unknown, BatteryKnown = false, BatteryPercent = -1 };
            return new PowerStatus {
                Ac = status.AcLineStatus == 1 ? AcState.Online :
                     status.AcLineStatus == 0 ? AcState.Offline : AcState.Unknown,
                BatteryKnown = status.BatteryFlag != 255,
                HasBattery = status.BatteryFlag != 255 && (status.BatteryFlag & 128) == 0,
                BatteryPercent = status.BatteryLifePercent <= 100 ? status.BatteryLifePercent : -1
            };
        }
        public static AcState ReadAc() { return ReadStatus().Ac; }
        public static bool HasBattery() { return ReadStatus().HasBattery; }

        // Both calls must be made on the SAME controller thread. Only idle sleep is
        // prevented: explicit sleep, lid policy, shutdown and critical battery remain.
        public static void KeepAwake()
        {
            if (SetThreadExecutionState(0x80000001) == 0)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not prevent idle sleep.");
        }
        public static void AllowSleep()
        {
            if (SetThreadExecutionState(0x80000000) == 0)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not clear the idle-sleep request.");
        }
    }

    public sealed class SessionMonitor : IDisposable
    {
        // Layout follows WtsApi32.h (Unicode, default 8-byte packing). The union
        // after Level contains only level 1, whose LARGE_INTEGER fields align to 8.
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 8)]
        private struct WtsInfoExLevel1
        {
            public uint SessionId;
            public int SessionState, SessionFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 33)] public string WinStationName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 21)] public string UserName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 18)] public string DomainName;
            public long LogonTime, ConnectTime, DisconnectTime, LastInputTime, CurrentTime;
            public uint IncomingBytes, OutgoingBytes, IncomingFrames, OutgoingFrames;
            public uint IncomingCompressedBytes, OutgoingCompressedBytes;
        }
        [StructLayout(LayoutKind.Sequential, Pack = 8)]
        private struct WtsInfoEx { public uint Level; public WtsInfoExLevel1 Data; }
        [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool WTSQuerySessionInformationW(IntPtr server, int session,
            int infoClass, out IntPtr buffer, out uint bytes);
        [DllImport("wtsapi32.dll")]
        private static extern void WTSFreeMemory(IntPtr buffer);
        [DllImport("wtsapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool WTSRegisterSessionNotification(IntPtr window, uint flags);
        [DllImport("wtsapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool WTSUnRegisterSessionNotification(IntPtr window);
        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool PostMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);

        private const int StopMessage = 0x8000 + 42;
        private readonly int sessionId;
        private readonly ManualResetEvent ready = new ManualResetEvent(false);
        private readonly Thread thread;
        private int state = (int)LockState.Unknown;
        private long generation;
        private long unlockGeneration;
        private volatile string failure;
        private volatile bool stopRequested;
        private IntPtr windowHandle;
        private bool disposed;

        public SessionMonitor()
        {
            sessionId = Process.GetCurrentProcess().SessionId;
            thread = new Thread(Run);
            thread.IsBackground = true;
            thread.Name = "Computer alarm session notifications";
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
            if (!ready.WaitOne(5000))
            {
                stopRequested = true;
                if (windowHandle != IntPtr.Zero) PostMessage(windowHandle, StopMessage, IntPtr.Zero, IntPtr.Zero);
                throw new TimeoutException("Session notification window did not initialize.");
            }
            if (!String.IsNullOrEmpty(failure))
            {
                thread.Join(5000);
                throw new InvalidOperationException(failure);
            }
        }
        public LockState State { get { return stopRequested ? LockState.Unknown : (LockState)Volatile.Read(ref state); } }
        public long Generation { get { return Interlocked.Read(ref generation); } }
        // Count actual unlock notifications independently of State so a quick
        // unlock/relock between controller polls still disarms the current run.
        public long UnlockGeneration { get { return Interlocked.Read(ref unlockGeneration); } }
        public int SessionId { get { return sessionId; } }
        public string Failure { get { return failure; } }

        private void SetState(LockState value)
        {
            int previous = Interlocked.Exchange(ref state, (int)value);
            if (previous != (int)value) Interlocked.Increment(ref generation);
        }
        private LockState QueryState()
        {
            IntPtr buffer = IntPtr.Zero;
            uint bytes;
            try
            {
                if (!WTSQuerySessionInformationW(IntPtr.Zero, sessionId, 25, out buffer, out bytes) ||
                    buffer == IntPtr.Zero || bytes < Marshal.SizeOf(typeof(WtsInfoEx)))
                    return LockState.Unknown;
                WtsInfoEx info = (WtsInfoEx)Marshal.PtrToStructure(buffer, typeof(WtsInfoEx));
                if (info.Level != 1 || info.Data.SessionId != (uint)sessionId ||
                    info.Data.SessionState != 0) // WTSActive: only this connected session.
                    return LockState.Unknown;
                // Windows 7 reverses these flags; this tool targets Windows 10/11.
                return info.Data.SessionFlags == 0 ? LockState.Locked :
                       info.Data.SessionFlags == 1 ? LockState.Unlocked : LockState.Unknown;
            }
            finally { if (buffer != IntPtr.Zero) WTSFreeMemory(buffer); }
        }
        private void Run()
        {
            MessageWindow window = null;
            bool registered = false;
            try
            {
                window = new MessageWindow(this);
                windowHandle = window.Handle;
                if (!WTSRegisterSessionNotification(windowHandle, 0))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot register current-session notifications.");
                registered = true;
                SetState(QueryState());
                ready.Set();
                if (!stopRequested) Application.Run();
            }
            catch (Exception ex) { failure = ex.Message; SetState(LockState.Unknown); }
            finally
            {
                SetState(LockState.Unknown);
                if (registered && !WTSUnRegisterSessionNotification(windowHandle) && failure == null)
                    failure = "Could not unregister session notifications.";
                if (window != null) window.DestroyHandle();
                windowHandle = IntPtr.Zero;
                ready.Set();
            }
        }
        private sealed class MessageWindow : NativeWindow
        {
            private readonly SessionMonitor owner;
            public MessageWindow(SessionMonitor owner)
            {
                this.owner = owner;
                CreateHandle(new CreateParams { Caption = "Computer alarm notifications", Width = 0, Height = 0 });
            }
            protected override void WndProc(ref Message message)
            {
                if (message.Msg == StopMessage) { Application.ExitThread(); return; }
                if (message.Msg == 0x02B1 && message.LParam.ToInt64() == owner.sessionId)
                {
                    int change = message.WParam.ToInt32();
                    if (change == 7) owner.SetState(LockState.Locked);
                    else if (change == 8)
                    {
                        Interlocked.Increment(ref owner.unlockGeneration);
                        owner.SetState(LockState.Unlocked);
                    }
                    else if (change == 1 || change == 3 || change == 5)
                        owner.SetState(owner.QueryState());
                    else if (change == 2 || change == 4 || change == 6)
                        owner.SetState(LockState.Unknown);
                }
                if (message.Msg == 0x0218 && (message.WParam.ToInt32() == 7 || message.WParam.ToInt32() == 18))
                    owner.SetState(owner.QueryState());
                base.WndProc(ref message);
            }
        }
        public void Dispose()
        {
            if (disposed) return;
            stopRequested = true;
            if (windowHandle != IntPtr.Zero) PostMessage(windowHandle, StopMessage, IntPtr.Zero, IntPtr.Zero);
            if (!thread.Join(5000)) throw new TimeoutException("Session notification thread did not stop.");
            disposed = true;
            ready.Dispose();
        }
    }

    public sealed class SpeakerEndpoint
    {
        public string Id { get; internal set; }
        public string Name { get; internal set; }
        public int FormFactor { get; internal set; }
        public bool IsSpeakers { get { return FormFactor == 1; } }
        public override string ToString() { return Name + " [" + Id + "]"; }
    }

    public sealed class Audio : IDisposable
    {
        private readonly object gate = new object();
        private RunState run;
        private volatile string lastFailure;
        private bool disposed;
        private SpeechClip voiceClip;
        private SpeechPreparation preparation;

        public static string WarningText { get { return SpeechPreparation.WarningText; } }
        public string VoiceName { get { lock (gate) { return voiceClip == null ? null : voiceClip.VoiceName; } } }

        // Call only after the controller's explicit loud-mode confirmation.
        // Preparation targets an in-memory stream and never plays speech.
        public void PrepareVoice()
        {
            SpeechPreparation pending;
            lock (gate)
            {
                if (disposed) throw new ObjectDisposedException("Audio");
                if (run != null) throw new InvalidOperationException("Stop the alarm before preparing its warning voice.");
                if (voiceClip != null) return;
                if (preparation != null) throw new InvalidOperationException("Warning voice preparation is already running.");
                pending = new SpeechPreparation();
                preparation = pending;
            }
            try
            {
                SpeechClip clip = pending.Wait();
                lock (gate)
                {
                    if (disposed) throw new ObjectDisposedException("Audio");
                    if (pending.IsCancelled) throw new OperationCanceledException("Warning voice preparation was cancelled.");
                    voiceClip = clip;
                }
            }
            finally
            {
                lock (gate) { if (preparation == pending) preparation = null; }
                pending.Cancel();
            }
        }

        private sealed class RunState
        {
            public string EndpointId;
            public SessionMonitor Guard;
            public long UnlockGeneration;
            public readonly ManualResetEvent Stop = new ManualResetEvent(false);
            public readonly ManualResetEvent Ready = new ManualResetEvent(false);
            public Thread Thread;
            public volatile bool IsPlaying;
            public volatile bool Cancelled;
            public volatile string Failure;
            public int RequestVolume;
            public SpeechClip VoiceClip;
        }
        public bool IsPlaying { get { RunState current = run; return current != null && current.IsPlaying; } }
        public string Failure { get { RunState current = run; return current != null ? current.Failure : lastFailure; } }

        // Read-only: enumerates active render devices and opens property stores only.
        public static SpeakerEndpoint[] ListEndpoints()
        {
            IMMDeviceEnumerator enumerator = null;
            IMMDeviceCollection collection = null;
            List<SpeakerEndpoint> endpoints = new List<SpeakerEndpoint>();
            try
            {
                enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
                Check(enumerator.EnumAudioEndpoints(0, 1, out collection));
                uint count;
                Check(collection.GetCount(out count));
                for (uint i = 0; i < count; i++)
                {
                    IMMDevice device = null;
                    try { Check(collection.Item(i, out device)); endpoints.Add(Describe(device)); }
                    finally { Release(device); }
                }
                return endpoints.ToArray();
            }
            finally { Release(collection); Release(enumerator); }
        }
        public bool Start(string endpointId, SessionMonitor guard)
        {
            if (String.IsNullOrWhiteSpace(endpointId)) throw new ArgumentException("Choose an explicit speaker endpoint ID.");
            if (guard == null) throw new ArgumentNullException("guard");
            lock (gate)
            {
                if (disposed) throw new ObjectDisposedException("Audio");
                if (voiceClip == null)
                    throw new InvalidOperationException("Prepare an installed English warning voice before arming the loud alarm.");
                StopCore();
                lastFailure = null;
                RunState current = new RunState {
                    EndpointId = endpointId, Guard = guard, UnlockGeneration = guard.UnlockGeneration,
                    VoiceClip = voiceClip
                };
                // Fail closed before opening a stream; the worker repeats this
                // check after initialization and throughout speaker playback.
                if (!CanPlay(current))
                {
                    current.Stop.Dispose();
                    current.Ready.Dispose();
                    return false;
                }
                current.Thread = new Thread(delegate() { Render(current); });
                current.Thread.IsBackground = true;
                current.Thread.Name = "Computer alarm speaker playback";
                current.Thread.SetApartmentState(ApartmentState.STA);
                run = current;
                current.Thread.Start();
                if (!current.Ready.WaitOne(10000))
                {
                    StopCore();
                    throw new TimeoutException("Speaker playback did not initialize.");
                }
                if (!current.IsPlaying)
                {
                    if (current.Cancelled && current.Failure == null)
                    {
                        StopCore();
                        return false;
                    }
                    string error = current.Failure ?? "Speaker playback failed to start.";
                    StopCore();
                    throw new InvalidOperationException(error);
                }
                return true;
            }
        }
        public void EnsureVolume()
        {
            RunState current = run;
            if (current != null && current.IsPlaying) Interlocked.Exchange(ref current.RequestVolume, 1);
        }
        public void Stop() { lock (gate) { StopCore(); } }
        private void StopCore()
        {
            if (preparation != null) preparation.Cancel();
            RunState current = run;
            if (current == null) return;
            current.Stop.Set();
            if (!current.Thread.Join(5000))
                throw new TimeoutException("Speaker worker has not stopped; endpoint-volume restoration is pending.");
            lastFailure = current.Failure;
            run = null;
            current.Stop.Dispose();
            current.Ready.Dispose();
        }
        public void Dispose()
        {
            lock (gate) { if (disposed) return; StopCore(); disposed = true; }
        }

        private static SpeakerEndpoint Describe(IMMDevice device)
        {
            string id;
            Check(device.GetId(out id));
            IPropertyStore properties = null;
            try
            {
                Check(device.OpenPropertyStore(0, out properties));
                PropertyKey nameKey = new PropertyKey(new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), 14);
                PropertyKey formKey = new PropertyKey(new Guid("1da5d803-d492-4edd-8c23-e0c0ffee7f0e"), 0);
                string name = id;
                int form = -1;
                PropVariant value = new PropVariant();
                try
                {
                    if (properties.GetValue(ref nameKey, out value) >= 0 && value.Type == 31 && value.Pointer != IntPtr.Zero)
                        name = Marshal.PtrToStringUni(value.Pointer);
                }
                finally { PropVariantClear(ref value); }
                value = new PropVariant();
                try
                {
                    if (properties.GetValue(ref formKey, out value) >= 0 && value.Type == 19) form = (int)value.UIntValue;
                }
                finally { PropVariantClear(ref value); }
                return new SpeakerEndpoint { Id = id, Name = name, FormFactor = form };
            }
            finally { Release(properties); }
        }
        private static void Render(RunState current)
        {
            IMMDeviceEnumerator enumerator = null;
            IMMDevice device = null;
            IAudioClient client = null;
            IAudioRenderClient renderer = null;
            IAudioEndpointVolume endpointVolume = null;
            ISimpleAudioVolume sessionVolume = null;
            IntPtr formatPointer = IntPtr.Zero;
            bool volumeSaved = false;
            bool volumeChanged = false;
            bool streamStarted = false;
            float originalMaster = 0;
            bool originalMute = false;
            float[] originalChannels = null;
            Guid context = Guid.NewGuid();
            try
            {
                enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
                Check(enumerator.GetDevice(current.EndpointId, out device));
                uint state;
                Check(device.GetState(out state));
                if ((state & 1) == 0) throw new InvalidOperationException("Selected speaker endpoint is inactive.");
                SpeakerEndpoint endpoint = Describe(device);
                if (!endpoint.IsSpeakers)
                    throw new InvalidOperationException("Alarm output must be a Speakers endpoint; headphones and unknown outputs are refused.");

                object service;
                Guid iid = typeof(IAudioClient).GUID;
                Check(device.Activate(ref iid, 23, IntPtr.Zero, out service));
                client = (IAudioClient)service;
                Check(client.GetMixFormat(out formatPointer));
                WaveFormat format = (WaveFormat)Marshal.PtrToStructure(formatPointer, typeof(WaveFormat));
                ushort encoding = format.FormatTag;
                ushort validBits = format.BitsPerSample;
                if (encoding == 0xFFFE)
                {
                    if (format.ExtraSize < 22) throw new InvalidOperationException("Incomplete extensible audio format.");
                    validBits = (ushort)Marshal.ReadInt16(formatPointer, 18);
                    Guid subtype = (Guid)Marshal.PtrToStructure(IntPtr.Add(formatPointer, 24), typeof(Guid));
                    if (subtype == new Guid("00000001-0000-0010-8000-00aa00389b71")) encoding = 1;
                    else if (subtype == new Guid("00000003-0000-0010-8000-00aa00389b71")) encoding = 3;
                    else throw new InvalidOperationException("Speaker endpoint uses an unsupported audio subtype.");
                }
                bool floatSamples = encoding == 3 && format.BitsPerSample == 32;
                bool pcmSamples = encoding == 1 && (format.BitsPerSample == 16 || format.BitsPerSample == 24 || format.BitsPerSample == 32);
                if ((!floatSamples && !pcmSamples) || format.Channels < 1 || format.Channels > 8 ||
                    format.SampleRate < 8000 || format.SampleRate > 192000 ||
                    format.BlockAlign != format.Channels * (format.BitsPerSample / 8) ||
                    (!floatSamples && (validBits == 0 || validBits > format.BitsPerSample)))
                    throw new InvalidOperationException("Speaker endpoint mix format is unsupported.");
                // Shared stream, 200 ms buffering, unique nonpersistent session.
                Guid session = Guid.NewGuid();
                Check(client.Initialize(0, 0x00080000, 2000000, 0, formatPointer, ref session));
                iid = typeof(IAudioRenderClient).GUID;
                Check(client.GetService(ref iid, out service));
                renderer = (IAudioRenderClient)service;
                iid = typeof(ISimpleAudioVolume).GUID;
                Check(client.GetService(ref iid, out service));
                sessionVolume = (ISimpleAudioVolume)service;
                iid = typeof(IAudioEndpointVolume).GUID;
                Check(device.Activate(ref iid, 23, IntPtr.Zero, out service));
                endpointVolume = (IAudioEndpointVolume)service;
                Check(endpointVolume.GetMasterVolumeLevelScalar(out originalMaster));
                Check(endpointVolume.GetMute(out originalMute));
                uint channelCount;
                Check(endpointVolume.GetChannelCount(out channelCount));
                if (channelCount > 32) throw new InvalidOperationException("Endpoint has an unsupported channel count.");
                originalChannels = new float[channelCount];
                for (uint i = 0; i < channelCount; i++) Check(endpointVolume.GetChannelVolumeLevelScalar(i, out originalChannels[i]));
                volumeSaved = true; // Set before any write, so partial failures restore.
                if (!CanPlay(current)) { current.Cancelled = true; return; }

                uint bufferFrames;
                Check(client.GetBufferSize(out bufferFrames));
                byte[] buffer = new byte[checked((int)bufferFrames * format.BlockAlign)];
                ComputerAlarmAudio.AlarmSequence sequence = new ComputerAlarmAudio.AlarmSequence(
                    current.VoiceClip.CopySamples(), SpeechClip.SampleRate, (int)format.SampleRate);
                // A new envelope belongs to this playback run, not to the
                // repeating siren/voice cycle. Primed samples begin at t = 0.
                ComputerAlarmAudio.AlarmVolumeRamp envelope = new ComputerAlarmAudio.AlarmVolumeRamp((int)format.SampleRate);
                Fill(renderer, bufferFrames, buffer, format, floatSamples, validBits, sequence, envelope);
                // Audio initialization may take seconds. Recheck on the worker so
                // unlock or restored AC during that wait cannot start an alarm.
                if (!CanPlay(current)) { current.Cancelled = true; return; }
                volumeChanged = true; // Partial volume-write failures also restore.
                if (!ApplyVolumeRamp(current, endpointVolume, sessionVolume, originalMaster, originalChannels, originalMute, 0, ref context))
                { current.Cancelled = true; return; }
                if (!CanPlay(current)) { current.Cancelled = true; return; }
                Check(client.Start());
                Stopwatch playbackTimer = Stopwatch.StartNew();
                streamStarted = true;
                current.IsPlaying = true;
                current.Ready.Set();
                Stopwatch volumeTimer = Stopwatch.StartNew();
                while (!current.Stop.WaitOne(10))
                {
                    // Reconnecting AC, unlocking this session, or losing either
                    // known state stops the stream on this worker immediately.
                    // The unlock serial also catches a quick unlock/relock.
                    if (!CanPlay(current))
                    {
                        current.Cancelled = true;
                        break;
                    }
                    if (Interlocked.Exchange(ref current.RequestVolume, 0) != 0 || volumeTimer.ElapsedMilliseconds >= 50)
                    {
                        // The refresh timer may restart; playback elapsed time
                        // never does. Enforcement reapplies the current target.
                        if (!ApplyVolumeRamp(current, endpointVolume, sessionVolume, originalMaster, originalChannels,
                            originalMute, playbackTimer.Elapsed.TotalSeconds, ref context))
                        { current.Cancelled = true; break; }
                        volumeTimer.Restart();
                    }
                    uint padding;
                    Check(client.GetCurrentPadding(out padding));
                    if (padding > bufferFrames) throw new InvalidOperationException("Invalid audio buffer padding.");
                    uint available = bufferFrames - padding;
                    if (available > 0)
                    {
                        // COM volume/padding calls above can take time. Confirm
                        // the stop conditions again before submitting new audio.
                        if (!CanPlay(current)) { current.Cancelled = true; break; }
                        Fill(renderer, available, buffer, format, floatSamples, validBits, sequence, envelope);
                    }
                }
            }
            catch (Exception ex) { current.Failure = ex.Message; }
            finally
            {
                current.IsPlaying = false;
                if (streamStarted && client != null)
                    TryCleanup(current, delegate() { Check(client.Stop()); }, "stop playback");
                // Restore on the COM-owning worker, including an initialization error.
                // Hard process termination or removed hardware can defeat restoration.
                if (volumeSaved && volumeChanged && endpointVolume != null)
                {
                    // If the endpoint was muted before triggering, mute first:
                    // restoring its saved high volume must not briefly expose
                    // other applications' audio during an early cancellation.
                    if (originalMute)
                        TryCleanup(current, delegate() { Check(endpointVolume.SetMute(true, ref context)); }, "restore mute before volume");
                    TryCleanup(current, delegate() { Check(endpointVolume.SetMasterVolumeLevelScalar(originalMaster, ref context)); }, "restore master volume");
                    for (uint i = 0; i < originalChannels.Length; i++)
                    {
                        uint channel = i;
                        TryCleanup(current, delegate() { Check(endpointVolume.SetChannelVolumeLevelScalar(channel, originalChannels[channel], ref context)); }, "restore channel volume");
                    }
                    TryCleanup(current, delegate() { Check(endpointVolume.SetMute(originalMute, ref context)); }, "restore mute state");
                }
                if (formatPointer != IntPtr.Zero) Marshal.FreeCoTaskMem(formatPointer);
                Release(sessionVolume); Release(renderer); Release(endpointVolume);
                Release(client); Release(device); Release(enumerator);
                current.Ready.Set();
            }
        }
        private static bool CanPlay(RunState current)
        {
            return !current.Stop.WaitOne(0) && current.Guard.State == LockState.Locked &&
                   current.Guard.UnlockGeneration == current.UnlockGeneration && Power.ReadAc() == AcState.Offline;
        }
        private static bool ApplyVolumeRamp(RunState current, IAudioEndpointVolume endpoint, ISimpleAudioVolume session,
            float originalMaster, float[] originalChannels, bool originalMute, double elapsedSeconds, ref Guid context)
        {
            // PCM carries the deterministic 1%-to-full alarm envelope. Keep
            // this session at unity while the endpoint itself rises from its
            // saved effective settings, avoiding a sudden boost to other apps.
            if (!CanPlay(current)) return false;
            Check(session.SetMasterVolume(1.0f, ref context));
            if (!CanPlay(current)) return false;
            Check(session.SetMute(false, ref context));
            for (uint i = 0; i < originalChannels.Length; i++)
            {
                if (!CanPlay(current)) return false;
                float level = (float)ComputerAlarmAudio.AlarmVolumeRamp.EndpointLevelAtSeconds(
                    originalMute ? 0 : originalChannels[i], elapsedSeconds);
                Check(endpoint.SetChannelVolumeLevelScalar(i, level, ref context));
            }
            float master = (float)ComputerAlarmAudio.AlarmVolumeRamp.EndpointLevelAtSeconds(
                originalMute ? 0 : originalMaster, elapsedSeconds);
            if (!CanPlay(current)) return false;
            Check(endpoint.SetMasterVolumeLevelScalar(master, ref context));
            if (!CanPlay(current)) return false;
            Check(endpoint.SetMute(false, ref context));
            return true;
        }
        private static void Fill(IAudioRenderClient renderer, uint frames, byte[] buffer, WaveFormat format,
            bool floating, ushort validBits, ComputerAlarmAudio.AlarmSequence sequence, ComputerAlarmAudio.AlarmVolumeRamp envelope)
        {
            int offset = 0;
            int bytesPerSample = format.BitsPerSample / 8;
            for (uint frame = 0; frame < frames; frame++)
            {
                double sample = sequence.NextSample() * envelope.NextGain();
                // Integer extensible PCM keeps valid bits left-aligned in its container.
                long integer = floating ? 0 : (long)(sample * (Math.Pow(2, validBits - 1) - 1)) << (format.BitsPerSample - validBits);
                byte[] floatBytes = floating ? BitConverter.GetBytes((float)sample) : null;
                for (int channel = 0; channel < format.Channels; channel++)
                {
                    if (floating) { Buffer.BlockCopy(floatBytes, 0, buffer, offset, 4); offset += 4; }
                    else { for (int b = 0; b < bytesPerSample; b++) buffer[offset++] = (byte)(integer >> (8 * b)); }
                }
            }
            IntPtr destination;
            Check(renderer.GetBuffer(frames, out destination));
            bool copied = false;
            try { Marshal.Copy(buffer, 0, destination, offset); copied = true; }
            finally { Check(renderer.ReleaseBuffer(frames, copied ? 0u : 2u)); }
        }
        private static void TryCleanup(RunState current, Action action, string description)
        {
            try { action(); }
            catch (Exception ex) { current.Failure = (current.Failure == null ? "" : current.Failure + " ") + "Could not " + description + ": " + ex.Message; }
        }
        private static void Check(int result) { if (result < 0) Marshal.ThrowExceptionForHR(result); }
        private static void Release(object value)
        {
            if (value != null && Marshal.IsComObject(value))
            {
                try { Marshal.FinalReleaseComObject(value); } catch (InvalidComObjectException) { }
            }
        }

        [StructLayout(LayoutKind.Sequential, Pack = 2)]
        private struct WaveFormat
        {
            public ushort FormatTag, Channels;
            public uint SampleRate, AverageBytesPerSecond;
            public ushort BlockAlign, BitsPerSample, ExtraSize;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct PropertyKey
        {
            public Guid FormatId; public uint PropertyId;
            public PropertyKey(Guid formatId, uint propertyId) { FormatId = formatId; PropertyId = propertyId; }
        }
        // Large enough for both native architectures; only scalar/string union
        // members are used. Native PROPVARIANT data starts at byte offset 8.
        [StructLayout(LayoutKind.Explicit, Size = 24)]
        private struct PropVariant
        {
            [FieldOffset(0)] public ushort Type;
            [FieldOffset(8)] public IntPtr Pointer;
            [FieldOffset(8)] public uint UIntValue;
        }
        [DllImport("ole32.dll")]
        private static extern int PropVariantClear(ref PropVariant value);
        [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
        private class MMDeviceEnumerator { }
        [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDeviceEnumerator
        {
            [PreserveSig] int EnumAudioEndpoints(int flow, uint stateMask, out IMMDeviceCollection devices);
            [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice device);
            [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
            [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr callback);
            [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr callback);
        }
        [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-C0A13C3769E7"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDeviceCollection
        {
            [PreserveSig] int GetCount(out uint count);
            [PreserveSig] int Item(uint index, out IMMDevice device);
        }
        [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDevice
        {
            [PreserveSig] int Activate(ref Guid iid, uint context, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object result);
            [PreserveSig] int OpenPropertyStore(uint mode, out IPropertyStore properties);
            [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
            [PreserveSig] int GetState(out uint state);
        }
        [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPropertyStore
        {
            [PreserveSig] int GetCount(out uint count);
            [PreserveSig] int GetAt(uint index, out PropertyKey key);
            [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
            [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
            [PreserveSig] int Commit();
        }
        [ComImport, Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IAudioClient
        {
            [PreserveSig] int Initialize(int mode, uint flags, long duration, long periodicity, IntPtr format, ref Guid session);
            [PreserveSig] int GetBufferSize(out uint frames);
            [PreserveSig] int GetStreamLatency(out long latency);
            [PreserveSig] int GetCurrentPadding(out uint frames);
            [PreserveSig] int IsFormatSupported(int mode, IntPtr format, out IntPtr closest);
            [PreserveSig] int GetMixFormat(out IntPtr format);
            [PreserveSig] int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
            [PreserveSig] int Start();
            [PreserveSig] int Stop();
            [PreserveSig] int Reset();
            [PreserveSig] int SetEventHandle(IntPtr handle);
            [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
        }
        [ComImport, Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IAudioRenderClient
        {
            [PreserveSig] int GetBuffer(uint frames, out IntPtr data);
            [PreserveSig] int ReleaseBuffer(uint frames, uint flags);
        }
        [ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface ISimpleAudioVolume
        {
            [PreserveSig] int SetMasterVolume(float volume, ref Guid context);
            [PreserveSig] int GetMasterVolume(out float volume);
            [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid context);
            [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
        }
        [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IAudioEndpointVolume
        {
            [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
            [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
            [PreserveSig] int GetChannelCount(out uint count);
            [PreserveSig] int SetMasterVolumeLevel(float decibels, ref Guid context);
            [PreserveSig] int SetMasterVolumeLevelScalar(float volume, ref Guid context);
            [PreserveSig] int GetMasterVolumeLevel(out float decibels);
            [PreserveSig] int GetMasterVolumeLevelScalar(out float volume);
            [PreserveSig] int SetChannelVolumeLevel(uint channel, float decibels, ref Guid context);
            [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float volume, ref Guid context);
            [PreserveSig] int GetChannelVolumeLevel(uint channel, out float decibels);
            [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float volume);
            [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid context);
            [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
            [PreserveSig] int GetVolumeStepInfo(out uint step, out uint count);
            [PreserveSig] int VolumeStepUp(ref Guid context);
            [PreserveSig] int VolumeStepDown(ref Guid context);
            [PreserveSig] int QueryHardwareSupport(out uint mask);
            [PreserveSig] int GetVolumeRange(out float minimum, out float maximum, out float increment);
        }
    }
}
