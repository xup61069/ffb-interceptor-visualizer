# Architecture

`dinput8.dll` is a delay-loaded proxy. `DllMain` only stores the module handle
and calls `DisableThreadLibraryCalls`; `DirectInput8Create` performs one-time
System32 loading and starts telemetry after process initialization. The COM
chain is `IDirectInput8[A/W] → IDirectInputDevice8[A/W] →
IDirectInputEffect`. A/W views created by the proxy share a control block, so their
`QueryInterface(IUnknown)`, AddRef and Release calls retain one canonical
identity and reference count; aggregation and unknown interfaces pass through
unchanged.

FFB calls copy validated scalar DirectInput structures into a preallocated
bounded queue. A worker thread owns pipe I/O and emits protocol frames. Queue
overflow increments a drop counter; it never waits or changes the original
HRESULT/arguments. The viewer is a named-pipe server with a background reader
and a 60 Hz Qt model/plot refresh. No file or network sink is active by default.
