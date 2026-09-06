// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 drem contributors

import DremCore
import AppKit
import Combine
import IOKit.ps

@MainActor
final class KeepAwakeManager: ObservableObject {
    static let shared = KeepAwakeManager()

    enum EndReason {
        case manual
        case timer
        case battery
        case quit
    }

    enum SessionTrigger {
        case manual
        case automation
    }

    @Published private(set) var isActive = false
    @Published private(set) var endDate: Date?
    @Published private(set) var sessionTrigger: SessionTrigger?
    @Published private(set) var activeAutomationConditions = Set<KeepAwakeAutomationCondition>()
    @Published private(set) var isPausedForScreenLock = false
    @Published private(set) var clamshellActive = false
    @Published private(set) var passwordlessClamshell = false
    @Published private(set) var clamshellRulePresent = false
    @Published private(set) var clamshellSetupInProgress = false
    @Published private(set) var clamshellSetupFailed = false
    @Published private(set) var accessibilityTrusted = KeepAwakeAccessibility.isTrusted
    @Published private(set) var lastError: String?
    @Published private(set) var brightnessError: String?
    @Published private(set) var hasWorkingAgent = false

    @Published var whileAgentsWork: Bool {
        didSet {
            guard whileAgentsWork != oldValue else { return }
            self.defaults.set(whileAgentsWork, forKey: KeepAwakeDefaultsKey.whileAgentsWork)
            automationSuppressedUntilConditionsClear = false
            clamshellSetupFailed = false
            clamshellSetupRetried = false
            syncWithPreferences()
            // Ask while the user is at the switch, not after they close the lid.
            if whileAgentsWork { applyClamshellPreference() }
        }
    }

    @Published var clamshellPreferred: Bool {
        didSet {
            guard clamshellPreferred != oldValue else { return }
            self.defaults.set(
                clamshellPreferred,
                forKey: KeepAwakeDefaultsKey.clamshellPreferred
            )
            clamshellSetupFailed = false
            clamshellSetupRetried = false
            syncClamshellDemand()
            if clamshellPreferred, !isPausedForScreenLock { applyClamshellPreference() }
        }
    }

    var onSessionEnded: ((EndReason) -> Void)?

    private let assertions = SleepAssertionController()
    private let defaults: UserDefaults
    private let monitorSystem: Bool
    private let clamshellWrite: (Bool, @escaping (Bool) -> Void) -> Void
    private let clamshellRestoreSync: () -> Bool
    private let batterySnapshot: () -> KeepAwakeBatteryInfo?
    private var endTimer: Timer?
    private var batteryTimer: Timer?
    private var mouseJiggleTimer: Timer?
    private var pendingMouseReturn: DispatchWorkItem?
    private var defaultsObserver: AnyCancellable?
    private var appActiveObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?
    private var screenLockObservers: [NSObjectProtocol] = []
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var automationEvaluationWorkItem: DispatchWorkItem?
    private var lastExternalDisplayConnected: Bool?
    private var screenLocked = false
    private var automationSuppressedUntilConditionsClear = false
    private var recoveryCompleted = false
    private var clamshellSetupRetried = false
    private var clamshellState = KeepAwakeClamshellState()
    private var clamshellActivationPending: Bool { clamshellState.pending != nil }
    private var isQuitting = false
    private var handlingClamshellFailure = false
    private var preferenceSyncScheduled = false

    var agentRequiresWake: Bool {
        KeepAwakeAgentPolicy.requiresWake(
            enabled: whileAgentsWork,
            hasWorkingAgent: hasWorkingAgent,
            suppressed: automationSuppressedUntilConditionsClear
        )
    }

    private var clamshellConfigurationRequested: Bool { clamshellPreferred || whileAgentsWork }
    private var clamshellRequested: Bool {
        KeepAwakeAgentPolicy.requiresClamshell(
            manualPreference: clamshellPreferred, agentRequiresWake: agentRequiresWake
        )
    }
    private var shouldPauseForScreenLock: Bool {
        KeepAwakeAgentPolicy.shouldPauseForLock(
            locked: screenLocked,
            pauseEnabled: self.defaults.bool(forKey: KeepAwakeDefaultsKey.pauseWhenLocked),
            agentRequiresWake: agentRequiresWake
        )
    }

    private static let screenLockNotification = Notification.Name("com.apple.screenIsLocked")
    private static let screenUnlockNotification = Notification.Name("com.apple.screenIsUnlocked")

    init(
        defaults: UserDefaults = .standard,
        monitorSystem: Bool = true,
        clamshellWrite: @escaping (Bool, @escaping (Bool) -> Void) -> Void = KeepAwakeSudoers.pmsetDisableSleep,
        clamshellRestoreSync: @escaping () -> Bool = { KeepAwakeSudoers.pmsetDisableSleep(false) },
        clamshellConfigured: Bool? = nil,
        batterySnapshot: @escaping () -> KeepAwakeBatteryInfo? = KeepAwakeSystemInfo.batterySnapshot
    ) {
        self.defaults = defaults
        self.monitorSystem = monitorSystem
        self.clamshellWrite = clamshellWrite
        self.clamshellRestoreSync = clamshellRestoreSync
        self.batterySnapshot = batterySnapshot
        KeepAwakePreferences.registerDefaults(in: defaults)
        clamshellPreferred = self.defaults.bool(
            forKey: KeepAwakeDefaultsKey.clamshellPreferred
        )
        whileAgentsWork = self.defaults.bool(forKey: KeepAwakeDefaultsKey.whileAgentsWork)

        if let clamshellConfigured {
            passwordlessClamshell = clamshellConfigured
        } else {
            refreshPasswordlessStatus()
        }
        guard monitorSystem else { return }
        defaultsObserver = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.preferenceSyncScheduled else { return }
                    self.preferenceSyncScheduled = true
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.preferenceSyncScheduled = false
                        self.syncWithPreferences()
                    }
                }
            }

        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.accessibilityTrusted = KeepAwakeAccessibility.isTrusted
            }
        }
    }

    deinit {
        endTimer?.invalidate()
        batteryTimer?.invalidate()
        mouseJiggleTimer?.invalidate()
        automationEvaluationWorkItem?.cancel()
        if let appActiveObserver { NotificationCenter.default.removeObserver(appActiveObserver) }
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        let center = DistributedNotificationCenter.default()
        for observer in screenLockObservers { center.removeObserver(observer) }
        if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .defaultMode)
        }
        assertions.deactivate()
    }

    func toggle() {
        if isActive {
            if sessionTrigger == .automation || !currentMatchingAutomationConditions().isEmpty {
                automationSuppressedUntilConditionsClear = true
            }
            deactivate(reason: .manual)
        } else {
            activate(minutes: KeepAwakePolicy.sanitizedDuration(
                self.defaults.integer(forKey: KeepAwakeDefaultsKey.defaultDuration)
            ))
        }
    }

    func activate(minutes: Int) {
        automationSuppressedUntilConditionsClear = false
        if !whileAgentsWork { KeepAwakeNotifier.requestPermissionIfNeeded() }
        activate(minutes: minutes, trigger: .manual)
    }

    func activateOnLaunchIfNeeded() {
        guard self.defaults.bool(forKey: KeepAwakeDefaultsKey.autoStart), !isActive else {
            return
        }
        activate(
            minutes: KeepAwakePolicy.sanitizedDuration(
                self.defaults.integer(forKey: KeepAwakeDefaultsKey.defaultDuration)
            ),
            trigger: .manual
        )
    }

    func extend(minutes: Int) {
        guard isActive, let currentEnd = endDate, minutes > 0 else { return }
        let newEnd = max(currentEnd, Date()).addingTimeInterval(TimeInterval(minutes * 60))
        endDate = newEnd
        scheduleEnd(at: newEnd)
    }

    func deactivate(reason: EndReason) {
        let hadSession = isActive
        if reason == .quit {
            isQuitting = true
            stopAutomationMonitoring()
        }

        endTimer?.invalidate()
        endTimer = nil
        endDate = nil
        assertions.deactivate()
        if clamshellActive
            || clamshellActivationPending
            || self.defaults.bool(forKey: KeepAwakeDefaultsKey.sleepDisabledFlag) {
            disableClamshell(synchronous: reason == .quit)
        }
        sessionTrigger = nil
        activeAutomationConditions.removeAll()
        isActive = false
        isPausedForScreenLock = false
        stopBatteryWatch()
        stopMouseJiggleTimer()

        if hadSession, reason != .quit, reason != .manual {
            onSessionEnded?(reason)
        }
    }

    func syncWithPreferences() {
        guard !isQuitting else { return }
        syncAutomationMonitoring()
        if isActive, !isPausedForScreenLock {
            applyAssertions()
            checkBattery()
        }
        syncMouseJiggleTimer()
    }

    func agentActivityDidChange(hasWorkingAgent: Bool) {
        guard !isQuitting, self.hasWorkingAgent != hasWorkingAgent else { return }
        self.hasWorkingAgent = hasWorkingAgent
        evaluateAutomation()
    }

    func reportBrightnessError(_ error: String?) {
        if brightnessError != error { brightnessError = error }
    }

    func automationPreferencesDidChange() {
        automationSuppressedUntilConditionsClear = false
        syncWithPreferences()
    }

    func refreshAccessibilityStatus() {
        accessibilityTrusted = KeepAwakeAccessibility.isTrusted
    }

    func requestAccessibility() {
        KeepAwakeAccessibility.request()
        KeepAwakeAccessibility.openSettings()
        refreshAccessibilityStatus()
    }

    func refreshPasswordlessStatus() {
        DispatchQueue.global(qos: .utility).async {
            let configured = KeepAwakeSudoers.isConfigured()
            let present = KeepAwakeSudoers.ruleFilePresent
            DispatchQueue.main.async {
                self.passwordlessClamshell = configured
                self.clamshellRulePresent = present
            }
        }
    }

    func removeClamshellPermission() {
        guard !clamshellSetupInProgress else { return }
        whileAgentsWork = false
        clamshellPreferred = false
        clamshellSetupInProgress = true
        clamshellSetupFailed = false

        let needsRestore = self.defaults.bool(forKey: KeepAwakeDefaultsKey.sleepDisabledFlag)
        DispatchQueue.global(qos: .userInitiated).async {
            if needsRestore {
                guard KeepAwakeSudoers.pmsetDisableSleep(false) else {
                    DispatchQueue.main.async {
                        self.clamshellSetupInProgress = false
                        self.clamshellSetupFailed = true
                        self.lastError = "Не удалось восстановить обычный сон Mac"
                    }
                    return
                }
                DispatchQueue.main.async {
                    self.defaults.set(false, forKey: KeepAwakeDefaultsKey.sleepDisabledFlag)
                }
            }

            KeepAwakeSudoers.remove { ok in
                DispatchQueue.main.async {
                    self.clamshellSetupInProgress = false
                    self.passwordlessClamshell = false
                    self.clamshellRulePresent = KeepAwakeSudoers.ruleFilePresent
                    self.clamshellSetupFailed = !ok
                    if !ok { self.lastError = "Не удалось удалить системное разрешение" }
                }
            }
        }
    }

    /// Repairs a prior crash before any automatic session can start.
    func recoverIfNeeded(completion: (() -> Void)? = nil) {
        guard self.defaults.bool(forKey: KeepAwakeDefaultsKey.sleepDisabledFlag) else {
            finishRecovery(completion)
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let report = KeepAwakeShell.run("/usr/bin/pmset", ["-g"])
            let stillDisabled = KeepAwakeSudoersSupport.sleepDisabled(inPmsetOutput: report.output)
            if stillDisabled, KeepAwakeSudoers.pmsetDisableSleep(false) {
                DispatchQueue.main.async {
                    self.defaults.set(false, forKey: KeepAwakeDefaultsKey.sleepDisabledFlag)
                    self.finishRecovery(completion)
                }
                return
            }

            DispatchQueue.main.async {
                if stillDisabled {
                    KeepAwakeAdminShell.run(
                        "/usr/bin/pmset disablesleep 0",
                        prompt: "drem восстанавливает обычный режим сна после прошлого аварийного завершения."
                    ) { ok in
                        DispatchQueue.main.async {
                            if ok {
                                self.defaults.set(
                                    false,
                                    forKey: KeepAwakeDefaultsKey.sleepDisabledFlag
                                )
                            } else {
                                self.lastError = "Не удалось восстановить сон после прошлого запуска"
                            }
                            self.finishRecovery(completion)
                        }
                    }
                } else {
                    self.defaults.set(false, forKey: KeepAwakeDefaultsKey.sleepDisabledFlag)
                    self.finishRecovery(completion)
                }
            }
        }
    }

    private func finishRecovery(_ completion: (() -> Void)?) {
        recoveryCompleted = true
        completion?()
        syncWithPreferences()
    }

    func activate(minutes: Int, trigger: SessionTrigger) {
        guard !isQuitting else { return }
        // Every manual entry point (switch, hotkey, menu, launch) obeys the
        // selected agent mode instead of creating a second, indefinite owner.
        if trigger == .manual, whileAgentsWork {
            evaluateAutomation()
            return
        }
        let duration = KeepAwakePolicy.sanitizedDuration(minutes)
        endTimer?.invalidate()
        endTimer = nil
        lastError = nil

        syncScreenLockMonitoring()
        isPausedForScreenLock = shouldPauseForScreenLock
        sessionTrigger = trigger
        if trigger == .manual { activeAutomationConditions.removeAll() }
        isActive = true

        if duration > 0 {
            let date = Date().addingTimeInterval(TimeInterval(duration * 60))
            endDate = date
            scheduleEnd(at: date)
        } else {
            endDate = nil
        }

        if !isPausedForScreenLock {
            applyAssertions()
            guard isActive else { return }
            startBatteryWatch()
        }
        syncMouseJiggleTimer()
        syncClamshellDemand()
    }

    private func applyAssertions() {
        do {
            try assertions.activate(
                allowDisplaySleep: self.defaults.bool(
                    forKey: KeepAwakeDefaultsKey.allowDisplaySleep
                )
            )
        } catch {
            lastError = error.localizedDescription
            if !assertions.hasSystemAssertion {
                endTimer?.invalidate()
                endTimer = nil
                endDate = nil
                sessionTrigger = nil
                activeAutomationConditions.removeAll()
                isActive = false
                stopBatteryWatch()
                stopMouseJiggleTimer()
            }
        }
    }

    // MARK: - Automatic sessions

    private func syncAutomationMonitoring() {
        if monitorSystem {
            syncScreenLockMonitoring()
            setScreenMonitoringEnabled(
                !whileAgentsWork && self.defaults.bool(forKey: KeepAwakeDefaultsKey.externalDisplay)
            )
            setPowerMonitoringEnabled(
                self.defaults.bool(forKey: KeepAwakeDefaultsKey.connectedToPower)
                    || whileAgentsWork
            )
        }
        evaluateAutomation()
    }

    private func syncScreenLockMonitoring() {
        guard monitorSystem else { return }
        let enabled = self.defaults.bool(forKey: KeepAwakeDefaultsKey.pauseWhenLocked)
        let center = DistributedNotificationCenter.default()

        if enabled {
            guard screenLockObservers.isEmpty else { return }
            screenLockObservers = [
                center.addObserver(
                    forName: Self.screenLockNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.screenLockStateDidChange(locked: true) }
                },
                center.addObserver(
                    forName: Self.screenUnlockNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.screenLockStateDidChange(locked: false) }
                },
            ]
            screenLocked = KeepAwakeAutomationSupport.isScreenLocked(
                sessionDictionary: CGSessionCopyCurrentDictionary() as? [String: Any]
            )
            syncSessionWithScreenLock()
        } else {
            guard !screenLockObservers.isEmpty else { return }
            for observer in screenLockObservers { center.removeObserver(observer) }
            screenLockObservers.removeAll()
            screenLocked = false
            syncSessionWithScreenLock()
        }
    }

    func screenLockStateDidChange(locked: Bool) {
        guard screenLocked != locked else { return }
        screenLocked = locked
        syncSessionWithScreenLock()
        evaluateAutomation()
    }

    private func syncSessionWithScreenLock() {
        guard isActive else {
            isPausedForScreenLock = false
            return
        }
        let shouldPause = shouldPauseForScreenLock
        guard shouldPause != isPausedForScreenLock else { return }

        if shouldPause {
            isPausedForScreenLock = true
            assertions.deactivate()
            if clamshellActive || clamshellActivationPending {
                disableClamshell(synchronous: false)
            }
            stopBatteryWatch()
            stopMouseJiggleTimer()
            return
        }

        isPausedForScreenLock = false
        if let endDate, endDate <= Date() {
            if !continueAutomaticallyAfterTimerIfNeeded() { deactivate(reason: .timer) }
            return
        }
        if sessionTrigger == .automation, currentMatchingAutomationConditions().isEmpty {
            deactivate(reason: .manual)
            return
        }
        applyAssertions()
        guard isActive else { return }
        startBatteryWatch()
        syncMouseJiggleTimer()
        syncClamshellDemand()
    }

    private func setScreenMonitoringEnabled(_ enabled: Bool) {
        if enabled {
            guard screenParametersObserver == nil else { return }
            screenParametersObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleAutomationEvaluation(after: 0.35)
                }
            }
        } else if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
            lastExternalDisplayConnected = nil
        }
    }

    private func setPowerMonitoringEnabled(_ enabled: Bool) {
        if enabled {
            guard powerSourceRunLoopSource == nil else { return }
            let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            powerSourceRunLoopSource = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                let manager = Unmanaged<KeepAwakeManager>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.scheduleAutomationEvaluation(after: 0.1)
                }
            }, context)?.takeRetainedValue()
            if let powerSourceRunLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .defaultMode)
            }
        } else if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .defaultMode)
            self.powerSourceRunLoopSource = nil
        }
    }

    private func scheduleAutomationEvaluation(after delay: TimeInterval) {
        automationEvaluationWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.automationEvaluationWorkItem = nil
            self?.evaluateAutomation()
        }
        automationEvaluationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func stopAutomationMonitoring() {
        automationEvaluationWorkItem?.cancel()
        automationEvaluationWorkItem = nil
        setScreenMonitoringEnabled(false)
        setPowerMonitoringEnabled(false)
        let center = DistributedNotificationCenter.default()
        for observer in screenLockObservers { center.removeObserver(observer) }
        screenLockObservers.removeAll()
        screenLocked = false
        isPausedForScreenLock = false
        activeAutomationConditions.removeAll()
    }

    private func evaluateAutomation() {
        guard recoveryCompleted, !isQuitting else { return }
        let matches = currentMatchingAutomationConditions()

        if whileAgentsWork, sessionTrigger == .manual {
            // Transfer ownership without briefly releasing assertions or lid
            // protection. A previous timer must never outlive/control this mode.
            endTimer?.invalidate()
            endTimer = nil
            endDate = nil
            sessionTrigger = .automation
        }

        if automationSuppressedUntilConditionsClear {
            if matches.isEmpty { automationSuppressedUntilConditionsClear = false }
            if sessionTrigger == .automation { deactivate(reason: .manual) }
            return
        }

        syncSessionWithScreenLock()
        if shouldPauseForScreenLock {
            if sessionTrigger == .automation { activeAutomationConditions = matches }
            if sessionTrigger == .automation, matches.isEmpty { deactivate(reason: .manual) }
            return
        }

        if sessionTrigger == .automation { activeAutomationConditions = matches }
        let action = KeepAwakeAutomationSupport.action(
            matchingConditions: matches,
            sessionActive: isActive,
            automaticSessionActive: isActive && sessionTrigger == .automation
        )
        switch action {
        case .none:
            break
        case .activate:
            guard automaticSessionAllowedByBatteryProtection() else { return }
            activeAutomationConditions = matches
            activate(minutes: 0, trigger: .automation)
        case .deactivate:
            deactivate(reason: .manual)
        }
        syncClamshellDemand()
    }

    private func currentMatchingAutomationConditions() -> Set<KeepAwakeAutomationCondition> {
        let defaults = self.defaults
        let externalDisplayEnabled = !whileAgentsWork && defaults.bool(forKey: KeepAwakeDefaultsKey.externalDisplay)
        let externalDisplayConnected: Bool
        if externalDisplayEnabled {
            if let current = Self.hasExternalDisplay() { lastExternalDisplayConnected = current }
            externalDisplayConnected = lastExternalDisplayConnected ?? false
        } else {
            externalDisplayConnected = false
        }

        let powerEnabled = !whileAgentsWork && defaults.bool(forKey: KeepAwakeDefaultsKey.connectedToPower)
        let connectedToPower = powerEnabled
            && (batterySnapshot().map { !$0.isOnBattery } ?? false)
        return KeepAwakeAutomationSupport.matchingConditions(
            externalDisplayEnabled: externalDisplayEnabled,
            externalDisplayConnected: externalDisplayConnected,
            powerEnabled: powerEnabled,
            connectedToPower: connectedToPower,
            agentsEnabled: whileAgentsWork,
            hasWorkingAgent: hasWorkingAgent
        )
    }

    private static func hasExternalDisplay() -> Bool? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        guard count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return KeepAwakeAutomationSupport.hasExternalDisplay(
            builtInFlags: displays.prefix(Int(count)).map { CGDisplayIsBuiltin($0) != 0 }
        )
    }

    private func automaticSessionAllowedByBatteryProtection() -> Bool {
        let limit = KeepAwakePolicy.sanitizedBatteryLimit(
            self.defaults.integer(forKey: KeepAwakeDefaultsKey.batteryLimit)
        )
        guard limit > 0,
              let battery = batterySnapshot(),
              battery.isOnBattery else { return true }
        return battery.percent > limit
    }

    private func continueAutomaticallyAfterTimerIfNeeded() -> Bool {
        guard sessionTrigger == .manual,
              !automationSuppressedUntilConditionsClear,
              automaticSessionAllowedByBatteryProtection() else { return false }
        let matches = currentMatchingAutomationConditions()
        guard !matches.isEmpty else { return false }
        activeAutomationConditions = matches
        activate(minutes: 0, trigger: .automation)
        return true
    }

    private func scheduleEnd(at date: Date) {
        endTimer?.invalidate()
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.continueAutomaticallyAfterTimerIfNeeded() {
                    self.deactivate(reason: .timer)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        endTimer = timer
    }

    // MARK: - Closed lid

    private func syncClamshellDemand() {
        guard !isQuitting else { return }
        if isActive, !isPausedForScreenLock, clamshellRequested {
            applyClamshellPreference()
        } else if clamshellState.desired || clamshellActive || clamshellActivationPending {
            disableClamshell(synchronous: false)
        }
    }

    private func applyClamshellPreference() {
        guard !isQuitting, !handlingClamshellFailure,
              clamshellConfigurationRequested, !clamshellSetupFailed else { return }
        if passwordlessClamshell {
            if isActive, clamshellRequested, !isPausedForScreenLock { enableClamshell() }
        } else {
            prepareClamshellPreference()
        }
    }

    private func prepareClamshellPreference() {
        guard !isQuitting, clamshellConfigurationRequested, !clamshellSetupInProgress else { return }
        clamshellSetupInProgress = true
        clamshellSetupFailed = false

        DispatchQueue.global(qos: .userInitiated).async {
            if KeepAwakeSudoers.isConfigured() {
                DispatchQueue.main.async { self.finishClamshellSetup(ok: true) }
                return
            }
            KeepAwakeSudoers.install { ok in
                DispatchQueue.main.async { self.finishClamshellSetup(ok: ok) }
            }
        }
    }

    private func finishClamshellSetup(ok: Bool) {
        guard !isQuitting else { return }
        clamshellSetupInProgress = false
        passwordlessClamshell = ok
        clamshellRulePresent = KeepAwakeSudoers.ruleFilePresent
        guard ok else {
            markClamshellSetupFailed()
            return
        }
        if isActive, clamshellRequested, !isPausedForScreenLock { enableClamshell() }
    }

    private func markClamshellSetupFailed() {
        clamshellSetupInProgress = false
        guard clamshellConfigurationRequested else { return }
        handlingClamshellFailure = true
        defer { handlingClamshellFailure = false }
        // Disable the failed opt-in, rather than reporting closed-lid protection
        // that could not actually be established or repeatedly asking for a password.
        whileAgentsWork = false
        clamshellPreferred = false
        clamshellSetupFailed = true
        lastError = "Не удалось настроить режим закрытой крышки"
    }

    private func enableClamshell() {
        guard !isQuitting, isActive, clamshellRequested, !isPausedForScreenLock else { return }
        if let operation = clamshellState.request(true) { performClamshellOperation(operation) }
    }

    private func disableClamshell(synchronous: Bool) {
        if synchronous {
            // The serial queue drains any pending enable before this restore.
            // Late main-queue callbacks are ignored after application quit begins.
            let ok = clamshellRestoreSync()
            if ok {
                clamshellState = KeepAwakeClamshellState()
                clamshellActive = false
                self.defaults.set(false, forKey: KeepAwakeDefaultsKey.sleepDisabledFlag)
            } else {
                lastError = "Не удалось восстановить обычный режим сна Mac"
            }
        } else if let operation = clamshellState.request(false) {
            performClamshellOperation(operation)
        }
    }

    private func performClamshellOperation(_ enabled: Bool) {
        if enabled {
            // Record ownership BEFORE the system write, closing the crash window
            // between pmset succeeding and its main-queue callback executing.
            self.defaults.set(true, forKey: KeepAwakeDefaultsKey.sleepDisabledFlag)
        }
        clamshellWrite(enabled) { usedPasswordless in
            let ok = usedPasswordless || (!enabled && KeepAwakeAdminShell.runSync(
                "/usr/bin/pmset disablesleep 0",
                prompt: "drem должен восстановить обычный режим сна Mac."
            ))
            DispatchQueue.main.async {
                guard !self.isQuitting else { return }
                let next = self.clamshellState.complete(success: ok)
                self.clamshellActive = self.clamshellState.active
                if ok {
                    self.defaults.set(enabled, forKey: KeepAwakeDefaultsKey.sleepDisabledFlag)
                    self.clamshellSetupRetried = false
                    if let next { self.performClamshellOperation(next) }
                } else if enabled {
                    self.passwordlessClamshell = false
                    guard self.clamshellConfigurationRequested else { return }
                    if self.clamshellSetupRetried {
                        self.markClamshellSetupFailed()
                    } else {
                        self.clamshellSetupRetried = true
                        self.prepareClamshellPreference()
                    }
                } else {
                    self.lastError = "Не удалось восстановить обычный режим сна Mac"
                }
            }
        }
    }

    // MARK: - Battery protection

    private func startBatteryWatch() {
        stopBatteryWatch()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkBattery() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        batteryTimer = timer
        checkBattery()
    }

    private func stopBatteryWatch() {
        batteryTimer?.invalidate()
        batteryTimer = nil
    }

    private func checkBattery() {
        let limit = KeepAwakePolicy.sanitizedBatteryLimit(
            self.defaults.integer(forKey: KeepAwakeDefaultsKey.batteryLimit)
        )
        guard limit > 0, isActive,
              let battery = batterySnapshot(),
              battery.isOnBattery,
              battery.percent <= limit else { return }
        deactivate(reason: .battery)
    }

    // MARK: - Optional pointer activity

    private func syncMouseJiggleTimer() {
        guard isActive,
              !isPausedForScreenLock,
              self.defaults.bool(forKey: KeepAwakeDefaultsKey.mouseJiggleEnabled)
        else {
            stopMouseJiggleTimer()
            return
        }

        let minutes = KeepAwakePolicy.sanitizedMouseJiggleInterval(
            self.defaults.integer(forKey: KeepAwakeDefaultsKey.mouseJiggleInterval)
        )
        let interval = TimeInterval(minutes * 60)
        if mouseJiggleTimer?.timeInterval == interval { return }

        stopMouseJiggleTimer()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.jiggleMousePointer() }
        }
        timer.tolerance = min(10, interval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        mouseJiggleTimer = timer
    }

    private func stopMouseJiggleTimer() {
        mouseJiggleTimer?.invalidate()
        mouseJiggleTimer = nil
        pendingMouseReturn?.cancel()
        pendingMouseReturn = nil
    }

    private func jiggleMousePointer() {
        guard isActive,
              self.defaults.bool(forKey: KeepAwakeDefaultsKey.mouseJiggleEnabled),
              let original = CGEvent(source: nil)?.location,
              let target = Self.mouseJiggleTarget(from: original),
              Self.postMouseMove(to: target) else {
            syncMouseJiggleTimer()
            return
        }

        pendingMouseReturn?.cancel()
        let returnMove = DispatchWorkItem { [weak self] in
            self?.pendingMouseReturn = nil
            guard let current = CGEvent(source: nil)?.location,
                  abs(current.x - target.x) <= 2,
                  abs(current.y - target.y) <= 2 else { return }
            _ = Self.postMouseMove(to: original)
        }
        pendingMouseReturn = returnMove
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: returnMove)
    }

    private static func mouseJiggleTarget(from original: CGPoint) -> CGPoint? {
        guard let bounds = displayBounds(containing: original) else { return nil }
        let safe = bounds.insetBy(dx: 2, dy: 2)
        let x = min(max(original.x, safe.minX), safe.maxX)
        let y = min(max(original.y, safe.minY), safe.maxY)
        if x + 1 <= safe.maxX { return CGPoint(x: x + 1, y: y) }
        if x - 1 >= safe.minX { return CGPoint(x: x - 1, y: y) }
        if y + 1 <= safe.maxY { return CGPoint(x: x, y: y + 1) }
        if y - 1 >= safe.minY { return CGPoint(x: x, y: y - 1) }
        return nil
    }

    private static func displayBounds(containing point: CGPoint) -> CGRect? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return nil
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        for display in displays.prefix(Int(count)) {
            let bounds = CGDisplayBounds(display)
            if bounds.contains(point) { return bounds }
        }
        return nil
    }

    private static func postMouseMove(to point: CGPoint) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }
}
