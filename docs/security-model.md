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

The proxy never injects code, patches vtables, scans memory, reads arbitrary
effect payloads, or changes FFB semantics. It records only bounded standard
DirectInput fields. Errors in allocation, parsing, pipe connection or sending
are swallowed and the original COM call remains authoritative. Install/remove
is manual to make an existing game proxy recoverable.
