// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 drem contributors

import AppKit
import Carbon.HIToolbox
import Foundation

struct GlobalShortcutModifiers: OptionSet, Hashable {
    let rawValue: Int

    static let control = GlobalShortcutModifiers(rawValue: 1 << 0)
    static let option = GlobalShortcutModifiers(rawValue: 1 << 1)
    static let shift = GlobalShortcutModifiers(rawValue: 1 << 2)
    static let command = GlobalShortcutModifiers(rawValue: 1 << 3)
    static let validMask: GlobalShortcutModifiers = [.control, .option, .shift, .command]

    var hasPrimaryModifier: Bool {
        contains(.control) || contains(.option) || contains(.command)
    }

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(eventFlags: NSEvent.ModifierFlags) {
        var value: GlobalShortcutModifiers = []
        if eventFlags.contains(.control) { value.insert(.control) }
        if eventFlags.contains(.option) { value.insert(.option) }
        if eventFlags.contains(.shift) { value.insert(.shift) }
        if eventFlags.contains(.command) { value.insert(.command) }
        self = value
    }

    var carbonFlags: UInt32 {
        var flags = UInt32(0)
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        if contains(.command) { flags |= UInt32(cmdKey) }
        return flags
    }

    var storageTokens: [String] {
        var tokens: [String] = []
        if contains(.control) { tokens.append("control") }
        if contains(.option) { tokens.append("option") }
        if contains(.shift) { tokens.append("shift") }
        if contains(.command) { tokens.append("command") }
        return tokens
    }

    var keyCaps: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }
}

struct GlobalShortcut: Equatable, Hashable {
    let keyCode: Int64
    let modifiers: GlobalShortcutModifiers

    static let defaultKeepAwake = GlobalShortcut(
        keyCode: Int64(kVK_ANSI_K),
        modifiers: [.control, .option, .command]
    )

    init(keyCode: Int64, modifiers: GlobalShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.validMask)
    }

    init?(storageValue: String) {
        guard let separator = storageValue.firstIndex(of: ":"),
              let keyCode = Int64(storageValue[storageValue.index(after: separator)...]),
              (0...0xFFFF).contains(keyCode)
        else { return nil }

        var modifiers: GlobalShortcutModifiers = []
        for token in storageValue[..<separator].split(separator: "+") {
            switch token {
            case "control": modifiers.insert(.control)
            case "option": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "command": modifiers.insert(.command)
            default: return nil
            }
        }

        self.init(keyCode: keyCode, modifiers: modifiers)
        guard isValid else { return nil }
    }

    var storageValue: String {
        "\(modifiers.storageTokens.joined(separator: "+")):\(keyCode)"
    }

    var displayString: String {
        modifiers.keyCaps + keyLabel
    }

    var isValid: Bool {
        modifiers.hasPrimaryModifier && keyLabel != "Клавиша \(keyCode)"
    }

    var carbonKeyCode: UInt32 { UInt32(exactly: keyCode) ?? 0 }
    var carbonModifiers: UInt32 { modifiers.carbonFlags }

    private var keyLabel: String {
        if let label = Self.keyLabels[Int(keyCode)] { return label }
        return "Клавиша \(keyCode)"
    }

    private static let keyLabels: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_Space: "Space", kVK_Tab: "Tab", kVK_Return: "Return",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

@MainActor
final class KeepAwakeHotkeyManager: ObservableObject {
    static let shared = KeepAwakeHotkeyManager()

    @Published private(set) var registrationFailed = false
    @Published private(set) var isCapturing = false
    @Published private(set) var shortcut = GlobalShortcut.defaultKeepAwake
    @Published private(set) var captureError: String?

    var onActivate: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var registeredShortcut: GlobalShortcut?
    private var localMonitor: Any?

    private init() {
        reloadShortcut()
    }

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func syncWithPreferences() {
        reloadShortcut()
        setEnabled(UserDefaults.standard.bool(forKey: KeepAwakeDefaultsKey.hotkeyEnabled))
    }

    func setEnabled(_ enabled: Bool) {
        if enabled, !isCapturing {
            register()
        } else {
            unregister()
        }
    }

    func beginCapture() {
        guard !isCapturing else {
            cancelCapture()
            return
        }

        unregister()
        isCapturing = true
        captureError = nil
        NSApp.activate(ignoringOtherApps: true)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor [weak self] in self?.capture(event) }
            return nil
        }
    }

    func cancelCapture() {
        stopCaptureMonitor()
        captureError = nil
        syncWithPreferences()
    }

    func resetToDefault() {
        UserDefaults.standard.set(
            GlobalShortcut.defaultKeepAwake.storageValue,
            forKey: KeepAwakeDefaultsKey.shortcut
        )
        syncWithPreferences()
    }

    private func capture(_ event: NSEvent) {
        guard isCapturing else { return }
        if Int(event.keyCode) == kVK_Escape {
            cancelCapture()
            return
        }

        let candidate = GlobalShortcut(
            keyCode: Int64(event.keyCode),
            modifiers: GlobalShortcutModifiers(eventFlags: event.modifierFlags)
        )
        guard candidate.isValid else {
            captureError = "Добавьте Control, Option или Command"
            return
        }

        UserDefaults.standard.set(candidate.storageValue, forKey: KeepAwakeDefaultsKey.shortcut)
        stopCaptureMonitor()
        shortcut = candidate
        syncWithPreferences()
    }

    private func stopCaptureMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        isCapturing = false
    }

    private func reloadShortcut() {
        let raw = UserDefaults.standard.string(forKey: KeepAwakeDefaultsKey.shortcut) ?? ""
        shortcut = GlobalShortcut(storageValue: raw) ?? .defaultKeepAwake
    }

    private func register() {
        let wanted = shortcut
        if hotKeyRef != nil, registeredShortcut == wanted { return }
        unregister()

        if eventHandler == nil {
            var spec = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            InstallEventHandler(
                GetEventDispatcherTarget(),
                { _, event, userData -> OSStatus in
                    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                    var hotKeyID = EventHotKeyID()
                    GetEventParameter(
                        event,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &hotKeyID
                    )
                    guard hotKeyID.signature == 0x4157_4B41, hotKeyID.id == 1
                    else { return OSStatus(eventNotHandledErr) }
                    let manager = Unmanaged<KeepAwakeHotkeyManager>
                        .fromOpaque(userData).takeUnretainedValue()
                    DispatchQueue.main.async { manager.onActivate?() }
                    return noErr
                },
                1,
                &spec,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandler
            )
        }

        let id = EventHotKeyID(signature: 0x4157_4B41, id: 1) // 'AWKA'
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            wanted.carbonKeyCode,
            wanted.carbonModifiers,
            id,
            GetEventDispatcherTarget(),
            0,
            &reference
        )
        if status == noErr, let reference {
            hotKeyRef = reference
            registeredShortcut = wanted
            registrationFailed = false
        } else {
            hotKeyRef = nil
            registeredShortcut = nil
            registrationFailed = true
        }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registeredShortcut = nil
        registrationFailed = false
    }
}
