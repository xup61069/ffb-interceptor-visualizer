# SPDX-License-Identifier: GPL-3.0-only
"""Little-endian FFB Interceptor protocol v1 decoder.

The decoder is deliberately strict: malformed, truncated, unknown-version, and
oversize frames are rejected before they reach the UI model.
"""

from __future__ import annotations

import struct
from collections.abc import Iterable
from dataclasses import dataclass, field

MAGIC = b"FFB1"
VERSION = 1
HEADER_SIZE = 32
MAX_FRAME_SIZE = 64 * 1024
MAX_AXES = 8
_BASE = struct.Struct("<IIII16si" + "I" * 14 + "i" * 7 + "I")
_CONDITION = struct.Struct("<iiiIIi")


class ProtocolError(ValueError):
    """Raised when a frame violates protocol bounds or encoding."""


@dataclass(slots=True, frozen=True)
class Condition:
    offset: int
    positive_coefficient: int
    negative_coefficient: int
    positive_saturation: int
    negative_saturation: int
    dead_band: int


@dataclass(slots=True, frozen=True)
class Frame:
    message_type: int
    flags: int
    sequence: int
    qpc_ticks: int
    process_id: int
    qpc_frequency: int
    device_id: int
    effect_id: int
    effect_guid: bytes
    hresult: int
    di_flags: int
    duration: int
    sample_period: int
    gain: int
    start_delay: int
    trigger_button: int
    trigger_repeat: int
    iterations: int
    envelope_attack_level: int
    envelope_attack_time: int
    envelope_fade_level: int
    envelope_fade_time: int
    property_id: int
    dropped: int
    magnitude: int
    ramp_start: int
    ramp_end: int
    periodic_magnitude: int
    periodic_offset: int
    periodic_phase: int
    periodic_period: int
    axes: tuple[int, ...] = field(default_factory=tuple)
    directions: tuple[int, ...] = field(default_factory=tuple)
    conditions: tuple[Condition, ...] = field(default_factory=tuple)
    type_specific_size: int = 0
    custom_redacted: bool = False
    text: str = ""

    @property
    def relative_seconds(self) -> float:
        return self.qpc_ticks / 1_000_000_000


def _u32(data: bytes | bytearray, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def decode_frame(data: bytes | bytearray | memoryview) -> Frame:
    raw = bytes(data)
    if len(raw) < HEADER_SIZE:
        raise ProtocolError("truncated header")
    magic, version, message_type, frame_size, flags, sequence, qpc_ticks = struct.unpack_from(
        "<4sHHIIQQ", raw, 0
    )
    if magic != MAGIC:
        raise ProtocolError("bad magic")
    if version != VERSION:
        raise ProtocolError(f"unsupported protocol version {version}")
    if frame_size < HEADER_SIZE or frame_size > MAX_FRAME_SIZE:
        raise ProtocolError("invalid frame size")
    if frame_size != len(raw):
        raise ProtocolError("fragmented or trailing frame")
    payload = raw[HEADER_SIZE:]
    # process/device/effect/GUID + 18 DWORDs + 7 signed values + axis count
    minimum = _BASE.size + (MAX_AXES * 4 * 2) + 4 + (MAX_AXES * _CONDITION.size) + 10
    if len(payload) < minimum:
        raise ProtocolError("truncated payload")
    values = _BASE.unpack_from(payload, 0)
    (
        process_id,
        qpc_frequency,
        device_id,
        effect_id,
        guid,
        hresult,
        di_flags,
        duration,
        sample_period,
        gain,
        start_delay,
        trigger_button,
        trigger_repeat,
        iterations,
        attack_level,
        attack_time,
        fade_level,
        fade_time,
        property_id,
        dropped,
        magnitude,
        ramp_start,
        ramp_end,
        periodic_magnitude,
        periodic_offset,
        periodic_phase,
        periodic_period,
        axis_count,
    ) = values
    if axis_count > MAX_AXES:
        raise ProtocolError("axis count exceeds limit")
    offset = _BASE.size
    axes = struct.unpack_from("<8i", payload, offset)
    offset += 32
    directions = struct.unpack_from("<8i", payload, offset)
    offset += 32
    condition_count = _u32(payload, offset)
    offset += 4
    if condition_count > MAX_AXES:
        raise ProtocolError("condition count exceeds limit")
    conditions: list[Condition] = []
    for index in range(MAX_AXES):
        values_c = _CONDITION.unpack_from(payload, offset)
        offset += _CONDITION.size
        if index < condition_count:
            conditions.append(Condition(*values_c))
    type_specific_size = _u32(payload, offset)
    custom_redacted = bool(_u32(payload, offset + 4))
    text_length = struct.unpack_from("<H", payload, offset + 8)[0]
    offset += 10
    if text_length > 63 or offset + text_length > len(payload):
        raise ProtocolError("invalid text length")
    text = payload[offset : offset + text_length].decode("utf-8", errors="replace")
    return Frame(
        message_type,
        flags,
        sequence,
        qpc_ticks,
        process_id,
        qpc_frequency,
        device_id,
        effect_id,
        guid,
        hresult,
        di_flags,
        duration,
        sample_period,
        gain,
        start_delay,
        trigger_button,
        trigger_repeat,
        iterations,
        attack_level,
        attack_time,
        fade_level,
        fade_time,
        property_id,
        dropped,
        magnitude,
        ramp_start,
        ramp_end,
        periodic_magnitude,
        periodic_offset,
        periodic_phase,
        periodic_period,
        tuple(axes[:axis_count]),
        tuple(directions[:axis_count]),
        tuple(conditions),
        type_specific_size,
        custom_redacted,
        text,
    )


def iter_frames(buffer: bytearray) -> Iterable[Frame]:
    """Consume complete frames from a byte buffer, retaining a partial tail."""

    while len(buffer) >= HEADER_SIZE:
        if buffer[:4] != MAGIC:
            del buffer[0]
            continue
        frame_size = _u32(buffer, 8)
        if frame_size < HEADER_SIZE or frame_size > MAX_FRAME_SIZE:
            del buffer[:4]
            continue
        if len(buffer) < frame_size:
            return
        chunk = bytes(buffer[:frame_size])
        del buffer[:frame_size]
        yield decode_frame(chunk)
