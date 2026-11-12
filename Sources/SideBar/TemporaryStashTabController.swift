import AppKit

struct TemporaryStashTabDescriptor {
    let session: WindowSession
    let edge: Int
    let screenID: UInt32
    let visibleFrame: CGRect
    let isOnScreen: Bool
    let title: String
}

enum TemporaryStashTabEvent {
    case hover, down(CGPoint), dragged(CGPoint), up(CGPoint)
}

enum TemporaryStashToggleResult {
    case collapsed, revealed, unchanged
}

/// 快捷键标签独立于设置托管的融合条，面板只占标签本身的命中区域。
final class TemporaryStashTabCoordinator {
    private struct EdgeKey: Hashable {
        let edge: Int
        let screenID: UInt32
        init(_ descriptor: TemporaryStashTabDescriptor) {
            edge = descriptor.edge
            screenID = descriptor.screenID
        }
    }

    private struct Drag {
        let id: ObjectIdentifier
        let key: EdgeKey
        let start: CGPoint
        let initialFrame: CGRect
        let visibleFrame: CGRect
        let slotCount: Int
        let assignments: [TemporaryStashSlotAssignment]
        var frame: CGRect
        var moved = false
        var cancelled = false
    }

    var onSlotsChanged: (([TemporaryStashSlotAssignment]) -> Void)?
    private var assignments: [TemporaryStashSlotAssignment] = []
    private var pendingRecoveryIDs: Set<String> = []
    private var slotPanels: [Int: TemporaryStashTabWindow] = [:]

    func restoreSlots(_ assignments: [TemporaryStashSlotAssignment], pendingIDs: Set<String> = []) {
        self.assignments = assignments
        pendingRecoveryIDs = pendingIDs
    }

    func suppressRestoredHover(for session: WindowSession) {
        hoverSuppressedUntilExit.insert(ObjectIdentifier(session))
    }

    private var panels: [ObjectIdentifier: TemporaryStashTabWindow] = [:]
    private var visibility: [ObjectIdentifier: TemporaryStashVisibility] = [:]
    private var layoutFrames: [ObjectIdentifier: CGRect] = [:]
    private var drag: Drag?
    private var sessions: [WindowSession] = []
    private var isReconciling = false
    private var hoveredID: ObjectIdentifier?
    private var hoverBeganAt = Date.distantPast
    private var hoverTimer: Timer?
    private var hoverSuppressedUntilExit: Set<ObjectIdentifier> = []
    private weak var pendingAppActivation: WindowSession?
    // 只限制等待 Workspace 前台更新的时间；前台到位后的 AX 忙沿用原有重试。
    private var appActivationDeadline: Date?
    private var appActivationRetryTimer: Timer?
    private var recentExpandedIDs: [String] = []

    func rememberExpansion(of session: WindowSession) {
        guard session.isManagedByTemporaryShortcut else { return }
        recentExpandedIDs.removeAll { $0 == session.temporaryStashID }
        recentExpandedIDs.append(session.temporaryStashID)
    }

    func toggleMainInterface(sessions: [WindowSession]) -> TemporaryStashToggleResult {
        resetAppActivation()
        resetHover()
        // 快捷键优先于鼠标当前所在标签，移出再移入后才恢复悬停。
        for (id, frame) in layoutFrames where frame.contains(NSEvent.mouseLocation) {
            hoverSuppressedUntilExit.insert(id)
        }
        let managed = sessions.filter(\.isManagedByTemporaryShortcut)
        let expanded = managed.filter { $0.isExpandedForCoordination && !$0.isTemporaryPinnedForFusion() }
        if !expanded.isEmpty {
            var allCollapsed = true
            for session in expanded {
                if !session.hideForTemporaryStashTab() { allCollapsed = false }
            }
            return allCollapsed ? .collapsed : .unchanged
        }

        let descriptors = managed.compactMap { $0.temporaryStashTabDescriptor() }.filter(\.isOnScreen)
        for id in recentExpandedIDs.reversed() {
            guard let target = descriptors.first(where: { $0.session.temporaryStashID == id }) else { continue }
            // 当前可见性直接读取会话，不使用标签离屏去抖后的缓存。
            guard activate(target, among: descriptors, waitForInteraction: true) else { return .unchanged }
            if target.session.isTemporaryPinnedForFusion() { target.session.focusForTemporaryStashTab() }
            return .revealed
        }
        return .unchanged
    }

    func handleAppActivation(activatedPID: pid_t, activationPolicy: NSApplication.ActivationPolicy, sessions: [WindowSession]) {
        resetAppActivation()
        guard activationPolicy == .regular,
              activatedPID != ProcessInfo.processInfo.processIdentifier,
              !WindowSession.shouldIgnoreTemporaryAppActivation(activatedPID: activatedPID) else { return }
        // 只在 Workspace 激活通知中执行；不依赖可能滞后的 frontmostApplication。
        for session in sessions where session.isManagedByTemporaryShortcut
            && session.pid != activatedPID && session.isExpandedForCoordination {
            if session.hideForTemporaryAppActivation(activatedPID: activatedPID) {
                let id = ObjectIdentifier(session)
                if layoutFrames[id]?.contains(NSEvent.mouseLocation) == true {
                    hoverSuppressedUntilExit.insert(id)
                }
                resetHover()
            }
        }
        let candidates = sessions.filter { $0.isManagedByTemporaryShortcut && $0.pid == activatedPID }
        if !candidates.isEmpty {
            StashDebugLog.write("activation pid=\(activatedPID)")
            candidates.forEach { StashDebugLog.write("  candidate \($0.temporaryActivationDiagnostics(activatedPID: activatedPID))") }
        }
        // 激活通知先于 frontmostApplication 更新时，仍记录满足其他门槛的目标。
        pendingAppActivation = sessions.first {
            $0.canRevealForTemporaryAppActivation(activatedPID: activatedPID, requiresFrontmost: false)
        }
        if !candidates.isEmpty { StashDebugLog.write("  pending=\(pendingAppActivation.map { "\($0.temporaryStashID.prefix(8))" } ?? "none")") }
        guard pendingAppActivation != nil else { return }
        appActivationDeadline = Date().addingTimeInterval(0.6)
        resetHover()
        reconcile(sessions: sessions)
    }

    func reconcileAfterSpaceChange(sessions: [WindowSession]) {
        for id in panels.keys { visibility[id, default: TemporaryStashVisibility()].expireDebounce() }
        reconcile(sessions: sessions)
    }

    func reconcile(sessions: [WindowSession]) {
        guard !isReconciling else { return }
        isReconciling = true
        defer {
            isReconciling = false
            scheduleAppActivationRetry()
        }
        self.sessions = sessions.filter(\.isManagedByTemporaryShortcut)
        let liveIDs = Set(self.sessions.map(\.temporaryStashID))
        recentExpandedIDs.removeAll { !liveIDs.contains($0) }
        let now = Date()
        if let pending = pendingAppActivation {
            let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pending.pid
            let waitExpired = appActivationDeadline.map { now >= $0 } ?? true
            if !self.sessions.contains(where: { $0 === pending })
                || !pending.canRevealForTemporaryAppActivation(activatedPID: pending.pid, requiresFrontmost: false)
                || (!isFrontmost && waitExpired) {
                StashDebugLog.write("  pending dropped \(pending.temporaryActivationDiagnostics(activatedPID: pending.pid))")
                resetAppActivation()
            } else if isFrontmost {
                // 此后前台若转走就放弃，不再把它视作 Workspace 更新延迟。
                appActivationDeadline = nil
            }
        }
        // 面板在按住期间离屏/关闭时可能丢失 mouseUp，由轮询补齐松手收尾。
        if let drag, NSEvent.pressedMouseButtons & 1 == 0 {
            handle(.up(NSEvent.mouseLocation), id: drag.id)
        }
        let descriptors = self.sessions.compactMap { $0.temporaryStashTabDescriptor() }
        let managedIDs = Set(self.sessions.map(ObjectIdentifier.init))
        // 只有离开管理才销毁；切换 Space、全屏遮挡或 AX 暂时读不到都保留面板和顺序。
        for id in Array(panels.keys) where !managedIDs.contains(id) {
            panels.removeValue(forKey: id)?.close()
            visibility[id] = nil
        }
        // Waiting records reserve slots without creating panels or hit targets.
        let stableIDs = Set(self.sessions.map(\.temporaryStashID))
        let existing = assignments.filter { stableIDs.contains($0.id) || pendingRecoveryIDs.contains($0.id) }
        var requested = existing.filter { pendingRecoveryIDs.contains($0.id) && !stableIDs.contains($0.id) }
        requested += descriptors.map { descriptor in
            TemporaryStashSlotAssignment(id: descriptor.session.temporaryStashID, screenID: descriptor.screenID,
                                        edge: descriptor.edge, slot: descriptor.session.temporaryStashSlot)
        }
        // A transient missing descriptor must not release an established live slot.
        requested += existing.filter { item in !requested.contains { $0.id == item.id } }
        assignments = TemporaryStashSlots.resolve(existing: existing, requested: requested)
        for session in self.sessions {
            if let assignment = assignments.first(where: { $0.id == session.temporaryStashID }) {
                session.temporaryStashSlot = assignment.slot
            }
        }

        let visible = descriptors.filter { descriptor in
            let id = ObjectIdentifier(descriptor.session)
            return visibility[id, default: TemporaryStashVisibility()].isVisible(
                isOnScreen: descriptor.isOnScreen, now: now.timeIntervalSinceReferenceDate)
        }
        let previousFrames = layoutFrames
        layoutFrames.removeAll()
        for descriptor in visible {
            guard let assignment = assignments.first(where: { $0.id == descriptor.session.temporaryStashID }),
                  let frame = TemporaryStashGeometry.slotFrame(slot: assignment.slot, edge: descriptor.edge,
                                                               visibleFrame: descriptor.visibleFrame) else { continue }
            layoutFrames[ObjectIdentifier(descriptor.session)] = frame
        }
        for (id, panel) in panels where layoutFrames[id] == nil { panel.orderOut(nil) }
        // 成员或屏幕几何变化时取消本次拖动，避免用过期的列范围插入。
        if let current = drag, previousFrames != layoutFrames || current.assignments != assignments {
            drag?.cancelled = true
            resetHover()
        }
        updateSlotPlaceholders()
        for descriptor in visible {
            let id = ObjectIdentifier(descriptor.session)
            guard let frame = layoutFrames[id] else { continue }
            let panel = panels[id] ?? TemporaryStashTabWindow()
            panels[id] = panel
            panel.onEvent = { [weak self] event in self?.handle(event, id: id) }
            var displayFrame = frame
            if let drag, drag.id == id, !drag.cancelled { displayFrame = drag.frame }
            panel.update(frame: displayFrame, title: descriptor.title,
                         expanded: descriptor.session.isExpandedForCoordination)
        }

        hoverSuppressedUntilExit = hoverSuppressedUntilExit.filter {
            layoutFrames[$0]?.contains(NSEvent.mouseLocation) == true
        }
        // 按住标签期间锁住全部快捷键会话的悬停展开/鼠标收回；激活通知仍可收回。
        if let drag {
            if !drag.cancelled { panels[drag.id]?.orderFrontRegardless() }
            self.sessions.forEach { $0.setFusionHoverLock(true) }
            return
        }
        let hovered = visible.first { layoutFrames[ObjectIdentifier($0.session)]?.contains(NSEvent.mouseLocation) == true }
        let newID = hovered.map { ObjectIdentifier($0.session) }
        self.sessions.forEach { $0.setFusionHoverLock(ObjectIdentifier($0) == newID) }
        if newID != hoveredID {
            resetHover()
            hoveredID = newID
            hoverBeganAt = now
        }
        if let pending = pendingAppActivation {
            // 尚未成为前台时只等待；AX 忙/同边收回失败也保留请求供下一次重查。
            if pending.canRevealForTemporaryAppActivation(activatedPID: pending.pid) {
                let target = visible.first(where: { $0.session === pending })
                let activated = target.map { activate($0, among: visible, isAppActivated: true) } ?? false
                StashDebugLog.write("  pending activate visible=\(target != nil) result=\(activated)")
                if activated { resetAppActivation() }
            }
            return
        }
        guard let hovered, !hoverSuppressedUntilExit.contains(ObjectIdentifier(hovered.session)) else { return }
        let remaining = Double(AppConfig.shared.hoverDelayMS) / 1000 - now.timeIntervalSince(hoverBeganAt)
        if remaining <= 0 {
            hoverTimer?.invalidate()
            hoverTimer = nil
            _ = activate(hovered, among: visible)
        } else if hoverTimer == nil {
            // tracking area 立即开始计时；轮询仍负责离屏校准和失败重试。
            let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.hoverTimer = nil
                self.reconcile(sessions: self.sessions)
            }
            hoverTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func handle(_ event: TemporaryStashTabEvent, id: ObjectIdentifier) {
        switch event {
        case .hover:
            reconcile(sessions: sessions)
        case .down(let point):
            guard drag == nil, let frame = layoutFrames[id], frame.contains(point),
                  let descriptor = sessions.first(where: { ObjectIdentifier($0) == id })?.temporaryStashTabDescriptor() else { return }
            let key = EdgeKey(descriptor)
            let highest = assignments.filter { $0.screenID == key.screenID && $0.edge == key.edge }.map(\.slot).max() ?? 0
            let count = min(highest + 1, TemporaryStashGeometry.slotCapacity(visibleFrame: descriptor.visibleFrame))
            drag = Drag(id: id, key: key, start: point, initialFrame: frame, visibleFrame: descriptor.visibleFrame,
                        slotCount: count, assignments: assignments, frame: frame)
            resetHover()
            reconcile(sessions: sessions)
        case .dragged(let point):
            guard drag?.id == id else { return }
            updateDrag(at: point)
            reconcile(sessions: sessions)
        case .up(let point):
            guard drag?.id == id else { return }
            updateDrag(at: point)
            guard let current = drag else { return }
            if current.moved && !current.cancelled,
               let slot = TemporaryStashGeometry.slot(at: point, edge: current.key.edge,
                                                     visibleFrame: current.visibleFrame, count: current.slotCount),
               let session = sessions.first(where: { ObjectIdentifier($0) == id }) {
                assignments = TemporaryStashSlots.move(id: session.temporaryStashID, to: slot, assignments: assignments)
                for session in sessions {
                    session.temporaryStashSlot = assignments.first { $0.id == session.temporaryStashID }?.slot ?? session.temporaryStashSlot
                }
                onSlotsChanged?(assignments)
            }
            drag = nil
            resetHover()
            reconcile(sessions: sessions)
        }
    }

    private func updateDrag(at point: CGPoint) {
        guard var current = drag, !current.cancelled else { return }
        let delta = point.y - current.start.y
        current.moved = current.moved || abs(delta) >= 3 || abs(point.x - current.start.x) >= 3
        if current.moved { current.frame = current.initialFrame.offsetBy(dx: 0, dy: delta) }
        drag = current
    }

    private func updateSlotPlaceholders() {
        guard let drag, !drag.cancelled else {
            slotPanels.values.forEach { $0.close() }
            slotPanels.removeAll()
            return
        }
        for slot in 1...max(1, drag.slotCount) {
            guard slot <= drag.slotCount,
                  let frame = TemporaryStashGeometry.slotFrame(slot: slot, edge: drag.key.edge, visibleFrame: drag.visibleFrame) else { continue }
            let panel = slotPanels[slot] ?? TemporaryStashTabWindow()
            slotPanels[slot] = panel
            panel.update(frame: frame, title: "", expanded: false, isPlaceholder: true)
        }
    }

    private func resetHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoveredID = nil
        hoverBeganAt = .distantPast
    }

    private func resetAppActivation() {
        appActivationRetryTimer?.invalidate()
        appActivationRetryTimer = nil
        pendingAppActivation = nil
        appActivationDeadline = nil
    }

    private func scheduleAppActivationRetry() {
        guard pendingAppActivation != nil else {
            resetAppActivation()
            return
        }
        guard appActivationRetryTimer == nil else { return }
        let timer = Timer(timeInterval: 0.04, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.appActivationRetryTimer = nil
            self.reconcile(sessions: self.sessions)
        }
        appActivationRetryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func activate(_ target: TemporaryStashTabDescriptor, among descriptors: [TemporaryStashTabDescriptor], isAppActivated: Bool = false, waitForInteraction: Bool = false) -> Bool {
        let siblings = descriptors.filter { EdgeKey($0) == EdgeKey(target) && $0.session !== target.session }
        for sibling in siblings where sibling.session.isExpandedForCoordination {
            if !sibling.session.hideForTemporaryStashTab() { return false }
        }
        // 同边窗口收回可能经过 AX 调用；真正展开前再次确认前台及其余门槛。
        if isAppActivated && !target.session.canRevealForTemporaryAppActivation(activatedPID: target.session.pid) { return false }
        if !target.session.isExpandedForCoordination {
            target.session.revealForTemporaryStashTab(isAppActivated: isAppActivated || waitForInteraction)
            if target.session.isExpandedForCoordination { rememberExpansion(of: target.session) }
        }
        return target.session.isExpandedForCoordination
    }

    func tearDownAll() {
        panels.values.forEach { $0.close() }
        panels.removeAll()
        assignments.removeAll()
        pendingRecoveryIDs.removeAll()
        slotPanels.values.forEach { $0.close() }
        slotPanels.removeAll()
        visibility.removeAll()
        layoutFrames.removeAll()
        hoverSuppressedUntilExit.removeAll()
        sessions.removeAll()
        recentExpandedIDs.removeAll()
        drag = nil
        resetHover()
        resetAppActivation()
    }
}

private final class TemporaryStashTabWindow: NSPanel {
    private let label = TemporaryStashTabView()
    var onEvent: ((TemporaryStashTabEvent) -> Void)? {
        didSet { label.onEvent = onEvent }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        contentView = label
    }

    func update(frame: CGRect, title: String, expanded: Bool, isPlaceholder: Bool = false) {
        if self.frame != frame { setFrame(frame, display: true) }
        ignoresMouseEvents = isPlaceholder
        if label.title != title || label.expanded != expanded || label.isPlaceholder != isPlaceholder {
            label.isPlaceholder = isPlaceholder
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
    var isPlaceholder = false
    var onEvent: ((TemporaryStashTabEvent) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onEvent?(.hover) }
    override func mouseExited(with event: NSEvent) { onEvent?(.hover) }
    override func mouseDown(with event: NSEvent) { onEvent?(.down(NSEvent.mouseLocation)) }
    override func mouseDragged(with event: NSEvent) { onEvent?(.dragged(NSEvent.mouseLocation)) }
    override func mouseUp(with event: NSEvent) { onEvent?(.up(NSEvent.mouseLocation)) }

    override func draw(_ dirtyRect: NSRect) {
        if isPlaceholder {
            NSColor.white.withAlphaComponent(0.3).setStroke()
            NSColor.black.withAlphaComponent(0.12).setFill()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            path.fill()
            path.stroke()
            return
        }
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
