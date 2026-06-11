# 回归后续追踪条目 — 2026-06-11

> 本文档把 [REPORT.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/regression/2026_06_11/REPORT.md) + [competitors_matrix.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/regression/2026_06_11/competitors_matrix.md) + [perf.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/regression/2026_06_11/perf.md) 中标注的所有「未做 / followup / 缺口」整理为可追踪条目，按优先级排序。

## P0 — 本轮已顺手补完

| ID | 内容 | 状态 |
|---|---|---|
| F-0-1 | [KnownVersionedRoots.swift#L111-L139](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/KnownVersionedRoots.swift#L111-L139) `var fileManager` 死代码删除 | ✅ 本轮删除（实际从未引用，"forward-compat" 注释名不副实） |
| F-0-2 | PerfBench 1M 节点压力 bench | ✅ 本轮跑完，[B3](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/regression/2026_06_11/perf.md) 入库 |

## P1 — 性能可优化（数据已证据齐全）

### F-1-1 SQLite `cache_size` 调优（1M 节点场景）
- **现象**：1M 节点 cold-root 4.5s，3.3× 数据吃 8.9× 时延（vs 300k）
- **推断**：默认 `cache_size = -2000`（2MB）下 GROUP BY 中间结果集溢写临时表
- **方案**：在 [GRDBScanResultStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift) 打开 connection 后 `PRAGMA cache_size = -10000`（10MB），再跑 B3 对比
- **验收**：1M cold ≤ 2s（接近 warm 现值 2.76s 即可）
- **依据**：[perf.md §B3 判读](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/regression/2026_06_11/perf.md)

### F-1-2 气泡图 / Treemap 可视化
- **缺口**：[competitors_matrix §三](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/regression/2026_06_11/competitors_matrix.md) P1 — DaisyDisk Sunburst / GrandPerspective Squarified 是用户「一眼看见大目录」的核心体验
- **方案**：基于 [GRDBScanResultStore.directChildrenAggregated](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L289) 已下推聚合数据，新增 Canvas/Metal Treemap view，作为 [TreeBrowserView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift) 兄弟视图
- **验收**：300k 节点 root 视图 60fps 可平移缩放

## P2 — 功能缺口（竞品已有，我们暂无）

### F-2-1 浏览器隐私痕迹清理
- **缺口**：CleanMyMac Privacy / Browser — Cookies / History / Autofill / Downloads
- **方案**：新建 `BrowserPrivacyScanner`，遍历 Safari / Chrome / Firefox / Edge / Arc 的 sqlite db
- **风险**：Safari `~/Library/Safari/History.db` 受 FDA 保护，需走 [TCCProbe](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/Onboarding/TCCProbe.swift) 引导

### F-2-2 系统维护脚本扩展
- **现状**：[MaintenanceTasks](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/MaintenanceTasks.swift) 已实现 periodic daily/weekly/monthly
- **缺口**：vs OnyX / CMM Maintenance 还差 Flush DNS / Repair Permissions / Rebuild LaunchServices / Rebuild Spotlight
- **方案**：扩展 [MaintenanceScreen](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MaintenanceScreen.swift) 子项卡片

### F-2-3 Lipo 通用二进制瘦身接入 sidebar
- **现状**：[LipoKit](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/LipoKit) 已完成，**未接入 sidebar**
- **方案**：[ScanCategory.Kind](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCategory.swift#L9-L14) 增加 `case lipo`，在 [MainView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift) sidebar 增 LipoScreen 入口

### F-2-4 Brew 管理接入 sidebar
- **现状**：[BrewKit](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/BrewKit) 已完成，**未接入 sidebar**
- **方案**：同 F-2-3

## P3 — 体验 / 长尾

### F-3-1 Cloud Storage 扫描（Dropbox / OneDrive / iCloud Drive 占用）
- **参考**：CleanMyMac Cloud Cleanup / DaisyDisk Scan Cloud
- **风险**：iCloud 占位文件 `.icloud` 不计入磁盘但显示尺寸

### F-3-2 浏览器扩展管理
- **参考**：CMM Extensions
- **范围**：Safari Extension / Chrome Extension manifest 解析

### F-3-3 应用 Updater
- **参考**：CMM Updater / Pearcleaner Apps Updater
- **方案**：扫 `/Applications/*.app/Contents/Info.plist` `CFBundleShortVersionString`，调 Sparkle/MAS feeds 比版

### F-3-4 状态栏 Menu App（RAM/CPU/Battery）
- **参考**：CMM Menu
- **方案**：复用 [TrayController](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrayController.swift)，加 `IOServiceMatching` data source

## P4 — 长期 / 仅记录

| ID | 内容 |
|---|---|
| F-4-1 | KnownVersionedRoots 真正接 mock 注入（届时再加 `fileManager` 参数） |
| F-4-2 | 对竞品 DaisyDisk / OmniDiskSweeper 实测同机对齐复测（需安装试用版） |
| F-4-3 | macOS Sequoia 26 / 27 兼容性矩阵 |

## 追踪规则

- 完成时请在对应条目末尾追加 `→ 完成于 YYYY-MM-DD（commit hash）`
- 新增条目按 P{N}-X-Y 顺序追加，不要插入中间
- 每次回归（`docs/regression/<date>/`）都应回头核查本文档的 P0/P1 是否需要状态更新
