import Foundation

/// 测试用临时文件系统沙箱。
///
/// 每个 `FixtureFS` 实例对应一个隔离的临时根目录（`temporaryRoot`），
/// 所有相对路径都会落到该根下，避免污染真实磁盘。
///
/// 典型用法：
/// ```swift
/// let fs = try await FixtureFS.create()
/// defer { Task { await fs.cleanup() } }
/// try await fs.createDir("Caches/com.adobe")
/// try await fs.createFile("Caches/com.adobe/log.txt", bytes: 256)
/// ```
///
/// 之所以用 `actor`：
/// - 多个测试可能并行写入；actor 串行化避免目录创建竞争。
/// - `cleanup()` 是幂等的，即便发生异常也能在 defer 中安全调用。
public actor FixtureFS {
    /// 当前沙箱的真实根目录（绝对路径）。
    public let temporaryRoot: URL

    private let fm = FileManager.default
    private var didCleanup = false

    private init(root: URL) {
        self.temporaryRoot = root
    }

    /// 在系统临时目录下创建一个全新的隔离沙箱。
    /// - Parameter prefix: 目录名前缀，便于人肉调试时区分用例。
    public static func create(prefix: String = "TestHarness") throws -> FixtureFS {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return FixtureFS(root: base)
    }

    /// 解析相对路径到沙箱根下的绝对 URL。
    public func resolve(_ relativePath: String) -> URL {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty { return temporaryRoot }
        return temporaryRoot.appendingPathComponent(trimmed)
    }

    /// 创建一个目录（含中间目录）。
    @discardableResult
    public func createDir(_ relativePath: String) throws -> URL {
        let url = resolve(relativePath)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 写入指定字节数的文件（默认填充 0x00）。
    /// 中间目录会被自动创建。
    @discardableResult
    public func createFile(_ relativePath: String, bytes: Int) throws -> URL {
        precondition(bytes >= 0, "bytes must be >= 0")
        let url = resolve(relativePath)
        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = Data(count: bytes)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 写入指定原始数据。
    @discardableResult
    public func createFile(_ relativePath: String, contents: Data) throws -> URL {
        let url = resolve(relativePath)
        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try contents.write(to: url, options: .atomic)
        return url
    }

    /// 创建符号链接。
    ///
    /// - Parameters:
    ///   - relativePath: 链接自身的相对路径。
    ///   - target: 链接指向的目标（通常为绝对路径）。
    @discardableResult
    public func createSymlink(_ relativePath: String, target: String) throws -> URL {
        let url = resolve(relativePath)
        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        return url
    }

    /// 路径是否存在（不解析符号链接）。
    public func exists(_ relativePath: String) -> Bool {
        fm.fileExists(atPath: resolve(relativePath).path)
    }

    /// 文件物理大小（不存在或目录返回 nil）。
    public func size(_ relativePath: String) -> Int64? {
        let url = resolve(relativePath)
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    /// 删除整个沙箱根目录。多次调用安全（幂等）。
    public func cleanup() {
        if didCleanup { return }
        didCleanup = true
        try? fm.removeItem(at: temporaryRoot)
    }
}
