"""Support the workshop's slash-style unittest invocation."""

from __future__ import annotations

import importlib.abc
import importlib.util
from pathlib import Path
import sys


class _SlashModuleFinder(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path=None, target=None):
        if "/" not in fullname:
            return None

        candidate = Path.cwd() / fullname
        if candidate.is_file():
            return importlib.util.spec_from_file_location(fullname, candidate)

        py_candidate = candidate.with_suffix(".py")
        if py_candidate.is_file():
            return importlib.util.spec_from_file_location(fullname, py_candidate)

        return None


if not any(isinstance(finder, _SlashModuleFinder) for finder in sys.meta_path):
    sys.meta_path.insert(0, _SlashModuleFinder())
