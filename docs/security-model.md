# Security model

The viewer creates a local named pipe with a DACL for the current interactive
user and `PIPE_REJECT_REMOTE_CLIENTS`. On `Hello`, it may compare the claimed
PID with `GetNamedPipeClientProcessId`. This prevents remote clients and other
users in normal configurations; each connection must begin with a matching
`Hello`, and the server bounds active client readers. A process running as the
same user can still impersonate a proxy, so the pipe is telemetry, not an
authentication boundary. If pywin32 cannot construct the current-user ACL, the
viewer refuses to create the production pipe instead of falling back to a
default DACL.

The proxy never injects code, patches vtables, scans memory, reads arbitrary
effect payloads, or changes FFB semantics. It records only bounded standard
DirectInput fields. Errors in allocation, parsing, pipe connection or sending
are swallowed and the original COM call remains authoritative. Install/remove
is manual to make an existing game proxy recoverable.
