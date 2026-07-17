import Foundation
import ScanKit

@main
struct ScanKitBench {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("""
            ScanKit Benchmark
            -----------------
            用法:
              scankit-bench <path> [--no-hidden] [--no-dedup]
                                   [--top-level | --summary-only | --large-files]

            示例:
              scankit-bench ~/Downloads
              scankit-bench /System/Volumes/Data/Users/$(whoami)/Library/Caches

            输出与 `du -sh -x` / `du -sh -A` 对比，验证：
              1. 物理占用 vs 逻辑大小差异（iCloud / 稀疏文件）
              2. 硬链接去重正确性（Time Machine / Xcode DerivedData）
              3. 隐藏文件是否纳入（你说的"100G 找不到 80G"问题）
            """)
            exit(64)
        }

        let path = (args[1] as NSString).expandingTildeInPath
        var options = ScanOptions()
        var useLegacy = false
        var delivery: BulkScanner.EventDelivery = .complete
        for arg in args.dropFirst(2) {
            switch arg {
            case "--no-hidden": options.includeHidden = false
            case "--no-dedup": options.dedupByInode = false
            case "--legacy": useLegacy = true
            case "--top-level": delivery = .topLevel
            case "--summary-only": delivery = .summaryOnly
            case "--large-files":
                delivery = .largeFiles(
                    minimumAllocatedBytes: 100 * 1024 * 1024,
                    maximumResults: 1_000
                )
            default: break
            }
        }

        let url = URL(fileURLWithPath: path)
        let engine = useLegacy ? "Scanner (FileManager.enumerator)" : "BulkScanner (getattrlistbulk)"
        print("→ scanning \(url.path) ...")
        print("  engine:  \(engine)")
        print("  options: hidden=\(options.includeHidden) dedup=\(options.dedupByInode) delivery=\(delivery)")

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        let stream: AsyncStream<ScanEvent>
        if useLegacy {
            stream = ScanKit.Scanner(options: options).scan(root: url)
        } else {
            stream = BulkScanner(options: options).scan(root: url, delivery: delivery)
        }

        var incrementalNodeCount = 0
        for await event in stream {
            switch event {
            case .heartbeat:
                continue
            case .progress(let bytes, let count):
                let human = formatter.string(fromByteCount: bytes)
                fputs("\r  scanned: \(count) files / \(human)         ", stderr)
            case .node:
                incrementalNodeCount += 1
            case .nodes(let nodes):
                incrementalNodeCount += nodes.count
            case .finished(let summary):
                print("")
                print("─────────────────────────────────────────────")
                print("✓ done in \(String(format: "%.2f", summary.elapsed))s")
                print("  files:        \(summary.fileCount)")
                print("  directories:  \(summary.directoryCount)")
                print("  on disk:      \(formatter.string(fromByteCount: summary.totalAllocatedBytes))")
                print("  logical:      \(formatter.string(fromByteCount: summary.totalLogicalBytes))")
                print("  hardlink dedup saved: \(formatter.string(fromByteCount: summary.dedupedHardlinkBytes))")
                print("  incremental nodes delivered: \(incrementalNodeCount)")
                switch summary.projection {
                case .none:
                    print("  projection rows: none")
                case .topLevel(let entries):
                    print("  projection rows: \(entries.count)")
                case .largeFiles(let nodes):
                    print("  projection rows: \(nodes.count)")
                case .fileCandidates(let nodes):
                    print("  projected file candidates: \(nodes.count)")
                }
                let diff = summary.totalLogicalBytes - summary.totalAllocatedBytes
                if diff != 0 {
                    let label = diff > 0 ? "iCloud/sparse phantom" : "compressed/cloned bonus"
                    print("  Δ (logical-physical): \(formatter.string(fromByteCount: diff)) [\(label)]")
                }
                print("─────────────────────────────────────────────")
                print("→ 用以下命令对比:")
                print("    du -sh \"\(url.path)\"        # on-disk allocated size")
                print("    du -sh -A \"\(url.path)\"     # apparent size")
            case .failed(let err):
                fputs("✗ failed: \(err)\n", stderr)
                exit(1)
            case .permissionDenied(let path):
                fputs("WARN permission denied: \(path)\n", stderr)
            case .tccProtectedSkipped(let path):
                fputs("⊘ TCC protected (skipped): \(path)\n", stderr)
            case .incomplete(let issue):
                fputs("WARN incomplete [\(issue.reason.rawValue)]: \(issue.path)\n", stderr)
            case .cacheDirTagged(let path):
                fputs("ⓘ CACHEDIR.TAG (classified as cache; size still scanned): \(path)\n", stderr)
            }
        }
    }
}
