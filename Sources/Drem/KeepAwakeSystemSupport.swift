// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 drem contributors

import DremCore
import AppKit
import ApplicationServices
import Darwin
import Foundation
import IOKit.ps
import UserNotifications
import os.log

private final class BoundedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let available = max(0, limit - data.count)
        if available > 0 { data.append(chunk.prefix(available)) }
    }

    func value() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

enum BoundedProcessRunner {
    struct Result {
        let status: Int32
        let output: Data
        let timedOut: Bool
    }

    static func run(
        _ path: String,
        _ arguments: [String],
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let output = BoundedProcessOutput(limit: maxOutputBytes)
        let drained = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                drained.signal()
            } else {
                // Keep draining even after the retained prefix is full so a
                // noisy child can never block on its stdout pipe.
                output.append(chunk)
            }
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            reader.readabilityHandler = nil
            try? reader.close()
            return Result(status: -1, output: Data(), timedOut: false)
        }

        var didFinish = finished.wait(timeout: .now() + max(0, timeout)) == .success
        let timedOut = !didFinish
        if timedOut {
            process.terminate()
            didFinish = finished.wait(timeout: .now() + 0.5) == .success
            if !didFinish {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.5)
            }
        }

        _ = drained.wait(timeout: .now() + 0.2)
        reader.readabilityHandler = nil
        try? reader.close()

        return Result(
            status: timedOut ? -1 : process.terminationStatus,
            output: output.value(),
            timedOut: timedOut
        )
    }
}

enum KeepAwakeShell {
    @discardableResult
    static func run(
        _ path: String,
        _ arguments: [String],
        timeout: TimeInterval = 5,
        maxOutputBytes: Int = 1024 * 1024
    ) -> (status: Int32, output: String) {
        let result = BoundedProcessRunner.run(
            path,
            arguments,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes
        )
        return (result.status, String(decoding: result.output, as: UTF8.self))
    }
}

/// Runs in a tiny child process while closed-lid sleep is disabled. The child
/// blocks on stdin without polling; if the owning drem process exits or is
/// force-quit, the pipe reaches EOF and the child restores normal sleep.
enum ClamshellSleepGuardWorker {
    static let argument = "--clamshell-sleep-guard"

    static func run(
        input: FileHandle = .standardInput,
        readyOutput: FileHandle? = .standardOutput,
        setSleepDisabled: (Bool) -> Bool = KeepAwakeSudoers.pmsetDisableSleep
    ) -> Int32 {
        guard setSleepDisabled(true) else {
            readyOutput?.write(Data([0]))
            return 1
        }

        readyOutput?.write(Data([1]))
        _ = input.readDataToEndOfFile()
        return setSleepDisabled(false) ? 0 : 2
    }
}

private final class ClamshellProcessExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var didExit = false

    func signal() {
        lock.lock()
        guard !didExit else {
            lock.unlock()
            return
        }
        didExit = true
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: DispatchTime) -> Bool {
        lock.lock()
        let alreadyExited = didExit
        lock.unlock()
        return alreadyExited || semaphore.wait(timeout: timeout) == .success
    }
}

private final class ClamshellReadySignal: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var completed = false
    private var byte: UInt8?

    func receive(_ data: Data) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        byte = data.first
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> UInt8? {
        guard semaphore.wait(timeout: .now() + max(0, timeout)) == .success else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return byte
    }
}

/// Serialized owner for the crash-safe closed-lid helper. Every wait is bounded:
/// a stale Foundation `Process` can never occupy the lifecycle queue forever.
final class KeepAwakeClamshellGuardController: @unchecked Sendable {
    private struct Child {
        let process: Process
        let input: Pipe
        let exitSignal: ClamshellProcessExitSignal
    }

    private let lifecycleQueue: DispatchQueue
    private let processFactory: () -> Process?
    private let restoreSleep: () -> Bool
    private let handshakeTimeout: TimeInterval
    private let exitTimeout: TimeInterval
    private let terminationGrace: TimeInterval
    private var child: Child?

    init(
        label: String,
        processFactory: @escaping () -> Process?,
        restoreSleep: @escaping () -> Bool,
        handshakeTimeout: TimeInterval,
        exitTimeout: TimeInterval,
        terminationGrace: TimeInterval
    ) {
        lifecycleQueue = DispatchQueue(label: label)
        self.processFactory = processFactory
        self.restoreSleep = restoreSleep
        self.handshakeTimeout = handshakeTimeout
        self.exitTimeout = exitTimeout
        self.terminationGrace = terminationGrace
    }

    func setEnabled(_ enabled: Bool, completion: @escaping (Bool) -> Void) {
        lifecycleQueue.async {
            completion(enabled ? self.startOnQueue() : self.stopOnQueue())
        }
    }

    func restoreSync() -> Bool {
        lifecycleQueue.sync { stopOnQueue() }
    }

    private func startOnQueue() -> Bool {
        if let child, isAlive(child) { return true }
        if let child {
            closeInput(child)
            _ = stop(child, initialWait: 0)
            clearChildOnQueue()
            _ = restoreSleep()
        }

        guard let process = processFactory() else { return false }
        let input = Pipe()
        let ready = Pipe()
        let readySignal = ClamshellReadySignal()
        let exitSignal = ClamshellProcessExitSignal()
        let reader = ready.fileHandleForReading

        reader.readabilityHandler = { handle in
            readySignal.receive(handle.availableData)
        }
        process.terminationHandler = { _ in exitSignal.signal() }
        process.standardInput = input
        process.standardOutput = ready
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            try? input.fileHandleForReading.close()
            try? ready.fileHandleForWriting.close()
        } catch {
            reader.readabilityHandler = nil
            try? input.fileHandleForReading.close()
            try? input.fileHandleForWriting.close()
            try? reader.close()
            try? ready.fileHandleForWriting.close()
            return false
        }

        let candidate = Child(process: process, input: input, exitSignal: exitSignal)
        let readyByte = readySignal.wait(timeout: handshakeTimeout)
        reader.readabilityHandler = nil
        try? reader.close()

        guard readyByte == 1, isAlive(candidate) else {
            closeInput(candidate)
            _ = stop(candidate, initialWait: 0)
            clear(candidate)
            // A failed or interrupted handshake must never leave the durable
            // pmset switch behind.
            _ = restoreSleep()
            return false
        }

        child = candidate
        return true
    }

    private func stopOnQueue() -> Bool {
        guard let child else {
            clearChildOnQueue()
            // Also repairs state left by an older drem build which had no guard.
            return restoreSleep()
        }

        closeInput(child)
        _ = stop(child, initialWait: exitTimeout)
        clearChildOnQueue()

        // Never trust only the child's termination status: if Foundation lost
        // the exit notification, explicitly reconcile the actual pmset state.
        return restoreSleep()
    }

    private func stop(_ child: Child, initialWait: TimeInterval) -> Bool {
        if waitForExit(child, timeout: initialWait) { return true }

        let pid = child.process.processIdentifier
        if Self.kernelReportsAlive(pid) { _ = kill(pid, SIGTERM) }
        if waitForExit(child, timeout: terminationGrace) { return true }

        if Self.kernelReportsAlive(pid) { _ = kill(pid, SIGKILL) }
        return waitForExit(child, timeout: terminationGrace)
    }

    private func waitForExit(_ child: Child, timeout: TimeInterval) -> Bool {
        if child.exitSignal.wait(timeout: .now()) { return true }
        guard Self.kernelReportsAlive(child.process.processIdentifier) else { return true }
        if child.exitSignal.wait(timeout: .now() + max(0, timeout)) { return true }
        return !Self.kernelReportsAlive(child.process.processIdentifier)
    }

    private func isAlive(_ child: Child) -> Bool {
        !child.exitSignal.wait(timeout: .now())
            && Self.kernelReportsAlive(child.process.processIdentifier)
    }

    private static func kernelReportsAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func closeInput(_ child: Child) {
        try? child.input.fileHandleForWriting.close()
    }

    private func clearChildOnQueue() {
        if let child { clear(child) }
        child = nil
    }

    private func clear(_ child: Child) {
        try? child.input.fileHandleForReading.close()
        try? child.input.fileHandleForWriting.close()
    }
}

/// Owns the production guard process from the app side. All transitions are
/// serialized so a late enable cannot outlive a newer disable request.
enum KeepAwakeClamshellGuard {
    private static let controller = KeepAwakeClamshellGuardController(
        label: "local.mrvasil.drem.clamshell-guard",
        processFactory: {
            guard let executable = Bundle.main.executableURL else { return nil }
            let process = Process()
            process.executableURL = executable
            process.arguments = [ClamshellSleepGuardWorker.argument]
            return process
        },
        restoreSleep: { KeepAwakeSudoers.pmsetDisableSleep(false) },
        handshakeTimeout: 6,
        exitTimeout: 6,
        terminationGrace: 0.5
    )

    static func setEnabled(_ enabled: Bool, completion: @escaping (Bool) -> Void) {
        controller.setEnabled(enabled, completion: completion)
    }

    static func restoreSync() -> Bool {
        controller.restoreSync()
    }
}

enum KeepAwakeAdminShell {
    private static let promptLock = NSLock()
    private static var prompting = false

    static func runSync(_ command: String, prompt: String) -> Bool {
        promptLock.lock()
        if prompting {
            promptLock.unlock()
            return false
        }
        prompting = true
        promptLock.unlock()
        defer {
            promptLock.lock()
            prompting = false
            promptLock.unlock()
        }

        bringAppToFront()
        let source = "do shell script \(appleScriptString(command)) with administrator privileges with prompt \(appleScriptString(prompt))"
        return KeepAwakeShell.run("/usr/bin/osascript", ["-e", source], timeout: 600).status == 0
    }

    static func run(_ command: String, prompt: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            completion(runSync(command, prompt: prompt))
        }
    }

    private static func bringAppToFront() {
        if Thread.isMainThread {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            DispatchQueue.main.sync {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        Thread.sleep(forTimeInterval: 0.12)
    }

    private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

enum KeepAwakeSudoers {
    static let rulePath = "/etc/sudoers.d/drem-clamshell"
    // Keep the previous installation working without a new administrator prompt.
    static let legacyRulePath = "/etc/sudoers.d/agent-watch-clamshell"
    private static let sleepStateQueue = DispatchQueue(label: "local.mrvasil.drem.pmset-state")

    static func isConfigured() -> Bool {
        // A different utility may have installed an identical uid-based rule.
        // Require our own file so drem remains self-contained and does
        // not silently lose this capability when that other app is removed.
        guard ruleFilePresent else { return false }
        return sleepStateQueue.sync {
            let report = KeepAwakeShell.run("/usr/bin/pmset", ["-g"])
            guard report.status == 0 else { return false }
            let enabled = KeepAwakeSudoersSupport.sleepDisabled(inPmsetOutput: report.output)
            return pmsetDisableSleepOnQueue(enabled)
        }
    }

    static var ruleFilePresent: Bool {
        FileManager.default.fileExists(atPath: rulePath)
            || FileManager.default.fileExists(atPath: legacyRulePath)
    }

    static func install(completion: @escaping (Bool) -> Void) {
        let rule = KeepAwakeSudoersSupport.clamshellRule(uid: getuid())
        let command = "/bin/mkdir -p /etc/sudoers.d && /bin/chmod 0755 /etc/sudoers.d && /bin/echo '\(rule)' > \(rulePath) && /bin/chmod 0440 \(rulePath) && /usr/sbin/visudo -c -f \(rulePath) || { /bin/rm -f \(rulePath); exit 1; }"
        KeepAwakeAdminShell.run(
            command,
            prompt: "drem требуется один раз разрешить режим работы с закрытой крышкой."
        ) { ok in
            completion(ok && isConfigured())
        }
    }

    static func remove(completion: @escaping (Bool) -> Void) {
        KeepAwakeAdminShell.run(
            "/bin/rm -f \(rulePath) \(legacyRulePath)",
            prompt: "Удалить системное разрешение drem для режима закрытой крышки?",
            completion: completion
        )
    }

    @discardableResult
    static func pmsetDisableSleep(_ enabled: Bool) -> Bool {
        sleepStateQueue.sync { pmsetDisableSleepOnQueue(enabled) }
    }

    static func pmsetDisableSleep(_ enabled: Bool, completion: @escaping (Bool) -> Void) {
        sleepStateQueue.async {
            completion(pmsetDisableSleepOnQueue(enabled))
        }
    }

    private static func pmsetDisableSleepOnQueue(_ enabled: Bool) -> Bool {
        KeepAwakeShell.run(
            "/usr/bin/sudo",
            ["-n", "/usr/bin/pmset", "disablesleep", enabled ? "1" : "0"]
        ).status == 0
    }
}

struct KeepAwakeBatteryInfo: Equatable {
    let percent: Int
    let isCharging: Bool
    let isOnBattery: Bool
}

enum KeepAwakeSystemInfo {
    static func batterySnapshot() -> KeepAwakeBatteryInfo? {
        guard let blobRef = IOPSCopyPowerSourcesInfo() else { return nil }
        let blob = blobRef.takeRetainedValue()
        guard let listRef = IOPSCopyPowerSourcesList(blob) else { return nil }
        let list = listRef.takeRetainedValue() as [AnyObject]
        guard let first = list.first,
              let descriptionRef = IOPSGetPowerSourceDescription(blob, first),
              let description = descriptionRef.takeUnretainedValue() as? [String: Any]
        else { return nil }

        let current = description["Current Capacity"] as? Int ?? 0
        let maximum = description["Max Capacity"] as? Int ?? 100
        let percent = maximum > 0
            ? Int((Double(current) / Double(maximum) * 100).rounded())
            : current
        let state = description["Power Source State"] as? String ?? ""
        return KeepAwakeBatteryInfo(
            percent: percent,
            isCharging: description["Is Charging"] as? Bool ?? false,
            isOnBattery: state == "Battery Power"
        )
    }
}

enum KeepAwakeNotifier {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "local.mrvasil.drem",
        category: "keep-awake-notifications"
    )

    static func requestPermissionIfNeeded() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    log.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
                } else if !granted {
                    log.notice("notification authorization not granted")
                }
            }
        }
    }

    static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            ) { error in
                if let error {
                    log.error("notification delivery failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}

enum KeepAwakeAccessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
