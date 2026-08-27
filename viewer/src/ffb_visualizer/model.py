# SPDX-License-Identifier: GPL-3.0-only
"""Bounded in-memory event model used by the Qt front end."""

from __future__ import annotations

import math
import time
from collections import deque
from dataclasses import dataclass, field
from itertools import pairwise

from .protocol import Frame


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
    markers: list[tuple[float, str]] = field(init=False)

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
    ) -> tuple[float, float]:
        """Return time-weighted command peak/RMS for the selected window."""
        events = self.window(seconds) if events is None else events
        if not events:
            return 0.0, 0.0

        def value(event: Frame) -> int:
            if channel == "ramp_end":
                return event.ramp_end
            if channel == "periodic_magnitude":
                return event.periodic_magnitude
            return event.magnitude

        peak = max(abs(value(event)) for event in events) / 10_000.0
        weighted = 0.0
        total = 0
        for previous, current in pairwise(events):
            delta = max(0, current.qpc_ticks - previous.qpc_ticks)
            weighted += (value(previous) / 10_000.0) ** 2 * delta
            total += delta
        if total == 0:
            return peak, abs(value(events[-1])) / 10_000.0
        return peak, math.sqrt(weighted / total)

    def mark_latest(self, label: str = "marker") -> None:
        """Record a user-created marker using relative, monotonic time only."""
        if not self.events:
            return
        origin = self.events[0].qpc_ticks
        latest = self.events[-1]
        seconds = (latest.qpc_ticks - origin) / (self.qpc_frequency or 1_000_000_000)
        if len(self.markers) >= self.marker_capacity:
            del self.markers[: len(self.markers) - self.marker_capacity + 1]
        self.markers.append((seconds, label[:64]))
