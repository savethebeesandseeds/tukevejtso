// Late-bound Windows SAPI. Compile with the other alarm sources in the Linux
// development container; no System.Speech reference or Windows compiler needed.
// Every Speak call below renders only into SpMemoryStream, never an audio device.
using System;
using System.Diagnostics;
using System.Globalization;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;

namespace ComputerAlarmNative
{
    internal sealed class SpeechClip
    {
        internal const int SampleRate = 16000;
        private readonly short[] samples;
        private readonly string voiceName;

        internal SpeechClip(byte[] pcm16Mono, string name)
        {
            if (pcm16Mono == null || pcm16Mono.Length == 0 ||
                (pcm16Mono.Length & 1) != 0 || pcm16Mono.Length > SampleRate * 2 * 30)
                throw new InvalidOperationException("The English warning voice produced an invalid or oversized PCM clip.");
            samples = new short[pcm16Mono.Length / 2];
            bool nonSilent = false;
            for (int i = 0; i < samples.Length; i++)
            {
                samples[i] = (short)(pcm16Mono[2 * i] | (pcm16Mono[2 * i + 1] << 8));
                if (samples[i] != 0) nonSilent = true;
            }
            if (!nonSilent) throw new InvalidOperationException("The English warning voice produced an empty audio signal.");
            voiceName = name;
        }

        internal string VoiceName { get { return voiceName; } }
        internal short[] CopySamples() { return (short[])samples.Clone(); }
    }

    internal sealed class SpeechPreparation
    {
        internal const string WarningText = "Attention. This computer has been disconnected from power. Please reconnect the charger to stop the alarm. If the alarm continues, the police will be notified.";
        private readonly Thread thread;
        private int cancelled;
        private SpeechClip clip;
        private Exception failure;

        internal SpeechPreparation()
        {
            thread = new Thread(Synthesize);
            thread.IsBackground = true;
            thread.Name = "Computer alarm offline warning preparation";
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
        }

        internal bool IsCancelled { get { return Volatile.Read(ref cancelled) != 0; } }
        internal void Cancel() { Interlocked.Exchange(ref cancelled, 1); }

        internal SpeechClip Wait()
        {
            // A broken third-party COM activation cannot be forcibly terminated
            // safely. A timed-out background worker remains memory-only; Cancel
            // prevents it from submitting or returning any subsequent clip.
            if (!thread.Join(30000))
            {
                Cancel();
                thread.Join(1000);
                throw new TimeoutException("The offline English warning voice did not prepare within 30 seconds. Loud mode remains disabled.");
            }
            if (failure != null)
                throw new InvalidOperationException("Could not prepare the offline English warning voice. Loud mode remains disabled. " + failure.Message, failure);
            ThrowIfCancelled();
            if (clip == null) throw new InvalidOperationException("The offline English warning voice did not return a PCM clip.");
            return clip;
        }

        private void ThrowIfCancelled()
        {
            if (IsCancelled) throw new OperationCanceledException("Warning voice preparation was cancelled.");
        }

        private void Synthesize()
        {
            object stream = null;
            object format = null;
            object voice = null;
            object voices = null;
            object selected = null;
            bool queued = false;
            bool complete = false;
            try
            {
                ThrowIfCancelled();
                stream = CreateCom("SAPI.SpMemoryStream");
                format = Get(stream, "Format");
                Set(format, "Type", 18); // SAFT16kHz16BitMono, signed little-endian PCM.
                voice = CreateCom("SAPI.SpVoice");
                Set(voice, "AllowAudioOutputFormatChangesOnNextSet", false);
                SetReference(voice, "AudioOutputStream", stream);
                // Do not reset AudioOutputStream to null: SAPI would then select
                // the default endpoint. It keeps the memory sink until release.
                voices = Call(voice, "GetVoices", "", "");
                int count = Convert.ToInt32(Get(voices, "Count"), CultureInfo.InvariantCulture);
                for (int i = 0; i < count; i++)
                {
                    ThrowIfCancelled();
                    object candidate = Call(voices, "Item", i);
                    bool keep = false;
                    try
                    {
                        string vendor = Convert.ToString(Call(candidate, "GetAttribute", "Vendor"), CultureInfo.InvariantCulture);
                        string languages = Convert.ToString(Call(candidate, "GetAttribute", "Language"), CultureInfo.InvariantCulture);
                        // Use an installed Microsoft desktop voice. Avoid
                        // arbitrary provider engines which might use a network.
                        if (String.Equals(vendor, "Microsoft", StringComparison.OrdinalIgnoreCase) && HasEnglishLanguage(languages))
                        {
                            selected = candidate;
                            keep = true;
                            break;
                        }
                    }
                    catch (COMException) { }
                    finally { if (!keep) Release(candidate); }
                }
                if (selected == null)
                    throw new InvalidOperationException("No installed Microsoft English desktop SAPI voice is available.");
                string name = Convert.ToString(Call(selected, "GetDescription", 0), CultureInfo.InvariantCulture);
                if (String.IsNullOrWhiteSpace(name)) throw new InvalidOperationException("The English voice has no readable name.");
                SetReference(voice, "Voice", selected);
                Set(voice, "Rate", 0);
                Set(voice, "Volume", 100);
                ThrowIfCancelled();
                // SVSFlagsAsync | SVSFIsNotXML. Fixed text is never interpreted
                // as XML, a file path, or instructions to select another output.
                Call(voice, "Speak", WarningText, 17);
                queued = true;
                Stopwatch timer = Stopwatch.StartNew();
                while (!Convert.ToBoolean(Call(voice, "WaitUntilDone", 10), CultureInfo.InvariantCulture))
                {
                    ThrowIfCancelled();
                    if (timer.ElapsedMilliseconds >= 25000)
                        throw new TimeoutException("In-memory English speech synthesis timed out.");
                }
                complete = true;
                ThrowIfCancelled();
                if (Convert.ToInt32(Get(format, "Type"), CultureInfo.InvariantCulture) != 18)
                    throw new InvalidOperationException("The warning voice changed the requested PCM format.");
                byte[] pcm = Call(stream, "GetData") as byte[];
                SpeechClip prepared = new SpeechClip(pcm, name);
                ThrowIfCancelled();
                clip = prepared;
            }
            catch (Exception ex) { failure = Unwrap(ex); }
            finally
            {
                if (voice != null && queued && !complete)
                {
                    try
                    {
                        // Cancel only this memory-directed voice's pending work.
                        Call(voice, "Speak", "", 19); // Async | Purge | IsNotXML.
                    }
                    catch (Exception) { }
                }
                Release(voice);
                Release(selected);
                Release(voices);
                Release(format);
                Release(stream);
            }
        }

        private static bool HasEnglishLanguage(string languages)
        {
            if (languages == null) return false;
            foreach (string language in languages.Split(';'))
            {
                int locale;
                if (Int32.TryParse(language.Trim(), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out locale) &&
                    (locale & 0x03FF) == 9) return true; // LANG_ENGLISH, any region.
            }
            return false;
        }

        private static object CreateCom(string progId)
        {
            Type type = Type.GetTypeFromProgID(progId, true);
            return Activator.CreateInstance(type);
        }
        private static object Get(object target, string member)
        {
            return Invoke(target, member, BindingFlags.GetProperty, new object[0]);
        }
        private static void Set(object target, string member, object value)
        {
            Invoke(target, member, BindingFlags.SetProperty, new object[] { value });
        }
        private static void SetReference(object target, string member, object value)
        {
            Invoke(target, member, BindingFlags.PutRefDispProperty, new object[] { value });
        }
        private static object Call(object target, string member, params object[] arguments)
        {
            return Invoke(target, member, BindingFlags.InvokeMethod, arguments);
        }
        private static object Invoke(object target, string member, BindingFlags action, object[] arguments)
        {
            try
            {
                return target.GetType().InvokeMember(member, action | BindingFlags.Public | BindingFlags.Instance,
                    null, target, arguments, CultureInfo.InvariantCulture);
            }
            catch (TargetInvocationException ex)
            {
                if (ex.InnerException != null) throw ex.InnerException;
                throw;
            }
        }
        private static Exception Unwrap(Exception exception)
        {
            TargetInvocationException wrapped = exception as TargetInvocationException;
            return wrapped != null && wrapped.InnerException != null ? Unwrap(wrapped.InnerException) : exception;
        }
        private static void Release(object value)
        {
            if (value != null && Marshal.IsComObject(value))
            {
                try { Marshal.FinalReleaseComObject(value); }
                catch (Exception) { }
            }
        }
    }
}
