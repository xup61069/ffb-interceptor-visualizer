# SPDX-License-Identifier: GPL-3.0-only
"""Background named-pipe receiver for the production Windows pipe."""

from __future__ import annotations

import ctypes
import os
import threading
from collections.abc import Callable

from .protocol import ProtocolError, iter_frames

PIPE_NAME = r"\\.\pipe\ffb-interceptor-v1"


class PipeServer:
    """Accept multiple proxy instances without blocking the Qt thread."""

    _MAX_CLIENTS = 32

    def __init__(self, on_frame: Callable[[object], None]) -> None:
        self._on_frame = on_frame
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._clients: set[threading.Thread] = set()
        self._clients_lock = threading.Lock()
        self.errors = 0

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="ffb-pipe", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=1.0)

    def _run(self) -> None:
        if os.name != "nt":
            self.errors += 1
            return
        import pywintypes
        import win32file  # ty: ignore[unresolved-import]
        import win32pipe  # ty: ignore[unresolved-import]

        # ERROR_PIPE_CONNECTED is a successful race: a client connected
        # between CreateNamedPipe and ConnectNamedPipe.  pywin32 exposes it
        # as an exception rather than a boolean result.
        pipe_connected = 535
        reject_remote = getattr(win32pipe, "PIPE_REJECT_REMOTE_CLIENTS", 0x00000008)

        while not self._stop.is_set():
            handle = None
            try:
                handle = win32pipe.CreateNamedPipe(
                    PIPE_NAME,
                    win32pipe.PIPE_ACCESS_INBOUND,
                    win32pipe.PIPE_TYPE_BYTE
                    | win32pipe.PIPE_READMODE_BYTE
                    | win32pipe.PIPE_WAIT
                    | reject_remote,
                    win32pipe.PIPE_UNLIMITED_INSTANCES,
                    64 * 1024,
                    64 * 1024,
                    250,
                    _security_attributes(),
                )
                try:
                    win32pipe.ConnectNamedPipe(handle, None)
                except pywintypes.error as exc:
                    if getattr(exc, "winerror", None) != pipe_connected:
                        raise
                with self._clients_lock:
                    if len(self._clients) >= self._MAX_CLIENTS:
                        win32file.CloseHandle(handle)
                        self.errors += 1
                        continue
                client = threading.Thread(
                    target=self._read_client,
                    args=(handle, win32file),
                    name="ffb-pipe-client",
                    daemon=True,
                )
                with self._clients_lock:
                    self._clients.add(client)
                client.start()
            except (OSError, RuntimeError):
                self.errors += 1
                if handle is not None:
                    try:
                        win32file.CloseHandle(handle)
                    except (OSError, RuntimeError):
                        pass

    def _read_client(self, handle: int, win32file: object) -> None:
        client_pid = _client_pid(handle)
        first_frame = True
        buf = bytearray()
        try:
            while not self._stop.is_set():
                status, chunk = win32file.ReadFile(handle, 64 * 1024)  # ty: ignore[unresolved-attribute]
                if status or not chunk:
                    break
                buf.extend(chunk)
                try:
                    for frame in iter_frames(buf):
                        if first_frame:
                            if frame.message_type != 1:
                                raise ProtocolError("first frame must be Hello")
                            if client_pid and frame.process_id != client_pid:
                                raise ProtocolError("Hello PID does not match pipe client")
                        first_frame = False
                        self._on_frame(frame)
                except ProtocolError:
                    self.errors += 1
                    break
        except (OSError, RuntimeError):
            self.errors += 1
        finally:
            if first_frame and not self._stop.is_set():
                self.errors += 1
            try:
                win32file.CloseHandle(handle)  # ty: ignore[unresolved-attribute]
            except (OSError, RuntimeError):
                pass
            with self._clients_lock:
                self._clients.discard(threading.current_thread())


def _security_attributes():
    """Restrict the pipe DACL to the interactive owner SID when pywin32 allows it."""
    try:
        import win32con
        import win32security  # ty: ignore[unresolved-import]

        token = win32security.OpenProcessToken(
            win32security.GetCurrentProcess(), win32security.TOKEN_QUERY
        )
        sid = win32security.GetTokenInformation(token, win32security.TokenUser)[0]
        descriptor = win32security.SECURITY_DESCRIPTOR()
        dacl = win32security.ACL()
        dacl.AddAccessAllowedAce(win32security.ACL_REVISION, win32con.GENERIC_ALL, sid)
        descriptor.SetSecurityDescriptorDacl(1, dacl, 0)
        descriptor.SetSecurityDescriptorOwner(sid, 0)
        attributes = win32security.SECURITY_ATTRIBUTES()
        attributes.SECURITY_DESCRIPTOR = descriptor
        return attributes
    except (ImportError, OSError, RuntimeError, AttributeError):
        return None


def _client_pid(handle: int) -> int | None:
    """Return the kernel-reported client PID, when supported by this Windows build."""
    try:
        pid = ctypes.c_ulong(0)
        function = ctypes.windll.kernel32.GetNamedPipeClientProcessId
        function.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
        function.restype = ctypes.c_bool
        return int(pid.value) if function(int(handle), ctypes.byref(pid)) else None
    except (AttributeError, OSError, TypeError, ValueError):
        return None
