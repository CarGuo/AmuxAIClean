# 2026-10-08 删除回执、列表同步与成功反馈

## 现场与根因

用户在专业 Tree 删除嵌套 `example/build` 后仍看到原行、选中高亮和详情。当前运行的
1.6.5 Debug App 日志证实，这次操作 `dryRun=false`，系统返回 `moved=1`、`failed=0`，
随后精确 prune 成功提交；最后一份 Tree projection 却以 `stale_after_prepare`、
`source_current=false` 丢弃，没有后续有效发布。这是删除后呈现错误，不能解释为预览或未执行。
原始现场截图、AX 和日志留在忽略目录 `build/review-delete-20261008/`。

两条独立通知链路都存在发布时序错误：

1. `bumpStructuralRevision` / `bumpTickRevision` 先同步通知订阅者，随后才推进
   `pruneSourceRevision`。订阅回调冻结版本 R，通知返回后数据变成 R+1，后台投影因此
   永远无法提交。children-cache 入口曾修正同类事故，但其它两个共同入口漏修。
2. receipt 快速删除订阅忽略 emitted revision，在回调中重新读取旧属性。
   [Apple 的 Published 文档](https://developer.apple.com/documentation/combine/published?changes=_5)
   明确其发布发生在 willSet；新值尚未写回，因此该 worker 同样会被版本校验拒绝。

跨入口审计另外确认：普通空间图没有消费 receipt tombstone，大文件 getter 虽已过滤
tombstone，冻结表格却没有订阅 receipt。两者都可能等到昂贵的权威 prune 完成才移除行。

上轮只读 App 验收没有完成真实 fixture 回收；已有测试验证了最终模型和独立后台 worker，
没有验证同步通知时视图冻结的身份，也没有挂载 production 原生表格验证即时更新。
这些证据缺口是本次漏检原因，不能以当时 C2/C3 通过推导删除交互正确。

## 修复与边界

- 三条 Tree 通知入口统一遵守“提交 source identity，再通知”；保留全部 stale/session CAS。
- receipt 发布改为不可变 matcher/revision 事件，Tree 直接消费 emitted value。
- 普通空间图使用同一冻结 source/tombstone，在后台投影中过滤，图块、列表和展示统计
  使用同一集合；receipt 先隐藏行，权威容量仍由 prune 对账。
- 大文件表格订阅同一事件，在后台对冻结行与独立类型统计源一起做删除投影；页面版本、
  receipt 版本和取消状态阻止旧 worker 覆盖新投影。完整排序/过滤更新仍走现有终态入口。
- 所有文件回收 owner 使用 `OperationCompletionPresentation`：纯成功为页面内五秒提示；
  失败、部分成功、用户跳过、pending、submission-unknown、not-submitted 保留共享明细页。
  不透明 completion 门禁、确认授权、最终安全重验、Trash 与 Undo 链路保持原合同。
- 新提示使用 String Catalog 的中英双语、英文单复数和项目要求的双向 variations；
  timer 绑定 receipt ID，后来的操作不会被旧 timer 关闭。

未改规则库、hard-forbid、工程、依赖或发布脚本。没有用重扫、延时重试、强制 table reload、
放宽 CAS 或扩大产品目录范围掩盖发布错误。

## 交互参考

[Apple Alerts 指南](https://developer.apple.com/design/human-interface-guidelines/alerts?changes=_1)
建议把普通信息放在相关上下文，避免为常见、可撤销动作频繁打断用户。
[DaisyDisk 删除指南](https://daisydiskapp.com/guide/4/en/DeletingFiles/) 把候选收集、审阅与
删除取消窗口放在同一 Collector 中。这里参考其操作上下文的组织方式；纯成功采用轻提示
是本项目据此做的交互决策。DaisyDisk 的永久删除方式不适用于本项目的 Trash 合同。

本地已有 [Pearcleaner 固定版本的回收 owner](https://github.com/alienator88/Pearcleaner/blob/1b3e07a484e36a09a6602836a85821d03f4ff491/Pearcleaner/Logic/UndoManager.swift)
成功后登记 Undo、播放声音；[开发者清理视图](https://github.com/alienator88/Pearcleaner/blob/1b3e07a484e36a09a6602836a85821d03f4ff491/Pearcleaner/Views/DevelopmentView.swift)
在成功分支直接移除对应模型项。这支持“成功在原页面收敛、恢复另有入口”的设计。
只参考交互与模型提交方式，没有复制其命令执行、权限或同步等待实现。

## 逐入口审计

| 入口 | 模型/回执 owner | 本轮处理与验证边界 |
|---|---|---|
| 专业 Tree，含行按钮/右键/Delete | MainView、ScanCoordinator、TreeBrowserView | 共同发布边界与 receipt 事件修复；原生表格集成复现先红后绿 |
| 专业清单、批量、待处理 | MainView、ScanCoordinator、StashStore | 主清单已有 receipt worker/CAS，待处理已有 move 通知；复核统一成功路由 |
| 大文件 | MainView、LargeFilesView | 补 receipt 订阅和后台冻结表格/类型统计投影；原生表格先红后绿 |
| 普通空间图 | StorageAnalysisTrashStore / Store | 补共享 receipt 源过滤；图块/列表无需等待 prune；先红后绿 |
| Smart Care | MainView、SmartCareSession | 完成页已有 summary reconciliation；反馈共用策略，异常结果仍保留 |
| 重复文件 | DuplicateScreen、DuplicateResultsStore | 会话/source CAS 已有覆盖；复核结果集合与手工选择，接入共同反馈 |
| 工作流文件项 | WorkflowDetailViewModel | 同步当前命中及父子卡片后反馈；增强测试验证连续删除无需 Done |
| Homebrew、卸载 | 各工具 owner 与 terminal projection | 终态投影先提交，再分流反馈；既有行为测试继续覆盖 |
| App Footprint | 复用工作流及公共回收入口 | 没有独立结果弹窗，依赖上述 owner 和 move 通知 |

Simulator 系统管理卸载是独立 managed operation，不属于 Trash receipt，保留其独立进度与终态。
没有把未实际操作的工具入口标为 C4。

## 自动化与构建证据

已保留原代码失败日志：

- `publication-red.log`：prune 通知生成的 source 在发布后即过期。
- `receipt-view-red.log`：production Tree 的 NSTableView 仍为两行，未自动变为一行。
- `map-receipt-red.log`：只发回执时普通分析的图块和列表仍未更新。
- `large-files-receipt-red.log`：production Large Files 表格仍为两行。

修复后验证包括同步通知 source CAS、真实 NSHostingView/NSTableView、普通图块/列表的
receipt-only 更新、所有异常结果分支、连续工作流删除，以及已有 prune/并发回执/旧会话测试。
这些使用隔离数据或内存模型的原生集成属于 C2，不等于真实 App 回收验收。

最终九包 `swift test` 均 exit 0：

| 包 | XCTest 条目 | 最终日志 |
|---|---:|---|
| ScanKit | 532 | `full-ScanKit.log` |
| SafetyKit | 174 | `full-SafetyKit-retry.log` |
| AppUI | 1,482，另有 11 项 Swift Testing | `full-AppUI-final.log` |
| HeuristicKit | 12 | `full-HeuristicKit.log` |
| LogKit | 46 | `full-LogKit.log` |
| BrewKit | 58 | `full-BrewKit.log` |
| FileSearchKit | 21 | `full-FileSearchKit.log` |
| AIKit | 55 | `full-AIKit.log` |
| TestHarness | 8 | `full-TestHarness.log` |

总计 2,399 个测试条目。全包并行运行中的两项 opt-in 原生视图测试另以
`GSYCLEAN_DELETION_VIEW_TESTS=1 swift test --filter 'DeletionPublicationBoundaryTests|StorageAnalysisStoreTests'`
非并行执行，`native-view-final.log` 记录 14/14 通过、0 失败。包含挂载 production
NSTableView 的 Tree、大文件回执更新，不能将其描述为真实 App 删除。

最终 Debug 命令使用原生工程、`build/delete-review-dd` derived data，
`debug-build-final.log` 记录 `** BUILD SUCCEEDED **`。编译器无新增诊断；Xcode 的
AppIntents metadata 提示仅说明项目没有该 framework 依赖。String Catalog 完整性测试和
`git diff --check` 通过。20 个改动的 Swift/catalog 文件在最终测试、构建及真实运行后
SHA-256 一致，记录在 `final-source-hashes.json`；二进制与进程路径见 `final-verification.json`。

ScanKit 使用 native backend / 独立 scratch path；默认 swiftbuild 的重复链接问题已在上轮
未修改基线上复现。首次 SafetyKit 性能断言与构建/benchmark 并发时超预算，保留
`full-SafetyKit.log`；独立全包重跑通过，没有修改阈值或断言。

只读 `Resources` 小目录 smoke benchmark：PerfBench 8.87ms、16 文件、1.42MiB、complete；
CoordinatorBench 54ms、producer 1ms、drain lag 2ms、16 文件、complete。两次均为 CLI，
不是 App 启停测试；它们不证明用户大目录的交互性能，也不包含随后新增的 View receipt 路由。

## 真实 App 验收边界

原 App 中的残留行与详情已留证。真实删除/Undo 只允许使用人工 fixture；现有
NSTemporaryDirectory 物理路径会被既有隐私规则跳过。本轮不再为测试改产品规则，已向用户
申请一次仅针对新建人工 fixture 的 HOME 缓存目录位置例外；收到明确答复前不进行该操作。

13:53–13:57 在最终 Debug App 中连续进行只读交互：

- 专业模式扫描项目 `Resources`，显示完成、16 文件和三条直接子项；Rules 展开后六行，
  选中详情与真实路径一致，日志中 shallow/deep 均终结并提交增量投影。
- 按 Delete 打开普通确认后取消，原行、展开与选中详情保留。没有确认回收。
- 清单与 Tree 切换，直接子项一致；普通分析通过系统选取器选择同一目录，图块与列表一致。
- 普通分析下钻 Rules，搜索 `safe` 后列表和图块均只显示 `safe_paths.yaml`、4kB；
  打开共享确认再取消，搜索结果与目录保留。清空搜索、返回根后恢复三项。
- 返回专业 Tree；移除本轮新增的 Resources 快捷项，用户原有 workspace、HOME 两项保留。
  整次验收没有按 case 重启 App，也没有通过命令模拟生产交互。

AX/截图为 `readonly-c4-*.ax.txt` / `.png`，现场原始事务节选为 `user-incident-0515.log`。
运行进程路径确认为 `build/delete-review-dd/Build/Products/Debug/AmuxAIClean.app`，
可执行文件 SHA-256 为 `e64a3591ed550c259b57094a6776e7a6496aabe7924b4e4ffacc7ee9e2a46b38`。
这是对应只读行为的 C4，**没有完成真实回收的运行交互验收**。最终读取 production
pending ledger 与 completion journal 均为空，Undo 保留十条既有记录；本轮没有新增回收、
恢复或隔离记录。这里只有结束时快照，不将其写成生产文件前后字节一致。

当前交付状态为 C3 加上述只读 C4。仍需受控 fixture 的真实回收、无成功模态、
行/选中项/详情自动消失及 Undo 恢复证据；位置例外未获答复。用户在获知这些验证边界后，
另行明确要求提交和推送，本轮按该授权交付。该授权不改变上述证据等级，也不包含测试位置例外。
macOS 13.5 真机/VM 和最终 Release/DMG C5 未做，不承诺全平台无缺陷。

## 会话 worktree 标记

本次改动位于主检出 `/Users/guoshuyu/workspace/GSYCleanMac` 的 `main`。
聊天仍附有上轮为重现基线构建问题创建的 `review-oct07` 独立 checkout；因此界面显示
worktree，并不表示当前改动写在其中。该 checkout 干净，归档工具返回被 pinned task/workspace
保护，未强行删除或改变其他任务的附件。
