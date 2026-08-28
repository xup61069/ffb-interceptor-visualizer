# SPDX-License-Identifier: GPL-3.0-only
import struct
from pathlib import Path

import pytest

from ffb_visualizer.protocol import MAX_FRAME_SIZE, ProtocolError, decode_frame, iter_frames


def fixture_frame() -> bytes:
    base = struct.pack(
        "<IIII16si" + "I" * 14 + "i" * 7 + "I",
        1,
        1_000_000_000,
        2,
        3,
        bytes(16),
        0,
        *([0] * 14),
        *([0] * 7),
        0,
    )
    payload = base + bytes(32 + 32) + struct.pack("<I", 0) + bytes(8 * 24)
    payload += struct.pack("<II", 0, 1) + b"0.1.0\0" + bytes(26) + b"test-session\0" + bytes(19)
    payload += struct.pack("<H", 0) + struct.pack("<HH", 2, 1)
    return b"FFB1" + struct.pack("<HHIIQQ", 1, 6, 32 + len(payload), 0, 9, 100) + payload


def test_decode_and_fragmented_stream() -> None:
    frame = decode_frame(fixture_frame())
    assert frame.effect_id == 3
    assert frame.qpc_frequency == 1_000_000_000
    assert frame.build_version == "0.1.0"
    assert frame.session_id == "test-session"
    assert frame.effect_kind == 2
    assert frame.command == 1
    buf = bytearray(fixture_frame()[:17])
    assert list(iter_frames(buf)) == []
    buf.extend(fixture_frame()[17:])
    assert next(iter(iter_frames(buf))).sequence == 9


def test_shared_golden_fixture() -> None:
    path = Path(__file__).resolve().parents[2] / "tests" / "fixtures" / "event_v1.hex"
    frame = decode_frame(bytes.fromhex(path.read_text(encoding="ascii")))
    assert frame.message_type == 5
    assert frame.flags == 165
    assert frame.sequence == 7
    assert frame.qpc_ticks == 123456789
    assert frame.process_id == 4242
    assert frame.qpc_frequency == 10_000_000
    assert frame.device_id == 11
    assert frame.effect_id == 22
    assert frame.effect_kind == 8
    assert frame.command == 2
    assert frame.axes == (1, -2)
    assert frame.directions == (3, -4)
    assert len(frame.conditions) == 1
    assert frame.type_specific_size == 24
    assert frame.text == "fixture.exe"


@pytest.mark.parametrize(
    "mutator",
    [
        lambda b: b.replace(b"FFB1", b"NOPE", 1),
        lambda b: b[:8] + struct.pack("<I", 64 * 1024 + 1) + b[12:],
    ],
)
def test_rejects_bad_frames(mutator) -> None:
    with pytest.raises(ProtocolError):
        decode_frame(mutator(fixture_frame()))


@pytest.mark.parametrize(
    "mutator",
    [
        lambda b: b.replace(b"FFB1", b"NOPE", 1),
        lambda b: b[:8] + struct.pack("<I", 31) + b[12:],
        lambda b: b[:8] + struct.pack("<I", MAX_FRAME_SIZE + 1) + b[12:],
        lambda b: b[:4] + struct.pack("<H", 2) + b[6:],
    ],
)
def test_stream_parser_fails_closed_on_invalid_headers(mutator) -> None:
    buffer = bytearray(mutator(fixture_frame()))
    with pytest.raises(ProtocolError):
        list(iter_frames(buffer))


def test_stream_parser_does_not_resynchronize_after_garbage() -> None:
    buffer = bytearray(b"garbage" + fixture_frame())
    with pytest.raises(ProtocolError):
        list(iter_frames(buffer))
