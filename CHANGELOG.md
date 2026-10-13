# Changelog

本项目所有显著变更将记录在此文件中。

格式参考 [Keep a Changelog 1.1.0](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

---

## [Unreleased]

## [1.6.2] - 2026-07-20

### Fixed
- **v2026.07.19 Tree 展开性能与终态**：普通全盘扫描和开发者构建产物入口强制使用 `deepIndex=false` 的按需 Tree：一次浅层枚举完成后立即发布**全部**直接子项并清除 fetching，深层容量统计只在后台 enrichment；96 个直接子项的两条产品入口测试证明不会进入 64 行预览分支。仅显式 deep-index 基准/fixture 在 cache miss 时于 MainActor 生成最多 64 行、检查最多 128 个 identity 的非权威预览，同 path/sort/revision 后续 getter 为 O(1)，完整物化、八种排序、索引重建与新增行安全判定由后台 worker 完成。该预览期间父节点保持 loading 且不能进入破坏性操作，完整投影以 revision/CAS 原子替换；切换排序也不再在 getter 同步排列宽数组。新交互取消旧任务后立即执行，不串行等待 predecessor；无关 path ownership 不再让当前 Tree 快照判 stale。新增结构化 `preview_ready/enrichment` 日志与 100k fan-out、MainActor heartbeat、首层完整终态、跨 path CAS、增量 worker防回归测试。
- **v2026.07.19 日志热路径、可达性与生命周期**：文件 sink 复用已验证的 directory/file descriptor，只按每 256 行或 1 秒重验可见 pathname，移除逐条完整路径遍历；可见路径被 unlink、普通 replacement 或目录换位时，保留自上次验证以来最多 4 MiB 的日志窗口，安全重绑后按原序回放，超限写显式计数 marker，symlink/越界路径仍 fail closed。`AmuxLog` 切换、禁用或重启 bootstrap 时，由独立 retirement owner 在配置锁外按 FIFO drain 已接受行后再关闭旧 sink，避免弱引用导致排队日志静默消失；新增 unlink/replay、symlink 恢复、overflow marker、disable drain 与并发 reconfigure 测试及相对 `70fce59e` 的性能 A/B。
- **v2026.07.19 Undo legacy 持续对账**：旧品牌 `UndoHistory.json` 不再只做一次复制后永久让新路径优先；schema-4 在当前 store 中保存各 50,000 上限的 observed record/receipt watermark，每次启动都对仍保留的 legacy 文件做 no-follow、fd-bound、8 MiB 有界读取，在当前 stable flock 下只导入新 UUID，并对仍可见的同 UUID 终态与 receipt 做单调合并。已被 LRU、确认清理或未来显式清除隐藏的旧 ID 不会复活；final source fence 后不协作旧进程继续写的内容保留在旧源并在下一次启动收敛，超限或冲突类型化失败而不伪装空历史。
- **v2026.07.18 隐私与权限合同**：按生产源码重建 `PRIVACY.md` / `SECURITY.md` / `TERMS.md`，明确更新检查与用户主动启用的 AI 是两条联网能力，披露包含绝对路径的本地 JSON、日志、Keychain、导出副本、保留与清除顺序；新增 `PrivacyInfo.xcprivacy`，把可选 AI 可能发送的路径/名称、文件元数据和可识别服务商账户/项目的 API Key 分别保守声明为 `Other User Content`、`Other Data Types`、`User ID`，三类均为 linked、App Functionality、无 tracking/无 tracking domain。Apple 当前只要求 iOS、iPadOS、tvOS、visionOS、watchOS 声明 Required Reason API，本项目是 Developer ID macOS，因此清单不再用移动平台理由码伪装源码 API 清单；发行合同固定这一平台边界。同时补齐 App 数据/App 管理、桌面、文稿、下载、可移动卷、网络卷共 7 类中英文用途说明。AI 请求改用禁 Cookie/cache/共享凭据的独立 ephemeral session；AI 网络错误与本地诊断只保留经验证的 endpoint host、闭集 stage、HTTP status/响应字节数或 transport domain/code，不保存请求正文、API Key、服务端错误正文或模型响应正文。Unified Logging 改为 private hash，避免继续发布“完全离线、无路径持久化”的失实承诺并从实现层收紧披露边界。
- **v2026.07.18 日志可诊断性与文件边界**：本地滚动日志仍保留用户可读的路径和技术诊断，不因隐私收紧而删除业务错误。主 App 启动不再在 UI 线程创建目录、打开文件或枚举保留期；改为后台 bootstrap + 最多 256 行有界内存缓冲，并以 revision 拒绝旧初始化覆盖新配置。文件 sink 的初始化、打开、写入和 Finder/设置访问失败形成独立 writer health；保留、枚举、导出等维护失败按 stage 持久可观察，只有同阶段成功才清除，设置页与 Help 用本地化操作名及 `domain/code` 解释“为什么没有日志/哪一步失败”。日志枚举、导出、保留期清理和手动清理统一使用精确文件名、逐级 no-follow、仅普通单链接文件与活跃 fd/path 身份校验；同名前缀目录、symlink、路径替换或已 unlink 句柄都不能被误删、误导出或伪装成 ready。合并导出改为固定 64 KiB 流式复制到 `0600` 同目录临时文件并 `fsync + renameat` 原子替换，不再把全部保留日志聚合进内存；设置页同时明确 7 天是活动驱动目标，“清理”只作用于主 App 滚动日志。
- **v2026.07.18 Tree 刷新与主线程边界**：右键“刷新此目录”不再只清展示缓存，而是取消并等待旧 producer 后在后台完整重扫子树，重建 `childEdges/dirIndex/fileLeaves`、八种排序投影与 typed incomplete，再以 revision/CAS 原子替换；complete 允许容量缩减，partial 只提高可信下界。修复 `/` 与同名前缀兄弟目录的字符串前缀误判，4096 节点宽目录的物化、排序和旧 COW 析构均不占 MainActor。
- **v2026.07.18 历史记录晚到与刷新单飞**：历史页明确区分 loading、可信空态和存储/完成日志故障；生产后台加载到达后以 storage+record revision 自动启动恢复能力探测，不再永久停在空白或 checking。Store 统一拥有 refresh generation：新请求取消并等待旧探测，每个 pair 协作取消，提交前对完整 history snapshot 做 CAS，journal/restore 并发变化后从最新状态重试，旧观察不能覆盖新状态。
- **v2026.07.18 Sentinel 权限域**：现行后台监控改为登录用户的非特权 `SMAppService.agent`，使 Home、Trash 与清理热点指向真实登录用户；两代 root Label 各保留一份文件名/Label 对应的 migration-only plist。ON 前必须逐项取得 `notRegistered`，`notFound`/未知状态不得伪装成已注销；迁移失败还会安全关闭已存在的当前 Agent。OFF 始终先关闭当前 Agent，旧状态无法确认时保持“未验证”而不回滚 ON。两代真实旧版升级仍需 C4；当前 Agent 的诊断日志在启动、每小时和休眠后的下一次写入检查 7 天保留边界。
- **v2026.07.18 Brew / DerivedData 解析证据**：Brew 的 Installed、Outdated、Cleanup 共用 `missing/complete/partial/unavailable` 权威证据；只有可信枚举才显示空态。Cellar/Caskroom、receipt/JWS、cleanup 根与下载条目的缺失、不可读、损坏、属性和 symlink 失败均类型化，未知 mtime/size/active alias 不进入清理计划；缺失保持正常 cache 状态，其他失败返回 source/stage/reason/path/domain/code/rejected-count 诊断。DerivedData 已存在但不可读/损坏的 `info.plist` 不再静默当作非工程：有独立 hash 身份时保留分类并记录稳定诊断，否则形成 scoped `ScanIncompleteIssue`。
- **v2026.07.18 卸载发现与身份合同**：应用占用与卸载扫描增加 `/Applications`、`~/Applications` 下有限深度的嵌套 App 发现，明确不跟随 symlink、遇到 `.app` 即停止向包内递归；主根、Spotlight、pkg receipt 与文件身份失败都保留类型化 incomplete，不能再把缺失证据伪装成“没有残留”。候选合并按真实 bundle/receipt 归属去重，执行前重读 bundle 元数据并核对冻结的 URL 与文件身份，目录重叠、共享组件和同名弱证据均 fail closed。
- **v2026.07.18 扫描终态与生产者收敛**：Duplicate、Workflow、Bulk 与 MultiRoot 扫描统一持有并等待唯一生产者完成，取消、失败和提前终止都先停止生产再结束消费，避免 detached producer 在页面结束后继续占用磁盘；全盘扫描的 TCC hard-skip 不再因 Full Disk Access 状态而失效，卷路径映射必须保持一一对应，歧义映射直接拒绝。终态的过滤、排序、树快照和完整性证据在后台生成，并以 revision 校验后一次发布，旧任务不能覆盖新页面。
- **v2026.07.18 撤销耐久事务**：系统 recycle callback 先把 operation/attempt、原路径、废纸篓路径和冻结身份写入独立 completion journal，再推进 pending ledger；启动时先幂等重放 journal 到 Undo history，再确认 ledger 并删除交接记录。journal、history 与 receipt 都采用原子替换、文件/父目录 `fsync` 和跨进程锁；同实例写入共用 FIFO 队列，防止并发保存互相覆盖或内存发布顺序倒置。
- **v2026.07.18 系统维护任务**：Quick Look 缓存重建使用系统支持的 `qlmanage -r cache` 参数；维护命令在后台串行执行并保留取消、退出码和类型化结果，页面 revision 变化后旧结果不得覆盖当前状态。
- **v2026.07.16 容量口径**：侧栏把“当前物理可用”“macOS 可能释放（估算）”“预计可用上限”拆成三个互不重复的值；System Reclaimable tooltip 改为中英文实时切换，并明确它不是一个可直接“全部清除”的目录，也不再把系统内部 `mobileassetd.cache-delete` 标签伪装成独立文件夹。
- **v2026.07.16 实时本地化**：菜单、设置、工具页、结果页、tooltip/popover 与字节/日期格式统一使用显式 App locale；切换中英文后同一进程立即重投影，不再依赖重启或残留英文缓存。
- **v2026.07.16 Apple Workflow**：DerivedData 改为共享扫描与真实项目元数据归类，修正 `.noindex` 假项目、空 Archives/iOS Device Support、父子重复选择、hard-link 重复计数、单卡刷新拖动整页 loading、旧扫描覆盖新结果等问题；扫描与重试绑定会话 revision 和可取消任务，版本目录在逐子项 I/O 边界协作取消并丢弃整轮部分候选。
- **v2026.07.16 Simulator managed uninstall**：明确仅 Simulator Device 与 Runtime 两类属于系统托管卸载，文件类仍统一移到废纸篓；单一复核 sheet 展示 preparing/validating/submitted/running/stalled/confirmed/unknown/skipped，停止只阻止后续提交、不强杀当前事务。持久账本以跨进程 `flock`、owner PID+kernel start、稳定 scan/review identity 与 attempt generation CAS 阻止重启、迟到终态和 authority probe 的 ABA 重复提交；迟到事件绑定 frozen sourceIntent，仅能投影到同 scan session/revision 与完整 item。
- **v2026.07.16 Trash 主链路**：所有生产删除入口携带稳定 scan/review identity；`NSWorkspace.recycle` 前以跨进程 `flock`、owner PID+kernel start、父 operation、单次 attempt 和 inode identity 冻结提交。PID reuse 与 owner 探针失败均 fail closed；claimed unknown 即使 owner 退出或路径缺失/替换也保持 pending，旧 callback 不能清除或授权新路径实体。
- **v2026.07.16 端口清理**：冻结 PID/UID/可执行文件/内核启动时间并在信号前重验；两轮 `lsof` 只接受稳定监听项，超时、输出截断与退出确认均进入类型化结果，避免把不完整快照或复用 PID 当作可终止目标。
- **v2026.07.16 子进程超时安全**：ScanKit 查询、`pkgutil` receipt 与维护命令统一改为 `posix_spawn` + 唯一 `waitpid` owner；仅在 owned child 明确仍运行时发送 TERM/KILL，已 reap 或 `ECHILD` 后永久禁止信号，关闭 Foundation 先回收后缓存 PID 被复用的误杀窗口。stdout/stderr 从启动起独立、有界排空，`pkgutil` 只解析完整 stdout，超时、ownership lost、launch failure 与真实退出状态均明确收敛。
- **v2026.07.16 Sentinel 与错误呈现**：登录项开关使用单一 MainActor transaction 处理系统回调与 rollback，避免嵌套 modal/通知导致重复 reconcile；扫描、AI、导入导出、Undo、Stash 等界面不再直接显示 raw Error、URL 编码或 enum 文本。
- **v2026.07.16 验证链路**：移除会为每个 case 反复启动并立即退出 App 的 `regression.sh`、只检查窗口/AX 后退出的 `e2e-smoke.sh`、内置 `RegressionRunner`、无人调用的 `AMUX_AUTOSCAN` Release 入口、正式 App 对 `TestHarness` 的链接及生成日志。这类快速启停不再冒充 UI 回归；逻辑验证归入 package tests，发行合同使用无启动的静态校验，性能走 ScanKit CLI，真实交互只在单次持续运行的 C4 中留证。

### Added
- `PRIVACY.md`：零遥测隐私政策，明确写出 GitHub 更新检查、用户主动启用的 AI 请求、全部已知本地持久化、后台 Agent、权限、保留与清除边界
- `TERMS.md`：MIT 复述 + 移入废纸篓、条件恢复边界与用户责任界定
- `CHANGELOG.md`：本文件
- `.github/release-template.md`：Release Notes 标准模板
- Help 菜单（`CommandGroup(replacing: .help)`）注册官方帮助、隐私协议、使用条款、提交 Issue、在 Finder 中显示日志五个入口
- `UpdateChecker`：解析并校验 GitHub Release 页面与 `assets[]` 元数据；不会自动下载 DMG、`*.sha256` 或其它 asset，用户确认后只把已验证的 Release 页面交给默认浏览器
- `build_release.sh`：本地 Developer ID Application 签名、Hardened Runtime 与最终 DMG-only 公证链路；GitHub `release.yml` 当前为显式停用占位，不生成或上传公开产物

### Changed
- `Scripts/build_release.sh`：本地 Release 默认使用工程 `MARKETING_VERSION`，可选 `VERSION=x.y.z` 覆盖；`CFBundleVersion` 默认取 `git rev-list --count HEAD`，公证和最终 SHA256 顺序仍以 `docs/RELEASE.md` 为唯一合同
- `.github/workflows/release.yml`：移除过时的 ad-hoc App/ZIP/DMG 发布实现，只保留 `if: false` 的显式停用占位；恢复 CI 发布必须重新取得授权并按 Developer ID、DMG-only 公证合同重建
- `UpdateChecker`：只允许固定仓库的 GitHub `latest` API，最终响应、Release 页面和 asset 元数据均按 HTTPS host 与精确 path 复验；默认使用 ephemeral `URLSession`（`timeoutForRequest=10s`、`timeoutForResource=30s`、`waitsForConnectivity=false`、禁用 cookie / cache / credential storage），并拒绝全部 HTTP redirect
- `UndoHistoryStore.saveHistory`：快照、completion journal 与确认清理统一进入实例 FIFO 持久队列；编码和原子落盘均不占用 MainActor，进程退出前可显式排空并同步保存最终快照
- `AmuxLog`：静态可变 `_minimumLevel` / `_fileSink` 改为 `os_unfair_lock` 守护，消除并发 sink 写入时的 data race
- `TrashPipeline` partial-success 修复：`NSWorkspace.recycle` 同时返回 `trashed` 非空 + `error` 非 nil 时（如 100 项中最后 1 项失败），不再丢弃已成功项的 undo pair；错误文案附"(已成功放入废纸篓 X 项，可在「最近删除」恢复)"
- **AUDIT A2**：[DeletionPipeline](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/DeletionPipeline.swift) 协议取消 `setAccessDeniedPaths(_:)` 的 protocol extension 默认 no-op——历史默认实现让"上层忘了调"会被静默放行而非 compile-error，是契约靠手记维系的脆弱点；现在每个 `DeletionPipeline` 实现都必须显式提供该方法，杜绝"漏调=误拒"未来重新爬回来；测试 stub（`StubPipelinePR9` / `StubPipeline`）相应补显式 no-op
- **AUDIT A4**：[MainView.performDelete](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/MainView.swift) 与 [MainView.triggerLargeFileTrash](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/MainView.swift) 抽出共用 `runTrash(paths:dryRun:source:)`，收口"accessDenied 注入 / moveToTrash / UndoHistory 写入 / snapshotLastOutcome → sheet/alert" 4 步握手——两处独立维护时任何一步漏掉都会让"上层防护漏失 / 结构化 sheet 退化为文本 alert"成为静默回归，统一收口后从语言层杜绝

### Documented
- `VendorTrieNode`：写明"build-once / read-many"契约，禁止扫描期任何 mutator
- `TrashPipeline`：写明 `setAccessDeniedPaths(_:)` 是唯一可变入口，必须在 MainActor 上 moveToTrash 之前调用

### Security
- 限定 Help 菜单 `openExternal` 只允许 `https://` scheme，防止后续被改成 `file://` / 自定义 scheme 等危险跳转
- 正式候选使用 Developer ID Application + Hardened Runtime；对外分发链路只公证最终 DMG，并在 staple/validate、Gatekeeper 和最终 SHA256 校验后形成发行证据

### Known Limitations
- **GitHub 工作流停用**：`ci.yml` 与 `release.yml` 的 job 都是 `if: false`；本地构建、测试或 DMG 不会自动上传 GitHub，也不能把 Actions 页面当成当前发行来源
- **未沙盒化**：磁盘占用、其他 App bundle/container 元数据和用户自选根扫描需要跨容器读取能力；本项目走“不进 App Sandbox + Hardened Runtime + 按需系统权限”路线。Mail 等 TCC hard-skip 位置即使已有 Full Disk Access 也不进入内容遍历
- **客户端不自动下载或安装升级**：`UpdateChecker` 只检查固定 GitHub Release API、验证页面与 asset 元数据并提示用户前往发布页；不会自动请求 DMG/校验文件，也不引入静默下载或安装链路
- **真实交互另行验收**：package tests 与 Xcode build 最多形成 C3；ServiceManagement、TCC、FSEvents、扫描流畅度和撤销历史 UI 仍需一次持续 C4，最终 DMG 则需要独立 C5

---

## [1.5.6] - 2026-06-04

### Fixed
- 修复扫描结束 / 删除后 `TreeBrowserView` 不实时同步大小、刷新闪烁的问题
- 修复 `ScanCoordinator.flushAndFinalizeStoreAsync` 递归调用导致的偶发崩溃
- 修复 `ScanCoordinator` 中 `try?` 静默吞 I/O 错误的 5 处问题，改成 `do/catch` + `AmuxLog.error`

### Performance
- `TreeBrowserView`：基于 `consumeLastPrunedPaths` 提示做 flatRows 增量 patch，1 万行树形展开 P95 帧时从 22ms 降到 7ms
- `ScanCoordinator`：用原生 String path 切片替代 NSString 桥接，扫描热路径减少 38% 临时对象分配
- `ScanCoordinator.pruneDeleted`：祖先 dirIndex 计数对称递减，修复二次扫描内存增长

---

## [1.5.0] - 2026-05-xx

### Added
- BrewKit：Step 16-B 包，集成 `brew outdated` / `brew cleanup --dry-run`（7 天冷却 + 50 MB 阈值）
- FileSearchKit：Step 16-A 包，提供日期 / Finder Tags / Spotlight comment 三维筛选
- AppUI Step 4.1 P3：AppFootprint 两阶段流式加载
- 新增 10 条 vendor 规则（包管理器与系统残留）

### Changed
- 默认 vendor 库扩容到 60+ 条，覆盖 Sparkle、Electron、Xcode DerivedData、GPU Metal Shader Cache 等

---

## [1.4.0] - 2026-04-xx

### Added
- Step 17-A：dirIndex / childEdges 内存占用回归契约
- Step 17-B：GRDB store daisychain 顺序契约
- Step 17-C：macOS Installer Leftovers vendor 规则
- Step 17-D：i18n 复数形式 lint 契约
- Step 17-E：GPU / Metal Shader Cache vendor 规则

---

## [1.3.0] - 2026-03-xx

### Added
- 扫描悬浮窗（NSPanel，跨 Space / 全屏不被遮，⌘⇧H 唤起）
- 菜单栏托盘图标（NSStatusItem）
- `LSUIElement` 模式下"关窗 → 仅托盘"
- ScanCoordinator 提升到 App 层，主窗口与 HUD 共享同一份 snapshot

---

## [1.2.0] - 2026-02-xx

### Added
- AppFootprint：按应用聚合占用的二级视图
- 启发式扫描缓存（`HeuristicScanStore.json`），二次扫描秒级出结果
- 撤销历史（`UndoHistoryStore`）支持「最近删除」面板

---

## [1.1.0] - 2026-01-xx

### Added
- 更新检查器：启动时静默 GET 一次 GitHub Releases API，菜单 → 「检查更新…」入口
- 多语言支持（简中 / 英文）
- Sentinel 命令行小工具：开机自启时静默扫描 + URL Scheme 回调主 App

---

## [1.0.0] - 2025-12-xx

### Added
- 首次发布
- 启发式扫描：~/Library/Caches / Logs / Application Support 等
- Vendor 规则系统（YAML 驱动）
- 安全保护：SafetyKit 三层校验（白名单 / 路径深度 / 用户主目录约束）
- 删除流水线：移入废纸篓 / 直接抹除 双模式
- ⌘, 设置窗口（隐藏文件 toggle / 大文件阈值 / 自定义路径）

---

[Unreleased]: https://github.com/CarGuo/AmuxAIClean/compare/v1.6.2...HEAD
[1.6.2]: https://github.com/CarGuo/AmuxAIClean/compare/v1.6.1...v1.6.2
[1.5.6]: https://github.com/CarGuo/AmuxAIClean/releases/tag/v1.5.6
[1.5.0]: https://github.com/CarGuo/AmuxAIClean/releases/tag/v1.5.0
[1.4.0]: https://github.com/CarGuo/AmuxAIClean/releases/tag/v1.4.0
[1.3.0]: https://github.com/CarGuo/AmuxAIClean/releases/tag/v1.3.0
[1.2.0]: https://github.com/CarGuo/AmuxAIClean/releases/tag/v1.2.0
[1.1.0]: https://github.com/CarGuo/AmuxAIClean/releases/tag/v1.1.0
[1.0.0]: https://github.com/CarGuo/AmuxAIClean/releases/tag/v1.0.0
