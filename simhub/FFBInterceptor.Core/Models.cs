// SPDX-License-Identifier: GPL-3.0-only
using System;

namespace FFBInterceptor.Core
{
    public sealed class DetectorSettings
    {
        public double EntryThresholdPercent { get; set; } = 98.0;
        public double ExitThresholdPercent { get; set; } = 95.0;
        public int ContinuousLimitMilliseconds { get; set; } = 100;
        public int RatioWindowMilliseconds { get; set; } = 1000;
        public double RatioTriggerPercent { get; set; } = 5.0;
        public int ExitHoldMilliseconds { get; set; } = 500;
        public bool AutoSelectSource { get; set; } = true;
        public uint ManualProcessId { get; set; }
        public string ManualSessionId { get; set; } = string.Empty;

        public static DetectorSettings Defaults() { return new DetectorSettings(); }

        public DetectorSettings CloneNormalized()
        {
            var entry = Clamp(EntryThresholdPercent, 1.0, 100.0);
            var exit = Clamp(ExitThresholdPercent, 0.0, entry);
            return new DetectorSettings
            {
                EntryThresholdPercent = entry,
                ExitThresholdPercent = exit,
                ContinuousLimitMilliseconds = Clamp(ContinuousLimitMilliseconds, 10, 5000),
                RatioWindowMilliseconds = Clamp(RatioWindowMilliseconds, 100, 10000),
                RatioTriggerPercent = Clamp(RatioTriggerPercent, 0.1, 100.0),
                ExitHoldMilliseconds = Clamp(ExitHoldMilliseconds, 0, 5000),
                AutoSelectSource = AutoSelectSource,
                ManualProcessId = ManualProcessId,
                ManualSessionId = (ManualSessionId ?? string.Empty).Trim().Substring(
                    0, Math.Min((ManualSessionId ?? string.Empty).Trim().Length, 31)),
            };
        }

        private static int Clamp(int value, int minimum, int maximum)
        {
            return Math.Max(minimum, Math.Min(maximum, value));
        }

        private static double Clamp(double value, double minimum, double maximum)
        {
            if (double.IsNaN(value) || double.IsInfinity(value)) return minimum;
            return Math.Max(minimum, Math.Min(maximum, value));
        }
    }

    public struct SourceKey : IEquatable<SourceKey>
    {
        public SourceKey(uint processId, string sessionId)
        {
            ProcessId = processId;
            SessionId = sessionId ?? string.Empty;
        }

        public uint ProcessId { get; }
        public string SessionId { get; }

        public bool Equals(SourceKey other)
        {
            return ProcessId == other.ProcessId &&
                   string.Equals(SessionId, other.SessionId, StringComparison.Ordinal);
        }

        public override bool Equals(object obj) { return obj is SourceKey && Equals((SourceKey)obj); }
        public override int GetHashCode()
        {
            unchecked { return ((int)ProcessId * 397) ^ StringComparer.Ordinal.GetHashCode(SessionId); }
        }
        public override string ToString() { return ProcessId + "/" + SessionId; }
    }

    public sealed class SourceIdentity
    {
        public SourceIdentity(SourceKey key, string processName, string buildVersion, int bitness)
        {
            Key = key;
            ProcessName = string.IsNullOrWhiteSpace(processName) ? "unknown.exe" : processName;
            BuildVersion = buildVersion ?? string.Empty;
            Bitness = bitness;
        }

        public SourceKey Key { get; }
        public string ProcessName { get; }
        public string BuildVersion { get; }
        public int Bitness { get; }
    }

    public enum DetectorTransitionKind
    {
        ClippingStarted,
        ClippingEnded,
        SourceConnected,
        SourceDisconnected,
    }

    public sealed class DetectorTransition
    {
        public DetectorTransition(DetectorTransitionKind kind, SourceKey source, double timestampMilliseconds)
        {
            Kind = kind;
            Source = source;
            TimestampMilliseconds = timestampMilliseconds;
        }

        public DetectorTransitionKind Kind { get; }
        public SourceKey Source { get; }
        public double TimestampMilliseconds { get; }
    }

    public sealed class GlobalClippingEventGate
    {
        private bool _anyClipping;

        public DetectorTransitionKind? Update(bool anyClipping)
        {
            if (anyClipping == _anyClipping) return null;
            _anyClipping = anyClipping;
            return anyClipping
                ? DetectorTransitionKind.ClippingStarted
                : DetectorTransitionKind.ClippingEnded;
        }

        public void Reset() { _anyClipping = false; }
    }

    public sealed class SourceCountEventGate
    {
        private int _sourceCount;

        public DetectorTransitionKind? Update(int sourceCount)
        {
            sourceCount = Math.Max(0, sourceCount);
            if (sourceCount == _sourceCount) return null;
            var transition = sourceCount > _sourceCount
                ? DetectorTransitionKind.SourceConnected
                : DetectorTransitionKind.SourceDisconnected;
            _sourceCount = sourceCount;
            return transition;
        }

        public void Reset() { _sourceCount = 0; }
    }

    public sealed class ClippingSnapshot
    {
        public static readonly ClippingSnapshot Empty = new ClippingSnapshot();

        public bool Connected { get; internal set; }
        public int SourceCount { get; internal set; }
        public bool ManualSourceAvailable { get; internal set; }
        public string SelectionMode { get; internal set; } = "Automatic";
        public string SelectedProcessName { get; internal set; } = string.Empty;
        public uint SelectedProcessId { get; internal set; }
        public string SelectedSessionId { get; internal set; } = string.Empty;
        public string ProxyBuildVersion { get; internal set; } = string.Empty;
        public int ProducerBitness { get; internal set; }
        public double CommandLevel { get; internal set; }
        public double PeakCommandLevel { get; internal set; }
        public double EffectiveCommandLevel { get; internal set; }
        public double EffectGain { get; internal set; }
        public double DeviceGain { get; internal set; }
        public bool AtLimit { get; internal set; }
        public bool IsClipping { get; internal set; }
        public bool AnyClipping { get; internal set; }
        public bool DataReliable { get; internal set; }
        public double ClipRatio { get; internal set; }
        public int RatioWindowMilliseconds { get; internal set; } = 1000;
        public int ActiveEffectCount { get; internal set; }
        public int UnsupportedEffectCount { get; internal set; }
        public string LastEffectKind { get; internal set; } = "Unknown";
        public ulong DroppedFrames { get; internal set; }
        public ulong ProtocolErrors { get; internal set; }
        public string StatusText { get; internal set; } = "等待 DirectInput 遙測";
        public double EntryThreshold { get; internal set; } = 0.98;
        public double ExitThreshold { get; internal set; } = 0.95;
        public string Definition { get; internal set; } = "DirectInput 命令削峰（非實際馬達扭力）";
    }
}
