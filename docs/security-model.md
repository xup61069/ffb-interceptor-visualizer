# Security model

The viewer and SimHub plug-in each create a local named pipe with a DACL for
the current interactive user and `PIPE_REJECT_REMOTE_CLIENTS`. On the mandatory first `Hello`, they
require `GetNamedPipeClientProcessId` to succeed and compare the claimed PID
with the kernel-reported client PID. This prevents remote clients and other
users in normal configurations; each connection must begin with a matching
`Hello`, and the server bounds active client readers. A process running as the
same user can still impersonate a proxy, so the pipe is telemetry, not an
authentication boundary. If pywin32 cannot construct the current-user ACL, the
viewer refuses to create the production pipe instead of falling back to a
default DACL. The net48 server creates the pipe through Win32 so the remote
client rejection flag is not lost through a managed API overload; it also
uses a fixed 32-client maximum, a 64 KiB frame bound and strict session-token
validation. Both consumers reject duplicate or decreasing per-connection
sequence numbers. The SimHub server uses overlapped I/O cancellation and joins
all accept/client workers before completing plug-in shutdown.

The traditional proxy mode never injects code, patches vtables, scans arbitrary
memory, reads arbitrary effect payloads, or changes FFB semantics. It records
only bounded standard DirectInput fields. Errors in allocation, parsing, pipe
connection or sending are swallowed and the original COM call remains
authoritative. Its installer preserves an existing game proxy for recovery.

The optional no-game-DLL launcher has a narrower but different runtime model.
It can only create a new child selected by local EXE path, only loads the fixed
architecture-matched `FFBInterceptor.Hook.dll` beside itself, and exposes no
existing-PID or arbitrary-DLL option. It rejects UNC paths, Windows-directory
targets, architecture mismatches, overlong paths, and elevated game launches.
It provides no anti-cheat bypass, stealth, persistence, driver component, or
online-game support. Before application code runs it temporarily changes one
entry-point byte in child memory for synchronization, restores that byte, and
patches only an exact unmodified `DirectInput8Create` import pointer. It does
not modify the game EXE or game-directory DLLs on disk.

The launcher bundle installs only the two project-owned SimHub DLLs. Its
authoritative state is stored under common application data with a protected
Administrators/SYSTEM-write, Users-read ACL and a fixed two-file schema. The
elevated uninstaller reconstructs and validates the two allowed destinations,
backup names, hashes, local path boundary, and non-reparse files before any
mutation. Install and uninstall use staged moves and rollback; a changed file
or backup is retained rather than deleted. Imported dashboards are never
removed automatically. Re-running the same package is idempotent, while a
different package version is rejected with an explicit uninstall-first message
instead of mixing hook and SimHub DLL versions.
