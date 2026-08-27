# SPDX-License-Identifier: GPL-3.0-only
"""Shared synthetic protocol fixtures for viewer tests."""

from __future__ import annotations

import os
import struct
import time
from pathlib import Path

from ffb_visualizer.protocol import Frame, decode_frame

_FIXTURE = Path(__file__).parents[2] / "tests" / "fixtures" / "event_v1.hex"
_GOLDEN = bytes.fromhex("".join(_FIXTURE.read_text(encoding="ascii").split()))


def frame_bytes(
    *,
    message_type: int = 5,
    sequence: int = 1,
    process_id: int | None = None,
    qpc_ticks: int | None = None,
) -> bytes:
    """Return a valid v1 fixture frame with safe, deterministic header fields."""
    frame = bytearray(_GOLDEN)
    struct.pack_into("<H", frame, 6, message_type)
    struct.pack_into("<Q", frame, 16, sequence)
    struct.pack_into(
        "<Q", frame, 24, qpc_ticks if qpc_ticks is not None else time.perf_counter_ns()
    )
    struct.pack_into("<I", frame, 32, process_id if process_id is not None else os.getpid())
    struct.pack_into("<I", frame, 36, 1_000_000_000)
    return bytes(frame)


def frame(
    *,
    message_type: int = 5,
    sequence: int = 1,
    process_id: int | None = None,
    qpc_ticks: int | None = None,
) -> Frame:
    """Decode a generated wire frame for model and Qt tests."""
    return decode_frame(
        frame_bytes(
            message_type=message_type,
            sequence=sequence,
            process_id=process_id,
            qpc_ticks=qpc_ticks,
        )
    )
