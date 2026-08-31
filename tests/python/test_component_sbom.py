# SPDX-License-Identifier: GPL-3.0-only
from __future__ import annotations

import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPOSITORY_ROOT / ".github" / "scripts" / "generate-component-sbom.py"
SPEC = importlib.util.spec_from_file_location("generate_component_sbom", SCRIPT_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ComponentSbomTests(unittest.TestCase):
    def test_real_repository_documents_are_deterministic_and_complete(self) -> None:
        first = MODULE.build_documents(REPOSITORY_ROOT)
        second = MODULE.build_documents(REPOSITORY_ROOT)
        self.assertEqual(
            json.dumps(first, ensure_ascii=False, sort_keys=True),
            json.dumps(second, ensure_ascii=False, sort_keys=True),
        )
        cyclonedx, spdx = first
        self.assertEqual(cyclonedx["specVersion"], "1.6")
        self.assertEqual(spdx["spdxVersion"], "SPDX-2.3")
        names = {component["name"] for component in cyclonedx["components"]}
        self.assertTrue(
            {
                "ffb-interceptor-proxy",
                "ffb-interceptor-hook",
                "ffb-interceptor-launcher",
                "ffb-interceptor-manager",
                "ffb-interceptor-core",
                "ffb-interceptor-simhub",
                "ffb-interceptor-viewer",
                "SimHub SDK",
                "numpy",
            }.issubset(names)
        )
        sdk = next(component for component in cyclonedx["components"] if component["name"] == "SimHub SDK")
        properties = {item["name"]: item["value"] for item in sdk["properties"]}
        self.assertEqual(properties["ffb:component-scope"], "build-time-only")
        self.assertEqual(properties["ffb:redistributed"], "false")
        self.assertIn("ffb:sdk-file:SimHub.Plugins.dll:sha256", properties)

    def test_version_mismatch_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ffb-sbom-test-") as temporary:
            fixture = Path(temporary)
            for relative in (
                "CMakeLists.txt",
                "viewer/pyproject.toml",
                "viewer/uv.lock",
                "viewer/src/ffb_visualizer/__init__.py",
                "simhub/FFBInterceptor.Core/FFBInterceptor.Core.csproj",
                "simhub/FFBInterceptor.SimHub/FFBInterceptor.SimHub.csproj",
                "simhub/sdk-compatibility.json",
            ):
                source = REPOSITORY_ROOT / relative
                destination = fixture / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)
            pyproject = fixture / "viewer" / "pyproject.toml"
            current_version = MODULE._read_version(REPOSITORY_ROOT)
            pyproject.write_text(
                pyproject.read_text(encoding="utf-8").replace(
                    f'version = "{current_version}"', 'version = "9.9.9"', 1
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "versions disagree"):
                MODULE.build_documents(fixture)


if __name__ == "__main__":
    unittest.main()
