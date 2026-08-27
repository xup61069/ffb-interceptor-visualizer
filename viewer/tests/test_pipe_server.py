# SPDX-License-Identifier: GPL-3.0-only
from ffb_visualizer import pipe_server


def test_non_windows_receiver_fails_closed(monkeypatch) -> None:
    monkeypatch.setattr(pipe_server.os, "name", "posix")
    server = pipe_server.PipeServer(lambda _frame: None)
    server._run()
    assert server.errors == 1
