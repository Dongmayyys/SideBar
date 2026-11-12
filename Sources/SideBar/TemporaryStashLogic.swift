import Foundation
import CoreGraphics

/// 快捷键标签的原型参数集中在这里；不处理一条边排不下的情况。
enum TemporaryStashDefaults {
    static let labelWidth: CGFloat = 18
    static let labelHeight: CGFloat = 120
    static let fontSize: CGFloat = 11
    static let lineHeight: CGFloat = 15
    static let textPadding: CGFloat = 8
    static let labelGap: CGFloat = 4
    static let screenAdjacencyTolerance: CGFloat = 5
}

enum TemporaryStashShortcutAction: Equatable {
    case stash, cancel, ignore

    static func resolve(isConfiguredApp: Bool, isManaged: Bool, isExpanded: Bool) -> Self {
        // 已收纳的会话即使后来启用了软件设置，仍允许独立取消。
        if isManaged { return isExpanded ? .cancel : .ignore }
        return isConfiguredApp ? .ignore : .stash
    }
}

enum TemporaryStashGeometry {
    /// 输入全部使用同一全局坐标系。任意正长度的竖直交叠都会封锁整条边。
    static func hasAdjacentScreen(edge: Int, screen: CGRect, screens: [CGRect]) -> Bool {
        screens.contains { other in
            guard other != screen, other.minY < screen.maxY, other.maxY > screen.minY else { return false }
            let distance = edge == 1 ? other.maxX - screen.minX : other.minX - screen.maxX
            return abs(distance) <= TemporaryStashDefaults.screenAdjacencyTolerance
        }
    }

    static func preferredEdge(screen: CGRect, screens: [CGRect]) -> Int? {
        if !hasAdjacentScreen(edge: 2, screen: screen, screens: screens) { return 2 }
        if !hasAdjacentScreen(edge: 1, screen: screen, screens: screens) { return 1 }
        return nil
    }

    static func recoveryEdge(savedEdge: Int?, screen: CGRect, screens: [CGRect]) -> Int? {
        if let savedEdge, (savedEdge == 1 || savedEdge == 2),
           !hasAdjacentScreen(edge: savedEdge, screen: screen, screens: screens) { return savedEdge }
        return preferredEdge(screen: screen, screens: screens)
    }

    static func restorePosition(original: CGRect, expanded: CGRect, screens: [CGRect]) -> CGPoint {
        let isVisible = screens.contains {
            let overlap = $0.intersection(original)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0
        }
        return isVisible ? original.origin : expanded.origin
    }

    static func slotCapacity(visibleFrame: CGRect) -> Int {
        max(0, Int((visibleFrame.height + TemporaryStashDefaults.labelGap)
            / (TemporaryStashDefaults.labelHeight + TemporaryStashDefaults.labelGap)))
    }

    static func slotFrame(slot: Int, edge: Int, visibleFrame: CGRect) -> CGRect? {
        guard slot > 0, slot <= slotCapacity(visibleFrame: visibleFrame) else { return nil }
        return CGRect(x: edge == 1 ? visibleFrame.minX : visibleFrame.maxX - TemporaryStashDefaults.labelWidth,
                      y: visibleFrame.maxY - TemporaryStashDefaults.labelHeight
                        - CGFloat(slot - 1) * (TemporaryStashDefaults.labelHeight + TemporaryStashDefaults.labelGap),
                      width: TemporaryStashDefaults.labelWidth, height: TemporaryStashDefaults.labelHeight)
    }

    static func slot(at point: CGPoint, edge: Int, visibleFrame: CGRect, count: Int) -> Int? {
        (1...max(1, count)).first { slot in
            slot <= count && slotFrame(slot: slot, edge: edge, visibleFrame: visibleFrame)?.contains(point) == true
        }
    }
}

struct TemporaryStashSlotAssignment: Codable, Equatable {
    let id: String
    let screenID: UInt32
    let edge: Int
    var slot: Int
    // nil is the shared all-desktops column (unknown or multiple Spaces).
    var spaceID: UInt64? = nil

    func sharesColumn(with other: Self) -> Bool {
        screenID == other.screenID && edge == other.edge && spaceID == other.spaceID
    }

    func conflicts(with other: Self) -> Bool {
        screenID == other.screenID && edge == other.edge
            && (spaceID == nil || other.spaceID == nil || spaceID == other.spaceID)
    }

    static func singleSpace(in spaces: Set<UInt64>?) -> UInt64? {
        guard let spaces, spaces.count == 1, let id = spaces.first, id > 0 else { return nil }
        return id
    }
}

enum TemporaryStashSlots {
    static func allocate(preferred: Int = 0, occupied: Set<Int>, capacity: Int = Int.max - 1) -> Int? {
        if preferred > 0 && preferred <= capacity && !occupied.contains(preferred) { return preferred }
        var slot = 1
        while slot <= capacity && occupied.contains(slot) { slot += 1 }
        return slot <= capacity ? slot : nil
    }

    /// Existing residents claim their slots before windows arriving from another column.
    static func resolve(existing: [TemporaryStashSlotAssignment], requested: [TemporaryStashSlotAssignment]) -> [TemporaryStashSlotAssignment] {
        let residents = requested.filter { item in existing.contains { $0.id == item.id && $0.sharesColumn(with: item) } }
        let arrivals = requested.filter { item in !residents.contains { $0.id == item.id } }
        var resolved: [TemporaryStashSlotAssignment] = []
        for var item in residents + arrivals {
            let previous = existing.first { $0.id == item.id }
            let occupied = Set(resolved.filter { $0.conflicts(with: item) }.map(\.slot))
            item.slot = allocate(preferred: item.slot > 0 ? item.slot : previous?.slot ?? 0, occupied: occupied) ?? 0
            resolved.append(item)
        }
        return requested.compactMap { item in resolved.first { $0.id == item.id } }
    }

    static func move(id: String, to slot: Int, assignments: [TemporaryStashSlotAssignment],
                     capacity: Int = Int.max - 1) -> [TemporaryStashSlotAssignment] {
        guard slot > 0, slot <= capacity, var source = assignments.first(where: { $0.id == id }) else { return assignments }
        let oldSlot = source.slot
        source.slot = slot
        let targets = assignments.filter { $0.id != id && $0.conflicts(with: source) && $0.slot == slot }
        let swapped = targets.map { item in
            var item = item
            item.slot = oldSlot
            return item
        }
        // A shared label may swap with several desktop-local labels. If a local
        // label swaps with a shared one, reserve the shared destination before
        // resolving other desktops' residents at that same slot.
        let untouched = assignments.filter { $0.id != id && !targets.contains($0) }
        let resolved = resolve(existing: [], requested: [source] + swapped + untouched)
        guard resolved.allSatisfy({ item in
            item.slot <= capacity || assignments.first(where: { $0.id == item.id })?.slot == item.slot
        }) else { return assignments }
        return assignments.compactMap { item in resolved.first { $0.id == item.id } }
    }
}

/// AX 与 CG 的位置更新可能不同步；持续离屏才隐藏，回屏立即恢复。
struct TemporaryStashVisibility {
    private var offscreenSince: TimeInterval?

    mutating func isVisible(isOnScreen: Bool, now: TimeInterval) -> Bool {
        if isOnScreen {
            offscreenSince = nil
            return true
        }
        let since = offscreenSince ?? now
        offscreenSince = since
        return now - since < 0.3
    }

    /// 切换 Space 或屏幕配置后坐标不会滞后，下一次离屏判定立即隐藏。
    mutating func expireDebounce() {
        offscreenSince = -.infinity
    }
}

/// 序号属于本次收纳，不因其他窗口离开而重排；最后一个离开后开始新一轮。
struct TemporaryStashOrdinals {
    private var members: [String: [String: Int]] = [:]
    private var next: [String: Int] = [:]

    func hasMembers(bundleID: String) -> Bool { members[bundleID]?.isEmpty == false }

    mutating func assign(bundleID: String, windowID: String) -> Int {
        if let existing = members[bundleID]?[windowID] { return existing }
        let ordinal = next[bundleID, default: 1]
        members[bundleID, default: [:]][windowID] = ordinal
        next[bundleID] = ordinal + 1
        return ordinal
    }

    mutating func reserve(bundleID: String, windowID: String, ordinal: Int) {
        members[bundleID, default: [:]][windowID] = ordinal
        next[bundleID] = max(next[bundleID, default: 1], ordinal + 1)
    }

    mutating func release(bundleID: String, windowID: String) {
        members[bundleID]?[windowID] = nil
        if members[bundleID]?.isEmpty == true {
            members[bundleID] = nil
            next[bundleID] = nil
        }
    }

    static func title(appName: String, ordinal: Int) -> String {
        ordinal == 1 ? appName : "\(appName) \(ordinal)"
    }
}
