// workflow-cli —— DeveloperWorkflow 卡片清单调试 CLI（v1.7 M1 调试工具）。
//
// 用法：
//   cd Packages/TestHarness && swift run workflow-cli apple
//   cd Packages/TestHarness && swift run workflow-cli apple --json
//
// 设计要点：
// - 仅依赖 ScanKit（不引 AppUI / SwiftUI），可在 CI/headless 环境跑；
// - 对 .dynamicScanner 卡片走 WorkflowRegistry.resolve，并强制注入
//   SubprocessExecutor(timeout: 1, dryRun: true) 避免真起 simctl；
// - 未知 workflow / 空卡片清单都以"友好提示 + 非 0 退出码"返回，
//   方便脚本组合（grep 退出码即可判定）。

import Foundation
import ScanKit

@main
struct WorkflowCLI {

    enum WorkflowKind: String {
        case apple
        case android
        case webnode
    }

    struct CLIHit: Encodable {
        let path: String
        let size: Int64?
        let name: String
    }

    struct CLICard: Encodable {
        let cardID: String
        let title: String
        let risk: String
        let hits: [CLIHit]
    }

    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            printUsage()
            exit(64)
        }

        let workflowArg = args[1].lowercased()
        let jsonMode = args.dropFirst(2).contains("--json")

        guard let kind = WorkflowKind(rawValue: workflowArg) else {
            FileHandle.standardError.write(Data(
                "❌ unknown workflow: \(args[1])\n   支持的取值: apple | android | webnode\n".utf8))
            exit(64)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser

        let cards: [DeveloperCard]
        switch kind {
        case .apple:
            cards = AppleWorkflow().cards(home: home)
        case .android:
            cards = AndroidWorkflow().cards(home: home)
        case .webnode:
            cards = WebNodeWorkflow().cards(home: home)
        }

        guard !cards.isEmpty else {
            FileHandle.standardError.write(Data(
                "ℹ️  no cards：当前机器在 workflow.\(kind.rawValue) 下无任何可展示卡片。\n".utf8))
            exit(jsonMode ? 0 : 1)
        }

        let dryRunExecutor = SubprocessExecutor(timeout: 1, dryRun: true)

        var resolved: [CLICard] = []
        resolved.reserveCapacity(cards.count)

        for card in cards {
            let hits: [WorkflowScanHit]
            switch card.source {
            case .dynamicScanner(let scannerID):
                hits = await WorkflowRegistry.resolve(
                    scannerID: scannerID,
                    home: home,
                    executor: dryRunExecutor)
            default:
                hits = []
            }

            resolved.append(CLICard(
                cardID: card.id,
                title: card.title,
                risk: card.risk.rawValue,
                hits: hits.map { hit in
                    CLIHit(path: hit.url.path,
                           size: hit.sizeBytes,
                           name: hit.displayName)
                }))
        }

        if jsonMode {
            emitJSON(resolved)
        } else {
            emitTable(cards: cards, resolved: resolved)
        }
    }

    // MARK: - Output

    private static func emitJSON(_ cards: [CLICard]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(cards)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("❌ JSON 编码失败: \(error)\n".utf8))
            exit(70)
        }
    }

    private static func emitTable(cards: [DeveloperCard], resolved: [CLICard]) {
        let header = ["cardID", "title", "risk", "sourceKind", "hits"]
        var rows: [[String]] = [header]
        for (card, cli) in zip(cards, resolved) {
            rows.append([
                cli.cardID,
                cli.title,
                cli.risk,
                sourceKind(card.source),
                String(cli.hits.count)
            ])
        }
        // 计算列宽（按字符数对齐，中文宽度近似按 2 算）
        var widths = Array(repeating: 0, count: header.count)
        for row in rows {
            for (i, cell) in row.enumerated() {
                widths[i] = max(widths[i], displayWidth(cell))
            }
        }
        for (i, row) in rows.enumerated() {
            let line = row.enumerated().map { idx, cell in
                pad(cell, to: widths[idx])
            }.joined(separator: "  ")
            print(line)
            if i == 0 {
                let sep = widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ")
                print(sep)
            }
        }
    }

    private static func sourceKind(_ source: DeveloperCard.PathSource) -> String {
        switch source {
        case .literal: return "literal"
        case .versionedRoot: return "versionedRoot"
        case .vendor: return "vendor"
        case .dynamicScanner(let id): return "dynamicScanner(\(id))"
        }
    }

    /// 近似显示宽度：ASCII = 1，其它（含 CJK / emoji）= 2。
    /// 控制台等宽字体下足以让中英混排表格目视对齐。
    private static func displayWidth(_ s: String) -> Int {
        var w = 0
        for scalar in s.unicodeScalars {
            w += scalar.isASCII ? 1 : 2
        }
        return w
    }

    private static func pad(_ s: String, to width: Int) -> String {
        let gap = width - displayWidth(s)
        return gap > 0 ? s + String(repeating: " ", count: gap) : s
    }

    private static func printUsage() {
        let usage = """
        workflow-cli —— DeveloperWorkflow 卡片清单调试工具

        用法:
          workflow-cli <workflow> [--json]

        参数:
          <workflow>   apple | android | webnode
          --json       以 JSON 数组输出（含 hits 详情），否则输出对齐表格

        示例:
          swift run workflow-cli apple
          swift run workflow-cli apple --json
        """
        FileHandle.standardError.write(Data((usage + "\n").utf8))
    }
}
