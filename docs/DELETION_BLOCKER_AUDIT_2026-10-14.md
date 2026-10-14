# 2026-10-14 删除阻断审查

## 结论与交付边界

用户试用 1.6.11 后发现，Downloads 中普通 APK、PKG 无法移动到废纸篓。
本轮按用户要求安排三组独立审查：入口/选择资格、请求生命周期、持久化/恢复。
审查基线为 `566118e`；兼容下限继续是 1.6.2，不恢复旧品牌或 1.5.9 迁移。

**1.6.11 是试用失败候选，禁止将其作为本轮通过验收的 Release。**
以下“已修”均指本轮代码，不代表全部真实 UI 入口已验收。
后续按用户“完成、测试、提交和推送”的要求继续修复；本文的最终验证表记录本次实际结果，
不能把局部测试通过写成“所有真实 UI 删除入口全部正常”。

## 问题矩阵

| ID | 优先级 | 触发条件与用户后果 | 状态/证据 |
|---|---|---|---|
| DB-01 | P0 发布阻断 | 写方式打开内部历史文件后只有 ctime 改变，仍被当成内容/身份遭修改；首个回收成功但历史写失败，后续所有入口被恢复闸门拒绝 | 真实日志和只读文件证据；失败回归已转通过；工作树已修 |
| DB-02 | P1 | callback 或取消已终态，Undo/账本一次写失败后，活进程仍被当作该请求 owner；重试和重新扫描仍被挡住 | 工作树已修；精确 attempt/path 交接，以及最后一条持久记录清除后 owner 退休，共 8 项生命周期回归 |
| DB-03 | P1 | 常用缓存、版本化产物等扫描缺口直接改写成 `.forbid/.accessDenied`，Professional 清单在预检前就锁死，无法进入严格确认 | 两类真实临时扫描 fixture 已复现；工作树已修并通过聚焦测试 |
| DB-04 | P1 | 卸载发现一个无关目录读取失败，就禁用整个页面，包括完整且身份可信的候选 | 回归已复现；工作树已修并通过聚焦测试 |
| DB-05 | P1 发布阻断 | 已接受的回执可以写入 32 MiB journal，却无法合并到 8 MiB Undo 历史；旧回执不能清空，所有后续删除被阻断 | 工作树改为系统 SQLite 逐项事务存储；回归覆盖 8,000 项长路径及同一 operation 超过 10,000 项的多批回执 |
| DB-06 | P1 | 空 journal 被当成整个恢复域健康，即使 Undo 已损坏仍允许首次 reserve；系统移动之后才发现不能记录历史，再进入全局阻断 | 工作树已修；每次恢复/提交前在同一持久化队列执行真实 prepare 写事务，不能从缓存状态推断 writer 可用 |
| DB-07 | P1 协议缺口 | 自制 WAL 已保存完整前后版本，但 canonical 写入中断后只剩部分内容；代码无法区分外部写与自身崩溃，永远拒绝自动恢复 | 新写入交由 SQLite；旧 PREPARED 仅在身份、安全元数据和完整前后镜像都可验证、canonical 是新镜像前缀时导入；未知损坏仍明确拒绝 |
| DB-08 | P2 | Tree 行的测量已更新，但选中路径未变化，父层仍持有旧 `isSizePending` 快照；底部操作可能保持禁用 | 回归先红后绿；工作树已修，同一路径更新选择快照，异步资格按 revision 和完整行快照提交，保留滚动与选中路径 |
| DB-09 | P1，正式 App 待复核 | 真实回收后身份仍匹配，但 Undo 用 O_RDONLY 打开废纸篓父目录被 EPERM 拒绝，在 rename 前就退出 | 改用 O_SEARCH 目录锚定；原失败集成现已通过，两次真实回收和两次撤销成功；工作树已修，正式签名 App 与 macOS 13.5 仍待验收 |

真正提交给 AppKit、进程退出后始终没有 callback 的请求另有产品恢复缺口：不能从文件消失或 owner 死亡推断“系统没有接受请求”，但目前也没有人工核对后的消歧流程。它与 DB-02 的“当前进程已经知道请求结束，却没有释放”不同，不能通过自动超时重试一起放开。

## 截图到底触发了什么规则

不是 APK/PKG 扩展名黑名单，也不是根据文件大小计算删除风险。
实际链路是：内部恢复域尚未完成结算 → `reserveAfterRecovery` 拒绝 → 类型化历史错误弹窗。
Professional 的 vendor/扫描缺口严格确认发生在另一层，因此不会覆盖这个内部存储错误。

现场日志证明：2026-10-14 11:33:50（UTC+8）一次操作已经移动 1 项，紧接着记录
`destinationChangedBeforeDescriptorCommit`；后面 2 项、1 项请求都在 `startupRecovery` 被拒绝。
只读核对发现 canonical 内容摘要、inode、owner、mode、字节数、mtime 与记录一致，只有 ctime 改变；文件带有 `com.apple.provenance`。

原检查意图是防止覆盖被替换或并发修改的内部文件，但错误地把“所有 stat 字段必须完全不变”当成“内容与对象不变”的唯一证明。
`git blame` 将 canonical 的 `O_RDWR`＋完整指纹相等检查以及全局恢复闸门追溯至 `875250e`（1.6.2 准备提交）。`944d31b` 移除旧版本兼容没有引入这段校验；`566118e` 只修了启动恢复的同类问题，遗漏了真实写入边界。
开源原始研究 [FFRI ProvenanceChecker](https://github.com/FFRI/ProvenanceChecker) 实测写模式 open 可设置 provenance 元数据；这与现场证据吻合。系统属性设置是原因推断，不冒充独立复现了该机器每一次系统行为。

DB-01 修复在已经打开的同一个 descriptor 上验证：对象身份和安全元数据完全一致；仅 ctime 变化时补做有界内容 SHA256；随后再核对 descriptor 与路径。身份、权限、链接数、flags、大小、mtime 或摘要变化仍拒绝。正常不变路径不增加全量读取；只读恢复不再申请写打开。

## 覆盖范围与强制流程

统一入口枚举共 10 类：scanSelection、tree、largeFiles、stash、smartCare、brew、duplicate、uninstall、workflowFilesystem、storageAnalysis。最终系统回收均由 `TrashPipeline` 提交。

| 判定来源 | 正确处理 |
|---|---|
| 目标身份、系统卷、HOME/Library 整根、越界、路径穿越、hard-forbid | 保留不可覆盖边界；不得用这次修复放宽 |
| vendor 产品风险 | Professional 严格确认，执行前重新验证 |
| 扫描不完整 | 单独携带 typed evidence；Professional 可以先做目标级重验，不能伪装成系统没有删除权限 |
| 运行中应用 | 已有退出/跳过/明确尝试流程 |
| 内部历史/请求所有权 | 修复持久化与终态；不能伪装成文件策略，也不能遗留永久 pending |

`SafetyRejection` 的 17 个拒绝类别并不等于 17 条路径黑名单。此次没有修改规则库或 hard-forbid 列表。

DB-03 保留 Safety 原始判定，在 RowItem、Smart Care 候选合并、子树重扫和复制时独立传播完整性原因。Normal 默认选择和容量分区继续排除缺证据项；Professional 入口交给既有统一预检授权，不由 View 制造 force。

DB-04 只让与所选对象相关的证据决定其资格：选中 App 身份失效或扫描取消仍使本次审阅失效；未选中的不完整候选、无关发现目录错误不应否定健康候选。覆盖不完整的警告仍展示。

DB-02 区分三种事实：活跃 owner、明确结束的 exact attempt/path、整个 operation 已明确终态。单条路径的交接不能释放仍在处理的 sibling。只有同一内核进程身份且本地明确退休，才能把“claim 后但尚未系统调用的取消”从残留 unknown 转为重新审阅；进程死亡本身不具备这个能力。

DB-02 同时修复空 owner 遗留：下一次 reserve/reconcile 成功落盘并清除最后一条已交接记录后，才退休 registry operation。清除前写失败、rename 后 fsync 失败仍保留恢复权，不能只凭单路径交接释放活跃 sibling。

DB-09 的四处源/目标目录锚定统一使用 `O_SEARCH | O_NOFOLLOW | O_CLOEXEC`。恢复只访问已知文件名，不枚举目录；原 `O_RDONLY` 额外申请了读取目录内容的权限。Apple 的 [Darwin 头文件](https://github.com/apple-oss-distributions/xnu/blob/xnu-8792.41.9/bsd/sys/fcntl.h)已定义 `O_SEARCH` 为包含 `O_DIRECTORY` 的目录搜索模式。该模式仍执行系统权限检查；原逐层锚定、设备和身份核验、`RENAME_EXCL` 全部保留，没有失败后改走路径 API 的兜底。

## 本轮持久化根治

不能只增加容量常量、静默丢历史、看到 journal 非空就永久拒绝，也不能仅凭 UI 的 `storageState` 增加一道锁。

Undo 历史使用系统 SQLite，逐项保存完成事实、恢复状态和幂等 receipt；最近 10 次是展示/保留策略，不再要求已接受回执先适配一个更小的 JSON 镜像。短期 completion journal 和 pending ledger 继续使用已有协议；本轮没有改写 AppKit callback 的提交边界或未知请求的判定。

新的请求以真实 prepare 写事务证明 writer 可用；写入故障解决后同进程可以重试。跨进程去重、恢复身份和范围验证仍保留。SQLite 使用 DELETE rollback journal、synchronous EXTRA 与 fullfsync，按其[原子提交恢复协议](https://sqlite.org/atomiccommit.html)负责新历史写入的崩溃恢复。真正无法写入或无法证明旧事实完整时仍会报告存储故障，不伪造成功。

容量复现使用合成 callback 数据，没有实际回收数千个文件。生产一次系统调用按 32 项分批，但正常最终提交按同一 operation 聚合全部 pairs，因此回归同时覆盖长路径字节上限与多 attempt 累加项数上限。

兼容范围仍是 1.6.2+ 当前品牌目录；没有恢复旧品牌自动导入。原始 JSON 字节、身份和完整退役 manifest 先在数据库提交，再通过已验证 fd 写入旧路径；首次创建使用 RENAME_EXCL。旧 writer 见 schema 5 明确拒绝，不能形成两份可写历史。已保存的迁移意图允许精确中断重试，外部替换对象和未知损坏保留原样。系统 SQLite 无新增依赖、工程或构建配置改动。

## 验证记录

原始日志保存在本地 `build/deletion-write-regression-2026-10-14/`：

- `commit-regression-before.log`：旧代码对提交边界 ctime 变化的用例失败。
- `focused-red-green.log`：已证明旧入口与生命周期阻断，不能用“测试都通过”覆盖此证据。
- `focused-audit.log`：88 项聚焦测试，86 项通过；DB-05/DB-06 两项失败，共 5 个失败断言。75 项历史存储测试全部通过，包括内容篡改、恢复 mtime、路径替换保护。
- `real-recycle.log`：两次真实临时 fixture 系统回收与写历史通过，但测试设置了比 pipeline 冻结 scope 更窄的 restore roots，撤销被正确拒绝；该次不能算集成通过。该次测试最后的成功打印是错误的，已改成任一失败即保留域并退出，不能据这行打印认定恢复成功。

### 中途验证及失败证据（2026-10-14 12:28，UTC+8）

| 验证 | 实际结果 |
|---|---|
| ScanKit 全量 558 项 | 1 项 50 ms stdout 截断时限测试失败；原断言不变、隔离重跑通过，保留两个日志 |
| SafetyKit 203 / HeuristicKit 15 / LogKit 50 / BrewKit 60 / FileSearchKit 23 / AIKit 57 / TestHarness 8 | 各包通过 |
| AppUI 全量 1,598 项 XCTest＋11 项 Swift Testing | 两项持久化复现失败，另有一项旧 Smart Care 判据仍期待错误的 forbid；11 项 Swift Testing 通过；真实回收 opt-in 默认跳过 |
| Smart Care 判据修正后，入口与生命周期定向 36 项 | 全部通过；包含 4 项 incomplete 入口/容量、6 项生命周期及 26 项 Smart Care Session |
| 持久化未关闭项单独复测 | 两项仍失败，共 5 个断言；容量用例明确输出 `storeTooLarge(maxBytes: 8388608)` |
| Xcode Debug 目标构建 | `BUILD SUCCEEDED`；未启动本轮 Debug App |
| String Catalog 双语、JSON、`git diff --check` | 通过 |

修正 Smart Care 测试的依据是本次入口合同：Safety 仍应是 `.safe`，独立完整性非空、不可选择、不可默认选择、普通 safeItems 为零。旧的完整性拒绝执行断言继续保留，不将需求改成自动允许不完整项。

以默认生产恢复范围重跑 opt-in 集成后，连续两次真实 `NSWorkspace.recycle`、receipt、历史落盘、journal 清空和下一次 reserve 均通过，但旧目录打开方式使撤销失败。诊断为同一进程 `lstat` 废纸篓目标身份正常，`open(.Trash, O_RDONLY|O_DIRECTORY|O_NOFOLLOW)` 却返回 `EPERM(1)`，被映射成 `trashedItemIdentityUnavailable`。

**12:35（UTC+8）改用 O_SEARCH 后，同一个 opt-in 集成已通过：两次真实系统回收、两条持久历史、两次生产 Undo 恢复、原始字节验证及自建 fixture 清理全部成功。** 75 项 UndoHistoryStore 测试也全部通过，包括原有身份替换、目的地冲突和安全恢复测试。该证据来自测试进程，不等于正式签名 App、最低支持系统或真实 UI 已验收。

该生产代码变更后再次运行目标 Debug 构建，`debug-search-anchor-build.log` 为 `BUILD SUCCEEDED`；未启动 App。目录打开语义另经持久化审查 agent 独立只读复核，没有新增发现。

所有实际回收只操作测试自己创建的 UUID 临时目录内的 APK/PKG 文本 fixture。失败后的两份文件均按记录的 device/inode 和已知字节验证后恢复，再清理自建目录；没有移动用户 Downloads 中的真实文件。最后三次失败的持久化域保留在本地证据目录中，测试没有清空用户历史。

追加日志：`package-*.log`、`package-AppUI-rerun.log`、`final-entry-lifecycle.log`、`persistence-open-findings.log`、`scankit-timing-rerun.log`、`debug-build.log`、`real-recycle-confirmed.log`、`real-recycle-probe.log`、`real-recycle-scope-diagnostic.log`、`undo-search-anchor.log`、`real-recycle-search-anchor.log`、`debug-search-anchor-build.log`。

### 最终自动化验证（2026-10-14 13:31，UTC+8）

| 验证 | 实际结果与日志 |
|---|---|
| 全部 9 包全量测试 | 全部通过。ScanKit 558；SafetyKit 203；HeuristicKit 15；LogKit 50；BrewKit 60；FileSearchKit 23；AIKit 57；TestHarness 8；AppUI 1,622 项 XCTest 调度条目和 11 项 Swift Testing。`final-package-*.log`，AppUI 以 `final-package-AppUI-rerun.log` 为最终结果；真实回收 opt-in 在默认全测中跳过，另行显式执行 |
| 真实回收与 journal 集成 | 29 项通过，含显式开启的真实回收测试。两次系统回收、两条历史、journal 清空、再次 reserve、两次 Undo 及原始字节验证通过，自建临时目录已清理。`final-real-recycle-and-journal.log` |
| 最终目标 Debug 构建 | `BUILD SUCCEEDED`，`final-debug-build.log`；此后仅调整测试存储适配和文档，没有再改生产代码 |
| 发布静态合同 | `final-release-contract.log` 通过 |
| 双语与差异格式 | 变更 String Catalog 条目同时含 en/zh-Hans；JSON 解析和 `git diff --check` 通过 |
| 提交前独立复核 | 持久化审查 agent 再次只读核对最终 source 身份绑定、事务→退役→完成顺序、旧 writer 拒绝、真实 prepare 和失败 rollback，未发现新增阻断级问题 |

存储测试新增或补充覆盖：SQLite 逐项提交与失败事务不可继续、七类迁移/中断/替换场景、8,000 项长路径回执、跨批次累计 10,001 项、空 journal 下损坏历史、ready 后变只读及同进程恢复，以及后台 UI 投影不能覆盖新 revision。Tree 三项回归覆盖同路径快照更新与旧异步资格丢弃。生命周期八项回归保留活跃 sibling 与跨进程未知请求的约束。

全测过程中曾暴露旧测试直接把运行文件当 JSON 解码。仅针对 JSON/WAL 格式的测试改为显式 legacy fixture；生产协议测试使用数据库读取适配，保留历史内容、receipt、幂等和恢复断言。该调整不将 SQLite 退回旧 writer，也不删除失败用例。生产问题还包括迁移期间外部替换、磁盘 `.available` 状态被误信任、同秒旧记录顺序和主线程大批投影，均在最终全测前修复；红色日志保留用于审计。

### 单次持续 C4（2026-10-14 13:33–13:39，UTC+8）

沿用用户对本轮持续交互的明确授权，启动上述 Debug 产物一次，连续操作后正常退出。进程路径经核对来自本轮 DerivedData。没有通过反复启停代替交互。

| 入口/观察点 | 实际观察 |
|---|---|
| Tree 操作列帮助 | `tree.actions.guide` 打开 popover，明确显示“操作示例 · 不涉及真实文件”“示例安装包.pkg”；解释 AI、暂存、删除及严格确认，没有真实操作 |
| SDK vendor 严格确认 | 只读扫描 Android `system-images`，选中一个 SDK 子目录，底部操作进入“覆盖厂商保护”。输入前强制按钮禁用；输入 `DELETE` 后启用；最后点取消 |
| 用户截图中的 APK | Downloads 扫描完成，选中原 APK，底部按钮进入“移到废纸篓？”确认框（160.1 MB），取消 |
| 用户截图中的 PKG | 选中 `flapp-lite.pkg`，通过 Tree Delete 快捷入口进入同一普通确认（91.4 MB），取消 |
| 真实旧历史恢复 | 历史页显示事故发生时 11:33 的那条回收记录为“可恢复”，其余历史仍可见。没有点击恢复来移动真实文件 |
| 启动结算后的只读核对 | 原路径成为 schema 5 manifest；SQLite `quick_check` 为 `ok`；completion journal entries 与 receiptPrunePendingIDs 均为 0；pending ledger records 为 0。`live-app-history-health.json` 只保存数量和结构，不导出历史内容 |

结束前删除了本轮新增的 SDK 自定义扫描快捷项，恢复启动时的普通模式并正常退出。APK、PKG、SDK 和真实废纸篓内容均未移动。Debug 版本标签仍取工程默认值，不用它宣称新 Release 版本已验收。

**最终达到 C3，并完成上述有限范围 C4。** 本轮未人为破坏真实历史来重现失败弹窗，也未在真实 UI 点击最终回收或恢复；成功后结算和撤销的端到端证据来自独立临时 fixture 集成。卸载、Brew、去重等其他入口的真实交互，以及正式签名 App、macOS 13.5/Intel 仍未全部覆盖，不得表述为“全入口实机正常”。

交付边界：按用户指令提交、推送这份完整修复基线，再构建新公证候选；最终提交和签名产物以 Git/provenance 为准。公开 Release 等用户试用批准。仍待用户对最终 DMG 的试用及 C5；跨进程真正未知请求的人工消歧属于另一个产品流程，未通过超时自动放行。
