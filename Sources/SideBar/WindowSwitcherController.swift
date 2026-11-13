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
    private var visibleIDs: [CGWindowID] = []
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
        // Do not offer stale windows from a previous invocation while this snapshot is being refreshed.
        inventory = WindowSwitcherInventory()
        updateResults()
        status.stringValue = "正在读取窗口…".localized
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let screen {
            let frame = screen.visibleFrame
            let size = NSSize(width: min(640, frame.width - 32), height: min(440, frame.height - 32))
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                                  width: size.width, height: size.height), display: false, animate: false)
        }
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
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
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
        input.font = .systemFont(ofSize: 20)
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
        table.rowHeight = 52
        table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(confirm)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("窗口".localized)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
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
            input.topAnchor.constraint(equalTo: background.topAnchor, constant: 18),
            input.heightAnchor.constraint(equalToConstant: 30),
            scroll.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
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
        let selected = preservingSelection && visibleIDs.indices.contains(table.selectedRow) ? visibleIDs[table.selectedRow] : nil
        visibleIDs = WindowSwitcherSearch.sortedIDs(query: input.stringValue, candidates: inventory.candidates,
            fields: inventory.fields, recency: recency, ownPID: ProcessInfo.processInfo.processIdentifier,
            focusedID: focusedID, stashedIDs: excludedWindowIDs())
        table.reloadData()
        status.isHidden = !visibleIDs.isEmpty
        status.stringValue = "没有匹配的窗口".localized
        if !visibleIDs.isEmpty {
            let row = selected.flatMap { visibleIDs.firstIndex(of: $0) } ?? 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }

    func controlTextDidChange(_ obj: Notification) { updateResults(preservingSelection: false) }

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
        guard !visibleIDs.isEmpty else { return }
        let row = max(0, min(visibleIDs.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func confirm() {
        let candidate = visibleIDs.indices.contains(table.selectedRow)
            ? inventory.candidates.first { $0.id == visibleIDs[table.selectedRow] } : nil
        close()
        guard let candidate, !excludedWindowIDs().contains(candidate.id) else { return }
        system.focus(candidate)
    }

    func windowDidResignKey(_ notification: Notification) {
        if panel.isVisible { close() }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { visibleIDs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleIDs.indices.contains(row), let candidate = inventory.candidates.first(where: { $0.id == visibleIDs[row] }) else { return nil }
        let cell = NSTableCellView()
        let icon = NSImageView()
        icon.image = NSRunningApplication(processIdentifier: candidate.pid)?.icon
        let app = NSTextField(labelWithString: candidate.appName)
        app.font = .systemFont(ofSize: 13, weight: .semibold)
        let title = NSTextField(labelWithString: candidate.title)
        title.font = .systemFont(ofSize: 13)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        app.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [app, title])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        for view in [icon, labels] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32), icon.heightAnchor.constraint(equalToConstant: 32),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            labels.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            app.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor)
        ])
        cell.textField = app
        cell.imageView = icon
        return cell
    }
}

private final class WindowSwitcherPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class WindowSwitcherTable: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}
