# SPDX-License-Identifier: GPL-3.0-only
"""Versioned, privacy-preserving FFB trace export format."""

from __future__ import annotations

from collections.abc import Sequence

from .protocol import Frame


def trace_payload(
    events: Sequence[Frame],
    qpc_frequency: int,
    markers: Sequence[tuple[float, str]],
) -> dict[str, object]:
    """Build a serializable v1 trace without paths or host-specific metadata."""
    frequency = qpc_frequency or 1_000_000_000
    origin = events[0].qpc_ticks if events else 0
    producer = ""
    for event in events:
        if event.message_type == 1 and event.text:
            producer = event.text.replace("\\", "/").rsplit("/", 1)[-1][:255]
            break
    return {
        "format": "ffbtrace",
        "version": 1,
        "qpc_frequency": frequency,
        "producer": producer,
        "events": [_event_payload(event, origin, frequency) for event in events],
        "markers": [
            {"relative_seconds": seconds, "label": label[:64]} for seconds, label in markers
        ],
    }


def _event_payload(event: Frame, origin: int, frequency: int) -> dict[str, object]:
    return {
        "relative_seconds": (event.qpc_ticks - origin) / frequency,
        "message_type": event.message_type,
        "flags": event.flags,
        "sequence": event.sequence,
        "process_id": event.process_id,
        "device_id": event.device_id,
        "effect_id": event.effect_id,
        "effect_guid": event.effect_guid.hex(),
        "hresult": event.hresult,
        "di_flags": event.di_flags,
        "duration": event.duration,
        "gain": event.gain,
        "magnitude": event.magnitude,
        "ramp_start": event.ramp_start,
        "ramp_end": event.ramp_end,
        "periodic_magnitude": event.periodic_magnitude,
        "periodic_offset": event.periodic_offset,
        "periodic_phase": event.periodic_phase,
        "periodic_period": event.periodic_period,
        "axes": list(event.axes),
        "directions": list(event.directions),
        "conditions": [
            {
                "offset": condition.offset,
                "positive_coefficient": condition.positive_coefficient,
                "negative_coefficient": condition.negative_coefficient,
                "positive_saturation": condition.positive_saturation,
                "negative_saturation": condition.negative_saturation,
                "dead_band": condition.dead_band,
            }
            for condition in event.conditions
        ],
        "type_specific_size": event.type_specific_size,
        "custom_redacted": event.custom_redacted,
    }
