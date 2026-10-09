// Deterministic decision tests only. This executable cannot access or play audio.
// Compile and run exclusively in the project's managed development container.
using System;
using ComputerAlarmLogic;

public static class ComputerAlarmTests
{
    private static int failures;
    private static int cases;

    private static AlarmEngine NewEngine()
    {
        return new AlarmEngine("Unlocked", "Online", 0);
    }

    private static void Check(bool condition, string reason)
    {
        if (!condition) throw new Exception(reason);
    }

    private static void Quiet(AlarmSnapshot result, string reason)
    {
        Check(!result.AlarmActive, reason);
    }

    private static void Cleared(AlarmSnapshot result, string reason)
    {
        Quiet(result, reason);
        Check(!result.PendingSinceSeconds.HasValue, reason + ": countdown retained");
        Check(!result.DelayRemainingSeconds.HasValue, reason + ": remaining delay retained");
    }

    private static void ExpectException<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new Exception("Expected " + typeof(T).Name);
    }

    private static void Run(string name, Action test)
    {
        cases++;
        try
        {
            test();
            Console.WriteLine("PASS " + name);
        }
        catch (Exception error)
        {
            failures++;
            Console.WriteLine("FAIL " + name + ": " + error.Message);
        }
    }

    public static int Main()
    {
        Run("exact two-second boundary", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Locked", "Online", 0);
            AlarmSnapshot start = engine.Update(0, "Locked", "Offline", 0);
            Quiet(start, "Unplug should start a delay");
            Check(start.Phase == "Pending" && start.PendingSinceSeconds == 0,
                "Countdown did not start at the observed unplug");
            Check(start.DelayRemainingSeconds == 2, "Delay must be fixed at two seconds");
            Quiet(engine.Update(1.999, "Locked", "Offline", 0), "Alarm started before two seconds");
            AlarmSnapshot active = engine.Update(2, "Locked", "Offline", 0);
            Check(active.AlarmActive && active.Phase == "Alarm", "Alarm missing at two seconds");
            Check(active.DelayRemainingSeconds == 0, "Active alarm retains a positive delay");
            Check(engine.Update(20, "Locked", "Offline", 0).AlarmActive, "Sustained condition lost alarm");
        });

        Run("elapsed time follows unplug rather than engine creation", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(40, "Locked", "Online", 0);
            engine.Update(45, "Locked", "Offline", 0);
            Quiet(engine.Update(46.999, "Locked", "Offline", 0), "Delay used engine age");
            Check(engine.Update(47, "Locked", "Offline", 0).AlarmActive, "Observed unplug delay is incorrect");
        });

        Run("reconnection before deadline cancels countdown", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Locked", "Offline", 0);
            Cleared(engine.Update(1.999, "Locked", "Online", 0), "Reconnection did not cancel");
            Quiet(engine.Update(3, "Locked", "Online", 0), "Cancelled countdown fired later");
        });

        Run("reconnection at deadline takes priority", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Locked", "Offline", 0);
            Cleared(engine.Update(2, "Locked", "Online", 0), "Deadline reconnection must remain silent");
        });

        Run("reconnection stops active alarm immediately", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Locked", "Offline", 0);
            Check(engine.Update(2, "Locked", "Offline", 0).AlarmActive, "Setup failed");
            Cleared(engine.Update(2.1, "Locked", "Online", 0), "Active alarm survived reconnection");
        });

        Run("unlock before deadline cancels and cannot restart offline", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Locked", "Offline", 0);
            Cleared(engine.Update(1.5, "Unlocked", "Offline", 1), "Unlock did not cancel");
            Cleared(engine.Update(4, "Locked", "Offline", 1), "Relock offline started a countdown");
        });

        Run("unlock stops active alarm", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Locked", "Offline", 0);
            Check(engine.Update(2, "Locked", "Offline", 0).AlarmActive, "Setup failed");
            Cleared(engine.Update(2.1, "Unlocked", "Offline", 1), "Unlock did not silence alarm");
        });

        Run("observed unlocked session is sufficient without event generation", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Locked", "Offline", 0);
            Cleared(engine.Update(1, "Unlocked", "Offline", 0), "Observed unlock was ignored");
            Cleared(engine.Update(4, "Locked", "Offline", 0), "Relock without reconnect restarted");
        });

        Run("unplug while unlocked does not trigger after later locking", delegate {
            AlarmEngine engine = NewEngine();
            Cleared(engine.Update(0, "Unlocked", "Offline", 0), "Unlocked unplug started delay");
            Cleared(engine.Update(1, "Locked", "Offline", 0), "Later lock started delay");
            Cleared(engine.Update(30, "Locked", "Offline", 0), "Long offline lock started alarm");
        });

        Run("lock and unplug between polls starts delay", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Unlocked", "Online", 0);
            AlarmSnapshot start = engine.Update(0.1, "Locked", "Offline", 0);
            Check(start.Phase == "Pending", "Lock/unplug polling edge missed");
            Quiet(engine.Update(2.099, "Locked", "Offline", 0), "Race triggered too early");
            Check(engine.Update(2.101, "Locked", "Offline", 0).AlarmActive, "Race never triggered");
        });

        Run("fast unlock and relock cancels pending delay", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Locked", "Offline", 0);
            Cleared(engine.Update(1, "Locked", "Offline", 1), "Unlock generation was ignored");
            Cleared(engine.Update(5, "Locked", "Offline", 1), "Cancelled offline alarm restarted");
        });

        Run("fast unlock and relock stops active alarm", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Locked", "Offline", 0);
            Check(engine.Update(2, "Locked", "Offline", 0).AlarmActive, "Setup failed");
            Cleared(engine.Update(2.1, "Locked", "Offline", 1), "Fast unlock retained active alarm");
        });

        Run("generation change overrides simultaneous unplug", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Locked", "Online", 0);
            Cleared(engine.Update(0.1, "Locked", "Offline", 1), "Unlock/unplug race must cancel");
            Cleared(engine.Update(5, "Locked", "Offline", 1), "Generation race later triggered");
        });

        Run("unknown lock cancels pending and requires known online baseline", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Locked", "Offline", 0);
            Cleared(engine.Update(1, "Unknown", "Offline", 0), "Unknown lock retained countdown");
            Cleared(engine.Update(5, "Locked", "Offline", 0), "Unknown lock recovery restarted offline");
            engine.Update(6, "Locked", "Online", 0);
            engine.Update(7, "Locked", "Offline", 0);
            Check(engine.Update(9, "Locked", "Offline", 0).AlarmActive, "Fresh online baseline did not recover");
        });

        Run("unknown power cancels pending and requires online baseline", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Locked", "Offline", 0);
            Cleared(engine.Update(1, "Locked", "Unknown", 0), "Unknown power retained countdown");
            Cleared(engine.Update(5, "Locked", "Offline", 0), "Unknown power recovery restarted offline");
        });

        Run("unknown lock stops active alarm", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Locked", "Offline", 0);
            Check(engine.Update(2, "Locked", "Offline", 0).AlarmActive, "Setup failed");
            Cleared(engine.Update(2.1, "Unknown", "Offline", 0), "Unknown lock retained alarm");
        });

        Run("unknown power stops active alarm", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Locked", "Offline", 0);
            Check(engine.Update(2, "Locked", "Offline", 0).AlarmActive, "Setup failed");
            Cleared(engine.Update(2.1, "Locked", "Unknown", 0), "Unknown power retained alarm");
        });

        Run("unknown lock online is not a valid baseline", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Unknown", "Online", 0);
            Cleared(engine.Update(1, "Locked", "Offline", 0), "Unknown online lock created baseline");
            Cleared(engine.Update(4, "Locked", "Offline", 0), "Unknown baseline caused alarm");
        });

        Run("missing or invalid state remains silent", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Locked", "Offline", 0);
            Cleared(engine.Update(1, null, "Offline", 0), "Missing lock did not cancel");
            Cleared(engine.Update(2, "Locked", "not-a-power-state", 0), "Invalid power did not cancel");
            Cleared(engine.Update(5, "Locked", "Offline", 0), "Invalid state recovery caused alarm");
        });

        Run("a second unplug gets a fresh full delay", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Locked", "Offline", 0);
            engine.Update(1.5, "Locked", "Online", 0);
            engine.Update(10, "Locked", "Offline", 0);
            Quiet(engine.Update(11.999, "Locked", "Offline", 0), "Second unplug reused earlier delay");
            Check(engine.Update(12, "Locked", "Offline", 0).AlarmActive, "Second unplug did not trigger");
            engine.Update(13, "Locked", "Online", 0);
            engine.Update(14, "Locked", "Offline", 0);
            Check(engine.Update(16, "Locked", "Offline", 0).AlarmActive, "Alarm did not restart after reconnection");
        });

        Run("generation change while online allows a later unplug", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Locked", "Online", 0);
            Cleared(engine.Update(1, "Locked", "Online", 1), "Generation change did not clear");
            engine.Update(2, "Locked", "Offline", 1);
            Check(engine.Update(4, "Locked", "Offline", 1).AlarmActive, "Online generation change lost baseline");
        });

        Run("arming rejects offline or unknown starting conditions", delegate {
            ExpectException<ArgumentException>(delegate { new AlarmEngine("Unlocked", "Offline", 0); });
            ExpectException<ArgumentException>(delegate { new AlarmEngine("Locked", "Online", 0); });
            ExpectException<ArgumentException>(delegate { new AlarmEngine("Unknown", "Online", 0); });
            ExpectException<ArgumentException>(delegate { new AlarmEngine("Unlocked", "Unknown", 0); });
        });

        Run("cancellation disables future decisions", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Locked", "Offline", 0);
            engine.Update(2, "Locked", "Offline", 0);
            engine.Cancel();
            AlarmSnapshot stopped = engine.Update(3, "Locked", "Offline", 0);
            Cleared(stopped, "Cancel retained active alarm");
            Check(!stopped.Enabled && stopped.Phase == "Disabled", "Cancel did not disable engine");
            engine.Update(4, "Unlocked", "Online", 0);
            engine.Update(5, "Locked", "Offline", 0);
            Cleared(engine.Update(10, "Locked", "Offline", 0), "Cancelled engine restarted");
        });

        Run("invalidating pending countdown requires online and a fresh delay", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Locked", "Offline", 0);
            engine.Update(1, "Locked", "Offline", 0);
            engine.Invalidate();
            Check(engine.Enabled, "Invalidation disabled monitoring");
            Cleared(engine.Update(3, "Locked", "Offline", 0), "Invalidation reused pending delay");
            engine.Update(4, "Locked", "Online", 0);
            engine.Update(5, "Locked", "Offline", 0);
            Quiet(engine.Update(6.999, "Locked", "Offline", 0), "Invalidation reused old start time");
            Check(engine.Update(7, "Locked", "Offline", 0).AlarmActive, "Fresh delay failed after invalidation");
        });

        Run("invalidating active alarm requires online and a fresh delay", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Locked", "Offline", 0);
            Check(engine.Update(2, "Locked", "Offline", 0).AlarmActive, "Setup failed");
            engine.Invalidate();
            Check(engine.Enabled, "Invalidation disabled monitoring");
            Cleared(engine.Update(3, "Locked", "Offline", 0), "Invalidation retained active alarm");
            Cleared(engine.Update(10, "Locked", "Offline", 0), "Invalidation restarted without online power");
            engine.Update(11, "Locked", "Online", 0);
            engine.Update(12, "Locked", "Offline", 0);
            Quiet(engine.Update(13.999, "Locked", "Offline", 0), "Invalidation alarm restarted too soon");
            Check(engine.Update(14, "Locked", "Offline", 0).AlarmActive, "Fresh cycle failed after active invalidation");
        });

        Run("equal timestamps are valid", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(0, "Unlocked", "Online", 0);
            engine.Update(0, "Locked", "Offline", 0);
            Quiet(engine.Update(0, "Locked", "Offline", 0), "Duplicate timestamp triggered alarm");
        });

        Run("backwards clock disables active alarm", delegate {
            AlarmEngine engine = NewEngine();
            engine.Update(1, "Locked", "Offline", 0);
            Check(engine.Update(3, "Locked", "Offline", 0).AlarmActive, "Setup failed");
            ExpectException<ArgumentOutOfRangeException>(delegate { engine.Update(2, "Locked", "Offline", 0); });
            Check(!engine.Enabled, "Invalid clock retained enabled state");
            Cleared(engine.Update(4, "Locked", "Offline", 0), "Invalid clock retained active state");
        });

        Run("nonfinite and negative clocks are rejected", delegate {
            double[] invalidTimes = new double[] { Double.NaN, Double.PositiveInfinity,
                Double.NegativeInfinity, -0.1 };
            foreach (double time in invalidTimes)
            {
                AlarmEngine engine = NewEngine();
                ExpectException<ArgumentOutOfRangeException>(delegate { engine.Update(time, "Locked", "Offline", 0); });
                Check(!engine.Enabled, "Invalid time did not disable engine");
            }
        });

        Console.WriteLine(cases + " decision tests, " + failures + " failures. No device or audio access.");
        return failures == 0 ? 0 : 1;
    }
}
