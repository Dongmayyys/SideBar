import Foundation

/// 快捷键收纳的诊断日志，写到 ~/Library/Logs/SideBar/stash.log，超过 1 MB 时换到 stash.old.log。
enum StashDebugLog {
    private static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SideBar", isDirectory: true)
    private static let url = directory.appendingPathComponent("stash.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
            let old = directory.appendingPathComponent("stash.old.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: url)
        }
    }

    /// 调用栈前几帧，用来区分是哪条路径收回了窗口。
    static func callers(_ count: Int = 6) -> String {
        Thread.callStackSymbols.dropFirst(2).prefix(count)
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).prefix(1).joined() }
            .joined(separator: " <- ")
    }
}
