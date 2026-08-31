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
        private const int MaximumSources = 64;
        private readonly object _gate = new object();
        private readonly Dictionary<SourceKey, SourceState> _sources = new Dictionary<SourceKey, SourceState>();
        private readonly ConcurrentQueue<DetectorTransition> _transitions = new ConcurrentQueue<DetectorTransition>();
        private DetectorSettings _settings;
        private ulong _protocolErrors;
        private ulong _sourceStateDrops;
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
                    if (!TryMakeSourceRoom())
                    {
                        _sourceStateDrops = SaturatingIncrement(_sourceStateDrops);
                        return;
                    }
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
                    _protocolErrors = SaturatingIncrement(_protocolErrors);
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
            lock (_gate) _protocolErrors = SaturatingIncrement(_protocolErrors);
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
                AnyClipping = _sourceStateDrops == 0 &&
                              connectedSources.Any(value => value.EstimateReliable && value.IsClipping),
                ProtocolErrors = _protocolErrors,
                SourceStateDrops = _sourceStateDrops,
                StateCapacityDrops = _sourceStateDrops,
                ReliabilityIssues = _sourceStateDrops == 0
                    ? DetectorReliabilityIssue.None
                    : DetectorReliabilityIssue.StateCapacityExceeded,
                ReliabilityReason = _sourceStateDrops == 0
                    ? DetectorReliabilityIssue.None.ToString()
                    : DetectorReliabilityIssue.StateCapacityExceeded.ToString(),
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
                snapshot.DeviceStateDrops = AggregateDeviceStateDrops(connectedSources);
                snapshot.EffectStateDrops = AggregateEffectStateDrops(connectedSources);
                snapshot.StateCapacityDrops = SaturatingAdd(
                    snapshot.SourceStateDrops,
                    SaturatingAdd(snapshot.DeviceStateDrops, snapshot.EffectStateDrops));
                snapshot.ModelLimited = snapshot.StateCapacityDrops != 0;
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
            snapshot.CombinedCommandLevel = selected.CombinedCommandLevel;
            snapshot.UnclampedCombinedCommandLevel = selected.UnclampedCombinedCommandLevel;
            snapshot.CombinedEffectiveCommandLevel = selected.CombinedEffectiveCommandLevel;
            snapshot.PeakCombinedCommandLevel = selected.PeakCombinedCommandLevel;
            snapshot.PeakUnclampedCombinedCommandLevel = selected.PeakUnclampedCombinedCommandLevel;
            snapshot.DetectionLevel = selected.CombinedCommandLevel;
            snapshot.EffectGain = selected.SelectedEffectGain;
            snapshot.DeviceGain = selected.SelectedDeviceGain;
            snapshot.DataReliable = _sourceStateDrops == 0 && selected.EstimateReliable;
            snapshot.AtLimit = snapshot.DataReliable && selected.AtLimit;
            snapshot.IsClipping = snapshot.DataReliable && selected.IsClipping;
            snapshot.ClipRatio = selected.ClipRatio;
            snapshot.ActiveEffectCount = selected.ActiveEffectCount;
            snapshot.UnsupportedEffectCount = selected.UnsupportedEffectCount;
            snapshot.UnobservedTriggerEffectCount = selected.UnobservedTriggerEffectCount;
            snapshot.LastEffectKind = selected.LastEffectKind.ToString();
            snapshot.DroppedFrames = selected.DroppedFrames;
            snapshot.DeviceStateDrops = selected.DeviceStateDrops;
            snapshot.EffectStateDrops = selected.EffectStateDrops;
            snapshot.StateCapacityDrops = SaturatingAdd(
                snapshot.SourceStateDrops,
                SaturatingAdd(snapshot.DeviceStateDrops, snapshot.EffectStateDrops));
            snapshot.ReliabilityIssues = selected.ReliabilityIssues;
            if (_sourceStateDrops != 0)
                snapshot.ReliabilityIssues |= DetectorReliabilityIssue.StateCapacityExceeded;
            snapshot.ReliabilityReason = snapshot.ReliabilityIssues.ToString();
            snapshot.ModelLimited = snapshot.ReliabilityIssues != DetectorReliabilityIssue.None ||
                                    selected.UnsupportedEffectCount != 0;
            snapshot.StatusText = BuildStatusText(selected, snapshot.ReliabilityIssues);
            return snapshot;
        }

        private static string BuildStatusText(SourceState selected, DetectorReliabilityIssue issues)
        {
            if ((issues & (DetectorReliabilityIssue.FrameGap |
                           DetectorReliabilityIssue.SessionReconnect)) != 0)
                return "資料缺口：已停用舊狀態，請重啟遊戲建立新 session";
            if ((issues & DetectorReliabilityIssue.StateCapacityExceeded) != 0)
                return "狀態容量已達上限：部分來源、裝置或效果未納入，已停用削峰判定";
            if ((issues & DetectorReliabilityIssue.TriggerStateUnavailable) != 0)
                return "模型限制：TriggerButton 按鍵狀態未提供，已停用削峰判定";
            if (selected.IsClipping) return "CLIP：DirectInput 命令持續碰頂";
            if (selected.AtLimit) return "LIMIT：多效果命令保守上界已達進入門檻";
            return selected.UnsupportedEffectCount == 0
                ? "監測中"
                : "監測中：不支援的效果未納入削峰模型";
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

        private static ulong AggregateDeviceStateDrops(IEnumerable<SourceState> sources)
        {
            return AggregateCounter(sources, value => value.DeviceStateDrops);
        }

        private static ulong AggregateEffectStateDrops(IEnumerable<SourceState> sources)
        {
            return AggregateCounter(sources, value => value.EffectStateDrops);
        }

        private static ulong AggregateCounter(
            IEnumerable<SourceState> sources, Func<SourceState, ulong> selector)
        {
            ulong total = 0;
            foreach (var source in sources) total = SaturatingAdd(total, selector(source));
            return total;
        }

        private static ulong SaturatingIncrement(ulong value)
        {
            return value == ulong.MaxValue ? value : value + 1;
        }

        private static ulong SaturatingAdd(ulong left, ulong right)
        {
            return right > ulong.MaxValue - left ? ulong.MaxValue : left + right;
        }

        private bool TryMakeSourceRoom()
        {
            if (_sources.Count < MaximumSources) return true;
            var candidate = _sources.Values.Where(value => !value.Connected)
                .OrderBy(value => value.LastActivityMilliseconds).FirstOrDefault();
            if (candidate != null) _sources.Remove(candidate.Identity.Key);
            return _sources.Count < MaximumSources;
        }

        private sealed class SourceState
        {
            private const int MaximumDevices = 64;
            private const int MaximumEffects = 1024;
            private const uint DiepGain = 0x00000004;
            private const uint DiepTypeSpecificParameters = 0x00000100;
            private const uint DiepDuration = 0x00000001;
            private const uint DiepStartDelay = 0x00000200;
            private const uint DiepTriggerButton = 0x00000008;
            private const uint DiepTriggerRepeatInterval = 0x00000010;
            private const uint DiepEnvelope = 0x00000080;
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
            private DetectorReliabilityIssue _persistentReliabilityIssues;

            internal SourceState(SourceIdentity identity) { Identity = identity; }
            internal SourceIdentity Identity { get; set; }
            internal HashSet<Guid> Connections { get; } = new HashSet<Guid>();
            internal bool Connected => Connections.Count != 0;
            internal double LastActivityMilliseconds { get; set; }
            internal double CommandLevel { get; private set; }
            internal double PeakCommandLevel { get; private set; }
            internal double EffectiveCommandLevel { get; private set; }
            internal double CombinedCommandLevel { get; private set; }
            internal double UnclampedCombinedCommandLevel { get; private set; }
            internal double CombinedEffectiveCommandLevel { get; private set; }
            internal double PeakCombinedCommandLevel { get; private set; }
            internal double PeakUnclampedCombinedCommandLevel { get; private set; }
            internal double SelectedEffectGain { get; private set; } = 1.0;
            internal double SelectedDeviceGain { get; private set; } = 1.0;
            internal bool AtLimit { get; private set; }
            internal bool IsClipping { get; private set; }
            internal double ClipRatio { get; private set; }
            internal int ActiveEffectCount { get; private set; }
            internal int UnsupportedEffectCount { get; private set; }
            internal int UnobservedTriggerEffectCount { get; private set; }
            internal EffectKind LastEffectKind { get; private set; } = EffectKind.Unknown;
            internal ulong DroppedFrames { get; private set; }
            internal ulong DeviceStateDrops { get; private set; }
            internal ulong EffectStateDrops { get; private set; }
            internal DetectorReliabilityIssue ReliabilityIssues =>
                _persistentReliabilityIssues |
                (UnobservedTriggerEffectCount == 0
                    ? DetectorReliabilityIssue.None
                    : DetectorReliabilityIssue.TriggerStateUnavailable);
            internal bool StateReliable =>
                (_persistentReliabilityIssues &
                 (DetectorReliabilityIssue.FrameGap |
                  DetectorReliabilityIssue.SessionReconnect |
                  DetectorReliabilityIssue.StateCapacityExceeded)) == 0;
            internal bool EstimateReliable => ReliabilityIssues == DetectorReliabilityIssue.None;

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
                    case MessageType.DeviceCreated:
                        GetOrCreateDevice(frame.DeviceId);
                        break;
                    case MessageType.DevicePropertyChanged:
                        if (frame.PropertyId == 1)
                        {
                            var propertyDevice = GetOrCreateDevice(frame.DeviceId);
                            if (propertyDevice != null)
                                propertyDevice.Gain = NormalizeUnsigned(frame.Gain);
                        }
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
                if (!EstimateReliable)
                {
                    var wasClipping = IsClipping;
                    IsClipping = false;
                    AtLimit = false;
                    ClipRatio = 0;
                    _history.Clear();
                    _continuousLimitMilliseconds = 0;
                    _continuousBelowExitMilliseconds = 0;
                    _lastTickMilliseconds = nowMilliseconds;
                    _lastAtLimit = false;
                    _lastBelowExit = true;
                    return wasClipping ? DetectorTransitionKind.ClippingEnded : (DetectorTransitionKind?)null;
                }
                var entry = settings.EntryThresholdPercent / 100.0;
                var exit = settings.ExitThresholdPercent / 100.0;
                var currentAtLimit = CombinedCommandLevel >= entry;
                var currentBelowExit = CombinedCommandLevel < exit;

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

            internal void ResetPeak()
            {
                PeakCommandLevel = CommandLevel;
                PeakCombinedCommandLevel = CombinedCommandLevel;
                PeakUnclampedCombinedCommandLevel = UnclampedCombinedCommandLevel;
            }

            internal void ResetAfterDisconnect(double nowMilliseconds)
            {
                foreach (var effect in _effects.Values) effect.Active = false;
                // Protocol v1 has no complete-state replay on reconnect. A
                // same-session reconnect after this reset therefore cannot
                // claim that an already-running effect is fully known.
                _persistentReliabilityIssues |= DetectorReliabilityIssue.SessionReconnect;
                IsClipping = false;
                AtLimit = false;
                CommandLevel = 0;
                EffectiveCommandLevel = 0;
                CombinedCommandLevel = 0;
                UnclampedCombinedCommandLevel = 0;
                CombinedEffectiveCommandLevel = 0;
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
                _persistentReliabilityIssues |= DetectorReliabilityIssue.FrameGap;
                IsClipping = false;
                _effects.Clear();
                _devices.Clear();
                CommandLevel = 0;
                EffectiveCommandLevel = 0;
                CombinedCommandLevel = 0;
                UnclampedCombinedCommandLevel = 0;
                CombinedEffectiveCommandLevel = 0;
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
                var key = new EffectKey(frame.DeviceId, frame.EffectId);
                if (!_effects.ContainsKey(key) && _effects.Count >= MaximumEffects)
                {
                    RecordEffectStateDrop();
                    return;
                }
                if (GetOrCreateDevice(frame.DeviceId) == null)
                {
                    RecordEffectStateDrop();
                    return;
                }
                var effect = new EffectState(frame.DeviceId, frame.EffectId)
                {
                    Kind = frame.EffectKind,
                };
                if (frame.EffectParameterPresence != EffectParameterPresence.Absent)
                {
                    // Unknown is the legacy protocol-v1 representation. Keep
                    // its previous payload interpretation for compatibility;
                    // a legacy zero trigger remains conservatively
                    // unobservable. Explicit Absent frames retain safe effect
                    // defaults until SetParameters supplies selected fields.
                    effect.Gain = NormalizeUnsigned(frame.Gain);
                    effect.DurationMicroseconds = frame.Duration;
                    effect.StartDelayMicroseconds = frame.StartDelay;
                    effect.Magnitude = frame.Magnitude;
                    effect.RampStart = frame.RampStart;
                    effect.RampEnd = frame.RampEnd;
                    effect.PeriodicMagnitude = frame.PeriodicMagnitude;
                    effect.PeriodicOffset = frame.PeriodicOffset;
                    effect.PeriodicPhase = frame.PeriodicPhase;
                    effect.PeriodicPeriodMicroseconds = unchecked((uint)frame.PeriodicPeriod);
                    effect.TriggerButton = frame.TriggerButton;
                    effect.TriggerRepeatMicroseconds = frame.TriggerRepeat;
                    effect.EnvelopeAttackLevel = frame.EnvelopeAttackLevel;
                    effect.EnvelopeAttackMicroseconds = frame.EnvelopeAttackTime;
                    effect.EnvelopeFadeLevel = frame.EnvelopeFadeLevel;
                    effect.EnvelopeFadeMicroseconds = frame.EnvelopeFadeTime;
                }
                _effects[key] = effect;
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
                    if (_effects.Count >= MaximumEffects)
                    {
                        RecordEffectStateDrop();
                        return;
                    }
                    if (GetOrCreateDevice(frame.DeviceId) == null)
                    {
                        RecordEffectStateDrop();
                        return;
                    }
                    effect = new EffectState(frame.DeviceId, frame.EffectId);
                    _effects[key] = effect;
                }
                var device = GetOrCreateDevice(effect.DeviceId);
                if (device == null) return;
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
                    effect.PeriodicPhase = frame.PeriodicPhase;
                    effect.PeriodicPeriodMicroseconds = unchecked((uint)frame.PeriodicPeriod);
                }
                if ((frame.Flags & DiepTriggerButton) != 0)
                    effect.TriggerButton = frame.TriggerButton;
                if ((frame.Flags & DiepTriggerRepeatInterval) != 0)
                    effect.TriggerRepeatMicroseconds = frame.TriggerRepeat;
                if ((frame.Flags & DiepEnvelope) != 0)
                {
                    effect.EnvelopeAttackLevel = frame.EnvelopeAttackLevel;
                    effect.EnvelopeAttackMicroseconds = frame.EnvelopeAttackTime;
                    effect.EnvelopeFadeLevel = frame.EnvelopeFadeLevel;
                    effect.EnvelopeFadeMicroseconds = frame.EnvelopeFadeTime;
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
                    if (_effects.Count >= MaximumEffects)
                    {
                        RecordEffectStateDrop();
                        return;
                    }
                    if (GetOrCreateDevice(frame.DeviceId) == null)
                    {
                        RecordEffectStateDrop();
                        return;
                    }
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
                var device = GetOrCreateDevice(deviceId);
                if (device == null) return;
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
                // CommandLevel and EffectiveCommandLevel intentionally retain
                // their v0.2 meaning: the largest single supported effect,
                // before and after gain.  The combined fields add a separate,
                // explainable mixer model.  Effects on the same device are
                // summed by absolute instantaneous magnitude, then the
                // busiest device is selected.  This cannot understate scalar
                // alignment, but may overstate forces whose vectors cancel;
                // it is therefore a clipping upper bound, not motor torque.
                CommandLevel = 0;
                EffectiveCommandLevel = 0;
                CombinedCommandLevel = 0;
                UnclampedCombinedCommandLevel = 0;
                CombinedEffectiveCommandLevel = 0;
                SelectedEffectGain = 1;
                SelectedDeviceGain = 1;
                ActiveEffectCount = 0;
                UnsupportedEffectCount = 0;
                UnobservedTriggerEffectCount = 0;
                UnobservedTriggerEffectCount = _effects.Values.Count(value => value.HasUnobservableTrigger);
                var commandByDevice = new Dictionary<uint, double>();
                var effectiveByDevice = new Dictionary<uint, double>();
                foreach (var effect in _effects.Values)
                {
                    DeviceState device;
                    if (!_devices.TryGetValue(effect.DeviceId, out device)) continue;
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
                    var raw = effect.RawLevelAt(nowMilliseconds);
                    if (raw >= CommandLevel)
                    {
                        CommandLevel = raw;
                        SelectedEffectGain = effect.Gain;
                        SelectedDeviceGain = device.Gain;
                        EffectiveCommandLevel = Clamp01(raw * effect.Gain * device.Gain);
                    }
                    double commandSum;
                    commandByDevice.TryGetValue(effect.DeviceId, out commandSum);
                    commandByDevice[effect.DeviceId] = commandSum + raw;
                    double effectiveSum;
                    effectiveByDevice.TryGetValue(effect.DeviceId, out effectiveSum);
                    effectiveByDevice[effect.DeviceId] = effectiveSum + raw * effect.Gain * device.Gain;
                }
                if (commandByDevice.Count != 0)
                    UnclampedCombinedCommandLevel = commandByDevice.Values.Max();
                if (effectiveByDevice.Count != 0)
                    CombinedEffectiveCommandLevel = Clamp01(effectiveByDevice.Values.Max());
                CombinedCommandLevel = Clamp01(UnclampedCombinedCommandLevel);
                PeakCommandLevel = Math.Max(PeakCommandLevel, CommandLevel);
                PeakCombinedCommandLevel = Math.Max(PeakCombinedCommandLevel, CombinedCommandLevel);
                PeakUnclampedCombinedCommandLevel = Math.Max(
                    PeakUnclampedCombinedCommandLevel, UnclampedCombinedCommandLevel);
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

            private DeviceState GetOrCreateDevice(uint deviceId)
            {
                DeviceState device;
                if (!_devices.TryGetValue(deviceId, out device))
                {
                    if (_devices.Count >= MaximumDevices)
                    {
                        RecordDeviceStateDrop();
                        return null;
                    }
                    device = new DeviceState();
                    _devices.Add(deviceId, device);
                }
                return device;
            }

            private void RecordDeviceStateDrop()
            {
                DeviceStateDrops = SaturatingIncrement(DeviceStateDrops);
                _persistentReliabilityIssues |= DetectorReliabilityIssue.StateCapacityExceeded;
            }

            private void RecordEffectStateDrop()
            {
                EffectStateDrops = SaturatingIncrement(EffectStateDrops);
                _persistentReliabilityIssues |= DetectorReliabilityIssue.StateCapacityExceeded;
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
            private const uint DiebNoTrigger = uint.MaxValue;

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
            internal int PeriodicPhase { get; set; }
            internal uint PeriodicPeriodMicroseconds { get; set; }
            internal uint TriggerButton { get; set; } = DiebNoTrigger;
            internal uint TriggerRepeatMicroseconds { get; set; }
            internal uint EnvelopeAttackLevel { get; set; }
            internal uint EnvelopeAttackMicroseconds { get; set; }
            internal uint EnvelopeFadeLevel { get; set; }
            internal uint EnvelopeFadeMicroseconds { get; set; }
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
            // A button-triggered effect can start in the driver without an
            // IDirectInputEffect::Start call. Protocol v1 carries the trigger
            // configuration but not input-button state, so it must never be
            // presented as a complete playback estimate.
            internal bool HasUnobservableTrigger => TriggerButton != DiebNoTrigger;
            internal bool IsSupported => Kind == EffectKind.Constant || Kind == EffectKind.Ramp ||
                                         (IsPeriodic(Kind) && PeriodicPeriodMicroseconds > 0);
            internal double RawLevelAt(double nowMilliseconds)
            {
                if (!IsSupported) return 0;
                var elapsed = IterationElapsedMilliseconds(nowMilliseconds);
                double command;
                if (Kind == EffectKind.Constant)
                {
                    command = ApplyEnvelopeToSigned(Magnitude / 10000.0, elapsed);
                }
                else if (Kind == EffectKind.Ramp)
                {
                    var progress = DurationMicroseconds == uint.MaxValue || DurationMicroseconds == 0
                        ? 0
                        : Clamp01(elapsed / (DurationMicroseconds / 1000.0));
                    var ramp = (RampStart + (RampEnd - (double)RampStart) * progress) / 10000.0;
                    command = ApplyEnvelopeToSigned(ramp, elapsed);
                }
                else
                {
                    var cycles = elapsed * 1000.0 / PeriodicPeriodMicroseconds +
                                 PeriodicPhase / 36000.0;
                    var phase = cycles - Math.Floor(cycles);
                    var baseline = PeriodicOffset / 10000.0;
                    var periodicAmplitude = EnvelopeAmplitudeAt(
                        elapsed, Math.Abs(PeriodicMagnitude / 10000.0));
                    command = baseline + (PeriodicMagnitude < 0 ? -1 : 1) *
                              periodicAmplitude * WaveformAt(Kind, phase);
                }
                return Clamp01(Math.Abs(command));
            }

            private double IterationElapsedMilliseconds(double nowMilliseconds)
            {
                var elapsed = Math.Max(0, nowMilliseconds - ActiveFromMilliseconds);
                if (DurationMicroseconds == uint.MaxValue || DurationMicroseconds == 0)
                    return elapsed;
                var durationMilliseconds = DurationMicroseconds / 1000.0;
                if (durationMilliseconds <= 0) return 0;
                return elapsed % durationMilliseconds;
            }

            private double ApplyEnvelopeToSigned(double sustain, double elapsedMilliseconds)
            {
                var direction = sustain < 0 ? -1 : 1;
                return direction * EnvelopeAmplitudeAt(elapsedMilliseconds, Math.Abs(sustain));
            }

            private double EnvelopeAmplitudeAt(double elapsedMilliseconds, double sustainAmplitude)
            {
                if (!HasEnvelope) return sustainAmplitude;

                var attackMilliseconds = EnvelopeAttackMicroseconds / 1000.0;
                if (attackMilliseconds > 0 && elapsedMilliseconds < attackMilliseconds)
                {
                    var attackStart = Clamp01(EnvelopeAttackLevel / 10000.0);
                    return attackStart + (sustainAmplitude - attackStart) *
                           Clamp01(elapsedMilliseconds / attackMilliseconds);
                }

                if (DurationMicroseconds != uint.MaxValue && EnvelopeFadeMicroseconds != 0)
                {
                    var durationMilliseconds = DurationMicroseconds / 1000.0;
                    var fadeMilliseconds = EnvelopeFadeMicroseconds / 1000.0;
                    var fadeStart = Math.Max(0, durationMilliseconds - fadeMilliseconds);
                    if (elapsedMilliseconds >= fadeStart)
                    {
                        var fadeEnd = Clamp01(EnvelopeFadeLevel / 10000.0);
                        var fadeProgress = fadeMilliseconds <= 0
                            ? 1
                            : Clamp01((elapsedMilliseconds - fadeStart) / fadeMilliseconds);
                        return sustainAmplitude + (fadeEnd - sustainAmplitude) * fadeProgress;
                    }
                }
                return sustainAmplitude;
            }

            private bool HasEnvelope => EnvelopeAttackLevel != 0 || EnvelopeAttackMicroseconds != 0 ||
                                        EnvelopeFadeLevel != 0 || EnvelopeFadeMicroseconds != 0;

            private static double WaveformAt(EffectKind kind, double phase)
            {
                if (kind == EffectKind.Sine)
                    return Math.Sin(2 * Math.PI * phase);
                if (kind == EffectKind.Square)
                    return phase < 0.5 ? 1 : -1;
                if (kind == EffectKind.Triangle)
                    return 1 - 4 * Math.Min(phase, 1 - phase);
                if (kind == EffectKind.SawtoothUp)
                    return 2 * phase - 1;
                if (kind == EffectKind.SawtoothDown)
                    return 1 - 2 * phase;
                return 0;
            }

            private static double Clamp01(double value)
            {
                return Math.Max(0, Math.Min(1, value));
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
