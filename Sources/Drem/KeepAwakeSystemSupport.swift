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
