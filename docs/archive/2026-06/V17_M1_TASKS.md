# v1.7 M1 PR 级任务拆分

> 创建日期：2026-06-15
> 上游：[DEVELOPER_ONE_CLICK_PLAN.md](file:///Users/amuxuser/workspace/AmuxAIClean/docs/DEVELOPER_ONE_CLICK_PLAN.md) §2 / §9
> 范围：v1.7 M1（2026-07-08 – 2026-07-15，1 周）
> 原则：每个 PR ≤ 600 行 diff，独立可 review；任一 PR 失败不阻塞下一个 PR 的 review

---

## PR-0（已合并基础设施，本轮已完成）

**目标**：为 v1.7 M1 后续 PR 准备最小骨架。

| 改动 | 文件 | 说明 |
|---|---|---|
| 扩展 KnownVersionedRoots | [KnownVersionedRoots.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/KnownVersionedRoots.swift#L75-L94) | 新增 Android SDK build-tools / platforms / system-images keepLatest=2 |
| 单测 | [KnownVersionedRootsTests.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Tests/ScanKitTests/KnownVersionedRootsTests.swift) | 新增 `test_entries_包含_Android_SDK_三条_*` / `test_scanAll_构造_Android_SDK_build_tools_*` / `test_scanAll_构造_Android_SDK_platforms_*` 三条 |
| 新增协议骨架 | [DeveloperWorkflow.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/DeveloperWorkflow.swift) | `DeveloperWorkflow` / `DeveloperCard` / `DeletionRecipe` / `AppleWorkflow`（空 cards）|
| 骨架契约测试 | [DeveloperWorkflowSkeletonTests.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Tests/ScanKitTests/DeveloperWorkflowSkeletonTests.swift) | 5 条契约（ID 命名、空 cards、recipe 安全门、Risk 三档对齐）|

**验收**：`swift test --filter ScanKitTests` 全绿，370+ 既有测试不破。

---

## PR-1：Apple 工作流前 6 张静态卡片（✅ 已完成 2026-06-15）

**目标**：把"零代码风险"的 6 类路径源以卡片形式接入 AppleWorkflow（仍**不接 UI**，仅在 ScanKit 内可被注册表读取）。

| 卡片 ID | 路径源 | 复用 | 状态 |
|---|---|---|---|
| `card.apple.derived-data` | `~/Library/Developer/Xcode/DerivedData` | literal · safe | ✅ |
| `card.apple.archives` | `~/Library/Developer/Xcode/Archives` | literal · confirm | ✅ |
| `card.apple.ios-devicesupport` | KVR ruleID `apple.ios-device-support.versioned` | versionedRoot · safe | ✅ |
| `card.apple.watchos-devicesupport` | KVR ruleID `apple.watchos-device-support.versioned` | versionedRoot · safe | ✅ |
| `card.apple.macos-devicesupport` | KVR ruleID `apple.macos-device-support.versioned` | versionedRoot · safe | ✅ |
| `card.apple.coresimulator-caches` | `~/Library/Developer/CoreSimulator/Caches` | literal · safe | ✅ |

**实际改动**（≈ 90 行 diff）：
- [DeveloperWorkflow.swift L116-L220](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/DeveloperWorkflow.swift#L116-L220)：填充 `AppleWorkflow.cards()`，存在性检测决定是否展示
- [AppleWorkflowCardsTests.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Tests/ScanKitTests/AppleWorkflowCardsTests.swift)：新建 8 个 case（部分存在 3 个 / 全部存在 4 个 / 防回归 1 个）
- [DeveloperWorkflowSkeletonTests L23-L32](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Tests/ScanKitTests/DeveloperWorkflowSkeletonTests.swift#L23-L32)：原"骨架空 cards"契约升级为"空 home 不污染 UI"契约

**关键设计决策（与原 PR-1 计划的偏离）**：
- ❌ **不用** `PathSource.vendor("Apple Developer Tools")`——因为 vendors.yaml 该 vendor 含 21 条 path（Xcode + Simulator + SwiftPM 全集），颗粒度太粗会破坏"按主题分卡"目标
- ✅ **改用** `.literal` + `.versionedRoot` 两种源，与 vendors.yaml 对应行号严格对位
- ✅ **每张卡 + 大前提双重存在性检测**：先判 Xcode 或 CoreSimulator 根目录存在，再判每张卡的子目录存在

**验收清单**：
- [x] 当 `~/Library/Developer/Xcode` 与 `~/Library/Developer/CoreSimulator` 都不存在时，AppleWorkflow 返空（不出空入口）
- [x] DerivedData 卡片 risk=safe；Archives risk=confirm
- [x] DeviceSupport 三卡均通过 `KnownVersionedRoots.scanAll` 取数（不直接 ls 子目录）
- [x] 所有 Apple 卡 ID 全局唯一
- [x] 所有 PR-1 卡片 recipe 均为 `.filesystem`（无 `.commandLine` 泄漏）
- [x] 既有 219 个 ScanKit 测试全绿（8.3s）
- [x] GetDiagnostics 三文件零警告

---

## PR-2：SimctlDevicesScanner + Apple 后续 4 张卡（✅ 已完成 2026-06-15）

**目标**：接入「按 simctl device 实例清理」能力，并把卡片绑定到 AppleWorkflow。**仍不开 UI，但 `.commandLine` recipe 通过 `isExecutableInCurrentBuild=true` 的 SubprocessExecutor allowlist**。

| 子任务 | 改动 | 状态 |
|---|---|---|
| 新建 [SimctlDevicesScanner.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/SimctlDevicesScanner.swift) | `xcrun simctl list devices --json` 解析，输出 (udid, name, runtime, state, size) | ✅ |
| 新建 [SimctlRuntimeScanner.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/SimctlRuntimeScanner.swift) | `xcrun simctl list runtimes --json` + FileManager 估算 sizeBytes | ✅ |
| 新建 [SubprocessExecutor.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/SubprocessExecutor.swift)（**ScanKit 层**） | allowlist：`xcrun simctl list devices/runtimes --json`、`xcrun simctl delete`、`xcrun simctl runtime delete`；其他全部拒绝；5s timeout；dryRun 闸门 | ✅ |
| 新增卡片 | `card.apple.coresimulator-devices`（commandLine） / `card.apple.coresimulator-runtimes`（commandLine） / `card.apple.coresimulator-volumes`（filesystem） / `card.apple.derived-data-per-project`（dynamicScanner + filesystem 占位） | ✅ |
| 安全门 | NSWorkspace 检测 `com.apple.iphonesimulator` 运行 → devices/runtimes 卡 risk 降级为 blocked，summary 带 ⚠️ 提示 | ✅ |
| DeletionRecipe.isExecutableInCurrentBuild 升级 | `.commandLine` 必须命中 SubprocessExecutor.defaultAllowlist 才返 true（二道闸门，挡未授权命令） | ✅ |
| 单测/集成测试 | [SubprocessExecutorTests](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Tests/ScanKitTests/SubprocessExecutorTests.swift) 10 个 / [SimctlDevicesScannerTests](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Tests/ScanKitTests/SimctlDevicesScannerTests.swift) 6 个 / [SimctlRuntimeScannerTests](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Tests/ScanKitTests/SimctlRuntimeScannerTests.swift) 6 个 / [AppleWorkflowPR2CardsTests](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Tests/ScanKitTests/AppleWorkflowPR2CardsTests.swift) 9 个 | ✅ |

**关键设计决策（与原 PR-2 计划的偏离）**：
- ❌ **不把 SubprocessExecutor 放在 AppUI 层**：原计划写的是 AppUI 层，但实地探查发现 [DefaultMaintenanceRunner](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/MaintenanceTasks.swift#L137-L171) 与 [PkgutilReceiptsScanner](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/PkgutilReceiptsScanner.swift) 已有同档次 Process 调用范式都在 ScanKit；Scanner 自己要调 simctl 也得有这个工具，反向依赖（ScanKit→AppUI）不行
- ✅ **改用** ScanKit 层 [SubprocessExecutor.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/SubprocessExecutor.swift)，AppUI 直接通过现有依赖访问
- ✅ **runtimes 卡仅依赖 csRoot 存在**：runtime 元数据来自 simctl JSON 而非 FS 枚举，无须等子目录
- ✅ **isSimulatorRunning 闭包注入**：默认实现走 NSWorkspace（仅 macOS 主进程），单测注入 `{ false }` / `{ true }` stub 避免 CI 偶发

**实际改动**（≈ 850 行 diff）：
- ScanKit 源码：3 个新文件（SimctlDevicesScanner 167L / SimctlRuntimeScanner 172L / SubprocessExecutor ~140L） + DeveloperWorkflow.swift 重构（+150L）
- ScanKit 测试：3 个新测试文件 + 1 个升级（AppleWorkflowCardsTests）+ 1 个升级（DeveloperWorkflowSkeletonTests `commandLine` 安全门契约）

**验收清单**：
- [x] simctl 不存在（非 macOS 开发机/CI runner）→ scanner 优雅返回空，不抛
- [x] 任何非 allowlist 命令调用 SubprocessExecutor → 拒绝并抛 `SubprocessError.notAllowed`
- [x] 检测到 Simulator.app 运行时，devices/runtimes 卡 risk 必须降级为 blocked + summary 带 ⚠️
- [x] dryRun 模式：allowlist 命中也不真起进程，但**未命中仍然抛 notAllowed**（先校验再 dryRun）
- [x] `isExecutableInCurrentBuild` 对 `.commandLine` 做 SubprocessExecutor.defaultAllowlist 二次校验
- [x] ScanKit 251 tests + AppUI 411 tests = 662 tests 全绿（22s 内）
- [x] GetDiagnostics 三组新文件零警告

---

## PR-3：JetBrains 跨产品分组 + KnownVersionedRoots 升级（✅ 已完成 2026-06-15）

**目标**：解决 [REVIEW_2026_06.md](file:///Users/amuxuser/workspace/AmuxAIClean/docs/REVIEW_2026_06.md) 提到的 JetBrains Caches 跨产品比版本号问题。

**Entry 协议升级**：

```swift
public struct Entry: Sendable, Hashable {
    public let relativePath: String              // 仍是相对 home 路径（原 collectionRoot）
    public let displayName: String
    public let keepLatest: Int
    public let ordering: VersionedRetainScanner.Ordering
    public let ruleID: String
    /// 新增：子目录名分组正则。
    /// 若 nil，则整 collectionRoot 子目录视为一组（旧行为）；
    /// 若提供，则匹配第一个 capture group 作为 group key，每组独立排序 + keepLatest。
    public let groupingRegex: String?
}
```

**新增 entries**（均带 groupingRegex=`^([A-Za-z]+)\d{4}\.\d+$`）：
- `Library/Caches/JetBrains` → 按产品分组：IntelliJIdea / PyCharm / WebStorm / GoLand / Rider / CLion / DataGrip 等
- `Library/Application Support/JetBrains` → 同上（Toolbox / consentOptions 因不匹配年版号正则被自动忽略）
- `Library/Logs/JetBrains` → 同上

**验收清单**：
- [x] 旧 entries（无 groupingRegex）行为完全不变 → [test_旧行为_DeviceSupport_4版_保留2_等同_KnownVersionedRootsTests](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Tests/ScanKitTests/KnownVersionedRootsGroupingTests.swift#L142-L158)
- [x] `IntelliJIdea2024.1/2/3` + `PyCharm2024.2` + `WebStorm2024.1/2` 同存时，IDEA 淘汰 2 个、PyCharm 不淘汰、WebStorm 淘汰 1 个 → [test_分组_IDEA_3版_PyCharm_单版_仅_IDEA_产出旧版](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Tests/ScanKitTests/KnownVersionedRootsGroupingTests.swift#L75-L114)
- [x] groupingRegex 解析失败 → 该 entry 整条降级为旧行为 + AmuxLog.warning（保护性回退已实现于 [scanGrouped](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/KnownVersionedRoots.swift#L214-L229)）
- [x] Toolbox/consentOptions 等无年版号目录不被误识别 → [test_PR3_JetBrains_entries_与_Toolbox_entry_路径互不重叠](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Tests/ScanKitTests/KnownVersionedRootsGroupingTests.swift#L44-L71)

**关键设计决策**：
- 复用 [VersionedRetainScanner.sort](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/VersionedRetainScanner.swift#L174-L192)（internal）做组内排序，避免造临时目录跑 detect
- 子目录名按 **fullMatch**（必须 location=0 且 length=NSString.length）才计入分组，未匹配自动忽略——避免误判 Toolbox/consentOptions
- displayName 拼接 group key（如 "JetBrains · 索引/编译缓存（旧版本） · IntelliJIdea"）方便 UI 直观看到是哪个产品的残留
- `Library/Application Support/JetBrains` entry 与既有 Toolbox `apps` entry 路径有父子关系但通过 fullMatch + 不同 relativePath 共存不冲突

**实际改动 ≈230 行 diff**：
- [KnownVersionedRoots.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/KnownVersionedRoots.swift)（+160 行：Entry 字段 + 3 个 JetBrains entries + scanGrouped 内核 + import LogKit）
- [KnownVersionedRootsGroupingTests.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Tests/ScanKitTests/KnownVersionedRootsGroupingTests.swift)（新建 168 行 / 5 case）

**测试结果**：ScanKit 256 tests / 2 skipped / 0 failures；AppUI 411 tests / 0 failures（零回归）

---

## PR-4：开发者一键 UI 接入（🚧 Scanner 实现已落 2026-06-15，UI 接入延后）

**实际落地范围（vs 原计划）**：
- ✅ **已落**：WorkflowRegistry + 3 个动态 Scanner 实现（derived-data-per-project / simctl-devices / simctl-runtimes）
- ⏸️ **延后到 PR-5**：AppUI 侧边栏新一级节点 + WorkflowDetailView（避免本 PR 改动面过大；UI 接入仍能复用 PR-4 落地的 ScanKit API）

**目标**：把 AppleWorkflow 10 张卡的"占位"`dynamicScanner` 入口接到真实扫描器，让上层（AppUI 或 CLI）拿到 `DeveloperCard` 就能 `WorkflowRegistry.resolve(scannerID: card.source.scannerID, home:)` 直接拿子项列表。

**新增 API 一览**：

```swift
// 统一 DTO
public struct WorkflowScanHit: Sendable, Hashable, Identifiable {
    public let url: URL
    public let sizeBytes: Int64?
    public let displayName: String
    public let note: String?
    public var id: String { url.path }  // 跨源不冲突的最低公约数主键
}

// 路由表（纯函数 + 容错）
public enum WorkflowRegistry {
    public static func resolve(scannerID: String,
                               home: URL,
                               executor: SubprocessExecutor? = nil) async -> [WorkflowScanHit]
}
```

**3 个动态 Scanner 路由映射**：

| scannerID | Scanner | 来源 | hit.displayName / note |
|---|---|---|---|
| `scanner.derived-data-per-project` | [DerivedDataPerProjectScanner](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/DerivedDataPerProjectScanner.swift) | `~/Library/Developer/Xcode/DerivedData/*` FS 扫描 | "MyApp" / "MyApp-abc123xyz" |
| `scanner.simctl-devices` | [SimctlDevicesScanner](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/SimctlDevicesScanner.swift) | `xcrun simctl list devices --json` | "iPhone 16 · UDID" / "Booted · com.apple.CoreSimulator.SimRuntime.iOS-18-0" |
| `scanner.simctl-runtimes` | [SimctlRuntimeScanner](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/SimctlRuntimeScanner.swift) | `xcrun simctl list runtimes --json` | "iOS 18.0 (22A348)" / runtime identifier |

**验收清单**：
- [x] 旧入口（推荐 / 自定义 / 全盘 / 大文件）行为不变 → AppUI 411 tests 全绿
- [x] [DerivedDataPerProjectScanner](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/DerivedDataPerProjectScanner.swift) 正确解析工程名 + 估算 size + 跳过 `ModuleCache.noindex` → 6 case 全绿
- [x] [WorkflowRegistry](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/WorkflowRegistry.swift) 未知 scannerID 不抛、空 home / dryRun executor 返回 [] → 9 case 全绿（含 PR-4 升级后的 derived-data 真实接线断言）
- [x] hit.id 用 url.path 作跨源主键，不冲突
- [ ] **延后到 PR-5**：开发者一键节点折叠默认收起 / WorkflowDetailView 可下钻 / 删除走 ConfirmDialog + recycle / simctl 走 SubprocessExecutor

**关键设计决策**：
- **WorkflowRegistry 用 enum + static func**：纯函数路由，无状态，避免引入 actor 调度开销；并发安全交由下游 actor Scanner 自身保证
- **derived-data 路由调 detect 而非 discover**：本扫描器纯 FS 无 subprocess，static 入口能省一次 Task 切换
- **hit.id = url.path**：未来 UI 合并多源 hit 时（如某卡同时展示 simctl + DerivedData）也不会主键冲突
- **失败兜底一致性**：未知 scannerID → warning 一行 + `[]`；扫描器抛 → 已被 Scanner 内部兜底；catch 仅作契约稳健性保底
- **UI 接入延后**：本 PR-4 让 ScanKit 层完全可用，可被未来 AppUI / CLI / TestHarness 任何上层消费；UI 接入是独立工作量（侧边栏注入 + DetailView + DeleteSheet 适配），值得独立 PR

**实际改动 ≈600 行 diff**：
- 新增 [DerivedDataPerProjectScanner.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/DerivedDataPerProjectScanner.swift)（生产 ~110 行）
- 新增 [WorkflowRegistry.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/WorkflowRegistry.swift)（生产 ~130 行）
- 新增 [DerivedDataPerProjectScannerTests.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Tests/ScanKitTests/DerivedDataPerProjectScannerTests.swift)（测试 ~200 行 / 6 case）
- 新增 [WorkflowRegistryTests.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Tests/ScanKitTests/WorkflowRegistryTests.swift)（测试 ~190 行 / 9 case）

**测试结果**：ScanKit 271 tests / 2 skipped / 0 failures；AppUI 411 tests / 0 failures（零回归）

---

## PR-5（✅ 已完成 2026-06-15）：Workflow AppUI 接入

**目标**：把 PR-4 落地的 WorkflowRegistry 接到 AppUI 侧边栏，让用户在 UI 中体验 Apple / Android / WebNode 三大工作流。

**实际落地范围**：
- 新建 [WorkflowDetailView.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/WorkflowDetailView.swift)：通用工作流详情壳 + @MainActor `WorkflowDetailViewModel`，支持：
  - `.literal / .versionedRoot / .dynamicScanner / .vendor` 四种 PathSource 全分发
  - 静态卡（literal/versionedRoot）同步算 size，动态卡 await `WorkflowRegistry.resolve`，每卡独立 loading 态
  - 卡片 DisclosureGroup + 行内 Checkbox 勾选，safe 卡默认 expanded + 默认全选
  - 删除路径：`.filesystem` 走 [DeletionPipeline.moveToTrash](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/DeletionPipeline.swift)；`.commandLine` 暂走 alert 提示（PR-6 接入）
  - footer 展示「已选 N 项 · 共 X.XX GB」+ 重新扫描 + 移到废纸篓
- [MainView.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/MainView.swift) 改动：
  - 新增 3 个 sentinel：`workflow.apple` / `workflow.android` / `workflow.webnode` + 集合 `workflowSentinelIDs`
  - sidebar 新增 Section "Developer Workflows"，3 行（applelogo / cube.box / globe 图标）
  - `results` 区新增 3 个分支：`isWorkflow*Mode` → `WorkflowDetailView(workflow:..., pipeline:)`
  - 与既有 `batch.developer` sentinel **共存**，向后兼容旧 `triggerDeveloperScan` 流程

**关键设计决策**：
1. **独立 @StateObject ViewModel 不复用 ScanCoordinator**：工作流是"按卡多源并发"，coordinator 是"单源 BulkScanner 串行"，模型不兼容
2. **不动 batch.developer**：v1.5 落地的散点扫保留，不强制用户迁移；workflow sentinel 是叠加能力
3. **删除走 pipeline.moveToTrash**：与 MainView.performDelete 同款，零新增删除路径，安全契约不破
4. **commandLine 暂不执行**：simctl 删除留 PR-6 单独 PR；当前点删除会 alert 告知"已跳过 N 项"
5. **风险面收敛**：MainView 改动仅追加（不改 onChange/resetSelectionState 路径），扫描/勾选/删除既有路径零改动

| 改动 | 文件 |
|---|---|
| WorkflowDetailView + ViewModel | [WorkflowDetailView.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/WorkflowDetailView.swift)（~420 行） |
| MainView sentinel + sidebar Section + results 分支 | [MainView.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/MainView.swift) |
| 单测 | [WorkflowDetailViewTests.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Tests/AppUITests/WorkflowDetailViewTests.swift)（6 case） |

**验收清单**：
- [x] 选中 "Apple" → 看到 7 张卡（视机器实际情况），每张可展开 hits
- [x] 选中 "Android" / "Web/Node" → 看到对应卡（机器无相关目录时空态文案）
- [x] 删除走 TrashPipeline，commandLine 卡被跳过且 alert 明示
- [x] sentinel ID 全局唯一（test_PR5_sentinel_workflow_三ID_全局唯一_v17 锁住）
- [x] bootstrap 幂等 + 重新扫描可重入 + formatBytes 边界稳定

**测试结果**：AppUI 411 → 417 tests（+6）；ScanKit 不变 295；零失败

---

## PR-6（新增计划）：AndroidWorkflow 落地

**已完成（2026-06-15）**。详见 [AndroidWorkflow.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/AndroidWorkflow.swift)。

**实际落地**：
- 10 张 DeveloperCard：gradle-caches / gradle-daemon / android-build-cache / android-cache / android-avd（confirm）/ sdk-build-tools（versionedRoot）/ sdk-platforms（versionedRoot）/ sdk-system-images（versionedRoot + confirm）/ jetbrains-androidstudio-caches / jetbrains-androidstudio-logs
- 大前提 guard：5 类祖目录任一存在才输出，避免空 home 污染
- gradle / .android 三卡走目录预检；SDK 三卡复用 [KnownVersionedRoots](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/KnownVersionedRoots.swift) 已注册 entries；JetBrains glob 路径保留 `*` 由 UI 层 expand
- [AndroidWorkflowCardsTests.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Tests/ScanKitTests/AndroidWorkflowCardsTests.swift)（5 case）

---

## PR-7（新增计划）：WebNodeWorkflow 落地

**已完成（2026-06-15）**。详见 [WebNodeWorkflow.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/WebNodeWorkflow.swift) + [NodeModulesScanner.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/NodeModulesScanner.swift)。

**实际落地**：
- 6 张 DeveloperCard：pnpm-store / yarn-cache / npm-cache / node-gyp-cache / electron-cache / node-modules-scattered（dynamicScanner + confirm）
- 新增 [NodeModulesScanner](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/NodeModulesScanner.swift)：扫 ~/Developer / ~/Projects / ~/Code / ~/workspace / ~/src 5 根，maxDepth=4，命中 node_modules 后不下钻（防递归爆栈）
- [WorkflowRegistry.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/WorkflowRegistry.swift) 新增 `scanner.node-modules-scattered` 路由
- 测试 19 case：[NodeModulesScannerTests.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Tests/ScanKitTests/NodeModulesScannerTests.swift)（7）+ [WebNodeWorkflowCardsTests.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Tests/ScanKitTests/WebNodeWorkflowCardsTests.swift)（10）+ [WorkflowRegistryTests.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Tests/ScanKitTests/WorkflowRegistryTests.swift) 追加 2 case

---

## PR-8（新增计划）：Workflow CLI（TestHarness 扩展）

**已完成（2026-06-15）**。详见 [workflow-cli/main.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/TestHarness/Sources/workflow-cli/main.swift)。

**实际落地**：
- [TestHarness/Package.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/TestHarness/Package.swift) 新增 executableTarget `workflow-cli`，仅依赖 ScanKit
- `@main async struct WorkflowCLI`：参数 `<workflow> [--json]`，workflow ∈ `apple / android / webnode`
- 默认表格输出：cardID / title / risk / sourceKind / hits.count（含 CJK 宽度对齐）
- `--json`：`JSONEncoder.prettyPrinted | sortedKeys | withoutEscapingSlashes`，结构 `[{cardID, title, risk, hits:[{path, size, name}]}]`
- dryRun=true 注入 `SubprocessExecutor(timeout:1, dryRun:true)`，simctl 卡静默返回 0（CI safe）
- 友好退出：unknown workflow → exit 64；空卡片 → exit 1（json 模式 exit 0）

**运行示例**：
```bash
cd Packages/TestHarness
swift run workflow-cli apple          # 表格
swift run workflow-cli apple --json   # JSON
```

---

## PR-9：simctl 真删 + i18n（✅ 已完成 2026-06-15）

**目标**：把 `.commandLine` recipe（仅 simctl devices/runtimes 两类）从 PR-5 的"占位拒绝"升级为"两轮确认 → 真执行"；同时把 WorkflowDetail / MainView workflow 路径中文硬编码全量迁移到 xcstrings 中英双语。

### PR-9a：simctl 真删主线

| 子任务 | 改动 | 状态 |
|---|---|---|
| WorkflowScanHit DTO 扩展 | [WorkflowRegistry.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/WorkflowRegistry.swift) 新增 `commandLineTailArg: String?`（默认 nil，向后兼容）；`scanner.simctl-devices` 填 UDID、`scanner.simctl-runtimes` 填 runtime identifier | ✅ |
| 协调器 | 新建 [SimulatorDeleteCoordinator.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/SimulatorDeleteCoordinator.swift)：纯 Sendable struct（无 SwiftUI 依赖）；`Item / Plan / Outcome` 三段式；prepare 4 分支（empty / invalid / blockedSimulatorRunning / ready）；execute 串行调 SubprocessExecutor 并 yield Outcome[]（throw 转 exitCode=-3 不中断后续）；truncate 限 512 字符 | ✅ |
| ViewModel 状态机 | [WorkflowDetailView.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/WorkflowDetailView.swift) WorkflowDetailViewModel 新增 `@Published pendingSimctlStage: SimctlConfirmStage?`（.firstReview / .secondConfirm）；新增 `advanceSimctlConfirm()` / `cancelSimctlConfirm()` / `executeConfirmedSimctl() async`；performDelete 移除 commandLineBlocked 占位 | ✅ |
| 两轮确认 sheet | 新增 `SimctlConfirmSheetContent: View`：第一轮列 displayName + 完整 `xcrun simctl ...` 命令 preview；第二轮加 `exclamationmark.octagon.fill` + 红字 irreversible 警示 + `role: .destructive` Primary | ✅ |
| i18n 文案 | [Localizable.xcstrings](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/Resources/Localizable.xcstrings) 追加 11 个 `workflow.detail.simctl.*` key（中英双语 + manual extractionState） | ✅ |
| 单测 | [SimulatorDeleteCoordinatorTests.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Tests/AppUITests/SimulatorDeleteCoordinatorTests.swift)：8 个协调器 case（4 prepare 分支 + execute dryRun/throw/顺序保留/部分失败汇总） + 2 个 ViewModel 集成 case（sheet 状态机 firstReview→secondConfirm→nil + Simulator running 不弹 sheet）；总计 10 个 | ✅ |

**关键设计决策**：
- ✅ **Coordinator 与 ViewModel 隔离**：simctl 删除是破坏性操作，独立 Sendable struct 便于单测 allowlist / Simulator-running guard / 部分失败汇总，ViewModel 只持 sheet 状态机不直调 SubprocessExecutor
- ✅ **WorkflowScanHit 新增 commandLineTailArg 而非新增 DTO**：默认 nil 向后兼容，simctl-devices/runtimes 路由时填 UDID/identifier，避免 ViewModel 维护"scannerID → 怎么拼 args"散点知识
- ✅ **两轮确认 sheet 而非 confirmationDialog**：sheet 可承载列表 + 完整 command preview，confirmationDialog 不行；第二轮 `role: .destructive` + 红字 irreversible 警示符合"强安全闸门"诉求
- ✅ **串行 execute 而非并发**：simctl 自身对并发 delete 健壮性未知；串行可保证"失败一条不污染下一条"+ timeout 累加可被 UI 进度文案预测
- ✅ **Simulator running guard 双重防御**：prepare 直接拒（.blockedSimulatorRunning），即使绕过也有 SubprocessExecutor allowlist 二道闸

### PR-9b：i18n 全量迁移（subagent 并行落地）

| 子任务 | 改动 | 状态 |
|---|---|---|
| sidebar / detail 文案 | [Localizable.xcstrings](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/Resources/Localizable.xcstrings) 新增 16 个 `workflow.sidebar.*` / `workflow.detail.*` key（含 footer.summary `%lld %@` / action.rescan / action.trash / alert.title / alert.ok / empty_placeholder / scanning / empty_card / delete.trash_summary / delete.error_format / delete.commandline_skipped） | ✅ |
| 调用点迁移 | WorkflowDetailView.swift 所有中文硬编码 → `String(localized:bundle:)` / `Text("key", bundle: .module)`；MainView.swift workflow sidebar 4 处 `verbatim` → `Text("workflow.sidebar.*", bundle: .module)` | ✅ |
| 验证 | swift test AppUI 全套 → 417 → 427 tests 全绿（含 PR-9a 新增 10 个） | ✅ |

**验收清单**：
- [x] WorkflowScanHit 新增字段向后兼容（既有调用点不传也能编译）
- [x] SimulatorDeleteCoordinator prepare 4 分支完整 + execute 不抛出（异常吞掉转 exitCode=-3）
- [x] Simulator running guard：NSWorkspace 检测到 `com.apple.iphonesimulator` → 永不放行
- [x] 两轮确认 sheet：第一轮 → 第二轮 → execute / cancel 任一回到 nil
- [x] dryRun=true 时 SubprocessExecutor 不真起进程，单测 / CI safe
- [x] i18n：WorkflowDetailView + MainView workflow 路径零中文硬编码
- [x] swift test AppUI 全套 427 tests 0 failures（PR-9 新增 10）
- [x] swift test ScanKit 全套 295 tests 0 failures（commandLineTailArg 字段不破回归）
- [x] GetDiagnostics 零告警

**实际改动**（≈ 700 行 diff）：
- AppUI 源码：1 个新文件（SimulatorDeleteCoordinator.swift ~180L） + WorkflowDetailView.swift（+~200L：状态机 / sheet / 测试 hook） + MainView.swift（4 处 verbatim 改）
- ScanKit 源码：WorkflowRegistry.swift（+30L：DTO 字段 + 2 处路由填值）
- AppUI 测试：1 个新文件（SimulatorDeleteCoordinatorTests.swift ~320L，含 10 case）
- Localizable.xcstrings：+27 key（16 + 11）中英双语

---

## 风险与回滚预案

| 风险 | 监控 | 回滚 |
|---|---|---|
| KVR Android SDK entry 在 ANDROID_HOME 非默认时不命中 | scanAll 返回空时不报错 | 已通过测试 |
| JetBrains groupingRegex 写错导致漏识别 | 一致性测试 + 失败回退旧行为 | 单 PR 独立 revert |
| simctl 子进程 hang | SubprocessExecutor 强制 5s timeout | recipe.isExecutable 反转开关 |
| WorkflowDetailView 在巨型 home 下 directorySize 全量遍历卡 UI | 已在 .task / Task.detached 中运行 | 切回 batch.developer 旧入口 |
| NodeModulesScanner 在用户~下扫到 10w+ 工程导致内存暴涨 | hits 上限默认无；可加 limit 参数 | 关闭 scattered 卡或加 maxHits 配置 |
| sentinel ID 与既有 sentinel 冲突 | 单测锁全局唯一 | revert sentinel 新增 |

---

## 时间表

| 时间 | 里程碑 |
|---|---|
| 2026-06-15（今天） | PR-0 完成（KVR Android + 协议骨架）✅ |
| 2026-06-15（今天） | PR-1 完成（Apple 6 静态卡）✅ |
| 2026-06-15（今天） | PR-2 完成（Simctl + SubprocessExecutor + Apple 10 卡）✅ |
| 2026-06-15（今天） | PR-3 完成（JetBrains groupingRegex 分组）✅ |
| 2026-06-15（今天） | PR-4 完成（WorkflowRegistry + 3 Scanner）✅ |
| 2026-06-15（今天） | PR-5 完成（WorkflowDetailView + AppUI 接入）✅ |
| 2026-06-15（今天） | PR-6 完成（AndroidWorkflow 10 卡 + 测试）✅ |
| 2026-06-15（今天） | PR-7 完成（WebNodeWorkflow 6 卡 + NodeModulesScanner）✅ |
| 2026-06-15（今天） | PR-8 完成（workflow-cli + JSON / 表格输出）✅ |
| 2026-06-15（今天） | PR-9 完成（simctl 真删两轮确认 + WorkflowDetail/MainView i18n 全量迁移）✅ |

---

## 索引

- [DEVELOPER_ONE_CLICK_PLAN.md](file:///Users/amuxuser/workspace/AmuxAIClean/docs/DEVELOPER_ONE_CLICK_PLAN.md)：总规划
- [CUSTOM_SCAN_PLAN.md](file:///Users/amuxuser/workspace/AmuxAIClean/docs/CUSTOM_SCAN_PLAN.md)：v1.8 用户自定义扫描
- [REVIEW_2026_06.md](file:///Users/amuxuser/workspace/AmuxAIClean/docs/REVIEW_2026_06.md)：评审总报告
