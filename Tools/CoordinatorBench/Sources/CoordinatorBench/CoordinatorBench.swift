import Foundation
import AppUI

// CoordinatorBench —— 真实回归基准测试 CLI。
//
// 目的：在不依赖 SwiftUI Render 的情况下，复现 ScanCoordinator 全栈数据流耗时。
// 用法：
//   swift run -c release CoordinatorBench --root /Users/<you>/workspace
//
// 输出格式（机器可解析）：
//   BENCH_RESULT path=<root> elapsed_ms=<int> producer_elapsed_ms=<int>
//     drain_lag_ms=<int> totalBytes=<int64> fileCount=<int> isFinished=<bool>
//
// 与 PerfBench 的差别：
//   - PerfBench 只跑 BulkScanner 裸流，验证"扫描器本身的吞吐"
//   - CoordinatorBench 跑 ScanCoordinator + ingest + publishSnapshot 全链路（不渲染 UI）
//     验证"业务层 ingest / 聚合"的耗时上限
//   - 二者差距大 → 病灶在 Coordinator/ingest 层
//   - 二者差距小但 App 仍卡 → 病灶在 SwiftUI Render / Observation 层

@MainActor
func runBench(root: String, timeoutSeconds: Double, deepIndex: Bool, largeFiles: Bool) async {
    let url = URL(fileURLWithPath: root)
    let category = largeFiles
        ? ScanCategory.largeFiles(home: root)
        : ScanCategory.makeCustom(url: url)

    // v1.3.z 性能开关：默认关闭 TreeBrowserView 用的深索引。
    // 这会跳过 ingest 中"沿祖先上溯字典累加"的热路径（占主线程 ~80% 时间）。
    // 不影响 buckets 主列表 / totalBytes / scannedFiles / largeFileLeaves。
    let coordinator = ScanCoordinator(enableTreeDeepIndex: deepIndex)
    let started = Date()

    coordinator.scan(
        category: category,
        largeFileMinBytes: largeFiles ? 100 * 1024 * 1024 : 0
    )

    // 轮询 isFinished —— 用 50ms tick 既不浪费 CPU，也能拿到合理精度
    let pollInterval: UInt64 = 50_000_000  // 50ms
    var lastTotal: Int64 = 0
    var lastFiles: Int = 0
    var quietTicks = 0

    while !coordinator.snapshot.isFinished {
        try? await Task.sleep(nanoseconds: pollInterval)
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > timeoutSeconds {
            let snap = coordinator.snapshot
            print("BENCH_TIMEOUT elapsed_ms=\(Int(elapsed * 1000)) totalBytes=\(snap.totalBytes) fileCount=\(snap.scannedFileCount) isFinished=false")
            FileHandle.standardError.write(Data("[bench] timeout after \(Int(elapsed))s, aborting\n".utf8))
            coordinator.cancel()
            exit(2)
        }

        // 每秒打一行进度
        let totalNow = coordinator.snapshot.totalBytes
        let filesNow = coordinator.snapshot.scannedFileCount
        if totalNow == lastTotal && filesNow == lastFiles {
            quietTicks += 1
        } else {
            quietTicks = 0
            lastTotal = totalNow
            lastFiles = filesNow
        }

        // 每 1s 打一行进度（20 个 50ms tick）
        if Int(elapsed * 1000) % 1000 < 50 {
            FileHandle.standardError.write(Data("[bench] t=\(String(format: "%.1f", elapsed))s files=\(filesNow) bytes=\(totalNow / 1_048_576)MB quiet=\(quietTicks)\n".utf8))
        }

        // 探测"完全卡死"：连续 60 秒没有新数据进来 → 提前退出
        if quietTicks >= 1200 {
            print("BENCH_STUCK elapsed_ms=\(Int(elapsed * 1000)) totalBytes=\(totalNow) fileCount=\(filesNow) isFinished=false")
            FileHandle.standardError.write(Data("[bench] STUCK: no progress for 60s, aborting\n".utf8))
            coordinator.cancel()
            exit(3)
        }
    }

    let elapsed = Date().timeIntervalSince(started)
    let snap = coordinator.snapshot
    let candidateCount = largeFiles
        ? coordinator.largeFiles(minSizeMB: 100, sortKey: .sizeDesc, limit: 1_000).count
        : snap.rows.count
    // v2026.07.17: Report producer and coordinator terminals separately. The historic UI
    // regression happened after the scanner finished, so one aggregate elapsed value could
    // not distinguish filesystem cost from consumer backlog.
    let producerElapsedMs = coordinator.lastProducerTerminalElapsed.map { Int($0 * 1_000) } ?? -1
    let drainLagMs = coordinator.lastConsumerDrainLag.map { Int($0 * 1_000) } ?? -1
    print("BENCH_RESULT path=\(root) elapsed_ms=\(Int(elapsed * 1000)) producer_elapsed_ms=\(producerElapsedMs) drain_lag_ms=\(drainLagMs) totalBytes=\(snap.totalBytes) fileCount=\(snap.scannedFileCount) candidateCount=\(candidateCount) isFinished=true isComplete=\(snap.isComplete)")
}

// 简单参数解析：--root <path>  [--timeout <seconds>] [--deep-index] [--large-files]
let args = CommandLine.arguments
var rootArg: String?
var timeoutArg: Double = 600.0  // 默认 10 分钟兜底
var deepIndexArg: Bool = false  // 默认关闭，对齐 PerfBench 测纯 ingest 路径
var largeFilesArg: Bool = false
var i = 1
while i < args.count {
    let a = args[i]
    if a == "--root", i + 1 < args.count { rootArg = args[i + 1]; i += 2; continue }
    if a == "--timeout", i + 1 < args.count { timeoutArg = Double(args[i + 1]) ?? 600.0; i += 2; continue }
    if a == "--deep-index" { deepIndexArg = true; i += 1; continue }
    if a == "--large-files" { largeFilesArg = true; i += 1; continue }
    i += 1
}
guard let root = rootArg else {
    FileHandle.standardError.write(Data("usage: CoordinatorBench --root <path> [--timeout <seconds>] [--deep-index] [--large-files]\n".utf8))
    exit(1)
}

let capturedRoot = root
let capturedTimeout = timeoutArg
let capturedDeep = deepIndexArg
let capturedLargeFiles = largeFilesArg
let task = Task { @MainActor in
    FileHandle.standardError.write(Data("[bench] config root=\(capturedRoot) timeout=\(Int(capturedTimeout))s deepIndex=\(capturedDeep) largeFiles=\(capturedLargeFiles)\n".utf8))
    await runBench(
        root: capturedRoot,
        timeoutSeconds: capturedTimeout,
        deepIndex: capturedDeep,
        largeFiles: capturedLargeFiles
    )
    exit(0)
}
_ = task

// 让主 RunLoop 跑起来，让 ScanCoordinator 的 @MainActor 调度有地方落
RunLoop.main.run()
