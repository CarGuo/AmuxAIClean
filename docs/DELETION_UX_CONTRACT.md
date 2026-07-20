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
8. **零提交拒绝不得占用窗口**：预提交安全、身份或恢复账本校验失败时，删除能力继续
   fail-closed，但说明只能作为当前页面内的非模态 typed notice；不得使用 sheet/alert 阻塞浏览、
   调整选择、重新扫描或发起新的审阅。只有已经跨过系统提交边界并取得 receipt 的操作，才可进入
   结果 presentation。

**v2026.07.20 生产恢复域隔离规则**：生产删除入口必须显式构造 production recovery domain；
测试、Preview 和 scripted pipeline 必须拥有 UUID 隔离的临时 ledger、completion journal 与 Undo
store。禁止通过运行时猜测 XCTest 环境，也禁止任一测试默认访问
`~/Library/Application Support/AmuxAIClean`。这三类持久状态必须作为同一个 dependency domain
注入，不能只替换其中一个后让其余部分回落到生产 singleton。任何允许注入
`DeletionPipeline` 的 View / Preview / scripted 入口，都必须同时要求显式 `UndoHistoryStore`；
生产 composition root 明确传 `.shared`，测试明确传临时 store。注入 pipeline 时不得在后台另行
构造 production pipeline 或启动 production recovery prewarm。组合根的嵌套导航页面同样必须
透传这对 owner；即使页面只读取/恢复历史而不提交删除，也不得在内部重新选择 `.shared`。

**v2026.07.20 WAL 跨重启身份规则**：Darwin `st_dev` 是本次挂载实例编号，不是跨重启稳定的
卷身份。读取持久化 marker/bootstrap 时必须先按原始字段验证 checksum，再证明同一 generation
内的 marker、stage、reserve 与 destination identity 属于同一个 persisted-device domain；只有在
固定父目录 descriptor、inode、birth time、generation 与文件类型全部一致后，才允许把该 domain
原子 rebase 到本次挂载编号。rebase 之后的 marker/stage/path/descriptor CAS 仍必须完整比较当前
`st_dev`，禁止把“忽略 device”扩散到运行期安全判定。

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
    ↓ 真实调用已交给系统后
DeletionSubmissionReceipt
    ↓ 已确认终态 / 系统回调待确认
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

**v2026.07.17 精确提交边界**：队列等待、Duplicate 全量 rehash、retained-copy 复核、claim 前后
fence 和持久 ledger claim 都仍是 pre-submit；此时取消必须阻止系统调用并释放可安全释放的未提交
attempt。只有上述步骤全部通过后，串行 worker 才能在第一次真实
`NSWorkspace.recycle` 调用的紧邻位置同步记录/发布 `.submittingToTrash`。这个同步 worker 记录是
导航和取消策略的权威边界；异步 UI phase 可能滞后，不能反向充当授权或提交证明。一旦跨界，
页面离开不得取消并遗弃执行 owner，必须继续跟踪到 typed completed/pending/unknown/blocked/failed。

**v2026.07.16 异步回调边界**：调用已交给 `NSWorkspace.recycle` 后仍可能长期不回调。
应用等待窗口到期时必须返回独立 `pending` 状态，绝不能伪造成成功或失败，也不能对未知
路径自动重试。当前已提交但未知的路径写入 `pendingPaths`；为避免扩大未知面而停止的后续
路径写入 `notSubmittedPaths`。receipt 只记录真正跨过系统提交边界的路径，因此它可以是
授权集合的严格子集，但 outcome 必须无重叠、无遗漏地证明已提交与未提交的完整分区。
只有系统确认的 moved pair 才能写 Undo、更新统计或从 UI 移除。若迟到回调随后返回
confirmed moved pair，执行层必须 exactly-once 补写 Undo 并广播模型失效；原结果页仍保留
pending 语义，最终通过重新扫描收敛真实状态。

### 3.5 v2026.07.16 持久化提交身份与重启恢复

`NSWorkspace.recycle` 的同步返回、异步 callback 和 App 生命周期互不等价。为避免回调迟到、
诊断重试、另一个窗口或重启后的请求对同一路径重复提交，真实 Trash 提交必须遵守以下合同：

- 整批先以一个 parent `operationID` 原子 reserve；进程内 active registry 在所有普通、迟到
  callback 和外层终态路径上恰好一次 unregister。新建 pipeline 的 reconcile 必须跳过该
  active operation 的全部 sibling，不能因某个源路径已被系统移动或替换而清除它。
- 每次进入系统 API 的 `recycleOnce` 使用唯一 `attemptID`。claim、API-return、callback、
  retry-ready 和 finish 都必须同时匹配 parent operation 与当前 attempt；旧、重复或迟到事件
  不得推进或清除新一轮 retry。
- ledger 以独立稳定 lock inode 的 `flock` 串行化跨实例 read-modify-write，并为每条路径冻结
  `lstat(device, inode, fileType)`；JSON 的 atomic replace 本身不等于跨进程互斥。
- 每条持久记录必须冻结 owner 进程身份 `(pid, kernelStartSeconds, kernelStartMicroseconds)`；PID
  单独不是所有权能力。owner liveness 必须在同一个 `flock` 事务内查询：同 PID 不同 kernel
  start 视为旧 owner 已退出，查询失败视为 `unavailable` 并保持原记录、拒绝新提交。进程内
  active registry 只封闭 register→persist 窗口，不能代替跨进程 owner 身份。
- 一旦 `claim` 把 attempt 推进到 `submissionUnknown` / `callbackPending`，owner 退出、源路径缺失
  或 inode 被替换都不能证明 AppKit 没有接受请求；该 generation 必须继续保持 pending，不得
  自动转 fresh review 或重试。
- 只有 inactive `reserved` 才能证明尚未 claim：旧审阅转为 `needsFreshReview`；
  `callbackObserved` / `retryReady` 已有精确 attempt 的权威 callback，可按终态清除。仅 claim 前
  发现的缺失/替换进入 durable fresh-review tombstone。原 authorization、相同
  `DeletionSnapshotIdentity(sessionID, revision, categoryID)`、裸路径重试和缺少 identity 的
  legacy/debug 请求都不能清除此 tombstone。
- 只有用户看到新扫描结果后形成的 typed snapshot 可以在同一个 flock 事务中“清除 tombstone
  + reserve 新 operation”：同 session 必须是更高 revision；新 session 表示新的扫描 lineage。
  无旧 identity 的 legacy ledger 无法证明新旧关系，保持 fail-closed。

生产 identity 来源必须是结果集而非点击事件：Main/Tree/Large Files 使用 ScanCoordinator
session+store revision；Duplicate、Workflow 使用各自 scan evidence；Smart Care 在预览出现前
冻结其 ScanCoordinator session 与 summary revision；Brew/Uninstall 每次重新扫描候选时生成
稳定 session，并在该结果集内保持单调 revision。禁止在确认按钮中临时 `UUID()` 冒充新审阅。

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
- 只要目标仍属于 `strictOverrideEligible`，确认页就必须提供明确的“强制移到废纸篓”主操作；
  不得只给关闭按钮，也不得把该能力藏到失败结果页；
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
- **v2026.07.19 性能防回归**：Professional 的肯定操作必须在确认回调内同步领取一次性
  submission 并立即启动执行，不能等待 confirmation sheet 的 `onDismiss`。`onDismiss` 只作为
  后续 confirmation / typed notice / result presentation 的退场屏障；否则 Tree/layout 负载会被
  串到第一次 `NSWorkspace.recycle` 之前，形成数秒“点了删除却没开始”的假 I/O 延迟。必须用
  无路径结构化日志分别记录 confirm-to-submit、recycle、model sync 与 result-eligible 耗时。
- **v2026.07.20 回执优先合同**：执行层返回 typed completion 与
  `DeletionSubmissionReceipt` 后，结果页即具备呈现资格；扫描快照、Tree cache、选中项、统计和
  历史记录的模型同步属于回执后的 reconciliation，不能阻塞结果页。若 confirmation sheet 尚未
  退场，只允许等待该唯一 presentation 屏障；不得等待 prune、排序、全局 Tree projection 或缓存
  析构。结构化日志必须让 `result_eligible` 与 `model_sync_completed` 成为两个可独立观测的阶段。

## 6. 结果页

结果页只显示已经取得 `DeletionSubmissionReceipt` 后的：

- `trashed`；
- `failed`（系统/IO 返回）；
- `pending`（系统已接受请求但尚未返回最终结果；不得立即重试，稍后重新扫描确认）；
- `not-submitted`（前一批仍待确认，因此后续路径主动停止提交）；
- `blocked`（执行边界的最终重验在提交前发现新增风险；这类路径不得计入 receipt 的 submitted set）；
- `skipped`（用户在授权中明确选择跳过，或执行层返回路径变化）。

恢复动作按 typed reason 生成：

- 系统权限 → 正确的设置入口或 Finder 定位；
- 运行中 App → 返回 coordinator 重新规划；
- 扫描发生变化 → 重新预检；
- 新增 hard-forbid → 只解释，绝不提供 force；
- 实际 recycle 失败 → 重试同一精确 intent 或查看技术详情。

结果页不得再承担 vendor override、首次强制授权或“关闭即视为已删除”。没有 receipt 时，结果页在类型层和 UI 层都必须不可构造。

结果页显示也不得反向依赖删除后的列表/Tree 已完成重算。receipt 是“系统已完成哪些提交”的
权威证据，模型同步只负责让底层页面最终与 receipt 收敛；同步失败或变慢时应保留日志和继续修复
模型链路，不能把已经取得的结果再次扣留十几秒。

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

**v2026.07.17 Duplicate 内容身份合同**：`.full` 只是展示可靠度，不能单独铸造删除能力。
扫描结果必须从实际 hash 的同一个 `O_NOFOLLOW` 文件描述符冻结完整 SHA256、逻辑大小以及
`device/inode/type/mtime/ctime`，并在路径层用 `lstat` 证明仍指向同一对象。删除 intent 必须绑定
精确待移动项和至少一份明确保留项；最终执行在持久 ledger reserve 之后、任何 AppKit claim 之前，
在后台重新完整 hash 两类文件。任一身份、内容、读取或 retained-copy 变化都返回 typed pre-submit
block，释放尚未 claim 的 reservation，产生零次 `NSWorkspace.recycle`、零 receipt、零结果页。
重验完成后，每个 batch 和 fallback 单项重试都必须在实际 AppKit claim 的邻接边界廉价重验：
本次 targets 对照 full-hash descriptor 冻结的 identity，retained survivor 对照同一组
`device/inode/type/size/mtime/ctime`；ledger claim 仍独立比较 reservation identity。调用方取消通过
显式线程安全 token 传入每个 GCD read chunk，并在 claim 前后再次检查，不能依赖 GCD 上下文中的
`Task.isCancelled`。claim 前任一失败释放/终止未提交 reservation，零 recycle、零 receipt。
`.submittingToTrash` 只能由执行层在上述 claim/fence 全部成功后、紧邻实际 AppKit 调用时发布；
full-hash “完成”事件仍是 pre-submit，不能把 UI 提前推进到不可取消状态。Duplicate 页面离开时
必须读取同步 execution-boundary 记录：边界前请求 verifier 取消，边界后保留 transaction owner。

### 7.1 Simulator managed-resource 非 Trash 例外

在 Workflow 清理候选中，唯一允许不走 `TrashPipeline` 的系统托管资源是封闭的
`ManagedUninstallRecipe.simulatorDevice` 与 `.simulatorRuntime`。DerivedData、Archives、
Device Support、Caches 等文件项仍必须移到废纸篓；泛化 command line 不能成为删除通道，
CoreSimulator 挂载卷也不得作为文件候选。托管卸载必须明确显示“卸载、不可从废纸篓恢复”，
使用独立 typed receipt/result，绝不能伪装成 Trash。

复核必须冻结 `scanSessionID`、`scanRevision` 与完整 item identity；执行前再次拒绝 stale
revision。所有进度事件携带同一 `sourceIntent`，迟到终态只有在当前投影仍属于同
session/revision 且完整 item 相等时才能移除 row；ledger 对账可继续，但旧事件不得污染新扫描结果。

单一 sheet 必须收敛 `preparing → review → executing → finished/blocked`；逐项区分
`pending / validating / submitted / running / stalled / succeeded / failed / unknown / blocked /
skipped`。`stalled/unknown` 不是失败：唯一 monitor 继续等待权威终态并允许迟到对账；状态未知
时停止提交后续项，后续项保持未提交。停止按钮只阻止后续提交，绝不强杀正在执行的
CoreSimulator 事务；receipt 只包含真实跨过提交屏障的项。

持久 managed ledger 使用独立 lock inode + `flock`，并冻结 owner PID+kernel start、唯一
attemptID 与产生本次复核的 scan session/revision。死亡 owner 的 stale `reserved` 只能由新
session 或同 session 更高 revision 在同一事务中清除；点击时生成的 operation UUID 不构成新复核。
`reserved → submitted → terminal` 的每次 mutation/clear 都必须匹配 kind、identifier、owner
（适用时）和 expected attempt；owner 查询失败、submitted 未知、authority probe 失败均
fail closed。旧 schema 使用稳定 migration identity，不能绕过上述单调复核边界。

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
12. pending ledger 覆盖跨实例原子 reserve、active-operation 全组跳过、唯一 attemptID 的 ABA
    防护、restart stage 分类、缺失/替换后的 durable fresh-review tombstone，以及旧 token 拒绝、
    新 revision 原子清除并 reserve；测试只能使用临时 fixture 与 scripted recycle closure。
13. 所有生产 intent producer 必须证明 review identity 来自稳定扫描 session + revision；同一次
    结果集的重复点击不得生成随机 session，旧异步扫描结果不得覆盖新 identity。
14. Trash ledger 覆盖 live other-process owner、PID reuse、owner probe unavailable，以及 claimed
    后路径缺失/替换仍不重提。
15. Simulator ledger 覆盖跨实例 reserve、owner PID+kernel start、attempt CAS/ABA、
    submitted/terminal/authority-absence 分类；Workflow 覆盖 stale revision 零提交、迟到终态不污染
    同 hitID 的新 revision、unknown 不伪装失败，以及 managed 成功不触发无关 card loading。
16. Duplicate 覆盖：缺少 typed full-hash/identity 时不可选；目标或保留副本在确认后发生内容/
    身份变化时 reservation 被释放、claim 次数为 0；最终证明必须与授权路径精确同序且不可扩张；
    GCD full-hash 中途取消、batch claim 与 fallback single retry 的 target/retained identity fence
    都必须断言 workspace 调用次数为 0；还要覆盖取消与提交竞争，证明 `.submittingToTrash` 只在
    真实 workspace 调用的邻接边界出现，边界前离开可取消、边界后离开保留 owner（测试仅使用
    临时 fixture 与 scripted workspace closure）。
17. 纯 pre-submit rejection 在 Main、Brew、Duplicate、Uninstall、Workflow 五个入口只能投影为
    非模态 notice；它不属于 active sheet/transaction，不能构造 receipt/result，也不能阻止后续
    浏览和新审阅。反例测试必须证明已有提交或部分提交仍进入 receipt-bearing result。
18. 每个默认测试 pipeline 必须证明 ledger、completion journal、Undo store 都位于同一 UUID 临时
    根且不在用户 Application Support；两个实例不得共享恢复域。所有会写 Undo 的 coordinator /
    ViewModel 测试也必须显式注入临时 store，禁止依赖 `.shared` 默认值。
19. 所有 public/scripted View 的 pipeline 注入与 Undo owner 必须成对；源码合同测试必须拒绝 View
    内部硬编码 `undoHistoryStore: .shared`。production ledger/journal 的路径型 convenience init
    只能由其 `shared` owner 调用；测试初始化必须显式提供临时 URL 和独立 active registry。

对应测试职责应落在：

- `DeletionUXPolicyTests.swift`：plan 分类、mode route 和 typed explanation；
- `ProfessionalToolDeletionFlowTests.swift`：专业入口统一、简洁/严格确认；
- `TrashActionCoordinatorTests.swift`：authorization、最终重验、恰好一次提交；
- `TrashPipelineDryRunTests.swift`：诊断 dry-run 与生产真实提交隔离；
- `TrashPendingOperationLedgerTests.swift`：跨实例 ledger、attempt generation、restart recovery 与
  typed fresh-review capability；
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

> **v2026.07.17 当前证据**：Duplicate 最终 rehash、同步提交边界、页面离开策略以及
> Uninstaller typed execution progress 已完成实现与静态审阅，但遵循“先完整落地、后统一测试”，
> 新增测试、九包全测、Debug build 和真实 App 均未运行；这些新增边界当前仅为 C1，矩阵中的
> C2/C3/C4 复选框保持未勾选。

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
