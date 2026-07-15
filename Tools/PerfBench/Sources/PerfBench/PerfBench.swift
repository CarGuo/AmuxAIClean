import Foundation
import ScanKit

@main
struct PerfBench {
    static func main() async {
        let args = CommandLine.arguments

        var rootArg: String = "~/Library/Caches"
        var includeHidden = true
        var dedup = true
        var benchDirectChildren = false
        var nodeCount = 50_000

        let rest = Array(args.dropFirst())
        if rest.contains("--help") || rest.contains("-h") {
            printUsage()
            return
        }
        var i = 0
        while i < rest.count {
            let arg = rest[i]
            if let value = parseValue(arg, key: "--root") {
                rootArg = value
            } else if arg == "--root", i + 1 < rest.count {
                rootArg = rest[i + 1]
                i += 1
            } else if let value = parseValue(arg, key: "--hidden") {
                includeHidden = parseBool(value)
            } else if arg == "--hidden", i + 1 < rest.count {
                includeHidden = parseBool(rest[i + 1])
                i += 1
            } else if let value = parseValue(arg, key: "--dedup") {
                dedup = parseBool(value)
            } else if arg == "--dedup", i + 1 < rest.count {
                dedup = parseBool(rest[i + 1])
                i += 1
            } else if arg == "--bench-direct-children" {
                benchDirectChildren = true
            } else if let value = parseValue(arg, key: "--nodes") {
                nodeCount = Int(value) ?? nodeCount
            } else if arg == "--nodes", i + 1 < rest.count {
                nodeCount = Int(rest[i + 1]) ?? nodeCount
                i += 1
            }
            i += 1
        }

        if benchDirectChildren {
            await runDirectChildrenBench(nodeCount: nodeCount)
            return
        }

        let expanded = (rootArg as NSString).expandingTildeInPath
        let rootURL = URL(fileURLWithPath: expanded)

        var options = ScanOptions()
        options.includeHidden = includeHidden
        options.dedupByInode = dedup

        let scanner = BulkScanner(options: options)
        let stream = scanner.scan(root: rootURL)

        let startNs = DispatchTime.now().uptimeNanoseconds
        var summary: ScanSummary?

        for await event in stream {
            switch event {
            case .finished(let s):
                summary = s
            case .failed(let err):
                FileHandle.standardError.write(Data("PerfBench failed: \(err)\n".utf8))
                exit(1)
            case .incomplete(let issue):
                FileHandle.standardError.write(Data(
                    "PerfBench incomplete: \(issue.path) [\(issue.reason.rawValue)]\n".utf8
                ))
                exit(1)
            case .node, .nodes, .progress, .permissionDenied, .tccProtectedSkipped,
                 .cacheDirTagged:
                continue
            }
        }
        let endNs = DispatchTime.now().uptimeNanoseconds

        guard let summary else {
            FileHandle.standardError.write(Data("PerfBench: no summary produced\n".utf8))
            exit(1)
        }

        let elapsedMs = Double(endNs - startNs) / 1_000_000.0
        let mb = 1024.0 * 1024.0
        let totalAllocatedMB = Double(summary.totalAllocatedBytes) / mb
        let dedupedHardlinkMB = Double(summary.dedupedHardlinkBytes) / mb

        let line = String(
            format: "(elapsed_ms=%.2f, fileCount=%d, totalAllocatedMB=%.2f, dedupedHardlinkMB=%.2f)",
            elapsedMs,
            summary.fileCount,
            totalAllocatedMB,
            dedupedHardlinkMB
        )
        print(line)
    }

    // MARK: - on-demand direct children benchmark

    /// 在临时目录生成真实文件树，然后用 BulkScanner 扫当前子树并聚合直接子项。
    /// 这条基准对应产品里的无持久层下钻方案：用户展开目录时后台扫描该目录子树，
    /// 只把第一层 child 聚合成列表行。
    static func runDirectChildrenBench(nodeCount: Int) async {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PerfBench-direct-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let l1Count = 22
        let l2PerL1 = 22
        let dirOverhead = 1 + l1Count + l1Count * l2PerL1
        let l3Total = max(0, nodeCount - dirOverhead)
        let l3PerL2 = max(1, l3Total / (l1Count * l2PerL1))

        let createStart = DispatchTime.now().uptimeNanoseconds
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let payload = Data(repeating: 0xAB, count: 1024)
            for a in 0..<l1Count {
                let l1 = rootURL.appendingPathComponent("dir_\(a)", isDirectory: true)
                for b in 0..<l2PerL1 {
                    let l2 = l1.appendingPathComponent("sub_\(b)", isDirectory: true)
                    try FileManager.default.createDirectory(at: l2, withIntermediateDirectories: true)
                    for c in 0..<l3PerL2 {
                        try payload.write(to: l2.appendingPathComponent("file_\(c).bin"))
                    }
                }
            }
        } catch {
            FileHandle.standardError.write(Data("PerfBench: fixture create failed: \(error)\n".utf8))
            exit(1)
        }
        let createEnd = DispatchTime.now().uptimeNanoseconds

        let coldStart = DispatchTime.now().uptimeNanoseconds
        let coldChildren = await aggregateDirectChildren(root: rootURL)
        let coldEnd = DispatchTime.now().uptimeNanoseconds

        let warmStart = DispatchTime.now().uptimeNanoseconds
        _ = await aggregateDirectChildren(root: rootURL)
        let warmEnd = DispatchTime.now().uptimeNanoseconds

        let l1URL = rootURL.appendingPathComponent("dir_0", isDirectory: true)
        let midStart = DispatchTime.now().uptimeNanoseconds
        let midChildren = await aggregateDirectChildren(root: l1URL)
        let midEnd = DispatchTime.now().uptimeNanoseconds

        let createMs = Double(createEnd - createStart) / 1_000_000.0
        let coldMs = Double(coldEnd - coldStart) / 1_000_000.0
        let warmMs = Double(warmEnd - warmStart) / 1_000_000.0
        let midMs = Double(midEnd - midStart) / 1_000_000.0

        let line = String(
            format: "(files=%d, create_ms=%.2f, cold_root_ms=%.2f, warm_root_ms=%.2f, mid_l1_ms=%.2f, root_children=%d, l1_children=%d)",
            l1Count * l2PerL1 * l3PerL2,
            createMs,
            coldMs,
            warmMs,
            midMs,
            coldChildren.count,
            midChildren.count
        )
        print(line)
    }

    private static func aggregateDirectChildren(root: URL) async -> [String: Int64] {
        var options = ScanOptions()
        options.includeHidden = true
        options.dedupByInode = true

        let scanner = BulkScanner(options: options)
        let rootPath = root.path
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        var children: [String: Int64] = [:]

        for await event in scanner.scan(root: root) {
            switch event {
            case .node(let node):
                merge(node, rootPath: rootPath, prefix: prefix, into: &children)
            case .nodes(let nodes):
                for node in nodes {
                    merge(node, rootPath: rootPath, prefix: prefix, into: &children)
                }
            case .failed(let error):
                FileHandle.standardError.write(Data("PerfBench: direct children scan failed: \(error)\n".utf8))
                exit(1)
            case .incomplete(let issue):
                FileHandle.standardError.write(Data(
                    "PerfBench: direct children incomplete: \(issue.path) [\(issue.reason.rawValue)]\n".utf8
                ))
                exit(1)
            case .finished, .progress, .permissionDenied, .tccProtectedSkipped,
                 .cacheDirTagged:
                continue
            }
        }
        return children
    }

    private static func merge(
        _ node: FSNode,
        rootPath: String,
        prefix: String,
        into children: inout [String: Int64]
    ) {
        guard node.path != rootPath, node.path.hasPrefix(prefix) else { return }
        let tail = String(node.path.dropFirst(prefix.count))
        guard let segment = tail.split(separator: "/", maxSplits: 1).first.map(String.init),
              !segment.isEmpty else { return }
        let childPath = rootPath == "/" ? "/" + segment : prefix + segment
        children[childPath, default: 0] += node.allocatedSize
    }

    private static func parseValue(_ arg: String, key: String) -> String? {
        let prefix = key + "="
        if arg.hasPrefix(prefix) {
            return String(arg.dropFirst(prefix.count))
        }
        return nil
    }

    private static func parseBool(_ value: String) -> Bool {
        switch value.lowercased() {
        case "true", "1", "yes", "y": return true
        case "false", "0", "no", "n": return false
        default: return true
        }
    }

    /// v1.3.zzzz Phase 3-D：`--help` / `-h` 走这里直接 stdout 列出所有 flag 和默认值。
    /// 之前不识别 `--help` 直接掉进 BulkScanner 跑全 ~/Library/Caches 扫描——
    /// 在 release 机器上一跑就是 5 秒，新人极易误以为程序卡死。
    private static func printUsage() {
        print("""
        PerfBench — GSYCleanMac 扫描性能基线工具

        用法：
          PerfBench [flags]

        flags：
          --root <path>             默认扫描根（默认 ~/Library/Caches）；走 BulkScanner 路径，输出
                                    elapsed_ms / fileCount / totalAllocatedMB / dedupedHardlinkMB
          --hidden <bool>           是否包含隐藏文件（默认 true，接受 true/1/yes/y / false/0/no/n）
          --dedup <bool>            是否按 inode 去重 hardlink（默认 true）

          --bench-direct-children   走后台按需子树扫描 + 直接子项聚合基准
                                    （而不是默认的 BulkScanner 全盘扫描）。输出
                                    files / create_ms / cold_root_ms / warm_root_ms /
                                    mid_l1_ms / root_children / l1_children
          --nodes <N>               --bench-direct-children 模式下目标节点数（默认 50000）

          --help, -h                显示本帮助
        """)
    }
}
