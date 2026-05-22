import Foundation
import ScanKit

@main
struct PerfBench {
    static func main() async {
        let args = CommandLine.arguments

        var rootArg: String = "~/Library/Caches"
        var includeHidden = true
        var dedup = true

        let rest = Array(args.dropFirst())
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
            }
            i += 1
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
            case .node, .progress:
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
}
