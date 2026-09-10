// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 drem contributors

import ApplicationServices
import Carbon.HIToolbox
import Darwin

/// A narrow imperative bridge to the real macOS login screen. The private
/// symbol is loaded dynamically and never assumed to exist; the documented
/// Lock Screen shortcut is the Accessibility-gated fallback.
struct SystemScreenLocker {
    let canRequestPrimary: () -> Bool
    let canRequestFallback: () -> Bool
    let requestPrimary: () -> Bool
    let requestFallback: () -> Bool

    static let live = SystemScreenLocker(
        canRequestPrimary: { primaryFunction != nil },
        canRequestFallback: { CGPreflightPostEventAccess() },
        requestPrimary: {
            guard let function = primaryFunction else { return false }
            function()
            return true
        },
        requestFallback: requestLockShortcut
    )

    private typealias LockFunction = @convention(c) () -> Void

    // The binary may live only in the dyld shared cache on current macOS, so
    // test dlopen rather than checking for an ordinary file first. Keep the
    // successful handle open for the lifetime of the process.
    private static let primaryFunction: LockFunction? = {
        let paths = [
            "/System/Library/PrivateFrameworks/login.framework/Versions/A/login",
            "/System/Library/PrivateFrameworks/login.framework/login",
        ]
        for path in paths {
            guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { continue }
            guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
                dlclose(handle)
                continue
            }
            return unsafeBitCast(symbol, to: LockFunction.self)
        }
        return nil
    }()

    private static func requestLockShortcut() -> Bool {
        guard CGPreflightPostEventAccess(),
              let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: false
              ) else { return false }
        keyDown.flags = [.maskCommand, .maskControl]
        keyUp.flags = [.maskCommand, .maskControl]
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
