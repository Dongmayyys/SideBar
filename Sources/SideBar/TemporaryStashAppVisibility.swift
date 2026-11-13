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
        var displayUUID: String
        var spaces: Set<UInt64>
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
    private struct PendingReveal {
        let screenID: UInt32
        let edge: Int
        let deadline: Date
        var onReady: (() -> Void)?
        var isResuming = false
    }
    private struct AutoHideCircuitBreaker {
        let launchDate: Date
        let bundleID: String
        let sessionIDs: Set<String>
    }
    private var pendingReveals: [pid_t: [String: PendingReveal]] = [:]
    private var applications: [pid_t: HiddenApplication] = [:]
    // Runtime-only, independent of ownership release, reveal and AX snapshots.
    private var autoHideCircuitBreakers: [pid_t: AutoHideCircuitBreaker] = [:]
    private var spaceGeneration = 0
    private var sequence = 0
    private var pendingActivationPID: pid_t?
    private let store: TemporaryStashHiddenAppStore
    private let now: () -> Date
    private var lastActiveDescription = ""
    private var presenceDiagnostics: [String: String] = [:]
    private var notHiddenReasons: [pid_t: String] = [:]
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
            resumeReveals(pid: pid)
        } else { pendingReveals[pid] = nil }
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
              live.processStartDate == current.launchDate, live.bundleIdentifier == current.bundleID else {
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
        expireReveals()
        guard let current = applications[pid] else { return }
        guard !current.app.isTerminated,
              let live = NSRunningApplication(processIdentifier: pid), !live.isTerminated,
              live.processStartDate == current.launchDate, live.bundleIdentifier == current.bundleID else {
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
            if !live.isHidden {
                // Geometry must not wait for a poll or for an older hide's
                // acknowledgement window. Keep that transaction durable while
                // allowing the requested window to expand immediately.
                if now() >= current.settleUntil {
                    applications[pid]?.activationUntil = now().addingTimeInterval(0.8)
                    release(pid: pid, reason: "unhide-confirmed", remove: false)
                } else { resumeReveals(pid: pid) }
            } else if now().timeIntervalSince(current.requestedAt) >= 0.2 {
                // Keep a cancelled pending hide's intent through its acknowledgement
                // window: an older hide can complete after the first unhide.
                if current.attempts < 3 || now().timeIntervalSince(current.requestedAt) >= 2 {
                    request(pid: pid, reveal: true, reason: "reveal-confirmation-retry")
                }
            }
        case .hiddenOwned:
            observeExternalUnhide(pid: pid, reason: "external-unhide-state-observed")
        case .released: break
        }
    }

    private func skipHiding(pid: pid_t, reason: String) {
        if notHiddenReasons[pid] != reason {
            StashDebugLog.write("app not-hidden pid=\(pid) phase=\(applications[pid]?.phase.rawValue ?? "unowned") reason=\(reason)")
            notHiddenReasons[pid] = reason
        }
        _ = restore(pid: pid, reason: reason)
    }

    private func tripAutoHideCircuitBreaker(pid: pid_t, sessionIDs: Set<String>, reason: String) {
        if autoHideCircuitBreakers[pid] == nil, let current = applications[pid],
           current.phase == .hideRequested || current.phase == .hiddenOwned {
            autoHideCircuitBreakers[pid] = AutoHideCircuitBreaker(launchDate: current.launchDate,
                bundleID: current.bundleID, sessionIDs: sessionIDs)
            StashDebugLog.write("app auto-hide circuit-breaker triggered pid=\(pid) bundle=\(current.bundleID) identity=\(current.launchDate) sessions=\(sessionIDs.sorted()) reason=\(reason)")
        }
    }

    private func clearAutoHideCircuitBreaker(pid: pid_t, reason: String) {
        guard let breaker = autoHideCircuitBreakers.removeValue(forKey: pid) else { return }
        StashDebugLog.write("app auto-hide circuit-breaker cleared pid=\(pid) bundle=\(breaker.bundleID) identity=\(breaker.launchDate) sessions=\(breaker.sessionIDs.sorted()) reason=\(reason)")
    }

    private func observeExternalUnhide(pid: pid_t, reason: String) {
        guard let current = applications[pid], current.phase == .hiddenOwned,
              !current.app.isHidden else { return }
        tripAutoHideCircuitBreaker(pid: pid, sessionIDs: Set(current.windows.keys), reason: reason)
        release(pid: pid, reason: reason, remove: false)
        applications[pid]?.activationUntil = now().addingTimeInterval(0.8)
    }

    private func keepUnknownEligibility(pid: pid_t, reason: String) {
        if notHiddenReasons[pid] != reason {
            StashDebugLog.write("app eligibility unknown pid=\(pid) reason=\(reason) hidden-state-preserved=true")
            notHiddenReasons[pid] = reason
        }
    }

    private func reconcileAutoHideCircuitBreakers(groups: [pid_t: [WindowSession]]) {
        for (pid, breaker) in autoHideCircuitBreakers {
            let app = NSRunningApplication(processIdentifier: pid)
            let reason: String
            if app == nil || app?.isTerminated == true || app?.processStartDate != breaker.launchDate
                || app?.bundleIdentifier != breaker.bundleID {
                reason = "process-identity-changed"
            } else if Set((groups[pid] ?? []).map(\.temporaryStashID)) != breaker.sessionIDs {
                reason = "managed-session-set-changed"
            } else { continue }
            clearAutoHideCircuitBreaker(pid: pid, reason: reason)
        }
    }

    func reconcile(sessions: [WindowSession], activatingPID: pid_t? = nil) {
        pendingActivationPID = activatingPID
        expireReveals()
        let activeDescription = String(describing: TemporaryStashWindowSpaces.activeSpacesByDisplay()?.sorted { $0.key < $1.key })
        if activeDescription != lastActiveDescription {
            StashDebugLog.write("space active changed generation=\(spaceGeneration) value=\(activeDescription) previous=\(lastActiveDescription)")
            lastActiveDescription = activeDescription
        }
        for pid in Array(applications.keys) { advance(pid: pid) }
        for pid in Array(pendingReveals.keys) {
            if NSRunningApplication(processIdentifier: pid)?.isHidden == false { resumeReveals(pid: pid) }
        }
        let groups = Dictionary(grouping: sessions.filter(\.isManagedByTemporaryShortcut), by: \.pid)
        reconcileAutoHideCircuitBreakers(groups: groups)
        notHiddenReasons = notHiddenReasons.filter { groups[$0.key] != nil || applications[$0.key] != nil }
        for pid in Array(applications.keys) where groups[pid] == nil {
            skipHiding(pid: pid, reason: "no-managed-windows")
        }
        for (pid, group) in groups {
            guard let first = group.first, let app = NSRunningApplication(processIdentifier: pid),
                  !app.isTerminated else { release(pid: pid, reason: "terminated"); continue }
            // 访达隐藏后窗口列表会变化，导致隐藏/恢复循环；它不参与自动隐藏。
            guard first.bundleID != "com.apple.finder" else {
                skipHiding(pid: pid, reason: "excluded-app"); continue
            }
            guard group.allSatisfy(\.isSnappedForCoordination) else {
                skipHiding(pid: pid, reason: "expanded-window"); continue
            }
            if pendingReveals[pid]?.isEmpty == false { continue }
            if let current = applications[pid], current.phase == .revealRequested { continue }
            let revealOnSameEdge = group.contains { session in
                guard let descriptor = session.temporaryStashTabDescriptor() else { return false }
                return pendingReveals.values.contains { intents in
                    intents.values.contains { $0.screenID == descriptor.screenID && $0.edge == descriptor.edge }
                }
            }
            if revealOnSameEdge && !app.isHidden
                && (applications[pid] == nil || applications[pid]?.phase == .released) {
                skipHiding(pid: pid, reason: "same-edge-reveal-pending"); continue
            }
            guard TemporaryStashWindowIdentity.canValidate else {
                keepUnknownEligibility(pid: pid, reason: "system-transition"); continue
            }
            var value: CFTypeRef?
            guard AccessibilityRuntimeGuard.copyAttributeValue(of: first.appElement, attribute: kAXWindowsAttribute as CFString,
                      value: &value, context: "TemporaryStashAppVisibility.windows") == .success,
                  let windows = value as? [AXUIElement] else {
                keepUnknownEligibility(pid: pid, reason: "unknown-windows"); continue
            }
            let elements = windows.map { element -> (window: AXUIElement, role: String?) in
                var role: CFTypeRef?
                let result = AccessibilityRuntimeGuard.copyAttributeValue(of: element, attribute: kAXRoleAttribute as CFString,
                    value: &role, context: "TemporaryStashAppVisibility.role")
                return (element, result == .success ? role as? String : nil)
            }
            let managedIDs = Set(group.compactMap(\.temporaryStashWindowID))
            let listedIDs = Set(windows.compactMap { WindowAlphaManager.shared.findWindowID(for: $0, pid: pid) })
            guard managedIDs.count == group.count, !windows.isEmpty,
                  managedIDs.isSubset(of: listedIDs), elements.allSatisfy({ $0.role != nil }) else {
                keepUnknownEligibility(pid: pid, reason: "missing-session-window-or-role"); continue
            }
            // Finder includes its desktop AXScrollArea in AXWindows. Only real
            // AXWindow elements can veto hiding; desktop icons are OS-managed.
            let profiled = elements.filter { $0.role == kAXWindowRole }.map { element in
                let window = element.window
                return (window: window, profile: WindowCapabilityProfiler.profile(of: window, bundleID: first.bundleID,
                    context: "TemporaryStashAppVisibility.standard"))
            }
            guard profiled.allSatisfy({ $0.profile.subrole != nil }) else {
                keepUnknownEligibility(pid: pid, reason: "unknown-window-subrole"); continue
            }
            let standard = profiled.filter { $0.profile.isStandardWindow }.map { $0.window }
            let standardIDs = standard.compactMap { WindowAlphaManager.shared.findWindowID(for: $0, pid: pid) }
            guard !standardIDs.isEmpty, standardIDs.count == standard.count else {
                keepUnknownEligibility(pid: pid, reason: "unknown-standard-window-identity"); continue
            }
            guard standardIDs.allSatisfy({ managedIDs.contains($0) }) else {
                tripAutoHideCircuitBreaker(pid: pid, sessionIDs: Set(group.map(\.temporaryStashID)), reason: "unmanaged-standard-window")
                skipHiding(pid: pid, reason: "unmanaged-standard-window"); continue
            }
            if let current = applications[pid], current.phase == .released,
               current.activationUntil != .distantPast, now() >= current.activationUntil, pendingActivationPID != pid {
                release(pid: pid, reason: "activation-grace-ended")
            }
            if applications[pid] != nil { continue }
            if autoHideCircuitBreakers[pid] != nil {
                skipHiding(pid: pid, reason: "auto-hide-circuit-breaker"); continue
            }
            if pendingActivationPID == pid {
                skipHiding(pid: pid, reason: "activation-pending"); continue
            }
            guard !app.isHidden else {
                skipHiding(pid: pid, reason: "externally-hidden"); continue
            }
            guard let launchDate = app.processStartDate else {
                skipHiding(pid: pid, reason: "unknown-process-identity"); continue
            }
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
            guard presence.count == group.count, ids.count == group.count else {
                skipHiding(pid: pid, reason: "unknown-window-presence"); continue
            }
            notHiddenReasons[pid] = nil
            nextPresenceSampleAt[pid] = nil
            sequence += 1
            applications[pid] = HiddenApplication(app: app, launchDate: launchDate, bundleID: first.bundleID, windows: presence,
                windowIDs: ids, sequence: sequence)
            request(pid: pid, reveal: false, reason: "all-collapsed")
            advance(pid: pid)
        }
    }

    func isOnScreen(sessionID: String, pid: pid_t, spaces: Set<UInt64>? = nil, screenID: UInt32? = nil) -> Bool? {
        guard let current = applications[pid], !current.app.isTerminated,
              current.phase != .released || (!current.app.isHidden && (now() < current.activationUntil || pendingActivationPID == pid || pendingReveals[pid] != nil)),
              var presence = current.windows[sessionID] else { return nil }
        if let screenID, let display = TemporaryStashWindowSpaces.displayUUID(for: screenID) {
            presence.displayUUID = display
        }
        if let spaces, !spaces.isEmpty { presence.spaces = spaces }
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
        // Workspace may deliver activation before the external unhide notice.
        // Observe visibility before starting a SideBar restore transaction.
        observeExternalUnhide(pid: pid, reason: "external-unhide-before-activation")
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
            observeExternalUnhide(pid: pid, reason: "external-unhide-awaiting-activation")
        } else { advance(pid: pid) }
    }

    func applicationWasHidden(pid: pid_t) {
        notification(pid: pid, kind: "hide")
        if applications[pid]?.phase == .released, NSRunningApplication(processIdentifier: pid)?.isHidden == true {
            release(pid: pid, reason: "user-hide")
        } else {
            if applications[pid]?.phase == .revealRequested {
                request(pid: pid, reveal: true, reason: "late-hide-during-reveal")
            }
            advance(pid: pid)
        }
    }

    func spaceDidChange(topologyChanged: Bool = false) {
        spaceGeneration &+= 1
        StashDebugLog.write("space notification generation=\(spaceGeneration - 1)->\(spaceGeneration) topology=\(topologyChanged) active=\(String(describing: TemporaryStashWindowSpaces.activeSpacesByDisplay())) screens=\(NSScreen.screens.map { "\($0.displayID):\($0.visibleFrame)" }) resample=\(topologyChanged)")
        // A topology change invalidates geometry, not hide ownership. Resample
        // membership without exposing offscreen windows or rearming the breaker.
    }

    /// Registered before collapsing the previous label, including its reentrant
    /// state notifications. Polling retries never extend this deadline.
    @discardableResult
    func beginReveal(pid: pid_t, sessionID: String, screenID: UInt32, edge: Int) -> Bool {
        // Observe an external unhide before registering this reveal, so its
        // delayed notification cannot arm a breaker after expansion completes.
        observeExternalUnhide(pid: pid, reason: "external-unhide-before-reveal")
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              !app.isHidden || (applications[pid] != nil && applications[pid]?.phase != .released) else { return false }
        if pendingReveals[pid]?[sessionID] == nil {
            pendingReveals[pid, default: [:]][sessionID] = PendingReveal(screenID: screenID, edge: edge,
                deadline: now().addingTimeInterval(1))
            StashDebugLog.write("app reveal pending pid=\(pid) session=\(sessionID) timeout=1s")
        }
        return true
    }

    private func resumeReveals(pid: pid_t) {
        guard NSRunningApplication(processIdentifier: pid)?.isHidden == false else { return }
        for id in Array((pendingReveals[pid] ?? [:]).keys) {
            guard let intent = pendingReveals[pid]?[id], !intent.isResuming,
                  now() < intent.deadline, let callback = intent.onReady else { continue }
            pendingReveals[pid]?[id]?.isResuming = true
            callback()
            pendingReveals[pid]?[id]?.isResuming = false
        }
    }

    private func expireReveals() {
        for (pid, intents) in pendingReveals {
            for (id, intent) in intents where now() >= intent.deadline {
                pendingReveals[pid]?[id] = nil
                StashDebugLog.write("app reveal timeout pid=\(pid) session=\(id) reason=not-expanded normal-hide-rules=true")
            }
            guard pendingReveals[pid]?.isEmpty == true else { continue }
            pendingReveals[pid] = nil
            if applications[pid]?.phase == .revealRequested {
                if applications[pid]?.app.isHidden == true {
                    applications[pid]?.phase = .hiddenOwned
                    persist(pid: pid)
                } else { release(pid: pid, reason: "reveal-timeout") }
            }
        }
    }

    func completeReveal(pid: pid_t, sessionID: String) {
        // Only a successful window expansion rearms auto-hide, not an unhide
        // request or an expansion that is still waiting for AX geometry.
        if autoHideCircuitBreakers[pid]?.sessionIDs.contains(sessionID) == true {
            clearAutoHideCircuitBreaker(pid: pid, reason: "managed-window-expanded")
        }
        guard pendingReveals[pid]?.removeValue(forKey: sessionID) != nil else { return }
        if pendingReveals[pid]?.isEmpty == true { pendingReveals[pid] = nil }
        StashDebugLog.write("app reveal complete pid=\(pid) session=\(sessionID)")
    }

    func prepareToReveal(pid: pid_t, sessionID: String = "", onReady: @escaping () -> Void = {}) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        if app.isHidden && (applications[pid] == nil || applications[pid]?.phase == .released) { return false }
        pendingReveals[pid]?[sessionID]?.onReady = onReady
        // A confirmed unhide may call back while restore() is still on the stack.
        // Do not restart or release that transaction from the nested prepare.
        if !app.isHidden && applications[pid]?.phase != .hideRequested { return true }
        let ready = restore(pid: pid, reason: "reveal")
        return ready || (!app.isHidden && applications[pid]?.phase == .revealRequested)
    }

    @discardableResult
    func restore(pid: pid_t, reason: String) -> Bool {
        if reason == "cancel" || reason == "session-cleanup" || reason == "cleanup" || reason == "no-managed-windows" {
            pendingReveals[pid] = nil
        }
        guard let current = applications[pid] else { return true }
        if current.phase == .released {
            if pendingReveals[pid]?.isEmpty == false { return !current.app.isHidden }
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
        if pendingReveals[pid]?.removeValue(forKey: sessionID) != nil {
            if pendingReveals[pid]?.isEmpty == true { pendingReveals[pid] = nil }
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
        pendingReveals.removeAll()
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
