# SPDX-License-Identifier: GPL-3.0-only
"""Run Qt widget tests without depending on an interactive desktop session."""

from __future__ import annotations

import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
