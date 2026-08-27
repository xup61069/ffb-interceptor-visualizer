# SPDX-License-Identifier: GPL-3.0-only
import time
from dataclasses import replace

from ffb_visualizer.model import EventStore, command_channel_value
from ffb_visualizer.protocol import Condition, Frame
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
                effect_kind=2,
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
    assert {
        "sample_period",
        "start_delay",
        "trigger_button",
        "trigger_repeat",
        "iterations",
        "envelope_attack_level",
        "envelope_fade_time",
        "property_id",
        "dropped",
    }.issubset(exported["events"][0])


def test_condition_channels_are_observed_without_synthesizing_force() -> None:
    condition = Condition(
        offset=-12,
        positive_coefficient=2_000,
        negative_coefficient=-3_000,
        positive_saturation=4_000,
        negative_saturation=5_000,
        dead_band=6,
    )
    event = Frame(
        message_type=5,
        flags=0,
        sequence=1,
        qpc_ticks=1,
        process_id=1,
        qpc_frequency=1_000_000_000,
        device_id=2,
        effect_id=3,
        effect_guid=bytes(16),
        hresult=0,
        di_flags=0,
        duration=0,
        sample_period=0,
        gain=0,
        start_delay=0,
        trigger_button=0,
        trigger_repeat=0,
        iterations=0,
        envelope_attack_level=0,
        envelope_attack_time=0,
        envelope_fade_level=0,
        envelope_fade_time=0,
        property_id=0,
        dropped=0,
        magnitude=9_000,
        ramp_start=0,
        ramp_end=0,
        periodic_magnitude=0,
        periodic_offset=0,
        periodic_phase=0,
        periodic_period=0,
        effect_kind=8,
        conditions=(condition,),
    )
    assert command_channel_value(event, "condition_offset") == -12
    assert command_channel_value(event, "condition_positive_coefficient") == 2_000
    assert command_channel_value(event, "condition_negative_saturation") == 5_000
    assert command_channel_value(event, "condition_dead_band") == 6
    assert command_channel_value(event, "condition_offset", 1) is None
    assert command_channel_value(event, "constant_magnitude") is None

    constant = replace(event, effect_kind=1, magnitude=1_234)
    assert command_channel_value(constant, "constant_magnitude") == 1_234
    ramp = replace(event, effect_kind=2, ramp_start=-10, ramp_end=20)
    assert command_channel_value(ramp, "ramp_start") == -10
    assert command_channel_value(ramp, "ramp_end") == 20
    periodic = replace(
        event,
        effect_kind=4,
        periodic_magnitude=30,
        periodic_offset=40,
        periodic_phase=50,
        periodic_period=60,
    )
    assert command_channel_value(periodic, "periodic_magnitude") == 30
    assert command_channel_value(periodic, "periodic_offset") == 40
    assert command_channel_value(periodic, "periodic_phase") == 50
    assert command_channel_value(periodic, "periodic_period") == 60

    store = EventStore()
    store.add(event)
    peak, rms = store.command_peak_rms(1, channel="condition_positive_coefficient")
    assert peak == 0.2
    assert rms == 0.2
