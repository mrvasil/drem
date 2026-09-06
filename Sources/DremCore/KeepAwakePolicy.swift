// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 drem contributors

import Darwin
import Foundation

public enum KeepAwakeAutomationCondition: String, CaseIterable, Hashable, Sendable {
    case externalDisplay
    case power
    case agents
}

public enum KeepAwakeAutomationAction: Equatable, Sendable {
    case none
    case activate
    case deactivate
}

public enum KeepAwakeAutomationSupport {
    private static let screenLockedKey = "CGSSessionScreenIsLocked"

    public static func hasExternalDisplay(builtInFlags: [Bool]) -> Bool {
        builtInFlags.contains(false)
    }

    public static func isScreenLocked(sessionDictionary: [String: Any]?) -> Bool {
        guard let value = sessionDictionary?[screenLockedKey] else { return false }
        if let locked = value as? Bool { return locked }
        return (value as? NSNumber)?.boolValue ?? false
    }

    public static func matchingConditions(
        externalDisplayEnabled: Bool,
        externalDisplayConnected: Bool,
        powerEnabled: Bool,
        connectedToPower: Bool,
        agentsEnabled: Bool = false,
        hasWorkingAgent: Bool = false
    ) -> Set<KeepAwakeAutomationCondition> {
        // This is a selected mode, not an extra OR condition: no agent work
        // means ordinary sleep even with an external display or AC connected.
        if agentsEnabled { return hasWorkingAgent ? [.agents] : [] }
        var matches = Set<KeepAwakeAutomationCondition>()
        if externalDisplayEnabled, externalDisplayConnected {
            matches.insert(.externalDisplay)
        }
        if powerEnabled, connectedToPower {
            matches.insert(.power)
        }
        return matches
    }

    public static func action(
        matchingConditions: Set<KeepAwakeAutomationCondition>,
        sessionActive: Bool,
        automaticSessionActive: Bool
    ) -> KeepAwakeAutomationAction {
        guard !matchingConditions.isEmpty else {
            return automaticSessionActive ? .deactivate : .none
        }
        return sessionActive ? .none : .activate
    }
}

public enum KeepAwakeAgentPolicy {
    public static func requiresWake(enabled: Bool, hasWorkingAgent: Bool, suppressed: Bool) -> Bool {
        enabled && hasWorkingAgent && !suppressed
    }

    public static func shouldPauseForLock(locked: Bool, pauseEnabled: Bool, agentRequiresWake: Bool) -> Bool {
        locked && pauseEnabled && !agentRequiresWake
    }

    public static func requiresClamshell(manualPreference: Bool, agentRequiresWake: Bool) -> Bool {
        manualPreference || agentRequiresWake
    }
}

/// One system write at a time. Changes arriving during a write are coalesced
/// into the latest desired state, then reconciled after its completion.
public struct KeepAwakeClamshellState: Sendable {
    public private(set) var desired = false
    public private(set) var active = false
    public private(set) var pending: Bool?

    public init() {}

    public mutating func request(_ enabled: Bool) -> Bool? {
        desired = enabled
        return nextOperation()
    }

    public mutating func complete(success: Bool) -> Bool? {
        guard let target = pending else { return nil }
        pending = nil
        if success { active = target }
        // Failed writes are surfaced to the user; never spin on a failed sudo.
        return success ? nextOperation() : nil
    }

    private mutating func nextOperation() -> Bool? {
        guard pending == nil, desired != active else { return nil }
        pending = desired
        return desired
    }
}

public enum KeepAwakePolicy {
    public static let allowedDurations = [0, 15, 30, 60, 120, 240, 480]
    public static let allowedBatteryLimits = [0, 5, 10, 15, 20]
    public static let allowedMouseJiggleIntervals = [1, 2, 5, 10, 15]

    public static func sanitizedDuration(_ value: Int) -> Int {
        allowedDurations.contains(value) ? value : 0
    }

    public static func sanitizedBatteryLimit(_ value: Int) -> Int {
        allowedBatteryLimits.contains(value) ? value : 10
    }

    public static func sanitizedMouseJiggleInterval(_ value: Int) -> Int {
        allowedMouseJiggleIntervals.contains(value) ? value : 5
    }
}

public enum KeepAwakeSudoersSupport {
    public static func sleepDisabled(inPmsetOutput output: String) -> Bool {
        output.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
    }

    /// The uid form is deliberately used instead of a username: a uid is only
    /// digits and cannot become sudoers or shell syntax on an SSO-managed Mac.
    public static func clamshellRule(uid: uid_t) -> String {
        "#\(uid) ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0"
    }
}
