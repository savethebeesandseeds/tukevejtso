// Pure alarm decisions. No Windows, device, audio, timer, or process access.
// Call only after explicit arming has captured Unlocked + Online.
using System;

namespace ComputerAlarmLogic
{
    public sealed class AlarmSnapshot
    {
        public bool Enabled { get; private set; }
        public bool AlarmActive { get; private set; }
        public string Phase { get; private set; }
        public double? DelayRemainingSeconds { get; private set; }
        public double? PendingSinceSeconds { get; private set; }

        internal AlarmSnapshot(bool enabled, bool active, string phase,
            double? remaining, double? pendingSince)
        {
            Enabled = enabled;
            AlarmActive = active;
            Phase = phase;
            DelayRemainingSeconds = remaining;
            PendingSinceSeconds = pendingSince;
        }
    }

    public sealed class AlarmEngine
    {
        public const double DelaySeconds = 2.0;
        public bool Enabled { get; private set; }

        private string lastLock;
        private string lastAc;
        private long lastUnlockGeneration;
        private double? lastTime;
        private double? pendingSince;
        private bool alarmActive;
        private bool onlineBaseline;

        public AlarmEngine(string initialLockState, string initialAcState,
            long initialUnlockGeneration)
        {
            lastLock = NormalizeLock(initialLockState);
            lastAc = NormalizeAc(initialAcState);
            if (lastLock != "Unlocked" || lastAc != "Online")
                throw new ArgumentException("Arming requires a confirmed unlocked session and AC power online.");
            lastUnlockGeneration = initialUnlockGeneration;
            onlineBaseline = true;
            Enabled = true;
        }

        public AlarmSnapshot Update(double nowSeconds, string lockState,
            string acState, long unlockGeneration)
        {
            if (Double.IsNaN(nowSeconds) || Double.IsInfinity(nowSeconds) ||
                nowSeconds < 0 || (lastTime.HasValue && nowSeconds < lastTime.Value))
            {
                // A controller with an invalid clock must stop rather than retain
                // a previous alarm decision. Rearming requires a new engine.
                Cancel();
                throw new ArgumentOutOfRangeException("nowSeconds",
                    "Alarm time must be finite, nonnegative, and monotonic.");
            }
            lastTime = nowSeconds;
            if (!Enabled)
                return Snapshot("Disabled", nowSeconds);

            string currentLock = NormalizeLock(lockState);
            string currentAc = NormalizeAc(acState);
            bool unlockedBetweenSamples = unlockGeneration != lastUnlockGeneration;
            lastUnlockGeneration = unlockGeneration;

            if (currentLock == "Unknown" || currentAc == "Unknown")
            {
                ClearDetection();
                onlineBaseline = false;
                Remember(currentLock, currentAc);
                return Snapshot("Unknown", nowSeconds);
            }

            if (unlockedBetweenSamples)
            {
                // Even a complete unlock/relock between polls invalidates the
                // pending delay. Known online power can establish a fresh baseline.
                ClearDetection();
                onlineBaseline = currentAc == "Online";
                Remember(currentLock, currentAc);
                return Snapshot(currentAc == "Online" ? "Armed" : "WaitingForPower", nowSeconds);
            }

            if (currentAc == "Online")
            {
                // Reconnection cancels both the countdown and an active alarm.
                ClearDetection();
                onlineBaseline = true;
                Remember(currentLock, currentAc);
                return Snapshot("Armed", nowSeconds);
            }

            if (currentLock == "Unlocked")
            {
                ClearDetection();
                onlineBaseline = false;
                Remember(currentLock, currentAc);
                return Snapshot("WaitingForPower", nowSeconds);
            }

            // At this point the current session is confirmed Locked + Offline.
            // If both lock and unplug happen between adjacent polls, an earlier
            // Unlocked + Online sample is a valid edge. An unplug observed while
            // unlocked is not: locking later cannot start a countdown.
            if (!pendingSince.HasValue && onlineBaseline && lastAc == "Online" &&
                (lastLock == "Locked" || lastLock == "Unlocked"))
            {
                pendingSince = nowSeconds;
                onlineBaseline = false;
            }
            if (pendingSince.HasValue && nowSeconds - pendingSince.Value >= DelaySeconds)
                alarmActive = true;

            Remember(currentLock, currentAc);
            return Snapshot(alarmActive ? "Alarm" :
                pendingSince.HasValue ? "Pending" : "WaitingForPower", nowSeconds);
        }

        public void Cancel()
        {
            Invalidate();
            Enabled = false;
        }

        public void Invalidate()
        {
            // A native start can discover changed or unknown inputs after Update.
            // Keep monitoring enabled but require a fresh known-online sample
            // before allowing any later offline edge to start a new countdown.
            ClearDetection();
            onlineBaseline = false;
        }

        private void ClearDetection()
        {
            pendingSince = null;
            alarmActive = false;
        }

        private void Remember(string lockState, string acState)
        {
            lastLock = lockState;
            lastAc = acState;
        }

        private AlarmSnapshot Snapshot(string phase, double nowSeconds)
        {
            double? remaining = pendingSince.HasValue ?
                (double?)Math.Max(0, DelaySeconds - (nowSeconds - pendingSince.Value)) : null;
            return new AlarmSnapshot(Enabled, alarmActive, phase, remaining, pendingSince);
        }

        private static string NormalizeLock(string state)
        {
            if (String.Equals(state, "Locked", StringComparison.OrdinalIgnoreCase)) return "Locked";
            if (String.Equals(state, "Unlocked", StringComparison.OrdinalIgnoreCase)) return "Unlocked";
            return "Unknown";
        }

        private static string NormalizeAc(string state)
        {
            if (String.Equals(state, "Online", StringComparison.OrdinalIgnoreCase)) return "Online";
            if (String.Equals(state, "Offline", StringComparison.OrdinalIgnoreCase)) return "Offline";
            return "Unknown";
        }
    }
}
