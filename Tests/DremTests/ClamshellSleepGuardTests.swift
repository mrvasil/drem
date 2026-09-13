import Foundation
import Testing
@testable import Drem

@Suite(.serialized)
struct ClamshellSleepGuardTests {
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
}
