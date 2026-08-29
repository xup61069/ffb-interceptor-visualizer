# Release process

Every public release is an existing stable SemVer tag (`vX.Y.Z`) on `master`.
The release workflow checks out that exact tag, verifies that `HEAD` resolves
to the same commit, and requires the CMake project version, viewer package
version and runtime `__version__` to match the tag before it builds anything.

The workflow produces x86/x64 proxy ZIP files, an x64 viewer ZIP, source ZIP,
CycloneDX and SPDX SBOMs plus `SHA256SUMS`. Each binary archive carries the GPL license,
upstream MIT notice, third-party notices, and bilingual README files so manual
redistribution retains the required licensing and safety guidance. GitHub build
provenance attests the generated files. Releases remain `UNSIGNED EXPERIMENTAL`; the checksums and attestation
provide integrity/provenance evidence but are not an Authenticode signature.
The body is rendered from `.github/release-notes.md` with the tag substituted
for `{{TAG}}`, so rerunning a release workflow does not discard the safety and
verification guidance.

To reproduce a release from a clean clone:

```powershell
git checkout vX.Y.Z
.github/scripts/verify-release-ref.ps1
.github/scripts/package-release.ps1
```

Set `RELEASE_TAG=vX.Y.Z` before invoking the scripts locally. The packaging
script removes only the repository-local ignored `release/` directory before
recreating it, preventing a previous local asset from being included. It also
uses a clean DLL search path for PyInstaller and starts the packaged viewer in
offscreen mode before archiving it; a Viewer that exits during this smoke check
cannot be published.
The packaging script also inspects each ZIP and fails if the binary, GPL/MIT
notices, third-party notice, or bilingual README entries are missing.
Before any build or upload, the release job runs the pinned gitleaks scanner
against the complete checked-out Git history (`--all`) and the SPDX header
audit. A finding therefore blocks publication even if the branch `Security
analysis` workflow is still running in parallel.
The security workflow additionally runs
`.github/scripts/check-license-headers.ps1`, which checks every tracked
implementation/build file for an SPDX marker and verifies that the inherited
wrapper files remain MIT while project-authored files remain GPL-3.0-only.

The `Security analysis` workflow is a release prerequisite: its CodeQL and
dependency jobs run alongside a full-history gitleaks scan and pinned
actionlint/zizmor workflow audits. The scanner versions are pinned in
`.github/workflows/security.yml` so a future tool update is an explicit review
change rather than an implicit floating dependency.

The public `master` branch is protected by the active `master-protection`
ruleset. Changes must arrive through a pull request, cannot delete or
force-update the branch, and must pass the eight CI/Security job checks
(`proxy-x64`, `proxy-x86`, `viewer-py3.12`, `viewer-py3.13`, `codeql-cpp`,
`codeql-python`, `dependency-audit` and `history-and-workflow-audit`). The
additional `simhub-core-net48` CI job builds the detector and secure-pipe tests
without proprietary SDK assemblies and validates both Dash Studio packages.

The installable SimHub adapter is compiled locally against the SDK in an
installed SimHub copy by `simhub/tools/Build-SimHubPackage.ps1`. That package
contains only project-owned DLLs and dashboards; SimHub assemblies are never
vendored or redistributed. Public release automation must not substitute a
fake SDK reference assembly for the installable binary.
