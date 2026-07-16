# GUI 全流程回归 — 2026-06-11

> 历史记录：此处使用的 `regression.sh` / `RegressionRunner` 已于 v2026.07.16 删除。
> 下列结果不能证明真实 GUI 交互，也不得照此重新运行。

> 跑法：[Scripts/regression.sh](file:///Users/guoshuyu/workspace/GSYCleanMac/Scripts/regression.sh) → `xcodebuild` Debug → 22 case 串行 → `GSY_REGRESSION_CASE=<id>` 环境变量驱动 [RegressionRunner.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/App/RegressionRunner.swift) → 结构化日志 → [Tests/Regression/last-run.json](file:///Users/guoshuyu/workspace/GSYCleanMac/Tests/Regression/last-run.json)
> 运行时间：2026-06-11T06:34:49Z
> 结果：**total=22  PASS=22  FAIL=0  TIMEOUT=0** ✅

## 一、全 22 case 明细

| # | case id | status | elapsed | 备注 |
|---|---|---|---|---|
| 1 | scan-custom-fixture | ✅ PASS | 616 ms | 内置 fixture 扫描 |
| 2 | **scan-recommended** | ✅ PASS | **38.70 s** | 真实推荐扫盘 (默认 timeout 600s 之内) |
| 3 | tree-drilldown | ✅ PASS | 700 ms | TreeBrowser 多层下钻 |
| 4 | scan-cancel-restart | ✅ PASS | 594 ms | 取消 → 立即重扫 不崩 |
| 5 | large-files-threshold | ✅ PASS | 640 ms | 大文件阈值过滤 |
| 6 | duplicate-scan | ✅ PASS | 286 ms | DuplicateScanner |
| 7 | orphan-scan | ✅ PASS | 211 ms | OrphanScanner |
| 8 | appfootprint-scan | ✅ PASS | 219 ms | AppFootprint |
| 9 | uninstaller-dryrun | ✅ PASS | 234 ms | dry-run 不真删 |
| 10 | launchagent-scan | ✅ PASS | 242 ms | LaunchAgent 扫描 |
| 11 | exporter-csv | ✅ PASS | 214 ms | CSV 导出 |
| 12 | hud-toggle | ✅ PASS | 2,280 ms | 进度 HUD 显隐 |
| 13 | tray-install-uninstall | ✅ PASS | 640 ms | 状态栏 install/uninstall |
| 14 | activation-policy | ✅ PASS | 420 ms | accessory ↔ regular 切换 |
| 15 | quicklook-controller | ✅ PASS | 759 ms | QuickLook 预览 |
| 16 | trash-pipeline-dryrun | ✅ PASS | 222 ms | TrashPipeline dry-run |
| 17 | safety-engine-veto | ✅ PASS | 220 ms | SafetyEngine 否决 |
| 18 | undo-history-restore | ✅ PASS | 214 ms | UndoHistory 恢复 |
| 19 | trash-real-scan | ✅ PASS | 615 ms | ~/.Trash 真实扫描 |
| 20 | **fda-banner-diagnose** | ✅ PASS | **38.92 s** | FDA 横幅自检 + TCC 调用 |
| 21 | **scan-perf-diagnose** | ✅ PASS | **39.39 s** | 性能自检（timeout 900s 内） |
| 22 | sentinel-default-off | ✅ PASS | 1,551 ms | Sentinel 默认关闭校验 |

**累计耗时**：约 **127.7 s**（约 2 分 8 秒，加上 xcodebuild 编译约 5 分钟，总 ~7 分钟）。
**最重 3 case**：scan-perf-diagnose 39.4s / fda-banner-diagnose 38.9s / scan-recommended 38.7s — 都是真扫盘的"重量级"case。

## 二、判读

1. **0 崩溃 / 0 超时**：所有 22 个 GUI 功能 case 全跑通，含 hud / tray / activation-policy / sentinel / quicklook / safety / undo / trash 等所有"易崩"路径。
2. **真扫盘 3 case ~39s**：scan-recommended / fda-banner-diagnose / scan-perf-diagnose 在真用户 home 上 ~39s，符合 [perf.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/regression/2026_06_11/perf.md) Bench A 体感（用户 home 通常 1.5~3 倍 Caches 体量）。
3. **轻量交互 case 全部 <1s**：tree-drilldown 700ms、quicklook 759ms、safety-veto 220ms — 与 [TreeBrowserView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift) 实测 mid-tree 24ms 一致。

## 三、当前状态

该 harness 已删除，不再可重复运行；需要复验的纯逻辑应迁入 package tests，真实 GUI 走持续 C4。
