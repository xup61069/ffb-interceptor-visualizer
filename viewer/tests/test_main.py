# SPDX-License-Identifier: GPL-3.0-only
from __future__ import annotations

import csv
import time
from dataclasses import replace

import pytest
from PySide6 import QtTest

from ffb_visualizer.main import MainWindow

from .support import frame


def test_condition_channel_is_plotted_without_fabricated_samples(qtbot) -> None:
    window = MainWindow(start_server=False)
    qtbot.addWidget(window)
    window._enqueue(frame(sequence=1, qpc_ticks=1_000_000_000))
    window._refresh()

    condition_index = window.channel_box.findData("condition_offset")
    assert condition_index >= 0
    window.channel_box.setCurrentIndex(condition_index)
    window._refresh()
    _, values = window.curve.getData()
    assert len(values) == 1
    assert "Condition offset" in window.status.text()
    assert "motor torque" not in window.status.text().lower()


def test_device_and_effect_filters_are_scoped_to_producer(qtbot) -> None:
    window = MainWindow(start_server=False)
    qtbot.addWidget(window)
    first = replace(frame(sequence=1, process_id=101), device_id=7, effect_id=9)
    second = replace(frame(sequence=2, process_id=202), device_id=7, effect_id=9)
    window.store.add(first)
    window.store.add(second)
    window._update_filters()

    device_index = window.device_box.findData("101:7")
    effect_index = window.effect_box.findData("101:9")
    assert device_index >= 0
    assert effect_index >= 0
    assert window.device_box.findData("101:0") == -1
    assert window.effect_box.findData("101:0") == -1
    window.device_box.setCurrentIndex(device_index)
    assert window._visible_events() == [first]
    window.effect_box.setCurrentIndex(effect_index)
    assert window._visible_events() == [first]

    producer_index = window.producer_box.findData(202)
    assert producer_index >= 0
    window.producer_box.setCurrentIndex(producer_index)
    assert window.device_box.findData("101:7") == -1
    assert window.effect_box.findData("101:9") == -1
    assert window._visible_events() == [second]


def test_csv_export_includes_bounded_producer_identity(qtbot, monkeypatch, tmp_path) -> None:
    window = MainWindow(start_server=False)
    qtbot.addWidget(window)
    hello = replace(
        frame(sequence=1, process_id=101), message_type=1, text=r"C:\Games\producer.exe"
    )
    command = replace(frame(sequence=2, process_id=101), device_id=7, effect_id=9)
    window.store.add(hello)
    window.store.add(command)
    path = tmp_path / "trace.csv"
    monkeypatch.setattr(
        "PySide6.QtWidgets.QFileDialog.getSaveFileName",
        lambda *args, **kwargs: (str(path), ""),
    )

    window._export_csv()

    rows = list(csv.DictReader(path.open(newline="", encoding="utf-8")))
    assert rows[0]["producer"] == "producer.exe"
    assert rows[0]["process_id"] == "101"
    assert "C:\\Games" not in path.read_text(encoding="utf-8")


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
