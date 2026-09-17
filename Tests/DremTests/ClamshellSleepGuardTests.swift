import Foundation
import Testing
@testable import Drem

@Suite(.serialized)
struct ClamshellSleepGuardTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            storage += 1
            return storage
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Bool] = []

        func append(_ enabled: Bool) {
            lock.lock()
            storage.append(enabled)
            lock.unlock()
        }

        var values: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private final class Status: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Int32?

        func set(_ value: Int32) {
            lock.lock()
            storage = value
            lock.unlock()
        }

        var value: Int32? {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    @Test
    func parentExitRestoresNormalSleep() throws {
        let input = Pipe()
        let writes = Writes()
        let enabled = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let status = Status()

        DispatchQueue.global(qos: .userInitiated).async {
            let result = ClamshellSleepGuardWorker.run(
                input: input.fileHandleForReading,
                readyOutput: nil
            ) { value in
                writes.append(value)
                if value { enabled.signal() }
                return true
            }
            status.set(result)
            finished.signal()
        }

        #expect(enabled.wait(timeout: .now() + 1) == .success)
        try input.fileHandleForWriting.close()
        #expect(finished.wait(timeout: .now() + 1) == .success)

        #expect(writes.values == [true, false])
        #expect(status.value == 0)
    }

    @Test
    func unresponsiveGuardCannotWedgeTheNextEnable() {
        let launches = Counter()
        let restores = Counter()
        let controller = KeepAwakeClamshellGuardController(
            label: "local.mrvasil.drem.tests.clamshell-guard",
            processFactory: {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                if launches.next() == 1 {
                    // Announces readiness but deliberately ignores the ownership
                    // pipe. The controller must bound shutdown rather than leave
                    // its serial lifecycle queue stuck forever.
                    process.arguments = ["-c", "printf '\\001'; exec /usr/bin/tail -f /dev/null"]
                } else {
                    process.arguments = ["-c", "printf '\\001'; /bin/cat >/dev/null"]
                }
                return process
            },
            restoreSleep: {
                _ = restores.next()
                return true
            },
            handshakeTimeout: 0.5,
            exitTimeout: 0.05,
            terminationGrace: 0.2
        )

        let firstStart = DispatchSemaphore(value: 0)
        controller.setEnabled(true) { ok in
            #expect(ok)
            firstStart.signal()
        }
        #expect(firstStart.wait(timeout: .now() + 1) == .success)

        let stop = DispatchSemaphore(value: 0)
        controller.setEnabled(false) { ok in
            #expect(ok)
            stop.signal()
        }
        #expect(stop.wait(timeout: .now() + 1) == .success)

        let secondStart = DispatchSemaphore(value: 0)
        controller.setEnabled(true) { ok in
            #expect(ok)
            secondStart.signal()
        }
        #expect(secondStart.wait(timeout: .now() + 1) == .success)
        #expect(controller.restoreSync())
        #expect(restores.value == 2)
    }

    @Test
    func missingReadySignalCannotWedgeTheNextEnable() {
        let launches = Counter()
        let restores = Counter()
        let controller = KeepAwakeClamshellGuardController(
            label: "local.mrvasil.drem.tests.clamshell-handshake",
            processFactory: {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                if launches.next() == 1 {
                    process.arguments = ["-c", "exec /usr/bin/tail -f /dev/null"]
                } else {
                    process.arguments = ["-c", "printf '\\001'; /bin/cat >/dev/null"]
                }
                return process
            },
            restoreSleep: {
                _ = restores.next()
                return true
            },
            handshakeTimeout: 0.05,
            exitTimeout: 0.05,
            terminationGrace: 0.2
        )

        let failedStart = DispatchSemaphore(value: 0)
        controller.setEnabled(true) { ok in
            #expect(!ok)
            failedStart.signal()
        }
        #expect(failedStart.wait(timeout: .now() + 1) == .success)
        #expect(restores.value == 1)

        let recoveredStart = DispatchSemaphore(value: 0)
        controller.setEnabled(true) { ok in
            #expect(ok)
            recoveredStart.signal()
        }
        #expect(recoveredStart.wait(timeout: .now() + 1) == .success)
        #expect(controller.restoreSync())
        #expect(restores.value == 2)
    }
}
