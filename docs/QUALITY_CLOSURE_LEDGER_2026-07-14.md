# 2026-07-14 质量问题闭环台账

> 目的：把 2026-07-14 用户明确提出的问题、当前真实状态、验收标准和证据统一到一份可审计台账。
> 本文不是“完成清单”。没有运行时证据的项目，即使已有代码或单测，也不得标记完成。
>
> **v2026.07.16 兼容合同**：产品部署下限统一为 macOS 13.5；工程、Info.plist、SwiftPM manifests
> 和 Release 静态合同一致只构成 C1，不能替代 Ventura 真机/VM 的 C4 运行验收。

## 1. 状态与证据定义

| 状态 | 含义 |
|---|---|
| `OPEN` | 尚未开始实现，或根因/修复路径尚未确定 |
| `PARTIAL` | 只覆盖部分入口/场景，不能作为完整交付 |
| `CODED_UNVERIFIED` | 最新复现之后已有实现；可能已有自动化证据，但没有完成修改后的真实交互验收 |
| `VERIFIED` | 自动化合同、编译、受控运行交互三类证据均通过 |
| `RULE_LANDED` | 可执行过程规则已写入仓库，但不代表对应产品功能已经验收 |
| `NEEDS_RECHECK` | 以前可能完成过，但当前工作树/最终产物尚未重新核对 |
| `DEFERRED` | 用户明确要求暂不处理 |
| `EXCLUDED` | 用户明确说明不属于本任务 |

证据等级：

1. `C1`：静态检查或源码存在。
2. `C2`：聚焦测试/集成测试通过。
3. `C3`：相关包全量测试和目标构建通过。
4. `C4`：受控运行中按明确步骤观察到预期 UI 与行为；没有 C4 不得宣称“真实交互已测试”。
5. `C5`：最终 Release DMG 上完成同一验收并核对签名、公证和版本。

## 2. 今日问题总表

### 2.1 扫描与结果页交互

| ID | 用户要求/问题 | 当前真实状态 | 完成验收标准 | 主要位置 |
|---|---|---|---|---|
| SCAN-01 | 扫描状态文字本身要有跳动/光影动画，不能只给文字背景框做动画 | `CODED_UNVERIFIED` | 文字动画可见；Reduce Motion 下自动降级；背景框不喧宾夺主；C2+C4 | `SmartCareDashboardView.swift`、`SmartCarePresentationTests.swift` |
| SCAN-02 | 状态文字前的图标必须与当前扫描阶段一致 | `CODED_UNVERIFIED` | System & Logs、App Cache、Developer Cache、Safety Check 四阶段图标逐一匹配；C2+C4 | `SmartCareDashboardView.swift` |
| SCAN-03 | 进度连接条和当前扫描状态圆圈都必须有动画 | `CODED_UNVERIFIED` | 连接条有连续进度；当前圆圈有明确活动态；已完成/未开始不误动；C2+C4 | `SmartCareDashboardView.swift`、`FloatingScanHUDLayoutTests.swift` |
| SCAN-04 | 完成页底部区域颜色和结构难看，需要统一、克制的科技风 | `CODED_UNVERIFIED` | 普通/受限/失败/完成四态视觉一致；浅色/深色均可读；C4 | `SmartCareDashboardView.swift` |
| SCAN-05 | `Scan Again` 按钮视觉粗糙 | `CODED_UNVERIFIED` | 与主操作层级一致，hover/pressed/disabled 清晰；C4 | `SmartCareDashboardView.swift` |
| SCAN-06 | 扫描过程中和结束后把 `cannotEnumerate(file:///...)` 内部错误直接画成红字 | `CODED_UNVERIFIED`；最新截图是修改前复现证据 | 子目录失败只产生结构化 incomplete；只有整轮致命失败进入 terminal failure；UI 不得出现 Swift enum dump、`file:///` 或百分号编码；C2+C3+C4 | `BulkScanner.swift`、`ScanCoordinator.swift`、`MainView.swift` |
| SCAN-07 | 同一次不可读目录同时出现权限 banner、partial 提示、红色内部错误，信息重复且冲突 | `CODED_UNVERIFIED`；已建立互斥 presentation，缺 C4 | 同一原因只由一个统一 presentation 呈现；详细路径按需展开；C2+C4 | `MainView.swift`、`ScanIssuePresentation.swift` |
| SCAN-08 | 已确认 Full Disk Access 可用，却提示去系统设置授权；POSIX/ownership 与 TCC/FDA 混为一谈 | `PARTIAL`；扫描事件已类型化，恢复动作尚未完成全入口核验 | TCC、POSIX ownership/mode、目录消失、普通枚举失败分别使用类型化原因和正确动作；无意义时不显示“打开设置”；C2+C4 | `DiscoveryEvidence.swift`、`ScanCoordinator.swift`、权限 banner |
| SCAN-09 | 扫描窗口发生 `Update Constraints in Window` 循环并崩溃 | `CODED_UNVERIFIED` | 同一真实扫描场景持续运行，无约束循环、无 NSException；C2+C4 | `FloatingScanHUD.swift`、`FloatingScanHUDLayoutTests.swift` |
| SCAN-10 | Docker 稀疏文件显示 2 TB，但磁盘仅约 400 GB；大小要与 macOS 系统显示口径一致 | `CODED_UNVERIFIED` | 顶层、展开、汇总始终使用同一会话口径；与 Finder/系统设置对目标文件的显示一致；稀疏文件覆盖；性能基准无显著回退；C2+C3+C4 | `FSNode.swift`、`BulkScanner.swift`、`TreeSizeEstimator.swift`、`SystemStorageAccountingTests.swift` |
| SCAN-11 | Smart Care 把带精确拒绝路径的部分扫描误判为 `Action failed` | `CODED_UNVERIFIED` | partial 进入受限结果页；真实 stream failure 才失败；拒绝路径不能进入删除；C2 已有，仍缺 C4 | `SmartCareSession.swift`、`SmartCareSessionTests.swift` |
| SCAN-12 | 深层受限路径被向上放大成祖先 Tree 锁：`Library` / `Containers` 被置灰且无法下钻，真实受限目录反而不可达 | `CODED_UNVERIFIED`；双轴投影、旧展开状态、删除证据与 EINTR 合同已通过 C2，全 AppUI/ScanKit 与 Debug build 已通过 C3；缺 C4 真实 UI 视觉验收 | 使用双轴合同：`accessState` 只锁定 exact issue 或真正位于锁定上级内的行；strict ancestor 必须 `accessState == .normal`、保持可展开，并用独立 `subtreeCompleteness == .containsIncompleteDescendant` 显示 partial/内部受限；sibling 完全正常；祖先的删除完整性仍为 incomplete，不得从视觉锁推导授权；AppKit/SwiftUI 两条 Tree 渲染和 issue 先到/后到时序均覆盖；C2+C3+C4 | `ScanCoordinator.swift`、`TreeBrowserView.swift`、`ScanCoordinatorCompletenessProjectionTests.swift`、`ScanCoordinatorFullDiskTests.swift`、`FlatRowsIncrementalPatchTests.swift` |

### 2.2 删除交互与专业模式

| ID | 用户要求/问题 | 当前真实状态 | 完成验收标准 | 主要位置 |
|---|---|---|---|---|
| DEL-01 | 所有删除入口必须使用统一确认弹窗，不能有的确认、有的直接执行、有的被拦后才弹结果 | `OPEN/PARTIAL` | 单行按钮、右键、Delete 键、批量、Tree、List、Large Files、Workflow、Brew、Duplicate、Uninstall、Stash、Smart Care 全部先进入同一预检/确认状态机；C2+C4 | `DeletionUXModels.swift`、`DeleteSheet.swift`、`ToolTrashConfirmationSheet.swift`、各入口 View |
| DEL-02 | Release 模式不显示 dry-run/仅预览开关和干扰文案 | `CODED_UNVERIFIED` | Release 确认框只显示“移到废纸篓”；Debug 可保留诊断能力；最终 DMG C5 | `DeletionPreviewPolicy`、`DeleteSheet.swift` |
| DEL-03 | 专业模式下 `forbid` 不能一律锁死；应提供更严格的强制删除 | `PARTIAL`；类型化分级模型与 C2 已有，但 UI/执行仍保留空心 force 和旧分支 | 先将拒绝分成 hard-forbid、policy override、scan-incomplete、OS permission 四类；仅允许可覆盖类进入高风险确认；执行前重新预检；C2+C4 | `OperationResultSheet.swift`、`TrashActionCoordinator.swift`、`SafetyEngine.swift`、`TrashPipeline.swift` |
| DEL-04 | Android SDK `system-images` 子路径被拦截后，没有可用的专业严格删除流程 | `OPEN`，最新图 4 复现 | 若仅 vendor/toolchain policy 拦截，预检直接进入严格确认，不先伪造 `Cleanup Failed`；若只是扫描不完整，先做路径级重新验证，不得伪装成 FDA；C2+C4 | 删除 confirmation coordinator、`TrashActionCoordinator.swift`、`TrashPipeline.swift` |
| DEL-05 | “No permission to delete (grant Full Disk Access)” 与现场 FDA 可用矛盾 | `OPEN` | 结果项展示真实 typed reason；POSIX/ownership 不提供 FDA 动作；scan incomplete 不直接等于 OS 无删除权限；C2+C4 | `OperationResultSheet.swift`、`KeychainUserFacingError.swift` 同类映射模式 |
| DEL-06 | 相关应用仍运行时不能直接中断整个操作；应让用户选择跳过运行项、退出后继续或明确尝试 | `PARTIAL/CODED_UNVERIFIED` | 所有入口共用 RunningAppGuard；选项语义一致；部分跳过后其余项目继续；结果页展示跳过原因；C2+C4 | `RunningAppGuard.swift`、`RunningAppNoticeFormatter.swift`、统一确认状态机 |
| DEL-07 | 专业模式不同删除图标的确认行为不一致 | `OPEN/PARTIAL` | 同一动作无论从行按钮、context menu、Delete 键发起，进入完全相同的 frozen request；C2+C4 | `TreeBrowserView.swift`、`RowView.swift`、各工具页 |
| DEL-08 | 删除失败结果只能 Done，缺少与失败原因关联的恢复操作 | `OPEN/PARTIAL` | 预检 policy override 不进入结果页；真实结果按 running→重新选择、OS permission→正确设置或 Finder 定位、scan changed→重新预检、IO failure→重试/技术详情生成动作；C2+C4 | `OperationResultSheet.swift` |

### 2.3 专业模式、设置和窗口

| ID | 用户要求/问题 | 当前真实状态 | 完成验收标准 | 主要位置 |
|---|---|---|---|---|
| PRO-01 | 专业模式左边栏默认被挤压 | `CODED_UNVERIFIED` | 默认窗口尺寸和最小尺寸下，侧栏标签与内容不被异常压缩；C4 | `MainView.swift`、split view sizing |
| PRO-02 | Add Path 点击卡住或无响应 | `CODED_UNVERIFIED` | 点击后立即出现 panel；主线程无同步扫描/Keychain/文件遍历；取消和选择都可恢复；C2+C4 | `UserPathStore.swift`、Custom Paths UI |
| PRO-03 | 设置里的 AI / Advanced 项读不到或显示异常 | `CODED_UNVERIFIED` | 可读、可点击、disabled 原因明确；浅色/深色可用；C4 | `SettingsNavigation.swift`、`SettingsScene.swift` |
| PRO-04 | Keychain 报 `unhandled(100002)`，API Key 读不到 | `CODED_UNVERIFIED` | 旧 service/account 命名可迁移；真实 Keychain 错误映射为可操作文案；C2+C4 | `KeychainAPIKeyStore.swift`、`KeychainFailurePresentationTests.swift` |
| PRO-05 | 菜单“打开主窗口”错误跳到设置页 | `CODED_UNVERIFIED` | 主窗口不存在/已存在/设置窗口在前台三种场景均聚焦主窗口；C2+C4 | `MainWindowRoutingPolicy.swift`、`GSYCleanMacApp.swift` |
| PRO-06 | App 左上角品牌和版本号不应有背景胶囊 | `CODED_UNVERIFIED` | 标题与版本直接排版，无背景框；窗口宽度变化不重现；C4 | `MainView.swift`、`AppVersionPresentationTests.swift` |
| PRO-07 | Normal AI Review 完成后，成功或失败都应弹结果并展示内容和后续动作 | `CODED_UNVERIFIED` | success/failed/partial/empty/cancelled/stale 全部有确定 presentation；操作与对应报告 revision 绑定；C2 已有，缺 C4 | `SmartCareAIReviewResultSheet.swift`、`SmartCarePresentationTests.swift` |

### 2.4 发版边界

| ID | 用户要求/问题 | 当前真实状态 | 完成验收标准 | 主要位置 |
|---|---|---|---|---|
| REL-01 | App 内显示现实版本号 | `CODED_UNVERIFIED` | UI、Info.plist、构建设置、DMG 内 App 四处一致；C5 | `AppVersionPresentationTests.swift`、最终 bundle |
| REL-02 | 打本地 Release DMG 并公证，公证目标是最终 DMG | `NEEDS_RECHECK` | Developer ID 签名；只提交最终 DMG 公证；Accepted、staple、spctl、codesign 全部通过；C5 | `Scripts/build_release.sh`、`Scripts/test_release_contract.sh` |
| REL-03 | 不上传 GitHub Release；不能把“打 release”擅自扩成 GitHub 发布 | `RULE_LANDED` | 未获明确授权不得调用 GitHub 发布/上传；本地构建与 GitHub 发布分开描述 | `AGENTS.md` 发版与外部写入规则 |

### 2.5 工作方式与质量要求

| ID | 用户要求/问题 | 当前真实状态 | 完成验收标准 |
|---|---|---|---|
| QA-01 | 测试不能只是频繁打开后马上关闭，必须实际观察目标状态 | `RULE_LANDED` | 每次运行测试写明场景、观察点、停留条件和证据；不需要 UI 时只跑无窗口测试 |
| QA-02 | 不能把单测/编译通过说成真实 UI 已测试 | `RULE_LANDED` | 交付报告强制标 C1–C5；没有 C4 明说“未做运行交互验收” |
| QA-03 | 全 App review，安全小心修复，不能因修一个入口破坏其它入口 | `OPEN` | 使用问题矩阵与入口矩阵；相关包全测；扫描/删除/UI 主链路受控回归 |
| QA-04 | 不能局部硬编码、不能为过测试改需求、不能用兜底掩盖核心问题 | `RULE_LANDED`；历史执行失败 | 每个修复说明共享根因、影响面和防复发测试 |

## 3. 明确排除与暂缓

> 本节保留 2026-07-14 当时的范围决策。Update/AI 网络与隐私合同已在 2026-07-18 获得实现
> 授权；当前状态以第 9.9 节为准，下面的 `DEFERRED` 不得继续解释为现状。

- `EXCLUDED`：Dock 中同时出现两个 App 图标的问题。用户已说明属于隔壁会话，不计入本任务。
- `DEFERRED`：自动更新访问 GitHub 的 P1。
- `DEFERRED`：远程 AI 访问 GitHub 的 P1。
- `DEFERRED RULE CONFLICT`：现行 `AGENTS.md` 的“零网络 hard rule”与已有远程 AI/自动更新方向存在架构冲突。用户已明确这两个 P1 暂不处理，因此本次不擅自放宽安全规则；后续必须先单独决定允许的域名、用户授权、超时/取消、隐私和审计边界，再修改规则与实现。
- 未经明确授权，不上传 GitHub Release，不创建远程发布。
- 自动化测试不得在 `$HOME` 下执行真实删除；真实回收测试只能使用临时目录。

## 4. 最新四张图的统一根因

以下是修改前最新复现的因果链，用来固定根因而不是描述所有代码仍停留在原状：

1. `BulkScanner` 对 descendant 目录枚举失败同时发送结构化 `.incomplete(issue)` 和 `.failed(ScanError.cannotEnumerate(URL))`。
2. `ScanCoordinator` 把所有 `.failed` 当整轮 terminal failure，并用 `"\(error)"` 生成内部字符串。
3. `MainView` 又直接 `Text(lastError)`，因此把 Swift enum dump、`file:///` 和 percent encoding 泄漏给用户。
4. 同时，页面还根据 incomplete paths 画权限 banner、根据 `snapshot.isComplete` 画 partial 提示，最终同一原因被呈现三次。
5. 删除预检又把 `incompleteScanPaths` 与真正的 permission denied 合并成一个 `accessDeniedPaths` 集合，结果页把“扫描不完整”误称为“没有删除权限/FDA”，并阻断专业模式 override。
6. `OperationResultSheet` 的 `onForceDelete` 参数当前只为源码兼容而保留，初始化时直接 `_ = onForceDelete`；footer 只展示 vendor-only override。
7. `TrashActionCoordinator.Request.Mode.force` 和 `TrashPipeline.moveToTrashForce` 当前都回落普通删除路径，因此“强制删除”在现工作树中是空心 API，不是可用能力。
8. 当前预检失败会直接构造 `OperationResultSheet` 并显示 `Cleanup Failed 0/1`，但实际上没有执行过清理；这是把 preflight denial 错当 execution result。

这八点必须分别在事件合同、presentation model 和删除预检证据类型上修复；隐藏红字、改文案或加一个按钮都不算根因修复。

本次核对时，1–4 已有修改和自动化证据但缺 C4；5 只完成扫描证据分型，删除入口尚未全部消费；6–8 尚未闭环，因此 Android SDK 严格删除和统一确认仍不得标记完成。

## 5. 删除入口矩阵（完成前必须逐项打勾）

| 入口 | 统一预检 | 统一确认 | Running App 选择 | 专业 override | 统一结果 | C4 |
|---|---:|---:|---:|---:|---:|---:|
| 主列表行删除图标 | Main 自有 | `DeleteSheet` | 部分 | vendor-only | `OperationResultSheet` | ☐ |
| 主列表右键菜单 | Main 自有 | `DeleteSheet` | 部分 | vendor-only | `OperationResultSheet` | ☐ |
| 主列表 Delete 键 | Main 自有 | `DeleteSheet`；部分拒绝只蜂鸣 | 部分 | vendor-only | `OperationResultSheet` | ☐ |
| Tree 单行/批量 | Main 自有 | `DeleteSheet`；部分入口禁用 | 部分 | vendor-only | `OperationResultSheet` | ☐ |
| Large Files | Main 自有 | `DeleteSheet` | 部分 | vendor-only | `OperationResultSheet` | ☐ |
| Workflow / Developer Scan | 工具自有 | 文件走 `ToolTrashConfirmationSheet`；command 自定义 | 有独立实现 | vendor-only | 工具自有 | ☐ |
| Brew | 工具自有 | `ToolTrashConfirmationSheet` | 工具自有 | vendor-only | 工具自有 | ☐ |
| Duplicate | 工具自有 | `ToolTrashConfirmationSheet` | 工具自有 | vendor-only | 工具自有 | ☐ |
| Uninstall | 工具自有 | `ToolTrashConfirmationSheet` | 工具自有 | vendor-only | 工具自有 | ☐ |
| Stash | Main 自有 | `DeleteSheet` | 部分 | vendor-only | `OperationResultSheet` | ☐ |
| Smart Care | Main 自有 | 独立 `DeleteSheet` presenter | 部分 | vendor-only | `OperationResultSheet` | ☐ |

## 6. 规则缺口审计

### 6.1 已有但执行没有闭环

- 已有：所有删除必须进入 `TrashPipeline`。
  - 缺口：只统一了最终管线，没有统一“预检→确认→运行项处理→执行→结果”的 UI 状态机。
- 已有：`SafetyEngine` 三色判定、hardForbid、安全拒绝证据。
  - 缺口：没有正式定义专业模式哪些拒绝可 override，导致一处 vendor-only、一处全部锁死。
- 已有：权限拒绝路径与真实错误要分 channel（`PITFALLS.md` 已记录）。
  - 缺口：没有可执行规则禁止 `Text(lastError)` 和 `"\(error)"` 直出 UI。
- 旧有：扫描/删除/UI 主链路修改后跑快速启停 regression。
  - v2026.07.16 处理：该入口、内置 Runner 与生成日志已删除。逻辑断言归入 package tests；
    真实交互必须是用户授权的一次持续 C4，不能再把“启动后马上关闭”计作证据。
- 已有：`docs/RELEASE.md` 已定义 Developer ID + 最终 DMG-only 公证。
  - 缺口：`SECURITY.md` 仍残留 ad-hoc、未公证、默认 GitHub Releases 的历史事实，和当前流程冲突。
- 已有：顶层规则宣称零网络。
  - 缺口：源码已有可选远程 AI/自动更新方向；用户已要求 P1 暂缓，当前只能冻结扩张并记录决策缺口，不能假装冲突不存在。
  - 历史状态说明：该冲突已由第 9.9 节的固定 Updater origin、用户配置 AI origin、隐私披露与
    网络扩张门禁取代；本条只保留最初审计背景。

### 6.2 必须新增的可执行规则

1. **统一破坏性操作状态机**
   - 所有删除入口只能提交 typed intent，不得直接调用 `TrashPipeline`。
   - intent 必须进入同一个 coordinator，完成 frozen request、预检、确认、运行项选择、最终重验和结果展示。
   - 防复发测试：`DeletionUXPolicyTests` + `ProfessionalToolDeletionFlowTests` 增加全入口 source-contract 与行为测试。
2. **错误不得原样渲染**
   - 用户可见层禁止 `Text(error.localizedDescription)`、`Text("\(error)")`、`Text(lastError)`；必须使用 typed presentation 和 xcstrings。
   - 防复发测试：新增 `UserFacingErrorPresentationTests`，扫描源码并覆盖 URL/error 格式化。
3. **扫描完整性证据与 OS 删除权限分型**
   - `incomplete`、TCC、POSIX ownership/mode、路径消失、fatal stream error 不得共用一个字符串或一个布尔集合。
   - 防复发测试：`ScanCompletenessContractTests`、`MultiRootCompletionPolicyTests`、删除预检集成测试。
4. **专业模式 override 分级**
   - `hardForbid` 永不覆盖。
   - vendor/toolchain policy 与经过路径级重新验证的 scan-incomplete 可进入严格 override。
   - 真实 OS permission denial 不能用假按钮承诺“强制成功”；应显示准确原因和可行动作。
   - 防复发测试：`TrashPipelineDryRunTests`、`ProfessionalToolDeletionFlowTests`。
   - 禁止保留名称为 `force`、实际与 normal 完全相同的空心 API；能力不存在就不得显示/声明存在，能力存在就必须由类型化授权表达。
5. **验证声明分级**
   - 最终报告必须标注 C1–C5；C2/C3 不得表述成 C4/C5。
   - UI 回归脚本必须记录场景、观察点、停留条件和截图/日志证据。
6. **外部发布授权边界**
   - “打 Release/DMG”不等于“上传 GitHub Release”。任何远程发布必须获得单独明确授权。
7. **系统容量口径是会话合同**
   - 用户可见大小默认与 macOS/Finder 的对应口径一致；稀疏文件、hard link、clone 等不能只靠逻辑长度推算。
   - 顶层结果、按需展开、排序、汇总必须冻结并复用同一扫描会话的 accounting mode；变更实现必须跑稀疏文件测试和性能基准。
8. **异步用户流程必须有完整终态**
   - 扫描、AI Review、Add Path、Keychain 读取等一旦向用户显示已开始，必须收敛到 success / partial / failure / cancelled / stale 之一，并提供与 typed reason 对应的下一步。
   - 结果与发起时的 revision 绑定；旧任务不得覆盖新页面或静默消失。
9. **窗口与 modal 路由必须类型化**
   - “打开主窗口”“打开设置”和各 sheet/alert 使用独立 typed route；不得依赖当前 key window 猜测目标，也不得让 sibling sheet 竞争。
   - 防复发测试：`MainWindowRoutingPolicyTests`、`PresentationCoordinationTests`，并在 C4 覆盖设置窗口已打开的场景。

### 6.3 本次已落地的规则补全

- [AGENTS.md](file:///Users/guoshuyu/workspace/GSYCleanMac/AGENTS.md)：仅保留全仓库入口与最高风险边界，包括类型化用户错误、C1–C5 验证口径、统一删除授权、异步终态、禁止擅自 GitHub 发布和 Release 不显示 dry-run；容量会话口径、typed 窗口路由等细则继续由本台账、专项合同、PITFALLS 和测试负责。
- [SECURITY.md](file:///Users/guoshuyu/workspace/GSYCleanMac/SECURITY.md)：消除“所有 forbid 一律拒绝”与专业模式需求的冲突；明确普通 forbid、可覆盖 policy forbid 和永不可覆盖 hard/结构边界；同步 Developer ID + 最终 DMG 公证事实，并把未决网络边界显式标出。
- [PITFALLS.md](file:///Users/guoshuyu/workspace/GSYCleanMac/PITFALLS.md)：新增“统一 TrashPipeline 不等于统一删除交互”和“局部扫描不完整污染整个根”两条事故记录。
- [DELETION_UX_CONTRACT.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/DELETION_UX_CONTRACT.md)：定义唯一删除状态机、类型化授权、严格尝试边界、统一确认页和入口测试矩阵。

## 7. 闭环顺序

1. 修正 ScanKit 事件合同，消除 descendant `cannotEnumerate` 的假 fatal。
2. 建立单一扫描问题 presentation，去掉 raw lastError 和重复 banner。
3. 将扫描完整性证据从删除权限证据中类型化拆分。
4. 把所有删除入口收敛到统一确认 coordinator。
5. 实现专业模式 override 分级和结果页恢复动作。
6. 处理剩余专业模式、设置、窗口和视觉问题。
7. 跑 C2/C3；经用户同意后做一次持续、可观察的 C4，不频繁开关 App。
8. C4 全部通过后再进入本地 Release DMG 与 C5；不得擅自上传 GitHub。

## 8. 本次文档核对时的证据快照

- 文档/规则：`git diff --check` 通过；旧规则中“Release 必须显示 dry-run 切换”的冲突已移除。
- 语法：`MainView.swift`、扫描问题 presentation、删除 UX 模型和对应测试通过 `swiftc -parse`。
- ScanKit：全量 357 tests 通过、0 failure，2 个默认跳过的性能测试未计为通过证据。
- AppUI 聚焦：`ScanIssuePresentationTests`、`DeletionUXPolicyTests`、`ProfessionalToolDeletionFlowTests`、`MultiRootCompletionPolicyTests` 共 46 tests 通过、0 failure。
- ScanCoordinator 完整性投影：5 个聚焦测试通过、0 failure；更大组合测试的最终摘要未确认，因此不计入证据。
- 本轮没有启动 App、没有执行真实删除、没有打包、没有提交或推送；所以没有 C4/C5，也不宣称相关 UI 已完成。

## 9. v2026.07.16 根因修复与当前证据

> 本节记录 2026-07-16 的新实现与重新核验结果；对本节覆盖的容量、本地化、Workflow、
> Simulator、Trash、Port 和 Sentinel 问题，以这里的状态为准。前面第 2–8 节保留为事故基线，
> 不应再把其中修改前的源码描述当成当前实现。

### 9.1 “重启后释放 100 多 GB、开机后又回来”的证据结论

- 现场 APFS 权威值显示该占用是真实卷占用，不只是 Storage 分类动画：主 container 已用
  `425,771,298,816 B`、可用 `68,613,496,832 B`，Data volume 约 `402.7 GB`；VM volume
  只有约 `24.6 KB`，因此不是 2–3 GB 的 swap/sleep image 解释了 100 多 GB。
- Simulator 也不是这次 100 多 GB 回涨的主体：用户 CoreSimulator 目录约 `3.2 GB`，系统
  iOS Simulator Runtime assets 约 `31 GB`，两者量级都不等于本次回涨。
- 本次开机时间为 13:35。统一日志在 13:37 记录 `templateMigrator` 把 Previous System 下的
  `com_apple_MobileAsset_UAF_FM_GenerativeModels` 迁入当前 `AssetsV2`，随后
  `mobileassetd` 恢复 5,733 个 asset locks。15:32 的 cache-delete 记录中有 67 个唯一
  GenerativeModels asset 标记为 locked / never remove；按日志的 binary byte 字段合计约
  `135.499 GB`（`126.194 GiB`）。
- 因此当前最高置信解释是：已有或从 Previous System 迁移的 Apple Intelligence/Foundation
  Model 资产在开机后被重新登记、校验并锁定，从“可回收/暂未计入普通可用”的状态变为活跃的
  非可回收占用。这能解释“重启后短暂空出、稍后又被占用”的时间和量级。
- Apple 当前官方设备要求写的是 Apple Intelligence 约需 `7 GB` 存储，因此日志里的
  `135.499 GB` 不是单套正常模型的合理稳态量级；更符合多版本/迁移遗留 asset 被同时锁定的
  异常系统托管积累。这里的“异常”指资产保留状态与量级异常，不代表 APFS 占用是假的。
- 证据边界：没有与事故同步保存重启前后两份 APFS block snapshot，日志也不能证明这
  `135.499 GB` 全部在 13:37 后新写入。因此不能声称每一个字节都是当时下载的；准确说法是
  “现有/迁移模型资产在开机后重新激活并变得不可回收”，不是“虚构的 100 GB”，也不是已证明
  的单目录新下载。
- 当前 Foundation 容量 API 的普通可用约 `68.60 GB`、important-usage 可用约
  `76.12 GB`，差值约 `7.52 GB`。这说明此刻 macOS 对公开 API 暴露的可回收估算已经不是
  100 多 GB；App 不得用历史 `mobileassetd.cache-delete` 活动标签冒充当前可安全删除目录。
- 安全处置只走系统所有者：关闭“系统设置 → Apple Intelligence 与 Siri”可请求系统移除
  on-device models；不能手工删除 `/System/Library/AssetsV2`。Xcode → Settings → Components
  只管理 Simulator runtime，与这批 Foundation Models 是两件事。

### 9.2 本轮共享根因修复

- **容量口径**：侧栏把 ordinary physical free、macOS may release（important minus ordinary）
  和 estimated upper bound 三个值拆开；柱状图/current free 不再重复加 reclaimable。tooltip
  明确这是系统估算、不是单一目录、没有安全的 Clear All，并随 App locale 即时重投影。
- **实时本地化**：菜单、设置、工具卡、结果页、tooltip/popover、日期与容量格式统一消费显式
  App locale；长期存活的 Professional/Smart Care coordinator 由 App 级 fanout 更新，切换语言
  不再依赖重启。raw Error、URL、errno 和 CLI stdout/stderr 只进结构化日志/技术 outcome。
- **Workflow/DerivedData**：共享扫描按真实 plist/project metadata 投影，修复 `.noindex` 假项目、
  父子重复选择、hard-link 重复计数、空 Archives/Device Support 和一张卡刷新拖动全页 loading。
  全页与单卡任务均绑定 session/revision、可取消且旧结果不能覆盖新页面。
- **Simulator 托管卸载**：唯一非 Trash 例外封闭为 Simulator Device/Runtime；文件项仍只走
  `TrashPipeline → NSWorkspace.recycle`。单一 sheet 显示 preparing、逐项验证、已提交、运行、
  stalled、终态与未提交项；停止只阻止后续提交，不强杀 CoreSimulator。持久账本以跨进程锁、
  owner kernel identity、scan/review identity 和 attempt CAS 阻止 PID reuse、同一陈旧复核、重启、
  迟到终态与 replacement attempt ABA；schema 4 严格拒绝畸形 owner 并保守迁移旧记录。
- **Trash**：每批冻结 parent operation、每次 AppKit 调用冻结 attempt、每条路径冻结 inode/type，
  并以稳定 lock inode 的 `flock` 串行化跨 App 实例。claimed unknown 即使 owner 退出、路径缺失或
  被替换也保持 pending；只有未 claim 的 inactive reservation 可要求 fresh review，旧 callback
  不能清除或授权新实体。
- **Port Cleaner**：两轮 `lsof` 只接受稳定监听项；确认冻结 PID、UID、executable 和 kernel
  start time，SIGTERM 前在同一同步执行栈重验。命令输出有界且截断即拒绝；reload 绑定 revision，
  失败保留旧可信结果并给 typed retry，不把不完整结果显示成“没有端口”。
- **ScanKit 子进程与取消**：查询、维护命令和 pkgutil 统一使用 `posix_spawn` + 唯一 `waitpid`
  owner；已 reap/ECHILD 后不再 signal，双 Pipe 从启动起有界排空，pkgutil 只解析完整 stdout。
  版本根发现把取消检查下沉到逐子项 I/O 边界，取消后整轮候选清空且不伪装完整结果。
- **Sentinel**：开关、系统回调、失败 rollback 和 modal 期间的合并通知统一进入 MainActor typed
  transaction，避免重复 register/unregister/reconcile；程序写回不再被误当第二次用户手势。

### 9.3 已运行验证与等级

- 聚焦行为测试（C2）：Trash ledger `22/22`；Simulator coordinator/ledger `27/27`；
  Workflow `51/51`（其中 managed ViewModel `3/3` 另行复跑）；Port parser/scanner/reload `27/27`；
  Sentinel `22/22`；VersionedRoot discovery evidence `8/8`。所有 destructive 模拟均为 dry-run/scripted closure。
- 全包与构建（C3）：9 个 Swift package 全部 `swift test --parallel` exit 0；其中 ScanKit
  `411` tests、AppUI `995` XCTest + `11` Swift Testing。原生 Debug `xcodebuild` 明确输出
  `** BUILD SUCCEEDED **`。
- 验证噪声如实记录：SafetyKit 性能阈值在一次与其它包并行的早期运行中为 `1.744s`、超过
  `1.0s` 而失败；同项隔离复跑为 `0.695s`，随后 SafetyKit 全包 `167/167` 再次通过。
  未放宽阈值、未改测试，也不把首次失败藏掉。
- 快速启停结果已撤销：本轮曾运行的结果不计入证据。`Scripts/regression.sh`、
  `Scripts/e2e-smoke.sh`、`App/RegressionRunner.swift`、`Tests/Regression`、`GSY_AUTOSCAN` 及正式 App
  对 `TestHarness` 的链接已删除，防止以后继续把窗口/进程存在或进程内断言误报成 UI 验收。
- 只读性能基准：`~/Library/Caches` 扫描 `383,375` files / `17.35 GB`，完成时间 `6.47s`；
  `du -sh` 对照约 `16 GB`。权限拒绝作为 scoped incomplete 报告，基准没有把不可读目录伪装为
  完整结果。
- 静态审计：`git diff --check` 与 String Catalog JSON 校验通过；project 仅按用户明确要求移除
  RegressionRunner/TestHarness App 链接，Release 脚本仅删除用户明确要求退役的 `e2e-smoke.sh`；
  package/plist/entitlements/rules/CI 未修改，生产扫描候选无 `unlink/removeItem` 绕行。
- 证据等级仍为 **C3**。没有进行人工持续点击和视觉核对，因此没有 C4；没有签名、公证、
  staple 的最终 DMG，因此也没有 C5。

### 9.4 尚未关闭与授权边界

> 本节是 2026-07-16 的历史缺口快照。pkg receipt 与 Privacy Manifest 的当前状态由第 9.9 节
> 覆盖；保留原文是为了说明问题来源，不得把“当时尚无清单/尚未授权”当成当前结论。

- **P2 pkg receipt 完整性**：单个 `pkgutil --pkg-info/--files` 失败目前会 fail closed、漏掉该
  receipt 的卸载候选，但 `receipts(...)` 的旧数组接口没有把 scoped incomplete 证据带到卸载页。
  它不会扩大删除范围或解析截断输出；要正确展示需把 ScanKit 返回值和 AppUninstaller 状态合同
  一起类型化，不能用空候选旁边补一条通用警告来伪装修复。
- **P1 隐私清单**：仓库尚无 `PrivacyInfo.xcprivacy`，而容量 API 等 Required Reason API 需要
  清单审计。新增 manifest 与把它加入 Xcode resources 会修改受保护工程配置，当前未获这项
  单独授权，不能擅自落地。
- **保守 pending 的可用性代价**：Trash 已 claim 未知、Simulator 已 submitted 未知在 App
  崩溃后可能长期保留 tombstone。这是为了阻止重复破坏性提交；完全自动恢复需要进程外 helper
  或系统提供原子“查询事务 + 提交”能力，当前没有安全依据把未知猜成失败。
- **C4/C5**：仍缺一次按入口矩阵执行的人工持续 UI 验收，也缺最终发行产物验证。修复完成不等于
  用户交互已亲眼验收，更不等于可直接发布。

### 9.5 v2026.07.17 前一快照的扫描性能证据

- **共享根因与修复边界**：本轮不是只优化“大文件”或“推荐扫描”单页，而是沿生产扫描链路核对
  main、recommended、full、custom、Tree 按需展开、duplicate、Workflow、App Footprint、
  Uninstaller、orphan 以及页面/模式切换生命周期。核心回归是扫描线程把海量逐节点事件无界排队到
  MainActor，导致磁盘遍历已结束后 UI 仍需数分钟消费事件；当前由扫描侧按业务需求生成有界投影，
  终态摘要保持权威，页面切换会取消离开页面的生产者并阻止旧 revision 回写。Tree、同步快照和专用
  扫描也统一了取消、partial 与终态合同，避免用额外主线程工作掩盖吞吐问题。
- **安全合同未改变**：此次只收敛扫描事件量、后台执行和异步生命周期，没有扩大候选范围、放宽
  incomplete/partial 判定或更改删除语义；文件删除仍只能进入
  `TrashPipeline → NSWorkspace.recycle`，既有 SafetyEngine 与执行前重验继续生效。
- **当时的全包与构建（历史 C3）**：AppUI 全量通过 `1,036` 个 XCTest 和 `11` 个 Swift Testing；其余八个
  Swift package 合计 `731` 个测试通过。原生 Debug `xcodebuild` 成功，目标部署下限为
  macOS `13.5`。这些证据覆盖共享扫描引擎、协调器投影、Tree、专业工具快照和生命周期合同，
  但不等同于真实 UI 操作验收。
- **协调器只读基准**：`~/Library/Caches` 完成 `385,054` files、`17,791,373,312 B`、
  `248` 个投影行，耗时 `6.944s`；`$HOME` 大文件链路完成 `3,331,139` files、
  `313,285,234,688 B`、`404` 个候选，耗时 `24.406s`。两项均通过生产协调器路径执行只读扫描，
  没有移动、删除或修改用户文件。
- **证据时效边界**：上述结果证明的是当时代码快照，不能继承到 9.6 记录的后续修改。验证期间
  没有启动 App，因此该快照也从未达到 C4。当前工作树必须重新通过 C2/C3 后，再以一次持续运行
  核对可见进度、取消、页面切换、partial 展示、终态收敛与交互流畅度；该矩阵通过前不宣称真实
  UI 性能已完成人工验收。

### 9.6 v2026.07.17 实现优先落地：当前仅 C1

> 用户明确要求“先把问题都安全落地后再测试”。因此本节只记录当前源码/文档静态审阅，
> **没有运行新增测试、九包全测、build、benchmark 或 App**；当前证据等级为 C1，不能沿用
> 9.5 的历史 C3 数字。

- **目录 TOCTOU / no-follow**：`BulkScanner` 的并发队列不再只保存 pathname，而是冻结每个
  root/后代目录的 `(device, inode)`。默认以 `O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC` 打开并
  `fstat` 核对；显式 follow-symlink 分支也冻结 link 与 target identity。排队期间被替换只形成
  scoped incomplete，不进入替换树。NodeModules 固定 HOME roots 在 depth zero 同样不跟随
  symlink；外部卷必须由用户明确走 Custom Path。
- **有序、权威进度**：统计 merge 与绝对 progress publish 位于同一 actor turn，避免并发 worker
  恢复顺序导致进度倒退；所有 progress-capable delivery 在真实或 synthetic partial `finished`
  前发布与 summary 一致的终态 bytes/files。AppUI 非终态帧只推进单调下界，只有 terminal
  summary 可权威替换。进度不能推导 complete/success。
- **Workflow/DerivedData 长任务**：文件系统卡使用 `.summaryWithProgress`，保持 summary-only
  分配/完整性语义且不恢复 node/cache DTO；card/request、session、revision、retry generation
  共同拥有任务。DerivedData 在同一 allocation traversal 中发布有界进度；单卡 loading 不再
  借用整页/其它卡状态。
- **Uninstaller 生命周期与时长**：app list、candidate discovery、Trash execution 分属不同
  revision；执行 sheet 消费类型化 batch/diagnostic/disposition。`FSSnapshot` 对 NaN、负数和零
  立即到期，对 `+infinity` 保持明确的无实际 deadline，避免 NaN 使限时遍历意外无界。
- **Duplicate 最终证明与真实提交边界**：持久 reserve 后在后台完整 rehash targets 与 retained
  reference，并在每个 batch/fallback 的 durable claim 前后做 identity fence。rehash、队列等待、
  claim 都仍是 pre-submit；`.submittingToTrash` 只在 fence/claim 完成后、紧邻第一次真实
  `NSWorkspace.recycle` 调用的串行 worker 边界同步记录。边界前页面离开可请求取消，边界后
  transaction owner 必须保留到 typed recycle 终态；UI phase 不是授权或成功证据。
- **动态本地化根因**：长期存活的 Row/Tree、Smart Care、Stash、删除/结果和 Workflow 投影携带
  `LocalizedTextDescriptor`，在消费时按当前显式 locale 生成文案；path、ID、verdict、rejection、
  completeness 和 authorization 永远不读取展示字符串，切语言不得触发重扫或改变候选身份。
  现有 `Resources/Rules/vendors.yaml` common-app-cache 原文缺英文仍是受保护规则数据迁移，未获
  规则库授权前不得用 AppUI 硬编码映射冒充修复。
- **错误呈现边界**：根扫描 `.failed` 的 errno、原始路径与 `Error` 描述只进入结构化日志；长期
  `terminalFailure/lastError` 只保存按当前 locale 解析的 catalog 文案。descendant failure 仍只进入
  typed incomplete，不能因为清理 raw Error 而扩大成整轮失败。
- **Ventura 兼容边界**：9 个 Packages、3 个 Tools、Xcode Debug/Release 与 Info.plist 的静态部署
  合同均为 macOS 13.5。`onChange`、Settings、App 激活、symbol/focus effects 与 macOS 26 toolbar
  已集中做 availability；本轮另发现并收口 Smart Care 的 8 处 `Animation.smooth` 和 1 处
  `Animation.snappy`，Ventura 使用等价基础动画，14+ 保留增强曲线。无参数 `numericText()` 经 SDK
  interface 核对从 macOS 13.0 可用，没有为了“看起来保险”添加无依据降级。
- **长任务终态**：Workflow、Uninstaller 和 Duplicate 都以 typed terminal summary/disposition
  决定结果，进度只作有界 side channel；新 revision 先失效旧 owner，迟到事件不能关闭新 spinner
  或覆盖新行。

**尚缺项**：生产扫描入口、跨模块并发/状态机、测试源码、Ventura availability、String Catalog
结构与文档已完成静态收口；当前仍只是 C1。下一阶段统一跑新增聚焦测试（C2）、九包全测 +
Debug build + 双性能基准（C3），最后只启动一次 App 完成持续
C4（Large Files、推荐扫描、Workflow、Uninstaller、Duplicate、切语言、取消/页面离开与 partial
终态）。macOS 13.5 真机/VM、Instruments/Memory Graph 和最终 DMG C5 仍分别缺失。

### 9.7 Common App Cache C4 失败与硬终止修复（v2026.07.17，当前 C1）

- **真实失败证据**：第一次持续 Debug App 验收中，System & Logs 在 0.536s 进入页面终态；
  Common App Cache 声明 12s deadline，却约 368.47s 后才返回 partial（3 rows、80 incomplete）。
  sample/LLDB 只证明同步 `open` 位于 WPS 容器 `.kingsoft` 路径，不能把“WPS 正在运行”当成
  原因，也不能据此跳过运行中 App。整体 C4 判定失败，后续场景没有冒充通过。
- **顺序根因**：本轮新增的跨 verdict 共享 forest 让宽泛 `confirm` 父目录成为 owner，抢在
  具体 `safe` 子目录之前访问。现在 forest sharing 只发生在同 verdict，group 严格
  `safe → confirm → forbid`；跨 verdict 的重叠允许为风险顺序重复读取，但 unique physical
  totals 仍按 inode 去重，UI 不得把 inclusive rows 相加。
- **硬终止边界**：shipped App 显式使用同一签名可执行文件的 private worker mode，在
  SwiftUI/`NSApplication` 构造前分流；父进程通过 `posix_spawn` 成为唯一 `waitpid` owner。
  timeout/cancel 都必须先由 WNOHANG 证明 child 仍归属当前 generation，再 TERM → KILL → reap。
  worker 不可用或协议错误 fail closed，禁止静默回退到不可终止的 in-process 路径。
- **能力与协议边界**：worker request 不出现在 argv，也不接受同 UID 可命名路径；父进程把
  已 unlink 的只读 0600 descriptor 映射到 child stdin，child 复核 parent generation、同一
  executable vnode、designated requirement 和 unique signing digest。spawn 使用
  `POSIX_SPAWN_CLOEXEC_DEFAULT`，不继承 App 的无关 FD。stdout 采用严格单 final NDJSON；只有
  exit 0、完整 EOF、未截断、无坏帧且恰好一个 final 才能成功，其余均为 typed partial。
- **可信 partial 与进度**：候选解析和每个完整 group 发布 Codable checkpoint、pending paths、
  当前 verdict/path 与真实 completed/total group count。worker 卡在 syscall 时，父进程保留上一
  checkpoint，只把 pending 标为 typed deadline；MainActor 仍以 scan generation 拦截旧进度。
  UI 展示组数、当前路径和已用时间，不伪造 byte denominator 或 ETA。
- **测试源码已添加但尚未运行**：覆盖 safe-before-confirm 打开顺序、同 verdict 共享、checkpoint/
  pending、Codable、缺 worker fail-closed、阻塞子进程硬超时/reap、stdout 流式解析、取消与
  PID ownership。按用户明确顺序，当前先完成实现、静态审查、提交和推送，之后才运行 C2/C3。

**仍缺项**：本节当前证据仍为 C1。提交推送后必须完成 ScanKit/AppUI 聚焦测试、全部 9 包、
Debug build、双基准，并在一次持续 App 进程中复现相同受保护容器，验证 worker 的 FDA/TCC
可见范围、12s 级硬终态、safe checkpoint 保留、后续扫描响应和完整 C4 矩阵。macOS 13.5
真实设备/VM 与最终 DMG C5 仍未验证。

### 9.8 第二次 C4 暴露的 Developer discovery / App Data 根因（v2026.07.17，当前 C1）

- **隔离 worker 已取得局部 C4 证据**：同一持续 App 进程中 Common App Cache 在 12.31s
  返回 typed partial，旧 368.47s 不可终止阻塞未再出现。该结果只证明 hard cutoff/checkpoint，
  不代表 Common App Cache 整体通过。
- **App Data 系统窗**：unified log 将系统窗定位到 common-app-cache worker 的
  `kTCCServiceSystemPolicyAppData`，不是 DevArtifact、FDAProbe 或“目标 App 正在运行”。候选
  resolution 的 glob/lstat 本身也会触碰 TCC，不能只给 measurement group 排 safe → confirm。
  当前源码在 FDA 未被正向证明时，于 Container/App Group pattern 边界前形成 typed skip，
  普通缓存继续扫描；FDA confirmed 后才允许进入。未修改受保护规则库或 Info.plist。
- **Developer 真实分段**：HOME discovery 1,636,452 entries / 1,453 hits / 51.492s；随后
  1,454 roots 约 7.074s。当前源码改为复用 ScanKit descriptor identity 与 `getattrlistbulk`，
  每父目录单次读取并用统一介质 worker 策略；既有 rule/verdict、timeout/maxHits partial 和
  no-follow/跨卷边界必须保持。
- **指标纠错**：旧 `58.240s drainLag` 把 discovery 与 sliding-window root queueing 都归入
  UI。MultiRootEvent 现在冻结 root producer terminal 的绝对时间戳，协调器统一减去同一轮
  `startedAt`，只把最终 terminal 到 authoritative publish 的尾差记为 drain；0-hit discovery
  使用 scanner 内冻结的 elapsed。新增 `CoordinatorBench --developer` 防止只测 BulkScanner/
  Large Files 而漏掉 Developer 前置阶段。
- **Debug 冷启动独立归因**：约 250.56s 均发生在第一条 App 日志前的 dyld `F_CHECK_LV`
  冷校验；同一产物暖启动约 55ms，静态签名有效。当前没有证据支持修改业务代码、entitlement
  或工程设置；需独立 DerivedData 的 `ENABLE_DEBUG_DYLIB=NO` 诊断构建与 Release 冷启动 A/B，
  且禁止用反复快启停预热冒充 C4。

**仍缺项**：本节修改按用户顺序尚未运行测试。提交推送后必须完成 ScanKit/AppUI 聚焦测试、
九包全测、Debug build、三条 benchmark 与一次持续 C4。`web.dist` 命中已安装 Cursor extension
的规则所有权风险需要规则库单独授权；`NSAppDataUsageDescription` 需要 Info.plist 单独授权；
macOS 13.5 实机/VM 与最终 DMG C5 仍未验证。

### 9.9 v2026.07.18 四个截图问题、日志与隐私合同收口（历史 C3；性能结论已由 9.11 重新打开）

> 本节的 package tests 与 Debug build 仍是有效的历史 C3 证据，但不能证明真实 App 交互或
> 性能已经收口。2026-07-19 的真实日志随后暴露开发者扫描 `12s → 78–221s`、Tree `/Users`
> 浅层 `94.91ms` 后仍被 `32.94s` 深层 enrichment 持续标成 loading；因此“避免主线程重建大树”
> 和“四个截图已收口”不得继续作为当前结论，根因、基线 A/B 与重新验证以第 9.11 节为准。

- **四个截图的共享根因修复**：Port Cleaner 表格占位高度不再把少量端口行压到窗口底部；全盘
  扫描统一物理路径与用户可见路径映射，TCC/FDA/元数据缺口保持 typed partial，不再把受保护根
  当成完整的零结果；扫描 producer 的终止、取消与 revision 统一收敛，Tree verdict、排序、扁平
  投影和宽 COW 释放移出 MainActor，选择索引改为 O(1)，避免扫描期在主线程重建大树；历史记录
  改为后台 single-flight 加载，并把 durable completion journal 与当前内存投影按 revision 合并，
  旧加载不能再把新历史覆盖成空白。上述修改都落在共享状态/证据边界，没有扩大删除权限。
- **错误可观察性不是可选项**：App 启动早期日志进入 256 行有界 FIFO，文件 sink 就绪后按序落盘；
  writer health 与 retention/export/enumerate/clear issue 分开维护，单个阶段成功只清除本阶段错误。
  设置/帮助页展示本地化的阶段、错误域与错误码；导出使用 64 KiB 流式复制、0600 同目录临时文件、
  `fsync + renameat` 原子替换，并复核精确文件名、no-follow 与 inode。API Key、Authorization、请求/
  响应正文仍禁止进入日志，但扫描阶段、路径、errno 和类型化失败必须可见、可导出。
- **隐私与网络边界**：App bundle 新增 `PrivacyInfo.xcprivacy`，声明 tracking=false、无 tracking
  domains，并按真实本地功能披露 linked 的 Other User Content、Other Data Types 与 User ID，目的
  均为 App Functionality；当前 macOS-only 产品没有填写不适用的 Required Reason API 条目。
  Updater 只向固定 GitHub API origin 读取 release metadata，拒绝 redirect、cookie、credential、
  cache 与跨仓库 asset；AI 只使用用户明确配置的 endpoint/key，限制 origin、body 大小和取消，
  debug/custom mirror 不再泄露敏感字段。隐私文档、Security、README、安装/发布文档与产物合同同步。
- **不可信本地元数据与恢复台账**：ScanKit 新增共享有界 reader，执行
  `lstat → O_NOFOLLOW/O_NONBLOCK open → fstat → chunked read → identity/version fence`，拒绝 FIFO、
  final-component symlink、超限和读取中替换；DerivedData、AppMetadata、LaunchAgent 与标准 App
  cache discovery 使用同一失败分类。BrewKit 使用无跨包依赖的等价 reader。Trash pending ledger、
  completion journal 与 Simulator ledger 增加字节数、记录数、schema/shape 上限并 fail closed，旧坏
  文件不被空状态覆盖。Sentinel 第一条可执行语句拒绝 root 运行，新非特权 LaunchAgent 与旧 root
  daemon 迁移边界均写入构建/发布合同。
- **首次 AppUI 全量失败如实保留**：一次与其它包并发的运行中，20,000 行 prune 性能项为
  `2.3706s > 2.0s`；另有一项测试读取宿主 `/Applications` 导致 fixture 污染，以及两个已无调用方的
  String Catalog orphan。没有放宽性能阈值或削弱断言：隔离复跑性能项为 `1.436s`；目标 Smart Care
  用例 `1/1`、整组 `22/22` 通过；测试显式注入完整空的标准 App discovery，两个 orphan 从 catalog
  删除后 i18n 审计 `1/1` 通过。
- **最终全包与构建证据（C3）**：AppUI `1,295` XCTest + `11` Swift Testing；ScanKit `523`
  passed、`2` 个既有 `RUN_PERF` gate skip；SafetyKit `167`、HeuristicKit `11`、LogKit `37`、
  BrewKit `54`、FileSearchKit `21`、AIKit `55`、TestHarness `8`，全部 exit 0。原生 Debug
  `xcodebuild` 明确输出 `** BUILD SUCCEEDED **`。`git diff --check`、全部 plist/privacy manifest、
  String Catalog JSON、全部 shell 脚本语法及 `test_release_contract.sh` 均通过；构建产物确认包含
  privacy manifest、Sentinel、LaunchAgent/Daemon 与规则资源，所有 `Package.swift` 均未修改。
- **只读扫描基准**：`~/Library/Caches` 通过生产 BulkScanner 扫描 `376,122` files、物理占用
  `22.64 GB`，引擎阶段 `4.55s`；`du -sh` 对照约 `21G`。受保护目录逐项输出 permission-denied
  与 scoped incomplete，没有伪装为完整结果。该基准没有移动或删除文件，也不能替代 UI 主线程
  与窗口交互验证。
- **当前证据边界与剩余风险**：本轮没有启动 App，因此仍是 **C3**，没有对彩虹光标、Tree
  右键/展开、全盘 TCC/FDA、日志设置页和历史首次加载做持续 C4。还需在启用 orphan 删除前补齐
  installed-app discovery completeness/有界 plist 合同；Brew 取消应做到聚合器级尽快收敛；Trash/
  Undo 当前品牌常规读取的 pathname size preflight 仍需 fd-bound fence（旧品牌 Undo 迁移边界已由
  第 9.10 节单独闭环）；Heuristic/CleanStats/Whitelist 的其它本地 JSON
  仍需统一有界 reader。旧版本 root ServiceManagement 迁移、真实 provider/network volume、macOS
  13.5 实机/VM、两进程断电恢复和签名公证 DMG C5 也未验证。

### 9.10 v2026.07.19 Sentinel 默认关闭与 Undo legacy 迁移根因修复（当前 C2）

- **Sentinel fresh/default-OFF 合同**：Toggle 默认 OFF 且没有成功注册时间、已注册系统状态或
  持久化 shutdown-verification marker 等 authority 证据时，`.notFound` / `.unknown` 只保留
  `.desiredOffUnverified` 状态与结构化本地日志，不弹“关闭失败”、不引导从未启用的用户
  打开系统设置。用户显式 OFF 或已有 current/legacy authority 证据时仍 fail closed，且只有
  current Agent 与两代 legacy identity 都明确 `.notRegistered` 才清核验证据。
- **Undo legacy 持续对账**：移除 `attributes → Data(contentsOf:) → moveItem` 三次 pathname lookup，
  也废弃“只复制一次、destination 永久优先”的模型。每次 bootstrap 都在 current stable `flock`
  内对两边做 no-follow、同 fd、0…8 MiB 有界读取与版本栅栏；schema 4 保存各 50,000 上限的
  observed record/receipt ID，只导入未见 UUID，对 current 仍保留的同 UUID 做单调终态/journal
  合并，并阻止已 LRU、确认清理或未来显式清除的旧 ID 复活。current 通过 `0600` sibling temp、
  file `fsync`、原子提交与 parent `fsync` 更新；首次创建仍 no-replace。legacy 保留，因为 Darwin
  没有 identity-bound unlink；final source fence 后才开始的旧进程写入由下一次 bootstrap 收敛。
- **状态不再伪空**：reconciliation 返回 typed outcome；symlink、hardlink、超限、损坏、源
  replacement、current commit 或水位超限会投影为 read/corrupt/size/record/write failure，bootstrap
  不得继续把失败读成 `.ready + empty`。
- **已运行证据**：`UndoHistoryStoreTests` 52/52 通过，覆盖 safe initial copy、重复 bootstrap、
  clear/receipt tombstone 不复活、后续 legacy 新 UUID 导入、同 UUID 终态单调合并、final fence 后
  写入下一次收敛、symlink/FIFO/hardlink/replacement/8 MiB+1 与 corrupt typed-state；Trash action、
  completion journal、pending ledger 相关测试 75/75 通过；`SentinelManagerTests` 41/41、`AppSettingsTests` 19/19、
  `I18nIntegrityTests` 17/17 通过，默认 OFF/无 authority 不弹失败、证据持久化与中英文资源完整性
  均有直接断言。
  本节没有启动 App，因此没有 Sentinel 设置页和历史首次加载的 C4；也未将聚焦 C2 写成 C3。

### 9.11 v2026.07.19 扫描与 Tree 性能回归重新打开并完成代码级根因修复（当前 C2 + Debug build）

- **基线与根因**：以 `70fce59e4ca57552675adc249d107d7342ad153b` 为已知良好行为逐段对比。
  `DevArtifactScanner` 遍历策略与基线一致；回归发生在 `ScanCoordinator` 的发布所有权：异步
  projection worker 跨 `await` 保留 MainActor 上持续增长的 `perRootStaging` Dictionary，后续每
  20 个 discovery hit 的写入都会触发越来越大的 COW 复制。Tree 的独立回归是直接子项已经提交后
  仍持有 disclosure loading ownership，直到不影响下钻正确性的深层容量 enrichment 完成。
- **修复边界**：开发者发现的 0.4 秒 partial 与 final flush 恢复 `70fce59e` 的单 turn 发布形状，
  不再把 staging storage 交给跨 `await` worker；其它入口的有界后台 projection 保持不变。Tree 在
  直接子项 identity terminal 时先清 in-flight/ownership 并发布 revision，深层容量继续后台补齐；
  宽树 materialize、verdict 与 COW retirement 仍在后台 worker。未改变扫描候选、安全 verdict、
  incomplete/partial 或删除合同。
- **当前自动化证据**：developer 2,048-root ownership 聚焦测试 `1/1` 通过；全盘 96 个直接子项
  shallow-terminal 与 20,000 行 Tree 非主线程 projection 两项 `2/2` 通过。当前完整源码的原生
  Debug 构建输出 `** BUILD SUCCEEDED **`，产物位于 Xcode DerivedData 的
  `Build/Products/Debug/AmuxAIClean.app`。`git diff --check` 通过。
- **证据边界**：尚未重跑 AppUI 全包和九包全测，因此本节不能升级为 C3；没有启动 App，也没有
  C4。真实开发者扫描总时长、彩虹光标、全盘宽目录首帧和 loading 消失时间必须由下一次持续运行
  记录。Review 另发现 completion journal 的当前读取边界仍需同 fd/no-follow/shape 上限闭环，
  所以当前整个脏树不满足提交闸门。

### 9.12 v2026.07.20 Tree 精确终态与扫描进度 UI 隔离修正（当前 C2 + Debug build）

> 本节废止 9.11 中“shallow identity 提交后立即清除 Tree loading”的判断。该行为与用户
> 交互合同及已知良好提交 `70fce59e4ca57552675adc249d107d7342ad153b` 均不一致，属于再次回归，
> 不能继续作为正确性能修复保留。

- **Tree 工作量与正确终态**：`/Users` 的直接子项枚举约 `116ms`，但两个直接目录的精确递归
  容量与排序仍需遍历 `3,130,624` 个后代文件，约 `31.4s`。因此直接子项 identity 继续立即显示；
  同一 disclosure owner 则保留到 exact bytes、file count 与请求排序完成。精确行先写入 cache，
  再清 ownership，并只发布一个 terminal revision，避免 pending rows 已显示 idle、或精确行仍
  显示 loading 的撕裂状态。该 revision 保留所属 parent path，使 Tree 只 patch 当前连续 segment，
  不因一次精确测量完成而重建全部可见行。取消、lease 未取得、stale generation 与扫描准入变化
  也统一发布明确终态，避免 spinner 永久悬挂。
- **全盘扫描 UI 卡顿根因**：生产 `.topLevel` 扫描终态前没有可展示 Tree rows，却仍每 `0.4s`
  替换完整 `ScanSnapshot`；`MainView` 和 HUD 对整个 `ScanCoordinator` 的观察因此让 elapsed/bytes
  单字段变化反复 invalidation 完整 `NavigationSplitView`、侧栏与结果区。当前 bytes/files/rate/
  elapsed 进入独立 `ScanLiveProgressStore`，只有状态栏小子树与 HUD 订阅；权威 snapshot 和 Tree
  revision 只在结构/终态 transaction 发布。per-root 兼容镜像仍保留，但不再作为宽 coordinator
  的实时 `@Published` 广播源。
- **聚焦证据**：`ScanCoordinatorProjectionIntegrationTests` `9/9` 通过，覆盖 shallow rows 立即
  可见、loading 保留至 exact terminal，以及投影进度只更新窄 store、`objectWillChange` /
  `$snapshot` / Tree tick 均不发布；`ScanCoordinatorPresentationWorkerTests` `26/26` 通过。当前
  完整源码 Debug 构建输出 `** BUILD SUCCEEDED **`，`git diff --check` 通过。
- **未升级为 C3**：已实际运行 AppUI 全包，但当前脏树仍有四组独立失败：primary admission
  settlement 期间的 common-app-cache presentation 合同、测试 seed 未生成 terminal per-root Tree
  cache、以及 Trash completion journal / receipt prune 两组闭环。四组均可单独稳定复现，且调用链
  不经过本节的 Tree loading 或 live-progress 修改；不得为让本轮变绿而回退性能修复或放宽断言。
  尚未启动 App，因此没有 C4；侧栏连续滚动、HUD 动画和 Tree loading 消失时机仍需用户在同一次
  持续运行中验证。

### 9.13 v2026.07.20 删除结果延迟的回执/模型边界修正（当前 C2 + Debug build）

- **真实根因证据**：同一 trace 中 `NSWorkspace.recycle` 在约 `364ms` 返回 typed completion；随后
  删除模型同步进入 `13,651` 行 snapshot、`11,872` 个 Tree cache entry 的 prune，plan 约
  `11.45s`，旧顺序直到它完成才记录 `result_eligible`。因此“删除后十几秒才弹完成”不是系统
  recycle 慢，而是 UI 错把模型 reconciliation 当成结果权限。
- **双层修复**：Main Professional 删除在 receipt 到达后立即 route typed result，SwiftUI 获得
  presentation turn 后再同步列表/Tree/统计/历史；日志明确区分 `result_eligible` 与
  `model_sync_completed`。prune 同时改为按需构建 Tree-cache contribution fallback，并在
  Developer terminal 没有全局 snapshot Tree projection 时保持为空，不再重建八套无消费者排序。
- **聚焦证据**：`ProfessionalToolDeletionFlowTests` `21/21` 与 `PruneDeletedTests` `30/30`
  通过。结果顺序测试证明慢 reconciliation 开始前结果已经呈现；宽 Developer fixture
  覆盖 `1,484 roots × 8 sort keys`，证明单项删除不构建 `11,872`-entry contribution index、不恢复
  全局排序，且 planner 保持后台执行；当前完整源码 Debug 构建输出 `** BUILD SUCCEEDED **`。
  AppUI 全包仍被同一脏树中既存的 scan settlement、terminal per-root seed 与 Trash/Undo journal
  红项阻断，尚未做真实 App 持续 C4，因此不能宣称实际弹框体感已经验收；本轮也未提交或推送。

### 9.14 v2026.07.20 Trash 测试域污染、非模态预检与 Undo WAL 连续事务闭环（当前 C3）

- **事故根因与 UI 边界**：包测试曾通过裸 `TrashPipeline()` 继承 production pending ledger / completion
  journal，scripted Workflow 又可借默认 `.shared` 写入用户 Undo。真实 App 随后把未结算测试 callback
  当成生产恢复事实，零提交的 ledger 校验失败再被错误画成 raw-key 阻塞结果框。当前五个入口统一把
  pre-submit rejection 投影为页面内 typed banner；它不占 sheet/transaction，不吞掉真实确认，也不
  阻止下一次审阅。只有取得真实 recycle receipt 的完成结果可进入 `OperationResultSheet`。
- **生产/测试持久化域不可拆**：生产只经具名 `TrashPipeline.production`，裸 package initializer 每实例
  创建 UUID 临时 ledger、journal、Undo、registry 与 single-flight identity。所有允许注入 pipeline 的
  Main/Brew/Duplicate/Uninstall/Workflow View 同时强制注入 Undo owner；App composition root 显式选择
  `.shared`，scripted caller 必须显式选择临时 store。production ledger/journal 无参构造已收为 private，
  pending ledger 测试构造不再默认 shared registry。规则已同步到 `DELETION_UX_CONTRACT.md` 与
  `PITFALLS.md`，关键转移均保留 `v2026.07.20` 原因注释。终审另外关闭了 Main 嵌套导航的两个 P1：
  Uninstall 显式复用 Main 的 pipeline，UndoHistoryScreen 显式接收 Main 的 store；源码合同测试拒绝
  后续重新引入 production prewarm 或 `.shared` 回退。
- **Undo WAL 根因修复**：首次创建 Undo store 时，reserve slot 重写后已有新的 fingerprint/version，旧
  代码却把重写前 version 写入 idle marker，导致下一笔 receipt-prune RMW 以 `transactionContract`
  fail-closed。现在 marker 使用同一时点的 fresh evidence，并用 add → acknowledge → add 连续事务锁定。
  同一 WAL 重构漏掉的 legacy `.UndoHistory.<UUID>.tmp` 清理也已恢复：只在稳定 flock 内通过 anchored
  parent descriptor 执行 `readdir + fstatat(AT_SYMLINK_NOFOLLOW) + unlinkat + fsync`，仅删除当前用户
  拥有的 canonical uppercase-UUID、regular single-link 文件；畸形名、额外后缀、hardlink 与 symlink
  均保留。
- **完整自动化证据**：删除交互/恢复聚焦集合 `179/179`；AppUI `1,379` XCTest 与 `11` Swift Testing
  全部通过。ScanKit `525`、SafetyKit `167`、HeuristicKit `11`、LogKit `46`、BrewKit `54`、
  FileSearchKit `21`、AIKit `55`、TestHarness `8` 均 exit 0。AppUI 首轮暴露的 common-cache typed
  settlement 与 terminal-only per-root fixture 两项旧测试合同，仅更新测试以经过现有 `.settling` /
  off-main terminal transaction，生产 ScanCoordinator 未改；对应聚焦 `3/3` 通过。原生 Debug
  `xcodebuild` 输出 `** BUILD SUCCEEDED **`；全仓 `git diff --check`、String Catalog JSON、Info.plist 与
  Privacy manifest 校验通过。
- **终审增量证据**：上述两个嵌套导航 P1 修复后，依赖域聚焦测试 `15/15`、完整 AppUI package 和
  原生 Debug build 再次 exit 0；Debug 输出 `** BUILD SUCCEEDED **`。三轮前后 production recovery
  目录文件清单与 SHA-256 均一致。
- **生产数据证明与剩余边界**：每轮删除相关测试、完整 AppUI 和 Debug build 前后均比较 production
  ledger、journal、UndoHistory 的 SHA-256，全部保持不变；本轮没有启动 App。历史目录中已确认的 1 组
  未结算测试事务与 UndoHistory 中 4 组旧测试记录尚未修改；现有 schema 没有可信 test provenance，
  禁止按路径名自动猜删。必须在用户明确确认 exact IDs 后，以 durable quarantine + 锁内 CAS 执行一次
  性隔离，且不移动或删除废纸篓文件。完成前不得启动 production recovery 做 C4，因此当前证据止于 C3。

### 9.15 v2026.10.07 两个当日提交复审、修复与部分真实运行验收（C3，C4 未全闭合）

- 审阅 `e27bf74`、`4760396` 后修复四项 P2：Smart Care 完成后继续审阅的错误状态转换；
  普通分析延迟删除回执跨扫描会话；重复文件旧投影覆盖新扫描/并发回执互相恢复旧路径；
  Brew Cask 别名读取失败被静默当成没有活跃引用。新状态 owner 保持会话/revision 校验，
  过滤与证据计算留在后台，回归覆盖真实失效条件。
- 用户授权持续真实 App 测试后，又复现普通分析把隐私跳过根呈现为空目录，以及中文页面
  的确认 sheet 使用英文。前者复用 Tree 的 typed access projection；后者由公共
  `localizedSheet` 显式传递页面 locale，全部 presenter 使用同一入口。隐私规则未改，
  不因临时 fixture 受阻放开 `/private/var/folders`，也不改用别名绕过。
- 最终九包全测全部通过：AppUI 1,476 XCTest + 11 Swift Testing，ScanKit 532、SafetyKit 174、
  HeuristicKit 12、LogKit 46、BrewKit 58、FileSearchKit 21、AIKit 55、TestHarness 8；合计
  2,393。最终原生 Debug build、catalog 校验与 `git diff --check` 通过。ScanKit 使用 native
  backend；默认 swiftbuild 的重复链接故障在未修改基线上同样复现，未改项目/依赖。
- 真实操作已覆盖 Smart Care 扫描/停止/继续/预览取消，项目目录的普通分析下钻/返回/搜索，
  专业 Tree/清单切换，卸载/Brew/Apple workflow 的发现，以及最终构建的工作流中文/英文
  确认取消与语言还原。隐私跳过根已观察到修复后的明确终态。上述为对应只读交互证据，
  **不代表删除合同的 C4 已完成**。
- 当前启动前后的 pending ledger、completion journal 均为空，字节哈希相同；没有真删、
  新 receipt 或 Undo 操作。10 月 7 日 23:59 九个临时 fixture 的哈希/大小/mtime/inode 不变；
  10 月 8 日补验后核对发现 `Duplicates/old.bin` 缺失，其余八个未变，目录修改时间为补验前
  03:35，删除来源未证实；该 fixture 后续须重建，不能再作为完整的原始验收输入。Undo 保留十条
  既有记录；正常退出会重写 JSON，字节哈希并非未变。7 月第 9.14 节的队列状态是当时
  证据，不能替代本轮实际读取，也不能据此猜测或清除旧记录。
- 首轮后续原生 UI 工具返回 `cgWindowNotFound`，库存仍报 App 运行，未把它解释成 App
  崩溃。10 月 8 日窗口恢复后，最终产物 Smart Care 的中英文确认/取消已复验通过，原选择
  保留，语言恢复简体中文。真实 fixture 回收、receipt/结果、Undo、Smart Care 真清理后的
  完成页、深色/尺寸矩阵、macOS 13.5 与 Release DMG C5 仍未完成。
- 10 月 8 日用户授权最终 review 通过后提交、推送。六类修复的最终审查无未处理阻塞项；
  源码及运行二进制哈希匹配上述九包测试/Debug 构建，不重复运行未发生源码变化的测试。
  提交不改变 C3 与部分 C4 的证据边界，也不构成全平台/全入口无缺陷保证。

完整范围、根因、操作步骤与原始证据索引见
[2026-10-07 commit 修复与真实 App 验收](regression/COMMIT_REVIEW_C4_2026-10-07.md)。

### 9.16 v2026.10.08 回收成功但行残留、多个页面回执漏订阅与成功弹框（C3，回收 C4 待验）

- **真实事故重开**：用户截图对应的系统回收已返回 moved=1、failed=0，权威 prune 已提交，
  最后 Tree 投影却被 `source_current=false` 丢弃。structural/tick 两个入口在通知后推进
  source revision，自行使订阅者冻结的 source 过期；receipt 订阅又在 `@Published` 的 willSet
  回调读取旧 revision。此前只修过 children-cache 的同类顺序，没有覆盖这些入口。
  本轮统一提交 identity 后发布，并用不可变 matcher/revision 事件保留全部 stale CAS。
- **跨页面与反馈**：普通空间图补回执订阅，后台使用共享 tombstone 过滤图块、列表与展示
  统计；大文件补冻结表格和独立类型统计源的后台 receipt 投影。所有 Trash owner 共用纯成功
  页面内短提示，失败、部分成功与不确定终态保留明细；定时关闭绑定 receipt ID。
  未改安全/隐私规则、删除授权、最终重验、Trash、Undo、工程或依赖。
- **最终自动化**：九包 swift test 均 exit 0，共 2,399 个条目；两项 opt-in 原生视图另在非并行
  集合中执行，Tree/大文件/普通分析集成 14/14 通过。四个根因均保留原代码失败日志。
  最终原生 Debug build、String Catalog 完整性与 diff check 通过。SafetyKit 性能首轮受并发负载
  影响失败，独立全包重跑通过，阈值未改。20 个 Swift/catalog 文件在最终验证后指纹一致。
- **真实运行与边界**：最终二进制的一次持续只读验收覆盖 Resources 的 Tree 展开/详情、清单
  切换、普通空间图下钻/搜索/返回、两种确认取消。测试添加的快捷项已移除，用户原有路径保留。
  这不证明真实回收后行/选择/详情消失、无成功模态或 Undo 正确；NSTemporaryDirectory 被现有
  规则跳过，人工 HOME 缓存 fixture 的一次位置例外尚未获答复。没有为测试改规则或绕路径。
  用户获知边界后明确要求提交和推送，按该授权交付，证据等级保持不变；
  macOS 13.5 和 Release/DMG C5 未做。
- **漏检原因**：上轮只读 C4、模型终态和独立 worker 测试没有观察同步发布边界，也没有挂载
  production 表格验证 receipt-only 删除。后续不能再以这类 C2/C3 结果宣称真实删除交互已通过。

逐入口审计、竞品参考、验证命令与证据索引见
[2026-10-08 删除呈现复盘](regression/DELETION_PRESENTATION_2026-10-08.md)。

### 9.17 v2026.10.08 `7b96b02` 六项复审修复（`CODED_UNVERIFIED`，待作者 review 与 C4）

- **范围**：仅处理本次复审的六个根因：大小写敏感卷被错误升级 `.safe`；完整 prune 后 Undo
  未重建结果；独立子树刷新重复计算跨目录硬链接；普通文件类型在流转中丢失；历史路径别名
  覆盖恢复信号；active version 按 readlink 拼写而非目录身份排除。
- **共同边界**：正向规则由目标文件系统能力决定；Undo 通过后台 indexed transaction 重测并
  提交行、图索引、总量、Tree 排序、Top-N 与 tombstone。原始扫描目录合计与多链接身份归属
  贯穿 refresh/prune；两轮间出现未知硬链接身份时使稀疏容量基线失效并重放原始扫描计划。
  普通单链接文件名不进入持久内存账本，多链接别名集合原位更新以避免二次方复制。
  恢复通知按当前扫描命名空间投影父级别名，保留最后一级软链目录项。
  文件类型、历史计数和版本身份均保留生产者证据。
- **防回归**：新增实际临时文件/硬链接/FIFO/断链 fixture，覆盖完整 prune、重名恢复、整根
  多根恢复、连续刷新、计费路径消失、直接 prune 计费项、路径别名与两轮之间新建硬链接；另验证正向 literal/glob 规则、
  历史 JSON 别名合并和 mixed-case 多跳 current。重名通知测试统一 `/var` 与 `/private/var`
  的同一位置比较，仍断言占用的 original 不得出现在恢复通知。未改需求或削弱安全断言。
- **最终验证（C3）**：九包全测、Debug 构建、六项 opt-in 原生订阅集成全部通过，
  String Catalog 与 diff check 通过，21 个修改的 Swift 文件在最终验证期间指纹一致。
  最终日志在本地 `build/fix-7b96b02/final/`。ScanKit 使用此前已验证的 native build-system
  scratch 方式避开本地默认构建器重复 object 问题，未改 manifest、工具链或断言。
  并发编译时 SafetyKit 和前一轮 AppUI 的既有性能项曾超预算，失败日志保留；最终 AppUI
  全测通过，构建结束后 SafetyKit 独立全测 181/181 通过，性能项五次平均 0.691 秒，
  原本的 1 秒 budget 未改。Undo、pending ledger、completion journal 的生产文件哈希与复审前相同。
- **扫描基准**：受控临时数据共 60,100 个普通文件目录项、50,001 个唯一 inode，单个文件
  有 10,100 个硬链接；独立 metadata 合计 allocated/logical 均为 204,804,096 bytes。
  PerfBench 57ms、默认 CoordinatorBench 108ms、大文件模式 54ms，容量与数量全部一致；
  深索引诊断模式 615ms、drain 528ms，不能把诊断模式耗时写成默认投影开销。
  该基准没有渲染 UI，也不证明高频文件变化、真实界面响应性或 APFS exclusive reclaimable size。
- **剩余边界**：未启动 App，未做运行交互验收；作者 review 与持续 C4 尚未完成。
  C4 须在同一次 App 运行内核验回收后 Tree/清单/大文件的行、选择、详情和统计，随后 Undo
  与重名恢复无需再次点击就重现一致结果；并检查取消/换扫描后的旧恢复不能覆盖新页面、
  大目录 UI 响应性与内存。真实回收仍只能使用允许的临时 fixture，现有安全/隐私规则没有
  为测试调整。macOS 13.5、Release/DMG C5 未做。本轮不提交、不推送，交由作者复审。


### 9.18 v2026.10.08 全功能真实 App 首轮回归（`PARTIAL_C4`，未完成全功能验收）

- **计划**：[75 项矩阵](regression/FULL_APP_C4_2026-10-08.md) 覆盖回收/Undo、普通与专业扫描、
  工具、四工作流、设置及生命周期。每项 [执行状态](regression/FULL_APP_C4_RESULTS_2026-10-08.md)
  区分通过、部分完成、失败、受阻与待测；页面进入、取消分支和 C3 不能算正向操作通过。
- **实际修复并复测的范围**：人工端口/Dart 真实退出后的纯成功非模态；应用占用/卸载的可见
  选择与异步 owner 同步；卸载候选数量/容量同源；Tree 父目录连续与嵌套刷新结束 owner 后
  再发布最终投影；重复扫描完整空/不完整空/输入变更与语言切换。后两项均由本轮真实交互
  发现，保留失败现场、共享边界修复、版本注释和聚焦防回归，未加 spinner 超时或 UI 兜底。
- **C3**：九包 2,457 个测试项通过，原生视图 opt-in 另在 7 项集成集合中实际执行并通过；目标
  Debug 构建与签名严格验证通过。最终源码/测试/整个 bundle 指纹核对一致。日志和 manifest
  位于本地 `build/full-app-c4-20261008/`，当前结论对应 `delivery-build-preflight.json`，不是
  中间构建的 loader 哈希。SwiftPM native scratch 方式未改变工程/manifest。
- **未关闭**：F04 原生菜单展开后混语；F07 `/private/var` 与 `/var` 的规则匹配缺口真实枚举
  人工临时文件。F07 保持规则不变的候选补丁与红/绿独立探针已准备，规则实现修改等待明确
  授权，尚未应用，不计为修复通过。英文既有单数计数和更新请求 HTTP 404 也已如实记录。
- **核心缺口**：没有真实回收或 Undo；TMP fixture 与现有 HOME 删除边界/隐私策略冲突，
  HOME 人工 cache fixture 的一次测试位置例外尚未获答复。未用 `/var` 漏洞、改规则或既有
  用户数据制造通过证据。系统维护、真实卸载、模拟器/后台服务、权限/提交故障需要隔离 E；
  AI 请求、macOS 13.5、Intel、Release/DMG C5 未覆盖。作者 review 仍待，本轮未提交/推送。
- **清理**：最后持续会话 PID 7041 正常退出；偏好与两条原自定义路径还原，人工五进程已结束，
  参考文件哈希一致；pending/journal 仍为空、历史仍十条。人工 TMP 文本与空后缀目录保留，
  没有绕过回收合同删除。正常退出重写 Undo JSON，不能声称其字节哈希不变。

### 9.19 v2026.10.08 外部复审发现的 Undo 模式同步遗漏（C3；无新 C4）

- **复核结论**：三项核心指摘成立。原有多根 Undo 用例只断言总量和 Tree，遗漏实际清单与
  bucket；特殊版本/缓存扫描缺少恢复对账范围；普通结果尚未生成 Tree 投影时刷新沿用空字典。
  第三项应收窄到未投影状态，完整空扫描通常已有八个排序键的空数组。新增/强化的聚焦集合
  在原实现产生 22 处断言失败，见 `build/undo-review-20261008/red.log`。
- **修复边界**：普通多根在同一后台 indexed transaction 合并当前根的一级 rows/buckets，
  保留其他根。专用发现使用类型化计划和独立候选历史，经 primary admission 重放原生产者，
  重新执行版本保留、缓存选项和白名单；不先清 tombstone 暴露旧行。Tree 按真实模式构造，
  版本候选显式刷新仍保持语义叶子，不把所有 sentinel 都当 per-root。
- **修复自查**：在实现过程中进一步用红断言拦住取消后通知重启扫描、重名恢复失效、候选
  路径混入枚举根而使显式刷新替换候选等问题；最终候选历史跨恢复重扫保留，结果 owner
  失效时撤销计划，重名仅使候选父域失效并重新判定规则，不能给新名字授信。红日志分别为
  `cancelled-owner-red.log`、`renamed-discovery-red.log`、`discovery-root-domain-red.log`。
- **最终验证（C3）**：九包全测全部 exit 0，共调度 2,451 项 XCTest，11 项 Swift Testing
  通过；AppUI 为 1,508 项 XCTest 加 11 项 Swift Testing。默认跳过的两项原生视图已在开启
  opt-in 的 45 项聚焦集合中实际执行，全部通过，不重复累加。目标 Debug 构建、签名
  strict/deep 与 diff check 通过。214 个生产/工程资源、211 个测试文件验证期间指纹一致，
  完整 bundle 未再变化；生产 Undo、pending ledger、completion journal 哈希均未变。
  新增五个有行为意义的用例，另强化已有多根恢复断言；仅用系统临时 fixture，没有真实回收。
  默认高并发全测出现既有 2 万候选性能项超出原 1 秒预算（1.407 秒），失败日志保留；原
  断言独立复测通过（整个用例 0.530 秒），两个测试 worker 的完整 AppUI 重跑也通过，未改
  预算、环境判据或需求。原始失败、最终全测、源码/产物身份见本地
  `build/undo-review-20261008/verification-summary.json` 与关联日志，不能隐去首次失败。
- **作者复审追加闭环（C2/C3）**：
  1. `KnownVersionedRoots` 语义叶子合同统一：`prepareVersionedRootsPresentation` 生成的 `RowItem`、部分删除（`PruneStateWorker.prepare` / `makePrunePlan`）、外部硬链接容量更新（`applyExternalAllocationDeltas`）以及显式刷新（`buildIndexedSubtreeTransaction`）均保持 `hasChildren == false`，避免部分删除后剩余版本候选退化为可展开目录；在 `ScanCoordinatorKnownVersionedRootsTests` 中增加先删 1 个候选再删剩余候选及 Undo 的断言。
  2. `VendorTrie` 同一下写化节点多字面量 `pathOverride` 合同：`VendorTrieNode` 保存保持声明顺序的 `literalOverrides`，在不破坏既有“先到先得”合同的前提下，支持区分大小写卷上同一归一化节点的多种大小写拼写（后续大小写变体不会在建树时被首条规则吞没）；新增 `PermissivePathSemanticsTests.testSameNormalizedTrieNodeSupportsCaseVariantsAndFirstMatchFallback`。
  3. 复核 F07 候选补丁（`privacy-alias-proposed.patch`）：实测发现若直接将 `/private/var/folders` 折叠为 `/var/folders`，会导致 `FileManager.default.temporaryDirectory`（`/var/folders/.../T`）下的 `BulkScanner` / `TreeSizeEstimator` 测试 fixture 全部被误判为 `.tccProtectedSkipped`（触发 `ScanCoordinatorKnownVersionedRootsTests` 等 8 处断言失败），且与 `AGENTS.md` 的 `NSTemporaryDirectory()` fixture 合同冲突；因此驳回该候选补丁，保持 `TCCSkipList.swift` 原实现不变，留待后续区分系统目录与当前进程临时目录后再处理。
- **剩余项**：本节改动完成九包全测与 Debug 构建（C3），未启动 App 做新的运行交互验收（C4）。
  F04 原生菜单混语与 F07 隐私路径匹配仍待后续处理；真实回收/Undo、macOS 13.5/Intel 与 Release/DMG C5 尚未完成。长期合同见 PITFALLS 第 22 节。

### 9.20 v2026.10.09 最新提交审查后的刷新基线与扫描范围修复（C3；无新 C4）

- **问题证据**：`7837094` 的默认浅层扫描保留 allocation catalog，但没有 deep index。
  根不可读后的 partial refresh 将清单与总量清零，恢复权限后容量仍为零；Undo 对账重新
  构造固定 `includeHidden=true`，把原扫描排除的隐藏文件重新加入清单和容量。使用真实
  primary scan 的三项新增回归在修复前产生 47 处断言失败，原十项恢复测试仍通过；原审查
  的独立生产 API 探针也复现两项问题，均只操作 `NSTemporaryDirectory()` 内人工 fixture。
- **修复边界**：indexed transaction 的目录索引统一从合并后的稀疏账本取得容量基线，批量
  聚合在后台进行；partial 保留未观测清单和已展开 Tree 成员，complete 才按缺席移除。
  可读目录增长与旧不可读目录容量合并，硬链接保留 owner 的展示修正同步推进 delta 基线，
  避免重复计费。单根、多根和开发者 producer 保存完整原始 `ScanOptions`，Undo 与显式
  indexed refresh 使用该副本；新结果 owner 重设配置，发现型列表继续重放原类型化计划。
- **聚焦验证**：新增四项 AppUI 行为回归及一项 ScanKit 聚合合同测试，覆盖浅层 scan 的
  根/后代权限变化、重复 partial、权限恢复、完整删除观测、已展开 Tree、单根选项切换、
  多根 Undo 以及不可读硬链接 owner 的容量修正。68 项相关 AppUI 行为与 4 项 allocation
  测试通过；原独立探针复验显示权限失败/恢复均保留 `8192 / 1`，关闭隐藏文件的 Undo 后
  仍只有原可见文件和 `8192 / 1`。没有真实回收，也没有启动 App。
- **最终验证（C3）**：九包全测全部 exit 0，共调度 2,457 项 XCTest，11 项 Swift Testing
  通过；AppUI 为 1,512 项 XCTest 加 11 项 Swift Testing。另开启原生视图 opt-in，7 项
  发布边界测试全部通过，包含默认跳过的两项原生视图，不重复累加。目标 Debug 构建、
  实际 `AmuxAIClean.app` 的 strict/deep 签名核验和 diff check 通过。全测使用既有 native
  SwiftPM backend，AppUI 使用两个 test worker，未改测试预算或断言。440 个生产/工程资源
  与测试文件在验证期间指纹一致；生产 Undo、pending ledger 与 completion journal 哈希
  均未变。完整命令、红日志、聚焦/全量结果和探针见本地
  `build/refresh-review-fix-20261009/verification-summary.json` 及关联日志。
- **剩余项**：未做运行交互验收，真实回收/Undo 的 C4 仍待用户授权的持续 App 场景验证。
  本轮只修复审查发现的两项问题；既有 F04/F07、macOS 13.5/Intel 与 Release/DMG C5
  仍按前述台账待办，未扩大规则、安全边界、删除执行或发布范围。

### 9.21 v2026.10.09–10 `1f48352` 复审后的路径共同边界修复（C3；无新 C4）

- **原始问题**：生产 API 探针确认多跳悬空链接指向 `/System` 时被缓存路径判为 safe；
  白名单互指 symlink 查询不终止；Duplicate 根规划再次 standardize，丢失
  `/private/var/folders` 政策身份，绕过与 BulkScanner 相同的 TCC skip。复现仅创建系统
  临时 fixture，没有用真实 HOME 制造证据，也没有实际回收系统路径。
- **共同修复**：SafetyEngine 三个解析入口与 WhitelistStore 共用有系统 link budget 的
  SymbolicLinkResolver。存在目标走 libc；缺失目标仍逐组件解析整条链与相对目标，循环、
  权限或 I/O 错误保留 typed failure。bundle override 使用三态证据，只有 unprotected
  才满足资格。ScanPathIdentity 统一用户根存储、根规划、估算、终态证据、Tree 状态和
  preflight overlap 的词法身份；物理所有权仍合并 filesystem alias，公开政策身份保留
  所选命名空间。移除 DuplicateScreen 拼接 `/private` 的局部补丁，未更改 TCC 或安全
  规则资产。BundleProtectionMatcher 一次编译 wildcard，保持原规则与优先级，并由
  编译器验证 Sendable，移除原 unchecked 声明。
- **聚焦证据（C2）**：多跳 dangling 与后代、libc/custom missing-component 两条循环路径、
  actor 后续可用、相对 `..` 与非 ASCII 目标、权限来源、shipped wildcard 原语义 oracle
  均通过。临时目录中的真实 producer 验证物理根从扫描终态到 Tree/预检查询保留 TCC
  证据；随后显式逻辑根扫描保留当前进程临时目录豁免，并清除旧 revision 的证据。
  独立生产 API 复验得到 dangling forbid、cycle false 终态、Duplicate 0 groups / 1 TCC issue。
- **性能证据**：相同 seeds、159 vendors、5,000 paths；每 revision 三个交错进程、一次
  warmup 后五次测量，15 样本中位数为 `519.550 ms → 210.951 ms`（2.463×），safe checksum
  全部为 9,942。只说明安全评估热点改善，不宣称真实 UI 或整轮扫描同比加速。最终全测
  曾发现新增 URL 身份适配使两万行 prune plan 在并行负载下超过原 2 秒预算；保留红日志，
  把字符串消费点改成纯字符串处理，并在空的不可变证据索引上省去无用查询。71 项相关
  聚焦测试与最终全测的原性能断言均通过，没有放宽预算或更改断言。
- **最终验证（C3）**：九包 full native SwiftPM tests 均 exit 0，AppUI 另有 11 项 Swift
  Testing 通过；目标 Debug 构建、actual App strict/deep codesign 与 diff check 通过。
  491 个源码、资源和测试文件在最终验证期间指纹一致。Release 静态合同检查通过。
  验证命令、红日志、清单、性能原样本与探针见本地
  `build/root-fix-20261009/verification-summary.json` 及关联文件。
- **剩余边界**：未做运行交互验收，macOS 13.5/Intel 运行验证仍缺。Apple 公证凭据预检
  返回 HTTP 403，服务报告团队必要协议缺失或过期；账号持有人处理后才可完成公证。
  本地签名不能代替 Apple Accepted，正式发布状态以最终 DMG provenance、公证结果和
  GitHub Release 为准。版本按现有脚本以提交计数生成递增 build，不修改工程版本配置。
  长期合同见 PITFALLS 第 23 节。
