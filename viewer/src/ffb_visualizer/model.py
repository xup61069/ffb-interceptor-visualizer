# SPDX-License-Identifier: GPL-3.0-only
"""Bounded in-memory event model used by the Qt front end."""

from __future__ import annotations

import math
import time
from collections import deque
from dataclasses import dataclass, field
from itertools import pairwise

from .protocol import Frame

_PERIODIC_EFFECT_KINDS = frozenset((3, 4, 5, 6, 7))
_CONDITION_EFFECT_KINDS = frozenset((8, 9, 10, 11))
_NORMALIZED_COMMAND_CHANNELS = frozenset(
    (
        "magnitude",
        "constant_magnitude",
        "ramp_start",
        "ramp_end",
        "periodic_magnitude",
        "condition_positive_coefficient",
        "condition_negative_coefficient",
        "condition_positive_saturation",
        "condition_negative_saturation",
    )
)


def command_channel_value(event: Frame, channel: str, condition_axis: int = 0) -> int | None:
    """Return one observed command parameter, never a synthesized force.

    ``None`` means that the event does not carry the selected parameter.  In
    particular, condition values are only available for a real condition
    effect and never inferred from a Constant/Ramp/Periodic command.
    """

    if channel == "magnitude":
        return event.magnitude
    if channel == "constant_magnitude":
        return event.magnitude if event.effect_kind == 1 else None
    if channel == "ramp_start":
        return event.ramp_start if event.effect_kind == 2 else None
    if channel == "ramp_end":
        return event.ramp_end if event.effect_kind == 2 else None
    if channel == "periodic_magnitude":
        return event.periodic_magnitude if event.effect_kind in _PERIODIC_EFFECT_KINDS else None
    if channel == "periodic_offset":
        return event.periodic_offset if event.effect_kind in _PERIODIC_EFFECT_KINDS else None
    if channel == "periodic_phase":
        return event.periodic_phase if event.effect_kind in _PERIODIC_EFFECT_KINDS else None
    if channel == "periodic_period":
        return event.periodic_period if event.effect_kind in _PERIODIC_EFFECT_KINDS else None
    if event.effect_kind not in _CONDITION_EFFECT_KINDS:
        return None
    if not 0 <= condition_axis < len(event.conditions):
        return None
    condition = event.conditions[condition_axis]
    values = {
        "condition_offset": condition.offset,
        "condition_positive_coefficient": condition.positive_coefficient,
        "condition_negative_coefficient": condition.negative_coefficient,
        "condition_positive_saturation": condition.positive_saturation,
        "condition_negative_saturation": condition.negative_saturation,
        "condition_dead_band": condition.dead_band,
    }
    return values.get(channel)


def command_channel_scale(channel: str) -> float:
    """Normalize only DirectInput force-scale fields for a readable graph."""

    return 10_000.0 if channel in _NORMALIZED_COMMAND_CHANNELS else 1.0


def command_channel_unit(channel: str) -> str:
    """Describe the API unit without implying physical motor torque."""

    if channel in _NORMALIZED_COMMAND_CHANNELS:
        return "normalized DirectInput command units"
    if channel == "periodic_period":
        return "DirectInput time units"
    if channel == "periodic_phase":
        return "DirectInput phase units"
    return "raw DirectInput command units"


@dataclass(slots=True)
class EventStore:
    capacity: int = 20_000
    marker_capacity: int = 1_024
    events: deque[Frame] = field(init=False)
    paused: bool = field(init=False, default=False)
    received: int = field(init=False, default=0)
    invalid: int = field(init=False, default=0)
    dropped: int = field(init=False, default=0)
    started: float = field(init=False, default=0.0)
    qpc_frequency: int = field(init=False, default=1_000_000_000)
    # Keep marker positions in the same monotonic QPC domain as events.  The
    # visible rolling window can advance after a marker is created, so storing
    # a relative offset here would make later exports drift.
    markers: list[tuple[int, str]] = field(init=False)

    def __post_init__(self) -> None:
        self.events: deque[Frame] = deque(maxlen=self.capacity)
        self.paused = False
        self.received = 0
        self.invalid = 0
        self.dropped = 0
        self.started = time.monotonic()
        self.qpc_frequency = 1_000_000_000
        self.markers = []

    def add(self, frame: Frame) -> None:
        if self.paused:
            return
        self.events.append(frame)
        self.received += 1
        if frame.message_type == 1 and frame.qpc_frequency:
            self.qpc_frequency = frame.qpc_frequency
        if frame.dropped:
            self.dropped = max(self.dropped, frame.dropped)

    def window(self, seconds: float) -> list[Frame]:
        if not self.events:
            return []
        newest = self.events[-1].qpc_ticks
        # QPC frequency is supplied by Hello; 1e9 is a safe fallback for a
        # display-only model when a fixture does not include Hello.
        cutoff = newest - int(seconds * self.qpc_frequency)
        return [event for event in self.events if event.qpc_ticks >= cutoff]

    def command_peak_rms(
        self,
        seconds: float,
        events: list[Frame] | None = None,
        channel: str = "magnitude",
        condition_axis: int = 0,
    ) -> tuple[float, float]:
        """Return time-weighted command peak/RMS for the selected window."""
        events = self.window(seconds) if events is None else events
        samples = [
            (event, value)
            for event in events
            if (value := command_channel_value(event, channel, condition_axis)) is not None
        ]
        if not samples:
            return 0.0, 0.0
        scale = command_channel_scale(channel)
        peak = max(abs(value) for _, value in samples) / scale
        weighted = 0.0
        total = 0
        for (previous, previous_value), (current, _) in pairwise(samples):
            delta = max(0, current.qpc_ticks - previous.qpc_ticks)
            weighted += (previous_value / scale) ** 2 * delta
            total += delta
        if total == 0:
            return peak, abs(samples[-1][1]) / scale
        return peak, math.sqrt(weighted / total)

    def mark_latest(self, label: str = "marker") -> None:
        """Record a user-created marker at the latest event's QPC tick."""
        if not self.events:
            return
        latest = self.events[-1]
        if len(self.markers) >= self.marker_capacity:
            del self.markers[: len(self.markers) - self.marker_capacity + 1]
        self.markers.append((latest.qpc_ticks, label[:64]))
