import Foundation
import CoreGraphics

/// 快捷键标签的原型参数集中在这里；不处理一条边排不下的情况。
enum TemporaryStashDefaults {
    static let labelWidth: CGFloat = 24
    static let labelHeight: CGFloat = 120
    static let fontSize: CGFloat = 12
    static let lineHeight: CGFloat = 15
    static let textPadding: CGFloat = 8
    static let hoverDelay: TimeInterval = 0.18
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

    static func nearestEdge(window: CGRect, screen: CGRect, screens: [CGRect]) -> Int? {
        [1, 2].filter { !hasAdjacentScreen(edge: $0, screen: screen, screens: screens) }
            .min { left, right in
                let lhs = left == 1 ? abs(window.minX - screen.minX) : abs(screen.maxX - window.maxX)
                let rhs = right == 1 ? abs(window.minX - screen.minX) : abs(screen.maxX - window.maxX)
                return lhs < rhs
            }
    }

    static func restorePosition(original: CGRect, expanded: CGRect, screens: [CGRect]) -> CGPoint {
        let isVisible = screens.contains {
            let overlap = $0.intersection(original)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0
        }
        return isVisible ? original.origin : expanded.origin
    }

    /// 输入按窗口中心从低到高排序（AppKit 坐标）；只移动产生冲突的相邻块。
    /// 对 center[i] - i * height 做 pooled-adjacent-violators，成对碰撞各推一半；
    /// 连锁碰撞合并成块；给变换后的块施加共同上下界，保证整个标签在可用区域内。
    /// 可用区域装不下全部标签时不增加溢出机制。
    static func labelFrames(centers: [CGFloat], edge: Int, visibleFrame: CGRect) -> [CGRect] {
        let height = TemporaryStashDefaults.labelHeight
        struct Block { var start: Int; var count: Int; var mean: CGFloat }
        var blocks: [Block] = []
        for (index, center) in centers.enumerated() {
            blocks.append(Block(start: index, count: 1, mean: center - CGFloat(index) * height))
            while blocks.count >= 2 && blocks[blocks.count - 2].mean > blocks[blocks.count - 1].mean {
                let last = blocks.removeLast()
                let prior = blocks.removeLast()
                let count = prior.count + last.count
                blocks.append(Block(start: prior.start, count: count,
                                    mean: (prior.mean * CGFloat(prior.count) + last.mean * CGFloat(last.count)) / CGFloat(count)))
            }
        }
        let lower = visibleFrame.minY + height / 2
        let upper = visibleFrame.maxY - height / 2 - CGFloat(max(0, centers.count - 1)) * height
        var result = Array(repeating: CGRect.zero, count: centers.count)
        for block in blocks {
            let base = lower <= upper ? min(max(block.mean, lower), upper) : block.mean
            for index in block.start..<(block.start + block.count) {
                result[index] = CGRect(x: edge == 1 ? visibleFrame.minX : visibleFrame.maxX - TemporaryStashDefaults.labelWidth,
                                       y: base + CGFloat(index) * height - height / 2,
                                       width: TemporaryStashDefaults.labelWidth, height: height)
            }
        }
        return result
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
