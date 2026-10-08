# 2026-10-07 commit 修复与真实 App 验收

> 2026-10-08 后续现场发现了本文未覆盖的删除后 Tree 发布时序错误；上轮只读 C4 和模型
> 测试不能证明真实删除后的视图正确。该问题重新审阅、修复与验收见
> [删除回执与呈现回归记录](DELETION_PRESENTATION_2026-10-08.md)。本文保留当时实际证据和边界。

## 范围与授权

审阅基线为 `4760396`（包含同日 `e27bf74`）。用户在审阅后明确要求“修改，优化，调整，然后真实 app 测试”。本轮修复审阅中的四项问题，以及真实运行发现的目录状态、弹窗语言两个共同问题。2026-10-08 用户进一步授权最终 review 通过后提交、推送；本轮不制作 Release。

原验收计划使用修复后原生 Debug App 持续运行。入口、观察点和数据边界如下；表中是真删受阻前的计划，实际覆盖以末节为准：

| 场景 | 入口与操作 | 观察点 | 数据边界 |
|---|---|---|---|
| 普通存储分析 | 选取临时 Analysis 目录；下钻、面包屑、搜索；取消确认，再删除单个 fixture | 图表/列表同步、目录总量、取消无提交、完成终态 | 只真删本轮临时 fixture |
| 专业 List / Tree / Large Files / 待处理 | 自定义同一临时目录；行、右键、Delete、底部操作 | 选中范围、父级聚合、最后子项、重复提交与取消 | 只真删本轮临时 fixture |
| Smart Care | 扫描、停止/重新扫描、审阅、确认取消 | 进度、响应、剩余审阅入口、状态收敛 | 真实 HOME 只读；完成后继续审阅的可控状态另有 C2 |
| 重复文件 | 只保留临时 Duplicates 扫描根；保留最新、手工选择、确认；必要时在确认前修改 fixture | hardlink 不重复计算、保留副本、最终内容验证、删除后组更新 | 三份 12 MiB 相同内容副本及一个 hardlink |
| 卸载 / Brew / Workflow / App Footprint | 真实发现、搜索、详情、确认取消 | 内容范围、图标、错误/空态、确认交互 | 不删除真实应用、工具链或缓存 |
| Undo | 仅恢复本次生成的记录 | 文件回原位、内容哈希一致、恢复终态 | 不操作既有历史或其他废纸篓文件 |
| 跨页面与设置 | 同进程切换页面、zh-Hans/en、浅色/深色、调整窗口 | 文案、布局、取消、旧结果不覆盖新页面 | 完成后还原原有偏好 |

不更改系统权限，不执行维护任务，不结束真实业务进程，不触发 AI 请求。生产 pending ledger 与 completion journal 在启动前只读检查为空；既有 Undo 历史保持原样。临时目录路径、原始大小/mtime/inode/哈希及运行日志保存在 `build/review-oct07-fix/`。

## 临时目录问题与范围决定

这不是针对某个用户名的处理。macOS 的同一个临时目录可表现为 `/var/folders/...` 与 `/private/var/folders/...` 两个命名空间。包测试从 `NSTemporaryDirectory()` 创建 fixture，实际系统选择器返回物理的 `/private/var/folders/...` 路径。现有 `TCCSkipList.dangerousAbsolute` 对整个 `/private/var/folders` 主动跳过；真实日志已经证明扫描在根目录即停止。

旧普通分析界面只看子行是否为空，丢失了“主动跳过根目录”的证据，因此显示没有测得数据和零容量。这是用户可见的状态错误；目录并未被证实为空，也不是用户需要补授 FDA。

最初考虑按系统 API 识别当前用户临时/缓存根，缩小跳过范围。用户要求说明产品意义后，本轮撤回该调整：系统 API 识别可做成通用方案，但“测试 fixture 需要可扫”不足以证明产品应该开放这些目录。隐私规则没有修改，也没有改用 `/var` 别名绕过它。修复落在共享节点访问证据与普通分析展示边界。

临时目录的别名处理、扫描范围和当前用户临时目录清理定位仍有合同不一致，后续应从产品支持范围统一决定。本轮不把它扩展为隐私策略重构，也不把受阻的真实回收/撤销标为通过。

## 修复

- Smart Care：为已完成清理后的继续审阅建立独立状态转换，保留剩余摘要与用户选择。
- 普通分析：删除通知在入队前冻结扫描会话，异步阶段之间重新校验；同会话并发回执仍交由扫描器的 source-revision CAS 合并。
- 重复文件：由结果 owner 管理扫描会话和 source revision；旧投影丢弃，同会话并发更新重算合并，过滤在后台执行；无关通知不重置手工选择。
- Brew：Cask 别名目录的读取失败通过类型化诊断使活跃引用证据失效，禁止发布可能仍活跃的清理候选。
- 普通分析根目录状态：复用 Tree 的节点 access projection，将隐私跳过、文件访问拒绝和分析不完整分别展示；受限根不显示测得零容量，不提供误导性的搜索。正常目录与后代不完整证据仍保留各自原有语义。
- 运行期语言：`localizedSheet` 在公共 presentation 边界向独立托管的 macOS sheet 显式传递发起页面的 locale。全部 AppUI sheet 入口以及 App 层的引导/更新 sheet 采用同一边界，路由、授权和 onDismiss 不变。没有硬编码语言或重启换语言。

实现方式采用 SwiftUI 正式的 [`EnvironmentValues`](https://developer.apple.com/documentation/swiftui/environmentvalues/) 与 `environment` API。弹窗在本机未沿用页面 locale 是真实运行观察；不能仅凭 API 文档或字符串单测认定该边界已正确，中文/英文工作流确认页另有运行证据。

防回归测试只覆盖有实际失效条件的合同：完成后审阅状态转换、普通分析旧会话回执与并发回执、重复文件旧投影与并发投影、不可读 Cask 活跃引用、系统选择器物理临时路径的隐私跳过状态。原静态检查只数 `.sheet` 字面调用，改为同时统计 `.sheet` 与 `.localizedSheet`，仍严格要求卸载只有一个 presenter；非模态预检限制同时覆盖两种入口。

## 验证结果

### 自动化与构建

最终九包回归全部 exit 0，共 **2,393 项**（2,382 XCTest + 11 Swift Testing），详见 `package-final-results.json`：

| 包 | XCTest | Swift Testing |
|---|---:|---:|
| AppUI | 1,476 | 11 |
| ScanKit | 532 | 0 |
| SafetyKit | 174 | 0 |
| HeuristicKit | 12 | 0 |
| LogKit | 46 | 0 |
| BrewKit | 58 | 0 |
| FileSearchKit | 21 | 0 |
| AIKit | 55 | 0 |
| TestHarness | 8 | 0 |

每包使用 `swift test --parallel --num-workers 4`，ScanKit 的构建后端选项见下文。最终回归包含两个实测修复及静态 presenter 判据更新；没有把首轮结果替代最终源码验证。String Catalog JSON 校验通过，只新增六条双语 key，既有条目没有改变；`git diff --check` 通过。

定向用例已通过，包括物理临时路径扫描，以及公共 presenter 的静态合同检查。初次追加回归曾在旧 `.sheet` 字面计数断言失败，证据保留于 `AppUI-final-source-guard-failure.log`，没有删除或放宽单 owner 需求。

最终 Debug 目标构建通过：

```bash
xcodebuild -project GSYCleanMac.xcodeproj -scheme GSYCleanMac -configuration Debug \
  -derivedDataPath build/review-dd -jobs 2 build
```

运行产物为 `build/review-dd/Build/Products/Debug/AmuxAIClean.app`。环境是 macOS 27.0、Xcode 27 / Swift 6.4。ScanKit 使用 `swift test --parallel --num-workers 4 --build-system native --scratch-path .build/native-review`：默认 swiftbuild 的重复链接错误在未修改基线上也复现，没有修改 manifest、依赖或断言来规避。

### 真实 App 操作

每个修复产物使用一次持续运行，不按 case 重启。首轮持续扫描、停止/继续、跨页面发现、确认取消后，针对实测问题重新构建；中间产物验证目录状态，最终产物验证公共弹窗与双语切换。中间尝试的 scene 层 locale 注入未通过实测，最终代码没有保留该方案。

| 场景 | 实际操作与观察 | 覆盖边界 / 证据 |
|---|---|---|
| 普通分析：受保护临时根 | 系统选择器选取 Analysis；原界面误呈空数据；修复后显示“已按隐私策略跳过目录”及原因，搜索禁用，无测得零容量 | 已观察修复后状态；`c4-protected-directory.*`；未真删 |
| 普通分析：正常目录 | 只读扫描项目 `Resources`，显示 Assets/Rules/.DS_Store 合计约 1.5 MB；下钻 Assets、返回、搜索 Rules 后列表/图表同步为约 90 kB | `c4-normal-analysis-search.ax.txt`；真实源码资源未修改 |
| 专业 Tree / 清单 | 同一 Resources 扫描完成：16 文件、约 1.5 MB、0.39 秒；树形展开 Assets，切换清单后顶层容量一致 | `c4-professional-tree.*`；本轮添加的路径入口已移除，原两条自定义路径保留 |
| Smart Care | 真实 HOME 扫描，停止后显示暂停且没有改动文件；继续扫描得到部分受限结果，4 个位置未完整扫描；74 项约 6.69 GB 可清理，另约 3.14 GB 需确认；打开预览后取消。10 月 8 日在同一最终产物中重新扫描得到约 6.68 GB，中文/英文确认页均正确，分别取消后保留 43 项日志与 31 项缓存选择，最后恢复简体中文 | `c4-smartcare-review.*`、`c4-smartcare-confirm.*` 是修复弹窗语言前证据；最终语言证据为 `c4-smartcare-confirm-final-{zh,en}.*`。完成后继续审阅只到 C2，未制造真实清理完成状态 |
| 工作流确认及语言 | 最终产物发现 DerivedData 约 1.98 GB；中文确认标题/说明/按钮一致；取消后保留选择；同进程切英文，再确认并取消，容量/选择保持；恢复简体中文 | `c4-workflow-confirm-final-{zh,en}.*`、`c4-restored-language.ax.txt`；真实缓存未清理 |
| 卸载 | 发现 62 个真实应用，搜索 Typora、查看约 63 MB 的六个关联位置；扫描不完整证据保留，未误当可清理完整结果 | `c4-uninstall.ax.txt`；未卸载 |
| Homebrew | 真实 `/opt/homebrew` 发现；清理页为零候选，删除按钮禁用 | `c4-brew-cleanup.ax.txt`；不可读 Cask 故障用定向测试覆盖，未改真实权限制造故障 |
| 其他入口 | 重复文件真实删除、Large Files 删除、待处理删除、Undo、模拟器系统管理卸载、AI、系统维护没有执行 | 均未完成相应 C4；不能由共享组件或 package tests 代替 |

首轮后续操作期间，原生控制工具返回 `cgWindowNotFound`，应用库存仍报告进程运行。这项工具失败不能推断为 App 崩溃，也没有杀进程或反复启动制造证据。10 月 8 日主窗口恢复可控制后，继续使用最终产物完成 Smart Care 中英文确认与取消复验；深色与窗口尺寸矩阵尚未完成。

### 数据边界和剩余项

- 10 月 7 日 23:59 核对时，九个临时 fixture 的大小、mtime、inode 和 SHA256 与创建时一致，见 `fixture-after.json`。10 月 8 日 12:58 再核对时，`Duplicates/old.bin` 缺失，其余八个文件未变；该目录的最后修改时间为当天 03:35，早于本轮补验。系统日志未提供可确认删除来源的记录，不能断言是系统清理或 App 行为。此 fixture 已失去完整性，后续受控回收验收需要重新创建；不得恢复文件后伪称原 fixture 一直完整。
- 生产 pending ledger、completion journal 仍为空且字节哈希未变；运行日志没有 `submit_start` 或 `recycle_completed`。Undo 仍为十条既有记录，最新记录为 10 月 3 日，没有本轮新增记录或恢复操作。正常 App 退出会重写 Undo JSON，其字节哈希发生变化，不能宣称生产目录没有任何写入。
- 界面语言已恢复 `zh-Hans`，自定义路径恢复为原两条；没有改系统权限或外观设置。UI 控制受阻前已切回普通模式。
- 原始四项问题的确定性回归与构建属于 C2/C3；表内真实只读操作属于对应场景的运行证据。删除合同要求的 fixture 真回收、receipt、结果终态、Undo 尚未闭合，不能宣称整个删除功能完成 C4。
- macOS 13.5 真机/VM 与最终 Release/DMG C5 没有验证。本轮不制作 Release/DMG，提交推送依据 10 月 8 日的新增授权。

主要原始日志、AX 文本、截图、fixture 清单与验证结果位于 `build/review-oct07-fix/`；该目录不入仓。审阅用独立 worktree 已干净，归档被 pinned/workspace 保护拒绝，未强制删除。

## 2026-10-08 提交前最终复审

逐项复核六类修复的状态所有权、await 前后会话校验、并发回执合并、后台过滤、类型化错误与公共 sheet 的 locale/绑定/onDismiss 合同，未发现未处理的阻塞项。新增测试复核了真实失效条件；原 presenter 断言仍要求单一 owner，未削弱需求。源码与运行二进制的 SHA256 均匹配最终九包回归及 Debug 构建记录，未修改受保护项目文件、规则、依赖或发布脚本；只补充运行证据与本文档，因此沿用同一源码的最终测试结果。

最后数据复核确认生产 pending ledger、completion journal 字节哈希仍未变，Undo JSON 的规范化语义哈希与前次记录一致；补充运行日志仍没有 `submit_start` 或 `recycle_completed`。临时 fixture 缺失项没有本轮回收/Undo 证据，来源未证实；保留现状与原始清单，没有通过重建掩盖这一变化。核对明细保存为 `final-review-audit-2026-10-08.json`、`c4-runtime-final-review.log`。

当前平台的代码 review 通过，已执行的只读运行场景通过；这不构成“所有系统、所有入口没有任何问题”的保证。真实 fixture 回收/Undo、Smart Care 真清理后的完成页、深色/尺寸、macOS 13.5 和发布产物仍按上述边界保留未验状态，不因提交而升级证据等级。
