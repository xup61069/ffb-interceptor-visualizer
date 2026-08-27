# SPDX-License-Identifier: GPL-3.0-only
"""PySide6 viewer entry point."""

from __future__ import annotations

import csv
import sys
from pathlib import Path

import pyqtgraph as pg
from PySide6 import QtCore, QtGui, QtWidgets

from .model import EventStore
from .pipe_server import PipeServer
from .protocol import Frame


class MainWindow(QtWidgets.QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("FFB Interceptor Visualizer — command monitor")
        self.resize(1100, 700)
        self.store = EventStore()
        self.server = PipeServer(self._enqueue)
        self.pending: list[Frame] = []
        self.plot = pg.PlotWidget()
        self.plot.setLabel("left", "Command value (normalized API units)")
        self.plot.setLabel("bottom", "Relative time", units="s")
        self.curve = self.plot.plot(pen=pg.mkPen("#63d6ff", width=2))
        self.status = QtWidgets.QLabel("Waiting for proxy…")
        self.producer_box = QtWidgets.QComboBox()
        self.producer_box.addItem("All producers")
        self.device_box = QtWidgets.QComboBox()
        self.device_box.addItem("All devices")
        self.effect_box = QtWidgets.QComboBox()
        self.effect_box.addItem("All effects")
        self.window_box = QtWidgets.QComboBox()
        self.window_box.addItems(["1", "5", "10", "30"])
        self.pause = QtWidgets.QPushButton("Pause")
        self.pause.clicked.connect(self._toggle_pause)
        export = QtWidgets.QPushButton("Export CSV")
        export.clicked.connect(self._export_csv)
        toolbar = QtWidgets.QHBoxLayout()
        toolbar.addWidget(QtWidgets.QLabel("Window (s)"))
        toolbar.addWidget(self.window_box)
        toolbar.addWidget(self.producer_box)
        toolbar.addWidget(self.device_box)
        toolbar.addWidget(self.effect_box)
        toolbar.addWidget(self.pause)
        toolbar.addWidget(export)
        toolbar.addStretch(1)
        toolbar.addWidget(self.status)
        root = QtWidgets.QWidget()
        layout = QtWidgets.QVBoxLayout(root)
        layout.addLayout(toolbar)
        layout.addWidget(self.plot)
        self.setCentralWidget(root)
        self.timer = QtCore.QTimer(self)
        self.timer.timeout.connect(self._refresh)
        self.timer.start(16)
        self.server.start()

    @QtCore.Slot(object)
    def _enqueue(self, frame: object) -> None:
        if isinstance(frame, Frame):
            self.pending.append(frame)

    def _refresh(self) -> None:
        pending, self.pending = self.pending, []
        for frame in pending:
            self.store.add(frame)
        events = self.store.window(float(self.window_box.currentText()))
        if events:
            origin = events[0].qpc_ticks
            xs = [(event.qpc_ticks - origin) / self.store.qpc_frequency for event in events]
            ys = [event.magnitude / 10_000.0 for event in events]
            self.curve.setData(xs, ys)
            peak, rms = self.store.command_peak_rms(float(self.window_box.currentText()))
            self.status.setText(
                f"Command Peak/RMS {peak:.3f}/{rms:.3f} · events {self.store.received} · "
                f"drops {self.store.dropped} · pipe errors {self.server.errors}"
            )
        else:
            self.status.setText(
                f"events {self.store.received} · drops {self.store.dropped} · pipe errors {self.server.errors}"
            )

    def _toggle_pause(self) -> None:
        self.store.paused = not self.store.paused
        self.pause.setText("Resume" if self.store.paused else "Pause")

    def _export_csv(self) -> None:
        path, _ = QtWidgets.QFileDialog.getSaveFileName(self, "Export command trace", "trace.csv")
        if not path:
            return
        events = self.store.window(float(self.window_box.currentText()))
        origin = events[0].qpc_ticks if events else 0
        with Path(path).open("w", newline="", encoding="utf-8") as stream:
            writer = csv.writer(stream)
            writer.writerow(
                ["relative_seconds", "message_type", "device_id", "effect_id", "magnitude"]
            )
            for event in events:
                writer.writerow(
                    [
                        (event.qpc_ticks - origin) / self.store.qpc_frequency,
                        event.message_type,
                        event.device_id,
                        event.effect_id,
                        event.magnitude,
                    ]
                )

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
