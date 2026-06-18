import Foundation

/// WebNode 工作流配套：散落 `node_modules` 扫描器。
///
/// 设计动机（对位 [DEVELOPER_ONE_CLICK_PLAN.md](../../../../../docs/DEVELOPER_ONE_CLICK_PLAN.md) §WebNode）：
/// - 前端工程的 `node_modules` 体积通常 200 MB ~ 2 GB，且会散落在用户的多个 dev 根
///   （`~/Developer` / `~/Projects` / `~/Code` / `~/workspace` / `~/src`）；
/// - 用户切到新工程后旧工程的 `node_modules` 长期不清理，是 macOS 磁盘头号黑洞之一；
/// - 与 pnpm-store / yarn-cache 等「全局可重建缓存」不同，单个工程的 `node_modules`
///   是工程本地的"半瞬态产物"，删除后 `npm install` / `pnpm install` 可重建。
///
/// 与 [DerivedDataPerProjectScanner] 的关系：
/// - 同样采用「`static detect(home:)` 同步入口 + `actor discover()` 异步入口」双形态；
/// - `estimateSize(at:)` 实现风格完全对齐 [SimctlRuntimeScanner.estimateSize] /
///   [DerivedDataPerProjectScanner.estimateSize]：`FileManager.enumerator` 遍历，
///   优先 `totalFileAllocatedSize`，回退 `fileAllocatedSize`；
/// - 命中 `node_modules` 后**不再下钻**——node_modules 内部可能藏 5 万+ 文件，
///   下钻会让单次扫描爆栈到分钟级，违背"快速列清单"目标。
///
/// 容错红线：
/// - 任意 dev 根不存在 / 非目录 / 无权限读 → 跳过该根，**不抛**；
/// - 单个 `node_modules` 大小估算失败 → `sizeBytes` 为 `nil`，但仍纳入结果；
/// - 任意异常路径一律返回 `[]`，与 [DerivedDataPerProjectScanner] 容错语义对齐。
public actor NodeModulesScanner {

    public init() {}

    /// 异步入口：扫描 5 个常见 dev 根下的所有 `node_modules` 子目录。
    ///
    /// - Parameter home: 用户 home URL（注入便于测试，生产传 `FileManager.default.homeDirectoryForCurrentUser`）。
    /// - Returns: 命中列表；任何 IO 失败一律 `[]`，**不抛**。
    public func discover(home: URL) async -> [NodeModulesHit] {
        Self.detect(home: home)
    }

    /// 同步入口：纯 FS 遍历，无 subprocess，供单测直接调用。
    ///
    /// 流程：
    /// 1. 拼出 5 个常见 dev 根（不存在的根直接跳过）；
    /// 2. 对每个根做 BFS/DFS 递归（深度 ≤ `maxDepth`，根 = 深度 0）；
    /// 3. 命中 `node_modules` 后**不下钻**，把 hit 收集到结果；
    /// 4. 跳过隐藏目录（`.git` / `.DS_Store` / 以 `.` 开头的任何项）。
    ///
    /// - Parameters:
    ///   - home: 用户 home URL。
    ///   - maxDepth: 相对每个根的最大递归深度，根 = 深度 0，默认 4。
    /// - Returns: 命中列表；任何根失败一律跳过，整体不抛。
    public static func detect(home: URL, maxDepth: Int = 4) -> [NodeModulesHit] {
        let devRootNames = ["Developer", "Projects", "Code", "workspace", "src"]
        var results: [NodeModulesHit] = []
        // visited 跨所有 dev 根共享，确保用户在 ~/Projects ↔ ~/Developer 互链时不重复 walk。
        var visited: Set<String> = []
        for rootName in devRootNames {
            let root = home.appendingPathComponent(rootName, isDirectory: true)
            walk(root: root, maxDepth: maxDepth, visited: &visited, into: &results)
        }
        return results
    }

    // MARK: - 递归遍历

    /// 对单个 dev 根递归查找 `node_modules`。
    ///
    /// 关键约束：
    /// - 命中 `node_modules` 后**不下钻进入它内部**——避免遍历 5 万+ 个 npm 包文件；
    /// - 跳过隐藏目录（以 `.` 开头）——`.git` / `.DS_Store` / `.vscode` 等不可能藏工程目录；
    /// - `maxDepth` 是相对根的深度，根 = 深度 0；超出深度直接停止下钻；
    /// - **不跟随符号链接**（Review fix-soon #5，2026-06-15）：用户家目录里软链
    ///   极常见（如 `~/Code/foo -> ../Projects/foo`），若跟随会导致：
    ///     (a) 同一物理 `node_modules` 在结果里出现两次；
    ///     (b) `realpath` 形成环路时 DFS 栈打满到 `maxDepth` 才停（多个根之间互链）；
    ///     (c) 软链指向 `/private/var` 系统目录时被误扫。
    ///   通过 `.isSymbolicLinkKey` 直接过滤掉所有软链子项 + `visitedRealPaths`
    ///   用 canonical path 去重（`URL.resolvingSymlinksInPath` 物理化后比较）双保险。
    /// - `visitedRealPaths` 跨 dev 根共享：用户即便手动从 `~/Projects` 软链到
    ///   `~/Developer`，同一 realpath 也只会被走一次。
    /// - **传入 `&visited`**：让外层 detect() 在所有根之间复用同一份 visited set。
    private static func walk(root: URL,
                             maxDepth: Int,
                             visited: inout Set<String>,
                             into results: inout [NodeModulesHit]) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return
        }
        // 用显式栈实现 DFS，便于精确控制深度与"命中后不下钻"。
        var stack: [(url: URL, depth: Int)] = [(root, 0)]
        while let (current, depth) = stack.popLast() {
            // 物理化（resolve symlink）后去重——防止互链 / 自指 / 多根共享造成的重复 walk。
            let realPath = current.resolvingSymlinksInPath().path
            if !visited.insert(realPath).inserted {
                continue
            }

            // 当前目录是 node_modules → 收集 hit，但**不再下钻**
            if current.lastPathComponent == "node_modules" {
                results.append(makeHit(at: current))
                continue
            }
            // 已到最大深度 → 不再下钻
            guard depth < maxDepth else { continue }

            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
            guard let children = try? fm.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for child in children {
                // 双保险：即便 skipsHiddenFiles 漏过，也手动滤一遍以 `.` 开头的项
                if child.lastPathComponent.hasPrefix(".") { continue }
                let values = try? child.resourceValues(forKeys: keys)
                // Review fix-soon #5：显式跳过符号链接（无论指向什么），防软链循环 / 重复计数 / 越界扫描
                if values?.isSymbolicLink == true { continue }
                guard values?.isDirectory == true else { continue }
                stack.append((child, depth + 1))
            }
        }
    }

    /// 把一个 `node_modules` URL 转成 [NodeModulesHit]。
    /// 父目录名 = 工程名；估算大小 + 取 mtime。
    private static func makeHit(at nodeModulesURL: URL) -> NodeModulesHit {
        let parent = nodeModulesURL.deletingLastPathComponent()
        let projectName = parent.lastPathComponent
        let mtime = (try? nodeModulesURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return NodeModulesHit(
            url: nodeModulesURL,
            projectName: projectName,
            sizeBytes: estimateSize(at: nodeModulesURL.path),
            modificationDate: mtime
        )
    }

    // MARK: - sizeBytes 估算（对位 SimctlRuntimeScanner.estimateSize 风格）

    /// 遍历目录累加 totalFileAllocatedSize，回退 fileAllocatedSize。
    ///
    /// 失败语义：路径不存在 / 不是目录 / 无权限读 → 返回 `nil`（UI 侧显示 "—"）。
    static func estimateSize(at path: String) -> Int64? {
        guard !path.isEmpty else { return nil }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return nil
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }
            if values.isRegularFile == true {
                let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
                total += Int64(size)
            }
        }
        return total
    }
}

/// 单个 `node_modules` 命中记录。
public struct NodeModulesHit: Sendable, Hashable, Identifiable {
    /// `node_modules` 目录绝对 URL，如
    /// `~/Developer/my-app/node_modules`。
    public let url: URL
    /// 工程名（即 `node_modules` 的父目录名），如 `my-app`。
    public let projectName: String
    /// 目录累计大小（字节）。`nil` 表示路径不存在或无权限读。
    public let sizeBytes: Int64?
    /// 目录 mtime。`nil` 表示 stat 失败。
    public let modificationDate: Date?

    public var id: URL { url }

    public init(url: URL,
                projectName: String,
                sizeBytes: Int64?,
                modificationDate: Date?) {
        self.url = url
        self.projectName = projectName
        self.sizeBytes = sizeBytes
        self.modificationDate = modificationDate
    }
}
