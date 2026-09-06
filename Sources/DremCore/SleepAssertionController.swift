// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 drem contributors

import Foundation
import IOKit.pwr_mgt

public enum SleepAssertionError: LocalizedError {
    case systemAssertion(IOReturn)
    case displayAssertion(IOReturn)

    public var errorDescription: String? {
        switch self {
        case .systemAssertion(let code):
            return "Не удалось запретить сон системы (IOKit: \(code))"
        case .displayAssertion(let code):
            return "Не удалось удерживать дисплей включённым (IOKit: \(code))"
        }
    }
}

/// Owns the IOKit assertions so every partial activation and deinitialization
/// has one cleanup path. Releasing an assertion is idempotent.
public final class SleepAssertionController: @unchecked Sendable {
    public private(set) var hasSystemAssertion = false
    public private(set) var hasDisplayAssertion = false

    private var systemAssertion = IOPMAssertionID(0)
    private var displayAssertion = IOPMAssertionID(0)

    public init() {}

    deinit {
        deactivate()
    }

    public func activate(allowDisplaySleep: Bool) throws {
        if !hasSystemAssertion {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                "PreventUserIdleSystemSleep" as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "drem: keep the Mac awake" as CFString,
                &id
            )
            guard result == kIOReturnSuccess else {
                throw SleepAssertionError.systemAssertion(result)
            }
            systemAssertion = id
            hasSystemAssertion = true
        }

        if allowDisplaySleep {
            releaseDisplayAssertion()
        } else if !hasDisplayAssertion {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                "PreventUserIdleDisplaySleep" as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "drem: keep the display on" as CFString,
                &id
            )
            guard result == kIOReturnSuccess else {
                throw SleepAssertionError.displayAssertion(result)
            }
            displayAssertion = id
            hasDisplayAssertion = true
        }
    }

    public func deactivate() {
        if hasSystemAssertion {
            IOPMAssertionRelease(systemAssertion)
            hasSystemAssertion = false
            systemAssertion = 0
        }
        releaseDisplayAssertion()
    }

    private func releaseDisplayAssertion() {
        if hasDisplayAssertion {
            IOPMAssertionRelease(displayAssertion)
            hasDisplayAssertion = false
            displayAssertion = 0
        }
    }
}
