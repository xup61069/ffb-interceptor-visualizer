# SPDX-License-Identifier: GPL-3.0-only
"""Generate deterministic CycloneDX 1.6 and SPDX 2.3 component SBOMs."""

from __future__ import annotations

import argparse
import json
import re
import tomllib
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import quote

REPOSITORY_URL = "https://github.com/xup61069/ffb-interceptor-visualizer"
FIXED_CREATED = "1970-01-01T00:00:00Z"
TOOL_NAME = "ffb-interceptor-component-sbom"
TOOL_VERSION = "1"


def _normalise_name(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()


def _slug(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9.-]+", "-", value).strip("-") or "unknown"


def _generic_purl(name: str, version: str) -> str:
    return f"pkg:generic/{quote(name, safe='.-_')}@{quote(version, safe='.-_+')}"


def _pypi_purl(name: str, version: str) -> str:
    return f"pkg:pypi/{quote(_normalise_name(name), safe='.-_')}@{quote(version, safe='.-_+')}"


def _read_version(root: Path) -> str:
    versions: dict[str, str] = {}
    cmake = (root / "CMakeLists.txt").read_text(encoding="utf-8")
    match = re.search(
        r"project\(ffb_interceptor\s+VERSION\s+([0-9]+\.[0-9]+\.[0-9]+)\s+LANGUAGES\s+CXX\)",
        cmake,
    )
    if not match:
        raise ValueError("CMake project version is missing")
    versions["CMakeLists.txt"] = match.group(1)

    with (root / "viewer" / "pyproject.toml").open("rb") as stream:
        versions["viewer/pyproject.toml"] = str(tomllib.load(stream)["project"]["version"])
    package_init = (root / "viewer" / "src" / "ffb_visualizer" / "__init__.py").read_text(
        encoding="utf-8"
    )
    match = re.search(r'^__version__\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"\s*$', package_init, re.M)
    if not match:
        raise ValueError("Viewer runtime version is missing")
    versions["viewer runtime"] = match.group(1)

    project_paths = (
        root / "simhub" / "FFBInterceptor.Core" / "FFBInterceptor.Core.csproj",
        root / "simhub" / "FFBInterceptor.SimHub" / "FFBInterceptor.SimHub.csproj",
    )
    for project_path in project_paths:
        nodes = ET.parse(project_path).getroot().findall(".//Version")
        if len(nodes) != 1 or not nodes[0].text:
            raise ValueError(f"C# project version is missing: {project_path}")
        versions[str(project_path.relative_to(root))] = nodes[0].text.strip()

    distinct = set(versions.values())
    if len(distinct) != 1:
        detail = ", ".join(f"{path}={value}" for path, value in sorted(versions.items()))
        raise ValueError(f"Project versions disagree: {detail}")
    version = distinct.pop()
    if not re.fullmatch(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)", version):
        raise ValueError(f"Project version is not stable SemVer: {version}")
    return version


def _first_party(version: str) -> list[dict[str, object]]:
    rows = (
        ("ffb-interceptor-proxy", "library", "DirectInput8 proxy and command telemetry"),
        ("ffb-interceptor-hook", "library", "Child-process DirectInput8 import hook"),
        ("ffb-interceptor-launcher", "application", "No-game-DLL launcher"),
        ("ffb-interceptor-manager", "application", "One-click profile and package manager"),
        ("ffb-interceptor-core", "library", "Clipping detection and secure pipe core"),
        ("ffb-interceptor-simhub", "application", "SimHub property adapter"),
        ("ffb-interceptor-dashboards", "data", "SimHub dashboard and overlay assets"),
        ("ffb-interceptor-viewer", "application", "Standalone command visualizer"),
    )
    result = []
    for name, component_type, description in rows:
        purl = _generic_purl(name, version)
        result.append(
            {
                "type": component_type,
                "bom-ref": purl,
                "name": name,
                "version": version,
                "description": description,
                "purl": purl,
                "licenses": [{"license": {"id": "GPL-3.0-only"}}],
                "properties": [{"name": "ffb:component-scope", "value": "first-party"}],
            }
        )
    return result


def _python_components(root: Path, project_version: str) -> tuple[list[dict[str, object]], dict[str, list[str]]]:
    with (root / "viewer" / "uv.lock").open("rb") as stream:
        lock = tomllib.load(stream)
    packages = list(lock.get("package", ()))
    viewer_rows = [row for row in packages if _normalise_name(str(row.get("name", ""))) == "ffb-interceptor-viewer"]
    if len(viewer_rows) != 1 or str(viewer_rows[0].get("version", "")) != project_version:
        raise ValueError("uv.lock editable viewer version does not match the project")

    registry_rows = [row for row in packages if "registry" in row.get("source", {})]
    refs_by_name: dict[str, list[tuple[str, str]]] = {}
    components: list[dict[str, object]] = []
    for row in registry_rows:
        name = str(row["name"])
        version = str(row["version"])
        ref = _pypi_purl(name, version)
        refs_by_name.setdefault(_normalise_name(name), []).append((version, ref))
        components.append(
            {
                "type": "library",
                "bom-ref": ref,
                "name": name,
                "version": version,
                "purl": ref,
                "properties": [
                    {"name": "ffb:component-scope", "value": "locked-python-environment"},
                    {"name": "ffb:source-registry", "value": str(row["source"]["registry"])},
                ],
            }
        )

    dependencies: dict[str, list[str]] = {}

    def resolve(items: list[dict[str, object]]) -> list[str]:
        resolved: set[str] = set()
        for item in items:
            candidates = refs_by_name.get(_normalise_name(str(item.get("name", ""))), [])
            requested_version = str(item.get("version", ""))
            if requested_version:
                candidates = [candidate for candidate in candidates if candidate[0] == requested_version]
            for _, candidate_ref in candidates:
                resolved.add(candidate_ref)
        return sorted(resolved)

    viewer_ref = _generic_purl("ffb-interceptor-viewer", project_version)
    viewer_dependencies = list(viewer_rows[0].get("dependencies", ()))
    for optional_rows in viewer_rows[0].get("optional-dependencies", {}).values():
        viewer_dependencies.extend(optional_rows)
    dependencies[viewer_ref] = resolve(viewer_dependencies)
    for row in registry_rows:
        source_ref = _pypi_purl(str(row["name"]), str(row["version"]))
        items = list(row.get("dependencies", ()))
        for optional_rows in row.get("optional-dependencies", {}).values():
            items.extend(optional_rows)
        dependencies[source_ref] = resolve(items)
    return sorted(components, key=lambda item: str(item["bom-ref"])), dependencies


def _simhub_sdk(root: Path) -> list[dict[str, object]]:
    document = json.loads((root / "simhub" / "sdk-compatibility.json").read_text(encoding="utf-8"))
    profiles = list(document.get("profiles", ()))
    if not profiles:
        raise ValueError("No SimHub SDK compatibility profiles were found")
    components = []
    for profile in profiles:
        version = str(profile["simHubVersion"])
        properties = [
            {"name": "ffb:component-scope", "value": "build-time-only"},
            {"name": "ffb:redistributed", "value": "false"},
            {"name": "ffb:fingerprint-policy", "value": "exact-length-and-sha256"},
        ]
        for file_row in sorted(profile.get("files", ()), key=lambda item: str(item["name"])):
            name = str(file_row["name"])
            digest = str(file_row["sha256"]).upper()
            if not re.fullmatch(r"[A-F0-9]{64}", digest):
                raise ValueError(f"Invalid SimHub SDK fingerprint: {name}")
            properties.extend(
                (
                    {"name": f"ffb:sdk-file:{name}:length", "value": str(file_row["length"])},
                    {"name": f"ffb:sdk-file:{name}:sha256", "value": digest},
                )
            )
        ref = _generic_purl("simhub-sdk", version)
        components.append(
            {
                "type": "framework",
                "bom-ref": ref,
                "name": "SimHub SDK",
                "version": version,
                "description": "External proprietary build-time API; verified locally and never redistributed.",
                "purl": ref,
                "properties": properties,
            }
        )
    return components


def build_documents(root: Path) -> tuple[dict[str, object], dict[str, object]]:
    root = root.resolve()
    version = _read_version(root)
    suite_ref = _generic_purl("ffb-interceptor", version)
    first_party = _first_party(version)
    python_components, dependency_map = _python_components(root, version)
    sdk_components = _simhub_sdk(root)
    components = sorted(first_party + python_components + sdk_components, key=lambda item: str(item["bom-ref"]))

    refs = {str(component["name"]): str(component["bom-ref"]) for component in components}
    dependency_map[suite_ref] = sorted(str(component["bom-ref"]) for component in first_party)
    dependency_map[refs["ffb-interceptor-launcher"]] = [refs["ffb-interceptor-hook"]]
    dependency_map[refs["ffb-interceptor-manager"]] = sorted(
        refs[name]
        for name in ("ffb-interceptor-launcher", "ffb-interceptor-hook", "ffb-interceptor-core", "ffb-interceptor-simhub")
    )
    sdk_refs = sorted(str(component["bom-ref"]) for component in sdk_components)
    dependency_map[refs["ffb-interceptor-simhub"]] = [refs["ffb-interceptor-core"], *sdk_refs]
    dependency_map[refs["ffb-interceptor-dashboards"]] = [refs["ffb-interceptor-simhub"]]
    for component in components:
        dependency_map.setdefault(str(component["bom-ref"]), [])

    serial = uuid.uuid5(uuid.NAMESPACE_URL, f"{REPOSITORY_URL}/component-sbom/{version}")
    cyclonedx = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": f"urn:uuid:{serial}",
        "version": 1,
        "metadata": {
            "tools": {"components": [{"type": "application", "name": TOOL_NAME, "version": TOOL_VERSION}]},
            "component": {
                "type": "application",
                "bom-ref": suite_ref,
                "name": "FFB Interceptor",
                "version": version,
                "purl": suite_ref,
                "licenses": [{"license": {"id": "GPL-3.0-only"}}],
            },
        },
        "components": components,
        "dependencies": [
            {"ref": source, "dependsOn": sorted(set(targets))}
            for source, targets in sorted(dependency_map.items())
        ],
    }

    all_spdx_components = [cyclonedx["metadata"]["component"], *components]
    spdx_id_by_ref: dict[str, str] = {}
    spdx_packages = []
    for component in all_spdx_components:
        ref = str(component["bom-ref"])
        spdx_id = "SPDXRef-Package-" + _slug(f"{component['name']}-{component['version']}")
        if spdx_id in spdx_id_by_ref.values():
            raise ValueError(f"Duplicate SPDX identifier: {spdx_id}")
        spdx_id_by_ref[ref] = spdx_id
        first_party_component = any(
            prop.get("name") == "ffb:component-scope" and prop.get("value") == "first-party"
            for prop in component.get("properties", ())
        ) or ref == suite_ref
        spdx_packages.append(
            {
                "SPDXID": spdx_id,
                "name": component["name"],
                "versionInfo": component["version"],
                "downloadLocation": "NOASSERTION",
                "filesAnalyzed": False,
                "licenseConcluded": "GPL-3.0-only" if first_party_component else "NOASSERTION",
                "licenseDeclared": "GPL-3.0-only" if first_party_component else "NOASSERTION",
                "copyrightText": "NOASSERTION",
                "externalRefs": [
                    {
                        "referenceCategory": "PACKAGE-MANAGER",
                        "referenceType": "purl",
                        "referenceLocator": ref,
                    }
                ],
                "comment": str(component.get("description", "")),
            }
        )
    relationships = []
    for source, targets in sorted(dependency_map.items()):
        for target in sorted(set(targets)):
            relationships.append(
                {
                    "spdxElementId": spdx_id_by_ref[source],
                    "relationshipType": "DEPENDS_ON",
                    "relatedSpdxElement": spdx_id_by_ref[target],
                }
            )
    spdx = {
        "spdxVersion": "SPDX-2.3",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"FFB Interceptor {version} component SBOM",
        "dataLicense": "CC0-1.0",
        "documentNamespace": f"{REPOSITORY_URL}/spdx/components-{version}",
        "creationInfo": {"created": FIXED_CREATED, "creators": [f"Tool: {TOOL_NAME}-{TOOL_VERSION}"]},
        "documentDescribes": [spdx_id_by_ref[suite_ref]],
        "packages": sorted(spdx_packages, key=lambda item: str(item["SPDXID"])),
        "relationships": relationships,
    }
    return cyclonedx, spdx


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--cyclonedx", type=Path, required=True)
    parser.add_argument("--spdx", type=Path, required=True)
    args = parser.parse_args()
    cyclonedx, spdx = build_documents(args.root)
    for path, document in ((args.cyclonedx, cyclonedx), (args.spdx, spdx)):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Wrote component SBOMs with {len(cyclonedx['components'])} components")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
