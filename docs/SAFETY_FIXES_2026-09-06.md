# 2026-09-06 安全修复与验收

## 直接执行

本轮根据用户“修复、验证功能后启动供手测”的要求，修复上一轮审查的 SR-01、SR-02、
SR-03。保留已有普通模式 UI 改动，
未修改工程配置、依赖、规则资源或 hard-forbid 列表；没有 commit、push 或发布。

### 修复内容

| 编号 | 根因与修复 | 防回归证据 |
|---|---|---|
| SR-01 / P1 | 通用路径删除只有扫描 revision，执行前才捕获对象。现在确认页出现前在后台冻结 no-follow 对象身份，随完整 intent/plan/授权传递，durable reserve 后比对，并保留后续 claim fence。一键清理也绑定同一证据；筛选只能缩小范围，不能重新采样或扩大；无证据的 legacy 真删入口拒绝执行。 | 普通分析、专业 Tree 的确认后同名替换拒绝；确认前替换、缺失对象、缺失证据拒绝；一键清理证据保留/缩小；未替换临时文件可真实回收并取回，未选文件保留。 |
| SR-02 / P1 | 固定敏感路径只保护自身和后代，未保护会覆盖其内容的父目录。现在共同安全判定按路径组件检查祖先/自身/后代交集，同时保留原始与解析路径校验；没有给 `.config` 增加特例。 | 现有全部凭据规则及其 HOME 祖先、同级缓存、相似前缀、symlink；临时 HOME 加载实际 vendors 预检，凭据叶子及父目录均拒绝。 |
| SR-03 / P2 | 普通详细审阅只收到候选列表，丢失来源与递归文件数。现在消费完整类型化 plan，区分选中目标数与内部文件数，显示总量、逐项目文件数和来源，中英文均由 String Catalog 提供。 | 1 个目录含 123 个文件的 zh-Hans/en 摘要、来源及逐行计数；本地化完整性测试。 |

相关实现：`ReviewedDeletionObjects`、`DeletionInteractionCoordinator`、`TrashPipeline`、
`SmartCareCleanRequest`/`MainView`、`SafetyEngine`、`ToolTrashConfirmationSheet`、
普通分析与卸载的审阅调用方。修改原因和约束已写入版本注释、`DELETION_UX_CONTRACT.md` 和 `PITFALLS.md`。

### 自动化验证

环境：Apple Silicon / macOS 26.5.2 / Swift 6.2.3。

- 九包全量 `swift test`：SafetyKit、ScanKit、AppUI、HeuristicKit、LogKit、BrewKit、
  FileSearchKit、AIKit、TestHarness 均通过。AppUI 使用 `--parallel --num-workers 4`，
  其他包使用 `--parallel`。
- SR-01/SR-02 的原始失败反例已纳入正式测试；新增或扩展的安全正反例与
  `NormalDeletionReviewTests`、`CredentialAncestorProtectionTests` 均通过。
- 新身份闸门令一个已有“损坏恢复 journal”测试在更早的缺失证据闸门返回。
  该测试补充有效的审阅证据后仍断言原有 `ledgerUnavailable`、零执行结果和文件保留；
  没有降低断言或改变需求。原始失败日志保留为 `AppUI-initial.log`。
- `xcodebuild -project AmuxAIClean.xcodeproj -scheme AmuxAIClean -configuration Debug build`
  通过；未运行 `xcodebuild test`。诊断期间曾尝试改用 SwiftUI 目录选择器，AppUI 全量
  回归及构建均通过，但工具观察结果相同，已撤回该改动。交付代码恢复到九包全量通过
  的三项修复状态，另做最终 Debug 构建。
- 自动化测试开始前和启动应用前，生产 UndoHistory、pending ledger、completion journal
  的存在性、长度、SHA-256 一致；真实回收测试仅操作自建临时 fixture，测试恢复域独立。
  首次实际启动/退出应用后 UndoHistory 有写入（20:16:42），发生在额外 AppUI 回归开始
  （20:16:59）之前；该次回归期间生产三份恢复文件没有写入。启动后的状态变化不冒充
  包测试前后快照证据，详见 `production-state-before-final-c4.json`。
- `git diff --check` 通过。可选的离屏渲染测试遵守其 opt-in 条件，不把跳过项计作运行交互。

证据目录：[safety-fixes-2026-09-06](../build/validation/safety-fixes-2026-09-06/)。
包含逐包完整日志、`package-results.json`、原始失败与修复后日志、Debug 构建日志、
生产恢复文件哈希快照、C4 fixture 清单及实际交互结果。

### 持续运行交互

**完整 C4 尚未通过：目录选择及 UI 回收/恢复流程未做完运行交互验收。**

在“分析 → 扫描范围 → 选择文件夹”之后，自动化只读到 busy 的主窗口，没有读取到系统
目录面板；主线程采样处于正常事件循环。改用项目已有的 SwiftUI `fileImporter` 后工具
观察结果相同，不能证明原实现存在产品缺陷，故撤回这项诊断性改动，没有把它当作已修复
问题。已询问用户是否能看到实际系统面板，交付时该问题仍待人工确认。

所有 C4 尝试均未进行回收；自建目录的 131 个文件仍与 SHA-256 清单一致。没有用真实
用户文件制造删除证据。原计划的“123 文件目录审阅 → 取消 → 回收 → 历史恢复”不计为通过。

诊断涉及不同构建，相关进程在替换构建前退出；最终交付版本单独启动并保持运行。
首次 CUA 按显示名绑定应用时额外打开了仓库已有的 Release 构建，识别后已退出，
未扫描或删除；之后只用绝对路径绑定。诊断启停没有被当作 C4 功能验收。

最终交付版本在同一持续进程内实测了以下页面，详见 `c4-results.json`：

- 分析首页的空态及扫描入口；清理页显示两个已选扫描范围，未发起真实用户目录扫描。
- 卸载列表加载成功；1 个应用位置未完整读取的提示保持可见，未选择/卸载任何 App。
- 优化维护页打开成功，未执行维护命令；启动代理只读列表显示 18 项和 2 个位置无法
  读取或解析的提示，未修改任何启动项。
- 状态页 CPU、内存、磁盘、电池、网络、持续运行指标可见，多次观察中读数更新。
- 返回普通模式分析首页，导航和扫描按钮可用，**应用保持运行供用户手测**。

这些页面的加载和导航有实际运行证据，但不是扫描/清理/恢复的完整 C4 验收。
最终构建日志为 `Debug-build-delivery.log`，运行路径及二进制哈希见 `delivery-launch.json`。

## 深度交互

防误删依赖两个不变量：最终回收对象必须是用户审阅的对象，选中目录覆盖的范围不能包含
不可覆盖的保护内容。废纸篓只是恢复机制，不能代替这两项约束；同样，测试通过不能证明
所有机器、权限状态和并发时序都不会出错。

还差的证据：用户确认系统目录面板并完成扫描/取消/审阅/回收/恢复的持续交互；
macOS 13.5 实机、不同 TCC/ACL 组合、
真实崩溃重启后的完整交互以及用户实际数据规模下的长时间使用不在本轮证据范围内。
本轮不是 Release/公证/DMG 验收，也没有扩大 Kivo 功能对齐范围。
