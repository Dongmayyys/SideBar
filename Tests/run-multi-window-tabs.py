#!/usr/bin/env python3
"""Compile production pure logic and tab coordinator with an in-memory UI/AX backend."""
from pathlib import Path
import re
import subprocess
import sys

repo = Path(__file__).resolve().parents[1]
source = repo / 'Sources/SideBar'
coordinator = (source / 'TemporaryStashTabController.swift').read_text()
coordinator = coordinator.split('private final class TemporaryStashTabWindow:')[0]
coordinator = coordinator.replace('import AppKit', 'import Foundation')
fixture = (repo / 'Tests/TemporaryStashHarness.swift.txt').read_text()
fixture += '\n' + (source / 'TemporaryStashRecovery.swift').read_text()
fixture += '\n' + (source / 'TemporaryStashLogic.swift').read_text() + '\n' + coordinator
fixture += '\n' + (repo / 'Tests/TemporaryStashTests.swift.txt').read_text()
output = repo / 'build/tests/multi-window-tabs'
output.mkdir(parents=True, exist_ok=True)
(output / 'main.swift').write_text(fixture)
compiled = subprocess.run(['swiftc', str(output / 'main.swift'), '-o', str(output / 'tests')], capture_output=True, text=True)
(output / 'compile.log').write_text(compiled.stdout + compiled.stderr)
if compiled.returncode:
    print(compiled.stdout + compiled.stderr, file=sys.stderr)
    sys.exit(compiled.returncode)
result = subprocess.run([str(output / 'tests')], capture_output=True, text=True)
(output / 'tests.log').write_text(result.stdout + result.stderr)
print(result.stdout, end='')
print(result.stderr, end='', file=sys.stderr)
if result.returncode:
    sys.exit(result.returncode)

session_source = (source / 'WindowSession.swift').read_text()
methods = []
for name in ['startTemporaryShortcutStash', 'cancelTemporaryShortcutStash', 'restoreTemporaryShortcutWindow',
             'finishTemporaryShortcutSession', 'hideForTemporaryStashTab', 'revealForTemporaryStashTab',
             'restoreAndDestroy', 'handleDestroyed', 'handleMouseUp', 'isDetachedFromManagedEdge',
             'canRevealForTemporaryAppActivation', 'beginTargetedActivationWindow',
             'shouldIgnoreTemporaryAppActivation', 'hideForTemporaryAppActivation',
             'setWindowPosition', 'setWindowPositionWithoutSystemAnimation',
             'temporaryStashTabDescriptor', 'temporaryStashRecoveryRecord', 'clampFrameYToBounds', 'isWindowOnScreen', 'animateWindowPositionFast']:
    matches = list(re.finditer(r'(?:    @discardableResult\n)?    (?:private )?(?:static )?func ' + name + r'\(.*?\n    }', session_source, re.S))
    if len(matches) != 1:
        sys.exit(f'Expected exactly one production method: {name}')
    methods.append(matches[0].group())
state = re.search(r'enum SnapState:.*?\n}', session_source, re.S).group()
session_fixture = (repo / 'Tests/TemporaryStashSessionHarness.swift.txt').read_text()
session_fixture = session_fixture.replace('__SNAP_STATE__', state).replace('__METHODS__', '\n\n'.join(methods))
descriptor = coordinator[coordinator.index('struct TemporaryStashTabDescriptor'):coordinator.index('enum TemporaryStashTabEvent')]
session_fixture += '\n' + descriptor.replace('WindowSession', 'Session')
session_fixture += '\n' + (source / 'TemporaryStashRecovery.swift').read_text()
session_fixture += '\n' + (source / 'TemporaryStashLogic.swift').read_text()
session_base = session_fixture
session_fixture += '\n' + (repo / 'Tests/TemporaryStashSessionTests.swift.txt').read_text()
# Top-level Swift statements require a main.swift when compiling an executable.
session_output = output / 'sessions'
session_output.mkdir(exist_ok=True)
(session_output / 'main.swift').write_text(session_fixture)
compiled = subprocess.run(['swiftc', str(session_output / 'main.swift'), '-framework', 'ApplicationServices',
                           '-o', str(session_output / 'tests')], capture_output=True, text=True)
(session_output / 'compile.log').write_text(compiled.stdout + compiled.stderr)
if compiled.returncode:
    print(compiled.stdout + compiled.stderr, file=sys.stderr)
    sys.exit(compiled.returncode)
result = subprocess.run([str(session_output / 'tests')], capture_output=True, text=True)
(session_output / 'tests.log').write_text(result.stdout + result.stderr)
print(result.stdout, end='')
print(result.stderr, end='', file=sys.stderr)
if result.returncode:
    sys.exit(result.returncode)

manager_source = (source / 'AXWindowManager.swift').read_text()
manager_methods = []
for name in ['persistTemporaryRecovery', 'stopTemporaryRecovery', 'discardPendingTemporaryRecovery',
             'restoreTemporaryShortcuts', 'findTemporaryRecoveryWindow', 'handleTemporaryShortcutSessionEnded']:
    matches = list(re.finditer(r'    private func ' + name + r'\(.*?\n    }', manager_source, re.S))
    if len(matches) != 1:
        sys.exit(f'Expected exactly one production manager method: {name}')
    manager_methods.append(matches[0].group().replace('WindowSession', 'Session').replace('AXUIElementCreateApplication', 'testApplicationElement'))
recovery_harness = (repo / 'Tests/TemporaryStashRecoveryHarness.swift.txt').read_text()
recovery_harness = recovery_harness.replace('__MANAGER_METHODS__', '\n\n'.join(manager_methods))
recovery_fixture = session_base + '\n' + recovery_harness
recovery_fixture += '\n' + (repo / 'Tests/TemporaryStashRecoveryTests.swift.txt').read_text()
recovery_output = output / 'recovery'
recovery_output.mkdir(exist_ok=True)
(recovery_output / 'main.swift').write_text(recovery_fixture)
compiled = subprocess.run(['swiftc', str(recovery_output / 'main.swift'), '-framework', 'ApplicationServices',
                           '-o', str(recovery_output / 'tests')], capture_output=True, text=True)
(recovery_output / 'compile.log').write_text(compiled.stdout + compiled.stderr)
if compiled.returncode:
    print(compiled.stdout + compiled.stderr, file=sys.stderr)
    sys.exit(compiled.returncode)
result = subprocess.run([str(recovery_output / 'tests')], capture_output=True, text=True)
(recovery_output / 'tests.log').write_text(result.stdout + result.stderr)
print(result.stdout, end='')
print(result.stderr, end='', file=sys.stderr)
sys.exit(result.returncode)
