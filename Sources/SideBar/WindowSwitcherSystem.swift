import AppKit
import ApplicationServices
import Carbon
import Darwin

/// Private entry points are optional and confined here. No Space reassignment or hide/unhide calls.
/// Remote-token traversal and window-directed fronting follow AltTab's API wrappers:
/// https://github.com/lwouis/alt-tab-macos/tree/master/src/macos/api-wrappers
private enum WindowSwitcherPrivateAPI {
    typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError
    typealias RemoteElement = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    typealias FrontWindow = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    typealias PostRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    typealias ProcessForPID = @convention(c) (Int32, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
    static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(address, to: type)
    }
    static let copySpaces: CopySpaces? = {
        _ = skyLight
        return symbol("SLSCopySpacesForWindows", as: CopySpaces.self)
    }()
    static let getWindow = symbol("_AXUIElementGetWindow", as: GetWindow.self)
    static let remoteElement = symbol("_AXUIElementCreateWithRemoteToken", as: RemoteElement.self)
    static let processForPID = symbol("GetProcessForPID", as: ProcessForPID.self)
    static let frontWindow: FrontWindow? = {
        _ = skyLight
        return symbol("_SLPSSetFrontProcessWithOptions", as: FrontWindow.self)
    }()
    static let postRecord: PostRecord? = {
        _ = skyLight
        return symbol("SLPSPostEventRecordTo", as: PostRecord.self)
    }()

    static func spaces(_ id: CGWindowID) -> [NSNumber]? {
        copySpaces?(CGSMainConnectionID(), 0x7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber]
    }

    static func makeKey(_ id: CGWindowID, psn: inout ProcessSerialNumber) -> Int32? {
        // Window-directed key event, not a click on screen content. The oversized zeroed buffer
        // is required by newer WindowServer versions; post only DOWN (never a content click pair).
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0x04] = 0xf8
        bytes[0x08] = 0x01
        bytes[0x3a] = 0x10
        var id = id
        var point = CGPoint(x: 300_000, y: 300_000)
        bytes.withUnsafeMutableBytes { buffer in
            memcpy(buffer.baseAddress!.advanced(by: 0x3c), &id, MemoryLayout<CGWindowID>.size)
            memcpy(buffer.baseAddress!.advanced(by: 0x20), &point, MemoryLayout<CGPoint>.size)
        }
        return postRecord?(&psn, &bytes)
    }
}

struct WindowSwitcherInventory {
    var candidates: [WindowSwitcherCandidate] = []
    var fields: [CGWindowID: [WindowSwitcherSearchField]] = [:]
    var liveIDs: Set<CGWindowID> = []
    var isReading = false
    var unavailableReason: String?
}

/// All enumeration and potentially slow AX IPC runs on one background queue, never in the tab timer.
final class WindowSwitcherSystem {
    private let queue = DispatchQueue(label: "SideBar.window-switcher", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    // Accessed only on queue. Retain confirmed roots and resume bounded scans for long-lived apps.
    private var roots: [CGWindowID: AXUIElement] = [:]
    private var cursors: [pid_t: UInt64] = [:]
    private var scanTargets: [pid_t: Set<CGWindowID>] = [:]

    func cancel() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    private func currentGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    static func windowInfo() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    }

    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard WindowSwitcherPrivateAPI.getWindow?(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func focusedID(pid: pid_t) -> CGWindowID? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.025)
        guard let window = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return windowID(window as! AXUIElement)
    }

    func enumerate(deliver: @escaping (WindowSwitcherInventory) -> Void) {
        cancel()
        let request = currentGeneration()
        // Capture NSWorkspace data on main; the worker only uses this immutable inventory.
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        queue.async { [self] in
            guard request == currentGeneration() else { return }
            let budget = WindowSwitcherScanBudget(startedAt: ProcessInfo.processInfo.systemUptime)
            guard let info = Self.windowInfo() else {
                publish(WindowSwitcherInventory(unavailableReason: "CGWindowList 读取失败"), request: request, deliver: deliver)
                return
            }
            var unavailableReason: String?
            if WindowSwitcherPrivateAPI.getWindow == nil { unavailableReason = "_AXUIElementGetWindow 缺失" }
            if WindowSwitcherPrivateAPI.copySpaces == nil { unavailableReason = unavailableReason ?? "SLSCopySpacesForWindows 缺失" }
            let ids = Set(info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
            let owners = Dictionary(uniqueKeysWithValues: info.compactMap { row -> (CGWindowID, pid_t)? in
                guard let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                      let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
                return (id, pid)
            })
            roots = roots.filter { id, window in
                guard budget.hasTime(at: ProcessInfo.processInfo.systemUptime) else { return false }
                AXUIElementSetMessagingTimeout(window, 0.025)
                var pid: pid_t = 0
                return AXUIElementGetPid(window, &pid) == .success && owners[id] == pid && Self.windowID(window) == id
            }
            let pids = Set(apps.map(\.processIdentifier))
            cursors = cursors.filter { pids.contains($0.key) }
            scanTargets = scanTargets.filter { pids.contains($0.key) }
            // First publish AX-advertised and cached roots; then fill in other-Space roots incrementally.
            for app in apps {
                guard request == currentGeneration() else { return }
                guard budget.hasTime(at: ProcessInfo.processInfo.systemUptime) else {
                    unavailableReason = unavailableReason ?? "窗口读取超时：2 秒"
                    break
                }
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(element, 0.025)
                if let windows = Self.attribute(element, kAXWindowsAttribute) as? [AXUIElement] {
                    for window in windows {
                        guard budget.hasTime(at: ProcessInfo.processInfo.systemUptime), request == currentGeneration() else { break }
                        AXUIElementSetMessagingTimeout(window, 0.025)
                        if let id = Self.windowID(window) { roots[id] = window }
                        else { unavailableReason = unavailableReason ?? "_AXUIElementGetWindow 调用失败" }
                    }
                }
            }
            var snapshot = inventory(info: info, apps: apps, budget: budget)
            snapshot.liveIDs = ids
            snapshot.isReading = true
            snapshot.unavailableReason = snapshot.unavailableReason ?? unavailableReason
            publish(snapshot, request: request, deliver: deliver)
            refine(info: info, apps: apps, request: request, budget: budget, snapshot: snapshot, deliver: deliver)
        }
    }

    private func publish(_ snapshot: WindowSwitcherInventory, request: Int,
                         deliver: @escaping (WindowSwitcherInventory) -> Void) {
        DispatchQueue.main.async { [self] in
            if request == currentGeneration() { deliver(snapshot) }
        }
    }

    private func refine(info: [[String: Any]], apps: [NSRunningApplication], request: Int, budget: WindowSwitcherScanBudget,
                        snapshot: WindowSwitcherInventory, deliver: @escaping (WindowSwitcherInventory) -> Void) {
        guard request == currentGeneration() else { return }
        var snapshot = snapshot
        guard budget.hasTime(at: ProcessInfo.processInfo.systemUptime) else {
            snapshot.isReading = false
            snapshot.unavailableReason = snapshot.unavailableReason ?? "跨桌面补查超时：2 秒"
            publish(snapshot, request: request, deliver: deliver)
            return
        }
        var needsContinuation = false
        let byPID = Dictionary(grouping: info, by: { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0 })
        for app in apps {
            guard request == currentGeneration() else { return }
            guard budget.hasTime(at: ProcessInfo.processInfo.systemUptime) else {
                snapshot.unavailableReason = snapshot.unavailableReason ?? "跨桌面补查超时：2 秒"
                needsContinuation = false
                break
            }
            let missing = Set((byPID[app.processIdentifier] ?? []).compactMap { row -> CGWindowID? in
                guard (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                      let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                      roots[id] == nil else { return nil }
                guard let spaces = WindowSwitcherPrivateAPI.spaces(id) else {
                    snapshot.unavailableReason = snapshot.unavailableReason ?? "SLSCopySpacesForWindows 缺失或调用失败"
                    return nil
                }
                return spaces.isEmpty ? nil : id
            })
            guard !missing.isEmpty else { continue }
            guard WindowSwitcherPrivateAPI.getWindow != nil, WindowSwitcherPrivateAPI.remoteElement != nil else {
                snapshot.unavailableReason = snapshot.unavailableReason ?? "跨桌面 AX 私有接口缺失"
                continue
            }
            guard budget.hasTime(at: ProcessInfo.processInfo.systemUptime) else {
                snapshot.unavailableReason = snapshot.unavailableReason ?? "跨桌面补查超时：2 秒"
                needsContinuation = false
                break
            }
            scan(pid: app.processIdentifier, wanted: missing, request: request, budget: budget)
            guard request == currentGeneration() else { return }
            let discovered = missing.filter { roots[$0] != nil }
            needsContinuation = needsContinuation || discovered.count < missing.count
            guard !discovered.isEmpty else { continue }
            let delta = inventory(info: info.filter {
                discovered.contains(($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            }, apps: apps, budget: budget)
            snapshot.candidates += delta.candidates
            snapshot.unavailableReason = snapshot.unavailableReason ?? delta.unavailableReason
            snapshot.fields.merge(delta.fields) { _, new in new }
            let stacking = Dictionary(uniqueKeysWithValues: info.enumerated().compactMap { index, row -> (CGWindowID, Int)? in
                guard let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
                return (id, index)
            })
            snapshot.candidates.sort { (stacking[$0.id] ?? 0) < (stacking[$1.id] ?? 0) }
            publish(snapshot, request: request, deliver: deliver)
        }
        // One shared deadline for every process and continuation; keep the accumulated snapshot.
        if needsContinuation && budget.hasTime(at: ProcessInfo.processInfo.systemUptime) {
            let nextSnapshot = snapshot
            queue.asyncAfter(deadline: .now() + 0.1) { [self] in
                refine(info: info, apps: apps, request: request, budget: budget, snapshot: nextSnapshot, deliver: deliver)
            }
        } else {
            if needsContinuation { snapshot.unavailableReason = snapshot.unavailableReason ?? "跨桌面补查超时：2 秒" }
            snapshot.isReading = false
            publish(snapshot, request: request, deliver: deliver)
        }
    }

    private func inventory(info: [[String: Any]], apps: [NSRunningApplication], budget: WindowSwitcherScanBudget) -> WindowSwitcherInventory {
        let appsByPID = Dictionary(uniqueKeysWithValues: apps.map { ($0.processIdentifier, $0) })
        var result = WindowSwitcherInventory()
        for row in info {
            guard budget.hasTime(at: ProcessInfo.processInfo.systemUptime) else {
                result.unavailableReason = "窗口读取超时：2 秒"
                break
            }
            guard let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let app = appsByPID[pid], (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width.isFinite, frame.height.isFinite, frame.width > 1, frame.height > 1,
                  let window = roots[id], Self.windowID(window) == id else { continue }
            AXUIElementSetMessagingTimeout(window, 0.025)
            var owner: pid_t = 0
            guard AXUIElementGetPid(window, &owner) == .success, owner == pid else { continue }
            guard Self.attribute(window, kAXRoleAttribute) as? String == kAXWindowRole,
                  Self.attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole else { continue }
            let minimized = Self.attribute(window, kAXMinimizedAttribute) as? Bool == true
            let spaces = WindowSwitcherPrivateAPI.spaces(id)
            let hasSpace = spaces?.isEmpty == false
            if spaces == nil { result.unavailableReason = "SLSCopySpacesForWindows 缺失或调用失败" }
            // A genuine AX-minimized window is restorable even on systems reporting no Space for it.
            let publiclyVisible = spaces == nil && (row[kCGWindowIsOnscreen as String] as? Bool == true)
            guard hasSpace || minimized || publiclyVisible else { continue }
            let name = app.localizedName ?? app.bundleIdentifier ?? ""
            let title = Self.attribute(window, kAXTitleAttribute) as? String ?? row[kCGWindowName as String] as? String ?? ""
            var candidate = WindowSwitcherCandidate(id: id, pid: pid, appName: name, title: title)
            candidate.bundleID = app.bundleIdentifier
            candidate.isMinimized = minimized
            candidate.hasSpace = hasSpace || publiclyVisible
            result.candidates.append(candidate)
            result.fields[id] = [WindowSwitcherSearchField(name), WindowSwitcherSearchField(title)]
        }
        return result
    }

    private func scan(pid: pid_t, wanted: Set<CGWindowID>, request: Int, budget: WindowSwitcherScanBudget) {
        guard let create = WindowSwitcherPrivateAPI.remoteElement,
              let data = CFDataCreateMutable(nil, 20) else { return }
        CFDataSetLength(data, 20)
        guard let bytes = CFDataGetMutableBytePtr(data) else { return }
        memset(bytes, 0, 20)
        var pid = pid
        var magic: UInt32 = 0x636f636f
        memcpy(bytes, &pid, 4)
        memcpy(bytes + 8, &magic, 4)
        // A newly requested window may have an AX ID below the old cursor (including process reuse).
        // Continue only for the same remaining targets; a changed target set gets a fresh traversal.
        let previousTargets = scanTargets[pid] ?? []
        var cursor = wanted.isSubset(of: previousTargets) ? (cursors[pid] ?? 0) : 0
        scanTargets[pid] = wanted
        var remaining = wanted
        let deadline = budget.sliceDeadline(at: ProcessInfo.processInfo.systemUptime)
        while !remaining.isEmpty && ProcessInfo.processInfo.systemUptime < deadline && request == currentGeneration() {
            memcpy(bytes + 12, &cursor, 8)
            cursor &+= 1
            guard let window = create(data)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(window, 0.015)
            guard let id = Self.windowID(window), remaining.contains(id),
                  Self.attribute(window, kAXRoleAttribute) as? String == kAXWindowRole else { continue }
            roots[id] = window
            remaining.remove(id)
        }
        // Resume next time; once all targets have been found, a later new window starts a fresh sweep.
        cursors[pid] = remaining.isEmpty ? 0 : cursor
    }

    func reportFocusFailure(id: CGWindowID, pid: pid_t, reason: String) {
        DispatchQueue.main.async {
            StashDebugLog.write("switcher focus failed pid=\(pid) window=\(id) reason=\(reason)")
            NSSound.beep()
        }
    }

    func focus(_ candidate: WindowSwitcherCandidate) {
        cancel()
        let request = currentGeneration()
        queue.async { [self] in
            guard request == currentGeneration() else { return }
            guard let info = Self.windowInfo() else {
                reportFocusFailure(id: candidate.id, pid: candidate.pid, reason: "CGWindowList-unavailable")
                return
            }
            guard info.contains(where: {
                ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == candidate.id
                    && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == candidate.pid
            }) else {
                reportFocusFailure(id: candidate.id, pid: candidate.pid, reason: "window-closed-or-owner-changed")
                return
            }
            // Re-resolve a stale handle only by exact CGWindowID, never by title, geometry or app alone.
            let window = exactWindow(candidate)
            guard let window else {
                reportFocusFailure(id: candidate.id, pid: candidate.pid, reason: "exact-AX-window-unavailable")
                return
            }
            guard request == currentGeneration() else { return }
            AXUIElementSetMessagingTimeout(window, 0.05)
            if let spaces = WindowSwitcherPrivateAPI.spaces(candidate.id), spaces.isEmpty,
               Self.attribute(window, kAXMinimizedAttribute) as? Bool != true {
                reportFocusFailure(id: candidate.id, pid: candidate.pid, reason: "window-has-no-Space")
                return
            }
            if Self.attribute(window, kAXMinimizedAttribute) as? Bool == true {
                let restored = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                guard restored == .success else {
                    reportFocusFailure(id: candidate.id, pid: candidate.pid, reason: "AX-unminimize=\(restored.rawValue)")
                    return
                }
            }
            guard request == currentGeneration() else { return }
            var psn = ProcessSerialNumber()
            var frontResult: Int32?
            let processResult = WindowSwitcherPrivateAPI.processForPID?(candidate.pid, &psn)
            if processResult == noErr { frontResult = WindowSwitcherPrivateAPI.frontWindow?(&psn, candidate.id, 0x200) }
            let axResult = Self.raise(window, appPID: candidate.pid, activate: frontResult != 0)
            let keyResult = frontResult == 0 ? WindowSwitcherPrivateAPI.makeKey(candidate.id, psn: &psn) : nil
            let details = "GetProcessForPID=\(processResult.map(String.init) ?? "missing") private-front=\(frontResult.map(String.init) ?? "missing-or-process-lookup-failed") make-key=\(keyResult.map(String.init) ?? "unavailable") \(axResult)"
            verifyFocus(candidate, request: request, attemptsRemaining: 3, details: details)
        }
    }

    private func exactWindow(_ candidate: WindowSwitcherCandidate) -> AXUIElement? {
        func matches(_ window: AXUIElement) -> Bool {
            AXUIElementSetMessagingTimeout(window, 0.05)
            var owner: pid_t = 0
            return AXUIElementGetPid(window, &owner) == .success && owner == candidate.pid && Self.windowID(window) == candidate.id
        }
        if let window = roots[candidate.id], matches(window) { return window }
        let app = AXUIElementCreateApplication(candidate.pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let windows = Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement],
              let window = windows.first(where: matches) else { return nil }
        roots[candidate.id] = window
        return window
    }

    private func verifyFocus(_ candidate: WindowSwitcherCandidate,
                             request: Int, attemptsRemaining: Int, details: String) {
        guard request == currentGeneration() else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focused = Self.focusedID(pid: candidate.pid)
        if frontmost == candidate.pid && focused == candidate.id { return }
        guard attemptsRemaining > 0 else {
            reportFocusFailure(id: candidate.id, pid: candidate.pid,
                reason: "focus-not-confirmed frontmost=\(frontmost ?? 0) focused=\(focused ?? 0) \(details)")
            return
        }
        // Space switching is asynchronous. Verify only; never steal focus back with delayed raises.
        queue.asyncAfter(deadline: .now() + 0.25) { [self] in
            verifyFocus(candidate, request: request, attemptsRemaining: attemptsRemaining - 1, details: details)
        }
    }

    private static func raise(_ window: AXUIElement, appPID: pid_t, activate: Bool) -> String {
        let main = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let focused = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let app = AXUIElementCreateApplication(appPID)
        AXUIElementSetMessagingTimeout(app, 0.05)
        let focus = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window)
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        // Public fallback is allowed only after resolving the precise window; verification above
        // must confirm both application and window focus before considering the switch successful.
        let acceptedTarget = [main, focused, focus, raised].contains(.success)
        var front = "not-needed"
        if activate {
            front = acceptedTarget
                ? String(AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue).rawValue)
                : "not-attempted-target-rejected"
        }
        return "AX-main=\(main.rawValue) AX-focused=\(focused.rawValue) AX-focused-window=\(focus.rawValue) AX-raise=\(raised.rawValue) AX-frontmost=\(front)"
    }
}
