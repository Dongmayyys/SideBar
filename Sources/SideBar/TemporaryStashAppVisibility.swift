import AppKit
import ApplicationServices
import Darwin

/// Space membership survives application hiding, unlike CG's on-screen list.
/// Resolve read-only SkyLight entry points at runtime. Missing data is unknown,
/// never evidence that a hidden application's window left its logical Space.
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

    static func displayUUID(for screenID: UInt32) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(screenID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func activeSpacesByDisplay() -> [String: UInt64]? {
        guard let displays = copyDisplays?(CGSMainConnectionID())?.takeRetainedValue() as? [[String: Any]],
              !displays.isEmpty else { return nil }
        return activeSpaces(in: displays, screenUUIDs: NSScreen.screens.compactMap { displayUUID(for: $0.displayID) })
    }

    static func activeSpaces(in displays: [[String: Any]], screenUUIDs: [String]) -> [String: UInt64]? {
        var result: [String: UInt64] = [:]
        for display in displays {
            guard let uuid = display["Display Identifier"] as? String,
                  let current = display["Current Space"] as? [String: Any],
                  let id = current["ManagedSpaceID"] as? NSNumber, id.uint64Value > 0 else { continue }
            // With separate Spaces disabled, SkyLight describes one shared
            // display group rather than a physical display UUID.
            let targets = uuid == "Main" ? screenUUIDs : [uuid]
            for target in targets { result[target] = id.uint64Value }
        }
        return result.isEmpty ? nil : result
    }

    private static var windowQueryCategories: [CGWindowID: String] = [:]
    static func spaceQueryCategory(for windowID: CGWindowID) -> String { windowQueryCategories[windowID] ?? "unqueried" }

    static func spaceIDs(for windowID: CGWindowID) -> Set<UInt64>? {
        guard let spaces = copyWindowSpaces?(CGSMainConnectionID(), 0x7, [NSNumber(value: windowID)] as CFArray)?
            .takeRetainedValue() as? [NSNumber] else {
            windowQueryCategories[windowID] = "nil-or-malformed"
            return nil
        }
        windowQueryCategories[windowID] = spaces.isEmpty ? "empty" : "valid"
        return spaces.isEmpty ? nil : Set(spaces.map(\.uint64Value))
    }
}

/// Request return values are diagnostics, not acknowledgements. Only the same
/// live process can confirm a request or inherit its recovery transaction.
final class TemporaryStashAppVisibility {
    struct Presence {
        let displayUUID: String
        let spaces: Set<UInt64>
        var lastVisible: Bool
        let generation: Int
    }
    private enum Phase: String { case hideRequested, hiddenOwned, revealRequested, released }
    private struct HiddenApplication {
        let app: NSRunningApplication
        let launchDate: Date
        let bundleID: String
        var windows: [String: Presence]
        let windowIDs: [UInt32]
        var phase: Phase = .hideRequested
        var sequence: Int
        var attempts = 0
        var requestedAt = Date.distantPast
        var settleUntil = Date.distantPast
        var activationUntil = Date.distantPast
    }
    private var revealCallbacks: [pid_t: [String: () -> Void]] = [:]
    private var applications: [pid_t: HiddenApplication] = [:]
    private var spaceGeneration = 0
    private var sequence = 0
    private var pendingActivationPID: pid_t?
    private let store: TemporaryStashHiddenAppStore
    private let now: () -> Date
    private var lastActiveDescription = ""
    private var presenceDiagnostics: [String: String] = [:]
    private var nextPresenceSampleAt: [pid_t: Date] = [:]
    private static var sampleDiagnostics: [String: String] = [:]

    init(store: TemporaryStashHiddenAppStore = TemporaryStashHiddenAppStore(), now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    static func capturePresence(window: AXUIElement, pid: pid_t, screenID: UInt32, generation: Int = 0) -> Presence? {
        let start = Date()
        let id = WindowAlphaManager.shared.findWindowID(for: window, pid: pid)
        let spaces = id.flatMap { TemporaryStashWindowSpaces.spaceIDs(for: $0) }
        let display = TemporaryStashWindowSpaces.displayUUID(for: screenID)
        let active = TemporaryStashWindowSpaces.activeSpacesByDisplay()
        let cg = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])?
            .contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }
        let diagnostic = "pid=\(pid) window=\(String(describing: id)) display=\(display ?? "unknown") spaces=\(String(describing: spaces?.sorted())) rawCategory=\(id.map { TemporaryStashWindowSpaces.spaceQueryCategory(for: $0) } ?? "missing-windowID") active=\(String(describing: active?.sorted { $0.key < $1.key })) CG=\(String(describing: cg)) generation=\(generation)"
        let key = "\(pid):\(String(describing: id))"
        if sampleDiagnostics[key] != diagnostic {
            StashDebugLog.write("space sample \(diagnostic) start=\(start) sampleMS=\(Date().timeIntervalSince(start) * 1000)")
            sampleDiagnostics[key] = diagnostic
        }
        guard let display, let spaces, !spaces.isEmpty, let current = active?[display] else { return nil }
        return Presence(displayUUID: display, spaces: spaces, lastVisible: spaces.contains(current), generation: generation)
    }

    var diagnosticSummary: String {
        "owned=\(applications.values.filter { $0.phase == .hiddenOwned }.count) pending=\(applications.values.filter { $0.phase == .hideRequested || $0.phase == .revealRequested }.count)"
    }

    private func release(pid: pid_t, reason: String, remove: Bool = true) {
        guard let current = applications[pid] else { return }
        StashDebugLog.write("app released pid=\(pid) op=\(current.sequence) phase=\(current.phase.rawValue) reason=\(reason)")
        store.remove(pid: pid)
        if remove { applications[pid] = nil }
        else { applications[pid]?.phase = .released }
        if reason == "unhide-confirmed" {
            let callbacks = revealCallbacks.removeValue(forKey: pid)?.values.map { $0 } ?? []
            callbacks.forEach { $0() }
        } else { revealCallbacks[pid] = nil }
    }

    private func persist(pid: pid_t) {
        guard let current = applications[pid], current.phase != .released else { return }
        store.upsert(TemporaryStashHiddenAppRecord(pid: pid, bundleID: current.bundleID,
            launchDate: current.launchDate, windowIDs: current.windowIDs, sessionIDs: current.windows.keys.sorted(),
            phase: current.phase.rawValue))
    }

    private func request(pid: pid_t, reveal: Bool, reason: String) {
        guard var current = applications[pid] else { return }
        guard !current.app.isTerminated,
              let live = NSRunningApplication(processIdentifier: pid), !live.isTerminated,
              live.launchDate == current.launchDate, live.bundleIdentifier == current.bundleID else {
            release(pid: pid, reason: "request-process-identity-invalid")
            return
        }
        current.attempts += 1
        current.requestedAt = now()
        applications[pid] = current
        persist(pid: pid) // Persist intent before the asynchronous OS request.
        let before = current.app.isHidden
        let start = Date()
        let accepted = reveal ? current.app.unhide() : current.app.hide()
        StashDebugLog.write("app \(reveal ? "unhide" : "hide") request pid=\(pid) bundle=\(current.app.bundleIdentifier ?? "?") identity=\(current.launchDate) op=\(current.sequence) phase=\(current.phase.rawValue) attempt=\(current.attempts) sessions=\(current.windows.keys.sorted()) windows=\(current.windowIDs) reason=\(reason) accepted=\(accepted) before=\(before) after=\(current.app.isHidden) requestMS=\(Date().timeIntervalSince(start) * 1000)")
    }

    private func advance(pid: pid_t) {
        guard let current = applications[pid] else { return }
        guard !current.app.isTerminated,
              let live = NSRunningApplication(processIdentifier: pid), !live.isTerminated,
              live.launchDate == current.launchDate, live.bundleIdentifier == current.bundleID else {
            release(pid: pid, reason: "process-identity-invalid")
            return
        }
        switch current.phase {
        case .hideRequested:
            if live.isHidden {
                applications[pid]?.phase = .hiddenOwned
                persist(pid: pid)
                StashDebugLog.write("app hidden confirmed pid=\(pid) op=\(current.sequence)")
            } else if now().timeIntervalSince(current.requestedAt) >= 0.7 {
                if current.attempts < 3 { request(pid: pid, reveal: false, reason: "confirmation-timeout") }
                else { release(pid: pid, reason: "hide-confirmation-timeout", remove: false) }
            }
        case .revealRequested:
            if !live.isHidden && now() >= current.settleUntil {
                // Retain logical presence across CG/AX publication lag until the
                // requesting session writes its geometry or activation expires.
                applications[pid]?.activationUntil = now().addingTimeInterval(0.8)
                release(pid: pid, reason: "unhide-confirmed", remove: false)
            } else if now().timeIntervalSince(current.requestedAt) >= 0.2 {
                // Keep a cancelled pending hide's intent through its acknowledgement
                // window: an older hide can complete after the first unhide.
                if current.attempts < 3 || now().timeIntervalSince(current.requestedAt) >= 2 {
                    request(pid: pid, reveal: true, reason: "reveal-confirmation-retry")
                }
            }
        case .hiddenOwned:
            if !live.isHidden {
                release(pid: pid, reason: "external-unhide-state-observed", remove: false)
                applications[pid]?.activationUntil = now().addingTimeInterval(0.8)
            }
        case .released: break
        }
    }

    func reconcile(sessions: [WindowSession], activatingPID: pid_t? = nil) {
        pendingActivationPID = activatingPID
        let activeDescription = String(describing: TemporaryStashWindowSpaces.activeSpacesByDisplay()?.sorted { $0.key < $1.key })
        if activeDescription != lastActiveDescription {
            StashDebugLog.write("space active changed generation=\(spaceGeneration) value=\(activeDescription) previous=\(lastActiveDescription)")
            lastActiveDescription = activeDescription
        }
        for pid in Array(applications.keys) { advance(pid: pid) }
        let groups = Dictionary(grouping: sessions.filter(\.isManagedByTemporaryShortcut), by: \.pid)
        for pid in Array(applications.keys) where groups[pid] == nil {
            _ = restore(pid: pid, reason: "no-managed-windows")
        }
        for (pid, group) in groups {
            guard let first = group.first, let app = NSRunningApplication(processIdentifier: pid),
                  !app.isTerminated else { release(pid: pid, reason: "terminated"); continue }
            guard group.allSatisfy(\.isSnappedForCoordination) else {
                _ = restore(pid: pid, reason: "expanded-window"); continue
            }
            if let current = applications[pid], current.phase == .revealRequested { continue }
            var value: CFTypeRef?
            guard AccessibilityRuntimeGuard.copyAttributeValue(of: first.appElement, attribute: kAXWindowsAttribute as CFString,
                      value: &value, context: "TemporaryStashAppVisibility.windows") == .success,
                  let windows = value as? [AXUIElement] else {
                _ = restore(pid: pid, reason: "unknown-windows"); continue
            }
            let profiled = windows.map { window in
                (window: window, profile: WindowCapabilityProfiler.profile(of: window, bundleID: first.bundleID,
                    context: "TemporaryStashAppVisibility.standard"))
            }
            guard profiled.allSatisfy({ $0.profile.subrole != nil }) else {
                _ = restore(pid: pid, reason: "unknown-window-subrole"); continue
            }
            let standard = profiled.filter { $0.profile.isStandardWindow }.map { $0.window }
            guard !standard.isEmpty, standard.allSatisfy({ window in group.contains { CFEqual($0.windowElement, window) } }) else {
                _ = restore(pid: pid, reason: "unmanaged-standard-window"); continue
            }
            if let current = applications[pid], current.phase == .released,
               current.activationUntil != .distantPast, now() >= current.activationUntil, pendingActivationPID != pid {
                release(pid: pid, reason: "activation-grace-ended")
            }
            if applications[pid] != nil || pendingActivationPID == pid { continue }
            guard !app.isHidden, let launchDate = app.launchDate else { continue }
            guard now() >= (nextPresenceSampleAt[pid] ?? .distantPast) else { continue }
            nextPresenceSampleAt[pid] = now().addingTimeInterval(1)
            var presence: [String: Presence] = [:]
            var ids: [UInt32] = []
            for session in group {
                if session.temporaryStashPresence == nil {
                    session.temporaryStashPresence = Self.capturePresence(window: session.windowElement, pid: pid,
                        screenID: session.temporaryStashTabDescriptor()?.screenID ?? 0, generation: spaceGeneration)
                }
                presence[session.temporaryStashID] = session.temporaryStashPresence
                if let id = WindowAlphaManager.shared.findWindowID(for: session.windowElement, pid: pid) { ids.append(id) }
            }
            guard presence.count == group.count, ids.count == group.count else { continue }
            nextPresenceSampleAt[pid] = nil
            sequence += 1
            applications[pid] = HiddenApplication(app: app, launchDate: launchDate, bundleID: first.bundleID, windows: presence,
                windowIDs: ids, sequence: sequence)
            request(pid: pid, reveal: false, reason: "all-collapsed")
            advance(pid: pid)
        }
    }

    func isOnScreen(sessionID: String, pid: pid_t) -> Bool? {
        guard let current = applications[pid], !current.app.isTerminated,
              current.phase != .released || (!current.app.isHidden && (now() < current.activationUntil || pendingActivationPID == pid)),
              var presence = current.windows[sessionID] else { return nil }
        let active = TemporaryStashWindowSpaces.activeSpacesByDisplay()?[presence.displayUUID]
        if let active { presence.lastVisible = presence.spaces.contains(active) }
        applications[pid]?.windows[sessionID] = presence
        let diagnostic = "visible=\(presence.lastVisible) source=\(active == nil ? "unknown-retained" : "cached-space") display=\(presence.displayUUID) spaces=\(presence.spaces.sorted()) active=\(String(describing: active)) generation=\(spaceGeneration) sampled=\(presence.generation)"
        if presenceDiagnostics[sessionID] != diagnostic {
            StashDebugLog.write("descriptor space session=\(sessionID) pid=\(pid) \(diagnostic)")
            presenceDiagnostics[sessionID] = diagnostic
        }
        return presence.lastVisible
    }

    private func notification(pid: pid_t, kind: String) {
        let current = applications[pid]
        StashDebugLog.write("app notification=\(kind) pid=\(pid) hidden=\(NSRunningApplication(processIdentifier: pid)?.isHidden == true) phase=\(current?.phase.rawValue ?? "unowned") op=\(current?.sequence ?? 0)")
    }

    func applicationWasActivated(pid: pid_t) {
        notification(pid: pid, kind: "activate")
        guard applications[pid] != nil else { return }
        if applications[pid]?.phase == .released {
            applications[pid]?.activationUntil = now().addingTimeInterval(0.8)
        } else { _ = restore(pid: pid, reason: "activation") }
    }

    func applicationWasUnhidden(pid: pid_t) {
        notification(pid: pid, kind: "unhide")
        guard let current = applications[pid], !current.app.isHidden else { return }
        if current.phase == .hideRequested {
            StashDebugLog.write("app notification ignored pid=\(pid) reason=old-unhide-during-hide-request")
        } else if current.phase == .hiddenOwned {
            release(pid: pid, reason: "external-unhide-awaiting-activation", remove: false)
            applications[pid]?.activationUntil = now().addingTimeInterval(0.8)
        } else { advance(pid: pid) }
    }

    func applicationWasHidden(pid: pid_t) {
        notification(pid: pid, kind: "hide")
        if applications[pid]?.phase == .released, NSRunningApplication(processIdentifier: pid)?.isHidden == true {
            release(pid: pid, reason: "user-hide")
        } else { advance(pid: pid) }
    }

    func spaceDidChange(topologyChanged: Bool = false) {
        spaceGeneration &+= 1
        StashDebugLog.write("space notification generation=\(spaceGeneration - 1)->\(spaceGeneration) topology=\(topologyChanged) active=\(String(describing: TemporaryStashWindowSpaces.activeSpacesByDisplay())) screens=\(NSScreen.screens.map { "\($0.displayID):\($0.visibleFrame)" }) resample=\(topologyChanged)")
        if topologyChanged {
            for pid in Array(applications.keys) { _ = restore(pid: pid, reason: "display-topology-resample") }
        }
    }

    func prepareToReveal(pid: pid_t, sessionID: String = "", onReady: @escaping () -> Void = {}) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        if app.isHidden && (applications[pid] == nil || applications[pid]?.phase == .released) { return false }
        let ready = restore(pid: pid, reason: "reveal")
        if !ready { revealCallbacks[pid, default: [:]][sessionID] = onReady }
        return ready
    }

    @discardableResult
    func restore(pid: pid_t, reason: String) -> Bool {
        guard let current = applications[pid] else { return true }
        if reason == "cancel" || reason == "session-cleanup" || reason == "cleanup" {
            revealCallbacks[pid] = nil
        }
        if current.phase == .released {
            // No hide ownership remains (e.g. a user hide following external unhide).
            release(pid: pid, reason: reason)
            return !current.app.isHidden
        }
        if current.phase != .revealRequested {
            sequence += 1
            applications[pid]?.phase = .revealRequested
            applications[pid]?.sequence = sequence
            applications[pid]?.attempts = 0
            applications[pid]?.settleUntil = current.phase == .hideRequested && !current.app.isHidden ? now().addingTimeInterval(0.8) : now()
            request(pid: pid, reveal: true, reason: reason)
        }
        advance(pid: pid)
        return (applications[pid] == nil || applications[pid]?.phase == .released) && !current.app.isHidden
    }

    func cancelPendingReveal(pid: pid_t, sessionID: String) {
        if revealCallbacks[pid]?.removeValue(forKey: sessionID) != nil {
            StashDebugLog.write("app reveal intent cancelled pid=\(pid) session=\(sessionID) reason=activation-reset")
        }
    }

    func restorationIsConfirmed(pid: pid_t) -> Bool {
        applications[pid]?.phase != .revealRequested && NSRunningApplication(processIdentifier: pid)?.isHidden != true
    }

    func waitForRestore(pid: pid_t, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while applications[pid]?.phase == .revealRequested, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            advance(pid: pid)
        }
    }

    func restoreAll(reason: String, timeout: TimeInterval = 1) {
        for pid in Array(applications.keys) { _ = restore(pid: pid, reason: reason) }
        let deadline = Date().addingTimeInterval(timeout)
        while applications.values.contains(where: { $0.phase == .revealRequested }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            for pid in Array(applications.keys) { advance(pid: pid) }
        }
        StashDebugLog.write("app restore-all reason=\(reason) remaining=\(diagnosticSummary) persisted-for-recovery=true")
        pendingActivationPID = nil
    }
}
