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
