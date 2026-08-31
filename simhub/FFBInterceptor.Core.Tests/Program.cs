// SPDX-License-Identifier: GPL-3.0-only
using FFBInterceptor.Core;
using System;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Diagnostics;
using System.Text;
using System.Threading;

namespace FFBInterceptor.Core.Tests
{
    internal static class Program
    {
        private static int _tests;

        private static int Main()
        {
            try
            {
                Run("golden protocol fixture", GoldenProtocolFixture);
                Run("effect parameter presence uses protocol-v1 flags", EffectParameterPresenceFlags);
                Run("fragmented stream", FragmentedStream);
                Run("malformed protocol rejected", MalformedProtocolRejected);
                Run("invalid UTF-8 rejected", InvalidUtf8Rejected);
                Run("long valid UTF-8 accepted", LongValidUtf8Accepted);
                Run("secure pipe verifies and accepts local producer", SecurePipeHandshake);
                Run("secure pipe stop is prompt and restartable", SecurePipeStopsAndRestarts);
                Run("secure pipe rejects out-of-order sequence", SecurePipeRejectsOutOfOrderSequence);
                Run("98 percent ratio trigger and hysteretic exit", RatioTriggerAndExit);
                Run("gain does not hide command clipping", GainDoesNotHideClipping);
                Run("same-device effects use a conservative absolute-sum bound", SameDeviceEffectsUseConservativeBound);
                Run("different devices are not summed together", DifferentDevicesAreNotSummed);
                Run("periodic waveforms use phase, period, and elapsed time", PeriodicWaveformsAreInstantaneous);
                Run("periodic partial updates replace phase and period", PeriodicPartialUpdateChangesWave);
                Run("ramp effect follows playback time", RampFollowsPlaybackTime);
                Run("envelope attack and fade alter instantaneous amplitude", EnvelopeShapesAmplitude);
                Run("triggered effects disclose unavailable button state", TriggerStateIsDisclosed);
                Run("null-created partial effect remains reliable", NullCreatedPartialEffectRemainsReliable);
                Run("zero-period waveform is reported unsupported", ZeroPeriodIsUnsupported);
                Run("unsigned high-bit periodic duration stays supported", HighBitPeriodIsSupported);
                Run("device state capacity is bounded and observable", DeviceStateCapacityIsBounded);
                Run("effect state capacity is bounded and observable", EffectStateCapacityIsBounded);
                Run("source state capacity is bounded and observable", SourceStateCapacityIsBounded);
                Run("partial parameter updates preserve level", PartialUpdatePreservesLevel);
                Run("condition effect is unsupported", ConditionIsUnsupported);
                Run("manual source selection", ManualSourceSelection);
                Run("finite effect expires after all iterations", FiniteEffectExpires);
                Run("start delay defers command output", StartDelayDefersOutput);
                Run("duration update uses original playback origin", DurationUpdateUsesPlaybackOrigin);
                Run("drop notice invalidates stale state", DropNoticeInvalidatesState);
                Run("partial update can rebuild with safe defaults", PartialUpdateRebuildsSafely);
                Run("pause freezes finite effect clock", PauseFreezesEffectClock);
                Run("effect started while paused shifts only remaining pause", EffectStartedDuringPause);
                Run("actuator mute does not freeze effect clock", ActuatorMuteDoesNotFreezeClock);
                Run("global clipping event gate pairs overlapping sources", GlobalEventGatePairsEdges);
                Run("source events follow published count changes", SourceEventGateFollowsCounts);
                Run("any clipping stays set until all sources clear", AnyClippingAggregatesSources);
                Run("same-session reconnect is marked unreliable", SameSessionReconnectIsUnreliable);
                Run("expired effect cannot be resurrected by duration update", ExpiredEffectIsNotResurrected);
                Run("device reset retains effect parameters for restart", DeviceResetRetainsParameters);
                Run("device unacquire stops playback but permits restart", DeviceUnacquireStopsPlayback);
                Run("diagnostic transition queue is bounded", TransitionQueueIsBounded);
                Console.WriteLine("FFBInterceptor.Core.Tests: " + _tests + " passed");
                return 0;
            }
            catch (Exception exception)
            {
                Console.Error.WriteLine(exception);
                return 1;
            }
        }

        private static void GoldenProtocolFixture()
        {
            var hex = File.ReadAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "event_v1.hex"));
            var compact = new string(hex.Where(value => !char.IsWhiteSpace(value)).ToArray());
            var bytes = Enumerable.Range(0, compact.Length / 2)
                .Select(index => byte.Parse(compact.Substring(index * 2, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture))
                .ToArray();
            var frame = ProtocolDecoder.Decode(bytes);
            Equal(MessageType.EffectParametersChanged, frame.MessageType);
            Equal((ulong)7, frame.Sequence);
            Equal((uint)4242, frame.ProcessId);
            Equal(EffectKind.Spring, frame.EffectKind);
            Equal(EffectCommand.Start, frame.EffectCommand);
            Equal("fixture-session", frame.SessionId);
            Equal("fixture.exe", frame.Text);
            Equal(2, frame.Axes.Length);
            Equal(-2, frame.Axes[1]);
        }

        private static void FragmentedStream()
        {
            var data = GoldenBytes();
            var accumulator = new FrameAccumulator();
            Equal(0, accumulator.Feed(data.Take(17).ToArray(), 17).Count);
            var tail = data.Skip(17).ToArray();
            var frames = accumulator.Feed(tail, tail.Length);
            Equal(1, frames.Count);
            accumulator.Complete();
        }

        private static void MalformedProtocolRejected()
        {
            var data = GoldenBytes();
            data[0] = (byte)'X';
            Throws<ProtocolException>(() => ProtocolDecoder.Decode(data));
            var accumulator = new FrameAccumulator();
            Throws<ProtocolException>(() => accumulator.Feed(data, data.Length));
        }

        private static void InvalidUtf8Rejected()
        {
            var frame = BaseFrame(MessageType.DeviceCreated);
            frame.Text = "x";
            var data = EncodeFrame(frame);
            data[data.Length - 5] = 0xFF;
            Throws<ProtocolException>(() => ProtocolDecoder.Decode(data));
        }

        private static void LongValidUtf8Accepted()
        {
            var frame = BaseFrame(MessageType.DeviceCreated);
            frame.Text = string.Concat(Enumerable.Repeat("😀", 15));
            var decoded = ProtocolDecoder.Decode(EncodeFrame(frame));
            Equal(frame.Text, decoded.Text);
        }

        private static void SecurePipeHandshake()
        {
            var pipeName = "ffb-interceptor-test-" + Guid.NewGuid().ToString("N");
            var connectedSignal = new ManualResetEventSlim(false);
            var frameSignal = new ManualResetEventSlim(false);
            SourceIdentity connectedIdentity = null;
            ProtocolFrame receivedFrame = null;
            var connectionId = Guid.Empty;
            var server = new SecurePipeServer(
                (identity, id, now) => { connectedIdentity = identity; connectionId = id; connectedSignal.Set(); },
                (key, id, now) => { },
                (key, frame, now) => { receivedFrame = frame; frameSignal.Set(); },
                () => { },
                () => 1,
                @"\\.\pipe\" + pipeName);
            try
            {
                server.Start();
                using (var client = new NamedPipeClientStream(".", pipeName, PipeDirection.Out))
                {
                    client.Connect(2000);
                    var processId = (uint)Process.GetCurrentProcess().Id;
                    var hello = new ProtocolFrame
                    {
                        MessageType = MessageType.Hello,
                        ProcessId = processId,
                        QpcFrequency = 10000000,
                        Flags = 64,
                        Sequence = 1,
                        SessionId = processId + "-pipe-test",
                        BuildVersion = "test",
                        Text = "tests.exe",
                    };
                    var change = new ProtocolFrame
                    {
                        MessageType = MessageType.EffectParametersChanged,
                        ProcessId = processId,
                        DeviceId = 1,
                        EffectId = 2,
                        EffectKind = EffectKind.Constant,
                        Magnitude = 10000,
                        Gain = 10000,
                        Flags = 0x00000100,
                        Sequence = 2,
                    };
                    var helloBytes = EncodeFrame(hello);
                    var changeBytes = EncodeFrame(change);
                    client.Write(helloBytes, 0, helloBytes.Length);
                    client.Write(changeBytes, 0, changeBytes.Length);
                    client.Flush();
                    True(connectedSignal.Wait(2000));
                    True(frameSignal.Wait(2000));
                    Equal(processId, connectedIdentity.Key.ProcessId);
                    Equal("tests.exe", connectedIdentity.ProcessName);
                    True(connectionId != Guid.Empty);
                    Equal(MessageType.EffectParametersChanged, receivedFrame.MessageType);
                    Equal(10000, receivedFrame.Magnitude);
                }
            }
            finally
            {
                server.Dispose();
                connectedSignal.Dispose();
                frameSignal.Dispose();
            }
        }

        private static void RatioTriggerAndExit()
        {
            var engine = ConnectedEngine(out var key);
            engine.ProcessFrame(key, ConstantCreated(10000, 10000), 0);
            engine.ProcessFrame(key, Start(), 0);
            var initial = engine.Tick(0);
            False(initial.IsClipping);
            var triggered = engine.Tick(50);
            True(triggered.AtLimit);
            True(triggered.IsClipping);
            Near(0.05, triggered.ClipRatio, 0.001);

            engine.ProcessFrame(key, ConstantChanged(9400, 0x00000100), 60);
            var held = engine.Tick(60);
            True(held.IsClipping);
            var exited = engine.Tick(560);
            False(exited.IsClipping);
            False(engine.Tick(576).IsClipping);
        }

        private static void GainDoesNotHideClipping()
        {
            var engine = ConnectedEngine(out var key);
            engine.ProcessFrame(key, ConstantCreated(10000, 2500), 0);
            engine.ProcessFrame(key, Start(), 0);
            var snapshot = engine.Tick(0);
            Near(1.0, snapshot.CommandLevel, 0.0001);
            Near(0.25, snapshot.EffectiveCommandLevel, 0.0001);
            True(snapshot.AtLimit);
        }

        private static void EffectParameterPresenceFlags()
        {
            var present = BaseFrame(MessageType.EffectCreated);
            present.EffectParameterPresence = EffectParameterPresence.Present;
            present.TriggerButton = 0;
            var decodedPresent = ProtocolDecoder.Decode(EncodeFrame(present));
            Equal(EffectParameterPresence.Present, decodedPresent.EffectParameterPresence);
            Equal((uint)0, decodedPresent.TriggerButton);
            Equal(ProtocolDecoder.EffectCreatedParametersPresentFlag,
                  decodedPresent.Flags & ProtocolDecoder.EffectCreatedParametersPresenceMask);

            var absent = BaseFrame(MessageType.EffectCreated);
            absent.EffectParameterPresence = EffectParameterPresence.Absent;
            absent.TriggerButton = 0;
            var decodedAbsent = ProtocolDecoder.Decode(EncodeFrame(absent));
            Equal(EffectParameterPresence.Absent, decodedAbsent.EffectParameterPresence);
            Equal((uint)0, decodedAbsent.TriggerButton);

            var legacy = BaseFrame(MessageType.EffectCreated);
            legacy.EffectParameterPresence = EffectParameterPresence.Unknown;
            var decodedLegacy = ProtocolDecoder.Decode(EncodeFrame(legacy));
            Equal(EffectParameterPresence.Unknown, decodedLegacy.EffectParameterPresence);
            Equal((uint)0, decodedLegacy.Flags & ProtocolDecoder.EffectCreatedParametersPresenceMask);

            var changed = BaseFrame(MessageType.EffectParametersChanged);
            changed.Flags = ProtocolDecoder.EffectCreatedParametersPresentFlag | 0x00000004;
            var decodedChanged = ProtocolDecoder.Decode(EncodeFrame(changed));
            Equal(EffectParameterPresence.Unknown, decodedChanged.EffectParameterPresence);
            Equal(changed.Flags, decodedChanged.Flags);

            var invalid = EncodeFrame(present);
            invalid[15] |= (byte)(ProtocolDecoder.EffectCreatedParametersAbsentFlag >> 24);
            Throws<ProtocolException>(() => ProtocolDecoder.Decode(invalid));
        }

        private static void SameDeviceEffectsUseConservativeBound()
        {
            var engine = ConnectedEngine(out var key);
            var positive = ConstantCreated(6000, 5000);
            positive.EffectId = 1;
            var negative = ConstantCreated(-6000, 5000);
            negative.EffectId = 2;
            engine.ProcessFrame(key, positive, 0);
            engine.ProcessFrame(key, StartFor(1), 0);
            engine.ProcessFrame(key, negative, 0);
            engine.ProcessFrame(key, StartFor(2), 0);

            var snapshot = engine.Tick(0);
            Near(0.6, snapshot.CommandLevel, 0.0001);
            Near(0.3, snapshot.EffectiveCommandLevel, 0.0001);
            Near(1.0, snapshot.CombinedCommandLevel, 0.0001);
            Near(1.2, snapshot.UnclampedCombinedCommandLevel, 0.0001);
            Near(1.2, snapshot.PeakUnclampedCombinedCommandLevel, 0.0001);
            Near(0.6, snapshot.CombinedEffectiveCommandLevel, 0.0001);
            Near(snapshot.CombinedCommandLevel, snapshot.DetectionLevel, 0.0001);
            Equal("ConservativeAbsoluteSumPerDevice", snapshot.AggregationModel);
            True(snapshot.AtLimit);
        }

        private static void DifferentDevicesAreNotSummed()
        {
            var engine = ConnectedEngine(out var key);
            var first = ConstantCreated(6000, 10000);
            first.DeviceId = 1;
            first.EffectId = 1;
            var second = ConstantCreated(6000, 10000);
            second.DeviceId = 2;
            second.EffectId = 1;
            engine.ProcessFrame(key, first, 0);
            engine.ProcessFrame(key, StartFor(1, 1), 0);
            engine.ProcessFrame(key, second, 0);
            engine.ProcessFrame(key, StartFor(1, 2), 0);

            var snapshot = engine.Tick(0);
            Near(0.6, snapshot.CommandLevel, 0.0001);
            Near(0.6, snapshot.CombinedCommandLevel, 0.0001);
            Near(0.6, snapshot.UnclampedCombinedCommandLevel, 0.0001);
            False(snapshot.AtLimit);
        }

        private static void PeriodicWaveformsAreInstantaneous()
        {
            Near(0, PeriodicLevel(EffectKind.Sine, 0, 0, 0), 0.0001);
            Near(1, PeriodicLevel(EffectKind.Sine, 25, 0, 0), 0.0001);
            Near(1, PeriodicLevel(EffectKind.Sine, 0, 9000, 0), 0.0001);

            Near(1, PeriodicLevel(EffectKind.Square, 0, 0, 2000, 8000), 0.0001);
            Near(0.6, PeriodicLevel(EffectKind.Square, 50, 0, 2000, 8000), 0.0001);

            Near(1, PeriodicLevel(EffectKind.Triangle, 0, 0, 0), 0.0001);
            Near(0, PeriodicLevel(EffectKind.Triangle, 25, 0, 0), 0.0001);
            Near(1, PeriodicLevel(EffectKind.Triangle, 50, 0, 0), 0.0001);

            Near(0.6, PeriodicLevel(EffectKind.SawtoothUp, 0, 0, 2000, 8000), 0.0001);
            Near(1, PeriodicLevel(EffectKind.SawtoothDown, 0, 0, 2000, 8000), 0.0001);
            Near(0.2, PeriodicLevel(EffectKind.SawtoothUp, 25, 0, 2000, 8000), 0.0001);
            Near(0.6, PeriodicLevel(EffectKind.SawtoothDown, 25, 0, 2000, 8000), 0.0001);
        }

        private static void PeriodicPartialUpdateChangesWave()
        {
            var engine = ConnectedEngine(out var key);
            engine.ProcessFrame(key, PeriodicCreated(EffectKind.Sine), 0);
            engine.ProcessFrame(key, Start(), 0);
            Near(0, engine.Tick(0).CommandLevel, 0.0001);

            var changed = BaseFrame(MessageType.EffectParametersChanged);
            changed.EffectKind = EffectKind.Sine;
            changed.Flags = 0x00000100;
            changed.PeriodicMagnitude = 10000;
            changed.PeriodicPhase = 9000;
            changed.PeriodicPeriod = 200000;
            engine.ProcessFrame(key, changed, 0);
            Near(1, engine.Tick(0).CommandLevel, 0.0001);
            Near(0, engine.Tick(50).CommandLevel, 0.0001);
        }

        private static void RampFollowsPlaybackTime()
        {
            var engine = ConnectedEngine(out var key);
            var ramp = BaseFrame(MessageType.EffectCreated);
            ramp.EffectKind = EffectKind.Ramp;
            ramp.RampStart = -10000;
            ramp.RampEnd = 10000;
            ramp.Gain = 10000;
            ramp.Duration = 100000;
            engine.ProcessFrame(key, ramp, 0);
            engine.ProcessFrame(key, Start(), 0);

            Near(1, engine.Tick(0).CommandLevel, 0.0001);
            Near(0.5, engine.Tick(25).CommandLevel, 0.0001);
            Near(0, engine.Tick(50).CommandLevel, 0.0001);
            Near(0.5, engine.Tick(75).CommandLevel, 0.0001);
            Near(0, engine.Tick(100).CommandLevel, 0.0001);
        }

        private static void EnvelopeShapesAmplitude()
        {
            var engine = ConnectedEngine(out var key);
            var effect = ConstantCreated(5000, 10000);
            effect.Duration = 200000;
            effect.EnvelopeAttackLevel = 0;
            effect.EnvelopeAttackTime = 100000;
            effect.EnvelopeFadeLevel = 0;
            effect.EnvelopeFadeTime = 50000;
            engine.ProcessFrame(key, effect, 0);
            engine.ProcessFrame(key, Start(), 0);

            Near(0, engine.Tick(0).CommandLevel, 0.0001);
            Near(0.25, engine.Tick(50).CommandLevel, 0.0001);
            Near(0.5, engine.Tick(100).CommandLevel, 0.0001);
            Near(0.25, engine.Tick(175).CommandLevel, 0.0001);
            Near(0, engine.Tick(200).CommandLevel, 0.0001);

            var highAttackEngine = ConnectedEngine(out var highAttackKey);
            var highAttack = ConstantCreated(5000, 10000);
            highAttack.Duration = 200000;
            highAttack.EnvelopeAttackLevel = 10000;
            highAttack.EnvelopeAttackTime = 100000;
            highAttackEngine.ProcessFrame(highAttackKey, highAttack, 0);
            highAttackEngine.ProcessFrame(highAttackKey, Start(), 0);
            Near(1, highAttackEngine.Tick(0).CommandLevel, 0.0001);
            Near(0.75, highAttackEngine.Tick(50).CommandLevel, 0.0001);

            var periodicEngine = ConnectedEngine(out var periodicKey);
            var periodic = PeriodicCreated(EffectKind.Square, 0, 2000, 5000);
            periodic.PeriodicPeriod = 200000;
            periodic.EnvelopeAttackLevel = 0;
            periodic.EnvelopeAttackTime = 100000;
            periodicEngine.ProcessFrame(periodicKey, periodic, 0);
            periodicEngine.ProcessFrame(periodicKey, Start(), 0);
            Near(0.2, periodicEngine.Tick(0).CommandLevel, 0.0001);
            Near(0.45, periodicEngine.Tick(50).CommandLevel, 0.0001);
        }

        private static void TriggerStateIsDisclosed()
        {
            var engine = ConnectedEngine(out var key);
            var effect = ConstantCreated(10000, 10000);
            engine.ProcessFrame(key, effect, 0);
            engine.ProcessFrame(key, Start(), 0);
            engine.Tick(0);
            True(engine.Tick(50).IsClipping);

            var triggered = BaseFrame(MessageType.EffectParametersChanged);
            triggered.Flags = 0x00000008;
            triggered.TriggerButton = 3;
            engine.ProcessFrame(key, triggered, 60);

            var limited = engine.Tick(60);
            False(limited.DataReliable);
            False(limited.AtLimit);
            False(limited.IsClipping);
            Near(1, limited.CommandLevel, 0.0001);
            Equal(1, limited.UnobservedTriggerEffectCount);
            True((limited.ReliabilityIssues & DetectorReliabilityIssue.TriggerStateUnavailable) != 0);
            True(limited.StatusText.Contains("TriggerButton"));
            var ended = 0;
            DetectorTransition transition;
            while (engine.TryDequeueTransition(out transition))
                if (transition.Kind == DetectorTransitionKind.ClippingEnded) ended++;
            Equal(1, ended);

            var changed = BaseFrame(MessageType.EffectParametersChanged);
            changed.Flags = 0x00000008;
            changed.TriggerButton = uint.MaxValue;
            engine.ProcessFrame(key, changed, 61);
            var reliable = engine.Tick(61);
            True(reliable.DataReliable);
            Equal(0, reliable.UnobservedTriggerEffectCount);
            True(reliable.AtLimit);
        }

        private static void NullCreatedPartialEffectRemainsReliable()
        {
            var engine = ConnectedEngine(out var key);
            var created = BaseFrame(MessageType.EffectCreated);
            created.EffectKind = EffectKind.Constant;
            created.EffectParameterPresence = EffectParameterPresence.Absent;
            // Zero is still present in the fixed payload, but the explicit
            // Absent marker means it is not a real trigger-button value.
            created.TriggerButton = 0;
            engine.ProcessFrame(key, created, 0);

            var changed = BaseFrame(MessageType.EffectParametersChanged);
            changed.EffectKind = EffectKind.Constant;
            changed.Flags = 0x00000100;
            changed.Magnitude = 10000;
            engine.ProcessFrame(key, changed, 0);
            engine.ProcessFrame(key, Start(), 0);

            var snapshot = engine.Tick(0);
            True(snapshot.DataReliable);
            Equal(0, snapshot.UnobservedTriggerEffectCount);
            Near(1, snapshot.CommandLevel, 0.0001);

            var buttonZeroEngine = ConnectedEngine(out var buttonZeroKey);
            var buttonZero = ConstantCreated(10000, 10000);
            buttonZero.EffectParameterPresence = EffectParameterPresence.Present;
            buttonZero.TriggerButton = 0;
            buttonZeroEngine.ProcessFrame(buttonZeroKey, buttonZero, 0);
            buttonZeroEngine.ProcessFrame(buttonZeroKey, Start(), 0);
            var limited = buttonZeroEngine.Tick(0);
            False(limited.DataReliable);
            Equal(1, limited.UnobservedTriggerEffectCount);
        }

        private static void ZeroPeriodIsUnsupported()
        {
            var engine = ConnectedEngine(out var key);
            var effect = PeriodicCreated(EffectKind.Sine);
            effect.PeriodicPeriod = 0;
            engine.ProcessFrame(key, effect, 0);
            engine.ProcessFrame(key, Start(), 0);
            var snapshot = engine.Tick(0);
            Equal(1, snapshot.ActiveEffectCount);
            Equal(1, snapshot.UnsupportedEffectCount);
            Near(0, snapshot.CommandLevel, 0.0001);
            True(snapshot.ModelLimited);
        }

        private static void HighBitPeriodIsSupported()
        {
            var engine = ConnectedEngine(out var key);
            var effect = PeriodicCreated(EffectKind.Square);
            effect.PeriodicPeriod = unchecked((int)3000000000u);
            engine.ProcessFrame(key, effect, 0);
            engine.ProcessFrame(key, Start(), 0);
            var snapshot = engine.Tick(0);
            Equal(0, snapshot.UnsupportedEffectCount);
            Near(1, snapshot.CommandLevel, 0.0001);
        }

        private static void DeviceStateCapacityIsBounded()
        {
            var engine = ConnectedEngine(out var key);
            for (uint deviceId = 2; deviceId <= 80; deviceId++)
            {
                var frame = BaseFrame(MessageType.DeviceCreated);
                frame.DeviceId = deviceId;
                engine.ProcessFrame(key, frame, deviceId);
            }
            var snapshot = engine.Tick(100);
            True(snapshot.DeviceStateDrops > 0);
            True(snapshot.StateCapacityDrops >= snapshot.DeviceStateDrops);
            False(snapshot.DataReliable);
            True((snapshot.ReliabilityIssues & DetectorReliabilityIssue.StateCapacityExceeded) != 0);
        }

        private static void EffectStateCapacityIsBounded()
        {
            var engine = ConnectedEngine(out var key);
            for (uint effectId = 1; effectId <= 1100; effectId++)
            {
                var frame = ConstantCreated(100, 10000);
                frame.EffectId = effectId;
                engine.ProcessFrame(key, frame, effectId);
            }
            var snapshot = engine.Tick(1200);
            True(snapshot.EffectStateDrops > 0);
            False(snapshot.DataReliable);
            True(snapshot.StatusText.Contains("容量"));
        }

        private static void SourceStateCapacityIsBounded()
        {
            var engine = new ClippingEngine(DetectorSettings.Defaults());
            for (uint processId = 1; processId <= 80; processId++)
            {
                var key = new SourceKey(processId, processId + "-capacity");
                engine.Connect(new SourceIdentity(key, processId + ".exe", "test", 64),
                               Guid.NewGuid(), processId);
            }
            var snapshot = engine.Tick(100);
            Equal(64, snapshot.SourceCount);
            True(snapshot.SourceStateDrops > 0);
            False(snapshot.DataReliable);
            True((snapshot.ReliabilityIssues & DetectorReliabilityIssue.StateCapacityExceeded) != 0);
        }

        private static void PartialUpdatePreservesLevel()
        {
            var engine = ConnectedEngine(out var key);
            engine.ProcessFrame(key, ConstantCreated(9900, 10000), 0);
            engine.ProcessFrame(key, Start(), 0);
            engine.Tick(0);
            engine.ProcessFrame(key, ConstantChanged(0, 0x00000004, 5000), 10);
            var snapshot = engine.Tick(10);
            Near(0.99, snapshot.CommandLevel, 0.0001);
            Near(0.495, snapshot.EffectiveCommandLevel, 0.0001);
        }

        private static void ConditionIsUnsupported()
        {
            var engine = ConnectedEngine(out var key);
            var created = BaseFrame(MessageType.EffectCreated);
            created.EffectKind = EffectKind.Spring;
            created.Gain = 10000;
            created.Duration = uint.MaxValue;
            engine.ProcessFrame(key, created, 0);
            engine.ProcessFrame(key, Start(), 0);
            var snapshot = engine.Tick(0);
            Equal(1, snapshot.ActiveEffectCount);
            Equal(1, snapshot.UnsupportedEffectCount);
            Near(0, snapshot.CommandLevel, 0.0001);
        }

        private static void ManualSourceSelection()
        {
            var settings = DetectorSettings.Defaults();
            settings.AutoSelectSource = false;
            settings.ManualProcessId = 200;
            var engine = new ClippingEngine(settings);
            var first = new SourceKey(100, "100-a");
            var second = new SourceKey(200, "200-b");
            engine.Connect(new SourceIdentity(first, "one.exe", "test", 64), Guid.NewGuid(), 0);
            engine.Connect(new SourceIdentity(second, "two.exe", "test", 64), Guid.NewGuid(), 1);
            var snapshot = engine.Tick(2);
            Equal((uint)200, snapshot.SelectedProcessId);
            Equal("Manual", snapshot.SelectionMode);
        }

        private static void FiniteEffectExpires()
        {
            var engine = ConnectedEngine(out var key);
            var created = ConstantCreated(10000, 10000);
            created.Duration = 100000;
            engine.ProcessFrame(key, created, 0);
            engine.ProcessFrame(key, Start(2), 0);
            Near(1, engine.Tick(199).CommandLevel, 0.0001);
            Near(0, engine.Tick(200).CommandLevel, 0.0001);
        }

        private static void StartDelayDefersOutput()
        {
            var engine = ConnectedEngine(out var key);
            var created = ConstantCreated(10000, 10000);
            created.Duration = 100000;
            created.StartDelay = 50000;
            engine.ProcessFrame(key, created, 0);
            engine.ProcessFrame(key, Start(), 0);
            Near(0, engine.Tick(49).CommandLevel, 0.0001);
            Near(1, engine.Tick(50).CommandLevel, 0.0001);
            Near(0, engine.Tick(150).CommandLevel, 0.0001);
        }

        private static void DurationUpdateUsesPlaybackOrigin()
        {
            var engine = ConnectedEngine(out var key);
            var created = ConstantCreated(10000, 10000);
            created.Duration = 300000;
            engine.ProcessFrame(key, created, 0);
            engine.ProcessFrame(key, Start(), 0);
            Near(1, engine.Tick(200).CommandLevel, 0.0001);
            var changed = ConstantChanged(0, 0x00000001);
            changed.Duration = 150000;
            engine.ProcessFrame(key, changed, 200);
            Near(0, engine.Tick(200).CommandLevel, 0.0001);
        }

        private static void DropNoticeInvalidatesState()
        {
            var engine = new ClippingEngine(DetectorSettings.Defaults());
            var key = new SourceKey(1234, "1234-test");
            var connectionId = Guid.NewGuid();
            engine.Connect(new SourceIdentity(key, "game.exe", "test", 64), connectionId, 0);
            engine.ProcessFrame(key, ConstantCreated(10000, 10000), 0);
            engine.ProcessFrame(key, Start(), 0);
            engine.Tick(0);
            engine.Tick(50);
            DetectorTransition ignored;
            while (engine.TryDequeueTransition(out ignored)) { }
            var drop = BaseFrame(MessageType.DropNotice);
            drop.Dropped = 1;
            engine.ProcessFrame(key, drop, 60);
            var snapshot = engine.Tick(60);
            False(snapshot.DataReliable);
            False(snapshot.IsClipping);
            Near(0, snapshot.CommandLevel, 0.0001);
            True(snapshot.StatusText.Contains("資料缺口"));
            engine.Tick(1000);
            engine.Disconnect(key, connectionId, 1001);
            var clippingEnded = 0;
            DetectorTransition transition;
            while (engine.TryDequeueTransition(out transition))
                if (transition.Kind == DetectorTransitionKind.ClippingEnded) clippingEnded++;
            Equal(1, clippingEnded);
        }

        private static void PartialUpdateRebuildsSafely()
        {
            var engine = ConnectedEngine(out var key);
            engine.ProcessFrame(key, ConstantChanged(10000, 0x00000100), 0);
            engine.ProcessFrame(key, Start(), 0);
            var snapshot = engine.Tick(0);
            Near(1, snapshot.CommandLevel, 0.0001);
            Near(1, snapshot.EffectiveCommandLevel, 0.0001);
        }

        private static void PauseFreezesEffectClock()
        {
            var engine = ConnectedEngine(out var key);
            var created = ConstantCreated(10000, 10000);
            created.Duration = 100000;
            engine.ProcessFrame(key, created, 0);
            engine.ProcessFrame(key, Start(), 0);
            engine.ProcessFrame(key, DeviceCommand(0x00000004), 40);
            Near(0, engine.Tick(200).CommandLevel, 0.0001);
            engine.ProcessFrame(key, DeviceCommand(0x00000008), 200);
            Near(1, engine.Tick(259).CommandLevel, 0.0001);
            Near(0, engine.Tick(260).CommandLevel, 0.0001);
        }

        private static void EffectStartedDuringPause()
        {
            var engine = ConnectedEngine(out var key);
            var created = ConstantCreated(10000, 10000);
            created.Duration = 100000;
            engine.ProcessFrame(key, created, 0);
            engine.ProcessFrame(key, DeviceCommand(0x00000004), 0);
            engine.ProcessFrame(key, Start(), 100);
            engine.ProcessFrame(key, DeviceCommand(0x00000008), 200);
            Near(1, engine.Tick(200).CommandLevel, 0.0001);
            Near(1, engine.Tick(299).CommandLevel, 0.0001);
            Near(0, engine.Tick(300).CommandLevel, 0.0001);
        }

        private static void ActuatorMuteDoesNotFreezeClock()
        {
            var engine = ConnectedEngine(out var key);
            var created = ConstantCreated(10000, 10000);
            created.Duration = 100000;
            engine.ProcessFrame(key, created, 0);
            engine.ProcessFrame(key, Start(), 0);
            engine.ProcessFrame(key, DeviceCommand(0x00000020), 40);
            Near(0, engine.Tick(200).CommandLevel, 0.0001);
            engine.ProcessFrame(key, DeviceCommand(0x00000010), 200);
            Near(0, engine.Tick(200).CommandLevel, 0.0001);
        }

        private static void GlobalEventGatePairsEdges()
        {
            var gate = new GlobalClippingEventGate();
            False(gate.Update(false).HasValue);
            Equal(DetectorTransitionKind.ClippingStarted, gate.Update(true).Value);
            False(gate.Update(true).HasValue);
            Equal(DetectorTransitionKind.ClippingEnded, gate.Update(false).Value);
            False(gate.Update(false).HasValue);
        }

        private static void SourceEventGateFollowsCounts()
        {
            var gate = new SourceCountEventGate();
            False(gate.Update(0).HasValue);
            Equal(DetectorTransitionKind.SourceConnected, gate.Update(2).Value);
            False(gate.Update(2).HasValue);
            Equal(DetectorTransitionKind.SourceDisconnected, gate.Update(1).Value);
            Equal(DetectorTransitionKind.SourceDisconnected, gate.Update(0).Value);
        }

        private static void AnyClippingAggregatesSources()
        {
            var settings = DetectorSettings.Defaults();
            settings.ExitHoldMilliseconds = 0;
            var engine = new ClippingEngine(settings);
            var first = new SourceKey(100, "100-a");
            var second = new SourceKey(200, "200-b");
            engine.Connect(new SourceIdentity(first, "one.exe", "test", 64), Guid.NewGuid(), 0);
            engine.Connect(new SourceIdentity(second, "two.exe", "test", 64), Guid.NewGuid(), 0);

            var firstCreated = ConstantCreated(10000, 10000);
            firstCreated.ProcessId = 100;
            var firstStart = Start();
            firstStart.ProcessId = 100;
            engine.ProcessFrame(first, firstCreated, 0);
            engine.ProcessFrame(first, firstStart, 0);
            engine.Tick(0);
            True(engine.Tick(50).AnyClipping);

            var secondCreated = ConstantCreated(10000, 10000);
            secondCreated.ProcessId = 200;
            var secondStart = Start();
            secondStart.ProcessId = 200;
            engine.ProcessFrame(second, secondCreated, 60);
            engine.ProcessFrame(second, secondStart, 60);
            engine.Tick(60);
            True(engine.Tick(110).AnyClipping);

            var firstStop = Stop();
            firstStop.ProcessId = 100;
            engine.ProcessFrame(first, firstStop, 120);
            True(engine.Tick(120).AnyClipping);
            var secondStop = Stop();
            secondStop.ProcessId = 200;
            engine.ProcessFrame(second, secondStop, 130);
            False(engine.Tick(130).AnyClipping);
        }

        private static void SameSessionReconnectIsUnreliable()
        {
            var engine = new ClippingEngine(DetectorSettings.Defaults());
            var key = new SourceKey(1234, "1234-test");
            var firstConnection = Guid.NewGuid();
            engine.Connect(new SourceIdentity(key, "game.exe", "test", 64), firstConnection, 0);
            engine.ProcessFrame(key, ConstantCreated(10000, 10000), 0);
            engine.ProcessFrame(key, Start(), 0);
            engine.Disconnect(key, firstConnection, 10);
            engine.Connect(new SourceIdentity(key, "game.exe", "test", 64), Guid.NewGuid(), 20);
            var snapshot = engine.Tick(20);
            True(snapshot.Connected);
            False(snapshot.DataReliable);
            Near(0, snapshot.CommandLevel, 0.0001);
        }

        private static void ExpiredEffectIsNotResurrected()
        {
            var engine = ConnectedEngine(out var key);
            var created = ConstantCreated(10000, 10000);
            created.Duration = 100000;
            engine.ProcessFrame(key, created, 0);
            engine.ProcessFrame(key, Start(), 0);
            var changed = ConstantChanged(0, 0x00000001);
            changed.Duration = 300000;
            engine.ProcessFrame(key, changed, 200);
            Near(0, engine.Tick(200).CommandLevel, 0.0001);
        }

        private static void DeviceResetRetainsParameters()
        {
            var engine = ConnectedEngine(out var key);
            engine.ProcessFrame(key, ConstantCreated(10000, 10000), 0);
            engine.ProcessFrame(key, Start(), 0);
            engine.ProcessFrame(key, DeviceCommand(0x00000001), 10);
            engine.ProcessFrame(key, DeviceCommand(0x00000010), 20);
            engine.ProcessFrame(key, Start(), 20);
            Near(1, engine.Tick(20).CommandLevel, 0.0001);
        }

        private static void SecurePipeStopsAndRestarts()
        {
            var pipeName = @"\\.\pipe\ffb-interceptor-stop-test-" + Guid.NewGuid().ToString("N");
            using (var server = new SecurePipeServer(
                (identity, id, now) => { },
                (key, id, now) => { },
                (key, frame, now) => { },
                () => { },
                () => 1,
                pipeName))
            {
                var stopwatch = Stopwatch.StartNew();
                server.Start();
                server.Stop();
                True(stopwatch.ElapsedMilliseconds < 2000);
                stopwatch.Restart();
                server.Start();
                server.Stop();
                True(stopwatch.ElapsedMilliseconds < 2000);
            }
        }

        private static void SecurePipeRejectsOutOfOrderSequence()
        {
            var pipeName = "ffb-interceptor-sequence-test-" + Guid.NewGuid().ToString("N");
            var protocolError = new ManualResetEventSlim(false);
            using (var server = new SecurePipeServer(
                (identity, id, now) => { },
                (key, id, now) => { },
                (key, frame, now) => { },
                () => protocolError.Set(),
                () => 1,
                @"\\.\pipe\" + pipeName))
            {
                server.Start();
                using (var client = new NamedPipeClientStream(".", pipeName, PipeDirection.Out))
                {
                    client.Connect(2000);
                    var processId = (uint)Process.GetCurrentProcess().Id;
                    var hello = new ProtocolFrame
                    {
                        MessageType = MessageType.Hello,
                        ProcessId = processId,
                        QpcFrequency = 10000000,
                        Flags = 64,
                        Sequence = 1,
                        SessionId = processId + "-sequence-test",
                        BuildVersion = "test",
                        Text = "tests.exe",
                    };
                    var newer = BaseFrame(MessageType.DeviceCommand);
                    newer.ProcessId = processId;
                    newer.Sequence = 3;
                    var stale = BaseFrame(MessageType.DeviceCommand);
                    stale.ProcessId = processId;
                    stale.Sequence = 2;
                    foreach (var bytes in new[]
                    {
                        EncodeFrame(hello), EncodeFrame(newer), EncodeFrame(stale),
                    })
                        client.Write(bytes, 0, bytes.Length);
                    client.Flush();
                    True(protocolError.Wait(2000));
                }
            }
            protocolError.Dispose();
        }

        private static void DeviceUnacquireStopsPlayback()
        {
            var engine = ConnectedEngine(out var key);
            engine.ProcessFrame(key, ConstantCreated(10000, 10000), 0);
            engine.ProcessFrame(key, Start(), 0);
            Near(1, engine.Tick(0).CommandLevel, 0.0001);
            engine.ProcessFrame(key, DeviceCommand(0x00000002), 10);
            Near(0, engine.Tick(10).CommandLevel, 0.0001);
            engine.ProcessFrame(key, Start(), 20);
            Near(1, engine.Tick(20).CommandLevel, 0.0001);
        }

        private static void TransitionQueueIsBounded()
        {
            var engine = new ClippingEngine(DetectorSettings.Defaults());
            var key = new SourceKey(1234, "1234-bounded");
            var identity = new SourceIdentity(key, "game.exe", "test", 64);
            for (var index = 0; index < 400; index++)
            {
                var connection = Guid.NewGuid();
                engine.Connect(identity, connection, index * 2);
                engine.Disconnect(key, connection, index * 2 + 1);
            }
            var count = 0;
            DetectorTransition transition;
            while (engine.TryDequeueTransition(out transition)) count++;
            Equal(256, count);
        }

        private static ClippingEngine ConnectedEngine(out SourceKey key)
        {
            var engine = new ClippingEngine(DetectorSettings.Defaults());
            key = new SourceKey(1234, "1234-test");
            engine.Connect(new SourceIdentity(key, "game.exe", "test", 64), Guid.NewGuid(), 0);
            return engine;
        }

        private static ProtocolFrame ConstantCreated(int magnitude, uint gain)
        {
            var frame = BaseFrame(MessageType.EffectCreated);
            frame.EffectKind = EffectKind.Constant;
            frame.Magnitude = magnitude;
            frame.Gain = gain;
            frame.Duration = uint.MaxValue;
            return frame;
        }

        private static ProtocolFrame ConstantChanged(int magnitude, uint flags, uint gain = 10000)
        {
            var frame = BaseFrame(MessageType.EffectParametersChanged);
            frame.EffectKind = EffectKind.Constant;
            frame.Magnitude = magnitude;
            frame.Gain = gain;
            frame.Flags = flags;
            return frame;
        }

        private static ProtocolFrame PeriodicCreated(
            EffectKind kind, int phase = 0, int offset = 0, int magnitude = 10000)
        {
            var frame = BaseFrame(MessageType.EffectCreated);
            frame.EffectKind = kind;
            frame.PeriodicMagnitude = magnitude;
            frame.PeriodicOffset = offset;
            frame.PeriodicPhase = phase;
            frame.PeriodicPeriod = 100000;
            frame.Gain = 10000;
            frame.Duration = uint.MaxValue;
            return frame;
        }

        private static double PeriodicLevel(
            EffectKind kind, double nowMilliseconds, int phase, int offset,
            int magnitude = 10000)
        {
            var engine = ConnectedEngine(out var key);
            engine.ProcessFrame(key, PeriodicCreated(kind, phase, offset, magnitude), 0);
            engine.ProcessFrame(key, Start(), 0);
            return engine.Tick(nowMilliseconds).CommandLevel;
        }

        private static ProtocolFrame Start(uint iterations = 1)
        {
            var frame = BaseFrame(MessageType.EffectCommand);
            frame.EffectCommand = EffectCommand.Start;
            frame.Iterations = iterations;
            return frame;
        }

        private static ProtocolFrame StartFor(uint effectId, uint deviceId = 1, uint iterations = 1)
        {
            var frame = Start(iterations);
            frame.EffectId = effectId;
            frame.DeviceId = deviceId;
            return frame;
        }

        private static ProtocolFrame DeviceCommand(uint command)
        {
            var frame = BaseFrame(MessageType.DeviceCommand);
            frame.DiFlags = command;
            return frame;
        }

        private static ProtocolFrame Stop()
        {
            var frame = BaseFrame(MessageType.EffectCommand);
            frame.EffectCommand = EffectCommand.Stop;
            return frame;
        }

        private static ProtocolFrame BaseFrame(MessageType type)
        {
            return new ProtocolFrame
            {
                MessageType = type,
                EffectParameterPresence = type == MessageType.EffectCreated
                    ? EffectParameterPresence.Present
                    : EffectParameterPresence.Unknown,
                ProcessId = 1234,
                DeviceId = 1,
                EffectId = 7,
                HResult = 0,
            };
        }

        private static byte[] GoldenBytes()
        {
            var hex = File.ReadAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "event_v1.hex"));
            var compact = new string(hex.Where(value => !char.IsWhiteSpace(value)).ToArray());
            return Enumerable.Range(0, compact.Length / 2)
                .Select(index => Convert.ToByte(compact.Substring(index * 2, 2), 16)).ToArray();
        }

        private static byte[] EncodeFrame(ProtocolFrame frame)
        {
            byte[] payload;
            using (var stream = new MemoryStream())
            using (var writer = new BinaryWriter(stream, Encoding.UTF8))
            {
                writer.Write(frame.ProcessId);
                writer.Write(frame.QpcFrequency);
                writer.Write(frame.DeviceId);
                writer.Write(frame.EffectId);
                writer.Write(frame.EffectGuid.ToByteArray());
                writer.Write(frame.HResult);
                writer.Write(frame.DiFlags);
                writer.Write(frame.Duration);
                writer.Write(frame.SamplePeriod);
                writer.Write(frame.Gain);
                writer.Write(frame.StartDelay);
                writer.Write(frame.TriggerButton);
                writer.Write(frame.TriggerRepeat);
                writer.Write(frame.Iterations);
                writer.Write(frame.EnvelopeAttackLevel);
                writer.Write(frame.EnvelopeAttackTime);
                writer.Write(frame.EnvelopeFadeLevel);
                writer.Write(frame.EnvelopeFadeTime);
                writer.Write(frame.PropertyId);
                writer.Write(frame.Dropped);
                writer.Write(frame.Magnitude);
                writer.Write(frame.RampStart);
                writer.Write(frame.RampEnd);
                writer.Write(frame.PeriodicMagnitude);
                writer.Write(frame.PeriodicOffset);
                writer.Write(frame.PeriodicPhase);
                writer.Write(frame.PeriodicPeriod);
                writer.Write((uint)frame.Axes.Length);
                for (var index = 0; index < ProtocolDecoder.MaximumAxes; index++)
                    writer.Write(index < frame.Axes.Length ? frame.Axes[index] : 0);
                for (var index = 0; index < ProtocolDecoder.MaximumAxes; index++)
                    writer.Write(index < frame.Directions.Length ? frame.Directions[index] : 0);
                writer.Write((uint)frame.Conditions.Length);
                for (var index = 0; index < ProtocolDecoder.MaximumAxes; index++)
                {
                    var condition = index < frame.Conditions.Length ? frame.Conditions[index] : new ConditionSample();
                    writer.Write(condition.Offset);
                    writer.Write(condition.PositiveCoefficient);
                    writer.Write(condition.NegativeCoefficient);
                    writer.Write(condition.PositiveSaturation);
                    writer.Write(condition.NegativeSaturation);
                    writer.Write(condition.DeadBand);
                }
                writer.Write(frame.TypeSpecificSize);
                writer.Write(frame.CustomRedacted ? 1u : 0u);
                WriteFixed(writer, frame.BuildVersion, 32);
                WriteFixed(writer, frame.SessionId, 32);
                var textBytes = Encoding.UTF8.GetBytes(frame.Text ?? string.Empty);
                writer.Write((ushort)textBytes.Length);
                writer.Write(textBytes);
                writer.Write((ushort)frame.EffectKind);
                writer.Write((ushort)frame.EffectCommand);
                payload = stream.ToArray();
            }

            using (var stream = new MemoryStream())
            using (var writer = new BinaryWriter(stream, Encoding.UTF8))
            {
                writer.Write(new[] { (byte)'F', (byte)'F', (byte)'B', (byte)'1' });
                writer.Write(ProtocolDecoder.Version);
                writer.Write((ushort)frame.MessageType);
                writer.Write((uint)(ProtocolDecoder.HeaderSize + payload.Length));
                var flags = frame.Flags;
                if (frame.MessageType == MessageType.EffectCreated)
                {
                    flags &= ~ProtocolDecoder.EffectCreatedParametersPresenceMask;
                    if (frame.EffectParameterPresence == EffectParameterPresence.Absent)
                        flags |= ProtocolDecoder.EffectCreatedParametersAbsentFlag;
                    else if (frame.EffectParameterPresence == EffectParameterPresence.Present)
                        flags |= ProtocolDecoder.EffectCreatedParametersPresentFlag;
                }
                writer.Write(flags);
                writer.Write(frame.Sequence);
                writer.Write(frame.QpcTicks);
                writer.Write(payload);
                return stream.ToArray();
            }
        }

        private static void WriteFixed(BinaryWriter writer, string value, int capacity)
        {
            var bytes = Encoding.UTF8.GetBytes(value ?? string.Empty);
            var buffer = new byte[capacity];
            Buffer.BlockCopy(bytes, 0, buffer, 0, Math.Min(bytes.Length, capacity - 1));
            writer.Write(buffer);
        }

        private static void Run(string name, Action test)
        {
            test();
            _tests++;
            Console.WriteLine("PASS " + name);
        }

        private static void True(bool value) { if (!value) throw new InvalidOperationException("expected true"); }
        private static void False(bool value) { if (value) throw new InvalidOperationException("expected false"); }
        private static void Near(double expected, double actual, double tolerance)
        {
            if (Math.Abs(expected - actual) > tolerance)
                throw new InvalidOperationException("expected " + expected + ", got " + actual);
        }
        private static void Equal<T>(T expected, T actual)
        {
            if (!Equals(expected, actual))
                throw new InvalidOperationException("expected " + expected + ", got " + actual);
        }
        private static void Throws<T>(Action action) where T : Exception
        {
            try { action(); }
            catch (T) { return; }
            throw new InvalidOperationException("expected " + typeof(T).Name);
        }
    }
}
