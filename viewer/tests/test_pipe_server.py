# SPDX-License-Identifier: GPL-3.0-only
from __future__ import annotations

import multiprocessing
import os
import threading
import time
from contextlib import contextmanager

import pytest

from ffb_visualizer import pipe_server
from ffb_visualizer.protocol import Frame

from .support import frame_bytes

_WARMUP_FRAMES = 128


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


def _produce_frames(total: int) -> None:
    """Write a burst from a separate process, like the native proxy does."""

    with _connect_writer() as writer:
        _write(writer, frame_bytes(message_type=1, sequence=0))
        for sequence in range(1, _WARMUP_FRAMES + 1):
            _write(writer, frame_bytes(sequence=sequence))
        for sequence in range(_WARMUP_FRAMES + 1, _WARMUP_FRAMES + total + 1):
            timestamp = time.perf_counter_ns()
            _write(writer, frame_bytes(sequence=sequence, qpc_ticks=timestamp))
            # Keep the producer above the 1 kHz gate without creating an
            # unrepresentative burst that can backlog a hosted runner.
            time.sleep(0.0002)


@pytest.mark.skipif(os.name != "nt", reason="uses the production Windows named pipe")
def test_windows_pipe_accepts_fragmented_frames_and_reconnects() -> None:
    received: list[int] = []
    delivered = threading.Event()

    def on_frame(value: Frame) -> None:
        received.append(value.sequence)
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


@pytest.mark.skipif(os.name != "nt", reason="uses the production Windows named pipe")
def test_windows_pipe_rejects_unavailable_client_pid(monkeypatch) -> None:
    received: list[object] = []
    monkeypatch.setattr(pipe_server, "_client_pid", lambda _handle: None)
    server = pipe_server.PipeServer(received.append)
    server.start()
    try:
        with _connect_writer() as writer:
            _write(writer, frame_bytes(message_type=1, sequence=1))
        deadline = time.monotonic() + 5.0
        while server.errors == 0 and time.monotonic() < deadline:
            time.sleep(0.01)
        assert server.errors >= 1
        assert received == []
    finally:
        server.stop()
        assert not server._thread or not server._thread.is_alive()


@pytest.mark.skipif(os.name != "nt", reason="uses the production Windows named pipe")
def test_windows_pipe_rejects_truncated_frame_at_disconnect() -> None:
    received: list[Frame] = []
    hello_delivered = threading.Event()

    def on_frame(value: Frame) -> None:
        received.append(value)
        if value.sequence == 1:
            hello_delivered.set()

    server = pipe_server.PipeServer(on_frame)
    server.start()
    try:
        hello = frame_bytes(message_type=1, sequence=1)
        truncated = frame_bytes(sequence=2)[:17]
        with _connect_writer() as writer:
            _write(writer, hello)
            assert hello_delivered.wait(5.0)
            _write(writer, truncated)
        deadline = time.monotonic() + 5.0
        while server.errors == 0 and time.monotonic() < deadline:
            time.sleep(0.01)
        assert server.errors >= 1
        assert [frame.sequence for frame in received] == [1]
    finally:
        server.stop()
        assert not server._thread or not server._thread.is_alive()


@pytest.mark.skipif(os.name != "nt", reason="uses the production Windows named pipe")
def test_windows_pipe_rejects_out_of_order_sequence() -> None:
    received: list[int] = []
    server = pipe_server.PipeServer(lambda frame: received.append(frame.sequence))
    server.start()
    try:
        with _connect_writer() as writer:
            _write(writer, frame_bytes(message_type=1, sequence=1))
            _write(writer, frame_bytes(sequence=3))
            _write(writer, frame_bytes(sequence=2))
        deadline = time.monotonic() + 5.0
        while server.errors == 0 and time.monotonic() < deadline:
            time.sleep(0.01)
        assert server.errors >= 1
        assert received == [1, 3]
    finally:
        server.stop()
        assert not server._thread or not server._thread.is_alive()


@pytest.mark.skipif(os.name != "nt", reason="uses the production Windows named pipe")
def test_windows_pipe_stop_closes_connected_client_readers() -> None:
    server = pipe_server.PipeServer(lambda _frame: None)
    server.start()
    try:
        with _connect_writer():
            deadline = time.monotonic() + 5.0
            while not server._client_handles and time.monotonic() < deadline:
                time.sleep(0.01)
            assert server._client_handles
            server.stop()
            assert not server._clients
            assert not server._client_handles
            assert server.errors == 0
    finally:
        server.stop()
        assert not server._thread or not server._thread.is_alive()


@pytest.mark.performance
@pytest.mark.skipif(os.name != "nt", reason="uses the production Windows named pipe")
def test_windows_pipe_ingestion_p99_under_five_milliseconds_at_1000_events_per_second() -> None:
    total = 2_000
    latencies_ns: list[int] = []
    production_ticks: list[int] = []
    delivered = threading.Event()

    def on_frame(value: Frame) -> None:
        sequence = value.sequence
        first_measured = _WARMUP_FRAMES + 1
        last_measured = _WARMUP_FRAMES + total
        if first_measured <= sequence <= last_measured:
            latencies_ns.append(time.perf_counter_ns() - value.qpc_ticks)
            if sequence == first_measured or sequence == last_measured:
                production_ticks.append(value.qpc_ticks)
            if len(latencies_ns) == total:
                delivered.set()

    server = pipe_server.PipeServer(on_frame)
    server.start()
    producer = multiprocessing.Process(target=_produce_frames, args=(total,))
    producer.start()
    try:
        assert delivered.wait(10.0)
        producer.join(5.0)
        assert producer.exitcode == 0
        assert len(production_ticks) == 2
        production_elapsed = production_ticks[1] - production_ticks[0]
        rate = (total - 1) / (production_elapsed / 1_000_000_000)
        p99_index = (len(latencies_ns) * 99 + 99) // 100 - 1
        p99_nanoseconds = sorted(latencies_ns)[p99_index]
        print(f"pipe ingestion: {rate:.0f} events/s, p99 {p99_nanoseconds / 1_000_000:.3f} ms")
        assert rate >= 1_000.0
        assert p99_nanoseconds < 5_000_000
    finally:
        if producer.is_alive():
            producer.terminate()
            producer.join(5.0)
        server.stop()
        assert not server._thread or not server._thread.is_alive()
