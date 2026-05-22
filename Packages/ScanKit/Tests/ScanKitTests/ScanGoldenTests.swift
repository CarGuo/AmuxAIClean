import XCTest
@testable import ScanKit
import TestHarness

/// 把 `BulkScanner` 跑出来的节点列表序列化成稳定的 golden 快照，
/// 首次运行写入磁盘，后续运行严格比对——任何节点出现/消失/字节数漂移都会被捕获。
final class ScanGoldenTests: XCTestCase {

    /// 验证：扫描 Caches/{a.log,b.log} 这种最小 fixture 时，
    /// 节点集合（path、bytes、isDirectory）相对 root 是稳定可重现的。
    func test_BulkScanner_扫描结果_与_Golden_快照一致() async throws {
        // 1) 用 ScenarioBuilder 在临时目录搭一个最小文件树
        //    Caches/
        //      ├── a.log (1024 字节)
        //      └── b.log (2048 字节)
        let scenario = ScenarioBuilder.build(prefix: "ScanKit-Golden") { root in
            root.dir("Caches") { c in
                c.file("a.log", size: 1024)
                c.file("b.log", size: 2048)
            }
        }
        let root = scenario.root

        // 2) 跑 BulkScanner，收集所有 node 事件
        let scanner = BulkScanner()
        var nodes: [FSNode] = []
        for await event in scanner.scan(root: root) {
            switch event {
            case .node(let n):
                nodes.append(n)
            case .finished:
                break
            default:
                continue
            }
        }

        // 3) 把绝对路径裁成相对 root 的稳定 path，再投影成 GoldenRow
        //    （logicalSize 比 allocatedSize 在不同文件系统上更稳定）
        let rootPath = root.standardizedFileURL.path
        let rows: [GoldenRow] = nodes.compactMap { node in
            let abs = node.url.standardizedFileURL.path
            guard abs.hasPrefix(rootPath) else { return nil }
            var rel = String(abs.dropFirst(rootPath.count))
            if rel.isEmpty { rel = "/" }
            return GoldenRow(
                path: rel,
                bytes: node.logicalSize,
                verdict: node.isDirectory ? "dir" : "file",
                vendor: "scankit"
            )
        }

        // 4) 与 golden 文件比对
        //    - 首次运行：golden 不存在 → 写入并断言为 .created
        //    - 二次运行：golden 已存在 → 必须 .matched，否则给出 diff
        let goldenURL = Self.goldenURL(named: "scankit_basic.golden")
        let result = try GoldenSnapshot.compare(rows: rows, goldenURL: goldenURL)

        switch result {
        case .matched:
            // 严格比对通过
            break
        case .created(let url):
            // 首次写入：留个明确日志，避免 CI 上"误以为通过"
            print("[ScanGoldenTests] 首次写入 golden: \(url.path)")
        case .mismatch(let diff):
            XCTFail("BulkScanner 输出与 golden 不一致：\n\(diff)")
        }
    }

    /// 解析 golden 文件在**源代码**目录下的绝对路径。
    ///
    /// 走 `#filePath` 而不是 `Bundle.module`：
    /// - `Bundle.module` 指向构建产物中只读的 resource 副本，不能写入；
    /// - golden 是开发者要 commit 进仓库的文件，必须落到源码目录的 Fixtures/ 下，
    ///   这样首跑生成后，开发者可以直接 `git diff` / `git add`。
    private static func goldenURL(named name: String) -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }
}
