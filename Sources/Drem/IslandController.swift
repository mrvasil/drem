import AppKit
import Combine
import DremCore
import OSLog
import SwiftUI

private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class IslandHost: NSHostingView<IslandView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The sole imperative edge: screen placement, pointer events and visibility.
/// No timers poll screens, agents, files or pointer position.
@MainActor
final class IslandController {
    let presentation = IslandPresentation()
    private let panel: NSPanel
    private let defaults: UserDefaults
    private let environmentReader: () -> IslandEnvironmentSnapshot
    private let panelIsOnscreen: @MainActor (NSPanel) -> Bool
    private let monitorsEnabled: Bool
    private let logger = Logger(subsystem: "local.mrvasil.drem", category: "Island")
    private var blockedReason: String?
    private var lastVisibilityTrace: String?
    private weak var lidMonitor: LidStateMonitor?
    private var lidToken: UUID?
    private var subscriptions = Set<AnyCancellable>()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var globalMouse: Any?
    private var localMouse: Any?
    private var restoreGlobal: Any?
    private var restoreLocal: Any?
    private var hoverTask: DispatchWorkItem?
    private var completionTask: DispatchWorkItem?
    private var removalTask: DispatchWorkItem?
    private var gestureEndTask: DispatchWorkItem?
    private var environmentRetry: DispatchWorkItem?
    private var dragTranslation: CGSize?
    private var restoringGesture = false
    private var hovering = false
    private var swipe = IslandSwipe()
    private var stopped = false

    init(monitor: AgentMonitor? = nil, lidMonitor: LidStateMonitor? = nil, keepAwake: KeepAwakeManager? = nil,
         defaults: UserDefaults = .standard, panel: NSPanel? = nil,
         environmentReader: (() -> IslandEnvironmentSnapshot)? = nil,
         panelIsOnscreen: @escaping @MainActor (NSPanel) -> Bool = IslandController.windowServerReportsOnscreen,
         observeSystem: Bool = true) {
        self.defaults = defaults
        monitorsEnabled = observeSystem
        self.panel = panel ?? IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
        self.lidMonitor = lidMonitor
        self.environmentReader = environmentReader ?? { [weak lidMonitor] in
            IslandEnvironmentSnapshot.read(lidClosed: lidMonitor?.liveState)
        }
        self.panelIsOnscreen = panelIsOnscreen
        let panel = self.panel
        defaults.register(defaults: [IslandPreferences.enabled: false, IslandPreferences.publicStatus: true])
        panel.title = "drem Island"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Exclude public chat excerpts from standard window-sharing capture.
        // This is not a substitute for the privacy switch or screen locking.
        panel.sharingType = .none

        if let monitor {
            monitor.$snapshot.sink { [weak self] snapshot in
                guard let self else { return }
                let oldRows = self.presentation.rows
                let oldCompletions = self.presentation.completions
                self.presentation.receive(snapshot)
                guard oldRows != self.presentation.rows || oldCompletions != self.presentation.completions else { return }
                if oldCompletions != self.presentation.completions {
                    self.completionTask?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        self?.presentation.clearCompletions()
                        self?.presentation.lifecycle.finishCompletion()
                        self?.render()
                    }
                    self.completionTask = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
                }
                self.render()
            }.store(in: &subscriptions)
        }
        if let keepAwake {
            Publishers.CombineLatest4(keepAwake.$isActive, keepAwake.$clamshellActive,
                                      keepAwake.$isPausedForScreenLock, keepAwake.$whileAgentsWork)
                .map { IslandSleepState(active: $0, clamshell: $1, paused: $2, agentMode: $3) }
                .removeDuplicates().sink { [weak self] state in
                    guard let self else { return }
                    self.presentation.sleep = state
                    self.presentation.lifecycle.wakeChanged(state.preventsSleep)
                    self.render()
                }.store(in: &subscriptions)
        }

        if observeSystem {
            observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.environmentChanged(retryAfterTransition: true) }
            // UserDefaults notifications carry their originating store. Ignore
            // unrelated suites/components so they cannot clear a transient
            // display/lock/lid block by forcing an unrelated environment read.
            observe(NotificationCenter.default, UserDefaults.didChangeNotification, object: defaults) {
                $0.environmentChanged()
            }
            observe(NotificationCenter.default, IslandPreferences.showNotification) { $0.restore() }
            let workspace = NSWorkspace.shared.notificationCenter
            observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { $0.environmentChanged() }
            observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.environmentChanged(blockingHint: "display-sleep-event") }
            observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.environmentChanged(retryAfterTransition: true) }
            observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.environmentChanged(blockingHint: "session-inactive-event") }
            observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.environmentChanged(retryAfterTransition: true) }
            observe(workspace, NSWorkspace.didActivateApplicationNotification) {
                $0.environmentChanged(retryAfterTransition: true)
            }
            observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) {
                $0.environmentChanged(retryAfterTransition: true)
            }
            let distributed = DistributedNotificationCenter.default()
            observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.environmentChanged(blockingHint: "screen-lock-event") }
            observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.environmentChanged(retryAfterTransition: true) }
            lidToken = lidMonitor?.observe { [weak self] _ in self?.environmentChanged(retryAfterTransition: true) }
        }
        environmentChanged()
    }

    func shutdown() {
        stopped = true
        presentation.lifecycle.configure(enabled: false, available: false)
        hoverTask?.cancel()
        completionTask?.cancel()
        removalTask?.cancel()
        gestureEndTask?.cancel()
        environmentRetry?.cancel()
        swipe.reset()
        presentation.gesture = nil
        subscriptions.removeAll()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        if let lidToken { lidMonitor?.removeObserver(lidToken) }
        lidToken = nil
        hidePanel(immediately: true)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, object: Any? = nil,
                         action: @escaping @MainActor (IslandController) -> Void) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            // A main-queue observer can still run synchronously inside AppKit
            // font/layout initialization. Leave that stack before publishing
            // state or attaching another hosting view. The serial queue also
            // preserves lock/unlock order, unlike independent actor tasks.
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }

    static func notchedScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0 && CGDisplayIsActive(number.uint32Value) != 0
                && screen.safeAreaInsets.top > 0
                && screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
        }
    }

    /// `NSWindow.isVisible` remains true when a window is ordered on another
    /// Space. WindowServer is the authoritative source for whether its surface
    /// is actually composited in the active Space.
    private static func windowServerReportsOnscreen(_ panel: NSPanel) -> Bool {
        guard panel.windowNumber > 0,
              let rows = CGWindowListCopyWindowInfo(
                .optionIncludingWindow,
                CGWindowID(panel.windowNumber)
              ) as? [[String: Any]],
              let row = rows.first,
              let value = row[kCGWindowIsOnscreen as String] as? NSNumber else {
            // An unavailable WindowServer answer must not make a visible panel
            // blink. Ordering it to the front is still a safe repair attempt.
            return panel.isVisible
        }
        return value.boolValue
    }

    func environmentChanged(blockingHint: String? = nil, retryAfterTransition: Bool = false,
                            reattachPanel: Bool = false) {
        guard !stopped else { return }
        if blockingHint != nil || retryAfterTransition {
            environmentRetry?.cancel()
            environmentRetry = nil
        }
        // A display/Space/lock transition invalidates the old gesture surface.
        cancelGesture()
        let showStatus = defaults.bool(forKey: IslandPreferences.publicStatus)
        if presentation.showPublicStatus != showStatus { presentation.showPublicStatus = showStatus }
        let environment = environmentReader()
        if let screen = environment.placement {
            presentation.screenTop = screen.frame.maxY
            let width = screen.notchWidth
            if presentation.notchWidth != width { presentation.notchWidth = width }
            if presentation.notchHeight != screen.notchHeight { presentation.notchHeight = screen.notchHeight }
            let size = NSSize(width: presentation.expandedWidth + 40, height: presentation.canvasHeight + 24)
            panel.setFrame(NSRect(x: screen.centerX - size.width / 2, y: screen.frame.maxY - size.height,
                                  width: size.width, height: size.height), display: false)
        }
        let workspace = NSWorkspace.shared
        if presentation.reduceMotion != workspace.accessibilityDisplayShouldReduceMotion {
            presentation.reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        }
        if presentation.reduceTransparency != workspace.accessibilityDisplayShouldReduceTransparency {
            presentation.reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        }
        if presentation.increaseContrast != workspace.accessibilityDisplayShouldIncreaseContrast {
            presentation.increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        }
        blockedReason = blockingHint ?? environment.blockedReason
        presentation.lifecycle.configure(enabled: defaults.bool(forKey: IslandPreferences.enabled),
            available: blockedReason == nil)
        render()
        // isVisible only means ordered, not that the panel is in this Space.
        if presentation.isPresented {
            // Never detach a surface which WindowServer already composites:
            // orderOut/orderFront creates a visible blink during Space changes.
            // If the settled active Space truly lost the surface, a single
            // detach/reattach remains the bounded recovery path.
            let needsReattach = reattachPanel && panel.isVisible && !panelIsOnscreen(panel)
            if needsReattach { panel.orderOut(nil) }
            if reattachPanel || !panel.isVisible { panel.orderFrontRegardless() }
            panel.contentView?.needsDisplay = true
            panel.displayIfNeeded()
            if reattachPanel { traceVisibility(needsReattach ? "repair" : "reassert") }
        }
        traceVisibility("environment")
        if retryAfterTransition {
            // One bounded resample and conditional repair after WindowServer
            // has settled. No polling and no visible detach during transition.
            let work = DispatchWorkItem { [weak self] in
                self?.environmentRetry = nil
                self?.environmentChanged(reattachPanel: true)
            }
            environmentRetry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    func restore(expanded: Bool = true) {
        guard !stopped else { return }
        cancelGesture()
        if expanded {
            defaults.set(true, forKey: IslandPreferences.enabled)
            environmentChanged()
            // A Show command is also a repair command for a stale/transparent
            // hosting tree. Keep the sleep owner and monitoring untouched.
            removalTask?.cancel()
            removalTask = nil
            removeHost()
        }
        presentation.lifecycle.restore(expanded: expanded)
        render()
        if presentation.lifecycle.mode != .absent {
            presentation.isPresented = true
            panel.orderFrontRegardless()
        }
        traceVisibility("restore")
    }

    private func traceVisibility(_ reason: String) {
        let state = "mode=\(presentation.lifecycle.mode) blocked=\(blockedReason ?? "none") dismissed=\(presentation.lifecycle.dismissed) host=\(panel.contentView != nil) presented=\(presentation.isPresented) ordered=\(panel.isVisible)"
        guard reason == "restore" || reason == "reassert" || reason == "repair" || lastVisibilityTrace != state else { return }
        lastVisibilityTrace = state
        logger.info("\(reason, privacy: .public) \(state, privacy: .public)")
    }

    private func render() {
        guard !stopped else { return }
        if !presentation.lifecycle.available || !presentation.lifecycle.enabled ||
            (presentation.lifecycle.mode == .absent && !presentation.lifecycle.dismissed) {
            cancelGesture()
        }
        let restoring = presentation.lifecycle.mode == .absent && restoringGesture
        guard presentation.lifecycle.mode != .absent || restoring else {
            hidePanel(immediately: !presentation.lifecycle.available || !presentation.lifecycle.enabled)
            return
        }
        removalTask?.cancel()
        removalTask = nil
        if !restoring { removeRestoreMonitors() }
        if panel.contentView == nil {
            panel.contentView = IslandHost(rootView: IslandView(model: presentation,
                toggle: { [weak self] in
                    self?.cancelGesture()
                    self?.presentation.showOverview()
                    self?.presentation.lifecycle.toggle()
                    self?.render()
                }, hide: { [weak self] in self?.dismiss() },
                dragChanged: { [weak self] in self?.handleDrag($0, ended: false) },
                dragEnded: { [weak self] in self?.handleDrag($0, ended: true) }))
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        if restoring {
            // A reversible peek is not a restored island and owns no clicks.
            presentation.isPresented = true
            panel.ignoresMouseEvents = true
            return
        }
        installMouseMonitors()
        // Defer the first animation target until the host has its initial frame.
        if !presentation.isPresented {
            DispatchQueue.main.async { [weak self, weak host = panel.contentView] in
                guard let self, !self.stopped, let host, self.panel.contentView === host,
                      self.presentation.lifecycle.available, self.presentation.lifecycle.mode != .absent else { return }
                self.presentation.isPresented = true
                self.traceVisibility("present")
            }
        }
        updateHitTesting()
    }

    private func dismiss() {
        gestureEndTask?.cancel()
        presentation.showOverview()
        presentation.lifecycle.dismiss()
        render()
        traceVisibility("dismiss")
    }

    private func hidePanel(immediately: Bool) {
        hoverTask?.cancel()
        hoverTask = nil
        hovering = false
        presentation.pointer = 0
        presentation.hoveredID = nil
        presentation.showOverview()
        presentation.isPresented = false
        panel.ignoresMouseEvents = true
        if let globalMouse { NSEvent.removeMonitor(globalMouse) }
        if let localMouse { NSEvent.removeMonitor(localMouse) }
        globalMouse = nil
        localMouse = nil
        updateRestoreMonitors()
        if immediately || !panel.isVisible {
            removalTask?.cancel()
            removeHost()
        } else if removalTask == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.presentation.lifecycle.mode == .absent, !self.restoringGesture else { return }
                self.removeHost()
            }
            removalTask = work
            let delay = presentation.gesture?.intent == .restore ? 0.34 : 0.23
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func removeHost() {
        // Destroy the host rather than retain a hidden repeating layer.
        panel.orderOut(nil)
        panel.contentView = nil
        presentation.isPresented = false
        presentation.gesture = nil
        removalTask = nil
    }

    private var surfaceFrame: NSRect {
        let gesture = presentation.reduceMotion ? nil : presentation.gesture
        let width = presentation.width * (gesture?.scaleX ?? 1)
        let height = presentation.height * (gesture?.scaleY ?? 1)
        return NSRect(x: panel.frame.midX + (gesture?.offsetX ?? 0) - width / 2,
                      y: panel.frame.maxY - (gesture?.offsetY ?? 0) - height,
                      width: width, height: height)
    }

    private func updateHitTesting() {
        guard presentation.lifecycle.mode != .absent else { panel.ignoresMouseEvents = true; return }
        let inside = containsPointer
        // The transparent animation canvas must never block the app beneath.
        // Keep the active drag captured until mouse-up, even across the edge.
        if NSEvent.pressedMouseButtons == 0 { panel.ignoresMouseEvents = !inside }
        if inside != hovering {
            hovering = inside
            hoverTask?.cancel()
            if inside, presentation.lifecycle.mode == .compact {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.hovering else { return }
                    self.presentation.lifecycle.hover(true)
                    self.render()
                }
                hoverTask = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
            } else if !inside { presentation.lifecycle.hover(false) }
        }
        let pointer = inside && !presentation.reduceMotion
            ? max(-1, min(1, (NSEvent.mouseLocation.x - panel.frame.midX) / (presentation.width / 2))) : 0
        // Quantize tiny pointer jitter so it cannot churn the hosting tree.
        let quantized = (pointer * 12).rounded() / 12
        if presentation.pointer != quantized { presentation.pointer = quantized }
        let vertical = inside && !presentation.reduceMotion
            ? max(-1, min(1, (surfaceFrame.midY - NSEvent.mouseLocation.y) / max(1, surfaceFrame.height / 2))) : 0
        let quantizedY = (vertical * 8).rounded() / 8
        if presentation.pointerY != quantizedY { presentation.pointerY = quantizedY }
    }

    private func installMouseMonitors() {
        guard monitorsEnabled, globalMouse == nil, localMouse == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged, .scrollWheel]
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            if event.type == .scrollWheel { _ = self?.handleScroll(event) }
            else { self?.handleMouse(event) }
        }
        localMouse = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            if event.type == .scrollWheel { return self.handleScroll(event) ? nil : event }
            if event.type == .leftMouseDown, event.window === self.panel, self.notchTarget.contains(NSEvent.mouseLocation) {
                self.cancelGesture()
                self.presentation.lifecycle.toggle()
                self.render()
                return nil
            }
            self.handleMouse(event)
            return event
        }
    }

    private func handleMouse(_ event: NSEvent) {
        updateHitTesting()
        if event.type == .leftMouseDown, event.window !== panel, notchTarget.contains(NSEvent.mouseLocation) {
            cancelGesture()
            presentation.lifecycle.toggle()
            render()
            return
        }
        if [.leftMouseDown, .rightMouseDown].contains(event.type), !containsPointer {
            presentation.showOverview()
            presentation.lifecycle.collapse()
            updateHitTesting()
        }
    }

    private var containsPointer: Bool {
        notchTarget.contains(NSEvent.mouseLocation) || IslandHitRegion.contains(NSEvent.mouseLocation, rect: surfaceFrame,
                                 expanded: presentation.lifecycle.mode == .expanded)
    }

    private var notchTarget: NSRect {
        IslandHitRegion.notchTarget(centerX: panel.frame.midX, screenTop: panel.frame.maxY,
                                   width: presentation.notchWidth, height: presentation.notchHeight)
    }

    private func updateRestoreMonitors() {
        removeRestoreMonitors()
        guard monitorsEnabled, !stopped, presentation.lifecycle.enabled, presentation.lifecycle.available,
              presentation.lifecycle.dismissed else { return }
        // Hidden host stays destroyed. Listen only for gestures, not mouse moves
        // or a timer. The rest of the screen never participates in restoration.
        let mask: NSEvent.EventTypeMask = [.scrollWheel, .leftMouseDown]
        restoreGlobal = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            _ = self?.handleRestoreGesture(event)
        }
        restoreLocal = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleRestoreGesture(event) == true ? nil : event
        }
    }

    private func handleRestoreGesture(_ event: NSEvent) -> Bool {
        if event.type == .scrollWheel { return handleScroll(event) }
        guard notchTarget.contains(NSEvent.mouseLocation) else { return false }
        if event.type == .leftMouseDown { restore(); return true }
        return false
    }

    private func handleScroll(_ event: NSEvent) -> Bool {
        let hidden = presentation.lifecycle.mode == .absent
        let point = NSEvent.mouseLocation
        // Expanded cards own their scrolling. Only their header hides the island.
        let inHeader = containsPointer && point.y >= panel.frame.maxY - presentation.notchHeight
        let eligible = hidden ? notchTarget.contains(point)
            : (presentation.lifecycle.mode == .expanded ? inHeader || notchTarget.contains(point) : containsPointer)
        let phase: IslandSwipe.Phase = event.phase.contains(.began) ? .began
            : event.phase.contains(.ended) ? .ended
            : event.phase.contains(.cancelled) ? .cancelled
            : event.phase.isEmpty ? .none : .changed
        let intent: IslandSwipe.Intent? = eligible ? (hidden ? .restore : .hide) : nil
        let result = swipe.consume(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
            inverted: event.isDirectionInvertedFromDevice, precise: event.hasPreciseScrollingDeltas,
            timestamp: event.timestamp, phase: phase, momentum: !event.momentumPhase.isEmpty, intent: intent)
        applyGesture(result)
        if result.captured {
            gestureEndTask?.cancel()
            gestureEndTask = nil
            if phase == .none, result.feedback != nil {
                // Some precise devices omit phase. One cancellable debounce,
                // never a polling timer, supplies their release boundary.
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.applyGesture(self.swipe.finish(at: ProcessInfo.processInfo.systemUptime))
                }
                gestureEndTask = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
            }
        }
        return result.captured
    }

    private func applyGesture(_ update: IslandSwipe.Update) {
        guard update.captured else { return }
        if let feedback = update.feedback {
            restoringGesture = feedback.intent == .restore
            hoverTask?.cancel()
            // No spring under the fingers; the spring belongs to release only.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { presentation.gesture = feedback }
            if update.thresholdCrossed, !presentation.reduceMotion {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            render()
        } else if let resolution = update.resolution {
            let wasRestoring = restoringGesture
            restoringGesture = false
            withAnimation(presentation.reduceMotion ? .easeOut(duration: 0.12)
                          : .spring(response: 0.30, dampingFraction: 0.86)) {
                presentation.gesture = nil
                switch resolution {
                case .commit(.hide): dismiss()
                case .commit(.restore): restore(expanded: false)
                case .cancel:
                    if wasRestoring, presentation.lifecycle.mode == .absent {
                        presentation.gesture = .init(intent: .restore, horizontal: 0, vertical: 0, distance: 0)
                        hidePanel(immediately: false)
                    } else { render() }
                }
            }
        }
    }

    private func handleDrag(_ translation: CGSize, ended: Bool) {
        guard presentation.lifecycle.mode != .absent else { return }
        let previous = dragTranslation ?? .zero
        let first = dragTranslation == nil
        dragTranslation = translation
        let now = ProcessInfo.processInfo.systemUptime
        applyGesture(swipe.consume(x: translation.width - previous.width,
            y: previous.height - translation.height, inverted: false, precise: true,
            timestamp: now, phase: first ? .began : .changed, momentum: false, intent: .hide))
        if ended {
            // Mouse drags cannot physically travel beyond the top screen edge.
            if translation.height <= -8, NSEvent.mouseLocation.y >= panel.frame.maxY - 1 {
                _ = swipe.consume(x: 0, y: 44, inverted: false, precise: true,
                    timestamp: now, phase: .changed, momentum: false, intent: .hide)
            }
            applyGesture(swipe.finish(at: now))
            dragTranslation = nil
        }
    }

    private func cancelGesture() {
        gestureEndTask?.cancel()
        gestureEndTask = nil
        dragTranslation = nil
        restoringGesture = false
        swipe.reset()
        presentation.gesture = nil
    }

    private func removeRestoreMonitors() {
        if let restoreGlobal { NSEvent.removeMonitor(restoreGlobal) }
        if let restoreLocal { NSEvent.removeMonitor(restoreLocal) }
        restoreGlobal = nil; restoreLocal = nil
    }
}
