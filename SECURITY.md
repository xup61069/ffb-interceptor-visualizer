# Security policy

The supported release is the latest `v0.1.x` prerelease. Please report a
vulnerability privately through GitHub Private Vulnerability Reporting on
`xup61069/ffb-interceptor-visualizer` (or open a draft security advisory).
Do not include live game credentials, serial numbers, crash dumps with paths,
or private telemetry in a public issue. We will acknowledge a report within
14 days and coordinate a fix or mitigation before disclosure.

The proxy is fail-open by design. The named-pipe ACL restricts access to the
current user and rejects remote clients, but another malicious process running
as the same user is outside the complete security boundary. Never use this
experiment as an anti-cheat or safety control.
