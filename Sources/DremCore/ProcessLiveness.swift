import Darwin

public enum ProcessLiveness {
    public static func isAlive(_ processID: Int32) -> Bool {
        guard processID > 0 else { return false }

        if kill(processID, 0) == 0 {
            return true
        }

        return errno == EPERM
    }
}
