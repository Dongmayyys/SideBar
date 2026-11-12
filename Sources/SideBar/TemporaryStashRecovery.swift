import Foundation
import Darwin

struct TemporaryStashRecoveryRecord: Codable, Equatable {
    let id: String
    let bundleID: String
    let pid: Int32
    let windowID: UInt32
    let edge: Int
    let screenID: UInt32
    let originalFrame: CGRect
    let ordinal: Int

    func matches(pid: Int32, bundleID: String, windowID: UInt32) -> Bool {
        self.pid == pid && self.bundleID == bundleID && self.windowID == windowID
    }

    var isValid: Bool {
        !id.isEmpty && !bundleID.isEmpty && pid > 0 && windowID > 0 && ordinal > 0 && ordinal < Int.max
            && (edge == 1 || edge == 2)
            && [originalFrame.minX, originalFrame.minY, originalFrame.width, originalFrame.height].allSatisfy(\.isFinite)
            && originalFrame.width > 0 && originalFrame.height > 0
    }
}

struct TemporaryStashTabOrder: Codable, Equatable {
    let screenID: UInt32
    let edge: Int
    var ids: [String]
}

struct TemporaryStashRecoverySnapshot: Codable, Equatable {
    var windows: [TemporaryStashRecoveryRecord] = []
    var orders: [TemporaryStashTabOrder] = []

    /// Pending records keep their slots while AX is busy. Reordering live tabs replaces
    /// only live slots, so late restoration cannot discard either order or membership.
    mutating func update(windows: [TemporaryStashRecoveryRecord], liveOrders: [TemporaryStashTabOrder]) {
        self.windows = windows
        orders = orders.compactMap { order in
            let ids = order.ids.filter { id in
                windows.contains { $0.id == id && $0.screenID == order.screenID && $0.edge == order.edge }
            }
            return ids.isEmpty ? nil : TemporaryStashTabOrder(screenID: order.screenID, edge: order.edge, ids: ids)
        }
        for window in windows {
            if let index = orders.firstIndex(where: { $0.screenID == window.screenID && $0.edge == window.edge }) {
                if !orders[index].ids.contains(window.id) { orders[index].ids.append(window.id) }
            } else {
                orders.append(TemporaryStashTabOrder(screenID: window.screenID, edge: window.edge, ids: [window.id]))
            }
        }
        for liveOrder in liveOrders {
            guard let index = orders.firstIndex(where: { $0.screenID == liveOrder.screenID && $0.edge == liveOrder.edge }) else { continue }
            let liveIDs = liveOrder.ids.filter { orders[index].ids.contains($0) }
            var iterator = liveIDs.makeIterator()
            orders[index].ids = orders[index].ids.map { liveIDs.contains($0) ? iterator.next()! : $0 }
        }
    }

    mutating func remove(id: String) {
        update(windows: windows.filter { $0.id != id }, liveOrders: [])
    }
}

/// Separate from hidden-window rescue records: cleanup restores visibility but preserves intent.
final class TemporaryStashRecoveryStore {
    static let defaultsKey = "SideBarTemporaryShortcutRecoveryV1"
    private struct Archive: Codable {
        let bootSessionID: String
        let snapshot: TemporaryStashRecoverySnapshot
    }
    private let defaults: UserDefaults
    private let bootSessionID: String
    private var lastSaved: TemporaryStashRecoverySnapshot?

    init(defaults: UserDefaults = .standard, bootSessionID: String = TemporaryStashRecoveryStore.currentBootSessionID()) {
        self.defaults = defaults
        self.bootSessionID = bootSessionID
    }

    func load() -> TemporaryStashRecoverySnapshot {
        guard !bootSessionID.isEmpty,
              let data = defaults.data(forKey: Self.defaultsKey),
              let archive = try? JSONDecoder().decode(Archive.self, from: data),
              archive.bootSessionID == bootSessionID else { return TemporaryStashRecoverySnapshot() }
        var snapshot = archive.snapshot
        var ids: Set<String> = []
        let valid = snapshot.windows.filter { $0.isValid && ids.insert($0.id).inserted }
        snapshot.update(windows: valid, liveOrders: [])
        return snapshot
    }

    func save(_ snapshot: TemporaryStashRecoverySnapshot) {
        guard snapshot != lastSaved,
              let data = try? JSONEncoder().encode(Archive(bootSessionID: bootSessionID, snapshot: snapshot)) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
        lastSaved = snapshot
    }

    static func currentBootSessionID() -> String {
        var length = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &length, nil, 0) == 0, length > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &length, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }
}
