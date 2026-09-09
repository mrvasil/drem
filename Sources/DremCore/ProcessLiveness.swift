import Darwin
import Foundation

public enum ProcessLiveness {
    public static func startTime(_ processID: Int32) -> Date? {
        guard processID > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    public static func isAlive(_ processID: Int32) -> Bool {
        guard processID > 0 else { return false }

        if kill(processID, 0) == 0 {
            return true
        }

        return errno == EPERM
    }
}
