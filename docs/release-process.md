# Release process

Every public release is an existing stable SemVer tag (`vX.Y.Z`) on `master`.
The release workflow checks out that exact tag, verifies that `HEAD` resolves
to the same commit, and requires the CMake project version and viewer package
version to match the tag before it builds anything.

The workflow produces x86/x64 proxy ZIP files, an x64 viewer ZIP, source ZIP,
CycloneDX SBOM and `SHA256SUMS`. GitHub build provenance attests the generated
files. Releases remain `UNSIGNED EXPERIMENTAL`; the checksums and attestation
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

The `Security analysis` workflow is a release prerequisite: its CodeQL and
dependency jobs run alongside a full-history gitleaks scan and pinned
actionlint/zizmor workflow audits. The scanner versions are pinned in
`.github/workflows/security.yml` so a future tool update is an explicit review
change rather than an implicit floating dependency.
