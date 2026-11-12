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

    static func nearestEdge(window: CGRect, screen: CGRect, visibleWidth: CGFloat, screens: [CGRect]) -> Int? {
        let leftAvailable = !hasAdjacentScreen(edge: 1, screen: screen, screens: screens)
        let rightAvailable = !hasAdjacentScreen(edge: 2, screen: screen, screens: screens)
        guard leftAvailable || rightAvailable else { return nil }
        if !rightAvailable { return 1 }
        if !leftAvailable { return 2 }
        let leftDistance = abs(window.minX - screen.minX)
        let rightDistance = abs(screen.maxX - window.maxX)
        if window.width >= visibleWidth - 40 || abs(leftDistance - rightDistance) <= 20 { return 2 }
        return leftDistance < rightDistance ? 1 : 2
    }

    static func recoveryEdge(savedEdge: Int?, window: CGRect, screen: CGRect,
                             visibleWidth: CGFloat, screens: [CGRect]) -> Int? {
        if let savedEdge, !hasAdjacentScreen(edge: savedEdge, screen: screen, screens: screens) {
            return savedEdge
        }
        return nearestEdge(window: window, screen: screen, visibleWidth: visibleWidth, screens: screens)
    }

    static func restorePosition(original: CGRect, expanded: CGRect, screens: [CGRect]) -> CGPoint {
        let isVisible = screens.contains {
            let overlap = $0.intersection(original)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0
        }
        return isVisible ? original.origin : expanded.origin
    }

    /// 列表从上到下排列（AppKit 的 y 向上）；整列居中，与窗口几何无关。
    static func labelFrames(count: Int, edge: Int, visibleFrame: CGRect) -> [CGRect] {
        let height = TemporaryStashDefaults.labelHeight
        let stride = height + TemporaryStashDefaults.labelGap
        let totalHeight = CGFloat(count) * height + CGFloat(max(0, count - 1)) * TemporaryStashDefaults.labelGap
        return (0..<count).map { index in
            CGRect(x: edge == 1 ? visibleFrame.minX : visibleFrame.maxX - TemporaryStashDefaults.labelWidth,
                   y: visibleFrame.midY + totalHeight / 2 - height - CGFloat(index) * stride,
                   width: TemporaryStashDefaults.labelWidth, height: height)
        }
    }

    static func draggedFrame(initial: CGRect, deltaY: CGFloat, column: CGRect) -> CGRect {
        CGRect(x: initial.minX, y: min(max(initial.minY + deltaY, column.minY), column.maxY - initial.height),
               width: initial.width, height: initial.height)
    }

    /// 松手中心落在哪个槽位就插入该序号；原列包含被拖项，跨过槽位中线时换位。
    static func insertionIndex(centerY: CGFloat, columnFrames: [CGRect]) -> Int {
        guard let first = columnFrames.first else { return 0 }
        let stride = TemporaryStashDefaults.labelHeight + TemporaryStashDefaults.labelGap
        let index = Int(((first.midY - centerY) / stride).rounded())
        return min(max(index, 0), columnFrames.count - 1)
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
