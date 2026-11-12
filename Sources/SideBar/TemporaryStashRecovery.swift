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
    // Optional so archives written before size restoration remain position-only.
    var originalSize: CGSize? = nil

    // Missing fields in V1 archives retain the old same-boot exact-identity path.
    var awaitingRelaunch: Bool = false
    var closedAt: Date? = nil
    var slot: Int = 0
    var windowFrame: CGRect? = nil
    var matchingFrame: CGRect { windowFrame ?? originalFrame }

    private enum CodingKeys: String, CodingKey {
        case id, bundleID, pid, windowID, edge, screenID, originalFrame, ordinal, originalSize, awaitingRelaunch, closedAt, slot, windowFrame
    }

    private enum LegacyKeys: String, CodingKey { case waitForProcessExit }

    init(id: String, bundleID: String, pid: Int32, windowID: UInt32, edge: Int, screenID: UInt32,
         originalFrame: CGRect, ordinal: Int, originalSize: CGSize? = nil,
         awaitingRelaunch: Bool = false, slot: Int = 0, windowFrame: CGRect? = nil) {
        self.id = id
        self.bundleID = bundleID
        self.pid = pid
        self.windowID = windowID
        self.edge = edge
        self.screenID = screenID
        self.originalFrame = originalFrame
        self.ordinal = ordinal
        self.originalSize = originalSize
        self.awaitingRelaunch = awaitingRelaunch
        self.slot = slot
        self.windowFrame = windowFrame
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        bundleID = try values.decode(String.self, forKey: .bundleID)
        pid = try values.decode(Int32.self, forKey: .pid)
        windowID = try values.decode(UInt32.self, forKey: .windowID)
        edge = try values.decode(Int.self, forKey: .edge)
        screenID = try values.decode(UInt32.self, forKey: .screenID)
        originalFrame = try values.decode(CGRect.self, forKey: .originalFrame)
        ordinal = try values.decode(Int.self, forKey: .ordinal)
        originalSize = try values.decodeIfPresent(CGSize.self, forKey: .originalSize)
        awaitingRelaunch = try values.decodeIfPresent(Bool.self, forKey: .awaitingRelaunch) ?? false
        closedAt = try values.decodeIfPresent(Date.self, forKey: .closedAt)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        if closedAt == nil, try legacy.decodeIfPresent(Bool.self, forKey: .waitForProcessExit) == true {
            closedAt = .distantPast
        }
        slot = try values.decodeIfPresent(Int.self, forKey: .slot) ?? 0
        windowFrame = try values.decodeIfPresent(CGRect.self, forKey: .windowFrame)
    }

    func waitingForRelaunch() -> Self {
        var record = self
        record.awaitingRelaunch = true
        record.closedAt = nil
        return record
    }

    func matches(pid: Int32, bundleID: String, windowID: UInt32) -> Bool {
        self.pid == pid && self.bundleID == bundleID && self.windowID == windowID
    }

    var isValid: Bool {
        !id.isEmpty && !bundleID.isEmpty && pid > 0 && windowID > 0 && ordinal > 0 && ordinal < Int.max
            && slot >= 0 && slot < Int.max
            && (edge == 1 || edge == 2)
            && [originalFrame.minX, originalFrame.minY, originalFrame.width, originalFrame.height].allSatisfy(\.isFinite)
            && originalFrame.width > 0 && originalFrame.height > 0
            && (originalSize.map { $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 } ?? true)
            && [matchingFrame.minX, matchingFrame.minY, matchingFrame.width, matchingFrame.height].allSatisfy(\.isFinite)
            && matchingFrame.width > 0 && matchingFrame.height > 0
    }
}

struct TemporaryStashRecoverySnapshot: Codable, Equatable {
    var windows: [TemporaryStashRecoveryRecord] = []
    var assignments: [TemporaryStashSlotAssignment] { windows.map(\.slotAssignment) }

    private enum CodingKeys: String, CodingKey { case windows, orders }
    private struct LegacyOrder: Decodable {
        let screenID: UInt32
        let edge: Int
        let ids: [String]
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var records = try values.decode([TemporaryStashRecoveryRecord].self, forKey: .windows)
        let orders = try values.decodeIfPresent([LegacyOrder].self, forKey: .orders) ?? []
        for index in records.indices where records[index].slot == 0 {
            let record = records[index]
            if let order = orders.first(where: { $0.screenID == record.screenID && $0.edge == record.edge }),
               let rank = order.ids.firstIndex(of: record.id) { records[index].slot = rank + 1 }
        }
        update(windows: records)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(windows, forKey: .windows)
    }

    mutating func update(windows: [TemporaryStashRecoveryRecord]) {
        let resolved = TemporaryStashSlots.resolve(existing: assignments, requested: windows.map(\.slotAssignment))
        self.windows = windows.map { record in
            var record = record
            record.slot = resolved.first { $0.id == record.id }?.slot ?? record.slot
            return record
        }
    }

    mutating func remove(id: String) { windows.removeAll { $0.id == id } }
}

extension TemporaryStashRecoveryRecord {
    var slotAssignment: TemporaryStashSlotAssignment {
        TemporaryStashSlotAssignment(id: id, screenID: screenID, edge: edge, slot: slot)
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
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let archive = try? JSONDecoder().decode(Archive.self, from: data) else { return TemporaryStashRecoverySnapshot() }
        var snapshot = archive.snapshot
        var ids: Set<String> = []
        let sameBoot = !bootSessionID.isEmpty && archive.bootSessionID == bootSessionID
        let valid = snapshot.windows.filter { $0.isValid && ids.insert($0.id).inserted }
            .map { sameBoot ? $0 : $0.waitingForRelaunch() }
        snapshot.update(windows: valid)
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

/// Conservative one-to-one matching: size is mandatory; a nearby position may
/// disambiguate equal-size windows, but enumeration order never breaks a tie.
enum TemporaryStashRecoveryMatcher {
    static func uniqueMatches(records: [TemporaryStashRecoveryRecord], frames: [CGRect]) -> [String: Int] {
        var candidates: [[Int]] = records.map { record in
            let sizeMatches = frames.indices.filter {
                abs(frames[$0].width - record.matchingFrame.width) <= 8
                    && abs(frames[$0].height - record.matchingFrame.height) <= 8
            }
            let nearby = sizeMatches.filter { positionMatches(record.matchingFrame, frames[$0]) }
            return sizeMatches.count > 1 && nearby.count == 1 ? nearby : sizeMatches
        }
        // Apply the same positional rule from the window side. Never let two
        // records claim one window just because it is the only size candidate.
        for index in frames.indices {
            let owners = records.indices.filter { candidates[$0].contains(index) }
            let nearby = owners.filter { positionMatches(records[$0].matchingFrame, frames[index]) }
            if owners.count > 1 && nearby.count == 1 {
                for owner in owners where owner != nearby[0] { candidates[owner].removeAll { $0 == index } }
            }
        }
        var result: [String: Int] = [:]
        for index in records.indices {
            guard candidates[index].count == 1, let window = candidates[index].first,
                  candidates.filter({ $0.contains(window) }).count == 1 else { continue }
            result[records[index].id] = window
        }
        return result
    }

    static func replacement(in records: [TemporaryStashRecoveryRecord], frame: CGRect) -> TemporaryStashRecoveryRecord? {
        records.min { sizeDistance($0.matchingFrame, frame) < sizeDistance($1.matchingFrame, frame) }
    }

    private static func sizeDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
    }

    private static func positionMatches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 24 && abs(lhs.minY - rhs.minY) <= 24
    }
}

/// App-level ownership is separate from window geometry and shortcut intent.
/// Old archives have no ownership, so they cannot authorize an unhide.
struct TemporaryStashHiddenAppRecord: Codable, Equatable {
    let pid: Int32
    let bundleID: String
    let launchDate: Date
    let windowIDs: [UInt32]
    let sessionIDs: [String]
    var phase: String

    func matches(pid: Int32, bundleID: String?, launchDate: Date?, windowIDs: Set<UInt32>) -> Bool {
        self.pid == pid && self.bundleID == bundleID && self.launchDate == launchDate
            && ["hideRequested", "hiddenOwned", "revealRequested"].contains(phase)
            && !self.windowIDs.isEmpty && !Set(self.windowIDs).isDisjoint(with: windowIDs)
    }
}

final class TemporaryStashHiddenAppStore {
    static let defaultsKey = "SideBarTemporaryHiddenApplicationsV1"
    private struct Archive: Codable {
        let bootSessionID: String
        let applications: [TemporaryStashHiddenAppRecord]
    }
    private let defaults: Foundation.UserDefaults
    private let bootSessionID: String

    init(defaults: Foundation.UserDefaults = .standard, bootSessionID: String = TemporaryStashRecoveryStore.currentBootSessionID()) {
        self.defaults = defaults
        self.bootSessionID = bootSessionID
    }

    func load() -> [TemporaryStashHiddenAppRecord] {
        guard !bootSessionID.isEmpty, let data = defaults.data(forKey: Self.defaultsKey),
              let archive = try? JSONDecoder().decode(Archive.self, from: data),
              archive.bootSessionID == bootSessionID else { return [] }
        return archive.applications
    }

    func upsert(_ record: TemporaryStashHiddenAppRecord) {
        let saved = load()
        if saved.first(where: { $0.pid == record.pid }) == record { return }
        var records = saved.filter { $0.pid != record.pid }
        records.append(record)
        save(records)
    }

    func remove(pid: Int32) { save(load().filter { $0.pid != pid }) }

    private func save(_ records: [TemporaryStashHiddenAppRecord]) {
        guard let data = try? JSONEncoder().encode(Archive(bootSessionID: bootSessionID, applications: records)) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
        // Flush intent before OS requests so a crash cannot lose our ownership.
        defaults.synchronize()
    }
}
