# Changelog

本项目所有显著变更将记录在此文件中。

格式参考 [Keep a Changelog 1.1.0](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

---

## [Unreleased]

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
