# Changelog

本项目所有显著变更将记录在此文件中。

格式参考 [Keep a Changelog 1.1.0](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

---

## [Unreleased]

### Fixed
- **v2026.07.16 容量口径**：侧栏把“当前物理可用”“macOS 可能释放（估算）”“预计可用上限”拆成三个互不重复的值；System Reclaimable tooltip 改为中英文实时切换，并明确它不是一个可直接“全部清除”的目录，也不再把系统内部 `mobileassetd.cache-delete` 标签伪装成独立文件夹。
- **v2026.07.16 实时本地化**：菜单、设置、工具页、结果页、tooltip/popover 与字节/日期格式统一使用显式 App locale；切换中英文后同一进程立即重投影，不再依赖重启或残留英文缓存。
- **v2026.07.16 Apple Workflow**：DerivedData 改为共享扫描与真实项目元数据归类，修正 `.noindex` 假项目、空 Archives/iOS Device Support、父子重复选择、hard-link 重复计数、单卡刷新拖动整页 loading、旧扫描覆盖新结果等问题；扫描与重试绑定会话 revision 和可取消任务，版本目录在逐子项 I/O 边界协作取消并丢弃整轮部分候选。
- **v2026.07.16 Simulator managed uninstall**：明确仅 Simulator Device 与 Runtime 两类属于系统托管卸载，文件类仍统一移到废纸篓；单一复核 sheet 展示 preparing/validating/submitted/running/stalled/confirmed/unknown/skipped，停止只阻止后续提交、不强杀当前事务。持久账本以跨进程 `flock`、owner PID+kernel start、稳定 scan/review identity 与 attempt generation CAS 阻止重启、迟到终态和 authority probe 的 ABA 重复提交；迟到事件绑定 frozen sourceIntent，仅能投影到同 scan session/revision 与完整 item。
- **v2026.07.16 Trash 主链路**：所有生产删除入口携带稳定 scan/review identity；`NSWorkspace.recycle` 前以跨进程 `flock`、owner PID+kernel start、父 operation、单次 attempt 和 inode identity 冻结提交。PID reuse 与 owner 探针失败均 fail closed；claimed unknown 即使 owner 退出或路径缺失/替换也保持 pending，旧 callback 不能清除或授权新路径实体。
- **v2026.07.16 端口清理**：冻结 PID/UID/可执行文件/内核启动时间并在信号前重验；两轮 `lsof` 只接受稳定监听项，超时、输出截断与退出确认均进入类型化结果，避免把不完整快照或复用 PID 当作可终止目标。
- **v2026.07.16 子进程超时安全**：ScanKit 查询、`pkgutil` receipt 与维护命令统一改为 `posix_spawn` + 唯一 `waitpid` owner；仅在 owned child 明确仍运行时发送 TERM/KILL，已 reap 或 `ECHILD` 后永久禁止信号，关闭 Foundation 先回收后缓存 PID 被复用的误杀窗口。stdout/stderr 从启动起独立、有界排空，`pkgutil` 只解析完整 stdout，超时、ownership lost、launch failure 与真实退出状态均明确收敛。
- **v2026.07.16 Sentinel 与错误呈现**：登录项开关使用单一 MainActor transaction 处理系统回调与 rollback，避免嵌套 modal/通知导致重复 reconcile；扫描、AI、导入导出、Undo、Stash 等界面不再直接显示 raw Error、URL 编码或 enum 文本。
- **v2026.07.16 验证链路**：移除会为每个 case 反复启动并立即退出 App 的 `regression.sh`、只检查窗口/AX 后退出的 `e2e-smoke.sh`、内置 `RegressionRunner`、无人调用的 `GSY_AUTOSCAN` Release 入口、正式 App 对 `TestHarness` 的链接及生成日志。这类快速启停不再冒充 UI 回归；逻辑验证归入 package tests，发行合同使用无启动的静态校验，性能走 ScanKit CLI，真实交互只在单次持续运行的 C4 中留证。

### Added
- `PRIVACY.md`：零遥测隐私协议，明确写出唯一对外网络请求（GitHub Releases API）与本地数据保留范围
- `TERMS.md`：MIT 复述 + 删除操作不可逆免责声明 + 用户责任界定
- `CHANGELOG.md`：本文件
- `.github/release-template.md`：Release Notes 标准模板
- Help 菜单（`CommandGroup(replacing: .help)`）注册官方帮助、隐私协议、使用条款、提交 Issue、在 Finder 中显示日志五个入口
- `UpdateChecker`：解析 GitHub Release `assets[]`，自动拉取同名 `*.sha256` 文件展示给用户做手动完整性校验
- `release.yml`：可选 minisign（ed25519 离线签名）步骤——若仓库配置 `MINISIGN_PRIVATE_KEY` secret，则为 `.dmg` / `.app.zip` 生成 `.minisig` 同名上传，提供"无 Apple Developer Program 也能验签发布者身份"的离线信任链
- `release.yml` + `build_release.sh`：构建后强制开启 macOS **Hardened Runtime**（即使是 ad-hoc 签名也启用），阻止任意 dyld 注入 / 未签名第三方代码加载 / 调试器附加，等同 Rectangle / AltTab 当前的安全等级

### Changed
- `Scripts/build_release.sh` 与 `.github/workflows/release.yml`：每次构建自动注入 `CFBundleVersion = git rev-list --count HEAD`，避免不同 Release 共享同一 build 号导致 Sparkle 升级静默失败或 TCC 权限错复用
- `release.yml` 安装故障兜底章节：删除以前直接教用户跑 `xattr -cr` 的写法，改为优先引导走「系统设置 → 隐私与安全 → 仍要打开」官方路径；保留 xattr 命令但明确标注为"最后手段"并附 SHA256 校验前置条件
- `release.yml` 完整性校验章节：拆分成 SHA256（最低门槛）与 minisign（高级用户）双方案，并明确写出"客户端不自动下载升级包"的设计取舍，避免用户误以为还会接入 Sparkle EdDSA
- `UpdateChecker`：默认使用 ephemeral `URLSession`（`timeoutForRequest=10s`、`timeoutForResource=30s`、`waitsForConnectivity=false`、禁用 cookie / cache），杜绝磁盘缓存与 cookie 持久化
- `UndoHistoryStore.saveHistory`：编码后通过 `Task.detached(.utility)` 后台落盘，避免大批量删除后 MainActor 卡顿 100~300ms；保留 `.synchronous` 策略给测试用
- `GSYLog`：静态可变 `_minimumLevel` / `_fileSink` 改为 `os_unfair_lock` 守护，消除并发 sink 写入时的 data race
- `TrashPipeline` partial-success 修复：`NSWorkspace.recycle` 同时返回 `trashed` 非空 + `error` 非 nil 时（如 100 项中最后 1 项失败），不再丢弃已成功项的 undo pair；错误文案附"(已成功放入废纸篓 X 项，可在「最近删除」恢复)"
- **AUDIT A2**：[DeletionPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/DeletionPipeline.swift) 协议取消 `setAccessDeniedPaths(_:)` 的 protocol extension 默认 no-op——历史默认实现让"上层忘了调"会被静默放行而非 compile-error，是契约靠手记维系的脆弱点；现在每个 `DeletionPipeline` 实现都必须显式提供该方法，杜绝"漏调=误拒"未来重新爬回来；测试 stub（`StubPipelinePR9` / `StubPipeline`）相应补显式 no-op
- **AUDIT A4**：[MainView.performDelete](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift) 与 [MainView.triggerLargeFileTrash](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift) 抽出共用 `runTrash(paths:dryRun:source:)`，收口"accessDenied 注入 / moveToTrash / UndoHistory 写入 / snapshotLastOutcome → sheet/alert" 4 步握手——两处独立维护时任何一步漏掉都会让"上层防护漏失 / 结构化 sheet 退化为文本 alert"成为静默回归，统一收口后从语言层杜绝

### Documented
- `VendorTrieNode`：写明"build-once / read-many"契约，禁止扫描期任何 mutator
- `TrashPipeline`：写明 `setAccessDeniedPaths(_:)` 是唯一可变入口，必须在 MainActor 上 moveToTrash 之前调用

### Security
- 限定 Help 菜单 `openExternal` 只允许 `https://` scheme，防止后续被改成 `file://` / 自定义 scheme 等危险跳转
- Hardened Runtime + ad-hoc 签名：取得"Personal Team 免费账号能拿到的最高被动安全等级"，下一步要更高等级（公证 / Notarization）需购买 Apple Developer Program 个人证书

### Known Limitations (deliberate, 免费 Personal Team 边界)
- **未公证**：没有 Apple Developer ID（$99/yr），无法走 `notarytool submit`，首次启动会触发 Gatekeeper 警告；安装指引已写明走系统设置 → 隐私与安全 → 仍要打开
- **未沙盒化**：扫描需要 `~/Library/Mail` 等用户私有数据，进 App Sandbox 会砍掉关键能力；本项目走"不进沙箱 + Hardened Runtime + 完全磁盘访问"路线
- **客户端不自动下载升级**：`UpdateChecker` 仅做"提示 + 跳转 Release 页"，不引入 Sparkle 框架；signing model 是 minisign 离线验签，而非装在客户端的 EdDSA 公钥

---

## [1.5.6] - 2026-06-04

### Fixed
- 修复扫描结束 / 删除后 `TreeBrowserView` 不实时同步大小、刷新闪烁的问题
- 修复 `ScanCoordinator.flushAndFinalizeStoreAsync` 递归调用导致的偶发崩溃
- 修复 `ScanCoordinator` 中 `try?` 静默吞 I/O 错误的 5 处问题，改成 `do/catch` + `GSYLog.error`

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

[Unreleased]: https://github.com/CarGuo/GSYCleanMac/compare/v1.5.6...HEAD
[1.5.6]: https://github.com/CarGuo/GSYCleanMac/releases/tag/v1.5.6
[1.5.0]: https://github.com/CarGuo/GSYCleanMac/releases/tag/v1.5.0
[1.4.0]: https://github.com/CarGuo/GSYCleanMac/releases/tag/v1.4.0
[1.3.0]: https://github.com/CarGuo/GSYCleanMac/releases/tag/v1.3.0
[1.2.0]: https://github.com/CarGuo/GSYCleanMac/releases/tag/v1.2.0
[1.1.0]: https://github.com/CarGuo/GSYCleanMac/releases/tag/v1.1.0
[1.0.0]: https://github.com/CarGuo/GSYCleanMac/releases/tag/v1.0.0
