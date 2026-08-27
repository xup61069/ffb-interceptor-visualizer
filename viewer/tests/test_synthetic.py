# SPDX-License-Identifier: GPL-3.0-only
import time

from ffb_visualizer.model import EventStore
from ffb_visualizer.protocol import Frame


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
