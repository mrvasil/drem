// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 drem contributors

import Foundation
import IOKit

/// IOPMrootDomain general-interest messages, not a repeating process/timer scan.
final class LidStateObserver {
    // IOPM.h: iokit_family_msg(sub_iokit_powermanagement, 0x100).
    // The function-like C macro is not imported by Swift.
    private static let clamshellChanged: UInt32 = (0x38 << 26) | (13 << 14) | 0x100
    private let changed: (Bool?) -> Void
    private var port: IONotificationPortRef?
    private var service: io_service_t = 0
    private var notification: io_object_t = 0

    init(changed: @escaping (Bool?) -> Void) { self.changed = changed }
    deinit { stop() }

    var currentState: Bool? {
        guard service != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? Bool
    }

    func start() -> Bool {
        guard port == nil else { return true }
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            stop()
            return false
        }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let result = IOServiceAddInterestNotification(
            port, service, kIOGeneralInterest,
            { context, _, message, _ in
                guard let context, message == LidStateObserver.clamshellChanged else { return }
                let observer = Unmanaged<LidStateObserver>.fromOpaque(context).takeUnretainedValue()
                observer.changed(observer.currentState)
            },
            Unmanaged.passUnretained(self).toOpaque(), &notification
        )
        guard result == KERN_SUCCESS else { stop(); return false }
        return true
    }

    func stop() {
        if notification != 0 { IOObjectRelease(notification); notification = 0 }
        if let port {
            IONotificationPortSetDispatchQueue(port, nil)
            IONotificationPortDestroy(port)
            self.port = nil
        }
        if service != 0 { IOObjectRelease(service); service = 0 }
    }
}
