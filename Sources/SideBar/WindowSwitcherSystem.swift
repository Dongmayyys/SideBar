import AppKit
import ApplicationServices
import Carbon
import Darwin

/// Private entry points are optional and confined here. No Space reassignment or hide/unhide calls.
/// Remote-token traversal and window-directed fronting follow AltTab's API wrappers:
/// https://github.com/lwouis/alt-tab-macos/tree/master/src/macos/api-wrappers
private enum WindowSwitcherPrivateAPI {
    typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
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

    static func makeKey(_ id: CGWindowID, psn: inout ProcessSerialNumber) {
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
        _ = postRecord?(&psn, &bytes)
    }
}

struct WindowSwitcherInventory {
    var candidates: [WindowSwitcherCandidate] = []
    var fields: [CGWindowID: [WindowSwitcherSearchField]] = [:]
    var liveIDs: Set<CGWindowID> = []
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

    static func windowInfo() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
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
            let info = Self.windowInfo()
            let ids = Set(info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
            let owners = Dictionary(uniqueKeysWithValues: info.compactMap { row -> (CGWindowID, pid_t)? in
                guard let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                      let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
                return (id, pid)
            })
            roots = roots.filter { id, window in
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
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(element, 0.025)
                if let windows = Self.attribute(element, kAXWindowsAttribute) as? [AXUIElement] {
                    for window in windows {
                        if let id = Self.windowID(window) { roots[id] = window }
                    }
                }
            }
            var snapshot = inventory(info: info, apps: apps)
            snapshot.liveIDs = ids
            publish(snapshot, request: request, deliver: deliver)
            refine(info: info, apps: apps, request: request, snapshot: snapshot, deliver: deliver)
        }
    }

    private func publish(_ snapshot: WindowSwitcherInventory, request: Int,
                         deliver: @escaping (WindowSwitcherInventory) -> Void) {
        DispatchQueue.main.async { [self] in
            if request == currentGeneration() { deliver(snapshot) }
        }
    }

    private func refine(info: [[String: Any]], apps: [NSRunningApplication], request: Int,
                        snapshot: WindowSwitcherInventory, deliver: @escaping (WindowSwitcherInventory) -> Void) {
        guard request == currentGeneration(), WindowSwitcherPrivateAPI.remoteElement != nil else { return }
        var snapshot = snapshot
        var needsContinuation = false
        let byPID = Dictionary(grouping: info, by: { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0 })
        for app in apps {
            guard request == currentGeneration() else { return }
            let missing = Set((byPID[app.processIdentifier] ?? []).compactMap { row -> CGWindowID? in
                guard (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                      let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                      roots[id] == nil, WindowSwitcherPrivateAPI.spaces(id)?.isEmpty == false else { return nil }
                return id
            })
            guard !missing.isEmpty else { continue }
            scan(pid: app.processIdentifier, wanted: missing, request: request)
            guard request == currentGeneration() else { return }
            let discovered = missing.filter { roots[$0] != nil }
            needsContinuation = needsContinuation || discovered.count < missing.count
            guard !discovered.isEmpty else { continue }
            let delta = inventory(info: info.filter {
                discovered.contains(($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            }, apps: apps)
            snapshot.candidates += delta.candidates
            snapshot.fields.merge(delta.fields) { _, new in new }
            let stacking = Dictionary(uniqueKeysWithValues: info.enumerated().compactMap { index, row -> (CGWindowID, Int)? in
                guard let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
                return (id, index)
            })
            snapshot.candidates.sort { (stacking[$0.id] ?? 0) < (stacking[$1.id] ?? 0) }
            publish(snapshot, request: request, deliver: deliver)
        }
        // Each AX sweep has a 250ms time slice, not an ID ceiling. Continue from the cursor while
        // the panel is open, so high/sparse AX IDs aren't permanently omitted. Reuse the SAME CG
        // snapshot: no polling of the window inventory and no work in the 120ms stash loop.
        if needsContinuation {
            let nextSnapshot = snapshot
            queue.asyncAfter(deadline: .now() + 0.1) { [self] in
                refine(info: info, apps: apps, request: request, snapshot: nextSnapshot, deliver: deliver)
            }
        }
    }

    private func inventory(info: [[String: Any]], apps: [NSRunningApplication]) -> WindowSwitcherInventory {
        let appsByPID = Dictionary(uniqueKeysWithValues: apps.map { ($0.processIdentifier, $0) })
        var result = WindowSwitcherInventory()
        for row in info {
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
            let hasSpace = WindowSwitcherPrivateAPI.spaces(id)?.isEmpty == false
            // A genuine AX-minimized window is restorable even on systems reporting no Space for it.
            guard hasSpace || minimized else { continue }
            let name = app.localizedName ?? app.bundleIdentifier ?? ""
            let title = Self.attribute(window, kAXTitleAttribute) as? String ?? row[kCGWindowName as String] as? String ?? ""
            var candidate = WindowSwitcherCandidate(id: id, pid: pid, appName: name, title: title)
            candidate.isMinimized = minimized
            candidate.hasSpace = hasSpace
            result.candidates.append(candidate)
            result.fields[id] = [WindowSwitcherSearchField(name), WindowSwitcherSearchField(title)]
        }
        return result
    }

    private func scan(pid: pid_t, wanted: Set<CGWindowID>, request: Int) {
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
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
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

    func focus(_ candidate: WindowSwitcherCandidate) {
        cancel()
        let request = currentGeneration()
        queue.async { [self] in
            guard request == currentGeneration(), Self.windowInfo().contains(where: {
                ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == candidate.id
                    && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == candidate.pid
            }),
                  let window = roots[candidate.id], Self.windowID(window) == candidate.id else { return }
            AXUIElementSetMessagingTimeout(window, 0.05)
            var owner: pid_t = 0
            guard AXUIElementGetPid(window, &owner) == .success, owner == candidate.pid else { return }
            let minimized = Self.attribute(window, kAXMinimizedAttribute) as? Bool == true
            guard WindowSwitcherPrivateAPI.spaces(candidate.id)?.isEmpty == false || minimized else { return }
            if minimized {
                guard AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else { return }
            }
            var psn = ProcessSerialNumber()
            guard let processForPID = WindowSwitcherPrivateAPI.processForPID,
                  processForPID(candidate.pid, &psn) == noErr,
                  let front = WindowSwitcherPrivateAPI.frontWindow,
                  front(&psn, candidate.id, 0x200) == 0 else { return }
            // AXRaise also requests exact-window activation. Never activate all windows of the app.
            Self.raise(window, appPID: candidate.pid)
            WindowSwitcherPrivateAPI.makeKey(candidate.id, psn: &psn)
            // Cross-Space fronting is asynchronous. Re-assert the exact focus after the transition,
            // but do not steal focus back if the user has moved to another application.
            queue.asyncAfter(deadline: .now() + 0.35) { [self] in
                guard request == currentGeneration(), NSWorkspace.shared.frontmostApplication?.processIdentifier == candidate.pid,
                      Self.windowID(window) == candidate.id else { return }
                Self.raise(window, appPID: candidate.pid)
            }
        }
    }

    private static func raise(_ window: AXUIElement, appPID: pid_t) {
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let app = AXUIElementCreateApplication(appPID)
        AXUIElementSetMessagingTimeout(app, 0.05)
        _ = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window)
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
}
