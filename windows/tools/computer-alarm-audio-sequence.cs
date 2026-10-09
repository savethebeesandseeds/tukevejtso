// Pure numeric audio sequencing. No device, speech engine, session, or audio APIs.
// The native worker sends these samples through its existing guarded WASAPI stream.
using System;

namespace ComputerAlarmAudio
{
    public enum AlarmSegment { Siren, GapBeforeSpeech, Speech, GapAfterSpeech }

    public sealed class AlarmVolumeRamp
    {
        public const double DurationSeconds = 15.0;
        public const double InitialGain = 0.01;
        private readonly int outputRate;
        private readonly long fullVolumeFrame;
        private long framePosition;

        public long FramePosition { get { return framePosition; } }

        public AlarmVolumeRamp(int outputRate)
        {
            if (outputRate < 8000 || outputRate > 192000)
                throw new ArgumentOutOfRangeException("outputRate", "PCM sample rates must be from 8000 to 192000 Hz.");
            this.outputRate = outputRate;
            fullVolumeFrame = (long)(outputRate * DurationSeconds);
        }

        public double NextGain()
        {
            double gain = GainAtSeconds((double)framePosition / outputRate);
            // This is an absolute per-run cursor, independent of speech/siren
            // cycles. Saturation prevents overflow during indefinite playback.
            if (framePosition < fullVolumeFrame) framePosition++;
            return gain;
        }

        public void Reset() { framePosition = 0; }

        public static double ProgressAtSeconds(double elapsedSeconds)
        {
            if (Double.IsNaN(elapsedSeconds) || Double.IsInfinity(elapsedSeconds))
                throw new ArgumentOutOfRangeException("elapsedSeconds", "Ramp time must be finite.");
            if (elapsedSeconds <= 0) return 0;
            if (elapsedSeconds >= DurationSeconds) return 1;
            return elapsedSeconds / DurationSeconds;
        }

        public static double GainAtSeconds(double elapsedSeconds)
        {
            double progress = ProgressAtSeconds(elapsedSeconds);
            if (progress == 0) return InitialGain;
            if (progress == 1) return 1;
            // Equal time intervals produce equal increases in decibels.
            return InitialGain * Math.Pow(1 / InitialGain, progress);
        }

        public static double EndpointLevelAtSeconds(double originalScalar, double elapsedSeconds)
        {
            if (Double.IsNaN(originalScalar) || Double.IsInfinity(originalScalar) ||
                originalScalar < 0 || originalScalar > 1)
                throw new ArgumentOutOfRangeException("originalScalar", "Endpoint volume must be a finite scalar from zero to one.");
            double progress = ProgressAtSeconds(elapsedSeconds);
            if (progress == 0) return originalScalar;
            if (progress == 1) return 1;
            return originalScalar + (1 - originalScalar) * progress;
        }
    }

    public sealed class AlarmSequence
    {
        public const double SirenAmplitude = 0.95;
        public const double VoiceGain = 0.90;
        public const int MaximumSpeechSeconds = 60;
        private readonly short[] speech;
        private readonly long sirenFadeFrames;
        private readonly long speechFadeFrames;
        private long framePosition;

        public int SourceRate { get; private set; }
        public int OutputRate { get; private set; }
        public long SirenFrames { get; private set; }
        public long PreSpeechGapFrames { get; private set; }
        public long SpeechFrames { get; private set; }
        public long PostSpeechGapFrames { get; private set; }
        public long CycleFrames { get; private set; }
        public long FramePosition { get { return framePosition; } }

        public AlarmSequence(short[] speechPcm16, int speechRate, int outputRate)
            : this(speechPcm16, speechRate, outputRate, false) { }

        public AlarmSequence(byte[] speechPcm16Le, int speechRate, int outputRate)
            : this(DecodePcm16(speechPcm16Le, speechRate), speechRate, outputRate, true) { }

        private AlarmSequence(short[] samples, int speechRate, int outputRate, bool ownSamples)
        {
            ValidateRate(speechRate, "speechRate");
            ValidateRate(outputRate, "outputRate");
            if (samples == null) throw new ArgumentNullException("speechPcm16");
            if (samples.Length == 0) throw new ArgumentException("Speech PCM must not be empty.", "speechPcm16");
            if ((long)samples.Length > (long)speechRate * MaximumSpeechSeconds)
                throw new ArgumentException("Speech PCM must be no longer than sixty seconds.", "speechPcm16");

            speech = ownSamples ? samples : (short[])samples.Clone();
            SourceRate = speechRate;
            OutputRate = outputRate;
            SirenFrames = FramesFromMilliseconds(1600);
            PreSpeechGapFrames = FramesFromMilliseconds(200);
            PostSpeechGapFrames = FramesFromMilliseconds(400);
            // Round the speech duration upward by at most one output frame. This
            // includes the complete input duration without changing speech speed.
            SpeechFrames = ((long)speech.Length * OutputRate + SourceRate - 1) / SourceRate;
            CycleFrames = checked(SirenFrames + PreSpeechGapFrames + SpeechFrames + PostSpeechGapFrames);
            sirenFadeFrames = FramesFromMilliseconds(10);
            long voiceEdge = FramesFromMilliseconds(5);
            // Do not erase very short clips merely to apply an edge fade.
            speechFadeFrames = SpeechFrames > 2 * voiceEdge ? voiceEdge : 0;
        }

        public double NextSample()
        {
            double sample = SampleAt(framePosition);
            framePosition++;
            if (framePosition == CycleFrames) framePosition = 0;
            return sample;
        }

        public void Reset() { framePosition = 0; }

        public AlarmSegment SegmentAt(long absoluteFrame)
        {
            long position = CyclePosition(absoluteFrame);
            if (position < SirenFrames) return AlarmSegment.Siren;
            position -= SirenFrames;
            if (position < PreSpeechGapFrames) return AlarmSegment.GapBeforeSpeech;
            position -= PreSpeechGapFrames;
            if (position < SpeechFrames) return AlarmSegment.Speech;
            return AlarmSegment.GapAfterSpeech;
        }

        public double SampleAt(long absoluteFrame)
        {
            long position = CyclePosition(absoluteFrame);
            if (position < SirenFrames) return SirenSample(position);
            position -= SirenFrames;
            if (position < PreSpeechGapFrames) return 0;
            position -= PreSpeechGapFrames;
            if (position < SpeechFrames) return SpeechSample(position);
            return 0;
        }

        private long CyclePosition(long absoluteFrame)
        {
            if (absoluteFrame < 0) throw new ArgumentOutOfRangeException("absoluteFrame");
            return absoluteFrame % CycleFrames;
        }

        private double SirenSample(long frame)
        {
            // Integrate a 750 -> 1600 -> 750 Hz triangle analytically. Phase is
            // determined by the frame position, so cycles and Reset are exact
            // even when WASAPI requests different buffer lengths.
            double seconds = (double)frame / OutputRate;
            double half = (double)SirenFrames / OutputRate / 2;
            double cycles;
            if (seconds <= half)
                cycles = 750 * seconds + 850 * seconds * seconds / (2 * half);
            else
            {
                double later = seconds - half;
                double firstHalf = 750 * half + 850 * half / 2;
                cycles = firstHalf + 1600 * later - 850 * later * later / (2 * half);
            }
            return SirenAmplitude * Math.Sin(2 * Math.PI * cycles) *
                EdgeGain(frame, SirenFrames, sirenFadeFrames);
        }

        private double SpeechSample(long frame)
        {
            // Integer position arithmetic avoids accumulated resampling error.
            // The last source sample is held at the tail rather than reading past
            // the immutable clip. Linear interpolation cannot exceed its endpoints.
            long scaled = frame * SourceRate;
            int source = (int)(scaled / OutputRate);
            double fraction = (double)(scaled % OutputRate) / OutputRate;
            if (source >= speech.Length) source = speech.Length - 1;
            int next = source + 1 < speech.Length ? source + 1 : source;
            double first = speech[source] / 32768.0;
            double second = speech[next] / 32768.0;
            double sample = VoiceGain * (first + (second - first) * fraction);
            return sample * EdgeGain(frame, SpeechFrames, speechFadeFrames);
        }

        private static double EdgeGain(long frame, long length, long edge)
        {
            if (edge == 0) return 1;
            return Math.Min(1, Math.Min((double)frame / edge, (double)(length - 1 - frame) / edge));
        }

        private long FramesFromMilliseconds(int milliseconds)
        {
            return ((long)OutputRate * milliseconds + 500) / 1000;
        }

        private static void ValidateRate(int rate, string parameter)
        {
            if (rate < 8000 || rate > 192000)
                throw new ArgumentOutOfRangeException(parameter, "PCM sample rates must be from 8000 to 192000 Hz.");
        }

        private static short[] DecodePcm16(byte[] pcm, int speechRate)
        {
            ValidateRate(speechRate, "speechRate");
            if (pcm == null) throw new ArgumentNullException("speechPcm16Le");
            if (pcm.Length == 0 || (pcm.Length & 1) != 0)
                throw new ArgumentException("PCM16LE must contain complete, nonempty mono samples.", "speechPcm16Le");
            if ((long)pcm.Length > (long)speechRate * MaximumSpeechSeconds * 2)
                throw new ArgumentException("Speech PCM must be no longer than sixty seconds.", "speechPcm16Le");
            short[] samples = new short[pcm.Length / 2];
            for (int i = 0; i < samples.Length; i++)
                samples[i] = unchecked((short)(pcm[2 * i] | (pcm[2 * i + 1] << 8)));
            return samples;
        }
    }
}
