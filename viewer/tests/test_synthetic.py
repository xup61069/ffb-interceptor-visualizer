# SPDX-License-Identifier: GPL-3.0-only
import time
from dataclasses import replace

from ffb_visualizer.model import EventStore
from ffb_visualizer.protocol import Frame
from ffb_visualizer.trace import trace_payload


def test_synthetic_ingestion_rate_and_metrics() -> None:
    store = EventStore(capacity=2_000)
    start = time.perf_counter()
    for index in range(2_000):
        store.add(
            Frame(
                6,
                0,
                index,
                index * 1_000_000,
                1,
                1_000_000_000,
                2,
                3,
                bytes(16),
                0,
                0,
                0,
                0,
                10_000,
                0,
                0,
                0,
                1,
                0,
                0,
                0,
                0,
                0,
                0,
                5000,
                0,
                0,
                0,
                0,
                0,
                0,
                (5000,),
                (0,),
                (),
            )
        )
    elapsed = time.perf_counter() - start
    assert store.received == 2_000
    peak, rms = store.command_peak_rms(5)
    assert peak == 0.5
    assert rms == 0.5
    assert elapsed < 1.0


def test_selected_channel_and_user_marker_are_bounded_metadata() -> None:
    store = EventStore(capacity=4)
    for index, value in enumerate((1_000, 4_000)):
        store.add(
            Frame(
                message_type=6,
                flags=0,
                sequence=index,
                qpc_ticks=index * 1_000_000_000,
                process_id=42,
                qpc_frequency=1_000_000_000,
                device_id=7,
                effect_id=8,
                effect_guid=bytes(16),
                hresult=0,
                di_flags=0,
                duration=0,
                sample_period=0,
                gain=0,
                start_delay=0,
                trigger_button=0,
                trigger_repeat=0,
                iterations=1,
                envelope_attack_level=0,
                envelope_attack_time=0,
                envelope_fade_level=0,
                envelope_fade_time=0,
                property_id=0,
                dropped=0,
                magnitude=value,
                ramp_start=value,
                ramp_end=value * 2,
                periodic_magnitude=value * 3,
                periodic_offset=0,
                periodic_phase=0,
                periodic_period=0,
            )
        )
    peak, rms = store.command_peak_rms(5, channel="ramp_end")
    assert peak == 0.8
    assert rms == 0.2
    store.mark_latest("button press")
    assert store.markers == [(1.0, "button press")]
    hello = replace(store.events[0], message_type=1, text=r"C:\Games\sample.exe")
    exported = trace_payload([hello, *list(store.events)], store.qpc_frequency, store.markers)
    assert exported["format"] == "ffbtrace"
    assert exported["version"] == 1
    assert exported["producer"] == "sample.exe"
    assert "C:\\Games" not in str(exported)
    assert exported["markers"] == [{"relative_seconds": 1.0, "label": "button press"}]
