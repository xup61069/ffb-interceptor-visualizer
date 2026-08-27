# SPDX-License-Identifier: GPL-3.0-only
"""PySide6 viewer entry point."""

from __future__ import annotations

import csv
import json
import sys
from pathlib import Path
from queue import Empty, Full, Queue

import pyqtgraph as pg
from PySide6 import QtCore, QtGui, QtWidgets

from .model import EventStore
from .pipe_server import PipeServer
from .protocol import Frame
from .trace import trace_payload


class MainWindow(QtWidgets.QMainWindow):
    _MAX_PENDING_PER_REFRESH = 4_096

    def __init__(self, *, start_server: bool = True) -> None:
        super().__init__()
        self.setWindowTitle("FFB Interceptor Visualizer — command monitor")
        self.resize(1100, 700)
        self.store = EventStore()
        self.server = PipeServer(self._enqueue)
        self.pending: Queue[Frame] = Queue(maxsize=20_000)
        self._last_filter_received = -1
        self._last_filter_window = ""
        self.plot = pg.PlotWidget()
        self.plot.setLabel("left", "Command value (normalized API units)")
        self.plot.setLabel("bottom", "Relative time", units="s")
        self.curve = self.plot.plot(pen=pg.mkPen("#63d6ff", width=2))
        self.details = QtWidgets.QPlainTextEdit()
        self.details.setReadOnly(True)
        self.details.setMaximumBlockCount(32)
        self.details.setPlaceholderText("Raw command parameters will appear here.")
        self.status = QtWidgets.QLabel("Waiting for proxy…")
        self.producer_box = QtWidgets.QComboBox()
        self.producer_box.addItem("All producers")
        self.producer_box.currentIndexChanged.connect(self._refresh)
        self.device_box = QtWidgets.QComboBox()
        self.device_box.addItem("All devices")
        self.device_box.currentIndexChanged.connect(self._refresh)
        self.effect_box = QtWidgets.QComboBox()
        self.effect_box.addItem("All effects")
        self.effect_box.currentIndexChanged.connect(self._refresh)
        self.window_box = QtWidgets.QComboBox()
        self.window_box.addItems(["1", "5", "10", "30"])
        self.window_box.currentIndexChanged.connect(self._refresh)
        self.pause = QtWidgets.QPushButton("Pause")
        self.pause.clicked.connect(self._toggle_pause)
        self.channel_box = QtWidgets.QComboBox()
        self.channel_box.addItems(["Magnitude", "Ramp end", "Periodic magnitude"])
        self.channel_box.currentIndexChanged.connect(self._refresh)
        export = QtWidgets.QPushButton("Export CSV")
        export.clicked.connect(self._export_csv)
        export_png = QtWidgets.QPushButton("Export PNG")
        export_png.clicked.connect(self._export_png)
        save_trace = QtWidgets.QPushButton("Save .ffbtrace")
        save_trace.clicked.connect(self._save_trace)
        mark = QtWidgets.QPushButton("Mark event")
        mark.clicked.connect(self._mark_event)
        toolbar = QtWidgets.QHBoxLayout()
        toolbar.addWidget(QtWidgets.QLabel("Window (s)"))
        toolbar.addWidget(self.window_box)
        toolbar.addWidget(self.producer_box)
        toolbar.addWidget(self.device_box)
        toolbar.addWidget(self.effect_box)
        toolbar.addWidget(self.channel_box)
        toolbar.addWidget(self.pause)
        toolbar.addWidget(export)
        toolbar.addWidget(export_png)
        toolbar.addWidget(save_trace)
        toolbar.addWidget(mark)
        toolbar.addStretch(1)
        toolbar.addWidget(self.status)
        root = QtWidgets.QWidget()
        layout = QtWidgets.QVBoxLayout(root)
        layout.addLayout(toolbar)
        layout.addWidget(self.plot)
        layout.addWidget(self.details)
        self.setCentralWidget(root)
        self.timer = QtCore.QTimer(self)
        self.timer.timeout.connect(self._refresh)
        self.timer.start(16)
        if start_server:
            self.server.start()

    @QtCore.Slot(object)
    def _enqueue(self, frame: object) -> None:
        if isinstance(frame, Frame):
            try:
                self.pending.put_nowait(frame)
            except Full:
                self.store.dropped += 1

    def _refresh(self) -> None:
        for _ in range(self._MAX_PENDING_PER_REFRESH):
            try:
                frame = self.pending.get_nowait()
            except Empty:
                break
            self.store.add(frame)
        self._update_filters()
        events = self._visible_events()
        if events:
            origin = events[0].qpc_ticks
            xs = [(event.qpc_ticks - origin) / self.store.qpc_frequency for event in events]
            channel = self.channel_box.currentIndex()
            if channel == 1:
                ys = [event.ramp_end / 10_000.0 for event in events]
            elif channel == 2:
                ys = [event.periodic_magnitude / 10_000.0 for event in events]
            else:
                ys = [event.magnitude / 10_000.0 for event in events]
            self.curve.setData(xs, ys)
            selected_channel = ("magnitude", "ramp_end", "periodic_magnitude")[channel]
            peak, rms = self.store.command_peak_rms(
                float(self.window_box.currentText()), events, selected_channel
            )
            self.status.setText(
                f"Command Peak/RMS ({self.channel_box.currentText()}) {peak:.3f}/{rms:.3f} · "
                f"events {self.store.received} · "
                f"drops {self.store.dropped} · pipe errors {self.server.errors}"
            )
        else:
            self.status.setText(
                f"events {self.store.received} · drops {self.store.dropped} · pipe errors {self.server.errors}"
            )
        self._update_details(events[-1] if events else None)

    def _visible_events(self) -> list[Frame]:
        events = self.store.window(float(self.window_box.currentText()))
        producer = self.producer_box.currentData()
        device = self.device_box.currentData()
        effect = self.effect_box.currentData()
        if producer is not None:
            events = [event for event in events if event.process_id == producer]
        if device is not None:
            events = [event for event in events if event.device_id == device]
        if effect is not None:
            events = [event for event in events if event.effect_id == effect]
        return events

    def _update_details(self, event: Frame | None) -> None:
        if event is None:
            self.details.clear()
            return
        lines = [
            (
                f"message_type={event.message_type} effect_kind={event.effect_kind} "
                f"command={event.command} sequence={event.sequence} "
                f"hresult=0x{event.hresult & 0xFFFFFFFF:08x}"
            ),
            f"process_id={event.process_id} device_id={event.device_id} effect_id={event.effect_id}",
            f"effect_guid={event.effect_guid.hex()} flags=0x{event.flags:08x} di_flags=0x{event.di_flags:08x}",
            f"duration={event.duration} gain={event.gain} iterations={event.iterations}",
            (
                f"envelope=(attack={event.envelope_attack_level}/{event.envelope_attack_time}, "
                f"fade={event.envelope_fade_level}/{event.envelope_fade_time})"
            ),
            f"magnitude={event.magnitude} ramp=({event.ramp_start}, {event.ramp_end})",
            (
                f"periodic=(magnitude={event.periodic_magnitude}, offset={event.periodic_offset}, "
                f"phase={event.periodic_phase}, period={event.periodic_period})"
            ),
            f"axes={list(event.axes)} directions={list(event.directions)} conditions={len(event.conditions)}",
            f"custom_redacted={event.custom_redacted} type_specific_size={event.type_specific_size}",
        ]
        lines.extend(
            f"condition[{index}]=offset:{condition.offset} +coef:{condition.positive_coefficient} "
            f"-coef:{condition.negative_coefficient} +sat:{condition.positive_saturation} "
            f"-sat:{condition.negative_saturation} deadband:{condition.dead_band}"
            for index, condition in enumerate(event.conditions)
        )
        self.details.setPlainText("\n".join(lines))

    def _update_filters(self) -> None:
        """Refresh filter choices from stable IDs without retaining process paths."""
        current_window = self.window_box.currentText()
        if (
            self._last_filter_received == self.store.received
            and self._last_filter_window == current_window
        ):
            return
        self._last_filter_received = self.store.received
        self._last_filter_window = current_window
        values = self.store.window(float(self.window_box.currentText()))
        choices = (
            (self.producer_box, "All producers", sorted({event.process_id for event in values})),
            (self.device_box, "All devices", sorted({event.device_id for event in values})),
            (self.effect_box, "All effects", sorted({event.effect_id for event in values})),
        )
        for box, label, ids in choices:
            selected = box.currentData()
            box.blockSignals(True)
            box.clear()
            box.addItem(label, None)
            for value in ids:
                box.addItem(str(value), value)
            index = box.findData(selected)
            box.setCurrentIndex(max(index, 0))
            box.blockSignals(False)

    def _toggle_pause(self) -> None:
        self.store.paused = not self.store.paused
        self.pause.setText("Resume" if self.store.paused else "Pause")

    def _export_csv(self) -> None:
        path, _ = QtWidgets.QFileDialog.getSaveFileName(self, "Export command trace", "trace.csv")
        if not path:
            return
        events = self._visible_events()
        origin = events[0].qpc_ticks if events else 0
        with Path(path).open("w", newline="", encoding="utf-8") as stream:
            writer = csv.writer(stream)
            writer.writerow(
                [
                    "relative_seconds",
                    "message_type",
                    "effect_kind",
                    "command",
                    "device_id",
                    "effect_id",
                    "magnitude",
                ]
            )
            for event in events:
                writer.writerow(
                    [
                        (event.qpc_ticks - origin) / self.store.qpc_frequency,
                        event.message_type,
                        event.effect_kind,
                        event.command,
                        event.device_id,
                        event.effect_id,
                        event.magnitude,
                    ]
                )

    def _export_png(self) -> None:
        path, _ = QtWidgets.QFileDialog.getSaveFileName(
            self, "Export plot", "trace.png", "PNG (*.png)"
        )
        if path:
            self.plot.grab().save(path, "PNG")

    def _mark_event(self) -> None:
        self.store.mark_latest()
        self.status.setText(f"Marker added · total {len(self.store.markers)}")

    def _save_trace(self) -> None:
        path, _ = QtWidgets.QFileDialog.getSaveFileName(
            self, "Save FFB trace", "trace.ffbtrace", "FFB trace (*.ffbtrace)"
        )
        if not path:
            return
        events = self._visible_events()
        payload = trace_payload(events, self.store.qpc_frequency, self.store.markers)
        with Path(path).open("w", encoding="utf-8") as stream:
            json.dump(payload, stream, ensure_ascii=False, indent=2)

    def closeEvent(self, event: QtGui.QCloseEvent) -> None:
        self.server.stop()
        super().closeEvent(event)


def run() -> int:
    app = QtWidgets.QApplication(sys.argv)
    window = MainWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(run())
