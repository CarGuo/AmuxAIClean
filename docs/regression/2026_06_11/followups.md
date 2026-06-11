# 回归后续追踪条目 — 2026-06-11

> 本文档把 [REPORT.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/regression/2026_06_11/REPORT.md) + [competitors_matrix.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/regression/2026_06_11/competitors_matrix.md) + [perf.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/regression/2026_06_11/perf.md) 中标注的所有「未做 / followup / 缺口」整理为可追踪条目，按优先级排序。

## P0 — 本轮已顺手补完

| ID | 内容 | 状态 |
|---|---|---|
| F-0-1 | [KnownVersionedRoots.swift#L111-L139](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/KnownVersionedRoots.swift#L111-L139) `var fileManager` 死代码删除 | ✅ 本轮删除（实际从未引用，"forward-compat" 注释名不副实） |
| F-0-2 | PerfBench 1M 节点压力 bench | ✅ 本轮跑完，[B3](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/regression/2026_06_11/perf.md) 入库 |
| F-0-3 | E2E smoke 启动 release .app 跑通 + AX 抓取 + 干净退出 | ✅ 本轮 [e2e.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/regression/2026_06_11/e2e.md) PASS |
| F-0-5 | SQLite scan.sqlite 11G 体积治理（无 session 保留 + auto_vacuum=NONE + 冗余索引）| ✅ 本轮闭环 [db_size.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/regression/2026_06_11/db_size.md) — 4 处代码改动 + 5 新测试 PASS，新库稳态 < 400 MB（缩 27×） |

## P0-bug — E2E 发现的真 bug（需要单独修）

### F-0-4 vendors.yaml / vendor_shared.yaml 未被打包进 .app ✅ 已修复（2026-06-11）
- **现象**：[GSYCleanMacApp.swift#L467-L475](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift#L467-L475) 查 `Bundle.main` 的 `vendors.yaml` 永远查不到，每次启动 NSLog `vendors.yaml 未找到，跳过 vendor 规则加载`
- **影响**：production 用户态 vendor 规则**完全不生效**，SafetyKit fallback 到代码内置 vendor 列表，命中精度下降（[Resources/Rules/vendors.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml) 里所有 vendor 增量条目实际未被消费）
- **根因**：[GSYCleanMac.xcodeproj/project.pbxproj](file:///Users/guoshuyu/workspace/GSYCleanMac/GSYCleanMac.xcodeproj/project.pbxproj) 的 Copy Bundle Resources phase 完全没引用 `Resources/Rules/` 目录或 `*.yaml` 文件
- **方案**：xcode 打开 project → GSYCleanMac target → Build Phases → Copy Bundle Resources → 拖入 `Resources/Rules` 整目录（保持 folder reference 蓝色而非 group 黄色），重 build 验证
- **修复实际操作**：用户在 Xcode GUI 里把 3 个 yaml 加入 Resources phase（pbxproj 新增 PBXBuildFile `4B62D5DE/DF/E0`、PBXFileReference `4B62D5DA/DB/DC`、PBXGroup `4B62D5DD Rules`，三个 yaml 进入 Resources Copy Phase `files` 数组与 `Assets.xcassets`/`InfoPlist.strings` 并列），实际效果为平铺到 `.app/Contents/Resources/` 顶层，被 [GSYCleanMacApp.swift#L467-L475](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift#L467-L475) 的 fallback 分支命中
- **验收**：
  - ✅ `find .app -name vendors.yaml` 命中 3 个 yaml（vendors / vendor_shared / safe_paths）
  - ✅ 启动 NSLog 改为 `[GSYCleanMac] 已加载 79 条 vendor 规则`
  - ✅ e2e-smoke 二次跑 RESULT PASS、crash_hits=0
  - 详情：[e2e.md §三 二次验证](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/regression/2026_06_11/e2e.md)
- **优先级**：~~**P0**~~ → ✅ 已闭环


## P1 — 性能可优化（数据已证据齐全）

### F-1-1 SQLite `cache_size` 调优（1M 节点场景）✅ 已落地（2026-06-11）
- **现象**：1M 节点 cold-root 4.5s，3.3× 数据吃 8.9× 时延（vs 300k）
- **推断**：默认 `cache_size = -2000`（2MB）下 GROUP BY 中间结果集溢写临时表
- **方案**：在 [GRDBScanResultStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift) 打开 connection 后 `PRAGMA cache_size = -10000`（10MB），再跑 B3 对比
- **验收**：1M cold ≤ 2s（接近 warm 现值 2.76s 即可）
- **依据**：[perf.md §B3 判读](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/regression/2026_06_11/perf.md)
- **落地**：[prepareDatabase](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L71-L79) 加 `PRAGMA cache_size = -10000` + [_debugCacheSize()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L666-L672) debug 接缝 + [test_新建库_cache_size应为10MB](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Tests/ScanKitTests/GRDBScanResultStoreTests.swift#L530-L539) 断言验证；ScanKit 全包 203 tests / 0 failures

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

### F-2-3 Lipo 通用二进制瘦身接入 sidebar ✅ 已落地（2026-06-11）
- **现状**：[LipoKit](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/LipoKit) 已完成，**未接入 sidebar**
- **方案**：[ScanCategory.Kind](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCategory.swift#L9-L14) 增加 `case lipo`，在 [MainView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift) sidebar 增 LipoScreen 入口
- **落地**：走 sentinel ID 旁路（与 Maintenance / Uninstall / UndoHistory 同款，避免污染 ScanCategory 枚举）；新建 [LipoScreen](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/LipoScreen.swift)（audit + extract + drop）；MainView 加 `lipoSentinelID` + Dev Tools section sidebar row + `isLipoMode` 分发；AppUI/Package.swift 加 LipoKit 依赖；Xcode App target 同步加 LipoKit framework

### F-2-4 Brew 管理接入 sidebar ✅ 已落地（2026-06-11）
- **现状**：[BrewKit](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/BrewKit) 已完成，**未接入 sidebar**
- **方案**：同 F-2-3
- **落地**：新建 [BrewScreen](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/BrewScreen.swift)（三 tab installed / outdated / cleanup，dry-run 不真删）；MainView 加 `brewSentinelID` + sidebar row + `isBrewMode` 分发；AppUI/Package.swift 加 BrewKit 依赖；Xcode App target 同步加 BrewKit framework；AppUI 全包 397 tests / 0 failures

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
