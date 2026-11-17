// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 drem contributors

import Foundation

/// One event-driven lid source shared by brightness and away-mode security.
/// Observers receive refreshes as well as state transitions so display
/// reconfiguration can retry work without introducing a polling timer.
@MainActor
final class LidStateMonitor {
    private var sensor: LidStateObserver?
    private var observers: [UUID: (Bool?) -> Void] = [:]
    private(set) var currentState: Bool?

    @discardableResult
    func observe(_ handler: @escaping (Bool?) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        handler(currentState)
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    func start() -> Bool {
        guard sensor == nil else { return true }
        let sensor = LidStateObserver { [weak self] state in
            DispatchQueue.main.async { self?.publish(state) }
        }
        guard sensor.start() else { return false }
        self.sensor = sensor
        publish(sensor.currentState)
        return true
    }

    func refresh() {
        guard let sensor else { return }
        publish(sensor.currentState)
    }

    func shutdown() {
        sensor?.stop()
        sensor = nil
        observers.removeAll()
    }

    private func publish(_ state: Bool?) {
        currentState = state
        for handler in observers.values { handler(state) }
    }
}
