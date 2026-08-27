# SPDX-License-Identifier: GPL-3.0-only
from __future__ import annotations

import time

import pytest
from PySide6 import QtTest

from ffb_visualizer.main import MainWindow

from .support import frame


@pytest.mark.performance
def test_ui_uses_a_60hz_timer_and_sustains_at_least_30fps(qtbot) -> None:
    window = MainWindow(start_server=False)
    qtbot.addWidget(window)
    assert window.timer.interval() == 16

    durations: list[float] = []
    sequence = 1
    for _ in range(60):
        for _ in range(17):
            window._enqueue(frame(sequence=sequence, qpc_ticks=sequence * 1_000_000))
            sequence += 1
        started = time.perf_counter()
        window._refresh()
        durations.append(time.perf_counter() - started)
    assert window.store.received == 1_020
    p99_index = (len(durations) * 99 + 99) // 100 - 1
    p99_seconds = sorted(durations)[p99_index]
    assert p99_seconds < 1 / 30

    spy = QtTest.QSignalSpy(window.timer.timeout)
    window.show()
    qtbot.wait(1_050)
    frames = spy.count()
    print(f"Qt refresh: {frames} ticks/s, p99 {p99_seconds * 1_000:.3f} ms")
    assert frames >= 30
