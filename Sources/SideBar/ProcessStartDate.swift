import AppKit
import Darwin

extension NSRunningApplication {
    /// 进程启动时间：优先用 launchDate；登录时由系统拉起的软件（如访达）launchDate 为 nil，
    /// 退回内核记录的进程启动时间，保证每个进程都有稳定身份。
    var processStartDate: Date? {
        if let launchDate { return launchDate }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processIdentifier]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}
