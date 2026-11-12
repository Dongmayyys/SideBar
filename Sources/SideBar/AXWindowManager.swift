import AppKit
import ApplicationServices

class AXWindowManager {
    private var sessions: [WindowSession] = []
    private let fusionCoordinator = FusionStripCoordinator()
    private let temporaryTabCoordinator = TemporaryStashTabCoordinator()
    private var temporaryOrdinals = TemporaryStashOrdinals()
    private let temporaryRecoveryStore = TemporaryStashRecoveryStore()
    private var temporaryRecovery = TemporaryStashRecoverySnapshot()
    private var pendingTemporaryRecovery: [TemporaryStashRecoveryRecord] = []
    private var temporaryRecoveryRetry: DispatchWorkItem?
    private var temporarilyExcludedWindowKeys: Set<String> = []
    private var bundleControlOwnerOverrides: [String: SideBarHotkeyClaim.HotkeyOwner] = [:]
    private var bundlePreferredClaimSessionIDs: [String: String] = [:]
    private var bundleLastExpandedSessions: [String: ObjectIdentifier] = [:]
    private var bundleLastSnappedSessions: [String: ObjectIdentifier] = [:]
    private var hasCleanedUp = false
    // 保留每个软件最后的普通焦点窗口；刚收纳该窗口时可回退到此前的主界面。
    private var mainInterfaceHistory: [(app: NSRunningApplication, window: AXUIElement)] = []

    // 监听应用级别的通知 (如焦点窗口变化)，跟踪新建的窗口
    private var appObservers: [pid_t: (AXObserver, CFRunLoopSource)] = [:]
    
    private var globalMouseDownMonitor: Any?
    private var localMouseDownMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var localMouseUpMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var fusionRefreshTimer: Timer?
    private var sessionSyncTimer: Timer?
    
    init() {
        // AppDelegate has already completed synchronous hidden-window rescue.
        temporaryRecovery = temporaryRecoveryStore.load()
        pendingTemporaryRecovery = temporaryRecovery.windows
        for record in pendingTemporaryRecovery {
            temporaryOrdinals.reserve(bundleID: record.bundleID, windowID: record.id, ordinal: record.ordinal)
        }
        temporaryTabCoordinator.restoreSlots(temporaryRecovery.assignments, pendingIDs: Set(pendingTemporaryRecovery.map(\.id)))
        temporaryTabCoordinator.onSlotsChanged = { [weak self] assignments in
            self?.handleTemporarySlotsChanged(assignments)
        }

        SideBarBridge.shared.hotkeyActionHandler = { [weak self] bundleID in
            self?.handleForwardedHotkeyAction(bundleID: bundleID) ?? .unhandled
        }
        startMonitoringAppActivation()
        setupGlobalMouseMonitor()
        setupGlobalKeyMonitor()
        
        // 监听配置变化，动态上/下线应用
        NotificationCenter.default.addObserver(self, selector: #selector(synchronizeSessions), name: NSNotification.Name("AppConfigDidChange"), object: nil)
        
        // 监听新应用启动
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appDidLaunch), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appDidTerminate), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleActiveSpaceDidChange), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        // 关键修复：监听屏幕配置变化（外接显示器热插拔、分辨率切换、显示器排列调整）。
        // 缺少此监听时，WindowSession 的 snappedScreen/snappedDisplayBounds 会指向已失效的
        // "幽灵屏幕"，导致快照条位置错乱、窗口卡在不可见坐标，必须重启进程才能恢复。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        
        // 启动时同步一次所有运行中应用
        synchronizeSessions()
        refreshSideBarHotkeyRuntime()
        restoreTemporaryShortcuts(attemptsRemaining: 20)
        if let app = NSWorkspace.shared.frontmostApplication { recordMainInterfaceActivation(app) }

        fusionRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.reconcileIndicators()
        }
        
        // 低频轮询（每 5 秒）：检测被管理应用是否已退出，自动清理残留 session
        sessionSyncTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.synchronizeSessions()
        }
    }

    deinit {
        cleanup()
    }
    
    func startMonitoringAppActivation() {
        let workspace = NSWorkspace.shared
        
        // 当任何一个应用被激活前台时，也是一个很好的补充检查机制
        workspace.notificationCenter.addObserver(self, selector: #selector(appDidActivate), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }
    
    @objc private func appDidLaunch(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            handleAppActivation(app: app, isActivationNotification: false)
            restoreTemporaryShortcuts(attemptsRemaining: 20)
        }
    }
    
    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        retainTemporaryRecoveryAfterTermination(pid: app.processIdentifier)
        synchronizeSessions()
        restoreTemporaryShortcuts(attemptsRemaining: 20)
    }

    private func retainTemporaryRecoveryAfterTermination(pid: pid_t) {
        // The archive also covers AX-destroy notifications delivered before the
        // workspace termination notification and sessions already being torn down.
        for record in temporaryRecovery.windows where record.pid == pid {
            pendingTemporaryRecovery.removeAll { $0.id == record.id }
            pendingTemporaryRecovery.append(record.waitingForRelaunch())
        }
    }

    @objc private func synchronizeSessions() {
        let runningApps = NSWorkspace.shared.runningApplications
        let runningPIDs = Set(runningApps.map { $0.processIdentifier })
        
        // 1. 下线不再被允许的会话及过期的应用级监听
        sessions.removeAll { session in
            if !AppConfig.shared.isAppEnabled(bundleID: session.bundleID) && !session.isManagedByTemporaryShortcut {
                print("🗑️ 配置变更，移除已停用会话: \(session.bundleID)")
                session.restoreAndDestroy()
                return true
            }
            
            // 进程已退出（应用被用户关闭）
            if !runningPIDs.contains(session.pid) {
                print("🗑️ 进程已退出，自动清理 session: \(session.bundleID) (pid=\(session.pid))")
                session.restoreAndDestroy()
                return true
            }
            
            // AXUIElement 失效
            var roleValue: CFTypeRef?
            let result = AccessibilityRuntimeGuard.copyAttributeValue(
                of: session.windowElement,
                attribute: kAXRoleAttribute as CFString,
                value: &roleValue,
                context: "AXWindowManager.synchronizeSessions.role"
            )
            if result == .success {
                session.noteAXRoleCheckSucceeded()
                return false
            }
            if shouldKeepSessionAfterTransientAXFailure(result, session: session, context: "synchronizeSessions") {
                return false
            }
            if result == .invalidUIElement || result == .apiDisabled {
                // 再次确认进程存活：如果进程已彻底退出，则必须清理
                guard let app = NSRunningApplication(processIdentifier: session.pid), !app.isTerminated else {
                    session.restoreAndDestroy()
                    return true
                }
                if result == .invalidUIElement && session.isManagedByTemporaryShortcut {
                    session.restoreAndDestroy()
                    return true
                }
                // 进程还在，信任 session 的内部容错计数
                return false
            }
            return false
        }
        
        for (pid, info) in appObservers {
            if !runningPIDs.contains(pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), info.1, .defaultMode)
                appObservers.removeValue(forKey: pid)
            }
        }
        
        // 2. 上线当前允许且在运行的会话
        for app in runningApps {
            guard let bundleID = app.bundleIdentifier, app.activationPolicy == .regular else { continue }
            if AppConfig.shared.isAppEnabled(bundleID: bundleID)
                || pendingTemporaryRecovery.contains(where: { $0.bundleID == bundleID }) {
                monitorApp(pid: app.processIdentifier, bundleID: bundleID, maxRetries: 1)
            }
        }

        reconcileIndicators()
        refreshSideBarHotkeyRuntime()
    }
    
    @objc private func appDidActivate(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            handleAppActivation(app: app, isActivationNotification: true)
        }
    }

    @objc private func handleActiveSpaceDidChange() {
        temporaryTabCoordinator.reconcileAfterSpaceChange(sessions: sessions)
        fusionCoordinator.resetForSpaceChange(sessions: sessions.filter { !$0.isManagedByTemporaryShortcut })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            self.reconcileIndicators()
        }
    }

    /// 屏幕配置发生变化（拔/插显示器、分辨率切换、显示器排列改变）。
    /// 对每个锁定几何已失效的 session：**优先就地重贴**（同物理显示器只是变分辨率的常见场景），
    /// 找不到对应新屏时才退化为"复位到主屏可见区域 + 状态机降级为 floating"的安全兜底。
    /// 同时让融合条按新的屏幕几何重新组装，避免快照条出现在"幽灵屏幕"的坐标上。
    @objc private func handleScreenParametersChanged() {
        let activeScreens = NSScreen.screens
        var reseated = 0
        var recovered = 0
        for session in sessions {
            guard session.snappedScreenIsStale(in: activeScreens) else { continue }
            // 先尝试就地重贴——同一块物理显示器切换分辨率是最常见的场景，
            // 直接把用户的吸附窗口和快照条搬到新几何上，保留吸附意图。
            if session.reseatSnappedGeometryIfPossible(in: activeScreens) {
                reseated += 1
            } else {
                // 找不到对应新屏（真的拔了外接屏），走安全兜底。
                session.recoverFromScreenParametersChange()
                recovered += 1
            }
        }
        if reseated + recovered > 0 {
            print("🖥️ 检测到屏幕配置变化: reseat=\(reseated), recover=\(recovered)")
        }

        temporaryTabCoordinator.reconcileAfterSpaceChange(sessions: sessions)
        fusionCoordinator.resetForSpaceChange(sessions: sessions.filter { !$0.isManagedByTemporaryShortcut })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            self.reconcileIndicators()
        }
    }
    
    private func handleAppActivation(app: NSRunningApplication, isActivationNotification: Bool) {
        if isActivationNotification {
            recordMainInterfaceActivation(app)
            temporaryTabCoordinator.handleAppActivation(activatedPID: app.processIdentifier,
                                                       activationPolicy: app.activationPolicy, sessions: sessions)
        }
        guard let bundleID = app.bundleIdentifier else { return }
        
        // 检查用户是否在面板里勾选了它
        if AppConfig.shared.isAppEnabled(bundleID: bundleID) {
            monitorApp(pid: app.processIdentifier, bundleID: bundleID, maxRetries: 5)
            prepareDockActivationRoutingIfNeeded(bundleID: bundleID)
        }
    }
    
    func cleanup() {
        guard !hasCleanedUp else { return }
        stopTemporaryRecovery()

        for session in sessions {
            session.restoreAndDestroy()
        }
        sessions.removeAll()
        mainInterfaceHistory.removeAll()
        bundleControlOwnerOverrides.removeAll()
        bundlePreferredClaimSessionIDs.removeAll()
        bundleLastExpandedSessions.removeAll()
        bundleLastSnappedSessions.removeAll()
        fusionCoordinator.tearDownAll()
        temporaryTabCoordinator.tearDownAll()
        fusionRefreshTimer?.invalidate()
        fusionRefreshTimer = nil
        sessionSyncTimer?.invalidate()
        sessionSyncTimer = nil
        
        for (_, info) in appObservers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), info.1, .defaultMode)
        }
        appObservers.removeAll()

        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor)
            self.localMouseDownMonitor = nil
        }
        if let globalMouseUpMonitor {
            NSEvent.removeMonitor(globalMouseUpMonitor)
            self.globalMouseUpMonitor = nil
        }
        if let localMouseUpMonitor {
            NSEvent.removeMonitor(localMouseUpMonitor)
            self.localMouseUpMonitor = nil
        }
        if let globalKeyDownMonitor {
            NSEvent.removeMonitor(globalKeyDownMonitor)
            self.globalKeyDownMonitor = nil
        }
        if let localKeyDownMonitor {
            NSEvent.removeMonitor(localKeyDownMonitor)
            self.localKeyDownMonitor = nil
        }

        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func suspendForAccessibilityLoss() {
        guard !hasCleanedUp else { return }
        stopTemporaryRecovery()

        for session in sessions {
            session.suspendForAccessibilityLoss()
        }
        sessions.removeAll()
        bundleControlOwnerOverrides.removeAll()
        bundlePreferredClaimSessionIDs.removeAll()
        bundleLastExpandedSessions.removeAll()
        bundleLastSnappedSessions.removeAll()
        fusionCoordinator.tearDownAll()
        temporaryTabCoordinator.tearDownAll()
        fusionRefreshTimer?.invalidate()
        fusionRefreshTimer = nil
        sessionSyncTimer?.invalidate()
        sessionSyncTimer = nil

        for (_, info) in appObservers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), info.1, .defaultMode)
        }
        appObservers.removeAll()

        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor)
            self.localMouseDownMonitor = nil
        }
        if let globalMouseUpMonitor {
            NSEvent.removeMonitor(globalMouseUpMonitor)
            self.globalMouseUpMonitor = nil
        }
        if let localMouseUpMonitor {
            NSEvent.removeMonitor(localMouseUpMonitor)
            self.localMouseUpMonitor = nil
        }
        if let globalKeyDownMonitor {
            NSEvent.removeMonitor(globalKeyDownMonitor)
            self.globalKeyDownMonitor = nil
        }
        if let localKeyDownMonitor {
            NSEvent.removeMonitor(localKeyDownMonitor)
            self.localKeyDownMonitor = nil
        }

        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    
    // 允许通过 AX 通知自己回调
    func handleFocusedWindowChanged(pid: pid_t) {
        if let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier {
            if pendingTemporaryRecovery.contains(where: { $0.bundleID == bundleID }) {
                restoreTemporaryShortcuts(attemptsRemaining: 20)
            }
            WindowSession.recordObservedFocusSnapshot(for: app)
            if AppConfig.shared.isAppEnabled(bundleID: bundleID) {
                monitorApp(pid: pid, bundleID: bundleID)
                sessions
                    .filter { $0.pid == pid }
                    .forEach { $0.handleFocusedWindowChangedWithinApp() }
            }
        }
    }
    
    private func monitorApp(pid: pid_t, bundleID: String, maxRetries: Int = 0) {
        guard !hasCleanedUp else { return }
        let appElement = AXUIElementCreateApplication(pid)
        
        // 注册应用级别的监听器 (只需要一次)，为了拦截 Cmd+N 和 Cmd+W 导致的焦点切换
        if appObservers[pid] == nil {
            var newObserver: AXObserver?
            let callback: AXObserverCallback = { (observer: AXObserver, element: AXUIElement, notification: CFString, context: UnsafeMutableRawPointer?) in
                let manager = Unmanaged<AXWindowManager>.fromOpaque(context!).takeUnretainedValue()
                var pid: pid_t = 0
                AXUIElementGetPid(element, &pid)
                if notification == kAXFocusedWindowChangedNotification as CFString
                    || notification == kAXWindowCreatedNotification as CFString {
                    DispatchQueue.main.async { manager.handleFocusedWindowChanged(pid: pid) }
                }
            }
            if AccessibilityRuntimeGuard.createObserver(
                pid: pid,
                callback: callback,
                observer: &newObserver,
                context: "AXWindowManager.monitorApp.createObserver"
            ) == .success, let observer = newObserver {
                let selfPtr = Unmanaged.passUnretained(self).toOpaque()
                let addResult = AccessibilityRuntimeGuard.addObserverNotification(
                    observer,
                    element: appElement,
                    notification: kAXFocusedWindowChangedNotification as CFString,
                    context: "AXWindowManager.monitorApp.addFocusedWindowObserver",
                    refcon: selfPtr
                )
                let createdResult = AccessibilityRuntimeGuard.addObserverNotification(
                    observer, element: appElement, notification: kAXWindowCreatedNotification as CFString,
                    context: "AXWindowManager.monitorApp.addWindowCreatedObserver", refcon: selfPtr
                )
                guard addResult == .success || createdResult == .success else { return }
                let runLoopSource = AXObserverGetRunLoopSource(observer)
                // 显式绑定到主 run loop：保证 AX 回调始终在主线程，且 cleanup/suspend 时
                // 能从同一 run loop 上拆除，避免在错误的 run loop 上调用造成 source 残留。
                CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
                appObservers[pid] = (observer, runLoopSource)
            }
        }
        
        guard AppConfig.shared.isAppEnabled(bundleID: bundleID) else { return }

        // 获取主窗口并为其添加移动监听
        var windowValue: CFTypeRef?
        if AccessibilityRuntimeGuard.copyAttributeValue(
            of: appElement,
            attribute: kAXFocusedWindowAttribute as CFString,
            value: &windowValue,
            context: "AXWindowManager.monitorApp.focusedWindow"
        ) == .success {
            let windowElement = windowValue as! AXUIElement
            
            // 核心修复：集中判断窗口能力，排除 Finder 桌面背景 (AXDesktop) 等非标准窗口
            let windowProfile = WindowCapabilityProfiler.profile(
                of: windowElement,
                bundleID: bundleID,
                context: "AXWindowManager.monitorApp.profile"
            )
            guard windowProfile.supportsManagedSession else {
                let subroleDescription = windowProfile.subrole ?? "unknown"
                print("⚠️ 过滤非标准窗口 (PID: \(pid), Subrole: \(subroleDescription))，跳过监控")
                return
            }

            if let windowKey = windowKey(for: windowElement, pid: pid),
               temporarilyExcludedWindowKeys.contains(windowKey) {
                return
            }
            
            // 检查缓存池中是否已存在这个窗口的会话
            if !sessions.contains(where: { CFEqual($0.windowElement, windowElement) }) {
                print("🆕 为新标准窗口创建 WindowSession (Bundle: \(bundleID), PID: \(pid))")
                let session = WindowSession(appElement: appElement, windowElement: windowElement, pid: pid, bundleID: bundleID)
                attachSessionLifecycle(to: session)
                sessions.append(session)
            }
        } else if maxRetries > 0 {
            // macOS 刚启动 App 时，窗口可能还在创建中，延迟重试
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.monitorApp(pid: pid, bundleID: bundleID, maxRetries: maxRetries - 1)
            }
            return
        }
        
        // 清理由于关闭等原因已经失效的旧会话（垃圾回收）
        sessions.removeAll { session in
            var roleValue: CFTypeRef?
            let result = AccessibilityRuntimeGuard.copyAttributeValue(
                of: session.windowElement,
                attribute: kAXRoleAttribute as CFString,
                value: &roleValue,
                context: "AXWindowManager.monitorApp.sessionRole"
            )
            if result == .success {
                session.noteAXRoleCheckSucceeded()
                return false
            }
            if shouldKeepSessionAfterTransientAXFailure(result, session: session, context: "monitorApp") {
                return false
            }
            if result == .invalidUIElement || result == .apiDisabled {
                guard let app = NSRunningApplication(processIdentifier: session.pid), !app.isTerminated else {
                    session.restoreAndDestroy()
                    return true
                }
                return false
            }
            return false
        }

        reconcileIndicators()
        refreshSideBarHotkeyRuntime()
    }
    
    private func setupGlobalMouseMonitor() {
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            WindowSession.noteGlobalMouseDown()
            self?.sessions.forEach { $0.handleMouseDown() }
        }
        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            WindowSession.noteGlobalMouseDown()
            self?.sessions.forEach { $0.handleMouseDown() }
            return event
        }

        // 监听全局鼠标左键放开
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.sessions.forEach { $0.handleMouseUp() }
        }
        // 应用内部鼠标左键放开
        localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.sessions.forEach { $0.handleMouseUp() }
            return event
        }
        
        // 基础防误触记录由 WindowSession 自己结合 pressedMouseButtons 处理。
    }
    
    private func setupGlobalKeyMonitor() {
        // 全局键盘监听：用于快捷键触发展开/折叠
        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleGlobalKeyDown(event: event)
        }
        // 本地键盘监听（当本应用在前台时）
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleGlobalKeyDown(event: event) == true {
                return nil // 吃掉事件，阻止传递
            }
            return event
        }
    }
    
    @discardableResult
    private func handleGlobalKeyDown(event: NSEvent) -> Bool {
        WindowSession.noteGlobalKeyDown(event)
        let keyCode = event.keyCode
        // 只关心修饰键中的四大标志位
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue

        if let mainModifiers = AppConfig.shared.mainInterfaceShortcutModifiers,
           let mainKeyCode = AppConfig.shared.mainInterfaceShortcutKeyCode,
           keyCode == mainKeyCode, modifiers == mainModifiers {
            return handleMainInterfaceShortcut()
        }

        if let temporaryModifiers = AppConfig.shared.temporaryShortcutModifiers,
           let temporaryKeyCode = AppConfig.shared.temporaryShortcutKeyCode,
           keyCode == temporaryKeyCode,
           modifiers == temporaryModifiers {
            return handleTemporaryShortcut()
        }

        if SideBarBridge.shared.isMirroredHotkey(modifiers: modifiers, keyCode: keyCode) {
            return false
        }
        
        // 遍历所有已启用应用的配置寻找匹配的快捷键
        for (bundleID, settings) in AppConfig.shared.appSettings {
            guard settings.isEnabled,
                  SideBarBridge.shared.hotkeyBinding(for: bundleID) == nil,
                  let savedModifiers = settings.shortcutModifiers,
                  let savedKeyCode = settings.shortcutKeyCode else { continue }
            
            if keyCode == savedKeyCode && modifiers == savedModifiers {
                maybeShowMultiWindowTip(for: bundleID)
                if let session = preferredControlSession(for: bundleID) {
                    session.toggleExpandCollapse()
                    return true
                }
            }
        }
        return false
    }

    private func recordMainInterfaceActivation(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !WindowSession.shouldIgnoreTemporaryAppActivation(activatedPID: app.processIdentifier) else { return }
        var value: CFTypeRef?
        guard AccessibilityRuntimeGuard.copyAttributeValue(
            of: AXUIElementCreateApplication(app.processIdentifier),
            attribute: kAXFocusedWindowAttribute as CFString,
            value: &value, context: "AXWindowManager.mainInterface.focusedWindow"
        ) == .success, let value else { return }
        let window = value as! AXUIElement
        guard !sessions.contains(where: { $0.isManagedByTemporaryShortcut && CFEqual($0.windowElement, window) }) else { return }
        mainInterfaceHistory.removeAll { $0.app.processIdentifier == app.processIdentifier || $0.app.isTerminated }
        mainInterfaceHistory.append((app, window))
    }

    private func handleMainInterfaceShortcut() -> Bool {
        if temporaryTabCoordinator.toggleMainInterface(sessions: sessions) == .collapsed,
           let main = mainInterfaceHistory.last(where: { entry in
               !sessions.contains { $0.isManagedByTemporaryShortcut && CFEqual($0.windowElement, entry.window) }
           })?.app, !main.isTerminated {
            WindowSession.suppressProgrammaticActivation(for: main.processIdentifier, duration: 0.6)
            main.activate(options: .activateIgnoringOtherApps)
        }
        return true
    }

    private func handleTemporaryShortcut() -> Bool {
        guard let target = currentFocusedStandardWindow() else { return false }
        let existing = sessions.first { CFEqual($0.windowElement, target.windowElement) }
        let action = TemporaryStashShortcutAction.resolve(
            isConfiguredApp: AppConfig.shared.isAppEnabled(bundleID: target.bundleID),
            isManaged: existing?.isManagedByTemporaryShortcut == true,
            isExpanded: existing?.isExpandedForCoordination == true
        )
        switch action {
        case .ignore:
            // 收起的窗口不能通过快捷键展开；设置托管的软件本期不接管。
            return false
        case .cancel:
            existing?.cancelTemporaryShortcutStash()
            return true
        case .stash:
            let replacement = pendingTemporaryReplacement(for: target.windowElement, pid: target.pid, bundleID: target.bundleID)
            let session = WindowSession(appElement: target.appElement, windowElement: target.windowElement,
                                        pid: target.pid, bundleID: target.bundleID, temporaryShortcut: true,
                                        temporaryStashID: replacement?.id ?? UUID().uuidString)
            guard session.startTemporaryShortcutStash(), claimTemporarySlot(for: session, preferred: replacement?.slot ?? 0) else {
                session.restoreAndDestroy()
                return false
            }
            if let replacement {
                pendingTemporaryRecovery.removeAll { $0.id == replacement.id }
            }
            attachSessionLifecycle(to: session)
            clearTemporarilyExcludedWindow(for: target.windowElement, pid: target.pid)
            session.temporaryStashOrdinal = temporaryOrdinals.assign(bundleID: target.bundleID, windowID: session.temporaryStashID)
            sessions.append(session)
            refreshTemporaryDockExclusion(bundleID: target.bundleID)
            reconcileIndicators()
            refreshSideBarHotkeyRuntime()
            return true
        }
    }

    private func reconcileIndicators() {
        fusionCoordinator.reconcile(sessions: sessions.filter { !$0.isManagedByTemporaryShortcut })
        persistTemporaryRecovery()
        temporaryTabCoordinator.reconcile(sessions: sessions)
    }

    private func persistTemporaryRecovery() {
        guard !hasCleanedUp else { return }
        let live = sessions.compactMap { $0.temporaryStashRecoveryRecord() }
        let liveIDs = Set(live.map(\.id))
        temporaryRecovery.update(windows: pendingTemporaryRecovery.filter { !liveIDs.contains($0.id) } + live)
        for session in sessions {
            if let record = temporaryRecovery.windows.first(where: { $0.id == session.temporaryStashID }) {
                session.temporaryStashSlot = record.slot
            }
        }
        temporaryRecoveryStore.save(temporaryRecovery)
        temporaryTabCoordinator.restoreSlots(temporaryRecovery.assignments, pendingIDs: Set(pendingTemporaryRecovery.map(\.id)))
    }

    private func handleTemporarySlotsChanged(_ assignments: [TemporaryStashSlotAssignment]) {
        for index in pendingTemporaryRecovery.indices {
            if let assignment = assignments.first(where: { $0.id == pendingTemporaryRecovery[index].id }) {
                pendingTemporaryRecovery[index].slot = assignment.slot
            }
        }
        persistTemporaryRecovery()
    }

    private func claimTemporarySlot(for session: WindowSession, preferred: Int) -> Bool {
        guard let record = session.temporaryStashRecoveryRecord() else { return false }
        let live = sessions.compactMap { $0.temporaryStashRecoveryRecord() }
        let liveIDs = Set(live.map(\.id))
        let allRecords = temporaryRecovery.windows.filter { !liveIDs.contains($0.id) } + live
        let occupied = Set(allRecords.filter {
            $0.id != record.id && $0.screenID == record.screenID && $0.edge == record.edge
        }.map(\.slot))
        let existing = temporaryRecovery.windows.first { $0.id == record.id }
        let retainsSlot = existing?.screenID == record.screenID && existing?.edge == record.edge && existing?.slot == preferred
        // A shorter visible area may temporarily hide an established slot. It
        // must not renumber that reservation when SideBar or the app restarts.
        let capacity = retainsSlot ? max(session.temporaryStashSlotCapacity, preferred) : session.temporaryStashSlotCapacity
        guard let slot = TemporaryStashSlots.allocate(preferred: preferred, occupied: occupied,
                                                       capacity: capacity) else { return false }
        session.temporaryStashSlot = slot
        return true
    }

    private func stopTemporaryRecovery() {
        persistTemporaryRecovery()
        hasCleanedUp = true
        temporaryRecoveryRetry?.cancel()
        temporaryRecoveryRetry = nil
    }

    private func discardPendingTemporaryRecovery(_ record: TemporaryStashRecoveryRecord) {
        pendingTemporaryRecovery.removeAll { $0.id == record.id }
        temporaryRecovery.remove(id: record.id)
        temporaryOrdinals.release(bundleID: record.bundleID, windowID: record.id)
        refreshTemporaryDockExclusion(bundleID: record.bundleID)
    }

    /// Exact identities always get first refusal. Only confirmed missing identities
    /// enter relaunch matching; a busy AX application keeps its exact record.
    private func restoreTemporaryShortcuts(attemptsRemaining: Int) {
        guard !hasCleanedUp else { return }
        temporaryRecoveryRetry?.cancel()
        temporaryRecoveryRetry = nil
        resolveClosedTemporaryRecovery()
        var exactWindows: [AXUIElement] = []
        for record in pendingTemporaryRecovery where !record.awaitingRelaunch && record.closedAt == nil {
            guard !AppConfig.shared.isAppEnabled(bundleID: record.bundleID) else { continue }
            guard let app = NSRunningApplication(processIdentifier: record.pid), !app.isTerminated,
                  app.bundleIdentifier == record.bundleID else {
                markTemporaryRecoveryWaiting(record)
                continue
            }
            guard let windows = temporaryRecoveryWindows(pid: record.pid) else { continue }
            if let window = windows.first(where: {
                WindowAlphaManager.shared.findWindowID(for: $0, pid: record.pid) == record.windowID
            }) {
                exactWindows.append(window)
                restoreTemporaryShortcut(record, window: window, pid: record.pid)
            } else if windows.allSatisfy({ WindowAlphaManager.shared.findWindowID(for: $0, pid: record.pid) != nil }) {
                markTemporaryRecoveryWaiting(record)
            }
        }

        let groups = Dictionary(grouping: pendingTemporaryRecovery.filter {
            $0.awaitingRelaunch && $0.closedAt == nil
        }, by: \.bundleID)
        for (bundleID, records) in groups {
            guard !AppConfig.shared.isAppEnabled(bundleID: bundleID) else { continue }
            var candidates: [(pid: pid_t, window: AXUIElement, frame: CGRect)] = []
            for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == bundleID && !app.isTerminated {
                monitorApp(pid: app.processIdentifier, bundleID: bundleID)
                guard let windows = temporaryRecoveryWindows(pid: app.processIdentifier) else { continue }
                for window in windows where !exactWindows.contains(where: { CFEqual($0, window) }) {
                    guard isTemporaryRecoveryCandidate(window, pid: app.processIdentifier, bundleID: bundleID),
                          let frame = temporaryRecoveryFrame(window) else { continue }
                    candidates.append((app.processIdentifier, window, frame))
                }
            }
            let bundleCount = temporaryRecovery.windows.filter { $0.bundleID == bundleID }.count
            if bundleCount == 1, let record = records.first {
                if let candidate = primaryTemporaryRecoveryCandidate(candidates) {
                    restoreTemporaryShortcut(record, window: candidate.window, pid: candidate.pid)
                }
            } else {
                let matches = TemporaryStashRecoveryMatcher.uniqueMatches(records: records, frames: candidates.map(\.frame))
                for record in records {
                    guard let index = matches[record.id] else { continue }
                    restoreTemporaryShortcut(record, window: candidates[index].window, pid: candidates[index].pid)
                }
            }
        }
        reconcileIndicators()
        guard attemptsRemaining > 0, !pendingTemporaryRecovery.isEmpty else { return }
        let retry = DispatchWorkItem { [weak self] in
            self?.restoreTemporaryShortcuts(attemptsRemaining: attemptsRemaining - 1)
        }
        temporaryRecoveryRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: retry)
    }

    private func markTemporaryRecoveryWaiting(_ record: TemporaryStashRecoveryRecord) {
        guard let index = pendingTemporaryRecovery.firstIndex(where: { $0.id == record.id }) else { return }
        pendingTemporaryRecovery[index] = record.waitingForRelaunch()
    }

    private func temporaryRecoveryWindows(pid: pid_t) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AccessibilityRuntimeGuard.copyAttributeValue(of: AXUIElementCreateApplication(pid),
                  attribute: kAXWindowsAttribute as CFString, value: &value,
                  context: "AXWindowManager.temporaryRecoveryWindows") == .success else { return nil }
        return value as? [AXUIElement]
    }

    private func isTemporaryRecoveryCandidate(_ window: AXUIElement, pid: pid_t, bundleID: String) -> Bool {
        if let key = windowKey(for: window, pid: pid), temporarilyExcludedWindowKeys.contains(key) { return false }
        return !sessions.contains(where: { CFEqual($0.windowElement, window) })
            && WindowCapabilityProfiler.profile(of: window, bundleID: bundleID,
                       context: "AXWindowManager.isTemporaryRecoveryCandidate").isStandardWindow
    }

    private func restoreTemporaryShortcut(_ record: TemporaryStashRecoveryRecord, window: AXUIElement, pid: pid_t) {
        guard isTemporaryRecoveryCandidate(window, pid: pid, bundleID: record.bundleID),
              WindowAlphaManager.shared.findWindowID(for: window, pid: pid) != nil else { return }
        let session = WindowSession(appElement: AXUIElementCreateApplication(pid), windowElement: window,
                                    pid: pid, bundleID: record.bundleID, temporaryShortcut: true, temporaryStashID: record.id)
        session.temporaryStashOrdinal = record.ordinal
        guard session.startTemporaryShortcutStash(restoring: record), claimTemporarySlot(for: session, preferred: record.slot) else {
            session.restoreAndDestroy()
            return
        }
        attachSessionLifecycle(to: session)
        sessions.append(session)
        temporaryTabCoordinator.suppressRestoredHover(for: session)
        pendingTemporaryRecovery.removeAll { $0.id == record.id }
        refreshTemporaryDockExclusion(bundleID: record.bundleID)
    }

    private func primaryTemporaryRecoveryCandidate(_ candidates: [(pid: pid_t, window: AXUIElement, frame: CGRect)])
        -> (pid: pid_t, window: AXUIElement, frame: CGRect)? {
        for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            for candidate in candidates {
                var value: CFTypeRef?
                if AccessibilityRuntimeGuard.copyAttributeValue(of: AXUIElementCreateApplication(candidate.pid),
                       attribute: attribute as CFString, value: &value,
                       context: "AXWindowManager.primaryTemporaryRecoveryCandidate") == .success,
                   let value, CFEqual(value, candidate.window) { return candidate }
            }
        }
        return candidates.first
    }

    private func temporaryRecoveryFrame(_ window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AccessibilityRuntimeGuard.copyAttributeValue(of: window, attribute: kAXPositionAttribute as CFString,
                  value: &positionValue, context: "AXWindowManager.temporaryRecoveryFrame.position") == .success,
              AccessibilityRuntimeGuard.copyAttributeValue(of: window, attribute: kAXSizeAttribute as CFString,
                  value: &sizeValue, context: "AXWindowManager.temporaryRecoveryFrame.size") == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              [position.x, position.y, size.width, size.height].allSatisfy(\.isFinite),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func pendingTemporaryReplacement(for window: AXUIElement, pid: pid_t, bundleID: String) -> TemporaryStashRecoveryRecord? {
        let records = pendingTemporaryRecovery.filter { $0.bundleID == bundleID }
        if let windowID = WindowAlphaManager.shared.findWindowID(for: window, pid: pid),
           let exact = records.first(where: { !$0.awaitingRelaunch && $0.matches(pid: pid, bundleID: bundleID, windowID: windowID) }) {
            return exact
        }
        guard let frame = temporaryRecoveryFrame(window) else { return nil }
        return TemporaryStashRecoveryMatcher.replacement(in: records.filter(\.awaitingRelaunch), frame: frame)
    }

    private func refreshTemporaryDockExclusion(bundleID: String) {
        AppConfig.shared.setTemporaryDockMinimizeExclusion(
            bundleID: bundleID,
            excluded: temporaryOrdinals.hasMembers(bundleID: bundleID)
        )
    }

    private func currentFocusedStandardWindow() -> (appElement: AXUIElement, windowElement: AXUIElement, pid: pid_t, bundleID: String)? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.activationPolicy == .regular,
              frontmostApp.bundleIdentifier != Bundle.main.bundleIdentifier,
              let bundleID = frontmostApp.bundleIdentifier else {
            return nil
        }

        let pid = frontmostApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        guard AccessibilityRuntimeGuard.copyAttributeValue(
            of: appElement,
            attribute: kAXFocusedWindowAttribute as CFString,
            value: &windowValue,
            context: "AXWindowManager.currentFocusedStandardWindow.focusedWindow"
        ) == .success,
              let focusedWindow = windowValue else {
            return nil
        }

        let windowElement = focusedWindow as! AXUIElement
        let windowProfile = WindowCapabilityProfiler.profile(
            of: windowElement,
            bundleID: bundleID,
            context: "AXWindowManager.currentFocusedStandardWindow.profile"
        )
        guard windowProfile.isStandardWindow else {
            return nil
        }

        return (appElement, windowElement, pid, bundleID)
    }

    private func attachSessionLifecycle(to session: WindowSession) {
        session.onHotkeyRuntimeStateChanged = { [weak self] _ in
            self?.handleSessionRuntimeStateChanged()
        }
        session.onStateTransition = { [weak self] session, oldState, newState in
            self?.handleSessionStateTransition(session, oldState: oldState, newState: newState)
        }
        session.onManagedEdgeDetachment = { [weak self] session in
            self?.handleManagedEdgeDetachment(for: session)
        }
        session.onTemporaryShortcutSessionEnded = { [weak self] session, excludeWindow, removeSession in
            self?.handleTemporaryShortcutSessionEnded(session, excludeWindow: excludeWindow, removeSession: removeSession)
        }
    }

    private func handleSessionRuntimeStateChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconcileIndicators()
            self.refreshSideBarHotkeyRuntime()
        }
    }

    private func shouldKeepSessionAfterTransientAXFailure(_ result: AXError, session: WindowSession, context: String) -> Bool {
        guard session.shouldDeferRemovalAfterAXRoleFailure(result) else { return false }
        return true
    }

    private func handleTemporaryShortcutSessionEnded(_ session: WindowSession, excludeWindow: Bool, removeSession: Bool) {
        if excludeWindow, let windowKey = windowKey(for: session.windowElement, pid: session.pid) {
            temporarilyExcludedWindowKeys.insert(windowKey)
        }
        if !hasCleanedUp {
            // Do not read sessions here: this callback can run inside sessions.removeAll.
            if !excludeWindow, let record = temporaryRecovery.windows.first(where: { $0.id == session.temporaryStashID }) {
                pendingTemporaryRecovery.removeAll { $0.id == record.id }
                var closing = record
                closing.closedAt = Date()
                pendingTemporaryRecovery.append(closing)
                temporaryRecovery.update(windows: temporaryRecovery.windows.filter { $0.id != record.id } + [closing])
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, !self.hasCleanedUp else { return }
                    self.resolveClosedTemporaryRecovery()
                    self.reconcileIndicators()
                }
            } else {
                temporaryRecovery.remove(id: session.temporaryStashID)
                temporaryOrdinals.release(bundleID: session.bundleID, windowID: session.temporaryStashID)
            }
            temporaryRecoveryStore.save(temporaryRecovery)
        }
        refreshTemporaryDockExclusion(bundleID: session.bundleID)

        guard removeSession else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sessions.removeAll { $0 === session }
            self.reconcileIndicators()
            self.refreshSideBarHotkeyRuntime()
        }
    }

    private func resolveClosedTemporaryRecovery(now: Date = Date()) {
        for record in pendingTemporaryRecovery {
            guard let closedAt = record.closedAt else { continue }
            let app = NSRunningApplication(processIdentifier: record.pid)
            let stillRunning = app?.isTerminated == false && app?.bundleIdentifier == record.bundleID
            if !stillRunning { markTemporaryRecoveryWaiting(record) }
            else if now.timeIntervalSince(closedAt) >= 2 { discardPendingTemporaryRecovery(record) }
        }
    }

    private func clearTemporarilyExcludedWindow(for windowElement: AXUIElement, pid: pid_t) {
        guard let windowKey = windowKey(for: windowElement, pid: pid) else { return }
        temporarilyExcludedWindowKeys.remove(windowKey)
    }

    private func windowKey(for windowElement: AXUIElement, pid: pid_t) -> String? {
        guard let windowID = WindowAlphaManager.shared.findWindowID(for: windowElement, pid: pid) else { return nil }
        return "\(pid):\(windowID)"
    }

    private func handleSessionStateTransition(_ session: WindowSession, oldState: SnapState, newState: SnapState) {
        if session.isManagedByTemporaryShortcut, case .expanded = newState {
            temporaryTabCoordinator.rememberExpansion(of: session)
        }
        guard !session.isManagedByTemporaryShortcut else { return }
        rememberBundleWindowHistory(for: session, newState: newState)
        guard case .floating = oldState else { return }
        guard case .snapped = newState else { return }
        handleFloatingToSnappedTransition(for: session)
    }

    private func handleManagedEdgeDetachment(for session: WindowSession) {
        guard !session.isManagedByTemporaryShortcut else { return }
        let bundleSessions = sessions(for: session.bundleID)
        guard bundleSessions.count > 1 else { return }

        let previousOwner = effectiveBundleOwner(for: session.bundleID)
        bundleControlOwnerOverrides[session.bundleID] = .dockminimize
        bundlePreferredClaimSessionIDs[session.bundleID] = session.coordinationSessionID

        let managedSiblingSessions = bundleSessions.filter {
            $0 !== session && $0.isManagedForCoordination
        }

        let shouldShowNotice = previousOwner != .dockminimize || !managedSiblingSessions.isEmpty
        if shouldShowNotice {
            SideBarBridge.shared.announceBundleControlTransfer(
                bundleID: session.bundleID,
                appName: session.coordinationAppDisplayName,
                owner: .dockminimize,
                reason: .detachedFromEdge
            )
        }

        fusionCoordinator.discardCachedDescriptors(for: [session] + managedSiblingSessions)

        if !managedSiblingSessions.isEmpty {
            managedSiblingSessions.forEach { $0.relinquishManagedStateForBundleTransfer() }
        }

        handleSessionRuntimeStateChanged()
    }

    private func handleFloatingToSnappedTransition(for session: WindowSession) {
        guard !session.isManagedByTemporaryShortcut else { return }
        let bundleSessions = sessions(for: session.bundleID)
        guard bundleSessions.count > 1 else { return }
        guard bundleSessions.contains(where: { $0 !== session && $0.isFloatingForCoordination }) else {
            return
        }

        let previousOwner = effectiveBundleOwner(for: session.bundleID)
        bundleControlOwnerOverrides[session.bundleID] = .sidebar
        bundlePreferredClaimSessionIDs[session.bundleID] = session.coordinationSessionID

        if previousOwner != .sidebar {
            SideBarBridge.shared.announceBundleControlTransfer(
                bundleID: session.bundleID,
                appName: session.coordinationAppDisplayName,
                owner: .sidebar,
                reason: .snappedWhileFloatingSiblingsPresent
            )
        }

        handleSessionRuntimeStateChanged()
    }

    private func sessions(for bundleID: String) -> [WindowSession] {
        sessions.filter { $0.bundleID == bundleID && !$0.isManagedByTemporaryShortcut }
    }

    private func effectiveBundleOwner(for bundleID: String) -> SideBarHotkeyClaim.HotkeyOwner {
        let bundleSessions = sessions(for: bundleID)
        guard !bundleSessions.isEmpty else { return .dockminimize }

        let hasManaged = bundleSessions.contains { $0.isManagedForCoordination }
        let hasFloating = bundleSessions.contains { $0.isFloatingForCoordination }

        if hasManaged && hasFloating, let override = bundleControlOwnerOverrides[bundleID] {
            return override
        }
        return hasManaged ? .sidebar : .dockminimize
    }

    private func reconcileBundleOwnershipState() {
        let groupedSessions = Dictionary(grouping: sessions.filter { !$0.isManagedByTemporaryShortcut }, by: \.bundleID)

        bundleControlOwnerOverrides = bundleControlOwnerOverrides.filter { bundleID, _ in
            guard let bundleSessions = groupedSessions[bundleID], !bundleSessions.isEmpty else {
                return false
            }
            let hasManaged = bundleSessions.contains { $0.isManagedForCoordination }
            let hasFloating = bundleSessions.contains { $0.isFloatingForCoordination }
            return hasManaged && hasFloating
        }

        bundlePreferredClaimSessionIDs = bundlePreferredClaimSessionIDs.filter { bundleID, sessionID in
            groupedSessions[bundleID]?.contains(where: { $0.coordinationSessionID == sessionID }) == true
        }

        bundleLastExpandedSessions = bundleLastExpandedSessions.filter { bundleID, sessionID in
            groupedSessions[bundleID]?.contains(where: { ObjectIdentifier($0) == sessionID }) == true
        }
        bundleLastSnappedSessions = bundleLastSnappedSessions.filter { bundleID, sessionID in
            groupedSessions[bundleID]?.contains(where: { ObjectIdentifier($0) == sessionID }) == true
        }
    }

    private func refreshSideBarHotkeyRuntime() {
        reconcileBundleOwnershipState()

        let effectiveOwners = Dictionary(
            uniqueKeysWithValues: Set(sessions.filter { !$0.isManagedByTemporaryShortcut }.map(\.bundleID)).sorted().map { bundleID in
                (bundleID, effectiveBundleOwner(for: bundleID))
            }
        )

        SideBarBridge.shared.syncRuntimeClaims(
            from: sessions.filter { !$0.isManagedByTemporaryShortcut }.map(\.runtimeClaimSnapshot),
            effectiveOwners: effectiveOwners,
            preferredSessionIDs: bundlePreferredClaimSessionIDs
        )
    }

    private func handleForwardedHotkeyAction(bundleID: String) -> SideBarBridge.HotkeyActionResponse {
        let effectiveOwner = effectiveBundleOwner(for: bundleID)
        let preferredSessionID = SideBarBridge.shared.runtimeClaim(for: bundleID)?.sessionID
        maybeShowMultiWindowTip(for: bundleID)
        let candidateSessions = sessions(for: bundleID).sorted { lhs, rhs in
            forwardedHotkeyPriority(
                for: lhs,
                effectiveOwner: effectiveOwner,
                preferredSessionID: preferredSessionID,
                bundleID: bundleID
            ) > forwardedHotkeyPriority(
                for: rhs,
                effectiveOwner: effectiveOwner,
                preferredSessionID: preferredSessionID,
                bundleID: bundleID
            )
        }

        if let session = candidateSessions.first {
            if session.relinquishToDockMinimizeIfDetachedFromEdge() {
                return SideBarBridge.HotkeyActionResponse(
                    handled: false,
                    state: session.runtimeClaimSnapshot.state,
                    handledBy: "dockminimize"
                )
            }

            if session.handleForwardedHotkeyAction() {
                return SideBarBridge.HotkeyActionResponse(
                    handled: true,
                    state: session.runtimeClaimSnapshot.state,
                    handledBy: "sidebar"
                )
            }

            if session.shouldRetainForwardedHotkeyOwnership {
                return SideBarBridge.HotkeyActionResponse(
                    handled: true,
                    state: session.runtimeClaimSnapshot.state,
                    handledBy: "sidebar"
                )
            }

            return SideBarBridge.HotkeyActionResponse(
                handled: false,
                state: session.runtimeClaimSnapshot.state,
                handledBy: "dockminimize"
            )
        }

        return .unhandled
    }

    private func forwardedHotkeyPriority(
        for session: WindowSession,
        effectiveOwner: SideBarHotkeyClaim.HotkeyOwner,
        preferredSessionID: String?,
        bundleID: String
    ) -> Int {
        var score = 0

        if let preferredControlSession = preferredControlSession(for: bundleID),
           preferredControlSession === session {
            score += 2000
        }

        if let preferredSessionID, session.coordinationSessionID == preferredSessionID {
            score += 1000
        }

        switch effectiveOwner {
        case .sidebar:
            if session.isSnappedForCoordination {
                score += 500
            } else if session.isExpandedForCoordination {
                score += 400
            }
        case .dockminimize:
            if session.isFloatingForCoordination {
                score += 500
            } else if session.isExpandedForCoordination {
                score += 200
            } else if session.isSnappedForCoordination {
                score += 100
            }
        }

        return score
    }

    private func prepareDockActivationRoutingIfNeeded(bundleID: String) {
        guard WindowSession.hasRecentDockClickIntent() else { return }
        maybeShowMultiWindowTip(for: bundleID)
        guard hasMultipleSnappedWindows(for: bundleID) else { return }
        guard let session = preferredControlSession(for: bundleID) else { return }
        WindowSession.suppressProgrammaticActivation(for: session.pid, duration: 0.5)
        _ = session.toggleExpandCollapse()
    }

    private func rememberBundleWindowHistory(for session: WindowSession, newState: SnapState) {
        let sessionID = ObjectIdentifier(session)
        switch newState {
        case .expanded:
            bundleLastExpandedSessions[session.bundleID] = sessionID
        case .snapped:
            bundleLastSnappedSessions[session.bundleID] = sessionID
        case .floating:
            break
        }
    }

    private func preferredControlSession(for bundleID: String) -> WindowSession? {
        let candidateSessions = sessions(for: bundleID).filter {
            $0.isSnappedForCoordination || $0.isExpandedForCoordination
        }
        guard !candidateSessions.isEmpty else { return nil }

        let lastExpandedSessionID = bundleLastExpandedSessions[bundleID]
        let lastSnappedSessionID = bundleLastSnappedSessions[bundleID]

        return candidateSessions.max { lhs, rhs in
            controlPriority(
                for: lhs,
                lastExpandedSessionID: lastExpandedSessionID,
                lastSnappedSessionID: lastSnappedSessionID
            ) < controlPriority(
                for: rhs,
                lastExpandedSessionID: lastExpandedSessionID,
                lastSnappedSessionID: lastSnappedSessionID
            )
        }
    }

    private func controlPriority(
        for session: WindowSession,
        lastExpandedSessionID: ObjectIdentifier?,
        lastSnappedSessionID: ObjectIdentifier?
    ) -> Int {
        var score = 0
        let sessionID = ObjectIdentifier(session)

        if sessionID == lastExpandedSessionID {
            score += 1000
        }
        if sessionID == lastSnappedSessionID {
            score += 500
        }
        if session.isExpandedForCoordination {
            score += 200
        } else if session.isSnappedForCoordination {
            score += 100
        }

        return score
    }

    private func hasMultipleSnappedWindows(for bundleID: String) -> Bool {
        sessions(for: bundleID).filter(\.isSnappedForCoordination).count >= 2
    }

    private func maybeShowMultiWindowTip(for bundleID: String) {
        guard hasMultipleSnappedWindows(for: bundleID) else { return }
        guard let appName = sessions(for: bundleID).first?.coordinationAppDisplayName else { return }
        MultiWindowTipController.shared.show(appName: appName)
    }
}
