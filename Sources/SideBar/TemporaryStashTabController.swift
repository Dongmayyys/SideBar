import AppKit

struct TemporaryStashTabDescriptor {
    let session: WindowSession
    let edge: Int
    let screenFrame: CGRect
    let visibleFrame: CGRect
    let centerY: CGFloat
    let title: String
}

/// 快捷键标签独立于设置托管的融合条。每个面板只有标签大小，且不接管点击。
final class TemporaryStashTabCoordinator {
    private struct EdgeKey: Hashable {
        let edge: Int
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
        init(_ descriptor: TemporaryStashTabDescriptor) {
            edge = descriptor.edge
            x = descriptor.screenFrame.minX
            y = descriptor.screenFrame.minY
            width = descriptor.screenFrame.width
            height = descriptor.screenFrame.height
        }
    }

    private var panels: [ObjectIdentifier: TemporaryStashTabWindow] = [:]
    private var hoveredID: ObjectIdentifier?
    private var hoverBeganAt = Date.distantPast
    private weak var pendingAppActivation: WindowSession?

    func handleAppActivation(activatedPID: pid_t, sessions: [WindowSession]) {
        pendingAppActivation = sessions.first { $0.canRevealForTemporaryAppActivation(activatedPID: activatedPID) }
        guard pendingAppActivation != nil else { return }
        hoveredID = nil
        hoverBeganAt = Date()
        reconcile(sessions: sessions)
    }

    func reconcile(sessions: [WindowSession]) {
        let temporary = sessions.filter(\.isManagedByTemporaryShortcut)
        let descriptors = temporary.compactMap { $0.temporaryStashTabDescriptor() }
        let validIDs = Set(descriptors.map { ObjectIdentifier($0.session) })
        for id in Array(panels.keys) where !validIDs.contains(id) {
            panels.removeValue(forKey: id)?.close()
        }

        var hovered: TemporaryStashTabDescriptor?
        let groups = Dictionary(grouping: descriptors, by: EdgeKey.init)
        for members in groups.values {
            let sorted = members.sorted {
                if $0.centerY != $1.centerY { return $0.centerY < $1.centerY }
                return $0.session.temporaryStashID < $1.session.temporaryStashID
            }
            guard let first = sorted.first else { continue }
            let frames = TemporaryStashGeometry.labelFrames(centers: sorted.map(\.centerY),
                                                            edge: first.edge, visibleFrame: first.visibleFrame)
            for (descriptor, frame) in zip(sorted, frames) {
                let id = ObjectIdentifier(descriptor.session)
                let panel = panels[id] ?? TemporaryStashTabWindow()
                panels[id] = panel
                panel.update(frame: frame, title: descriptor.title,
                             expanded: descriptor.session.isExpandedForCoordination)
                if frame.contains(NSEvent.mouseLocation) { hovered = descriptor }
            }
        }

        // 与原跟踪计时器协作：仅在当前标签内暂停该窗口的自动收回。
        // 空隙、同边其他标签、屏幕上其余部分都不在命中区内。
        let newID = hovered.map { ObjectIdentifier($0.session) }
        temporary.forEach { $0.setFusionHoverLock(ObjectIdentifier($0) == newID) }
        if newID != hoveredID {
            hoveredID = newID
            hoverBeganAt = Date()
        }
        if let pending = pendingAppActivation {
            // 前一个窗口暂时无法收回时保留请求，下轮重试前重新核实焦点，避免抢回已转移的焦点。
            if !temporary.contains(where: { $0 === pending }) || !pending.canRevealForTemporaryAppActivation(activatedPID: pending.pid) {
                pendingAppActivation = nil
            } else {
                if let target = descriptors.first(where: { $0.session === pending }),
                   activate(target, among: descriptors, isAppActivated: true) { pendingAppActivation = nil }
                return
            }
        }
        guard let hovered, Date().timeIntervalSince(hoverBeganAt) >= TemporaryStashDefaults.hoverDelay else { return }

        _ = activate(hovered, among: descriptors)
    }

    private func activate(_ target: TemporaryStashTabDescriptor, among descriptors: [TemporaryStashTabDescriptor], isAppActivated: Bool = false) -> Bool {
        // 先同步收回同边所有未固定窗口，再展开目标。AX 暂时不可读/动画中就下轮重试。
        let siblings = descriptors.filter { EdgeKey($0) == EdgeKey(target) && $0.session !== target.session }
        for sibling in siblings where sibling.session.isExpandedForCoordination {
            if !sibling.session.hideForTemporaryStashTab() { return false }
        }
        if !target.session.isExpandedForCoordination { target.session.revealForTemporaryStashTab(isAppActivated: isAppActivated) }
        return target.session.isExpandedForCoordination
    }

    func tearDownAll() {
        panels.values.forEach { $0.close() }
        panels.removeAll()
        hoveredID = nil
        hoverBeganAt = .distantPast
        pendingAppActivation = nil
    }
}

private final class TemporaryStashTabWindow: NSPanel {
    private let label = TemporaryStashTabView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        ignoresMouseEvents = true
        contentView = label
    }

    func update(frame: CGRect, title: String, expanded: Bool) {
        if self.frame != frame { setFrame(frame, display: true) }
        if label.title != title || label.expanded != expanded {
            label.title = title
            label.expanded = expanded
            label.needsDisplay = true
        }
        orderFrontRegardless()
    }
}

private final class TemporaryStashTabView: NSView {
    var title = ""
    var expanded = false

    override func draw(_ dirtyRect: NSRect) {
        (expanded ? NSColor(white: 0.32, alpha: 1) : NSColor.black).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        let capacity = max(1, Int((bounds.height - 2 * TemporaryStashDefaults.textPadding) / TemporaryStashDefaults.lineHeight))
        var characters = Array(title)
        if characters.count > capacity { characters = Array(characters.prefix(capacity - 1)) + ["…"] }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: TemporaryStashDefaults.fontSize),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style
        ]
        let top = bounds.midY + CGFloat(characters.count) * TemporaryStashDefaults.lineHeight / 2
        for (index, character) in characters.enumerated() {
            let rect = CGRect(x: 0, y: top - CGFloat(index + 1) * TemporaryStashDefaults.lineHeight,
                              width: bounds.width, height: TemporaryStashDefaults.lineHeight)
            (String(character) as NSString).draw(in: rect, withAttributes: attributes)
        }
    }
}
