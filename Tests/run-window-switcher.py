#!/usr/bin/env python3
"""Compile the production switcher value logic; no AX, UI, or user preferences."""
from pathlib import Path
import re
import subprocess
import sys

repo = Path(__file__).resolve().parents[1]
output = repo / "build/tests/window-switcher"
output.mkdir(parents=True, exist_ok=True)
fixture = (repo / "Sources/SideBar/WindowSwitcherLogic.swift").read_text()
controller = (repo / "Sources/SideBar/WindowSwitcherController.swift").read_text()
methods = []
for declaration in ["@objc private func clickedRow", "private func confirm(row: Int)"]:
    matches = list(re.finditer(r"    " + re.escape(declaration) + r".*?\n    }", controller, re.S))
    if len(matches) != 1:
        sys.exit(f"Expected one production action method: {declaration}")
    methods.append(matches[0].group())
fixture += "\n" + (repo / "Tests/WindowSwitcherActionHarness.swift.txt").read_text().replace(
    "__ACTION_METHODS__", "\n".join(methods))
fixture += "\n" + (repo / "Tests/WindowSwitcherTests.swift.txt").read_text()
(output / "main.swift").write_text(fixture)
commands = [
    ("compile", ["swiftc", str(output / "main.swift"), "-o", str(output / "tests")]),
    ("tests", [str(output / "tests")]),
]
for name, command in commands:
    result = subprocess.run(command, capture_output=True, text=True)
    (output / f"{name}.log").write_text(result.stdout + result.stderr)
    print(result.stdout, end="")
    print(result.stderr, end="", file=sys.stderr)
    if result.returncode:
        sys.exit(result.returncode)
