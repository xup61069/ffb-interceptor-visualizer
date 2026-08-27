# `.ffbtrace` v1

The viewer writes a JSON trace only after the user chooses **Save .ffbtrace**.
The top-level object has `format: "ffbtrace"`, `version: 1`, the Hello QPC
frequency, a basename-only `producer` value, an `events` array and user-created
`markers`. Event timestamps are relative seconds from the first exported event.

Each event contains the protocol message type, effect kind/command, sequence,
HRESULT, stable process/device/effect IDs (device/effect IDs are scoped to the
producer process), GUID and standard DirectInput values (duration,
gain, directions, axes, envelope, Constant/Ramp/Periodic fields and bounded
Condition samples). Custom effect bytes and pointers are never written;
`custom_redacted` and `type_specific_size` communicate that boundary. Full
paths, device serials, account names and host names are intentionally absent.

This is an experimental interchange format. Readers must reject unknown
versions and treat missing fields as unavailable rather than reconstructing
physical torque.
