# SPDX-License-Identifier: GPL-3.0-only
"""Generate a deterministic SPDX 2.3 document for the installed Python environment."""

from __future__ import annotations

import argparse
import importlib.metadata
import json
import re
import tomllib
from pathlib import Path
from urllib.parse import quote

_TOOL_NAME = "ffb-interceptor-spdx-sbom"
_TOOL_VERSION = "1"
_FIXED_CREATED = "1970-01-01T00:00:00Z"


def _normalise_name(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()


def _slug(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9.-]+", "-", value).strip("-") or "unknown"


def _package_id(name: str, version: str) -> str:
    return f"SPDXRef-Package-{_slug(_normalise_name(name))}-{_slug(version)}"


def _purl(name: str, version: str) -> str:
    return f"pkg:pypi/{quote(_normalise_name(name), safe='.-_')}@{quote(version, safe='.-_+')}"


def _requirement_name(requirement: str) -> str | None:
    match = re.match(r"\s*([A-Za-z0-9][A-Za-z0-9_.-]*)", requirement)
    return _normalise_name(match.group(1)) if match else None


def _installed_distributions() -> dict[tuple[str, str], importlib.metadata.Distribution]:
    distributions: dict[tuple[str, str], importlib.metadata.Distribution] = {}
    for distribution in importlib.metadata.distributions():
        name = distribution.metadata.get("Name")
        version = distribution.metadata.get("Version")
        if not name or not version:
            continue
        distributions.setdefault((_normalise_name(name), version), distribution)
    return distributions


def build_document(pyproject_path: Path, namespace: str | None = None) -> dict[str, object]:
    with pyproject_path.open("rb") as stream:
        project = tomllib.load(stream)["project"]
    project_name = str(project["name"])
    project_version = str(project["version"])
    distributions = _installed_distributions()
    root_key = (_normalise_name(project_name), project_version)

    # uv installs the editable root package. Keep a metadata-only fallback so
    # local generation remains useful even when the caller skipped uv sync.
    package_rows: dict[tuple[str, str], dict[str, object]] = {}
    requirements: dict[tuple[str, str], list[str]] = {}
    for key, distribution in distributions.items():
        name, version = key
        package_rows[key] = {
            "SPDXID": _package_id(name, version),
            "name": distribution.metadata.get("Name", name),
            "versionInfo": version,
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "copyrightText": "NOASSERTION",
            "externalRefs": [
                {
                    "referenceCategory": "PACKAGE-MANAGER",
                    "referenceType": "purl",
                    "referenceLocator": _purl(name, version),
                }
            ],
        }
        requirements[key] = list(distribution.requires or ())

    if root_key not in package_rows:
        package_rows[root_key] = {
            "SPDXID": _package_id(project_name, project_version),
            "name": project_name,
            "versionInfo": project_version,
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "copyrightText": "NOASSERTION",
            "externalRefs": [
                {
                    "referenceCategory": "PACKAGE-MANAGER",
                    "referenceType": "purl",
                    "referenceLocator": _purl(project_name, project_version),
                }
            ],
        }
        requirements[root_key] = [str(item) for item in project.get("dependencies", ())]

    packages = [package_rows[key] for key in sorted(package_rows)]
    relationships: list[dict[str, str]] = []
    for key in sorted(requirements):
        source_id = str(package_rows[key]["SPDXID"])
        seen_targets: set[str] = set()
        for requirement in requirements[key]:
            target_name = _requirement_name(requirement)
            if target_name is None:
                continue
            target_keys = [candidate for candidate in package_rows if candidate[0] == target_name]
            for target_key in sorted(target_keys):
                target_id = str(package_rows[target_key]["SPDXID"])
                if target_id == source_id or target_id in seen_targets:
                    continue
                relationships.append(
                    {
                        "spdxElementId": source_id,
                        "relationshipType": "DEPENDS_ON",
                        "relatedSpdxElement": target_id,
                    }
                )
                seen_targets.add(target_id)
                break

    resolved_namespace = namespace or (
        "https://github.com/xup61069/ffb-interceptor-visualizer/spdx/"
        f"{_slug(project_name)}-{_slug(project_version)}"
    )
    package_ids = [str(package["SPDXID"]) for package in packages]
    return {
        "spdxVersion": "SPDX-2.3",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"{project_name} {project_version} Python environment",
        "dataLicense": "CC0-1.0",
        "documentNamespace": resolved_namespace,
        "creationInfo": {
            "created": _FIXED_CREATED,
            "creators": [f"Tool: {_TOOL_NAME}-{_TOOL_VERSION}"],
        },
        "documentDescribes": package_ids,
        "packages": packages,
        "relationships": relationships,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pyproject", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--namespace")
    args = parser.parse_args()
    document = build_document(args.pyproject, args.namespace)
    args.output.write_text(
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"Wrote SPDX 2.3 SBOM with {len(document['packages'])} packages to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
