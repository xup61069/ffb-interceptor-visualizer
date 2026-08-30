// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Threading;

namespace FFBInterceptor.Core
{
    public sealed class ClippingEngine
    {
        private const int MaximumQueuedTransitions = 256;
        private readonly object _gate = new object();
        private readonly Dictionary<SourceKey, SourceState> _sources = new Dictionary<SourceKey, SourceState>();
        private readonly ConcurrentQueue<DetectorTransition> _transitions = new ConcurrentQueue<DetectorTransition>();
        private DetectorSettings _settings;
        private ulong _protocolErrors;
        private int _queuedTransitionCount;

        public ClippingEngine(DetectorSettings settings)
        {
            _settings = (settings ?? DetectorSettings.Defaults()).CloneNormalized();
        }

        public void UpdateSettings(DetectorSettings settings)
        {
            if (settings == null) throw new ArgumentNullException(nameof(settings));
            lock (_gate) _settings = settings.CloneNormalized();
        }

        public void Connect(SourceIdentity identity, Guid connectionId, double nowMilliseconds)
        {
            if (identity == null) throw new ArgumentNullException(nameof(identity));
            lock (_gate)
            {
                SourceState source;
                if (!_sources.TryGetValue(identity.Key, out source))
                {
                    TrimDisconnectedSources();
                    source = new SourceState(identity);
                    _sources.Add(identity.Key, source);
                }
                else
                {
                    source.Identity = identity;
                }

                var wasConnected = source.Connected;
                source.Connections.Add(connectionId);
                source.LastActivityMilliseconds = nowMilliseconds;
                if (!wasConnected)
                    EnqueueTransition(new DetectorTransition(
                        DetectorTransitionKind.SourceConnected, identity.Key, nowMilliseconds));
            }
        }

        public void Disconnect(SourceKey key, Guid connectionId, double nowMilliseconds)
        {
            lock (_gate)
            {
                SourceState source;
                if (!_sources.TryGetValue(key, out source)) return;
                source.Connections.Remove(connectionId);
                if (source.Connected) return;
                if (source.IsClipping)
                    EnqueueTransition(new DetectorTransition(
                        DetectorTransitionKind.ClippingEnded, key, nowMilliseconds));
                source.ResetAfterDisconnect(nowMilliseconds);
                EnqueueTransition(new DetectorTransition(
                    DetectorTransitionKind.SourceDisconnected, key, nowMilliseconds));
            }
        }

        public void ProcessFrame(SourceKey key, ProtocolFrame frame, double nowMilliseconds)
        {
            if (frame == null) throw new ArgumentNullException(nameof(frame));
            lock (_gate)
            {
                SourceState source;
                if (!_sources.TryGetValue(key, out source) || !source.Connected) return;
                if (frame.ProcessId != key.ProcessId)
                {
                    _protocolErrors++;
                    return;
                }
                source.LastActivityMilliseconds = nowMilliseconds;
                var wasClipping = source.IsClipping;
                source.Apply(frame, nowMilliseconds);
                if (wasClipping && !source.IsClipping)
                    EnqueueTransition(new DetectorTransition(
                        DetectorTransitionKind.ClippingEnded, key, nowMilliseconds));
            }
        }

        public void ReportProtocolError()
        {
            lock (_gate) _protocolErrors++;
        }

        public void ResetPeak()
        {
            lock (_gate)
            {
                foreach (var source in _sources.Values) source.ResetPeak();
            }
        }

        public bool TryDequeueTransition(out DetectorTransition transition)
        {
            if (!_transitions.TryDequeue(out transition)) return false;
            Interlocked.Decrement(ref _queuedTransitionCount);
            return true;
        }

        public ClippingSnapshot Tick(double nowMilliseconds)
        {
            lock (_gate)
            {
                foreach (var source in _sources.Values)
                {
                    var transition = source.Tick(nowMilliseconds, _settings);
                    if (transition.HasValue)
                        EnqueueTransition(new DetectorTransition(
                            transition.Value, source.Identity.Key, nowMilliseconds));
                }

                var connectedSources = _sources.Values.Where(value => value.Connected).ToList();
                var selected = SelectSource(connectedSources);
                return BuildSnapshot(connectedSources, selected);
            }
        }

        private void EnqueueTransition(DetectorTransition transition)
        {
            // SimHub derives public events from the published snapshot, so
            // this diagnostic per-source queue may safely shed excess edges.
            // Bounding it prevents a same-user synthetic producer from
            // growing host memory faster than DataUpdate drains diagnostics.
            if (Interlocked.Increment(ref _queuedTransitionCount) <= MaximumQueuedTransitions)
            {
                _transitions.Enqueue(transition);
                return;
            }
            Interlocked.Decrement(ref _queuedTransitionCount);
        }

        private SourceState SelectSource(IList<SourceState> connectedSources)
        {
            if (_settings.AutoSelectSource)
                return connectedSources.OrderByDescending(value => value.LastActivityMilliseconds).FirstOrDefault();

            return connectedSources
                .Where(value => _settings.ManualProcessId == 0 ||
                                value.Identity.Key.ProcessId == _settings.ManualProcessId)
                .Where(value => string.IsNullOrEmpty(_settings.ManualSessionId) ||
                                string.Equals(value.Identity.Key.SessionId,
                                              _settings.ManualSessionId,
                                              StringComparison.Ordinal))
                .OrderByDescending(value => value.LastActivityMilliseconds)
                .FirstOrDefault();
        }

        private ClippingSnapshot BuildSnapshot(IList<SourceState> connectedSources, SourceState selected)
        {
            var snapshot = new ClippingSnapshot
            {
                SourceCount = connectedSources.Count,
                Connected = selected != null,
                ManualSourceAvailable = _settings.AutoSelectSource || selected != null,
                SelectionMode = _settings.AutoSelectSource ? "Automatic" : "Manual",
                AnyClipping = connectedSources.Any(value => value.StateReliable && value.IsClipping),
                ProtocolErrors = _protocolErrors,
                EntryThreshold = _settings.EntryThresholdPercent / 100.0,
                ExitThreshold = _settings.ExitThresholdPercent / 100.0,
                RatioWindowMilliseconds = _settings.RatioWindowMilliseconds,
            };

            if (selected == null)
            {
                snapshot.StatusText = connectedSources.Count == 0
                    ? "等待 DirectInput 遙測"
                    : "手動指定的來源目前不可用";
                snapshot.DroppedFrames = AggregateDrops(connectedSources);
                return snapshot;
            }

            snapshot.SelectedProcessName = selected.Identity.ProcessName;
            snapshot.SelectedProcessId = selected.Identity.Key.ProcessId;
            snapshot.SelectedSessionId = selected.Identity.Key.SessionId;
            snapshot.ProxyBuildVersion = selected.Identity.BuildVersion;
            snapshot.ProducerBitness = selected.Identity.Bitness;
            snapshot.CommandLevel = selected.CommandLevel;
            snapshot.PeakCommandLevel = selected.PeakCommandLevel;
            snapshot.EffectiveCommandLevel = selected.EffectiveCommandLevel;
            snapshot.EffectGain = selected.SelectedEffectGain;
            snapshot.DeviceGain = selected.SelectedDeviceGain;
            snapshot.DataReliable = selected.StateReliable;
            snapshot.AtLimit = selected.StateReliable && selected.AtLimit;
            snapshot.IsClipping = selected.StateReliable && selected.IsClipping;
            snapshot.ClipRatio = selected.ClipRatio;
            snapshot.ActiveEffectCount = selected.ActiveEffectCount;
            snapshot.UnsupportedEffectCount = selected.UnsupportedEffectCount;
            snapshot.LastEffectKind = selected.LastEffectKind.ToString();
            snapshot.DroppedFrames = selected.DroppedFrames;
            snapshot.StatusText = !selected.StateReliable
                ? "資料缺口：已停用舊狀態，請重啟遊戲建立新 session"
                : selected.IsClipping
                    ? "CLIP：DirectInput 命令持續碰頂"
                    : selected.AtLimit ? "LIMIT：命令已達進入門檻" : "監測中";
            return snapshot;
        }

        private static ulong AggregateDrops(IEnumerable<SourceState> sources)
        {
            ulong total = 0;
            foreach (var source in sources)
            {
                var remaining = ulong.MaxValue - total;
                total += source.DroppedFrames > remaining ? remaining : source.DroppedFrames;
            }
            return total;
        }

        private void TrimDisconnectedSources()
        {
            if (_sources.Count < 64) return;
            var candidate = _sources.Values.Where(value => !value.Connected)
                .OrderBy(value => value.LastActivityMilliseconds).FirstOrDefault();
            if (candidate != null) _sources.Remove(candidate.Identity.Key);
        }

        private sealed class SourceState
        {
            private const uint DiepGain = 0x00000004;
            private const uint DiepTypeSpecificParameters = 0x00000100;
            private const uint DiepDuration = 0x00000001;
            private const uint DiepStartDelay = 0x00000200;
            private const uint DiepStart = 0x20000000;
            private const uint DiesSolo = 0x00000001;
            private const int DiEffectRestarted = 0x00000004;
            private const uint DisffcReset = 0x00000001;
            private const uint DisffcStopAll = 0x00000002;
            private const uint DisffcPause = 0x00000004;
            private const uint DisffcContinue = 0x00000008;
            private const uint DisffcActuatorsOn = 0x00000010;
            private const uint DisffcActuatorsOff = 0x00000020;

            private readonly Dictionary<EffectKey, EffectState> _effects = new Dictionary<EffectKey, EffectState>();
            private readonly Dictionary<uint, DeviceState> _devices = new Dictionary<uint, DeviceState>();
            private readonly LinkedList<ClipInterval> _history = new LinkedList<ClipInterval>();
            private double _lastTickMilliseconds = -1;
            private bool _lastAtLimit;
            private bool _lastBelowExit = true;
            private double _continuousLimitMilliseconds;
            private double _continuousBelowExitMilliseconds;

            internal SourceState(SourceIdentity identity) { Identity = identity; }
            internal SourceIdentity Identity { get; set; }
            internal HashSet<Guid> Connections { get; } = new HashSet<Guid>();
            internal bool Connected => Connections.Count != 0;
            internal double LastActivityMilliseconds { get; set; }
            internal double CommandLevel { get; private set; }
            internal double PeakCommandLevel { get; private set; }
            internal double EffectiveCommandLevel { get; private set; }
            internal double SelectedEffectGain { get; private set; } = 1.0;
            internal double SelectedDeviceGain { get; private set; } = 1.0;
            internal bool AtLimit { get; private set; }
            internal bool IsClipping { get; private set; }
            internal double ClipRatio { get; private set; }
            internal int ActiveEffectCount { get; private set; }
            internal int UnsupportedEffectCount { get; private set; }
            internal EffectKind LastEffectKind { get; private set; } = EffectKind.Unknown;
            internal ulong DroppedFrames { get; private set; }
            internal bool StateReliable { get; private set; } = true;

            internal void Apply(ProtocolFrame frame, double nowMilliseconds)
            {
                if (frame.MessageType == MessageType.DropNotice)
                {
                    if (frame.Dropped > DroppedFrames)
                        InvalidateAfterDrop(nowMilliseconds);
                    DroppedFrames = Math.Max(DroppedFrames, frame.Dropped);
                    return;
                }
                if (frame.HResult < 0 && frame.MessageType != MessageType.Hello) return;

                switch (frame.MessageType)
                {
                    case MessageType.DevicePropertyChanged:
                        if (frame.PropertyId == 1)
                            GetDevice(frame.DeviceId).Gain = NormalizeUnsigned(frame.Gain);
                        break;
                    case MessageType.EffectCreated:
                        ApplyEffectCreated(frame);
                        break;
                    case MessageType.EffectParametersChanged:
                        ApplyEffectParameters(frame, nowMilliseconds);
                        break;
                    case MessageType.EffectCommand:
                        ApplyEffectCommand(frame, nowMilliseconds);
                        break;
                    case MessageType.DeviceCommand:
                        ApplyDeviceCommand(frame.DeviceId, frame.DiFlags, nowMilliseconds);
                        break;
                }
            }

            internal DetectorTransitionKind? Tick(double nowMilliseconds, DetectorSettings settings)
            {
                EvaluateEffects(nowMilliseconds);
                if (!StateReliable)
                {
                    AtLimit = false;
                    ClipRatio = 0;
                    return null;
                }
                var entry = settings.EntryThresholdPercent / 100.0;
                var exit = settings.ExitThresholdPercent / 100.0;
                var currentAtLimit = CommandLevel >= entry;
                var currentBelowExit = CommandLevel < exit;

                if (_lastTickMilliseconds < 0 || nowMilliseconds < _lastTickMilliseconds ||
                    nowMilliseconds - _lastTickMilliseconds > Math.Max(250.0, settings.RatioWindowMilliseconds))
                {
                    _history.Clear();
                    _continuousLimitMilliseconds = 0;
                    _continuousBelowExitMilliseconds = 0;
                    _lastTickMilliseconds = nowMilliseconds;
                    _lastAtLimit = currentAtLimit;
                    _lastBelowExit = currentBelowExit;
                }
                else
                {
                    var delta = nowMilliseconds - _lastTickMilliseconds;
                    if (delta > 0)
                    {
                        _history.AddLast(new ClipInterval(_lastTickMilliseconds, nowMilliseconds, _lastAtLimit));
                        _continuousLimitMilliseconds = _lastAtLimit
                            ? _continuousLimitMilliseconds + delta : 0;
                        _continuousBelowExitMilliseconds = _lastBelowExit
                            ? _continuousBelowExitMilliseconds + delta : 0;
                    }
                    if (currentAtLimit != _lastAtLimit && currentAtLimit)
                        _continuousLimitMilliseconds = 0;
                    if (currentBelowExit != _lastBelowExit && currentBelowExit)
                        _continuousBelowExitMilliseconds = 0;
                    _lastTickMilliseconds = nowMilliseconds;
                    _lastAtLimit = currentAtLimit;
                    _lastBelowExit = currentBelowExit;
                }

                AtLimit = currentAtLimit;
                ClipRatio = CalculateRatio(nowMilliseconds, settings.RatioWindowMilliseconds);
                if (!IsClipping && (_continuousLimitMilliseconds >= settings.ContinuousLimitMilliseconds ||
                                    ClipRatio >= settings.RatioTriggerPercent / 100.0))
                {
                    IsClipping = true;
                    return DetectorTransitionKind.ClippingStarted;
                }
                if (IsClipping && currentBelowExit &&
                    _continuousBelowExitMilliseconds >= settings.ExitHoldMilliseconds)
                {
                    IsClipping = false;
                    // The completed episode must not immediately re-trigger
                    // from its own still-visible trailing-window samples.
                    _history.Clear();
                    ClipRatio = 0;
                    _continuousLimitMilliseconds = 0;
                    return DetectorTransitionKind.ClippingEnded;
                }
                return null;
            }

            internal void ResetPeak() { PeakCommandLevel = CommandLevel; }

            internal void ResetAfterDisconnect(double nowMilliseconds)
            {
                foreach (var effect in _effects.Values) effect.Active = false;
                // Protocol v1 has no complete-state replay on reconnect. A
                // same-session reconnect after this reset therefore cannot
                // claim that an already-running effect is fully known.
                StateReliable = false;
                IsClipping = false;
                AtLimit = false;
                CommandLevel = 0;
                EffectiveCommandLevel = 0;
                ClipRatio = 0;
                _history.Clear();
                _continuousLimitMilliseconds = 0;
                _continuousBelowExitMilliseconds = 0;
                _lastTickMilliseconds = nowMilliseconds;
                _lastAtLimit = false;
                _lastBelowExit = true;
            }

            private void InvalidateAfterDrop(double nowMilliseconds)
            {
                // A lost Stop/Release/parameter frame can otherwise leave a
                // stale effect clipping forever.  There is no complete-state
                // replay in protocol v1, so fail closed and disclose that the
                // source is unreliable until a fresh producer session.
                StateReliable = false;
                IsClipping = false;
                _effects.Clear();
                _devices.Clear();
                CommandLevel = 0;
                EffectiveCommandLevel = 0;
                SelectedEffectGain = 1;
                SelectedDeviceGain = 1;
                ActiveEffectCount = 0;
                UnsupportedEffectCount = 0;
                AtLimit = false;
                ClipRatio = 0;
                _history.Clear();
                _continuousLimitMilliseconds = 0;
                _continuousBelowExitMilliseconds = 0;
                _lastTickMilliseconds = nowMilliseconds;
                _lastAtLimit = false;
                _lastBelowExit = true;
            }

            private void ApplyEffectCreated(ProtocolFrame frame)
            {
                if (frame.EffectId == 0) return;
                var effect = new EffectState(frame.DeviceId, frame.EffectId)
                {
                    Kind = frame.EffectKind,
                    Gain = NormalizeUnsigned(frame.Gain),
                    DurationMicroseconds = frame.Duration,
                    StartDelayMicroseconds = frame.StartDelay,
                    Magnitude = frame.Magnitude,
                    RampStart = frame.RampStart,
                    RampEnd = frame.RampEnd,
                    PeriodicMagnitude = frame.PeriodicMagnitude,
                    PeriodicOffset = frame.PeriodicOffset,
                };
                _effects[new EffectKey(frame.DeviceId, frame.EffectId)] = effect;
                LastEffectKind = effect.Kind;
            }

            private void ApplyEffectParameters(ProtocolFrame frame, double nowMilliseconds)
            {
                if (frame.EffectId == 0) return;
                var key = new EffectKey(frame.DeviceId, frame.EffectId);
                EffectState effect;
                var created = !_effects.TryGetValue(key, out effect);
                if (created)
                {
                    effect = new EffectState(frame.DeviceId, frame.EffectId);
                    _effects[key] = effect;
                }
                var device = GetDevice(effect.DeviceId);
                if (effect.Active && !device.Paused)
                    effect.ExpireIfFinished(nowMilliseconds);
                if (frame.EffectKind != EffectKind.Unknown) effect.Kind = frame.EffectKind;
                if ((frame.Flags & DiepDuration) != 0)
                    effect.DurationMicroseconds = frame.Duration;
                if ((frame.Flags & DiepStartDelay) != 0)
                    effect.StartDelayMicroseconds = frame.StartDelay;
                if ((frame.Flags & DiepGain) != 0) effect.Gain = NormalizeUnsigned(frame.Gain);
                if ((frame.Flags & DiepTypeSpecificParameters) != 0)
                {
                    effect.Magnitude = frame.Magnitude;
                    effect.RampStart = frame.RampStart;
                    effect.RampEnd = frame.RampEnd;
                    effect.PeriodicMagnitude = frame.PeriodicMagnitude;
                    effect.PeriodicOffset = frame.PeriodicOffset;
                }
                if ((frame.Flags & DiepStart) != 0)
                    effect.Begin(nowMilliseconds, 1);
                else if (effect.Active &&
                         ((frame.Flags & (DiepDuration | DiepStartDelay)) != 0))
                    effect.RefreshSchedule();
                if ((frame.HResult & DiEffectRestarted) != 0)
                    effect.Begin(nowMilliseconds, effect.Iterations);
                LastEffectKind = effect.Kind;
            }

            private void ApplyEffectCommand(ProtocolFrame frame, double nowMilliseconds)
            {
                var key = new EffectKey(frame.DeviceId, frame.EffectId);
                EffectState effect;
                if (!_effects.TryGetValue(key, out effect))
                {
                    if (frame.EffectCommand != EffectCommand.Start) return;
                    effect = new EffectState(frame.DeviceId, frame.EffectId) { Kind = frame.EffectKind };
                    _effects[key] = effect;
                }
                if (frame.EffectKind != EffectKind.Unknown) effect.Kind = frame.EffectKind;
                LastEffectKind = effect.Kind;
                switch (frame.EffectCommand)
                {
                    case EffectCommand.Start:
                        if ((frame.Flags & DiesSolo) != 0)
                            foreach (var other in _effects.Values.Where(value =>
                                         value.DeviceId == frame.DeviceId && value.EffectId != frame.EffectId))
                                other.Stop();
                        effect.Begin(nowMilliseconds, frame.Iterations);
                        break;
                    case EffectCommand.Stop:
                    case EffectCommand.Unload:
                        effect.Stop();
                        break;
                    case EffectCommand.Release:
                        _effects.Remove(key);
                        break;
                }
            }

            private void ApplyDeviceCommand(uint deviceId, uint command, double nowMilliseconds)
            {
                var device = GetDevice(deviceId);
                if ((command & DisffcReset) != 0)
                {
                    // Reset unloads hardware slots but the DirectInput effect
                    // objects (and their parameter definitions) can be
                    // downloaded and started again. Keep the cached scalar
                    // parameters while stopping playback.
                    foreach (var effect in _effects.Values.Where(value => value.DeviceId == deviceId))
                        effect.Stop();
                    device.Paused = false;
                    device.ActuatorsEnabled = false;
                }
                if ((command & DisffcStopAll) != 0)
                {
                    foreach (var effect in _effects.Values.Where(value => value.DeviceId == deviceId))
                        effect.Stop();
                    device.Paused = false;
                }
                if ((command & DisffcPause) != 0 && !device.Paused)
                {
                    device.Paused = true;
                    device.PausedAtMilliseconds = nowMilliseconds;
                }
                if ((command & DisffcContinue) != 0 && device.Paused)
                {
                    foreach (var effect in _effects.Values.Where(value => value.DeviceId == deviceId))
                        effect.ResumeAfterPause(device.PausedAtMilliseconds, nowMilliseconds);
                    device.Paused = false;
                }
                if ((command & DisffcActuatorsOff) != 0) device.ActuatorsEnabled = false;
                if ((command & DisffcActuatorsOn) != 0) device.ActuatorsEnabled = true;
            }

            private void EvaluateEffects(double nowMilliseconds)
            {
                CommandLevel = 0;
                EffectiveCommandLevel = 0;
                SelectedEffectGain = 1;
                SelectedDeviceGain = 1;
                ActiveEffectCount = 0;
                UnsupportedEffectCount = 0;
                foreach (var effect in _effects.Values)
                {
                    var device = GetDevice(effect.DeviceId);
                    // Pausing stops the effect clock; disabled actuators only
                    // mute output while the finite-duration clock continues.
                    if (device.Paused) continue;
                    if (!effect.IsProducing(nowMilliseconds) || !device.ActuatorsEnabled) continue;
                    ActiveEffectCount++;
                    if (!effect.IsSupported)
                    {
                        UnsupportedEffectCount++;
                        continue;
                    }
                    var raw = effect.RawLevel;
                    if (raw >= CommandLevel)
                    {
                        CommandLevel = raw;
                        SelectedEffectGain = effect.Gain;
                        SelectedDeviceGain = device.Gain;
                        EffectiveCommandLevel = Clamp01(raw * effect.Gain * device.Gain);
                    }
                }
                PeakCommandLevel = Math.Max(PeakCommandLevel, CommandLevel);
            }

            private double CalculateRatio(double nowMilliseconds, int windowMilliseconds)
            {
                var cutoff = nowMilliseconds - windowMilliseconds;
                while (_history.First != null && _history.First.Value.End <= cutoff)
                    _history.RemoveFirst();
                double clipped = 0;
                foreach (var interval in _history)
                {
                    if (!interval.Clipped) continue;
                    clipped += Math.Max(0, interval.End - Math.Max(interval.Start, cutoff));
                }
                return Clamp01(clipped / windowMilliseconds);
            }

            private DeviceState GetDevice(uint deviceId)
            {
                DeviceState device;
                if (!_devices.TryGetValue(deviceId, out device))
                {
                    device = new DeviceState();
                    _devices.Add(deviceId, device);
                }
                return device;
            }

            private static double NormalizeUnsigned(uint value) { return Clamp01(value / 10000.0); }
            private static double Clamp01(double value) { return Math.Max(0, Math.Min(1, value)); }
        }

        private struct EffectKey : IEquatable<EffectKey>
        {
            internal EffectKey(uint deviceId, uint effectId) { DeviceId = deviceId; EffectId = effectId; }
            internal uint DeviceId { get; }
            internal uint EffectId { get; }
            public bool Equals(EffectKey other) { return DeviceId == other.DeviceId && EffectId == other.EffectId; }
            public override bool Equals(object obj) { return obj is EffectKey && Equals((EffectKey)obj); }
            public override int GetHashCode() { unchecked { return ((int)DeviceId * 397) ^ (int)EffectId; } }
        }

        private sealed class DeviceState
        {
            internal double Gain { get; set; } = 1.0;
            internal bool Paused { get; set; }
            internal double PausedAtMilliseconds { get; set; }
            internal bool ActuatorsEnabled { get; set; } = true;
        }

        private sealed class EffectState
        {
            internal EffectState(uint deviceId, uint effectId) { DeviceId = deviceId; EffectId = effectId; }
            internal uint DeviceId { get; }
            internal uint EffectId { get; }
            internal EffectKind Kind { get; set; }
            internal bool Active { get; set; }
            internal uint DurationMicroseconds { get; set; } = uint.MaxValue;
            internal uint StartDelayMicroseconds { get; set; }
            internal uint Iterations { get; private set; } = 1;
            internal double PlaybackRequestedMilliseconds { get; private set; }
            internal double ActiveFromMilliseconds { get; private set; }
            internal double ActiveUntilMilliseconds { get; private set; } = double.PositiveInfinity;
            internal double Gain { get; set; } = 1.0;
            internal int Magnitude { get; set; }
            internal int RampStart { get; set; }
            internal int RampEnd { get; set; }
            internal int PeriodicMagnitude { get; set; }
            internal int PeriodicOffset { get; set; }
            internal void Begin(double nowMilliseconds, uint iterations)
            {
                Active = true;
                Iterations = iterations == 0 ? 1u : iterations;
                PlaybackRequestedMilliseconds = nowMilliseconds;
                RefreshSchedule();
            }
            internal void RefreshSchedule()
            {
                ActiveFromMilliseconds = PlaybackRequestedMilliseconds + StartDelayMicroseconds / 1000.0;
                if (DurationMicroseconds == uint.MaxValue || Iterations == uint.MaxValue)
                {
                    ActiveUntilMilliseconds = double.PositiveInfinity;
                    return;
                }
                ActiveUntilMilliseconds = ActiveFromMilliseconds +
                    DurationMicroseconds / 1000.0 * Iterations;
            }
            internal void ShiftSchedule(double milliseconds)
            {
                if (!Active || milliseconds <= 0) return;
                PlaybackRequestedMilliseconds += milliseconds;
                ActiveFromMilliseconds += milliseconds;
                if (!double.IsPositiveInfinity(ActiveUntilMilliseconds))
                    ActiveUntilMilliseconds += milliseconds;
            }
            internal void ResumeAfterPause(double pausedAtMilliseconds, double nowMilliseconds)
            {
                // An effect started while the whole device was already
                // paused only needs the portion of the pause after its own
                // Start call shifted; applying the full device pause would
                // defer it twice.
                var effectivePauseStart = Math.Max(
                    pausedAtMilliseconds, PlaybackRequestedMilliseconds);
                ShiftSchedule(Math.Max(0, nowMilliseconds - effectivePauseStart));
            }
            internal bool IsProducing(double nowMilliseconds)
            {
                if (!Active || nowMilliseconds < ActiveFromMilliseconds) return false;
                ExpireIfFinished(nowMilliseconds);
                return Active;
            }
            internal void ExpireIfFinished(double nowMilliseconds)
            {
                if (Active && nowMilliseconds >= ActiveUntilMilliseconds)
                    Active = false;
            }
            internal void Stop()
            {
                Active = false;
                ActiveUntilMilliseconds = double.PositiveInfinity;
            }
            internal bool IsSupported => Kind == EffectKind.Constant || Kind == EffectKind.Ramp || IsPeriodic(Kind);
            internal double RawLevel
            {
                get
                {
                    long value;
                    if (Kind == EffectKind.Constant) value = Math.Abs((long)Magnitude);
                    else if (Kind == EffectKind.Ramp)
                        value = Math.Max(Math.Abs((long)RampStart), Math.Abs((long)RampEnd));
                    else if (IsPeriodic(Kind))
                        value = Math.Abs((long)PeriodicMagnitude) + Math.Abs((long)PeriodicOffset);
                    else return 0;
                    return Math.Max(0, Math.Min(1, value / 10000.0));
                }
            }
            private static bool IsPeriodic(EffectKind kind)
            {
                return kind == EffectKind.Square || kind == EffectKind.Sine ||
                       kind == EffectKind.Triangle || kind == EffectKind.SawtoothUp ||
                       kind == EffectKind.SawtoothDown;
            }
        }

        private struct ClipInterval
        {
            internal ClipInterval(double start, double end, bool clipped)
            {
                Start = start; End = end; Clipped = clipped;
            }
            internal double Start { get; }
            internal double End { get; }
            internal bool Clipped { get; }
        }
    }
}
