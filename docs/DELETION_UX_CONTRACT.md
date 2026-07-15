# 删除交互统一合同

> 本合同定义“用户从任意入口发起删除”直到“结果呈现”的唯一产品流程。
> “统一”指同一个 coordinator、同一套类型化安全判定与同一执行边界，不是所有模式共用一张巨大弹窗。
> 底层仍只允许 `TrashPipeline → NSWorkspace.recycle`，本文不引入永久删除、root helper 或 `unlink`。

## 1. 核心原则

1. **统一状态机，按模式呈现**：所有入口必须提交给同一个 `DeletionInteractionCoordinator`；Normal 与 Professional 只在 presentation route 上不同，安全判定、授权铸造、最终重验和执行不得分叉。
2. **Normal 负责详细审阅，Professional 负责高效操作**：Normal 展示完整候选、风险和运行中 App 处理；Professional 的普通删除只显示简洁“是否移到废纸篓”，遇到可覆盖风险时才升级为严格强制确认。
3. **预检不是执行结果**：用户尚未确认和实际提交前，不得展示 `Cleanup Failed 0/N`。预检只能生成 confirmation plan 或 typed explanation。
4. **结果页不承担首次授权**：`OperationResultSheet` 只能展示已经取得真实 submission receipt 的 moved / failed / blocked / skipped；不能先显示失败，再让用户从结果页寻找“强制删除”。
5. **确认上下文冻结，安全证据单调增加**：用户确认时冻结精确路径、原因、扫描 session 和运行中 App；执行前重新评估，新的风险只能增加，不能因旧快照而消失。
6. **强制是“严格尝试”，不是权限承诺**：专业模式允许覆盖的是产品风险策略，不会授予 macOS 权限，也不承诺 `NSWorkspace.recycle` 一定成功。
7. **肯定操作必须有真实效果**：Professional 普通确认中的“是/移到废纸篓”必须进入真实提交；不得隐式切换 dry-run，也不得在关闭确认页时假装完成。

## 2. 唯一状态机与呈现路由

```text
DeletionIntent
    ↓
DeletionInteractionCoordinator.prepare
    ↓
DeletionConfirmationPlan
  ├─ normalItems
  ├─ strictOverrideItems
  ├─ nonBypassableItems
  ├─ runningAppConflicts
  └─ changedSinceScan
    ↓
DeletionPresentationRoute
  ├─ NormalDetailedReview
  ├─ ProfessionalSimpleConfirmation
  ├─ ProfessionalStrictConfirmation
  ├─ RunningAppDecision
  └─ TypedBlockExplanation
    ↓ 用户授权或返回调整选择
ExecutionAuthorization
    ↓ 执行前最终重验
TrashPipeline → NSWorkspace.recycle
    ↓ 真实调用被接受后
DeletionSubmissionReceipt
    ↓ 执行终态
TrashOutcome
    ↓
OperationResultSheet(receipt, payload)
```

所有 View 只提交 `DeletionIntent`，不能自行：

- 决定某个 forbid 是否可覆盖；
- 根据模式绕过 coordinator 或另建一套安全规则；
- 直接把 preflight rejection 包装成结果；
- 为同类文件删除另造 sheet/alert；
- 调用空心 `.force` 后假装使用了另一条能力；
- 把关闭 sheet、授权成功或开始异步任务当成删除成功。

## 3. 类型化输入与输出

### 3.1 DeletionIntent

至少冻结：

- 标准化后的原始路径集合；
- 入口 origin；
- scan session / snapshot revision；
- 当时的候选元数据和安全评估；
- 用户模式（Normal / Professional）；
- 运行中 App 候选信息。

### 3.2 DeletionConfirmationPlan

必须把每条路径互斥地归入：

- `normal`：普通确认后可提交；
- `strictOverrideEligible(reason)`：Professional 可进行严格尝试；
- `nonBypassable(reason)`：永不允许提交；
- `runningConflict`：需要跳过、退出或明确尝试；
- `changedSinceScan`：扫描身份已变化，要求重新预检。

`DeletionConfirmationPlan` 是 presentation 的唯一输入。View 不得从原始 `SafetyVerdict`、字符串错误或布尔 `force` 自行推导 route。

### 3.3 ExecutionAuthorization

授权必须由生产预检铸造，且绑定：

- 精确路径及顺序身份；
- 精确 override reason；
- scan/session revision；
- 用户确认方式、确认时间和严格确认凭证；
- 运行中 App 的逐项选择；
- 执行前重新评估结果。

禁止使用裸 `[String]` 或 `Bool force` 表达专业覆盖能力。

### 3.4 DeletionSubmissionReceipt

receipt 只能在以下事实同时成立后创建：

- 用户授权已通过；
- 最终重验已通过；
- 非 dry-run 的真实删除请求已经交给 `TrashPipeline`，并实际进入 `NSWorkspace.recycle` 提交边界。

receipt 至少绑定 intent revision、精确提交路径、提交时间和执行 request id。授权成功、开始加载动画、sheet 被 dismiss 或生成 Task 都不等于 receipt。

`OperationResultPayload` 必须引用 receipt；没有 receipt 的预检拒绝、用户取消、路径变化或 hard-forbid 只能进入对应 presentation route，不能进入结果页。

## 4. 专业模式覆盖分级

### 4.1 永不可覆盖

- `/`、HOME 本身、`~/Library`、`~/Documents`、`~/Desktop`、`~/Downloads` 等整根；
- `/System`、系统卷、SIP/immutable 结构；
- HOME 外路径；
- 相对路径、空路径、`..`、路径解析后越界；
- symlink 解析后指向删除范围外；
- App 自身或其它明确 hard-forbid 身份边界；
- 预检取消、路径身份在确认后发生不可解释变化。

这些是能力/身份边界，不是用户风险偏好。

### 4.2 可进入严格覆盖

- `vendorPathRule`：SDK、toolchain、共享 vendor 路径；
- 被产品策略保护、但仍位于用户删除范围内的可逆风险项；
- `scanIncomplete`：只有在选中目标经过独立路径级重验，且用户明确接受“内容/大小未完整检查”后；
- 运行中 App 关联项：只有在用户明确选择仍尝试，并理解空间可能不会立即释放后。

敏感凭证、inside-app-bundle、用户白名单等是否开放必须由产品显式逐类决定，禁止使用字符串包含判断自动开放。

### 4.3 OS 权限失败

- TCC、POSIX owner/mode、ACL、immutable flag 必须分别记录。
- “扫描时无法枚举内容”不等于“父目录不能移动该目标”。Professional 可以在独立重验后提供“严格尝试移到废纸篓”。
- 如果父目录确实不可写或系统返回 EACCES/EPERM，只展示准确原因和可行动作；不得统一伪称“请授予 Full Disk Access”。
- 当前无 root helper，不能承诺绕过 POSIX/ACL/SIP。

## 5. 模式感知的统一呈现合同

### 5.1 Normal：详细安全审阅

Normal 使用 `NormalDetailedReview`，展示：

- 路径、大小、文件数和来源摘要；
- normal / strict-eligible / non-bypassable 分区；
- 运行中 App 列表及“跳过 / 请求退出 / 仍尝试 / 取消”；
- 扫描不完整的范围、精确路径和真实原因；
- 将要执行的操作明确为“移到废纸篓”。

Normal 不自动获得 Professional 严格覆盖能力。若用户需要覆盖产品风险策略，应明确切换到 Professional 后重新生成 plan，不能在 Normal 结果页临时出现 force。

### 5.2 Professional：普通删除的简洁确认

当 plan 只含 `normalItems`，且运行中冲突已解决时，必须使用 `ProfessionalSimpleConfirmation`：

- 只展示简洁的标题、项目数、总大小和“是否移到废纸篓”；
- 主操作是“是/移到废纸篓”，取消操作是“否/取消”；
- 肯定操作立即生成授权并进入真实提交，不能落到 preview、dry-run 或空实现；
- 不展示 Normal 的巨大候选列表、分区说明或诊断开关；
- 如提供“查看详情”，只能打开只读详情，不改变主确认的语义和提交路径。

### 5.3 Professional：严格强制确认

当 plan 含一个或多个 `strictOverrideItems` 时，必须直接升级为 `ProfessionalStrictConfirmation`，不能先显示失败页：

- 展示精确目标、可覆盖原因、不可恢复的业务影响和仍受 macOS 权限约束的事实；
- 要求输入与本次 intent 绑定的确认词或等价严格凭证；
- 明确区分“严格尝试移到废纸篓”与“永久删除”；
- normal siblings 可以与本次严格授权一起提交，但授权必须绑定完整精确路径集；
- 最终重验新增的风险必须重新规划，旧确认不得沿用。

### 5.4 hard-forbid、路径变化与不可提交项

含 `nonBypassableItems` 的批次不得静默跳过、部分执行或显示假结果：

- route 为 `TypedBlockExplanation`，展示精确路径、typed reason 和可行动作；
- 不提供 force，也不生成 `OperationResultPayload`；
- 用户必须返回调整选择并产生新的 intent，才能提交剩余项目；
- `changedSinceScan` 必须先重新预检；身份无法证明一致时按 non-bypassable 处理。

### 5.5 运行中 App 决策

`RunningAppDecision` 属于同一个 coordinator，可作为 Normal 详细审阅的一部分，也可作为 Professional 提交前的短步骤。四种选择在所有入口语义一致：

- 跳过运行中项；
- 请求退出相关 App，成功后重新预检；
- 明确接受风险并仍尝试；
- 取消整次操作。

任何选择都必须写入 `ExecutionAuthorization`，不能由 View 在提交前临时过滤路径。

### 5.6 dry-run 边界与 presentation 交接

- Release 的任何模式都不显示 dry-run UI。
- Professional 的普通和严格确认在任何构建中都不显示 dry-run；肯定操作就是实际移到废纸篓。
- Debug 诊断预览如保留，只能位于 Normal 的明确诊断路径，且与正式确认状态隔离。
- 同一 intent 只能有一个活动 presentation route；sheet 关闭、下一 route 和结果页之间必须确定性交接，不能 sibling sheet 竞争。

## 6. 结果页

结果页只显示已经取得 `DeletionSubmissionReceipt` 后的：

- `trashed`；
- `failed`（系统/IO 返回）；
- `blocked`（执行边界的最终重验在提交前发现新增风险；这类路径不得计入 receipt 的 submitted set）；
- `skipped`（用户在授权中明确选择跳过，或执行层返回路径变化）。

恢复动作按 typed reason 生成：

- 系统权限 → 正确的设置入口或 Finder 定位；
- 运行中 App → 返回 coordinator 重新规划；
- 扫描发生变化 → 重新预检；
- 新增 hard-forbid → 只解释，绝不提供 force；
- 实际 recycle 失败 → 重试同一精确 intent 或查看技术详情。

结果页不得再承担 vendor override、首次强制授权或“关闭即视为已删除”。没有 receipt 时，结果页在类型层和 UI 层都必须不可构造。

## 7. 逐入口验收矩阵

所有真实文件删除入口必须提交 `DeletionIntent` 给同一个 coordinator。下表中的 C2/C3/C4 需要分别留证，不能以共享底层调用替代入口验收。

| 入口 | 必须覆盖的触发方式 | Normal 期望 | Professional 期望 | 安全/强制期望 | C2 | C3 | C4 |
|---|---|---|---|---|---|---|---|
| Main List | 行图标、右键、Delete 键、底部批量 | 详细审阅 | 普通简洁确认；有 eligible 风险时严格确认 | hard-forbid 仅解释；肯定操作恰好一次真实提交 | ☐ | ☐ | ☐ |
| Tree | 行图标、右键、Delete 键、批量 | 详细审阅 | 普通简洁确认；有 eligible 风险时严格确认 | 锁只属于真实受限节点；parent 不得继承伪锁 | ☐ | ☐ | ☐ |
| Large Files | 单行、右键、批量 | 详细审阅 | 简洁/严格按 plan 路由 | 不得自建旧 confirmation sheet | ☐ | ☐ | ☐ |
| Stash | 单行、右键、批量/全部 | 详细审阅 | 简洁/严格按 plan 路由 | 关闭 presentation 不得提交或伪报成功 | ☐ | ☐ | ☐ |
| Smart Care | 清理选中项、全部清理 | 详细审阅 | 简洁/严格按 plan 路由 | 运行中 App 决策与其它入口一致 | ☐ | ☐ | ☐ |
| Brew | 单项、批量 | 详细审阅 | 简洁/严格按 plan 路由 | 文件废纸篓操作不得使用工具私有 sheet | ☐ | ☐ | ☐ |
| Duplicate | 单项、批量 | 详细审阅 | 简洁/严格按 plan 路由 | 精确路径集与保留项必须冻结 | ☐ | ☐ | ☐ |
| Uninstall | App 残留文件 | 详细审阅 | 简洁/严格按 plan 路由 | App bundle/残留必须分别判定，不得扩大删除范围 | ☐ | ☐ | ☐ |
| Workflow 文件删除 | 单项、批量 | 详细审阅 | 简洁/严格按 plan 路由 | 只允许 Trash 类型节点进入本合同 | ☐ | ☐ | ☐ |

纯 command 操作和 Simulator destructive command 不是文件废纸篓操作，可使用独立的 typed destructive coordinator；必须明确标注操作类型，不得复用 `OperationResultSheet` 伪装成 Trash，也不得借此绕过文件删除安全边界。

矩阵每一行至少验证：

1. 所有触发方式生成同语义 intent；
2. mode 和 plan 只影响 presentation route，不影响安全判定与执行边界；
3. 取消产生零次提交，肯定操作产生恰好一次提交；
4. eligible strict 直接进入严格确认，hard-forbid 只进入 typed explanation；
5. receipt 与最终结果能追溯到同一 intent revision。

## 8. 必须存在的自动化测试

1. 所有入口只提交 `DeletionIntent`，不直接构造 confirmation/result 或调用执行层。
2. mode routing 覆盖 Normal 详细审阅、Professional 普通简洁确认、Professional 严格确认、typed block explanation。
3. Professional 普通确认：肯定操作恰好一次 `dryRun == false` 的真实提交；取消与关闭均为零次提交。
4. Professional eligible strict：直接生成 strict plan 和严格确认，不先出现 `Cleanup Failed`；缺少/错误确认凭证不得提交。
5. preflight rejection、hard-forbid、路径变化不生成 `OperationResultPayload` 或 receipt。
6. Android SDK 等 vendor path 只在路径级资格成立时生成 strict override；无关 sibling 的 incomplete 证据不能污染目标路径。
7. scan-incomplete override 绑定精确路径，最终重验仍拒绝 root/system/outside-home/`..`/symlink 越界。
8. 运行中 App 的 skip/quit/attempt/cancel 在所有入口语义一致，并进入 authorization。
9. receipt 只在真实 `NSWorkspace.recycle` 提交边界创建；没有 receipt 时 `OperationResultSheet` 不可呈现。
10. Release 所有入口不存在 dry-run UI；Professional 在 Debug/Release 都不存在 dry-run。
11. presentation dismiss/route handoff 不丢失肯定操作，也不会重复提交或提前显示结果。

对应测试职责应落在：

- `DeletionUXPolicyTests.swift`：plan 分类、mode route 和 typed explanation；
- `ProfessionalToolDeletionFlowTests.swift`：专业入口统一、简洁/严格确认；
- `TrashActionCoordinatorTests.swift`：authorization、最终重验、恰好一次提交；
- `TrashPipelineDryRunTests.swift`：诊断 dry-run 与生产真实提交隔离；
- `PerformDeleteIntegrationTests.swift`：presentation handoff、receipt 与结果页门禁；
- 逐入口 integration/UI regression：验收矩阵中每一种触发方式。

## 9. C1–C5 证据边界

| 等级 | 本合同允许的证据 | 可以声称 | 不可以声称 |
|---|---|---|---|
| C1 | 源码映射、静态检查、合同/文档审计 | 入口与违规点已识别，合同已写入 | 功能已修复、按钮可用、真实删除成功 |
| C2 | 聚焦行为测试，使用 temp fixture、spy pipeline 或 production policy | route、授权、提交次数和 receipt 门禁在测试场景成立 | 真实 UI 已点击、真实 App 无卡顿/无 sheet 竞争 |
| C3 | 相关包全测、目标构建、C2 全部通过 | 编译与包级主链路闭合 | 用户看到的交互正确、最终 DMG 正确 |
| C4 | 单次持续运行 App，写明入口、fixture、操作步骤、观察点；用 `NSTemporaryDirectory()` 真删 fixture，并保存截图/日志/receipt | 对应矩阵入口的真实交互与真实移到废纸篓已验收 | 未实际操作的其它入口也已验收 |
| C5 | 最终签名、公证并 staple 的 DMG，在安装产物上复验 Release UI、无 dry-run、temp fixture 删除和 receipt/result | 最终发布产物满足本合同已覆盖的场景 | 未覆盖的 OS 权限、运行中 App 或异常路径均无风险 |

证据约束：

- 扫描字符串、确认源码存在或测试只断言 UI 文案属于 C1，不自动升级为 C2。
- 包测试和 `xcodebuild build` 属于 C3，不能表述为“我已经在 App 里测试过”。
- C4 必须让 App 保持运行并完成明确操作；启动后马上退出不构成运行交互验收。
- C4/C5 真删只能使用预先创建的临时 fixture，禁止用真实 `$HOME` 数据制造证据。
- 任何“统一确认已完成”“Professional 强制删除可用”的结论，至少需要相关矩阵行的 C4；最终 Release 结论还需要 C5。

## 10. 当前已确认的违规点

- `OperationResultSheet.init(onForceDelete:)` 静默丢弃回调；
- `TrashActionCoordinator.Mode.force` 与 normal 等价；
- `TrashPipeline.moveToTrashForce` 与 normal 等价；
- Main/各专业工具把 preflight rejection 直接包装成 `Cleanup Failed`；
- Main 使用 `DeleteSheet`，Brew/Uninstall/Duplicate/Workflow 使用 `ToolTrashConfirmationSheet`，确认状态机和模式路由分裂；
- Professional 仍展示 Normal 风格的大型候选页和 dry-run 控件，且肯定操作没有可证明的真实提交/receipt；
- production 入口没有统一消费现有 confirmation plan / authorization 类型；
- `incompleteScanPaths`、permission denied、TCC 被压成同一个 `accessDeniedPaths`，导致原因和操作错误；
- dismissal、execution 和结果 presentation 缺少 receipt 驱动的确定性交接。

以上项目全部关闭，逐入口矩阵达到对应 C4，且最终发布产物达到 C5 前，不得宣称“统一确认”“Professional 强制删除”或“Release 删除链路”已完成。
