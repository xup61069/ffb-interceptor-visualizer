# Protocol v1

The production pipe is `\\.\pipe\ffb-interceptor-v1`; the proxy is a one-way
client and the viewer is the server. Every frame starts with this explicit
little-endian header (32 bytes):

| offset | type | meaning |
|---:|---|---|
| 0 | bytes[4] | ASCII `FFB1` |
| 4 | u16 | version = 1 |
| 6 | u16 | message type |
| 8 | u32 | total frame size |
| 12 | u32 | flags |
| 16 | u64 | sequence |
| 24 | u64 | QPC ticks |

Payloads contain stable device/effect IDs, GUID, HRESULT, `DIEP_*` flags,
duration, gain, direction, axes, envelope and tagged Constant/Ramp/Periodic/
Condition fields. The payload ends with optional little-endian `effect_kind` and
`command` u16 values; older v1 readers may treat absent values as Unknown/zero.
Axis and condition counts are capped at eight; frame size is capped at 64 KiB.
Custom effects never copy arbitrary pointers or game memory.
The `Hello` payload carries the process ID, bitness in header flags, QPC
frequency, build version, per-process session ID and executable basename (never
the full path). Other messages leave those identity strings empty.
The current implementation decodes partial streams and rejects malformed,
oversize, truncated and version-mismatched frames. A malformed header is a
connection error; the parser does not resynchronize across arbitrary bytes.
Disconnecting with a non-empty partial-frame tail is also a protocol error.
