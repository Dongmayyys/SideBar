import AppKit
import ApplicationServices
import Darwin

/// Space membership survives application hiding, unlike CG's on-screen list.
/// Resolve these read-only SkyLight entry points at runtime so older systems can
/// fall back to a fresh on-screen sample after each desktop change.
enum TemporaryStashWindowSpaces {
    private typealias CopyDisplays = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyWindowSpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private static let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let copyDisplays: CopyDisplays? = {
        guard let library, let symbol = dlsym(library, "SLSCopyManagedDisplaySpaces") else { return nil }
        return unsafeBitCast(symbol, to: CopyDisplays.self)
    }()
    private static let copyWindowSpaces: CopyWindowSpaces? = {
        guard let library, let symbol = dlsym(library, "SLSCopySpacesForWindows") else { return nil }
        return unsafeBitCast(symbol, to: CopyWindowSpaces.self)
    }()

    static func activeSpaceIDs() -> Set<UInt64>? {
        guard let displays = copyDisplays?(CGSMainConnectionID())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let ids = displays.compactMap { display -> UInt64? in
            let current = display["Current Space"] as? [String: Any]
            return (current?["ManagedSpaceID"] as? NSNumber)?.uint64Value
        }
        guard ids.count == displays.count else { return nil }
        return ids.isEmpty ? nil : Set(ids)
    }

    static func spaceIDs(for windowID: CGWindowID) -> Set<UInt64>? {
        guard let spaces = copyWindowSpaces?(CGSMainConnectionID(), 0x7, [NSNumber(value: windowID)] as CFArray)?
            .takeRetainedValue() as? [NSNumber], !spaces.isEmpty else { return nil }
        return Set(spaces.map(\.uint64Value))
    }
}

/// Only this manager's successful hide requests grant permission to unhide an
/// application. User-hidden applications are never claimed or revealed.
final class TemporaryStashAppVisibility {
    private struct Presence {
        let spaces: Set<UInt64>?
        let wasOnScreen: Bool
        let generation: Int
    }

    private struct HiddenApplication {
        let app: NSRunningApplication
        let windows: [String: Presence]
        var ownsHide = true
        var activationUntil = Date.distantPast
    }

    private var applications: [pid_t: HiddenApplication] = [:]
    private var spaceGeneration = 0
    private var resampleUntil: [pid_t: Date] = [:]
    private var pendingActivationPID: pid_t?

    func reconcile(sessions: [WindowSession], activatingPID: pid_t? = nil) {
        pendingActivationPID = activatingPID
        let groups = Dictionary(grouping: sessions.filter(\.isManagedByTemporaryShortcut), by: \.pid)
        for pid in Array(applications.keys) where groups[pid] == nil {
            _ = restore(pid: pid, reason: "no-managed-windows")
        }
        for (pid, group) in groups {
            guard let first = group.first, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
                applications[pid] = nil
                continue
            }
            if applications[pid]?.app.isTerminated == true { applications[pid] = nil }
            if resampleUntil[pid] != nil && applications[pid]?.ownsHide == true {
                guard restore(pid: pid, reason: "space-resample-retry") else { continue }
                resampleUntil[pid] = Date().addingTimeInterval(0.2)
            }
            guard group.allSatisfy(\.isSnappedForCoordination) else {
                _ = restore(pid: pid, reason: "expanded-window")
                continue
            }
            var value: CFTypeRef?
            guard AccessibilityRuntimeGuard.copyAttributeValue(of: first.appElement, attribute: kAXWindowsAttribute as CFString,
                      value: &value, context: "TemporaryStashAppVisibility.windows") == .success,
                  let windows = value as? [AXUIElement] else {
                _ = restore(pid: pid, reason: "unknown-windows")
                continue
            }
            let profiled = windows.map { window in
                (window: window, profile: WindowCapabilityProfiler.profile(of: window, bundleID: first.bundleID,
                    context: "TemporaryStashAppVisibility.standard"))
            }
            guard profiled.allSatisfy({ $0.profile.subrole != nil }) else {
                _ = restore(pid: pid, reason: "unknown-window-subrole")
                continue
            }
            let standard = profiled.filter { $0.profile.isStandardWindow }.map { $0.window }
            guard !standard.isEmpty, standard.allSatisfy({ window in
                group.contains { CFEqual($0.windowElement, window) }
            }) else {
                _ = restore(pid: pid, reason: "unmanaged-standard-window")
                continue
            }
            if let current = applications[pid] {
                if current.ownsHide || Date() < current.activationUntil || pendingActivationPID == pid { continue }
                applications[pid] = nil
            }
            guard !app.isHidden, Date() >= (resampleUntil[pid] ?? .distantPast) else { continue }
            var presence: [String: Presence] = [:]
            for session in group {
                let spaces = WindowAlphaManager.shared.findWindowID(for: session.windowElement, pid: pid)
                    .flatMap { TemporaryStashWindowSpaces.spaceIDs(for: $0) }
                presence[session.temporaryStashID] = Presence(spaces: spaces,
                    wasOnScreen: session.temporaryStashTabDescriptor()?.isOnScreen == true, generation: spaceGeneration)
            }
            // hide() 是异步的，返回值不可靠（常返回 false 但随后真的隐藏）；先记下归属再请求隐藏。
            applications[pid] = HiddenApplication(app: app, windows: presence)
            resampleUntil[pid] = nil
            let accepted = app.hide()
            StashDebugLog.write("app hide pid=\(pid) bundle=\(first.bundleID) windows=\(standard.count) accepted=\(accepted)")
        }
    }

    func isOnScreen(sessionID: String, pid: pid_t) -> Bool? {
        guard let current = applications[pid], !current.app.isTerminated,
              current.ownsHide || (!current.app.isHidden && (Date() < current.activationUntil || pendingActivationPID == pid)),
              let presence = current.windows[sessionID] else { return nil }
        if let spaces = presence.spaces, let active = TemporaryStashWindowSpaces.activeSpaceIDs() {
            return !spaces.isDisjoint(with: active)
        }
        return presence.generation == spaceGeneration && presence.wasOnScreen
    }

    func applicationWasActivated(pid: pid_t) {
        guard let current = applications[pid] else { return }
        applications[pid]?.activationUntil = Date().addingTimeInterval(0.8)
        if !current.app.isHidden {
            // hide() is asynchronous: activation can beat its acknowledgement.
            // Cancel our in-flight hide rather than later hiding a revealed app.
            if current.ownsHide {
                guard current.app.unhide() else {
                    StashDebugLog.write("app unhide failed pid=\(pid) reason=activation")
                    return
                }
                StashDebugLog.write("app unhide pid=\(pid) reason=activation")
            }
            applicationWasUnhidden(pid: pid)
        }
    }

    func applicationWasUnhidden(pid: pid_t) {
        // An older notification may arrive after a subsequent hide request.
        guard let current = applications[pid], !current.app.isHidden else { return }
        applications[pid]?.ownsHide = false
        applications[pid]?.activationUntil = Date().addingTimeInterval(0.8)
        StashDebugLog.write("app unhide observed pid=\(pid) awaiting-activation")
    }

    func applicationWasHidden(pid: pid_t) {
        // A new user hide after an external unhide is not ours to undo.
        if let current = applications[pid], !current.ownsHide, current.app.isHidden { applications[pid] = nil }
    }

    func spaceDidChange() {
        spaceGeneration &+= 1
        let hasActiveSpaces = TemporaryStashWindowSpaces.activeSpaceIDs() != nil
        for (pid, current) in applications {
            if !hasActiveSpaces || current.windows.values.contains(where: { $0.spaces == nil }) {
                _ = restore(pid: pid, reason: "space-resample")
                resampleUntil[pid] = Date().addingTimeInterval(0.2)
            }
        }
    }

    func prepareToReveal(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        if app.isHidden && applications[pid]?.ownsHide != true { return false }
        return restore(pid: pid, reason: "reveal")
    }

    @discardableResult
    func restore(pid: pid_t, reason: String) -> Bool {
        guard let current = applications[pid] else { return true }
        if current.ownsHide && !current.app.isTerminated {
            let start = Date()
            guard current.app.unhide() else {
                StashDebugLog.write("app unhide failed pid=\(pid) reason=\(reason)")
                return false
            }
            StashDebugLog.write("app unhide pid=\(pid) reason=\(reason) requestMS=\(Date().timeIntervalSince(start) * 1000)")
        }
        applications[pid] = nil
        return true
    }

    func restoreAll(reason: String) {
        for pid in Array(applications.keys) { _ = restore(pid: pid, reason: reason) }
        resampleUntil.removeAll()
        pendingActivationPID = nil
    }
}
