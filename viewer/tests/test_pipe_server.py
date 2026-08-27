# SPDX-License-Identifier: GPL-3.0-only
from __future__ import annotations

import os
import sys
import threading
import time
from contextlib import contextmanager

import pytest

from ffb_visualizer import pipe_server

from .support import frame_bytes


def test_non_windows_receiver_fails_closed(monkeypatch) -> None:
    monkeypatch.setattr(pipe_server.os, "name", "posix")
    server = pipe_server.PipeServer(lambda _frame: None)
    server._run()
    assert server.errors == 1


@contextmanager
def _connect_writer():
    import pywintypes
    import win32con
    import win32file  # ty: ignore[unresolved-import]

    deadline = time.monotonic() + 5.0
    while True:
        try:
            handle = win32file.CreateFile(
                pipe_server.PIPE_NAME,
                win32con.GENERIC_WRITE,
                0,
                None,
                win32con.OPEN_EXISTING,
                0,
                None,
            )
            break
        except pywintypes.error:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.01)
    try:
        yield handle
    finally:
        win32file.CloseHandle(handle)


def _write(handle: int, data: bytes) -> None:
    import win32file  # ty: ignore[unresolved-import]

    win32file.WriteFile(handle, data)


@pytest.mark.skipif(os.name != "nt", reason="uses the production Windows named pipe")
def test_windows_pipe_accepts_fragmented_frames_and_reconnects() -> None:
    received: list[int] = []
    delivered = threading.Event()

    def on_frame(value: object) -> None:
        received.append(value.sequence)  # ty: ignore[unresolved-attribute]
        if received.count(2) and received.count(4):
            delivered.set()

    server = pipe_server.PipeServer(on_frame)
    server.start()
    try:
        hello = frame_bytes(message_type=1, sequence=1)
        first = frame_bytes(sequence=2)
        with _connect_writer() as writer:
            _write(writer, hello[:17])
            _write(writer, hello[17:])
            _write(writer, first)
        second_hello = frame_bytes(message_type=1, sequence=3)
        second = frame_bytes(sequence=4)
        with _connect_writer() as writer:
            _write(writer, second_hello)
            _write(writer, second)
        assert delivered.wait(5.0)
        assert received == [1, 2, 3, 4]
    finally:
        server.stop()
        assert not server._thread or not server._thread.is_alive()


@pytest.mark.skipif(os.name != "nt", reason="uses the production Windows named pipe")
def test_windows_pipe_rejects_hello_pid_mismatch() -> None:
    received: list[object] = []
    server = pipe_server.PipeServer(received.append)
    server.start()
    try:
        with _connect_writer() as writer:
            _write(writer, frame_bytes(message_type=1, process_id=os.getpid() + 1))
        deadline = time.monotonic() + 5.0
        while server.errors == 0 and time.monotonic() < deadline:
            time.sleep(0.01)
        assert server.errors >= 1
        assert received == []
    finally:
        server.stop()
        assert not server._thread or not server._thread.is_alive()


@pytest.mark.performance
@pytest.mark.skipif(os.name != "nt", reason="uses the production Windows named pipe")
def test_windows_pipe_ingestion_p99_under_five_milliseconds_at_1000_events_per_second() -> None:
    total = 2_000
    sent: dict[int, int] = {}
    latencies_ns: list[int] = []
    delivered = threading.Event()

    def on_frame(value: object) -> None:
        sequence = value.sequence  # ty: ignore[unresolved-attribute]
        if sequence in sent:
            latencies_ns.append(time.perf_counter_ns() - sent[sequence])
            if len(latencies_ns) == total:
                delivered.set()

    server = pipe_server.PipeServer(on_frame)
    server.start()
    # The production proxy is a separate C++ process.  Keep the synthetic
    # writer/reader harness from measuring Python's default 5 ms GIL scheduling
    # quantum instead of the pipe parser's latency.
    previous_switch_interval = sys.getswitchinterval()
    sys.setswitchinterval(0.001)
    try:
        with _connect_writer() as writer:
            _write(writer, frame_bytes(message_type=1, sequence=0))
            production_start = time.perf_counter_ns()
            for sequence in range(1, total + 1):
                encoded = frame_bytes(sequence=sequence)
                sent[sequence] = time.perf_counter_ns()
                _write(writer, encoded)
                # Let the reader thread run; a real proxy is a separate
                # process and does not hold the test process' GIL.
                time.sleep(0)
            production_elapsed = time.perf_counter_ns() - production_start
        assert delivered.wait(10.0)
        rate = total / (production_elapsed / 1_000_000_000)
        p99_index = (len(latencies_ns) * 99 + 99) // 100 - 1
        p99_nanoseconds = sorted(latencies_ns)[p99_index]
        print(f"pipe ingestion: {rate:.0f} events/s, p99 {p99_nanoseconds / 1_000_000:.3f} ms")
        assert rate >= 1_000.0
        assert p99_nanoseconds < 5_000_000
    finally:
        sys.setswitchinterval(previous_switch_interval)
        server.stop()
        assert not server._thread or not server._thread.is_alive()
