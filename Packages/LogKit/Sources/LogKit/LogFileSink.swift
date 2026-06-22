import Foundation

/// 文件日志 sink —— 按天滚动，超过保留期自动删除旧文件。
///
/// 落盘位置：`~/Library/Logs/GSYCleanMac/GSYCleanMac-YYYY-MM-DD.log`
/// （macOS 标准 user logs，Console.app 也能直接打开）。
///
/// **写入策略**：
/// - 串行 GCD 队列序列化所有 append，保证多线程不交错；
/// - 每天 0 点跨天后下次 append 自动切到新文件（不是定时器，避免 App 后台休眠错过）；
/// - 单条 append 不 fsync，依赖 close 时 OS 刷盘 + 进程退出时关闭句柄。
///
/// **保留策略**：构造时一次扫目录，删除超过 `retentionDays` 的旧文件；之后每天首次
/// append 触发"跨天检查"时再扫一次。开销：一次 contentsOfDirectory + 几次 attributes 查询，
/// 在 7 天 / 单文件几 MB 体量下完全可忽略。
public final class LogFileSink: @unchecked Sendable {

    public let directory: URL
    public let retentionDays: Int

    private let queue = DispatchQueue(label: "GSYCleanMac.LogFileSink", qos: .utility)
    /// 当前打开的文件句柄。同一天可复用，跨天关闭重开。
    private var handle: FileHandle?
    private var currentDayKey: String = ""
    /// 缓存当前文件 URL，给 UI 「查看今日日志」按钮用。
    private var _currentFileURL: URL?

    public init(directory: URL, retentionDays: Int = 7) throws {
        self.directory = directory
        self.retentionDays = retentionDays
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 启动期同步执行一次清理 + 打开当天文件，避免首次 append 触发的 race
        // （app 启动 → 第一行 log 还没打就 crash，文件就根本不存在）。
        queue.sync {
            self.rotateIfNeededLocked(now: Date())
            self.purgeOldFilesLocked(now: Date())
        }
    }

    public static func defaultDirectory(fileManager: FileManager = .default) throws -> URL {
        // ~/Library/Logs/GSYCleanMac/
        // 注意：macOS 沙盒下 .libraryDirectory 是容器内 Library，非沙盒下是 ~/Library。
        // 当前 App 不开 sandbox，所以 .libraryDirectory 拿到就是 ~/Library。
        let lib = try fileManager.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return lib.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("GSYCleanMac", isDirectory: true)
    }

    public var currentFileURL: URL? {
        queue.sync { _currentFileURL }
    }

    public func logFiles() -> [URL] {
        queue.sync { logFilesLocked() }
    }

    public func exportCombined(to destination: URL) throws {
        var result: Result<Void, Error>!
        queue.sync {
            result = Result {
                try self.exportCombinedLocked(to: destination)
            }
        }
        try result.get()
    }

    @discardableResult
    public func clearLogs() throws -> Int {
        var result: Result<Int, Error>!
        queue.sync {
            result = Result {
                try self.clearLogsLocked()
            }
        }
        return try result.get()
    }

    /// append 一行日志。若跨天会先关旧文件 → 删旧 → 开新文件。
    public func append(_ line: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.rotateIfNeededLocked(now: Date())
            guard let h = self.handle, let data = line.data(using: .utf8) else { return }
            do {
                try h.write(contentsOf: data)
            } catch {
                // 写盘失败时降级到 stderr，避免静默吞错（磁盘满 / 权限丢失场景）。
                FileHandle.standardError.write(Data("[GSYLog] file sink write failed: \(error)\n".utf8))
            }
        }
    }

    /// 主动 flush + close，进程退出 / 测试 teardown 用。
    public func close() {
        queue.sync {
            try? handle?.close()
            handle = nil
            _currentFileURL = nil
            currentDayKey = ""
        }
    }

    // MARK: - 私有

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func rotateIfNeededLocked(now: Date) {
        let today = LogFileSink.dayKeyFormatter.string(from: now)
        if today == currentDayKey, handle != nil { return }
        // 关闭旧句柄。
        try? handle?.close()
        handle = nil
        // 打开新文件。
        let url = directory.appendingPathComponent("GSYCleanMac-\(today).log", isDirectory: false)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        do {
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            handle = h
            currentDayKey = today
            _currentFileURL = url
            // 跨天时同步触发清理。
            purgeOldFilesLocked(now: now)
        } catch {
            FileHandle.standardError.write(Data("[GSYLog] open log file failed: \(error)\n".utf8))
        }
    }

    private func purgeOldFilesLocked(now: Date) {
        guard retentionDays > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in items {
            // 只动我们自己产生的文件，避免误删用户后续手动放进来的东西。
            guard url.lastPathComponent.hasPrefix("GSYCleanMac-"),
                  url.pathExtension == "log" else { continue }
            // 当前正在写的文件不删。
            if url == _currentFileURL { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let m = mtime, m < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    private func logFilesLocked() -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items
            .filter { $0.lastPathComponent.hasPrefix("GSYCleanMac-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func exportCombinedLocked(to destination: URL) throws {
        try handle?.synchronize()
        let files = logFilesLocked()
        var data = Data()
        for file in files {
            let header = "\n===== \(file.lastPathComponent) =====\n"
            data.append(Data(header.utf8))
            if let fileData = try? Data(contentsOf: file) {
                data.append(fileData)
                if !fileData.isEmpty, fileData.last != 0x0A {
                    data.append(0x0A)
                }
            }
        }
        try data.write(to: destination, options: [.atomic])
    }

    private func clearLogsLocked() throws -> Int {
        try handle?.close()
        handle = nil
        _currentFileURL = nil
        currentDayKey = ""

        let files = logFilesLocked()
        var removed = 0
        for file in files {
            try FileManager.default.removeItem(at: file)
            removed += 1
        }
        rotateIfNeededLocked(now: Date())
        return removed
    }
}
