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
manager_source = (source / 'AXWindowManager.swift').read_text()
main_methods = []
for name in ['recordMainInterfaceActivation', 'handleMainInterfaceShortcut', 'handleAppActivation', 'handleGlobalKeyDown']:
    matches = list(re.finditer(r'    private func ' + name + r'\(.*?\n    }', manager_source, re.S))
    if len(matches) != 1:
        sys.exit(f'Expected exactly one production manager method: {name}')
    main_methods.append(matches[0].group())
fixture = (repo / 'Tests/TemporaryStashHarness.swift.txt').read_text()
fixture = fixture.replace('__MAIN_INTERFACE_METHODS__', '\n\n'.join(main_methods))
fixture += '\n' + (source / 'TemporaryStashRecovery.swift').read_text().replace('Foundation.UserDefaults', 'TestHiddenDefaults')
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
for name in ['snappedScreenIsStale', 'reseatTemporaryShortcutGeometry', 'startTemporaryShortcutStash', 'cancelTemporaryShortcutStash', 'restoreTemporaryShortcutWindow',
             'finishTemporaryShortcutSession', 'beginTemporaryStashReveal', 'hideForTemporaryStashTab', 'revealForTemporaryStashTab', 'focusForTemporaryStashTab',
             'restoreAndDestroy', 'handleDestroyed', 'handleMouseUp', 'suspendForAccessibilityLoss', 'isDetachedFromManagedEdge',
             'relinquishToDockMinimizeIfDetachedFromEdge', 'prepareTemporaryShortcutFrame', 'edgeGeometry', 'getWindowFrame',
             'canRevealForTemporaryAppActivation', 'temporaryActivationFocusIsOutside', 'cancelTemporaryActivationReveal', 'beginTargetedActivationWindow',
             'shouldIgnoreTemporaryAppActivation', 'hideForTemporaryAppActivation',
             'setWindowPosition', 'setWindowPositionWithoutSystemAnimation',
             'refreshTemporaryStashSpaces', 'temporaryStashTabDescriptor', 'temporaryStashRecoveryRecord', 'clampFrameYToBounds', 'isWindowOnScreen', 'animateWindowPositionFast']:
    matches = list(re.finditer(r'(?:    @discardableResult\n)?    (?:private )?(?:static )?func ' + name + r'\(.*?\n    }', session_source, re.S))
    if len(matches) != 1:
        sys.exit(f'Expected exactly one production method: {name}')
    methods.append(matches[0].group().replace('[WindowSession]', '[Session]'))
state = re.search(r'enum SnapState:.*?\n}', session_source, re.S).group()
session_fixture = (repo / 'Tests/TemporaryStashSessionHarness.swift.txt').read_text()
session_fixture = session_fixture.replace('__SNAP_STATE__', state).replace('__METHODS__', '\n\n'.join(methods))
space_source = (source / 'TemporaryStashAppVisibility.swift').read_text()
space_parser = re.search(r'    static func activeSpaces\(in .*?\n    }', space_source, re.S).group()
session_fixture = session_fixture.replace('__SPACE_PARSER__', space_parser)
descriptor = coordinator[coordinator.index('struct TemporaryStashTabDescriptor'):coordinator.index('enum TemporaryStashTabEvent')]
session_fixture += '\n' + descriptor.replace('WindowSession', 'Session')
session_fixture += '\n' + (source / 'TemporaryStashRecovery.swift').read_text().replace('Foundation.UserDefaults', 'TestHiddenDefaults')
session_fixture += '\n' + (source / 'TemporaryStashLogic.swift').read_text()
visibility_source = (source / 'TemporaryStashAppVisibility.swift').read_text()
visibility_class = visibility_source[visibility_source.index('final class TemporaryStashAppVisibility'):]
session_fixture += '\n' + visibility_class.replace('WindowSession', 'Session').replace('CGWindowListCopyWindowInfo', 'testCGWindowListCopyWindowInfo').replace('TemporaryStashHiddenAppStore()', 'TemporaryStashHiddenAppStore(defaults: testHiddenDefaults)')
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
             'restoreTemporaryShortcuts', 'temporaryRecoveryWindows', 'isTemporaryRecoveryCandidate',
             'restoreTemporaryShortcut', 'primaryTemporaryRecoveryCandidate', 'temporaryRecoveryFrame',
             'pendingTemporaryReplacement', 'markTemporaryRecoveryWaiting', 'resolveClosedTemporaryRecovery', 'claimTemporarySlot', 'handleTemporarySlotsChanged',
             'retainTemporaryRecoveryAfterTermination', 'handleTemporaryShortcut', 'handleTemporaryShortcutSessionEnded']:
    matches = list(re.finditer(r'    private func ' + name + r'\(.*?\n    }', manager_source, re.S))
    if len(matches) != 1:
        sys.exit(f'Expected exactly one production manager method: {name}')
    manager_methods.append(matches[0].group().replace('WindowSession', 'Session').replace('AXUIElementCreateApplication', 'testApplicationElement'))
# The cancelled topology-reroute direction must not return through screen notifications.
assert not re.search(r'reroute|topologyAware|appendRelocated', manager_source + session_source, re.I)
assert 'nearestEdge' not in (source / 'TemporaryStashLogic.swift').read_text()
assert 'insertionIndex' not in coordinator and 'recoveryRanks' not in coordinator
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
if result.returncode:
    sys.exit(result.returncode)

# Exercise the production visibility coordinator and session/recovery entry points.
visibility_fixture = session_base + '\n' + recovery_harness
rescue_source = (source / 'WindowRescueManager.swift').read_text()
rescue_methods = []
for name in ['recoverOwnedApplications', 'candidatePIDs']:
    match = re.search(r'    (?:private )?func ' + name + r'\(.*?\n    }', rescue_source, re.S)
    if match is None:
        sys.exit(f'Missing production rescue method: {name}')
    rescue_methods.append(match.group().replace('AXUIElementCreateApplication', 'testApplicationElement'))
rescue_fixture = (repo / 'Tests/TemporaryStashRescueHarness.swift.txt').read_text()
rescue_fixture = rescue_fixture.replace('__RESCUE_METHODS__', '\n\n'.join(rescue_methods))
visibility_fixture += '\n' + rescue_fixture
# Exercise the real hide-before-reveal switch transaction with real session and
# visibility logic, including reentrant state notifications from the old window.
switch_method = re.search(r'    private func activate\(.*?\n    }', coordinator, re.S).group()
switch_method = switch_method.replace('private func activate', 'func activate')
visibility_fixture += '\nfinal class LiveSwitchCoordinator {\n'
visibility_fixture += '    func rememberExpansion(of session: Session) {}\n' + switch_method + '\n}\n'
visibility_fixture += '\n' + (repo / 'Tests/TemporaryStashAppVisibilityTests.swift.txt').read_text()
visibility_output = output / 'app-visibility'
visibility_output.mkdir(exist_ok=True)
(visibility_output / 'main.swift').write_text(visibility_fixture)
compiled = subprocess.run(['swiftc', str(visibility_output / 'main.swift'), '-framework', 'ApplicationServices',
                           '-o', str(visibility_output / 'tests')], capture_output=True, text=True)
(visibility_output / 'compile.log').write_text(compiled.stdout + compiled.stderr)
if compiled.returncode:
    print(compiled.stdout + compiled.stderr, file=sys.stderr)
    sys.exit(compiled.returncode)
result = subprocess.run([str(visibility_output / 'tests')], capture_output=True, text=True)
(visibility_output / 'tests.log').write_text(result.stdout + result.stderr)
print(result.stdout, end='')
print(result.stderr, end='', file=sys.stderr)
if result.returncode:
    sys.exit(result.returncode)

# Compile all of AppConfig; use an in-memory preference backend, never user defaults.
config_source = (source / 'AppConfig.swift').read_text()
config_source = config_source.replace('UserDefaults', 'MemoryDefaults').replace('private init()', 'init()')
settings_source = (source / 'SettingsView.swift').read_text()
conflicts = settings_source[settings_source.index('private let temporaryShortcutRecorderID'):settings_source.index('struct TemporaryShortcutRowView:')]
settings_fixture = (repo / 'Tests/MainInterfaceSettingsTests.swift.txt').read_text()
settings_fixture = settings_fixture.replace('__APP_CONFIG__', config_source).replace('__SHORTCUT_CONFLICTS__', conflicts)
settings_output = output / 'settings'
settings_output.mkdir(exist_ok=True)
(settings_output / 'main.swift').write_text(settings_fixture)
compiled = subprocess.run(['swiftc', str(settings_output / 'main.swift'), '-framework', 'AppKit',
                           '-o', str(settings_output / 'tests')], capture_output=True, text=True)
(settings_output / 'compile.log').write_text(compiled.stdout + compiled.stderr)
if compiled.returncode:
    print(compiled.stdout + compiled.stderr, file=sys.stderr)
    sys.exit(compiled.returncode)
result = subprocess.run([str(settings_output / 'tests')], capture_output=True, text=True)
(settings_output / 'tests.log').write_text(result.stdout + result.stderr)
print(result.stdout, end='')
print(result.stderr, end='', file=sys.stderr)
sys.exit(result.returncode)
