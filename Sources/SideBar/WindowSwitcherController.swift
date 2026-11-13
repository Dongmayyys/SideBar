import AppKit
import ApplicationServices

final class WindowSwitcherController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let excludedWindowIDs: () -> Set<CGWindowID>
    private let system = WindowSwitcherSystem()
    private let panel = WindowSwitcherPanel()
    private let input = NSTextField()
    private let table = WindowSwitcherTable()
    private let status = NSTextField(labelWithString: "")
    private var inventory = WindowSwitcherInventory()
    private var recency = WindowSwitcherRecency()
    private var focusedID: CGWindowID?
    private var rows: [WindowSwitcherRow] = []
    private var selection = WindowSwitcherSelection()
    private var screenFrame: CGRect?
    private var appObservers: [pid_t: AXObserver] = [:]
    private var notifications: [NSObjectProtocol] = []
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var stopped = false

    init(excludedWindowIDs: @escaping () -> Set<CGWindowID>) {
        self.excludedWindowIDs = excludedWindowIDs
        super.init()
        configurePanel()
        recency.seed(stackingOrder: WindowSwitcherSystem.windowInfo().compactMap {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        })
        let center = NSWorkspace.shared.notificationCenter
        notifications.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if self.panel.isVisible { self.close() }
            self.observe(app)
            self.recordFocus(app.processIdentifier)
        })
        notifications.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.observe(app) }
        })
        notifications.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.removeObserver(app.processIdentifier) }
        })
        for app in NSWorkspace.shared.runningApplications { observe(app) }
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { recordFocus(pid) }
    }

    func toggle() {
        guard !stopped else { return }
        if panel.isVisible { close(); return }
        focusedID = nil
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { recordFocus(pid) }
        input.stringValue = ""
        // Keep the same screen/top anchor while typing or receiving incremental inventory updates.
        screenFrame = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame
        // Do not offer stale windows from a previous invocation while this snapshot is being refreshed.
        inventory = WindowSwitcherInventory()
        updateResults(preservingSelection: false)
        status.stringValue = "正在读取窗口…".localized
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(input)
        installMouseMonitors()
        system.enumerate { [weak self] snapshot in
            guard let self, self.panel.isVisible else { return }
            self.inventory = snapshot
            if !snapshot.liveIDs.isEmpty { self.recency.retain(snapshot.liveIDs) }
            self.updateResults()
        }
    }

    func close() {
        system.cancel()
        panel.orderOut(nil)
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor); self.globalMouseMonitor = nil }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor); self.localMouseMonitor = nil }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        close()
        for pid in Array(appObservers.keys) { removeObserver(pid) }
        for token in notifications { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        notifications.removeAll()
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != ProcessInfo.processInfo.processIdentifier, appObservers[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            let owner = Unmanaged<WindowSwitcherController>.fromOpaque(context).takeUnretainedValue()
            if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { owner.recordFocus(pid) }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.025)
        let result = AXObserverAddNotification(observer, element, kAXFocusedWindowChangedNotification as CFString,
                                               Unmanaged.passUnretained(self).toOpaque())
        guard result == .success || result == .notificationAlreadyRegistered else { return }
        appObservers[pid] = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func removeObserver(_ pid: pid_t) {
        guard let observer = appObservers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func recordFocus(_ pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier,
              let id = WindowSwitcherSystem.focusedID(pid: pid) else { return }
        focusedID = id
        recency.recordFocus(id)
        if panel.isVisible { updateResults() }
    }

    private func configurePanel() {
        panel.delegate = self
        panel.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        panel.contentView = background
        input.placeholderString = "软件名或窗口标题".localized
        input.font = .systemFont(ofSize: 18)
        input.usesSingleLineMode = true
        input.isBezeled = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.delegate = self
        input.setAccessibilityLabel("按名字切换窗口".localized)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("window"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.autoresizingMask = [.width]
        table.headerView = nil
        table.rowHeight = WindowSwitcherPanelLayout.rowHeight
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clickedRow)
        table.onHover = { [weak self] row in
            guard let self else { return }
            let id = row.flatMap { self.rows.indices.contains($0) ? self.rows[$0].id : nil }
            self.selection.hover(id)
            self.applySelection(scroll: false)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("窗口".localized)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 13)
        for view in [input, scroll, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            input.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),
            input.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
            input.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
            status.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
    }

    private func installMouseMonitors() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in self?.close() }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if let self, event.window !== self.panel { self.close() }
            return event
        }
    }

    private func updateResults(preservingSelection: Bool = true) {
        rows = WindowSwitcherList.rows(query: input.stringValue, candidates: inventory.candidates,
            fields: inventory.fields, recency: recency, ownPID: ProcessInfo.processInfo.processIdentifier,
            focusedID: focusedID, stashedIDs: excludedWindowIDs())
        selection.reconcile(rows.map(\.id), preservingSelection: preservingSelection)
        // Resize before laying out rows; the top stays fixed and overflow remains inside the scroll view.
        if let screenFrame {
            panel.setFrame(WindowSwitcherPanelLayout.frame(visibleFrame: screenFrame, rowCount: rows.count),
                           display: panel.isVisible, animate: false)
        }
        table.reloadData()
        status.isHidden = !rows.isEmpty
        status.stringValue = "没有匹配的窗口".localized
        applySelection(scroll: true)
    }

    private func applySelection(scroll: Bool) {
        guard let index = rows.firstIndex(where: { $0.id == selection.selectedID }) else {
            table.deselectAll(nil)
            return
        }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        if scroll { table.scrollRowToVisible(index) }
    }

    /// 按键在到达输入框（和输入法）之前由面板直接处理：搜索只按字母和拼音匹配，
    /// 不经过输入法组字，当前是中文输入法时也能直接打字母。
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        switch event.keyCode {
        case 53: close(); return true
        case 36, 76, 49: confirm(); return true  // 空格与回车相同：搜索靠拼音与不连续匹配，不需要输入空格
        case 126: moveSelection(-1); return true
        case 125: moveSelection(1); return true
        case 51:
            var text = input.stringValue
            if flags.contains(.command) { text = "" }
            else if flags.contains(.option) {
                while text.last == " " { text.removeLast() }
                while let last = text.last, last != " " { text.removeLast() }
            } else if !text.isEmpty { text.removeLast() }
            setQuery(text); return true
        default: break
        }
        if flags.contains(.control) { return false }
        if flags.contains(.command) {
            guard event.charactersIgnoringModifiers?.lowercased() == "v",
                  let pasted = NSPasteboard.general.string(forType: .string) else { return false }
            setQuery(input.stringValue + pasted.replacingOccurrences(of: "\n", with: " ")); return true
        }
        guard let chars = event.characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else { return false }
        setQuery(input.stringValue + chars)
        return true
    }

    private func setQuery(_ text: String) {
        input.stringValue = text
        if let editor = input.currentEditor() { editor.selectedRange = NSRange(location: (text as NSString).length, length: 0) }
        table.preferKeyboardSelection()
        updateResults(preservingSelection: false)
    }

    func controlTextDidChange(_ obj: Notification) {
        table.preferKeyboardSelection()
        updateResults(preservingSelection: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
        case #selector(NSResponder.moveDown(_:)): moveSelection(1)
        case #selector(NSResponder.insertNewline(_:)): confirm()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        // 首尾循环：在第一项按上到最后一项，在最后一项按下回到第一项。
        let current = table.selectedRow < 0 ? (delta > 0 ? -1 : 0) : table.selectedRow
        let index = ((current + delta) % rows.count + rows.count) % rows.count
        table.preferKeyboardSelection()
        selection.move(to: rows[index].id)
        applySelection(scroll: true)
    }

    @objc private func clickedRow() {
        // NSTableView also sends actions for empty space: never confirm the old selection there.
        guard rows.indices.contains(table.clickedRow) else { return }
        confirm(row: table.clickedRow)
    }

    @objc private func confirm() { confirm(row: table.selectedRow) }

    private func confirm(row: Int) {
        let target = rows.indices.contains(row) ? rows[row].targetID : nil
        let candidate = target.flatMap { id in inventory.candidates.first { $0.id == id } }
        close()
        guard let candidate, !excludedWindowIDs().contains(candidate.id) else { return }
        system.focus(candidate)
    }

    func windowDidResignKey(_ notification: Notification) {
        if panel.isVisible { close() }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        WindowSwitcherRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        return WindowSwitcherCellView(row: rows[row])
    }
}

private final class WindowSwitcherPanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class WindowSwitcherTable: NSTableView {
    var onHover: ((Int?) -> Void)?
    private var hoverArea: NSTrackingArea?
    private var keyboardPointerLocation: NSPoint?
    override var acceptsFirstResponder: Bool { false }

    func preferKeyboardSelection() { keyboardPointerLocation = NSEvent.mouseLocation }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        // Relayout/scroll can generate mouse events without physical movement. They must not
        // undo an arrow-key selection under a stationary pointer.
        guard keyboardPointerLocation != NSEvent.mouseLocation else { return }
        keyboardPointerLocation = nil
        let index = row(at: convert(event.locationInWindow, from: nil))
        onHover?(index >= 0 ? index : nil)
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) { onHover?(nil) }
}

private final class WindowSwitcherRowView: NSTableRowView {
    // A nonactivating panel must still use the system accent, not inactive gray selection.
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

private final class WindowSwitcherCellView: NSTableCellView {
    private let app = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")

    init(row: WindowSwitcherRow) {
        super.init(frame: .zero)
        let font = NSFont.systemFont(ofSize: 13)
        for label in [app, title] {
            label.font = font
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
        }
        app.attributedStringValue = Self.highlight(row.appName, ranges: row.appHighlights, font: font)
        title.attributedStringValue = Self.highlight(row.title.isEmpty ? "无标题".localized : row.title,
                                                   ranges: row.titleHighlights, font: font)
        let icon = NSImageView()
        icon.image = NSRunningApplication(processIdentifier: row.pid)?.icon
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20)
        ])
        let labels = NSStackView(views: [icon, app, title])
        imageView = icon
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labels.orientation = .horizontal
        labels.alignment = .centerY
        labels.spacing = 10
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labels)
        app.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.4).isActive = true
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        textField = app
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var backgroundStyle: NSView.BackgroundStyle { didSet { updateColors() } }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        app.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        title.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }

    private static func highlight(_ text: String, ranges: [NSRange], font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font])
        for range in ranges where NSMaxRange(range) <= result.length {
            result.addAttribute(.font, value: NSFont.systemFont(ofSize: font.pointSize, weight: .bold), range: range)
        }
        return result
    }
}
