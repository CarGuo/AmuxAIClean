import Foundation

/// v1.0 用户自定义扫描路径仓库。
///
/// 用户在 Settings 或 MainView 里点 `+ 添加路径` / 拖文件夹进窗口后，
/// 路径以**绝对路径字符串**形式持久化到 UserDefaults，下次启动恢复。
///
/// 设计要点：
/// 1. v1.0 sandbox = false（[App/GSYCleanMac.entitlements](../../../../App/GSYCleanMac.entitlements) `app-sandbox: false`），
///    暂用纯路径字符串持久化即可；v1.1 切 sandbox 时再升级为 NSURL bookmarkData。
/// 2. `actor` 隔离：避免 add/remove/list 在多个 SwiftUI 视图并发调用时数据竞争。
/// 3. 去重：以**标准化绝对路径**为 key（解决 `~/Documents` 和 `/Users/x/Documents` 重复加入）。
/// 4. 决策来源：[docs/ROADMAP_V1.md](../../../../docs/ROADMAP_V1.md) §1 T1。
public actor UserPathStore {
    public static let defaultsKey = "v1.user_paths"

    private let defaults: UserDefaults
    private var paths: [String]

    /// 标准构造（生产代码用）：直接使用 `UserDefaults.standard`。
    public init() {
        let d = UserDefaults.standard
        self.defaults = d
        if let arr = d.stringArray(forKey: Self.defaultsKey) {
            self.paths = arr
        } else {
            self.paths = []
        }
    }

    /// 单测专用构造：传 suite name，actor 内部自己造 `UserDefaults`，
    /// 避免 Swift 6 严格并发下把非 Sendable 的 UserDefaults 跨 task 传递。
    public init(testSuite: String) {
        let d = UserDefaults(suiteName: testSuite) ?? .standard
        self.defaults = d
        if let arr = d.stringArray(forKey: Self.defaultsKey) {
            self.paths = arr
        } else {
            self.paths = []
        }
    }

    // MARK: - API

    /// 当前已保存的所有自定义路径（按用户加入顺序）。
    public func list() -> [URL] {
        paths.map { URL(fileURLWithPath: $0) }
    }

    /// 加入一个 URL；标准化后去重。返回 true 表示真实加入。
    @discardableResult
    public func add(_ url: URL) -> Bool {
        let key = Self.normalize(url)
        if paths.contains(key) {
            return false
        }
        paths.append(key)
        persist()
        return true
    }

    /// 删除一个 URL；返回 true 表示命中并删除。
    @discardableResult
    public func remove(_ url: URL) -> Bool {
        let key = Self.normalize(url)
        guard let idx = paths.firstIndex(of: key) else {
            return false
        }
        paths.remove(at: idx)
        persist()
        return true
    }

    /// 单测专用：清空全部并落盘。
    public func _testReset() {
        paths.removeAll()
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    // MARK: - 私有

    private func persist() {
        defaults.set(paths, forKey: Self.defaultsKey)
    }

    /// 把 URL 标准化为绝对路径字符串：展开 `~`，resolveSymlinks，去掉尾随 `/`。
    private static func normalize(_ url: URL) -> String {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        var p = resolved.path
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }
}
