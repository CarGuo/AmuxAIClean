# 全功能真实 App 回归执行记录

<!-- v2026.10.08：记录实际操作、失败现场及修复复测；未执行的正向动作不能由页面浏览或 C3 代替。 -->

完整计划见 [75 项回归矩阵](FULL_APP_C4_2026-10-08.md)。本记录只描述本轮已经发生的动作，
不能据此宣布全部功能或全部平台通过。证据保存在本地 `build/full-app-c4-20261008/`。

> 本记录截至 21:39 的首轮持续会话，构建身份以记录的指纹为准。其后外部复审触发 Undo
> 修复，源码与同路径 Debug 产物已变化；新版本验证另见质量台账 9.19 与
> `build/undo-review-20261008/`。下列真实交互不能作为这些新 Undo 改动的 C4 证据。

## 构建与会话

- 环境：macOS 27.0 / 26A428、arm64、Xcode 27.0 / 27A266a；用户安装下限 13.5 未覆盖。
- 初始待测构建：`build/fix-7b96b02-dd/Build/Products/Debug/AmuxAIClean.app`，SHA256
  `a442d2dce2bde35023095f3e41857260f486f9b10c26b2ca8d6abacbf34a5e7b`。
- 旧运行产物 PID 1169 正常退出后才开始验收；原生选取器一次工具不可达，正常退出恢复一次。
  随后 PID 79290 持续运行，未按 case 重启。完成初始观察后正常退出以更换修复构建；
  当时 pending 与 completion journal 均为零。事件见 `session-events.jsonl`。
- 中间修复构建：`build/full-app-c4-dd/Build/Products/Debug/AmuxAIClean.app`；持续运行
  PID 97833，20:33–20:40，结束正常退出。完整身份见 `final-build-preflight.json`。
  Debug 的主程序是 loader，必须连同 `AmuxAIClean.debug.dylib` 和 Catalog 一起核对：
  bundle 内容 SHA256 `235b3ef220a8618da0812c64fbb7f9c54fb869b70fb4c07b89e12d51a108620f`，
  debug dylib SHA256 `2a4b2b22e9e7af9ecb525f6e719694ab884abafab5cc3636a06ffe429d9c7660`。
  早期仅主程序的哈希不足以单独证明 AppUI payload 身份，保留其构建/源码记录，最终采用全 bundle 指纹。
- 修复后重建、诊断后重建均有正常退出/更换记录，没有按 case 快速启停。自动化曾因旧 helper
  捕获旧 App 对象而拉起旧 PID 90980；仅发生导航，已正常退出，`65`、`66` 证据明确作废。
  后续 helper 显式接收 App 对象。菜单实验 PID 96133 出现内部锁重入，记录 sample 后以
  SIGTERM 结束该无文件事务的诊断进程；整组实验代码已撤销，最终构建 Cmd+, / Cmd+W 正常。
- 同一产物继续只读与生命周期验收，PID 98739 约 20:47–21:08，正常退出。
  `113`–`148` 覆盖普通分析、八向清单排序、Finder、Quick Look、日志真实导出和待处理引用，
  实际发现 F05。此会话与 PID 97833 的产物相同；随后修复 F05 必须以新构建复验。

- F05 修复构建 PID 3328 约 21:12–21:20，连续刷新/嵌套刷新通过，同时发现 F06；正常退出后重建。
- **当前交付构建**仍在上述路径，但内容已更新：PID 7041 从 21:28 持续运行至约 21:39，
  `166`–`177` 实际验证 F06 的完整空、不完整空、重扫、输入变更与中英文切换，结束正常退出。
  `delivery-build-preflight.json` 记录 29 个生产源码/Catalog 与 12 个测试文件的指纹；最终核对一致。
  bundle 内容 SHA256 `09849cea5b478b5b5f844cfc09ec8058542774d3ec5d001db4a6a82c49f98909`，
  debug dylib SHA256 `f17d10f6c94da708066c9d4b5f1ba06549d26cef3ece62ea8526662ce3abd5d2`。
  `172`、`173` 又发现 F07；此产物不能宣布全功能通过，隐私匹配候选补丁因与 `NSTemporaryDirectory()`（`/var/folders/.../T`）测试及用户临时目录命名空间冲突而未合入。

## 真实发现与修复

| 问题 | 真实失败证据 | 根因与修复 | 复测状态 |
|---|---|---|---|
| F01 端口/Dart 纯成功仍弹模态 | `12-owned-ports-terminated`、`17-owned-dart-terminated`；独立 socket 与进程检查确认已退出 | 两个页面无条件展示结果 alert。改用共享的确认全部退出反馈，pending/未提交/失败保留明细，计时器绑定反馈 ID。 | 修复版端口两进程/三端口 `68`–`71`；对应修复构建 Dart `93`–`97`：非模态、列表归零、独立 PID/socket 验证通过。官方编译 Catalog 中英单复数断言通过。 |
| F02 筛选后详情与操作仍属于隐藏 App | `26-app-footprint-search`、`30-uninstall-search`、`32-uninstall-no-match`：左侧只有 Typora/无结果，右侧仍是旧应用 | 共享可见 identity 投影；卸载搜索、点击、刷新、删除终态统一同步选择切换，清候选、取消任务、旋转 revision。刷新采用重新发现的 inode/metadata；迟到结果仍须通过 gate。 | 对应修复构建 `98`–`104`：可见选择、隐藏清空、无匹配和带查询刷新通过。异步 intermediate/terminal、删除 fallback 与重新发现身份测试通过。 |
| F03 卸载候选总量错误 | `31-uninstall-typora`：六项约 66 MB，头部却显示“共 6 项 · 0 kB” | 头部使用勾选容量。改为候选数量与候选容量同源，底部继续显示勾选容量。 | 对应修复构建 `103`：6 项 66.1 MB，勾选总量仍为 0 kB。 |
| F04 切页后原生菜单退回旧语言 | `37-settings-english`→`38-settings-large-files`→`39-english-native-menu`；设置内容英文，菜单和窗口标题中文 | 单次刷新不能覆盖 scene 与原生菜单后续填充。当前只保留幂等 update、Settings 标题 attachment 和声明式新建窗口命令。通知/target/AX 接管实验未解决实际填充且触发重入，已全部撤销。 | **未关闭**：窗口标题与页面语言通过 `73`、`80`、`81`、`110`；展开子项仍混语 `74`、`82`、`84`、`89`、`90`。菜单图单测不能替代真实展开。 |
| F05 Tree 刷新后永久转圈 | `146`–`148`：Assets 刷新 worker 已完成，行内忙指示器仍在；本进程 sample 为正常 event loop | 最终 Tree 通知先于刷新 owner 结束，投影冻结了 fetching=true。请求结束移入 indexed transaction 的无挂起提交，与行/证据一起发布；拒绝的旧请求仍只能结束自身 token。 | `subtree-settlement-red.log` 在原代码两处断言失败；修复后同步通知及真实投影、重叠刷新/typed incomplete 等 41 项聚焦集合通过（原生视图 2 项按既有 opt-in 跳过）。`149`–`154` 连续两次父刷新及一次嵌套刷新通过，7 项原生订阅集成通过。 |
| F06 重复扫描完成后仍提示未开始 | `163`、`164`：Resources 实际扫描 16 文件，扫描按钮已恢复，空态仍要求开始扫描；Bulk 完成日志证明已执行 | 页面只有 isScanning/groups，没有会话终态。结果 store 新增完成/停止/异常结束，真实 producer 结算后按 session 提交；完整空结果与 incomplete 分开。修改根/阈值同时旋转 owner 并清旧结果与证据。 | 25 项聚焦集合及最终 AppUI 全测通过；`166`–`171`、`174`–`176` 真实完整空/不完整空、中英文、重扫与输入变更通过；正向 hash 组/取消中途仍缺。 |
| F07 系统路径别名绕过隐私跳过 | `172`、`173`：选择器返回物理 `/private/var/...`，重复页标准化为 `/var/...`；实际 Bulk 日志枚举了两个人工 Dart 文件，tccSkipped=0 | 规则的 `/private/var/folders` 与输入的 Foundation 表示不一致。独立执行现有匹配实现也证实 `/var/db/locationd` 返回 false；未实际扫描 locationd。影响共同 TCC 边界，不能用别名绕过规则做删除验收。 | **未关闭**：复审实测证实候选补丁若直接把 `/private/var/folders` 折叠为 `/var/folders`，会使 `FileManager.default.temporaryDirectory`（`/var/folders/.../T`）下的 `BulkScanner`/`TreeSizeEstimator` 测试 fixture 全部被误判为 `.tccProtectedSkipped`（如 `ScanCoordinatorKnownVersionedRootsTests` 8 处断言失败），且与 `AGENTS.md` 的 `NSTemporaryDirectory()` fixture 合同冲突。需单独设计区分系统受限目录与当前用户临时目录的命名空间规则后再处理。 |

未修改隐私、安全规则、hard-forbid、工程、依赖或发布配置。没有为运行测试放宽产品边界。
成功反馈延续仓库 [删除合同](../DELETION_UX_CONTRACT.md) 的非模态策略；本轮文件回收没有实际执行。

## 已实际操作的子项

这些是用例内的子项结果；例如 T15 的发现完成并不表示工作流真实清理通过。

| 用例 | 实际动作与可观察结果 | 证据与仍缺部分 |
|---|---|---|
| S07/S08、D02 取消分支 | Resources 扫描 16 文件、1.5 MB；Tree 展开/选中 Assets，详情显示 12 文件；键盘打开回收确认并取消，选择保留。 | `03-resources-tree`、`04-tree-confirm-cancel`；未真回收，未覆盖特殊文件。 |
| N01/N02 取消分支 | 普通分析真实选取 Resources；下钻 Assets，再下钻 AppIcon；搜索 Contents 后图/列表同时只剩 1 项 4 kB，清空与面包屑返回恢复 3 项 1.5 MB；重开选择器取消保留结果。 | `113`–`117`；换根、空/消失目录和扫描中换根尚未覆盖。 |
| S07 清单排序 | 三项参考根逐一验证大小、名称、文件数、修改时间的升降序，共八个方向；关闭原生菜单后观察最终顺序，恢复 sizeDesc。 | `118`–`120`、`sort-1`–`sort-7`、`list-sort-checks.json`；Tree 独立表头与时间过滤仍未全验。 |
| S08 Tree 操作 | 展开 Assets 显示 AppIcon/Contents；Finder 实际打开准确目录；选 Contents 后 Space 打开真实 Quick Look，Escape 关闭。刷新实际暴露 F05。 | `143`–`148`；特殊文件、复制路径仍缺。原生行没有名称 AX，坐标按本工具截图比例校正后可操作，不再声称 Tree 无法验收。 |
| S08 F05 修复复验 | 修复构建连续刷新 Assets 两次，再刷新 AppIcon；三个生产 intent 均完成，约 47–53 ms；行内忙指示器消失，选择/12 或 11 文件/容量正确，三级展开显示 16 行。 | `149`–`154`、`subtree-refresh-settled-operation.log`，PID 3328；`settled-native-publication.log` 的 7 项含两项实际挂载 NSHostingView，全部通过。此 C4 不包含回收。 |
| T03/T04 | 自建 Python PID 79401 两个环回监听端口；先确认取消，独立 lsof 仍监听；再由 App 终止，进程消失、两个端口均拒绝连接，列表归零。 | `09`–`13`、`owned-process-result.json`；已复现 F01，修复版两进程批量 `68`–`71`，`fixed-ports-cancel-check.json` / `fixed-ports-result.json` 通过。 |
| T05/T06 | 发现真实 Dart/Flutter 服务但未操作；用本机真实 Dart SDK 在临时目录运行人工监听程序 PID 79543，再经 App 结束，列表归零、端口拒绝连接。 | `14`–`18`、`owned-dart-result.json`；临时工程不在 HOME，项目归属显示未知，不能声称 HOME 项目识别通过。最终真实 Dart PID 93341、端口 63913：自动刷新开关、取消、结束与轻提示见 `93`–`97`，`fixed-dart-result.json` 确认退出。 |
| T01/T07 | 两页发现 62 个应用并保留 incomplete 说明；搜索、选 Typora、无匹配搜索，实际暴露 F02/F03。读取不完整时卸载按钮禁用。 | `25`–`32`；最终 `98`–`104` 复验 F02/F03；`126`、`127` 真实 Finder 选中 Charles.app。未卸载真实软件。 |
| T02 | 启动代理 18 项：用户 8、系统 4、Daemon 6；两处读取不完整明确提示；搜索 Atlas 得一项，清空搜索；手动刷新后 18 项与说明保留，Finder 选中准确 plist 并关闭本轮窗口。 | `23`、`24`、`124`、`125`；未改登录项。 |
| T03/T04/T06 返回与刷新 | 端口页过滤已结束的人工 PID，连续手动刷新两次始终为零；Dart 离页返回、过滤已结束 PID 后刷新仍为零，自动刷新开启。 | `121`–`123`；不能由空结果推断没有重复 timer，timer 生命周期仍待专门观察。 |
| T11 待处理引用 | Assets 加入后队列 1 项 1.4 MB，Tree 菜单显示“已在待处理”；清空取消保留 1 项，清空确认归零；重新加入后行内移除归零，清空文案明确不删磁盘文件。 | `136`–`142`；只改候选引用，未回收原文件；消失项与跨页更多入口待 F。 |
| T08/S10 | Library 只读扫描后停止；开发者版本页等待旧扫描 worker 结算，UI 仍可导航。 | `27`–`29`、`33`、`34`；版本正向结果受系统媒体权限等待阻塞。 |
| T08 后续独立发现 | 新构建无旧 Library worker 后实际完成两次开发者旧版本扫描：28 候选、99,639 文件、3.35 GB；Tree/清单均有结果。独立 metadata 核对 build-tools 候选正好排除最新两版 36.1.0/36.0.0。 | `155`–`157`、`versions-ui-crosscheck.json`；初次等待仍是真实权限问题，不能因此抹掉。实际 current 多跳软链/故障及回收仍缺 F/E。 |
| T12 | 历史有十条既有记录；当前条目显示废纸篓缺失，恢复禁用。 | `35-history-readonly`；未恢复或改动旧记录。 |
| T13 | 已安装显示 120 个版本，独立 Cellar/Caskroom metadata 核对 118+2；CLI 117 个包名的差额为三个双版本 formula。可升级页准确提示 registry 尚无数据。 | `06`、`57`、`brew-*-crosscheck.json`；可升级的正向数据分支未覆盖。 |
| T14 | 清理计划空，容量 0 kB、执行禁用。 | `07-brew-cleanup`；只有空分支，不能推断实际回收正常。 |
| T15/T18 | 四工作流都实际完成发现并展示卡片，见下表。 | `19`–`22`；未回收工作流文件、未操作模拟器。 |
| N06 | 普通状态页显示 CPU/内存/磁盘/网络与滚动历史，切页仍可用。 | `02-status`；未做同时间系统指标交叉核对与 timer 长时间验收。 |
| P01 | 同进程中文切英文、切设置页、打开原生菜单，再恢复中文。 | `36`–`39`、`54`；F04 的窗口标题已修复，原生菜单子项实时切换仍失败，见 `74`–`90`。 |
| P02 | HUD 开/关、五种位置逐一选择，最终恢复关闭与灵动岛位置；关闭时常驻/位置控件禁用。 | `58`–`64`；只验证设置值，独立浮窗的全屏边界视觉未覆盖。 |
| P04 | 阈值 100→110→100 MB，步进与文本同步。 | `38`、`40`、`41`；未用实写大文件验证边界结果。 |
| P05/S05 | 主入口添加 Resources 后设置同步；设置页重复选取同目录得到本地化提示且不重复。再从设置独立添加 Rules，主侧栏同步四项，逐一移除本轮两项后两处回到原有 workspace/amuxuser。 | `42`、`108`、`109`、`133`–`135`、`158`–`161`；不删除目录内容；主入口显式重复导入仍待单独覆盖。 |
| P06 | 打开更新页并实际点 Check now，收敛到 HTTP 404 的本地化失败，无永远 loading。 | `43`、`44`；更新服务可用性未通过，未覆盖新版本下载。 |
| P07 | 实际全关、仅安全、全开，数量 0/48、39/48、48/48；恢复原规则集合。 | `45`–`48`；扫描实际范围与逐项开关仍待验。 |
| P08/P09 | Finder 实际打开日志目录；导出选择器先取消再真实导出到本地证据目录，显示内联成功。独立读取导出 UTF-8 文件，五段均与源日志前缀一致，四个历史段完整相等。清除确认取消保留原日志。 | `49`–`51`、`130`–`132`、`log-export-check.json`；18,636,735 bytes，未上传；常见凭据模式检索零命中不构成绝对脱敏证明。未清生产日志。 |
| P10/P11 | 只读查看已有启用配置及安全输入框；未读取、保存或删除 Key，未发 AI 请求。 | `53-settings-ai-readonly`；配置修改与真实服务调用未验证。 |
| P12 | 高级页显示请求关闭、实际状态未验证，未把未验证状态伪称已运行。 | `52-settings-advanced`；未注册/注销后台服务。 |
| T09 F06 修复复验 | 最终构建先扫 Resources 得完整空结果；改变阈值后回到待扫描，重扫正确；切英文保留同一结果并翻译；移除根后禁用开始。再选人工空 `.photoslibrary` 目录，实际跳过 1 根，显示不完整空结果；恢复中文，再改阈值清除旧 incomplete。 | `166`–`171`、`174`–`176`；没有访问真实媒体库。`172-duplicate-incomplete-temp-en` 的旧文件名不能当不完整通过证据，其内容实际是 F07 的完整空失败现场。正向 hash 分组、运行中取消与真回收仍待 F。 |
| N05/T16、T09 | 系统维护两项及全部执行入口已查看；重复页原三根移除后仅添加 Resources、阈值设 1 MB，实际扫描 16 文件，正向重复组为空，暴露 F06。 | `55`、`56`、`162`–`164`；参考文件均不足 1 MB，空集合合理；没有据此降低阈值或算正向 hash 分组通过。系统维护未执行。 |

## 四工作流逐卡发现

以下容量是当时 UI 展示值，不是“实际可释放空间”证明；未验证 APFS 独占释放量。

| 工作流 / card ID | 发现终态 | 证据 |
|---|---|---|
| Apple / `card.apple.derived-data` | 2 GB，有结果 | `19-workflow-apple` |
| Apple / `card.apple.derived-data-per-project` | 1.61 GB，有结果，未默认选择 | 同上 |
| Apple / `card.apple.archives` | 未发现 | 同上 |
| Apple / DeviceSupport 卡 | 未发现，未把动态候选缺失算作正向清理通过 | 同上 |
| Apple / `card.apple.coresimulator-caches` | 空 | 同上 |
| Apple / `card.apple.coresimulator-devices` | 4.98 GB，managed 发现 | 同上 |
| Apple / `card.apple.coresimulator-runtimes` | 16.43 GB，managed 发现 | 同上 |
| Android / `card.android.gradle-caches` | 21.98 GB | `20-workflow-android` |
| Android / `card.android.gradle-daemon` | 2.05 GB | 同上 |
| Android / `card.android.android-build-cache` | 8 kB | 同上 |
| Android / `card.android.android-cache` | 10 MB | 同上 |
| Android / `card.android.android-avd` | 未发现 | 同上 |
| Android / `card.android.sdk-build-tools` | 1.94 GB | 同上 |
| Android / `card.android.sdk-platforms` | 1.24 GB | 同上 |
| Android / `card.android.sdk-system-images` | 166.9 MB | 同上 |
| Android / `card.android.jetbrains-androidstudio-caches` | 2.07 GB | 同上 |
| Android / `card.android.jetbrains-androidstudio-logs` | 233.4 MB | 同上 |
| Web / `card.webnode.pnpm-store` | 1.04 GB | `21-workflow-webnode` |
| Web / `card.webnode.yarn-cache` | 1.95 GB | 同上 |
| Web / `card.webnode.npm-cache` | 9.15 GB | 同上 |
| Web / `card.webnode.node-gyp-cache` | 247.5 MB | 同上 |
| Web / `card.webnode.electron-cache` | 295.6 MB | 同上 |
| Web / `card.webnode.node-modules-scattered` | 2.31 GB，未默认选择 | 同上 |
| Backend / `card.backend.gradle-caches` | 21.98 GB | `22-workflow-backend` |
| Backend / `card.backend.gradle-wrapper-dists` | 3.35 GB，未默认选择 | 同上 |
| Backend / `card.backend.maven-repository` | 809 MB，未默认选择 | 同上 |
| Backend / `card.backend.maven-wrapper` | 20 MB | 同上 |
| Backend / `card.backend.cargo-caches` | 168 MB | 同上 |
| Backend / `card.backend.rustup-downloads` | 未发现 | 同上 |
| Backend / `card.backend.rustup-toolchains` | 4.07 GB，未默认选择 | 同上 |

Backend 其余条件卡未在当前工具安装状态下出现，不能写成正向扫描/清理通过。

## 扫描等待的实际原因

Library 扫描 worker 阻塞于 `open(~/Library/Caches/com.apple.Music)`。主线程 sample 是正常
event loop，目录不是 dataless、不是软链。TCC 日志显示 `kTCCServiceMediaLibrary` 的
`AUTHREQ_PROMPTING` 正在等待用户，不能按主线程卡死或无权限目录进行猜测修补。
只读 sample/调试器均已结束并 detach；原始证据为 `versions-wait.sample.txt`、
`versions-wait-lldb.txt`、`tcc-wait.log`。

控制工具明确拒绝访问系统权限提示；没有绕过它或修改 TCC/FDA。已请用户在系统提示选择
“不允许”后告知，尚未收到回答。旧 worker 未结算时 primary admission 保持等待，未移除其
保护合同；该诊断会话已正常退出，拒绝授权后的终态与恢复扫描仍需真实验收。

## 验证与剩余项

最终九包与目标 Debug 均通过，属于 C3：ScanKit 549、SafetyKit 181、AppUI 1,503 XCTest
加 11 Swift Testing、HeuristicKit 15、LogKit 50、BrewKit 60、FileSearchKit 23、AIKit 57、
TestHarness 8，共 2,457 个测试项；包全测通过。原生视图 opt-in 项另在
`delivery-native-publication.log` 的 7 项集成集合中实际运行，全部通过；不把该 7 项重复累加。
使用本地已验证的 native scratch build-system，未改 manifest。AppUI 最终全测日志为
`delivery-full-AppUI.log`；其余八包为 `settled-full-<Package>.log`，这些包在 F06 后源码未再变化。
目标构建 `debug-build-delivery.log`，签名 strict/deep 验证和 `git diff --check` 通过。
`verification-summary.json` 核对最终生产源码、测试与完整 bundle 指纹没有变化。
隐私候选补丁仅保存在 ignored build 目录，尚未应用，不在这些通过结论内。
这不将 F04/F07、环境缺口或未执行动作转为通过。

完整测试暴露旧 Undo 用例的等待条件错误：journal append 也会发布 ready，不能据此推断
第二次 bootstrap 完成。现等待第二次 hook 后再检查，重读次数、两个 journal identity 和最终
history 断言均未削弱。初始失败保留在 `full-AppUI.log`，聚焦 `undo-bootstrap-retry.log`。
菜单实验中的人工 target validator 模型无法证明真实 NSMenu sideband 行为；随着实验机制
撤销，其专属测试一并撤销，原有菜单图 action/shortcut 与窗口 attachment 测试保留。
这不是把真实菜单混语判为通过：F04 与 P01/X02 仍明确失败。

最终清理检查见 `cleanup-delivery.json`：语言 zh-Hans、阈值 100 MB、HUD 关闭/灵动岛、
列表 sizeDesc 与普通模式还原；开发者规则偏好键恢复原本不存在的状态；只保留原两条自定义路径。
App 正常退出，五个人工测试进程均不存在。Assets 的 12 个参考文件哈希一致；本轮曾加入待处理
引用，已通过页面逐项移除/清空，未移动原文件。临时目录保留两个人工 Dart 文本文件和一个空
`.photoslibrary` 后缀目录，未绕过回收合同清除它们。生产 pending/journal 均为零且字节哈希与
前次清理一致；Undo 仍十条既有记录，没有执行本轮回收/恢复。正常退出会重写 Undo JSON，
字节哈希变化，不能声称其字节未变。导出的本地日志与原始证据保留在 ignored build 目录，未上传。

最优先仍差人工文件真回收、各入口行/选择/详情/统计同步及完整 Undo/重名恢复。项目要求
真删 fixture 在系统临时目录，产品又禁止 HOME 外清理并跳过其物理根；已申请只用人工
HOME cache fixture 的测试位置例外，尚未获答复。未创建 HOME 人工数据，未回收既有文件。

系统维护、真实软件/模拟器操作、登录服务/TCC 故障、故障恢复需要隔离环境；AI 服务未发送
请求；macOS 13.5、Intel、Release/DMG C5 仍未验证。作者 review 未完成，本轮未提交或推送。

## 未关闭的问题与执行约束

| 条目 | 当前结论 | 下一步 |
|---|---|---|
| F07 隐私路径别名匹配 | 真实临时根通过 `/var` 被扫描；只影响扫描证明，未据此提交回收。 | 规则判断实现修改等待明确授权；候选补丁与独立红/绿探针已备齐，应用后仍须包测试、构建和同路径真实复验。 |
| F04 原生菜单实时语言 | 实际展开后仍有启动语言子项；当前修复只覆盖窗口标题、部分菜单更新。 | 专门处理系统菜单填充生命周期，必须真实展开和执行快捷键；禁止同步通知内读取 AX 或递归菜单构建。 |
| 英文计数语法 | Dart 分组/选择和卸载文件数可见 `1 processes` / `1 files`（`93`、`96`、`103`）。新增成功反馈单复数正确，既有摘要尚未修复。 | 通过现有 Catalog plural 统一处理计数文案，独立排期；不能扩大本轮已经通过的成功反馈结论。 |
| 更新可用性 | 实际 GitHub 请求收敛为 HTTP 404；错误呈现正确，更新可用性未通过。 | 核实发布端数据/可访问性；没有据此更换来源或扩大网络请求。 |
| 媒体权限与取消收敛 | 原扫描被系统媒体权限提示阻塞；只读 sample 已定位，未改 admission/取消合同。 | 用户在系统提示拒绝后验证 worker 结算与新扫描；工具拒绝控制该系统提示，未绕过。 |
| Tree 无障碍信息 | 原生 AX 行没有名称/独立子控件；校正本工具截图的坐标比例后已完成真实展开、待处理、Finder、Quick Look 与刷新。 | UI 自动化可继续；行名称/动作的无障碍完善单独记录，不能把工具坐标误差归因于业务失败。 |

## 75 项逐项执行状态

`部分完成` 只表示已验证某些步骤，不能算整项通过；`待测` 明确表示本轮尚未执行，
不是环境故障。以下记录没有把计划、页面进入或 C3 写成全功能通过。

| ID | 状态 | 已验证范围 / 剩余 |
|---|---|---|
| D01 | 受阻 | F 位置例外待答复；尚未真实移动。 |
| D02 | 受阻 | Tree 键盘确认取消已验；右键/批量真回收缺 F。 |
| D03 | 受阻 | 清单可见且切换正常；真实回收与同步缺 F。 |
| D04 | 受阻 | 普通分析真回收缺 F。 |
| D05 | 受阻 | 大文件真回收缺 V/F。 |
| D06 | 受阻 | 待处理真回收缺 F。 |
| D07 | 受阻 | Smart Care 选中/全部真清理缺 F。 |
| D08 | 受阻 | 重复组真实回收缺 F。 |
| D09 | 受阻 | 真实卸载禁止使用既有软件；需 E 人工 App。 |
| D10 | 受阻 | 30 张卡片实际发现已登记；真实连续回收缺 F/E。 |
| D11 | 受阻 | 清理计划空；实际缓存回收需 E。 |
| D12 | 受阻 | 未产生本轮 receipt；真实 Undo 缺 F。 |
| D13 | 受阻 | 重名恢复缺 F；C2 不替代。 |
| D14 | 受阻 | 回收/Undo 中换扫描缺 F。 |
| D15 | 受阻 | 提交前变更 fixture 的真实拒绝场景缺 F。 |
| D16 | 受阻 | 严格覆盖与受控部分失败需 F/E。 |
| N01 | 部分完成 | 真实选择器、两级下钻、搜索/清空、面包屑返回图表一致；切根尚未覆盖。 |
| N02 | 部分完成 | 选择器取消保留当前结果；空/消失目录与扫描中换根未实际操作。 |
| N03 | 受阻 | 多范围 Smart Care 扫描未完成；媒体权限拒绝仍待操作。 |
| N04 | 待测 | 本轮普通扫描停止/重扫/筛选尚未完成。 |
| N05 | 受阻 | 已进入优化/维护页面；实际系统命令需 E 或具体同意。 |
| N06 | 部分完成 | 系统指标与历史刷新已见；未做同步系统指标交叉核对。 |
| N07 | 受阻 | 历史查看已验；恢复中导航缺本轮 F receipt。 |
| S01 | 受阻 | 四批量入口未全跑；权限处理后继续。 |
| S02 | 待测 | 五推荐分类本轮未逐根完成，不能由工作流发现替代。 |
| S03 | 受阻 | Library 已扫并停止，媒体权限等待；其它四根未全覆盖。 |
| S04 | 待测 | 独立整盘停止/小根重扫尚未完成。 |
| S05 | 部分完成 | 两处添加/移除及设置重复提示、侧栏同步通过；主入口显式重复导入尚缺。 |
| S06 | 待测 | 拖拽/空目录/消失路径未实际操作。 |
| S07 | 部分完成 | Tree/清单切换、清单四键八向顺序通过；Tree 独立表头/时间过滤未全验。 |
| S08 | 部分完成 | 三级展开/详情、Finder、真实 Quick Look；父目录连续/嵌套刷新 F05 修复通过；特殊文件/复制路径待测。 |
| S09 | 受阻 | 阈值步进恢复已验；实写边界 V 与结果筛选未验。 |
| S10 | 部分完成 | Library 停止后可导航，旧 worker 等权限；结算/重扫与连续模式切换待验。 |
| S11 | 受阻 | 已读取等待时主线程 sample；未完成 V 大目录 UI 性能验收。 |
| S12 | 受阻 | 实际硬链接删除/恢复需 F；仅 C2/C3。 |
| S13 | 受阻 | 大小写敏感卷与 current 实际 UI 需 E；仅 C2/C3。 |
| T01 | 部分完成 | 发现/筛选/选中/无匹配/带查询刷新及 Charles 来源与 Finder 通过；多来源展开与排序未全覆盖。 |
| T02 | 通过 | 用户/系统/Daemon 分类、搜索、刷新、typed 不完整说明及 plist 来源/Finder 核对通过。 |
| T03 | 通过 | 搜索、平铺/分组、单/多选、确认取消、连续两次手动刷新及空终态通过。 |
| T04 | 通过 | 人工单 PID/双端口、双 PID/三端口均真实终止，列表归零，socket/PID 独立核对；只对这些步骤有效。 |
| T05 | 部分完成 | 真实 Dart 发现/搜索/自动刷新切换/取消通过；HOME 项目归属和 Finder 未验。 |
| T06 | 部分完成 | 真实 Dart 终止/列表归零/非模态成功/端口释放，离页返回刷新通过；timer 无重复尚未专门核对。 |
| T07 | 部分完成 | 筛选/选择/候选容量/无匹配复测通过；共用厂商与运行 App 分支未全覆盖。 |
| T08 | 部分完成 | 后续新进程两次真实完成 28 候选；Tree/清单及 build-tools 最新两版排除独立核对；current 多跳与故障未验。 |
| T09 | 部分完成 | 完整空/不完整空、重复重扫、输入变更清旧证据、中英文实时切换已验，F06 关闭这些分支；正向人工 hash 组与中途停止尚缺。 |
| T10 | 受阻 | 变更重复组复验需 F，尚未执行。 |
| T11 | 部分完成 | 真实加入/已有成员标识、单项移除、清空取消/确认通过；跨更多入口及消失项需 F。 |
| T12 | 部分完成 | 旧记录十条、失效恢复禁用已验；本轮空/失败/恢复需 F/E。 |
| T13 | 部分完成 | 120 安装版本独立核对；缺 registry 提示正确，正向过期数据未验。 |
| T14 | 部分完成 | 空计划/零容量/执行禁用已验；非空计划勾选/确认需 E。 |
| T15 | 部分完成 | 四工作流 30 张运行卡发现已登记；展开/重试/选择没有逐张完成。 |
| T16 | 受阻 | 未执行系统维护命令；需 E 或具体操作同意。 |
| T17 | 受阻 | 真实模拟器仅发现；managed 删除需 E 人工资源。 |
| T18 | 部分完成 | 四工作流间导航与发现已验；跨卡重叠/取消/连续删除待验。 |
| P01 | 失败 | 窗口标题与大部分页面切换正确，原生展开子项仍混语；跟随系统未验。 |
| P02 | 部分完成 | HUD 开关和五位置设置值已验并恢复；浮窗视觉/隐藏项重扫未验。 |
| P03 | 待测 | 未完成关闭主窗口后 Dock/托盘重开矩阵。 |
| P04 | 部分完成 | 100→110→100 步进和持久值恢复；上下界及实写结果待验。 |
| P05 | 通过 | 设置独立添加 Rules、重复 Resources 提示、两条本轮路径移除与主侧栏同步；原两条保留。 |
| P06 | 受阻 | 实际 Check now 得 HTTP 404 且收敛；新版本/已最新/下载不可判通过。 |
| P07 | 部分完成 | 全关/仅安全/全开 0/39/48，精确恢复默认键；逐项与实际扫描范围未验。 |
| P08 | 部分完成 | 日志 Finder/导出取消/真实 UTF-8 导出与五段内容核对通过；常见凭据模式零命中，未做完整脱敏审计。 |
| P09 | 受阻 | 清除确认取消已验；隔离日志真正清除需 E。 |
| P10 | 受阻 | 已有配置只读查看；未动 Key，修改配置需隔离测试配置。 |
| P11 | 受阻 | 未发 AI 请求；只用获准人工元数据继续验收。 |
| P12 | 受阻 | 关闭/未验证状态只读查看；注册/拒绝/退出登录需 E。 |
| X01 | 部分完成 | 启动、设置开关与快捷键可用；Help 目标与主窗重开未全覆盖。 |
| X02 | 失败 | 原生菜单混语及既有英文单数计数问题；外观/尺寸矩阵未完成。 |
| X03 | 部分完成 | Tree Delete 确认取消、Cmd+,/Cmd+W/Cmd+Q 已验；全键盘矩阵待验。 |
| X04 | 部分完成 | 人工进程确认取消/执行已验；重复提交与事务中导航需 F。 |
| X05 | 受阻 | 真实媒体权限等待已定位；拒绝后恢复及受控 POSIX/ACL 故障需用户/E。 |
| X06 | 失败 | 人工媒体后缀根正确跳过；`/var` 与 `/private/var` 匹配不一致 F07 实际复现，原候选补丁因把 `FileManager.default.temporaryDirectory`（`/var/folders/.../T`）一并判为 TCC 跳过而驳回；其它敏感根/越界对照未全验。 |
| X07 | 受阻 | 只读检查 pending/journal；受控提交故障/重启恢复需 E。 |
| X08 | 部分完成 | 多次换构建保留偏好/十条历史；测试项/偏好已恢复，待处理不持久化未专门验收。 |
| X09 | 受阻 | 当前仅 arm64/macOS 27 Debug；13.5/Intel/Release/DMG C5 未验。 |

## 下一阶段的真实验收顺序

1. **先关闭 F07**：设计区分 `/private/var/folders` 系统跨用户目录与当前进程 `NSTemporaryDirectory()`（`/var/folders/.../T`）的命名空间规则（原候选补丁直接折叠 `/var/folders` 会阻断全仓 `temporaryDirectory` 测试 fixture）；运行聚焦规则/DuplicateScanner 测试、相关包全测与 Debug，再做真实 C4 复测。
2. **优先 D01–D16**：测试位置例外获准后生成 F/V manifest，按 Tree→清单→普通分析→大文件→
   待处理→重复文件/工作流验证真实回收；每次核对源/废纸篓、行/详情/选择/父统计，接着 Undo、
   重名恢复与运行中换扫描。只操作人工数据，不用现有 `build` 目录或真实安装软件试删除。
3. **补齐当前账户的只读缺项**：普通/专业扫描的切根、停止/重扫、筛选、Tree 表头、App 来源/
   排序、窗口托盘与 HUD 真实视觉、状态指标交叉核对。若再次触发系统媒体提示，必须由用户
   处理后才继续确认 worker 的结算，不把导航正常当作扫描已经取消。
4. **隔离 E 与兼容环境**：人工 App 卸载、Homebrew 非空清理、模拟器 managed 删除、服务注册、
   系统维护、权限/提交故障与重启恢复；另做 13.5、Intel、Release/DMG C5。AI 仅在获准的人工
   元数据及端点范围内验证。F04 原生菜单与英文计数文案也必须关闭后，才可宣布对应语言矩阵通过。

本轮已完成计划与首轮真实回归、修复和局部复测；**尚未完成全功能验收**，不得提交“全通过”结论。
