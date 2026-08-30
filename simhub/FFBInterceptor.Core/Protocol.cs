// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Text;

namespace FFBInterceptor.Core
{
    public enum MessageType : ushort
    {
        Hello = 1,
        DeviceCreated = 2,
        DevicePropertyChanged = 3,
        EffectCreated = 4,
        EffectParametersChanged = 5,
        EffectCommand = 6,
        DeviceCommand = 7,
        DropNotice = 8,
    }

    public enum EffectKind : ushort
    {
        Unknown = 0,
        Constant = 1,
        Ramp = 2,
        Square = 3,
        Sine = 4,
        Triangle = 5,
        SawtoothUp = 6,
        SawtoothDown = 7,
        Spring = 8,
        Damper = 9,
        Inertia = 10,
        Friction = 11,
        Custom = 12,
    }

    public enum EffectCommand : ushort
    {
        Download = 1,
        Start = 2,
        Stop = 3,
        Unload = 4,
        Release = 5,
    }

    public sealed class ConditionSample
    {
        public int Offset { get; internal set; }
        public int PositiveCoefficient { get; internal set; }
        public int NegativeCoefficient { get; internal set; }
        public uint PositiveSaturation { get; internal set; }
        public uint NegativeSaturation { get; internal set; }
        public int DeadBand { get; internal set; }
    }

    public sealed class ProtocolFrame
    {
        public MessageType MessageType { get; internal set; }
        public uint Flags { get; internal set; }
        public ulong Sequence { get; internal set; }
        public ulong QpcTicks { get; internal set; }
        public uint ProcessId { get; internal set; }
        public uint QpcFrequency { get; internal set; }
        public uint DeviceId { get; internal set; }
        public uint EffectId { get; internal set; }
        public Guid EffectGuid { get; internal set; }
        public int HResult { get; internal set; }
        public uint DiFlags { get; internal set; }
        public uint Duration { get; internal set; }
        public uint SamplePeriod { get; internal set; }
        public uint Gain { get; internal set; }
        public uint StartDelay { get; internal set; }
        public uint TriggerButton { get; internal set; }
        public uint TriggerRepeat { get; internal set; }
        public uint Iterations { get; internal set; }
        public uint EnvelopeAttackLevel { get; internal set; }
        public uint EnvelopeAttackTime { get; internal set; }
        public uint EnvelopeFadeLevel { get; internal set; }
        public uint EnvelopeFadeTime { get; internal set; }
        public uint PropertyId { get; internal set; }
        public uint Dropped { get; internal set; }
        public int Magnitude { get; internal set; }
        public int RampStart { get; internal set; }
        public int RampEnd { get; internal set; }
        public int PeriodicMagnitude { get; internal set; }
        public int PeriodicOffset { get; internal set; }
        public int PeriodicPhase { get; internal set; }
        public int PeriodicPeriod { get; internal set; }
        public int[] Axes { get; internal set; } = Array.Empty<int>();
        public int[] Directions { get; internal set; } = Array.Empty<int>();
        public ConditionSample[] Conditions { get; internal set; } = Array.Empty<ConditionSample>();
        public uint TypeSpecificSize { get; internal set; }
        public bool CustomRedacted { get; internal set; }
        public string BuildVersion { get; internal set; } = string.Empty;
        public string SessionId { get; internal set; } = string.Empty;
        public string Text { get; internal set; } = string.Empty;
        public EffectKind EffectKind { get; internal set; }
        public EffectCommand EffectCommand { get; internal set; }
    }

    public sealed class ProtocolException : Exception
    {
        public ProtocolException(string message) : base(message) { }
    }

    public static class ProtocolDecoder
    {
        private static readonly Encoding StrictUtf8 = new UTF8Encoding(false, true);
        public const ushort Version = 1;
        public const int HeaderSize = 32;
        public const int MaximumFrameSize = 64 * 1024;
        public const int MaximumAxes = 8;

        public static ProtocolFrame Decode(byte[] data)
        {
            if (data == null) throw new ArgumentNullException(nameof(data));
            if (data.Length < HeaderSize) throw new ProtocolException("truncated header");
            if (data[0] != (byte)'F' || data[1] != (byte)'F' || data[2] != (byte)'B' || data[3] != (byte)'1')
                throw new ProtocolException("bad magic");

            var reader = new LittleEndianReader(data);
            reader.Skip(4);
            var version = reader.ReadUInt16();
            if (version != Version) throw new ProtocolException("unsupported protocol version");
            var messageValue = reader.ReadUInt16();
            if (messageValue < (ushort)MessageType.Hello || messageValue > (ushort)MessageType.DropNotice)
                throw new ProtocolException("unknown message type");
            var frameSize = reader.ReadUInt32();
            if (frameSize < HeaderSize || frameSize > MaximumFrameSize || frameSize != data.Length)
                throw new ProtocolException("invalid frame size");

            var frame = new ProtocolFrame
            {
                MessageType = (MessageType)messageValue,
                Flags = reader.ReadUInt32(),
                Sequence = reader.ReadUInt64(),
                QpcTicks = reader.ReadUInt64(),
                ProcessId = reader.ReadUInt32(),
                QpcFrequency = reader.ReadUInt32(),
                DeviceId = reader.ReadUInt32(),
                EffectId = reader.ReadUInt32(),
                EffectGuid = reader.ReadGuid(),
                HResult = reader.ReadInt32(),
                DiFlags = reader.ReadUInt32(),
                Duration = reader.ReadUInt32(),
                SamplePeriod = reader.ReadUInt32(),
                Gain = reader.ReadUInt32(),
                StartDelay = reader.ReadUInt32(),
                TriggerButton = reader.ReadUInt32(),
                TriggerRepeat = reader.ReadUInt32(),
                Iterations = reader.ReadUInt32(),
                EnvelopeAttackLevel = reader.ReadUInt32(),
                EnvelopeAttackTime = reader.ReadUInt32(),
                EnvelopeFadeLevel = reader.ReadUInt32(),
                EnvelopeFadeTime = reader.ReadUInt32(),
                PropertyId = reader.ReadUInt32(),
                Dropped = reader.ReadUInt32(),
                Magnitude = reader.ReadInt32(),
                RampStart = reader.ReadInt32(),
                RampEnd = reader.ReadInt32(),
                PeriodicMagnitude = reader.ReadInt32(),
                PeriodicOffset = reader.ReadInt32(),
                PeriodicPhase = reader.ReadInt32(),
                PeriodicPeriod = reader.ReadInt32(),
            };

            var axisCount = reader.ReadUInt32();
            if (axisCount > MaximumAxes) throw new ProtocolException("axis count exceeds limit");
            var allAxes = reader.ReadInt32Array(MaximumAxes);
            var allDirections = reader.ReadInt32Array(MaximumAxes);
            frame.Axes = Slice(allAxes, (int)axisCount);
            frame.Directions = Slice(allDirections, (int)axisCount);

            var conditionCount = reader.ReadUInt32();
            if (conditionCount > MaximumAxes) throw new ProtocolException("condition count exceeds limit");
            var conditions = new ConditionSample[conditionCount];
            for (var index = 0; index < MaximumAxes; index++)
            {
                var condition = new ConditionSample
                {
                    Offset = reader.ReadInt32(),
                    PositiveCoefficient = reader.ReadInt32(),
                    NegativeCoefficient = reader.ReadInt32(),
                    PositiveSaturation = reader.ReadUInt32(),
                    NegativeSaturation = reader.ReadUInt32(),
                    DeadBand = reader.ReadInt32(),
                };
                if (index < conditionCount) conditions[index] = condition;
            }

            frame.Conditions = conditions;
            frame.TypeSpecificSize = reader.ReadUInt32();
            var customRedacted = reader.ReadUInt32();
            if (customRedacted > 1) throw new ProtocolException("invalid custom redaction flag");
            frame.CustomRedacted = customRedacted == 1;
            frame.BuildVersion = DecodeFixedString(reader.ReadBytes(32));
            frame.SessionId = DecodeFixedString(reader.ReadBytes(32));
            var textLength = reader.ReadUInt16();
            if (textLength > 63) throw new ProtocolException("invalid text length");
            frame.Text = DecodeUtf8(reader.ReadBytes(textLength));

            if (reader.Remaining == 4)
            {
                var kindValue = reader.ReadUInt16();
                var commandValue = reader.ReadUInt16();
                frame.EffectKind = Enum.IsDefined(typeof(EffectKind), kindValue)
                    ? (EffectKind)kindValue : EffectKind.Unknown;
                frame.EffectCommand = Enum.IsDefined(typeof(EffectCommand), commandValue)
                    ? (EffectCommand)commandValue : 0;
            }
            else if (reader.Remaining != 0)
            {
                throw new ProtocolException("invalid trailing payload");
            }

            return frame;
        }

        private static int[] Slice(int[] values, int count)
        {
            var result = new int[count];
            Array.Copy(values, result, count);
            return result;
        }

        private static string DecodeFixedString(byte[] value)
        {
            var length = Array.IndexOf(value, (byte)0);
            return DecodeUtf8(value, length < 0 ? value.Length : length);
        }

        private static string DecodeUtf8(byte[] value)
        {
            return DecodeUtf8(value, value.Length);
        }

        private static string DecodeUtf8(byte[] value, int length)
        {
            try
            {
                return StrictUtf8.GetString(value, 0, length);
            }
            catch (DecoderFallbackException)
            {
                throw new ProtocolException("invalid UTF-8");
            }
        }

        private sealed class LittleEndianReader
        {
            private readonly byte[] _data;
            private int _offset;

            internal LittleEndianReader(byte[] data) { _data = data; }
            internal int Remaining => _data.Length - _offset;
            internal void Skip(int count) { Require(count); _offset += count; }
            internal byte[] ReadBytes(int count)
            {
                Require(count);
                var result = new byte[count];
                Buffer.BlockCopy(_data, _offset, result, 0, count);
                _offset += count;
                return result;
            }
            internal ushort ReadUInt16()
            {
                Require(2);
                var result = (ushort)(_data[_offset] | (_data[_offset + 1] << 8));
                _offset += 2;
                return result;
            }
            internal uint ReadUInt32()
            {
                Require(4);
                var result = (uint)(_data[_offset] | (_data[_offset + 1] << 8) |
                                    (_data[_offset + 2] << 16) | (_data[_offset + 3] << 24));
                _offset += 4;
                return result;
            }
            internal int ReadInt32() { return unchecked((int)ReadUInt32()); }
            internal ulong ReadUInt64()
            {
                var low = ReadUInt32();
                var high = ReadUInt32();
                return low | ((ulong)high << 32);
            }
            internal Guid ReadGuid() { return new Guid(ReadBytes(16)); }
            internal int[] ReadInt32Array(int count)
            {
                var result = new int[count];
                for (var index = 0; index < count; index++) result[index] = ReadInt32();
                return result;
            }
            private void Require(int count)
            {
                if (count < 0 || _offset > _data.Length - count)
                    throw new ProtocolException("truncated payload");
            }
        }
    }

    public sealed class FrameAccumulator
    {
        private readonly byte[] _buffer = new byte[ProtocolDecoder.MaximumFrameSize * 2];
        private int _count;

        public IList<ProtocolFrame> Feed(byte[] data, int count)
        {
            if (data == null) throw new ArgumentNullException(nameof(data));
            if (count < 0 || count > data.Length) throw new ArgumentOutOfRangeException(nameof(count));
            if (_count > _buffer.Length - count) throw new ProtocolException("stream buffer exceeded limit");
            Buffer.BlockCopy(data, 0, _buffer, _count, count);
            _count += count;

            var result = new List<ProtocolFrame>();
            while (_count >= ProtocolDecoder.HeaderSize)
            {
                ValidateHeader();
                var frameSize = ReadUInt32(_buffer, 8);
                if (_count < frameSize) break;
                var frame = new byte[frameSize];
                Buffer.BlockCopy(_buffer, 0, frame, 0, (int)frameSize);
                result.Add(ProtocolDecoder.Decode(frame));
                var remaining = _count - (int)frameSize;
                if (remaining > 0) Buffer.BlockCopy(_buffer, (int)frameSize, _buffer, 0, remaining);
                _count = remaining;
            }
            return result;
        }

        public void Complete()
        {
            if (_count != 0) throw new ProtocolException("truncated frame at disconnect");
        }

        private void ValidateHeader()
        {
            if (_buffer[0] != (byte)'F' || _buffer[1] != (byte)'F' ||
                _buffer[2] != (byte)'B' || _buffer[3] != (byte)'1')
                throw new ProtocolException("bad magic");
            if ((_buffer[4] | (_buffer[5] << 8)) != ProtocolDecoder.Version)
                throw new ProtocolException("unsupported protocol version");
            var frameSize = ReadUInt32(_buffer, 8);
            if (frameSize < ProtocolDecoder.HeaderSize || frameSize > ProtocolDecoder.MaximumFrameSize)
                throw new ProtocolException("invalid frame size");
        }

        private static uint ReadUInt32(byte[] data, int offset)
        {
            return (uint)(data[offset] | (data[offset + 1] << 8) |
                          (data[offset + 2] << 16) | (data[offset + 3] << 24));
        }
    }
}
