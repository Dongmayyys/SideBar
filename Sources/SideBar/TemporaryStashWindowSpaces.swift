import AppKit
import ApplicationServices
import Darwin

/// Logical Space membership is independent of application visibility and window position.
/// Resolve read-only SkyLight entry points at runtime; missing data remains unknown.
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

    static func spaceIDs(for windowID: CGWindowID) -> Set<UInt64>? {
        guard let spaces = copyWindowSpaces?(CGSMainConnectionID(), 0x7, [NSNumber(value: windowID)] as CFArray)?
            .takeRetainedValue() as? [NSNumber] else {
            return nil
        }
        return spaces.isEmpty ? nil : Set(spaces.map(\.uint64Value))
    }
}

