// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 drem contributors

import AppKit
import Darwin

struct BuiltinBrightnessSnapshot: Codable, Equatable {
    let displayUUID: String
    let brightness: Float

    var isValid: Bool {
        !displayUUID.isEmpty && brightness.isFinite && (0...1).contains(brightness)
    }
}

/// A narrow hardware boundary: never address an external display or assume
/// that a saved numeric display ID still belongs to the same panel.
struct BuiltinDisplayBrightness {
    var read: () -> BuiltinBrightnessSnapshot?
    var write: (BuiltinBrightnessSnapshot, Float) -> Bool

    static let live = BuiltinDisplayBrightness(
        read: {
            guard let display = builtinDisplay(), let get = Bridge.get else { return nil }
            var value: Float = 0
            guard get(display.id, &value) == 0 else { return nil }
            let snapshot = BuiltinBrightnessSnapshot(displayUUID: display.uuid, brightness: value)
            return snapshot.isValid ? snapshot : nil
        },
        write: { snapshot, value in
            guard snapshot.isValid, value.isFinite, (0...1).contains(value),
                  let display = builtinDisplay(), display.uuid == snapshot.displayUUID,
                  let set = Bridge.set else { return false }
            return set(display.id, value) == 0
        }
    )

    private static func builtinDisplay() -> (id: CGDirectDisplayID, uuid: String)? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success,
              let id = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }),
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let text = CFUUIDCreateString(kCFAllocatorDefault, uuid) else { return nil }
        return (id, text as String)
    }

    /// DisplayServices is not public API. Resolve it once at runtime and fail
    /// safely on unsupported hardware/OS versions; do not use screen overlays.
    private enum Bridge {
        typealias Getter = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
        typealias Setter = @convention(c) (UInt32, Float) -> Int32
        static let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY
        )
        static let get: Getter? = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
            .map { unsafeBitCast($0, to: Getter.self) }
        static let set: Setter? = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
            .map { unsafeBitCast($0, to: Setter.self) }
    }
}
