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
        // v1.3.zzzz Phase 3-B：默认 50_000，让 50k 节点跑单事务（一次 store.insert 一次
        // dbPool.write = 一次 SQLite 事务），消除"分批 5000 = 多事务"带来的 begin/commit
        // + WAL flush 噪声。30 万节点时仍可走 5_000 / 50_000 / 300_000 的横评。
        var insertBatchSize = 50_000

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
            } else if let value = parseValue(arg, key: "--insert-batch-size") {
                insertBatchSize = Int(value) ?? insertBatchSize
            } else if arg == "--insert-batch-size", i + 1 < rest.count {
                insertBatchSize = Int(rest[i + 1]) ?? insertBatchSize
                i += 1
            }
            i += 1
        }

        if benchDirectChildren {
            await runDirectChildrenBench(nodeCount: nodeCount, insertBatchSize: insertBatchSize)
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
            case .node, .nodes, .progress, .permissionDenied, .tccProtectedSkipped, .cacheDirTagged:
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

    // MARK: - v1.3.zzzz Phase 2-C：directChildrenAggregated 基准

    /// 合成节点灌进 GRDBScanResultStore 后跑 directChildrenAggregated 的 cold/warm 延迟。
    ///
    /// 节点结构：root（1）→ L1（22 dir）→ L2（每个 L1 下 22 dir）→ L3（每个 L2 下 N 个 file），
    /// 默认 50k 节点；用 --nodes 调到 30 万对齐 v1.3.z 大基准。
    ///
    /// `insertBatchSize` 控制单次 `store.insert(...)` 的批量大小。
    /// **GRDB 一次 `dbPool.write { ... }` 调用 = 一次 SQLite 事务**
    /// （见 [GRDBScanResultStore.insert](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L106-L131)），
    /// 所以 batch 大小直接影响事务次数：
    /// - batch=5_000 → 50k 节点要切 10 个事务，10 次 begin/commit + WAL flush
    /// - batch=50_000 → 50k 节点单事务，begin/commit/WAL 各只 1 次
    /// 默认 50_000 让"50k 节点 baseline"是真正的"单事务"基线，避免事务次数掩盖真实 SQL 开销。
    /// 30 万节点时调小到 50_000 仍是 6 次事务，对内存峰值（~150MB prepared stmt 占用）友好。
    ///
    /// **目的**：把 v1.3.zzzz [directChildrenAggregated SQL GROUP BY 下推](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L289)
    /// 的延迟和"老路径单 record query + Swift 聚合"对比，留下可重复跑的硬数据基准，
    /// 防止后续重构把 SQL 下推路径回退到慢路径。
    static func runDirectChildrenBench(nodeCount: Int, insertBatchSize: Int = 50_000) async {
        let dir = NSTemporaryDirectory() + "PerfBench-direct-\(UUID().uuidString)"
        let dbURL = URL(fileURLWithPath: dir).appendingPathComponent("scan.sqlite")
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let store: GRDBScanResultStore
        do {
            store = try GRDBScanResultStore(databaseURL: dbURL)
        } catch {
            FileHandle.standardError.write(Data("PerfBench: store init failed: \(error)\n".utf8))
            exit(1)
        }

        let session = ScanSessionID()
        do {
            try await store.beginSession(session)
        } catch {
            FileHandle.standardError.write(Data("PerfBench: beginSession failed: \(error)\n".utf8))
            exit(1)
        }

        // 合成节点：root + L1*22 + L2*22*22 + L3 file*K，每层 parentPath 链接齐
        let root = "/perfbench-root"
        var records: [ScanResultRecord] = []
        records.reserveCapacity(nodeCount + 512)

        let l1Count = 22
        let l2PerL1 = 22
        // 算 L3 每 L2 下文件数：剩余预算 / (l1*l2)
        let dirOverhead = 1 + l1Count + l1Count * l2PerL1
        let l3Total = max(0, nodeCount - dirOverhead)
        let l3PerL2 = max(1, l3Total / (l1Count * l2PerL1))

        records.append(makeDir(session: session, path: root, parent: nil, inode: 1))
        var inode: UInt64 = 2
        for a in 0..<l1Count {
            let l1 = "\(root)/dir_\(a)"
            records.append(makeDir(session: session, path: l1, parent: root, inode: inode))
            inode += 1
            for b in 0..<l2PerL1 {
                let l2 = "\(l1)/sub_\(b)"
                records.append(makeDir(session: session, path: l2, parent: l1, inode: inode))
                inode += 1
                for c in 0..<l3PerL2 {
                    let f = "\(l2)/file_\(c).bin"
                    records.append(makeFile(
                        session: session, path: f, parent: l2,
                        inode: inode,
                        bytes: Int64(1024 + (c % 8) * 512)
                    ))
                    inode += 1
                }
            }
        }

        let insertStart = DispatchTime.now().uptimeNanoseconds
        // 用调用方传入的 batch 控制事务边界。默认 50_000：50k 节点 = 单事务。
        // 见函数 doc 注释中关于"一次 dbPool.write = 一次事务"的说明。
        let batchSize = max(1, insertBatchSize)
        var idx = 0
        while idx < records.count {
            let end = min(idx + batchSize, records.count)
            do {
                try await store.insert(Array(records[idx..<end]))
            } catch {
                FileHandle.standardError.write(Data("PerfBench: insert failed at \(idx): \(error)\n".utf8))
                exit(1)
            }
            idx = end
        }
        do {
            try await store.finalizeSession(session)
        } catch {
            FileHandle.standardError.write(Data("PerfBench: finalize failed: \(error)\n".utf8))
            exit(1)
        }
        let insertEnd = DispatchTime.now().uptimeNanoseconds

        // cold（actor 内部 cache miss）
        let coldStart = DispatchTime.now().uptimeNanoseconds
        var coldChildren: [DirectChildAggregate] = []
        do {
            coldChildren = try await store.directChildrenAggregated(sessionID: session, parentPath: root)
        } catch {
            FileHandle.standardError.write(Data("PerfBench: directChildren cold failed: \(error)\n".utf8))
            exit(1)
        }
        let coldEnd = DispatchTime.now().uptimeNanoseconds

        // warm（同一 query 立即重跑）
        let warmStart = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try await store.directChildrenAggregated(sessionID: session, parentPath: root)
        } catch {
            FileHandle.standardError.write(Data("PerfBench: directChildren warm failed: \(error)\n".utf8))
            exit(1)
        }
        let warmEnd = DispatchTime.now().uptimeNanoseconds

        // 深一层（L1[0]）作为 mid-depth baseline
        let midStart = DispatchTime.now().uptimeNanoseconds
        var midChildren: [DirectChildAggregate] = []
        do {
            midChildren = try await store.directChildrenAggregated(
                sessionID: session, parentPath: "\(root)/dir_0"
            )
        } catch {
            FileHandle.standardError.write(Data("PerfBench: directChildren mid failed: \(error)\n".utf8))
            exit(1)
        }
        let midEnd = DispatchTime.now().uptimeNanoseconds

        let insertMs = Double(insertEnd - insertStart) / 1_000_000.0
        let coldMs = Double(coldEnd - coldStart) / 1_000_000.0
        let warmMs = Double(warmEnd - warmStart) / 1_000_000.0
        let midMs = Double(midEnd - midStart) / 1_000_000.0

        let line = String(
            format: "(records=%d, batch=%d, txn=%d, insert_ms=%.2f, cold_root_ms=%.2f, warm_root_ms=%.2f, mid_l1_ms=%.2f, root_children=%d, l1_children=%d)",
            records.count,
            batchSize,
            (records.count + batchSize - 1) / batchSize,
            insertMs,
            coldMs,
            warmMs,
            midMs,
            coldChildren.count,
            midChildren.count
        )
        print(line)
    }

    private static func makeDir(
        session: ScanSessionID, path: String, parent: String?, inode: UInt64
    ) -> ScanResultRecord {
        ScanResultRecord(
            sessionID: session,
            path: path,
            isDirectory: true,
            isSymlink: false,
            allocatedSize: 0,
            logicalSize: 0,
            inode: inode,
            device: 1,
            modificationDate: nil,
            parentPath: parent
        )
    }

    private static func makeFile(
        session: ScanSessionID, path: String, parent: String?, inode: UInt64, bytes: Int64
    ) -> ScanResultRecord {
        ScanResultRecord(
            sessionID: session,
            path: path,
            isDirectory: false,
            isSymlink: false,
            allocatedSize: bytes,
            logicalSize: bytes,
            inode: inode,
            device: 1,
            modificationDate: nil,
            parentPath: parent
        )
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
        PerfBench — GSYCleanMac scan/store 性能基线工具

        用法：
          PerfBench [flags]

        flags：
          --root <path>             默认扫描根（默认 ~/Library/Caches）；走 BulkScanner 路径，输出
                                    elapsed_ms / fileCount / totalAllocatedMB / dedupedHardlinkMB
          --hidden <bool>           是否包含隐藏文件（默认 true，接受 true/1/yes/y / false/0/no/n）
          --dedup <bool>            是否按 inode 去重 hardlink（默认 true）

          --bench-direct-children   走 directChildrenAggregated GRDB 单 SQL 路径基准
                                    （而不是默认的 BulkScanner 全盘扫描）。输出
                                    records / batch / txn / insert_ms / cold_root_ms /
                                    warm_root_ms / mid_l1_ms / root_children / l1_children
          --nodes <N>               --bench-direct-children 模式下合成节点数（默认 50000）
          --insert-batch-size <N>   --bench-direct-children 模式下 store.insert 切片大小
                                    （默认 50000；一次 store.insert = 一次 SQLite 事务，
                                    详见 GRDBScanResultStore.insert 注释）

          --help, -h                显示本帮助
        """)
    }
}
