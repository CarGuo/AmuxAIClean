# 单元 / 集成测试回归报告 — 2026-06-11

> 跑法：`swift test --package-path Packages/<pkg>` × 9 个 SwiftPM 包
> 机器：M-系列 Mac, macOS 14+, Swift 6 toolchain
> 累计耗时：**~50 秒**（顺序，未并行）
> 全部产物日志：[logs/](file:///Users/amuxuser/workspace/AmuxAIClean/docs/regression/2026_06_11/logs)

## 汇总

| # | 包 | 入口 Package.swift | tests | skipped | failed | 耗时 |
|---|---|---|---|---|---|---|
| 1 | [AppUI](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI) | [Package.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Package.swift) | **397** | 0 | 0 | 15s |
| 2 | [ScanKit](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit) | [Package.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Package.swift) | **196** | 2 | 0 | 12s |
| 3 | [SafetyKit](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/SafetyKit) | [Package.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/SafetyKit/Package.swift) | **160** | 0 | 0 | 8s |
| 4 | [BrewKit](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/BrewKit) | [Package.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/BrewKit/Package.swift) | **32** | 0 | 0 | 2s |
| 5 | [FileSearchKit](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/FileSearchKit) | [Package.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/FileSearchKit/Package.swift) | **21** | 0 | 0 | 2s |
| 6 | [HeuristicKit](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/HeuristicKit) | [Package.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/HeuristicKit/Package.swift) | **11** | 0 | 0 | 4s |
| 7 | [LipoKit](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/LipoKit) | [Package.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/LipoKit/Package.swift) | **13** | 0 | 0 | 2s |
| 8 | [LogKit](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/LogKit) | [Package.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/LogKit/Package.swift) | **19** | 0 | 0 | 0s |
| 9 | [TestHarness](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/TestHarness) | [Package.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/TestHarness/Package.swift) | **8** | 0 | 0 | 5s |
| | **合计** | | **857** | **2** | **0** | **50s** |

**结果：857 PASS / 0 FAIL / 2 skipped（条件性 skip，非失败）。**

## 单包亮点（最慢测试集）

| 包 | 最慢 suite | 时长 |
|---|---|---|
| ScanKit | `BulkScannerConcurrencyTests` 9 cases | **6.93s**（真扫临时 fixture） |
| AppUI | `AppUIPackageTests.xctest` 全集 | 12.72s |
| SafetyKit | `SafetyKitTests` 7 cases | 5.30s |

> ScanKit 6.93s 的并发测试集是 [BulkScanner](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift) 多 root 真扫，属预期开销。

## 编译期警告（1 项，未阻塞）

[KnownVersionedRoots.swift#L115](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/KnownVersionedRoots.swift#L115)
```
warning: variable 'fileManager' was never mutated; consider changing to 'let' constant
```
**修复建议**：`var fileManager = FileManager.default` → `let fileManager = FileManager.default`。
**风险**：纯警告，不影响行为，下一轮顺手修。

## 跑法复现

```bash
for p in AppUI ScanKit SafetyKit BrewKit FileSearchKit HeuristicKit LipoKit LogKit TestHarness; do
    swift test --package-path Packages/$p 2>&1 | tee docs/regression/2026_06_11/logs/test-$p.log
done
```
