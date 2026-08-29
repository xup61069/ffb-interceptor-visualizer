# Architecture

Two producer modes share the same DirectInput wrapper and telemetry core.

The no-game-DLL mode uses an architecture-matched launcher and fixed sibling
`FFBInterceptor.Hook.dll`. The launcher validates a local non-system game EXE,
creates only a new child with `DEBUG_ONLY_THIS_PROCESS`, observes normal loader
events, and places a temporary one-byte breakpoint at the mapped PE entry point.
At that breakpoint it restores the original byte, rewinds the main thread to
the entry point, explicitly suspends it before the first instruction executes,
and continues the debug event. It then resolves the child's system
`LoadLibraryW`, loads only the fixed sibling hook, calls its fixed initializer,
resumes the main thread, and exits with process-kill-on-debugger-exit disabled.
The breakpoint exists only in child memory and is restored before application
code runs; no game file is written.

The hook loads the genuine System32 `dinput8.dll` and walks bounded PE import
tables in currently loaded modules. It replaces only an exact, still-unmodified
`dinput8.dll!DirectInput8Create` IAT pointer. Unreadable or malformed module
headers are skipped fail-closed. A bounded monitor repeats the same check for
late modules for approximately 10.5 minutes. Dynamic `GetProcAddress`, private
loaders, another child created by a launcher, or DirectInput loaded after that
window are outside this path.

The traditional `dinput8.dll` mode is a delay-loaded proxy. `DllMain` only stores the module handle
and calls `DisableThreadLibraryCalls`; `DirectInput8Create` performs one-time
System32 loading and starts telemetry after process initialization. The COM
chain is `IDirectInput8[A/W] → IDirectInputDevice8[A/W] →
IDirectInputEffect`. A/W views created by the proxy share a control block, so their
`QueryInterface(IUnknown)`, AddRef and Release calls retain one canonical
identity and reference count; aggregation and unknown interfaces pass through
unchanged. If an alternate A/W view cannot be allocated, the unpublished
wrapper is discarded without consuming the caller-owned real COM reference,
so fail-open fallback still returns the original interface safely.

In either mode, FFB calls copy validated scalar DirectInput structures into two independent,
preallocated bounded queues. One worker owns the Python viewer pipe and the
other owns the SimHub pipe. Each has separate reconnect and drop accounting,
so a blocked consumer cannot block the DirectInput hot path or the other
consumer. Queue overflow increments that sink's drop counter; it never waits
or changes the original HRESULT/arguments. Concurrent emitters commit sequence
allocation and both queue publications under a short SRW lock, preventing an
older state mutation from arriving after a newer one. A successful device
`Unacquire`, or a polled acquisition-loss result, is represented as
`DISFFC_STOPALL`, matching DirectInput's effect unload/stop semantics while
retaining cached parameters for a later `Start`.

The Python viewer is a named-pipe server with background readers and a 60 Hz
Qt model/plot refresh. The .NET Framework 4.8 SimHub plug-in is a second
current-user pipe server. Its background readers feed a lock-bounded state
engine; a steady 60 Hz timer evaluates held effect state and publishes an
immutable snapshot. SimHub's `DataUpdate` only swaps that snapshot and drains
a bounded event queue, keeping pipe I/O and detector work off its critical
game-data path. The engine expires finite effects from duration/start-delay/
iteration metadata and invalidates stale state after a sink reports loss. The
SimHub server uses overlapped connect/read operations, `CancelIoEx`, and joined
background workers so plug-in unload/reload does not leave blocked pipe I/O.
No file or network sink is active by default.
