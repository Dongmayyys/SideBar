import AppKit
import ApplicationServices

/// AX elements are replaceable handles. WindowServer owns the window lifetime.
enum TemporaryStashWindowIdentity {
    private static var suspensions: Set<String> = []
    private static var validationNotBefore = Date.distantPast

    static func setSuspended(_ suspended: Bool, reason: String) {
        if suspended { suspensions.insert(reason) }
        else { suspensions.remove(reason) }
        StashDebugLog.write("window identity availability reason=\(reason) suspended=\(suspended)")
    }

    static func deferValidationAfterSystemChange() {
        // WindowServer can publish an intermediate snapshot during a display or
        // login-session transition. Retry via the ordinary synchronization loop.
        validationNotBefore = Date().addingTimeInterval(1)
    }

    static var canValidate: Bool { suspensions.isEmpty && Date() >= validationNotBefore }

    static func exists(pid: pid_t, windowID: CGWindowID) -> Bool? {
        guard canValidate else { return nil }
        // optionAll includes hidden applications, other Spaces and offscreen windows.
        guard let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]],
              !windows.isEmpty,
              windows.allSatisfy({ $0[kCGWindowNumber as String] is NSNumber && $0[kCGWindowOwnerPID as String] is NSNumber }) else { return nil }
        return windows.contains {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
                && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
        }
    }

    static func window(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        var value: CFTypeRef?
        guard AccessibilityRuntimeGuard.copyAttributeValue(of: AXUIElementCreateApplication(pid),
                  attribute: kAXWindowsAttribute as CFString, value: &value,
                  context: "TemporaryStashWindowIdentity.windows") == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { WindowAlphaManager.shared.findWindowID(for: $0, pid: pid) == windowID }
    }
}
