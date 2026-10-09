// Synthetic numeric-data tests only. No SAPI, native helper, device, or audio access.
// Root may compile/run these in the managed Debian container when authorized.
using System;
using ComputerAlarmAudio;

public static class ComputerAlarmAudioSequenceTests
{
    private static int failures;
    private static int cases;

    private static void Check(bool condition, string reason)
    {
        if (!condition) throw new Exception(reason);
    }

    private static void Near(double actual, double expected, string reason)
    {
        if (Double.IsNaN(actual) || Double.IsInfinity(actual) || Math.Abs(actual - expected) > 1e-12)
            throw new Exception(reason + ": expected " + expected + ", got " + actual);
    }

    private static void ExpectException<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new Exception("Expected " + typeof(T).Name);
    }

    private static void Run(string name, Action action)
    {
        cases++;
        try { action(); Console.WriteLine("PASS " + name); }
        catch (Exception ex) { failures++; Console.WriteLine("FAIL " + name + ": " + ex.Message); }
    }

    private static long SpeechStart(AlarmSequence sequence)
    {
        return sequence.SirenFrames + sequence.PreSpeechGapFrames;
    }

    private static short[] Constant(int count, short value)
    {
        short[] values = new short[count];
        for (int i = 0; i < count; i++) values[i] = value;
        return values;
    }

    public static int Main()
    {
        Run("PCM16 little-endian signed decoding", delegate {
            byte[] pcm = new byte[] { 0, 0, 255, 127, 0, 128, 255, 255 };
            AlarmSequence sequence = new AlarmSequence(pcm, 8000, 8000);
            long start = SpeechStart(sequence);
            Near(sequence.SampleAt(start), 0, "Zero decoding");
            Near(sequence.SampleAt(start + 1), AlarmSequence.VoiceGain * 32767 / 32768.0, "Positive decoding");
            Near(sequence.SampleAt(start + 2), -AlarmSequence.VoiceGain, "Negative full-scale decoding");
            Near(sequence.SampleAt(start + 3), -AlarmSequence.VoiceGain / 32768.0, "Minus-one decoding");
        });

        Run("short input is copied", delegate {
            short[] pcm = new short[] { 12345, -12345 };
            AlarmSequence sequence = new AlarmSequence(pcm, 16000, 16000);
            pcm[0] = 0; pcm[1] = 0;
            Near(sequence.SampleAt(SpeechStart(sequence)), AlarmSequence.VoiceGain * 12345 / 32768.0,
                "Caller modified stored source samples");
        });

        Run("byte input is copied", delegate {
            byte[] pcm = new byte[] { 0, 64 };
            AlarmSequence sequence = new AlarmSequence(pcm, 16000, 16000);
            pcm[0] = 0; pcm[1] = 0;
            Near(sequence.SampleAt(SpeechStart(sequence)), AlarmSequence.VoiceGain * 0.5,
                "Caller modified stored source bytes");
        });

        Run("48kHz segment durations", delegate {
            AlarmSequence sequence = new AlarmSequence(new short[16000], 16000, 48000);
            Check(sequence.SirenFrames == 76800, "Siren is not 1.6 seconds");
            Check(sequence.PreSpeechGapFrames == 9600, "First gap is not .2 seconds");
            Check(sequence.SpeechFrames == 48000, "Speech duration changed");
            Check(sequence.PostSpeechGapFrames == 19200, "Final gap is not .4 seconds");
            Check(sequence.CycleFrames == 153600, "Cycle duration incorrect");
        });

        Run("44.1kHz segment durations", delegate {
            AlarmSequence sequence = new AlarmSequence(new short[16000], 16000, 44100);
            Check(sequence.SirenFrames == 70560 && sequence.PreSpeechGapFrames == 8820 &&
                sequence.SpeechFrames == 44100 && sequence.PostSpeechGapFrames == 17640,
                "44.1kHz frame counts changed timing");
        });

        Run("nonintegral rates round segments within one sample", delegate {
            AlarmSequence sequence = new AlarmSequence(new short[321], 16000, 44101);
            Check(Math.Abs(sequence.SirenFrames - 1.6 * sequence.OutputRate) <= 0.5,
                "Siren rounding exceeded half a frame");
            Check(Math.Abs(sequence.PreSpeechGapFrames - .2 * sequence.OutputRate) <= 0.5,
                "First gap rounding exceeded half a frame");
            Check(Math.Abs(sequence.PostSpeechGapFrames - .4 * sequence.OutputRate) <= 0.5,
                "Final gap rounding exceeded half a frame");
            double exactSpeechFrames = 321.0 * sequence.OutputRate / sequence.SourceRate;
            Check(sequence.SpeechFrames >= exactSpeechFrames && sequence.SpeechFrames < exactSpeechFrames + 1,
                "Complete speech duration was truncated or stretched");
        });

        Run("segment boundaries do not overlap", delegate {
            AlarmSequence sequence = new AlarmSequence(Constant(3200, 12000), 16000, 48000);
            long speechStart = SpeechStart(sequence);
            long speechEnd = speechStart + sequence.SpeechFrames;
            Check(sequence.SegmentAt(0) == AlarmSegment.Siren, "Cycle does not start with siren");
            Check(sequence.SegmentAt(sequence.SirenFrames - 1) == AlarmSegment.Siren, "Siren truncated");
            Check(sequence.SegmentAt(sequence.SirenFrames) == AlarmSegment.GapBeforeSpeech, "First gap missing");
            Check(sequence.SegmentAt(speechStart - 1) == AlarmSegment.GapBeforeSpeech, "Voice starts early");
            Check(sequence.SegmentAt(speechStart) == AlarmSegment.Speech, "Voice starts late");
            Check(sequence.SegmentAt(speechEnd - 1) == AlarmSegment.Speech, "Voice ends early");
            Check(sequence.SegmentAt(speechEnd) == AlarmSegment.GapAfterSpeech, "Voice overlaps final gap");
            Check(sequence.SegmentAt(sequence.CycleFrames - 1) == AlarmSegment.GapAfterSpeech, "Final gap truncated");
            Check(sequence.SegmentAt(sequence.CycleFrames) == AlarmSegment.Siren, "Repeat does not start at siren");
        });

        Run("both gaps contain exact zeros", delegate {
            AlarmSequence sequence = new AlarmSequence(Constant(800, 16000), 16000, 8000);
            for (long frame = sequence.SirenFrames; frame < SpeechStart(sequence); frame++)
                Near(sequence.SampleAt(frame), 0, "First gap has signal");
            for (long frame = SpeechStart(sequence) + sequence.SpeechFrames; frame < sequence.CycleFrames; frame++)
                Near(sequence.SampleAt(frame), 0, "Final gap has signal");
        });

        Run("upsampling preserves duration and linearly interpolates", delegate {
            AlarmSequence sequence = new AlarmSequence(new short[] { 0, 16000, -16000, 8000 }, 8000, 16000);
            long start = SpeechStart(sequence);
            Check(sequence.SpeechFrames == 8, "Upsampling changed duration");
            Near(sequence.SampleAt(start + 1), AlarmSequence.VoiceGain * 8000 / 32768.0, "First midpoint incorrect");
            Near(sequence.SampleAt(start + 2), AlarmSequence.VoiceGain * 16000 / 32768.0, "Original sample lost");
            Near(sequence.SampleAt(start + 3), 0, "Opposite-sign interpolation incorrect");
            Near(sequence.SampleAt(start + 5), AlarmSequence.VoiceGain * -4000 / 32768.0, "Second midpoint incorrect");
            Near(sequence.SampleAt(start + 7), AlarmSequence.VoiceGain * 8000 / 32768.0, "Tail reads past clip");
        });

        Run("downsampling preserves speech time", delegate {
            AlarmSequence sequence = new AlarmSequence(new short[] { 0, 1111, 2222, 3333, 4444, 5555, 6666, 7777 }, 16000, 8000);
            long start = SpeechStart(sequence);
            Check(sequence.SpeechFrames == 4, "Downsampling altered duration");
            Near(sequence.SampleAt(start + 1), AlarmSequence.VoiceGain * 2222 / 32768.0, "Rate mapping incorrect");
            Near(sequence.SampleAt(start + 3), AlarmSequence.VoiceGain * 6666 / 32768.0, "Last rate-mapped sample missing");
            Near(sequence.SampleAt(start + 4), 0, "Speech continued into gap");
        });

        Run("fractional resampling uses complete clip duration", delegate {
            AlarmSequence sequence = new AlarmSequence(new short[] { 1000, 2000, 3000 }, 11025, 48000);
            long start = SpeechStart(sequence);
            Check(sequence.SpeechFrames == 14, "Fractional duration must round up");
            Near(sequence.SampleAt(start + 13), AlarmSequence.VoiceGain * 3000 / 32768.0,
                "Fractional tail lost final input sample");
            Near(sequence.SampleAt(start + 14), 0, "Fractional tail escaped speech segment");
        });

        Run("siren fades to zero at each edge", delegate {
            AlarmSequence sequence = new AlarmSequence(new short[] { 1000 }, 16000, 48000);
            Near(sequence.SampleAt(0), 0, "Siren initial edge is discontinuous");
            Near(sequence.SampleAt(sequence.SirenFrames - 1), 0, "Siren final edge is discontinuous");
            double limit = AlarmSequence.SirenAmplitude / 480;
            Check(Math.Abs(sequence.SampleAt(1)) <= limit, "Siren start misses ten-ms fade");
            Check(Math.Abs(sequence.SampleAt(sequence.SirenFrames - 2)) <= limit, "Siren end misses ten-ms fade");
        });

        Run("speech fades preserve interior amplitude", delegate {
            AlarmSequence sequence = new AlarmSequence(Constant(3200, 16000), 16000, 48000);
            long start = SpeechStart(sequence);
            Near(sequence.SampleAt(start), 0, "Speech initial edge is discontinuous");
            Near(sequence.SampleAt(start + sequence.SpeechFrames - 1), 0, "Speech final edge is discontinuous");
            Near(sequence.SampleAt(start + sequence.SpeechFrames / 2), AlarmSequence.VoiceGain * 16000 / 32768.0,
                "Speech interior amplitude changed");
        });

        Run("short speech is not erased by an edge fade", delegate {
            AlarmSequence sequence = new AlarmSequence(new short[] { 16000 }, 16000, 8000);
            Check(sequence.SpeechFrames == 1, "One-sample clip lost its duration");
            Near(sequence.SampleAt(SpeechStart(sequence)), AlarmSequence.VoiceGain * 16000 / 32768.0,
                "Short clip was erased");
        });

        Run("full speech interior includes late content", delegate {
            short[] pcm = Constant(16000, 1000);
            for (int i = 12000; i < pcm.Length; i++) pcm[i] = -16000;
            AlarmSequence sequence = new AlarmSequence(pcm, 16000, 48000);
            long start = SpeechStart(sequence);
            Near(sequence.SampleAt(start + 39000), -AlarmSequence.VoiceGain * 16000 / 32768.0,
                "Late voice content was truncated");
            Check(sequence.SpeechFrames == 48000, "Voice was shortened to fit a fixed cycle");
        });

        Run("samples are finite and below full scale", delegate {
            AlarmSequence sequence = new AlarmSequence(new short[] { Int16.MinValue, Int16.MaxValue }, 8000, 8000);
            for (long frame = 0; frame < sequence.CycleFrames; frame++)
            {
                double sample = sequence.SampleAt(frame);
                Check(!Double.IsNaN(sample) && !Double.IsInfinity(sample), "Nonfinite output sample");
                Check(Math.Abs(sample) <= AlarmSequence.SirenAmplitude, "Output sample clipped");
            }
        });

        Run("two cycles repeat exactly without time drift", delegate {
            AlarmSequence sequence = new AlarmSequence(new short[] { 1000, -1000, 2000 }, 16000, 8000);
            for (long frame = 0; frame < 2 * sequence.CycleFrames; frame++)
                Near(sequence.NextSample(), sequence.SampleAt(frame), "Frame sequence drifted");
            Check(sequence.FramePosition == 0, "Cursor did not reset at complete cycles");
        });

        Run("manual reset returns to beginning", delegate {
            AlarmSequence sequence = new AlarmSequence(new short[] { 1000 }, 16000, 48000);
            for (int i = 0; i < 123; i++) sequence.NextSample();
            sequence.Reset();
            Check(sequence.FramePosition == 0, "Reset retained cursor");
            Near(sequence.NextSample(), sequence.SampleAt(0), "Reset retained previous siren phase");
            Check(sequence.FramePosition == 1, "Cursor failed after reset");
        });

        Run("large absolute indices cannot overflow resampling", delegate {
            AlarmSequence sequence = new AlarmSequence(new short[] { 1000, -1000 }, 16000, 192000);
            double sample = sequence.SampleAt(Int64.MaxValue);
            Check(!Double.IsNaN(sample) && !Double.IsInfinity(sample), "Large index created invalid sample");
            Near(sample, sequence.SampleAt(Int64.MaxValue % sequence.CycleFrames), "Modulo cycle incorrect");
        });

        Run("supported sample-rate limits", delegate {
            AlarmSequence lowest = new AlarmSequence(new short[] { 0 }, 8000, 8000);
            AlarmSequence highest = new AlarmSequence(new short[] { 0 }, 192000, 192000);
            Check(lowest.SpeechFrames == 1 && highest.SpeechFrames == 1, "Rate limits rejected valid clips");
        });

        Run("exact sixty-second maximum accepted", delegate {
            AlarmSequence sequence = new AlarmSequence(new short[8000 * 60], 8000, 8000);
            Check(sequence.SpeechFrames == 480000, "Maximum-duration clip changed length");
        });

        Run("excessive duration rejected before use", delegate {
            ExpectException<ArgumentException>(delegate { new AlarmSequence(new short[8000 * 60 + 1], 8000, 8000); });
            ExpectException<ArgumentException>(delegate { new AlarmSequence(new byte[8000 * 60 * 2 + 2], 8000, 8000); });
        });

        Run("empty missing and partial PCM rejected", delegate {
            ExpectException<ArgumentNullException>(delegate { new AlarmSequence((short[])null, 16000, 48000); });
            ExpectException<ArgumentNullException>(delegate { new AlarmSequence((byte[])null, 16000, 48000); });
            ExpectException<ArgumentException>(delegate { new AlarmSequence(new short[0], 16000, 48000); });
            ExpectException<ArgumentException>(delegate { new AlarmSequence(new byte[0], 16000, 48000); });
            ExpectException<ArgumentException>(delegate { new AlarmSequence(new byte[3], 16000, 48000); });
        });

        Run("out-of-range rates rejected", delegate {
            int[] invalid = new int[] { Int32.MinValue, -1, 0, 7999, 192001, Int32.MaxValue };
            foreach (int rate in invalid)
            {
                ExpectException<ArgumentOutOfRangeException>(delegate { new AlarmSequence(new short[] { 0 }, rate, 48000); });
                ExpectException<ArgumentOutOfRangeException>(delegate { new AlarmSequence(new short[] { 0 }, 16000, rate); });
                ExpectException<ArgumentOutOfRangeException>(delegate { new AlarmSequence(new byte[] { 0, 0 }, rate, 48000); });
            }
        });

        Run("negative frame indices rejected", delegate {
            AlarmSequence sequence = new AlarmSequence(new short[] { 0 }, 16000, 48000);
            ExpectException<ArgumentOutOfRangeException>(delegate { sequence.SampleAt(-1); });
            ExpectException<ArgumentOutOfRangeException>(delegate { sequence.SegmentAt(-1); });
        });

        Run("volume progress clamps at both finite boundaries", delegate {
            Near(AlarmVolumeRamp.ProgressAtSeconds(-5), 0, "Negative time changed starting progress");
            Near(AlarmVolumeRamp.ProgressAtSeconds(0), 0, "Starting progress is not zero");
            Check(AlarmVolumeRamp.ProgressAtSeconds(14.999) < 1, "Progress reached maximum before fifteen seconds");
            Near(AlarmVolumeRamp.ProgressAtSeconds(15), 1, "Progress missing at fifteen seconds");
            Near(AlarmVolumeRamp.ProgressAtSeconds(Double.MaxValue), 1, "Large finite time did not hold maximum");
        });

        Run("volume gain starts at one percent and reaches exact maximum", delegate {
            Near(AlarmVolumeRamp.GainAtSeconds(0), .01, "Ramp did not start at one percent");
            Near(AlarmVolumeRamp.GainAtSeconds(-1), .01, "Negative time did not preserve initial gain");
            Near(AlarmVolumeRamp.GainAtSeconds(7.5), .1, "Halfway gain is not ten percent");
            Check(AlarmVolumeRamp.GainAtSeconds(14.999) < 1, "Gain reached maximum too early");
            Check(AlarmVolumeRamp.GainAtSeconds(15) == 1, "Fifteen-second gain is not exact maximum");
            Check(AlarmVolumeRamp.GainAtSeconds(900) == 1, "Maximum gain was not held");
        });

        Run("volume rise has equal decibel steps", delegate {
            double first = AlarmVolumeRamp.GainAtSeconds(0);
            double quarter = AlarmVolumeRamp.GainAtSeconds(3.75);
            double half = AlarmVolumeRamp.GainAtSeconds(7.5);
            double later = AlarmVolumeRamp.GainAtSeconds(11.25);
            Near(quarter / first, half / quarter, "First two equal time intervals have different gain ratios");
            Near(half / quarter, later / half, "Later interval changed decibel slope");
        });

        Run("volume gain is monotonic finite and bounded", delegate {
            double previous = AlarmVolumeRamp.InitialGain;
            for (int step = 0; step <= 1200; step++)
            {
                double gain = AlarmVolumeRamp.GainAtSeconds(step * .015);
                Check(!Double.IsNaN(gain) && !Double.IsInfinity(gain), "Gain became nonfinite");
                Check(gain >= .01 && gain <= 1, "Gain exceeded normalized bounds");
                Check(gain >= previous, "Gain decreased during ramp");
                previous = gain;
            }
        });

        Run("frame volume reaches maximum at exactly fifteen seconds", delegate {
            AlarmVolumeRamp ramp = new AlarmVolumeRamp(8000);
            for (long frame = 0; frame < 120000; frame++)
            {
                double gain = ramp.NextGain();
                if (frame == 0) Near(gain, .01, "First frame not quiet");
                Check(gain < 1, "Frame ramp reached full volume before fifteen seconds");
            }
            Check(ramp.FramePosition == 120000, "Frame timeline missing deadline");
            Check(ramp.NextGain() == 1, "Deadline frame did not reach full volume");
            for (int extra = 0; extra < 1000; extra++)
                Check(ramp.NextGain() == 1, "Volume did not stay at maximum");
            Check(ramp.FramePosition == 120000, "Saturated timeline kept increasing");
        });

        Run("new trigger resets gain to one percent", delegate {
            AlarmVolumeRamp ramp = new AlarmVolumeRamp(8000);
            for (int frame = 0; frame < 80000; frame++) ramp.NextGain();
            Check(ramp.NextGain() > .01, "Setup did not increase gain");
            ramp.Reset();
            Check(ramp.FramePosition == 0, "Reset retained previous trigger timeline");
            Near(ramp.NextGain(), .01, "New trigger reused elevated gain");
            Near(ramp.NextGain(), AlarmVolumeRamp.GainAtSeconds(1.0 / 8000), "New trigger did not restart smooth rise");
        });

        Run("volume timeline spans repeated siren and voice cycles", delegate {
            AlarmSequence sequence = new AlarmSequence(Constant(400, 1000), 8000, 8000);
            AlarmVolumeRamp ramp = new AlarmVolumeRamp(8000);
            int completedCycles = 0;
            for (long frame = 0; frame < 120000; frame++)
            {
                double gain = ramp.NextGain();
                sequence.NextSample();
                if (frame > 0 && frame % sequence.CycleFrames == 0)
                {
                    completedCycles++;
                    Check(gain > .01 && gain < 1, "A sequence cycle restarted or completed the volume ramp");
                }
                Near(gain, AlarmVolumeRamp.GainAtSeconds((double)frame / 8000), "Sequence cycle changed absolute ramp time");
            }
            Check(completedCycles > 1, "Scenario did not cross multiple sequence cycles");
            Check(ramp.NextGain() == 1, "Cycle repetitions delayed fifteen-second maximum");
        });

        Run("resetting audio sequence does not reset volume", delegate {
            AlarmSequence sequence = new AlarmSequence(new short[] { 1000 }, 8000, 8000);
            AlarmVolumeRamp ramp = new AlarmVolumeRamp(8000);
            for (int frame = 0; frame < 60000; frame++)
            {
                sequence.NextSample();
                ramp.NextGain();
            }
            sequence.Reset();
            Near(ramp.NextGain(), .1, "Resetting sequence changed volume timeline");
        });

        Run("volume timing is independent of sample rate", delegate {
            int[] rates = new int[] { 8000, 44100, 192000 };
            foreach (int rate in rates)
            {
                AlarmVolumeRamp ramp = new AlarmVolumeRamp(rate);
                long halfway = (long)rate * 15 / 2;
                long deadline = (long)rate * 15;
                while (ramp.FramePosition < halfway) ramp.NextGain();
                Near(ramp.NextGain(), .1, "Sample rate changed halfway gain");
                while (ramp.FramePosition < deadline) ramp.NextGain();
                Check(ramp.NextGain() == 1, "Sample rate changed maximum deadline");
            }
        });

        Run("endpoint original level is preserved at startup", delegate {
            double[] originals = new double[] { 0, .25, 1 };
            foreach (double original in originals)
            {
                Near(AlarmVolumeRamp.EndpointLevelAtSeconds(original, 0), original, "Startup changed original endpoint level");
                Near(AlarmVolumeRamp.EndpointLevelAtSeconds(original, -10), original, "Negative time changed endpoint level");
            }
        });

        Run("endpoint level rises from original to maximum over fifteen seconds", delegate {
            Near(AlarmVolumeRamp.EndpointLevelAtSeconds(0, 7.5), .5, "Zero endpoint halfway level incorrect");
            Near(AlarmVolumeRamp.EndpointLevelAtSeconds(.25, 7.5), .625, "Quarter endpoint halfway level incorrect");
            Near(AlarmVolumeRamp.EndpointLevelAtSeconds(1, 7.5), 1, "Maximum original endpoint was reduced");
            double[] originals = new double[] { 0, .25, 1 };
            foreach (double original in originals)
            {
                Check(AlarmVolumeRamp.EndpointLevelAtSeconds(original, 15) == 1, "Endpoint not full at fifteen seconds");
                Check(AlarmVolumeRamp.EndpointLevelAtSeconds(original, 90) == 1, "Endpoint did not remain full");
            }
            Check(AlarmVolumeRamp.EndpointLevelAtSeconds(.25, 14.999) < 1, "Endpoint reached full volume early");
        });

        Run("endpoint levels remain monotonic finite and bounded", delegate {
            double[] originals = new double[] { 0, .25, 1 };
            foreach (double original in originals)
            {
                double previous = original;
                for (int step = 0; step <= 1000; step++)
                {
                    double scalar = AlarmVolumeRamp.EndpointLevelAtSeconds(original, step * .02);
                    Check(!Double.IsNaN(scalar) && !Double.IsInfinity(scalar), "Endpoint level became nonfinite");
                    Check(scalar >= original && scalar <= 1, "Endpoint level exceeded original/maximum bounds");
                    Check(scalar >= previous, "Endpoint level decreased");
                    previous = scalar;
                }
            }
        });

        Run("nonfinite ramp time and invalid endpoint levels rejected", delegate {
            double[] invalidTimes = new double[] { Double.NaN, Double.PositiveInfinity, Double.NegativeInfinity };
            foreach (double time in invalidTimes)
            {
                ExpectException<ArgumentOutOfRangeException>(delegate { AlarmVolumeRamp.ProgressAtSeconds(time); });
                ExpectException<ArgumentOutOfRangeException>(delegate { AlarmVolumeRamp.GainAtSeconds(time); });
                ExpectException<ArgumentOutOfRangeException>(delegate { AlarmVolumeRamp.EndpointLevelAtSeconds(.25, time); });
            }
            double[] invalidLevels = new double[] { -.001, 1.001, Double.NaN, Double.PositiveInfinity, Double.NegativeInfinity };
            foreach (double original in invalidLevels)
                ExpectException<ArgumentOutOfRangeException>(delegate { AlarmVolumeRamp.EndpointLevelAtSeconds(original, 0); });
        });

        Run("volume ramp rejects unsupported sample rates", delegate {
            int[] invalid = new int[] { Int32.MinValue, -1, 0, 7999, 192001, Int32.MaxValue };
            foreach (int rate in invalid)
                ExpectException<ArgumentOutOfRangeException>(delegate { new AlarmVolumeRamp(rate); });
        });

        Console.WriteLine(cases + " pure numeric tests, " + failures + " failures. No audio or speech engine access.");
        return failures == 0 ? 0 : 1;
    }
}
