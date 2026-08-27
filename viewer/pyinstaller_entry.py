# SPDX-License-Identifier: GPL-3.0-only
"""PyInstaller entry point that preserves the viewer package context."""

from ffb_visualizer.main import run

if __name__ == "__main__":
    raise SystemExit(run())
