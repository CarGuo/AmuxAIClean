# 竞品功能/性能/安全/价格 对照矩阵 — 2026-06-11

> 数据来源：[docs/competitors/](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/competitors) 7 篇深调文档
> 自家功能口径：[ScanCategory.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCategory.swift) + [MainView.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift) sidebar 实际接入项
> 注：本机**未安装第三方竞品**，对比基于公开文档/源码（如 Pearcleaner GitHub），非实测并排跑数

## 一、综合对照矩阵

| 维度 | **GSYCleanMac** | **CleanMyMac** (5.x) | **Pearcleaner** v5.4.3 | **AppCleaner** 3.6.8 | **DaisyDisk** 4.33 | **OmniDiskSweeper** 1.13 | **GrandPerspective** 3.6.4 |
|---|---|---|---|---|---|---|---|
| **开源/付费** | ✅ 开源免费 | ❌ $40/yr 订阅 / $90 一次 | ✅ 开源 (MIT) | 部分免费 | ❌ $10 一次 (MAS) | ✅ 免费 | ✅ 开源 GPL |
| **签名** | ✅ Developer ID + notarized | ✅ MAS / DevID | ✅ DevID + notarized | ✅ DevID | ✅ MAS+DevID | ✅ DevID | ✅ DevID |
| **App Store 版本** | 计划中 | ✅ 有 (功能阉割) | ❌ | ❌ | ✅ 有 | ❌ | ✅ 有 |
| **macOS 26 Tahoe** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **代码行数（开发体量）** | ~75k LoC Swift | 闭源 | ~120k LoC Swift | 闭源（~4 MB binary） | 闭源 | 闭源 | 闭源 |

## 二、扫描类功能对照

| 扫描类别 | GSYCleanMac | CleanMyMac | Pearcleaner | AppCleaner | DaisyDisk | OmniDiskSweeper |
|---|---|---|---|---|---|---|
| 推荐扫描（Caches/Logs/DerivedData） | ✅ [recommended batch](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCategory.swift) | ✅ System Junk | △ Orphans 偏向残留 | ❌ | ❌ 仅可视化 | ❌ |
| 开发者扫描（DerivedData/SwiftPM/Toolchains） | ✅ [DevArtifactScanner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/DevArtifactScanner.swift) + 规则文件可扩展 | △ Xcode Junk 子项 | ✅ Development 专区（含 brew/npm/pip/cargo） | ❌ | ❌ | ❌ |
| 全盘扫描 | ✅ `/` fullDisk | ✅ Space Lens | ❌ | ❌ | ✅ 主功能 | ✅ 主功能 |
| 任意路径扫描 | ✅ custom URL | ✅ Space Lens drive selector | ✅ File Search Volume → Choose Folder | ❌ | ✅ Scan Folder 按钮 | ✅ Size Folder… (Cmd+O) |
| 大文件扫描 | ✅ [LargeFilesView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/LargeFilesView.swift) (阈值可配，[heap top-N](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/LargeFileLeafTopNHeap.swift)) | ✅ Large & Old ≥50MB | △ File Search + Size Filter Chip 叠加 | ❌ | ✅ Sunburst 自然可见 | ✅ 排序自然可见 |
| 重复文件扫描 | ✅ [DuplicateScanner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/DuplicateScanner.swift) | ✅ Duplicate Finder | ❌ | ❌ | ❌ | ❌ |
| 应用残留扫描（孤儿） | ✅ [OrphanScanner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/OrphanScanner.swift) | ✅ App Leftovers | ✅ Orphans/Zombie | △ LeftOver Finder | ❌ | ❌ |
| 应用占用扫描 | ✅ [AppFootprintScreen](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppFootprintScreen.swift) | ✅ My Tools > App Leftovers | ✅ Applications 列表 | ✅ List Mode | ❌ | ❌ |
| 已卸载应用残留 | △ 同 Orphan | ✅ App Leftovers | ✅ Orphans | △ 通过手动 | ❌ | ❌ |
| 启动项 / LaunchAgent 扫描 | ✅ [LaunchAgentScanner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/LaunchAgentScanner.swift) | ✅ Login Items + Launch Agents | ✅ Services/Daemons 页 | ❌ | ❌ | ❌ |
| LaunchDaemon (root 级) | △ 仅展示 | ✅ | ✅ Helper Tool | ❌ | ❌ | ❌ |
| 旧版本回收（Xcode DeviceSupport / JetBrains） | ✅ [KnownVersionedRoots](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/KnownVersionedRoots.swift) (M4 新接 sidebar) | △ Xcode Junk 子项 | △ Dev 专区 | ❌ | ❌ | ❌ |
| Browser old framework | ✅ [BrowserOldFrameworkScanner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BrowserOldFrameworkScanner.swift) | ❌ | ❌ | ❌ | ❌ | ❌ |
| Mail Downloads | ✅ [MailDownloadsScanner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/MailDownloadsScanner.swift) | ✅ Mail Attachments | ❌ | ❌ | ❌ | ❌ |
| TimeMachine failed backup | ✅ [TMFailedBackupScanner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/TimeMachineFailedBackupScanner.swift) | △ TM Snapshots | ❌ | ❌ | △ TM 卷可扫 | ❌ |
| pkgutil receipts | ✅ [PkgutilReceiptsScanner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/PkgutilReceiptsScanner.swift) (M4) | ❌ | ✅ Packages PKG Manager | ❌ | ❌ | △ ReceiptFolders 反查 |

## 三、可视化对照

| 视图 | GSYCleanMac | CleanMyMac | Pearcleaner | AppCleaner | DaisyDisk | ODS | GrandPerspective |
|---|---|---|---|---|---|---|---|
| 列表视图 | ✅ + bucket 折叠 | ✅ | ✅ | ✅ | △ 右侧 | ✅ 多列 | △ |
| 多层树状下钻 | ✅ [TreeBrowserView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift) (4ms / 24ms cold-mid 实测) | ✅ Space Lens | △ 两层 | ❌ | ✅ 中心点反向 | ✅ Finder 列模式无限层 | ✅ 键盘缩放 |
| 气泡图 / 太阳光 | ❌ | ✅ Space Lens bubble | ❌ | ❌ | ✅ Sunburst (招牌) | ❌ | ❌ |
| Treemap (方块) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ Squarified |
| Quick Look 预览 | ✅ [QuickLookController](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/QuickLookController.swift) | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ |
| 隐藏文件 toggle | ✅ 显式开关 | ❌ (隐式纳入) | ✅ 显式 (默认 off) | ❌ | △ 隐藏空间专扇区 | ✅ 默认显示 | ✅ |

## 四、删除 / 安全对照

| 维度 | GSYCleanMac | CleanMyMac | Pearcleaner | AppCleaner | DaisyDisk | ODS |
|---|---|---|---|---|---|---|
| Trash (可恢复) | ✅ [TrashPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift) 主路径 | ✅ Move to Trash | ✅ UndoManager → Trash | ✅ Move to Trash | ✅ | ✅ Cmd+Del |
| 直接销毁 | ❌ (设计上不做) | ✅ Shredder | ❌ | ❌ | ❌ | ✅ Option+Trash |
| 删除前白名单 / Safety Engine | ✅ [SafetyEngine](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) + [BundleProtection](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/BundleProtection.swift) + [Vendor Trie](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/VendorTrie.swift) (160 测试覆盖) | △ MacPaw 黑盒 | △ "Confirmation alerts" toggle | △ 仅 Default Apps 灰显 | △ 系统目录提示 | △ "已知不可删除" 灰显 |
| Vendor 规则可扩展 | ✅ [vendors.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml) + [vendor_shared.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendor_shared.yaml) | ❌ | ❌ | ❌ | ❌ | ❌ |
| Dry-run 模式 | ✅ [TrashPipeline dryRun](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift) | ❌ | ❌ | ❌ | ❌ | ❌ |
| 撤销历史 | ✅ [UndoHistoryStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/UndoHistoryStore.swift) sidebar 入口 | ❌ | ✅ Edit > Delete History (最近 10 次) | ❌ | ❌ | ❌ |
| Helper Tool 提权 | ❌ ([已下线](file:///Users/guoshuyu/workspace/GSYCleanMac/PITFALLS.md)) 走 Trash + sentinel xpc | ✅ | ✅ SMAppService + Keychain | ✅ SmartDelete daemon | ❌ | ❌ |
| TCC / FDA 引导 | ✅ [TCCGuideView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/Onboarding/TCCGuideView.swift) + [TCCProbe](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/Onboarding/TCCProbe.swift) | ✅ | ✅ Permissions Sheet | ❌ | ✅ | △ root 启动绕过 |
| TCC 保护目录跳过 | ✅ [TCCSkipList](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/TCCSkipList.swift) | △ | △ | ❌ | ✅ Hidden Areas | ❌ |

## 五、性能对比（本工程实测 vs 已知数据）

| 工具 | 测试集 | 时长 | 来源 |
|---|---|---|---|
| **GSYCleanMac BulkScanner** | 358k files / 18 GB Caches | **5.5s** | [perf.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/regression/2026_06_11/perf.md) Bench A |
| **GSYCleanMac Coordinator 全链路** | 81k files / 7.4 GB repo | **1.4s** | perf.md Bench D |
| **GSYCleanMac directChildren mid-tree** | 300k 节点 SQL 下钻 | **24ms** | perf.md Bench B2 |
| **du -sh -A** | 同 18GB Caches | **9.7s** + 9 处 TCC 漏算 | perf.md Bench C |
| **DaisyDisk** Time Machine 卷 | — | 20~30 分钟 | [DaisyDisk.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/competitors/DaisyDisk.md) 自述 |
| **CleanMyMac Smart Scan** | 整盘 | 通常 30s~2min（首扫，无 FDA 慢） | 公开评测 |
| **Pearcleaner Orphans** | 整盘 | 通常 5~15s | GitHub issue/README |
| **AppCleaner SmartDelete** | 单 App 监听 | <1s | FreeMacSoft 文档 |
| **OmniDiskSweeper** Sweep | 整盘 | 通常 10~30s | Omni 文档 |

> **说明**：除我们 4 个 bench 实测外，其余均来自公开文档/评测数字，**未在同一机器对齐复测**。

## 六、定价对照

| 工具 | 价格模型 | 一次成本 | 备注 |
|---|---|---|---|
| **GSYCleanMac** | 开源免费 | **$0** | 永久免费 |
| **CleanMyMac** | 订阅 / 一次买断 | $40/yr 或 $90 永久 | Setapp 用户可订阅 $9.99/mo |
| **Pearcleaner** | 开源免费 | $0 | 接受 Sponsor |
| **AppCleaner** | 免费 | $0 | 单一职责 |
| **DaisyDisk** | 一次买断 | $9.99 (MAS) | DevID 版可试用 |
| **OmniDiskSweeper** | 免费 | $0 | Omni Group 维护 |
| **GrandPerspective** | 开源/可选捐赠 | $0 (MAS $2.99 表心意) | 老牌 GPL |

## 七、我们的核心竞争优势 (TL;DR)

1. **开源 + 免费 + 安全引擎透明可审计** — [SafetyKit](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit) 全套规则在 [Resources/Rules](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules) 用户可读 yaml，**唯一一家**。
2. **比 du 又快又准** — 5.5s 扫 18 GB / 358k files (du -sh -A 需 9.7s 且漏算 1 GB TCC 目录)。
3. **后台按需下钻** — 展开目录时只聚合当前子树直接子项，不引入扫描收尾落盘等待。Pearcleaner / AppCleaner 仅两层下钻，CMM Space Lens 主推 bubble 视觉而非列表 perf。
4. **Vendor 规则可扩展** — `vendors.yaml` 用户可自加 cleanup 规则，闭源四家全无。
5. **Dry-run 模式 + UndoHistory 双保险** — 删除前可预览影响，删除后可回滚，**业内独此一份**。
6. **9 包 / 857 tests 单元覆盖** — 所有竞品均闭源（除 Pearcleaner / GrandPerspective），用户无从核查测试边界。

## 八、我们的差距 / 后续可补

| 差距项 | 主要参考竞品 | 优先级 |
|---|---|---|
| 气泡图 / Treemap 可视化（让用户"一眼看见大目录"） | DaisyDisk Sunburst / GrandPerspective Squarified | P1 |
| 浏览器隐私痕迹（cookies / history / autofill） | CleanMyMac Privacy / Browser | P2 |
| 系统维护脚本（periodic daily/weekly/monthly） | OnyX Maintenance / CMM Maintenance | P2（部分已在 [MaintenanceTasks](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/MaintenanceTasks.swift)） |
| Cloud Storage 扫描（Dropbox / OneDrive / iCloud） | CMM Cloud Cleanup / DaisyDisk Scan Cloud | P3 |
| 浏览器扩展管理 | CMM Extensions | P3 |
| Lipo 通用二进制瘦身 | Pearcleaner Lipo | P3（已有 [LipoKit](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/LipoKit)，未接 sidebar） |
| 状态栏菜单 App（RAM/CPU/Battery 监控） | CMM Menu | P4 |
| Sentinel 模式（拖 .app → Trash 自动唤起） | AppCleaner SmartDelete / Pearcleaner Sentinel | ✅ 已有 [SentinelManager](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/SentinelManager.swift) (M4 完成) |
| Brew 管理 GUI | Pearcleaner Brew | P3（已有 [BrewKit](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/BrewKit)，未接 sidebar） |
| 应用 Updater | CMM Updater / Pearcleaner Apps Updater | P4 |
