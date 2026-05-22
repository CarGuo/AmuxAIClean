import Foundation

/// 由 `ScenarioBuilder.build` 返回的场景句柄。
///
/// 持有一个临时目录根 `root`；当 `Scenario` 实例被释放时（测试函数返回后），
/// 会在 `deinit` 中自动递归删除该目录，从而做到"自动清理"。
///
/// 之所以用 `final class` 而非 `struct`：
/// - 需要 `deinit` 触发清理；
/// - 需要确定的引用语义，避免值拷贝产生多个"看似独立但指向同一目录"的实例。
public final class Scenario: @unchecked Sendable {
    /// 场景的根目录（绝对 URL）。
    public let root: URL

    fileprivate init(root: URL) {
        self.root = root
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

/// 单个目录节点的构建上下文。
///
/// 通过 `dir(_:)` 与 `file(_:size:)` / `file(_:contents:)` 在该目录下
/// 构造子节点。所有方法都是同步的、即时执行的——DSL 闭包返回时，
/// 对应的物理目录/文件已经在磁盘上落地。
public final class ScenarioNode {
    /// 当前节点对应的绝对 URL。
    public let url: URL
    private let fm: FileManager

    fileprivate init(url: URL, fm: FileManager) {
        self.url = url
        self.fm = fm
    }

    /// 在当前节点下创建一个子目录，并在闭包中继续构建其内容。
    @discardableResult
    public func dir(_ name: String, _ build: (ScenarioNode) -> Void = { _ in }) -> URL {
        let child = url.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: child, withIntermediateDirectories: true)
        let node = ScenarioNode(url: child, fm: fm)
        build(node)
        return child
    }

    /// 创建一个指定字节数的占位文件（默认 0x00 填充）。
    @discardableResult
    public func file(_ name: String, size: Int) -> URL {
        precondition(size >= 0, "size must be >= 0")
        let target = url.appendingPathComponent(name, isDirectory: false)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        let data = Data(count: size)
        try? data.write(to: target, options: .atomic)
        return target
    }

    /// 创建一个内容为指定 `Data` 的文件。
    @discardableResult
    public func file(_ name: String, contents: Data) -> URL {
        let target = url.appendingPathComponent(name, isDirectory: false)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        try? contents.write(to: target, options: .atomic)
        return target
    }

    /// 创建符号链接，指向 `target`（可以是绝对路径，也可是相对路径字符串）。
    @discardableResult
    public func symlink(_ name: String, to target: String) -> URL {
        let link = url.appendingPathComponent(name, isDirectory: false)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        return link
    }
}

/// 用临时目录 + DSL 风格快速搭建一个文件树场景，便于扫描类逻辑做集成测试。
///
/// 示例：
/// ```swift
/// let scenario = ScenarioBuilder.build { root in
///     root.dir("Caches") { c in
///         c.file("a.log", size: 1024)
///         c.file("b.log", size: 2048)
///     }
/// }
/// // scenario.root 即根目录 URL；scenario 释放时自动清理。
/// ```
public enum ScenarioBuilder {
    /// 在系统临时目录下创建一个隔离根，执行 DSL 闭包构建文件树，返回 `Scenario`。
    /// - Parameters:
    ///   - prefix: 根目录前缀，便于人肉调试。
    ///   - build: DSL 闭包，参数为根节点。
    public static func build(
        prefix: String = "Scenario",
        _ build: (ScenarioNode) -> Void
    ) -> Scenario {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let node = ScenarioNode(url: root, fm: fm)
        build(node)
        return Scenario(root: root)
    }
}
