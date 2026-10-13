# 2026-09-06 安全测试与项目审查

> 后续状态：SR-01、SR-02、SR-03 已完成修复与 C3 回归，详见
> [修复与验收记录](SAFETY_FIXES_2026-09-06.md)。完整 C4 尚未完成。下文保留初次审查时
> 的失败证据和当时结论，不代表后续修复仍为 OPEN。

## 直接执行

**结论：发现 2 个 P1 删除安全问题、1 个 P2 普通模式审阅问题。当前不能认定防误删验收通过。**

本轮审查当前工作树，包含尚未提交的普通模式 UI 改动。重点检查路径和对象身份、删除授权、
hard-forbid、白名单、批量原子拒绝、卸载/重复文件证据、持久回收与撤销恢复、扫描取消和
页面 revision，以及子进程和网络边界。未修改产品实现、规则、工程配置或既有测试断言；
独立复现源码与失败日志保存在本轮验证目录。没有 commit、push 或启动 App。

### SR-01 · P1：确认后的同名替换对象继承旧删除授权

- **影响**：普通存储分析入口，以及没有独立对象校验证据的共享路径删除流程。属于共享链路
  的既有缺口，新分析页也使用这条链路。
- **复现**：在临时 HOME 中创建缓存文件 A，读取其对象身份，经过真实
  `DeletionInteractionCoordinator.prepare → authorize`。将 A 移开，在同一路径创建 B，保持
  scan revision 不变，再提交旧授权。普通分析 origin 和专业 Tree origin 均实际回收了 B。
  用户审阅的是 A，执行对象却是 B；即使 intent 显式携带 A 的 `sourceObjectIdentity` 也未被阻止。
- **根因**：[DeletionInteractionCoordinator.swift](../Packages/AppUI/Sources/AppUI/DeletionInteractionCoordinator.swift)
  的 `submit` 对通用 origin 接受 nil execution verification，向下只传路径和扫描 identity，
  没有把审阅对象身份交给提交边界。
  [TrashPipeline.swift](../Packages/AppUI/Sources/AppUI/TrashPipeline.swift)
  在 `reserveAfterRecovery` 时才捕获当前对象，随后 claim 能保护的是此时的 B。
  卸载路径的旧身份比较位于 `uninstallVerificationRequest.changedPaths(comparedTo:)`，通用路径
  没有对应约束。
- **违反合同**：[SECURITY.md §1.5](../SECURITY.md) 要求确认后路径身份变化必须重新预检。
- **证据**：C2，两个对象替换测试失败；未替换的正向对照确实回收了唯一选中项。测试逐一核对
  系统返回的 Trash 路径与对象身份，将自己的文件移回空置原路径，保留未选中的 sentinel 和 A。
- **修复方向**：在共享审阅边界冻结对象身份，贯穿 plan、authorization、持久 reserve 和紧邻
  recycle 的重验。身份缺失或变化必须终止旧授权并要求重新审阅，不能到执行时为新对象补发身份。

### SR-02 · P1：删除敏感凭据的父目录能够通过保护检查

- **影响**：用户选择含硬保护路径的上级目录时，受保护内容可能随整个目录被回收。
- **复现**：使用临时 HOME、实际 `Resources/Rules/vendors.yaml` 和隔离 pipeline，创建
  `.config/gh/hosts.yml` 假凭据。对该文件预检得到 `sensitiveCredential` 拒绝；对父目录
  `.config` 预检却得到 `canProceed == true`、空 rejection。此用例只预检，没有回收目录。
- **根因**：[SafetyEngine.swift](../Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift)
  的敏感路径判断只识别目标本身及其下级：
  `standardized == full || standardized.hasPrefix(full + "/")`，缺少删除祖先会覆盖保护目标的判定。
  TrashPipeline 的白名单已有祖先/后代交集保护，hard-forbid 凭据边界没有同等语义。
- **违反合同**：敏感凭据是不可覆盖的安全边界，普通目录确认不能绕过其保护。
- **证据**：C2，父目录保护断言失败，受保护叶子拒绝断言通过；假凭据内容保持原样。
- **修复方向**：在共同删除范围判定中检查目标覆盖的保护范围，保留路径组件和 symlink
  规范化语义。此例不能只靠给 `.config` 加一个特例解决；应覆盖既有保护路径的所有相关祖先。

### SR-03 · P2：新普通模式详细确认页缺少文件数和来源摘要

- **影响**：普通分析和普通卸载的确认页只展示名称、路径、容量；顶部仍使用专业简洁确认的
  `items.count` 文案。一个含大量文件的目录呈现为一个目标，无法在确认页核对目录内文件数和来源。
- **位置**：[ToolTrashConfirmationSheet.swift](../Packages/AppUI/Sources/AppUI/ToolTrashConfirmationSheet.swift)
  的 `reviewItems` 分支，仅消费 candidate 的 title/path/bytes，未展示 fileCount；输入也没有
  intent origin。属于本次普通模式 UI 改动。
- **违反合同**：[DELETION_UX_CONTRACT.md §5.1](DELETION_UX_CONTRACT.md) 明确要求
  NormalDetailedReview 展示路径、大小、文件数与来源摘要。
- **证据**：C1，源代码与现行合同对照；未进行实际窗口交互验收。
- **修复方向**：让普通详细审阅消费完整的类型化 plan，并采用中英文 String Catalog 展示
  文件数和来源；保持已有的运行中应用选择和执行授权规则。

### 实际验证

环境：Apple Silicon，macOS 26.5.2，Apple Swift 6.2.3。

| 验证 | 结果与边界 |
|---|---|
| 独立安全复现 | 4 例，1 通过、3 失败；失败分别证明 SR-01 的两个模式及 SR-02 |
| SafetyKit、ScanKit、AppUI、HeuristicKit、LogKit、BrewKit、FileSearchKit、AIKit、TestHarness 既有全量测试 | 9 包均通过；AppUI 使用 `swift test --parallel --num-workers 4`，其余使用 `swift test --parallel` |
| Debug 目标构建 | `xcodebuild -project AmuxAIClean.xcodeproj -scheme AmuxAIClean -configuration Debug build` 成功 |
| 生产恢复状态隔离 | 复现及全包测试前后，UndoHistory、pending ledger、completion journal 三份生产文件存在状态、大小、SHA-256 一致 |
| 运行交互验收 | **未做运行交互验收（C4）**；没有启动 App，也没有执行 `xcodebuild test` |

既有测试与构建通过是 C3 基线证据，不能覆盖独立复现的失败，也不代表上述问题已修复。
既有测试覆盖了系统/HOME 根拒绝、越界和 symlink、白名单父子范围、混合批原子拒绝、
卸载对象替换、重复文件及保留副本校验、pending/迟到回调、Undo 同名冲突与对象替换、
任务取消与旧 revision 拒绝等边界。本次针对审阅到提交的通用对象身份空隙，以及保护范围
的祖先关系补充了独立反例。

所有真实回收测试只使用 `NSTemporaryDirectory()` 下自建 fixture；独立复现的回收对象已取回，
未枚举或清空用户废纸篓。既有套件中的真实回收正例可能在废纸篓留下自己的临时测试文件。
网络相关包测试使用测试 transport，未新增产品网络请求。

完整证据位于 [本轮验证目录](../build/validation/safety-review-2026-09-06/)，包括：

- [专项复现源码](../build/validation/safety-review-2026-09-06/SafetyReviewProbeTests.swift) 与
  [失败日志](../build/validation/safety-review-2026-09-06/probes.log)；源码临时放入
  `Packages/AppUI/Tests/AppUITests/` 后运行 `swift test --filter SafetyReviewProbeTests` 可重现。
- [九包结果](../build/validation/safety-review-2026-09-06/package-results.json) 及逐包完整日志。
- [Debug 构建日志](../build/validation/safety-review-2026-09-06/Debug-build.log)。
- `production-state-before.json`、`production-state-after-probes.json`、
  `production-state-after-packages.json`：只记录哈希和元数据，不包含账本内容。

## 深度交互

“都走废纸篓”和“测试全绿”都不足以证明不会误删。实际删除范围必须与用户审阅的对象及其
覆盖内容一致：同名替换会改变对象，选择上级目录会扩大范围。这两个不变量应该由共享执行
边界保证，不能依赖每个 View 自行补一次检查。

**还差什么**：修复 SR-01、SR-02，补齐 SR-03；把本轮反例纳入正式回归并使其通过，重新完成
相关包与 Debug 验证；随后进行用户授权的一次持续 C4 验收。macOS 13.5 实机、真实 TCC/ACL
组合和实际崩溃重启后的交互不在本轮运行证据内。本轮未修复产品代码，上述问题均保持 OPEN。
