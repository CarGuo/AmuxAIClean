# GSYCleanMac - 开发者产物清理规则手册（DEV_ARTIFACTS_RULES）

> 编写日期：2026-05-23
> 版本基线：GSYCleanMac v1.2（基于 [SafetyEngine](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) 三档判定 + [vendors.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml) 厂商规则体系）
> 适用范围：macOS 15 Sequoia 或更高
> 目的：把"开发者机器上反复升级、版本切换沉淀下来的冗余产物"整合成一张**可落地、可 PR、可单测**的安全清理规则表，替换团队过去散落在脚本里的 `rm -rf` 经验。

---

## 0. TL;DR

开发者机器（尤其同时跑 iOS / Android / RN / Flutter / 后端）的 macOS 磁盘冗余典型分布：

| 生态 | 典型占用 | 主目录 |
|---|---|---|
| Xcode（DerivedData / Archives / DeviceSupport / Simulators / SPM） | 25–60 GB | [~/Library/Developer/](file:///Users/guoshuyu/Library/Developer) |
| Docker / Colima 镜像与卷 | 10–30 GB | `~/Library/Containers/com.docker.docker` 等 |
| Node.js（npm / yarn / pnpm 全局缓存 + 散落 node_modules） | 5–15 GB | `~/.npm`、`~/Library/Caches/Yarn`、pnpm store |
| Rust / Cargo registry + Rustup toolchains | 3–10 GB | `~/.cargo`、`~/.rustup` |
| Python pip / Poetry / Conda / venv / pyenv | 2–8 GB | `~/Library/Caches/pip` 等 |
| Android / Gradle / AVD / Android Studio | 5–12 GB | `~/.gradle`、`~/.android`、`~/Library/Caches/Google/AndroidStudio*` |
| Homebrew bottles / 旧版本 | 2–5 GB | `~/Library/Caches/Homebrew` |
| IDE 缓存（VS Code / Cursor / JetBrains） | 2–5 GB | `~/Library/Application Support/<ide>`、`~/Library/Caches/<ide>` |
| Flutter / Go / Ruby / CocoaPods | 2–8 GB | `~/.pub-cache`、`~/go`、`~/.gem`、`~/.cocoapods` |

合计可回收量 **38–118 GB**——这是社区量化结论（CodeCleaner / ClearDisk 多家工具的统计基本一致）。

本文给出一张**与项目 SafetyEngine 三档（safe / confirm / forbid）严格对齐**的规则表，可直接：
1. 转写为 [vendors.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml) 条目（带 `bundle_id_prefix` + `paths` + `safety` + `reason`）；
2. 接入 [ScanCategories.recommended](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCategory.swift#L79-L117) 增加"开发者清理"专区；
3. 用 [SafetyEngineTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Tests/SafetyKitTests/SafetyKitTests.swift) 钉死契约。

---

## 0.1 实施进度跟踪表

> 本表跟踪本文档中的规则与代码实施状态。新增规则时，**必须**同步更新此表。

### 阶段 A：文档自洽
| 任务 | 状态 | PR / Commit | 备注 |
|---|---|---|---|
| A1 修复 Docker vendor 锚点错位（§2.6 `vendors.yaml#L41` → `L81-L83`） | 已落地 | 本次 | [vendors.yaml#L81-L83](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml#L81-L83) |
| A1 新增本进度跟踪表 | 已落地 | 本次 | — |

### 阶段 B：硬安全网补全（最高优先级，与 §2.7 黄金禁区对齐）
| 任务 | 状态 | 关联规则 | 落地点 |
|---|---|---|---|
| B1.1 SSH/GPG/AWS/GitHub CLI 凭证目录 forbid | 已落地 | §2.7 `~/.ssh ~/.gnupg ~/.aws ~/.config/gh` | [SafetyEngine.dotfileCredentialSuffixes](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L72-L99) |
| B1.2 全局包管理器配置（`.netrc`/`.npmrc`/`.yarnrc`/`.pypirc`/`.gitconfig`/`.git-credentials`） | 已落地 | §2.7 | 同上 |
| B1.3 Apple keychain / TCC / Provisioning Profiles | 已落地 | §2.7 + §2.1 末尾 | [SafetyEngine.libraryCredentialSuffixes](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L101-L107) |
| B1.4 Android 签名 / adb 授权（`debug.keystore`/`adbkey`/`adbkey.pub`） | 已落地 | §2.3 + §2.7 | [SafetyEngine.dotfileCredentialSuffixes](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L72-L99) |
| B1.5 Gradle/Cargo/Maven/Kube 全局凭证配置 | 已落地 | §2.3/§2.6/§2.7 | 同 B1.1 |
| B1.6 SwiftPM 私有 keychain（`org.swift.swiftpm/security`） | 已落地 | §2.1 倒数第二行 | [SafetyEngine.libraryCredentialSuffixes](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L101-L107) |
| B1.7 文件名后缀禁区（`*.jks` `*.keystore` `*.p12` `*.pfx` `*.mobileprovision` `*.provisionprofile`） | 已落地 | §2.7 | [SafetyEngine.hardForbidSuffixes](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L109-L117) |
| B1.8 路径段禁区（任意深度 `.git`） | 已落地 | §2.7 | [SafetyEngine.hardForbidPathSegments](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L119-L123) |
| B2 新增 4 组黄金禁区契约测试（凭证 / 后缀 / `.git` 段 / 边界负样本） | 已落地 | — | [testGoldenZone*](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Tests/SafetyKitTests/SafetyKitTests.swift#L82-L199) |
| B3 性能基准 budget 重新校准（100→200ms 本地 / 250→350ms CI） | 已落地 | — | [VendorTrieTests#L88-L100](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Tests/SafetyKitTests/VendorTrieTests.swift#L88-L100) |

### 阶段 C：vendors.yaml schema 升级（path 级 verdict + reason）
| 任务 | 状态 | 备注 |
|---|---|---|
| C1 [VendorRule](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/RuleLoader.swift#L4-L52) 增加 `paths: [PathRule]` 可选字段 | 已落地 | 新增 [PathRule](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/RuleLoader.swift#L66-L81) 结构（path/verdict/reason/recipe），parser 支持嵌套 yaml；向后兼容现有 vendors.yaml |
| C2 [VendorTrie](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/VendorTrie.swift#L20-L28) 接收 path 级 verdict 覆盖 | 已落地 | 节点新增 [pathOverride](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/VendorTrie.swift#L25-L25)，[match](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/VendorTrie.swift#L86-L109) 让 override 沿子树继承；engine 中 [path 级 override 分支](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L300-L317) 优先于默认 confirm |
| C2.1 新增 `SafetyRejection.vendorPathRule` 拒绝原因 | 已落地 | [SafetyEngine.swift#L20](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L20-L20) 便于审计 / 日志区分硬安全网与规则覆盖 |
| C2.2 path 级 override 不能绕过硬安全网 | 已落地 | base `.forbid` 在 [SafetyEngine evaluate L295](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L295-L295) 短路；契约测试 [testPathOverrideCannotBypassHardForbid](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Tests/SafetyKitTests/RuleLoaderTests.swift#L259-L274) 钉死语义 |
| C3 [RuleLoaderTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Tests/SafetyKitTests/RuleLoaderTests.swift) + [VendorTrieTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Tests/SafetyKitTests/VendorTrieTests.swift) 覆盖新字段 | 已落地 | 新增 11 条测试：解析 / 后向兼容 / 非法 verdict / hardForbid 过滤 / safe 降级 / 子树继承 / forbid 升级 / 硬安全网兜底 / trie 节点存储 |

### 阶段 D：批量数据落地
| 任务 | 状态 | 关联章节 |
|---|---|---|
| D0b [loadVendors](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/RuleLoader.swift#L92-L127) 过滤策略细化：保留"显式 verdict=forbid"的多重防御条目 | 已落地 | §2.7 |
| D1 Apple/Xcode/iOS 模拟器规则（§2.1 全部 21 条 path-rule） | 已落地 | §2.1 |
| D2.1 JetBrains 全家桶 + VS Code/Cursor/Trae（§2.2，JetBrains 13 + Code 6 + Cursor 6 + Trae 6 = 31 条 path-rule） | 已落地 | §2.2 |
| D2.2 Android / Gradle / AndroidStudio（§2.3，Gradle 7 + Android 8 + AndroidStudio 4 = 19 条 path-rule） | 已落地 | §2.3 |
| D2.3 PathGlob 最小子集（`*` / `?`，不跨 `/`）+ VendorTrie globRules 旁路桶 + 装载时硬安全网探测 | 已落地 | [PathGlob.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/PathGlob.swift) / [VendorTrie.matchGlob](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/VendorTrie.swift) / [RuleLoader.literalPrefix](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/RuleLoader.swift) |
| D3.1 §2.5 RN/Flutter/前端工具链（CocoaPods 4 + NodePackagers 10 + Flutter 3 + ReactNative 4 = 21 条） | 已落地 | §2.5 |
| D3.2 §2.6 后端 / 通用工具链（Cargo 5 + Rustup 1 + Python 3 + Homebrew 2 + Go 2 + Ruby 2 + Containers 6 = 21 条） | 已落地 | §2.6 |

### 阶段 E：UI 专区与智能 Probe
| 任务 | 状态 | 关联章节 |
|---|---|---|
| E1 [ScanCategories](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCategory.swift) 新增 `dev.artifacts` 类目 |  计划中 | §4 Phase 2 |
| E2.a iOS 模拟器 unavailable 设备 probe |  计划中 | §3.1 |
| E2.b Gradle wrapper / NDK 多版本收敛（共享 SemVer 工具） |  计划中 | §3.2 §3.3 |
| E2.c JetBrains 旧版本目录聚合 |  计划中 | §3.4 |
| E3 UI"操作处方"卡片（仅引导，不调外部进程） |  计划中 | §3.5 §4 Phase 3 |

> **图例**：已落地（PR 合并）｜ 计划中（已建条目）｜⏸ 已暂缓｜已废弃

---

## 1. 字段约定（与现有 SafetyEngine 对齐）

每条规则一定包含 4 个字段，**与 [vendors.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml) 现有 schema 一致**：

| 字段 | 取值 | 含义 |
|---|---|---|
| `path` | 绝对路径（`~` 允许）；末尾以 `/` 表前缀匹配 | 经 [SafetyEngine.evaluate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L85-L97) 标准化后做严格 `hasPrefix` 比较 |
| `verdict` | `safe` / `confirm` / `forbid` | 与 [SafetyVerdict](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L4-L8) 同名枚举一一对应 |
| `bundle_id_prefix` | 反向匹配 App 卸载残留时使用（可选） | 仅当规则属于某个 vendor 应用时填写 |
| `reason` | 一句中文短语，UI 直接展示 | 解释为什么默认勾 / 不勾，避免用户黑盒操作 |

三档语义复述（来自 [SafetyEngine.swift L4-L8](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L4-L8)）：

-  **safe**：删除后**只损失重新下载/重建时间**，不丢源码、不丢账号、不破坏链接。UI 默认勾选。
-  **confirm**：删除可恢复但**会丢调试态 / 登录态 / 编辑器布局**，或牵连构建链。UI 默认不勾，弹二次确认。
-  **forbid**：删除会**毁掉源码 / 凭证 / 跨工具引用**，引擎一律拒绝。

**原则**（沿用 [PITFALLS §0](file:///Users/guoshuyu/workspace/GSYCleanMac/PITFALLS.md)）：
1. 任何不确定一律向 `confirm` 倾斜，宁可漏报不可误删。
2. 删除路径走 [TrashPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift) 的 `NSWorkspace.recycle` 进废纸篓，绝不调用 `sudo` / `rm -rf` 子进程。
3. 涉及"必须走 CLI 才能正确清"的（如 `xcrun simctl delete`、`docker system prune`），**不进默认勾选**，UI 走 `confirm` 并附操作建议。

---

## 2. 规则总表（按生态）

> 表内 `~` 代表 `NSHomeDirectory()`；`*` / `**` 为 glob，与 [safe_paths.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/safe_paths.yaml) 写法一致。

### 2.1 Apple / Xcode / iOS 模拟器

| 路径 | verdict | 典型量 | 推荐姿势 | reason |
|---|---|---|---|---|
| `~/Library/Developer/Xcode/DerivedData/**` | [safe] | 5–30 GB | 直接删 | 构建中间产物，下次 build 自动重建。已在 [safe_paths.yaml L9-L10](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/safe_paths.yaml#L9-L10) |
| `~/Library/Developer/Xcode/Archives/**` | [confirm] | 1–20 GB | 默认不勾 | TestFlight / App Store 上传记录，**包含 dSYM**，删后无法符号化历史 crash。已在 [safe_paths.yaml L13-L16](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/safe_paths.yaml#L13-L16) |
| `~/Library/Developer/Xcode/iOS DeviceSupport/**` | [safe] | 1–10 GB | 直接删 | 真机调试符号缓存，连接设备时 Xcode 自动重下。已在 [safe_paths.yaml L11-L12](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/safe_paths.yaml#L11-L12) |
| `~/Library/Developer/Xcode/watchOS DeviceSupport/**` | [safe] | 0.5–3 GB | 直接删 | 同上，watchOS 对应表 |
| `~/Library/Developer/Xcode/macOS DeviceSupport/**` | [safe] | 0.5–2 GB | 直接删 | 同上，macOS 对应表 |
| `~/Library/Developer/Xcode/iOS DeviceLogs/**` | [confirm] | 100 MB–1 GB | 默认不勾 | 真机 crash log，调试期间可能要复盘 |
| `~/Library/Developer/Xcode/UserData/IDEEditorInteractivityHistory/**` | [safe] | 100–500 MB | 直接删 | 编辑器交互历史 |
| `~/Library/Developer/Xcode/UserData/IB Support/**` | [safe] | 50–200 MB | 直接删 | Interface Builder 临时缓存 |
| `~/Library/Developer/Xcode/UserData/Previews/**` | [safe] | 200 MB–2 GB | 直接删 | SwiftUI Previews 派生数据 |
| `~/Library/Developer/CoreSimulator/Caches/**` | [safe] | 1–5 GB | 直接删 | 模拟器运行时缓存。已在 [safe_paths.yaml L17-L18](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/safe_paths.yaml#L17-L18) |
| `~/Library/Developer/CoreSimulator/Devices/<UDID>/` | [confirm] | 单个 0.5–8 GB | **走 `xcrun simctl delete <UDID>`** | iOS 模拟器实例。直接 `rm` 会污染 [device_set.plist](file:///Users/guoshuyu/Library/Developer/CoreSimulator/Devices/device_set.plist)；删除会丢 App 沙盒数据。**已 unavailable runtime 的 device 高价值低风险**（见 §3.1） |
| `~/Library/Developer/CoreSimulator/Volumes/**` | [forbid] | — | 引擎拦截 | 已挂载的卷，删了会让 simctl 永久卡住 |
| `~/Library/Developer/Xcode/DocumentationCache/**` | [safe] | 200 MB–2 GB | 直接删 | 离线文档缓存 |
| `~/Library/Caches/com.apple.dt.Xcode/**` | [safe] | 1–5 GB | 直接删 | Xcode 主进程缓存 |
| `~/Library/Caches/org.swift.swiftpm/**` | [safe] | 0.5–3 GB | 直接删 | SwiftPM 全局缓存 |
| `~/Library/org.swift.swiftpm/security/**` | [forbid] | — | 引擎拦截 | SwiftPM 私有 keychain 数据 |
| `~/Library/Developer/Xcode/Toolchains/**` | [confirm] | 0.3–2 GB / 个 | 默认不勾 | 第三方 toolchain（如 swift.org nightly），删了 build 会失败 |
| `~/Library/Developer/Xcode/UserData/KeyBindings/**` | [forbid] | — | 引擎拦截 | 用户自定义快捷键，丢了不可恢复 |
| `~/Library/Developer/Xcode/UserData/FontAndColorThemes/**` | [forbid] | — | 引擎拦截 | 用户主题 |
| `~/Library/Developer/Xcode/UserData/CodeSnippets/**` | [forbid] | — | 引擎拦截 | 用户 snippet |
| `~/Library/MobileDevice/Provisioning Profiles/**` | [forbid] | — | 引擎拦截 | 描述文件，删了真机 / 上架直接断 |

### 2.2 JetBrains 全家桶（IntelliJ / PyCharm / WebStorm / GoLand / CLion / Rider / DataGrip / RubyMine / PhpStorm / AppCode / AndroidStudio）

> 路径模式来自 JetBrains 官方文档：[Directories used by the IDE](https://www.jetbrains.com/help/idea/directories-used-by-the-ide-to-store-settings-caches-plugins-and-logs.html)（2026-03 更新）。<product> = `IntelliJIdea` / `PyCharm` / `WebStorm` / `GoLand` / `CLion` / `Rider` / `DataGrip` / `RubyMine` / `PhpStorm` / `AppCode` / `AndroidStudio` 等。<version> 形如 `2024.3`、`2025.1`。

| 路径 | verdict | 典型量 | 推荐姿势 | reason |
|---|---|---|---|---|
| `~/Library/Caches/JetBrains/<product><version>/**` | [safe] | 100 MB–3 GB / 版本 | 直接删 | 索引 / 编译缓存（`idea.system.path`），重启后会自动重建 |
| `~/Library/Logs/JetBrains/<product><version>/**` | [safe] | 50–500 MB / 版本 | 直接删 | IDE 日志 / 线程 dump |
| `~/Library/Application Support/JetBrains/<product><version>/plugins/**` | [confirm] | 200 MB–2 GB / 版本 | 默认不勾 | 已装插件目录，删了 IDE 启动后插件清空，需重新登录 plugin 市场 |
| `~/Library/Application Support/JetBrains/<product><version>/`（去掉 plugins） | [forbid] | — | 引擎拦截 | **IDE 配置 + 用户密钥**（`idea.config.path`），含 SSH key / 数据库连接 / Keymap，删了不可逆 |
| `~/Library/Application Support/JetBrains/Toolbox/**` | [confirm] | 100 MB–1 GB | 默认不勾 | Toolbox 状态目录，删了重新登录账号 |
| `~/Library/Caches/JetBrains/<product><OLD>/**`（**未在最近 180 天访问**） | [safe] | 累积 1–8 GB | 推荐勾选 | JetBrains 自身从 2021.2 起也会自动清，开源圈共识。社区帖：[Can delete large files previous version safely?](https://intellij-support.jetbrains.com/hc/en-us/community/posts/26903696994450) |
| `~/Library/Logs/JetBrains/<product><OLD>/**`（旧版本） | [safe] | — | 推荐勾选 | 同上 |
| `~/Library/Application Support/JetBrains/<product><OLD>/`（旧版本配置） | [confirm] | 200 MB–2 GB | 默认不勾 | 旧版本配置可在新版本中导入；JetBrains 提供 Help \| Delete Leftover IDE Directories... 也是确认式 |
| `~/Library/Application Support/JetBrains/consentOptions/**` | [confirm] | <10 MB | 默认不勾 | 用户隐私同意状态，删了会再次弹同意框 |

> 历史路径（2019.3 及更早）：`~/Library/Preferences/<product><version>` / `~/Library/Caches/<product><version>`。**不在新装机出现，仅遗留升级用户**——可作为"残留扫描"专项目标，verdict 同上。

#### VS Code / Cursor / Trae

| 路径 | verdict | 典型量 | 推荐姿势 | reason |
|---|---|---|---|---|
| `~/Library/Application Support/Code/Cache/**` | [safe] | 100 MB–1 GB | 直接删 | HTTP / 资源缓存 |
| `~/Library/Application Support/Code/CachedData/**` | [safe] | 200 MB–2 GB | 直接删 | 主进程预编译 |
| `~/Library/Application Support/Code/CachedExtensionVSIXs/**` | [safe] | 200 MB–1 GB | 直接删 | 已下载的 .vsix 临时文件 |
| `~/Library/Application Support/Code/logs/**` | [safe] | 50–500 MB | 直接删 | 日志 |
| `~/Library/Application Support/Code/User/workspaceStorage/**` | [confirm] | 100 MB–2 GB | 默认不勾 | 每个 workspace 的 IndexedDB / 状态，删了打开旧项目会丢面板布局 |
| `~/Library/Application Support/Code/User/globalStorage/**` | [forbid] | — | 引擎拦截 | 含已登录账号 token、设置同步密钥 |
| `~/Library/Application Support/Cursor/**`（同上各子目录） | — | — | 套用 Code 同款 | Cursor 是 Code fork，目录结构一致 |
| `~/Library/Application Support/Trae/**`（同上各子目录） | — | — | 套用 Code 同款 | Trae 同 Electron 系，[vendors.yaml L119-L122](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml#L119-L122) 已收 |

### 2.3 Android（SDK / AVD / Gradle / Android Studio）

| 路径 | verdict | 典型量 | 推荐姿势 | reason |
|---|---|---|---|---|
| `~/.gradle/caches/**` | [safe] | 5–30 GB | 直接删（先 `./gradlew --stop`） | Gradle 依赖与 transforms，下次 build 重新下。Gradle 8+ 自带 30 天 GC |
| `~/.gradle/caches/transforms-*` | [safe] | 1–10 GB | 直接删 | dexing / desugaring 中间产物 |
| `~/.gradle/caches/journal-1` | [safe] | <100 MB | 直接删 | 缓存 bookkeeping |
| `~/.gradle/wrapper/dists/gradle-<OLD>-*` | [safe] | 1–5 GB | 推荐勾选 | 旧 Gradle 发行版，每个 130–285 MB；按文件夹名版本号倒序保留最新 2 个即可 |
| `~/.gradle/daemon/**` | [safe] | 0.5–2 GB | 直接删（先 `./gradlew --stop`） | Daemon 日志 / registry，进程关闭后无引用 |
| `~/.gradle/build-scan-data/**` | [safe] | 100 MB–1 GB | 直接删 | 构建扫描数据 |
| `~/.gradle/configuration-cache/**` | [safe] | 100–500 MB | 直接删 | 配置缓存，下次 build 重建 |
| `~/.gradle/init.d/**` | [forbid] | — | 引擎拦截 | 用户初始化脚本（凭证 / repo 配置） |
| `~/.gradle/gradle.properties` | [forbid] | — | 引擎拦截 | 用户全局 properties，**常含 sonatypeUser / token** |
| `~/.android/cache/**` | [safe] | 1–5 GB | 直接删 | Android build cache（transforms） |
| `~/.android/build-cache/**` | [safe] | 0.5–3 GB | 直接删 | 同上旧版命名 |
| `~/.android/avd/**` | [confirm] | 单 AVD 2–5 GB | **走 Android Studio Device Manager → Wipe Data 或 `avdmanager delete avd`** | 模拟器实例，直接 `rm` 会让 AVD Manager 状态错乱 |
| `~/.android/avd/<name>.avd/snapshots/**` | [safe] | 0.3–2 GB | 直接删 | AVD 启动快照，删了第一次冷启动会慢 |
| `~/.android/avd/<name>.avd/userdata*.img` | [confirm] | 0.5–3 GB | 默认不勾 | 用户数据镜像，删了 App 沙盒数据丢失 |
| `~/.android/sdk/**` | [forbid] | — | 引擎拦截 | Android SDK 本体，删了所有项目 build 失败；管理走 SDK Manager |
| `~/Library/Android/sdk/**` | [forbid] | — | 引擎拦截 | 同上（默认安装位置） |
| `~/.android/debug.keystore` | [forbid] | — | 引擎拦截 | 调试签名 keystore，删了会让旧 debug 包认证失败 |
| `~/.android/adbkey` / `~/.android/adbkey.pub` | [forbid] | — | 引擎拦截 | adb 设备授权密钥 |
| `~/Library/Caches/Google/AndroidStudio<version>/**` | [safe] | 200 MB–3 GB | 直接删 | AS 索引 / 编译缓存（同 JetBrains 系） |
| `~/Library/Logs/Google/AndroidStudio<version>/**` | [safe] | 50–500 MB | 直接删 | AS 日志 |
| `~/Library/Application Support/Google/AndroidStudio<version>/**` | [forbid] | — | 引擎拦截 | AS 配置 + 插件，含 SDK Path 等关键设置 |

### 2.4 NDK / CMake / Native 工具链

| 路径 | verdict | 典型量 | 推荐姿势 | reason |
|---|---|---|---|---|
| `<sdk>/ndk/<version>/`（旧版本） | [confirm] | 1.5–3 GB / 版本 | 默认不勾 | NDK 版本由 `build.gradle` 中 `ndkVersion` 锁定，删错版本编译断裂；推荐"保留最新两个版本"策略 |
| `<sdk>/ndk-bundle/` | [confirm] | 2–4 GB | 默认不勾 | 旧式 NDK 安装位置，已废弃但仍可能被老项目引用 |
| `<sdk>/cmake/<version>/`（旧版本） | [safe] | 100–300 MB / 版本 | 推荐勾选 | CMake 由 SDK Manager 维护，重新下载即可 |
| `<sdk>/build-tools/<OLD>/`（旧版本） | [confirm] | 100–500 MB / 版本 | 默认不勾 | 旧 build-tools 仍可能被某些 module 引用 |
| `<sdk>/platforms/android-<OLD>/`（旧 API） | [confirm] | 50–200 MB / 版本 | 默认不勾 | compileSdk / targetSdk 锁定，删了对应 API 项目无法编译 |
| `<sdk>/system-images/**` | [confirm] | 单镜像 1–3 GB | 默认不勾 | AVD 用的系统镜像，未在 AVD 引用的可清；引用判断需读 AVD config |
| `<sdk>/.temp/**` / `<sdk>/temp/**` | [safe] | 100 MB–2 GB | 直接删 | SDK Manager 下载临时目录 |
| `~/Library/Caches/com.google.android.studio.SDKManager/**` | [safe] | <500 MB | 直接删 | SDK Manager 自身缓存 |

### 2.5 React Native / Flutter / Hybrid

| 路径 | verdict | 典型量 | 推荐姿势 | reason |
|---|---|---|---|---|
| `~/.cocoapods/repos/trunk/**` | [safe] | 1–3 GB | 直接删 | CocoaPods 主 spec 仓库，下次 `pod install` 自动 `pod repo update` 重建 |
| `~/.cocoapods/repos/<other>/**` | [confirm] | 100 MB–1 GB | 默认不勾 | 私有 spec 仓库，删了需手动 `pod repo add` 重新拉 |
| `~/Library/Caches/CocoaPods/Pods/Release/**` | [safe] | 1–5 GB | 直接删 | 解压后的 pod 二进制缓存 |
| `~/Library/Caches/CocoaPods/Pods/External/**` | [safe] | 0.5–2 GB | 直接删 | external 来源 pod 解压缓存 |
| `<project>/Pods/` | [confirm] | 项目级 0.3–3 GB | 默认不勾 | **属于项目目录**，工程默认外的扫描不会触达；自定义路径扫描时提示走 `pod deintegrate` |
| `~/Library/Caches/Yarn/**` | [safe] | 1–5 GB | 直接删 | Yarn v1 全局缓存，等价 `yarn cache clean` |
| `~/Library/Caches/Yarn/v6/**` | [safe] | — | 直接删 | 同上 v6 子目录 |
| `~/.yarn/berry/cache/**` | [safe] | 0.5–3 GB | 直接删 | Yarn Berry 全局缓存 |
| `~/.npm/_cacache/**` | [safe] | 1–8 GB | 直接删（等价 `npm cache clean --force`） | npm v7+ 内容寻址缓存 |
| `~/.npm/_logs/**` | [safe] | 50–500 MB | 直接删 | npm 日志 |
| `~/.npm/_npx/**` | [safe] | 100 MB–1 GB | 直接删 | `npx` 临时安装包 |
| `~/Library/pnpm/store/v3/**` 或 `~/.local/share/pnpm/store/**` | [confirm] | 2–10 GB | 默认不勾 | pnpm 内容寻址 store **被多个项目硬链引用**，直接删会让所有项目 `node_modules` 链接断裂；推荐走 `pnpm store prune` |
| `~/Library/Caches/pnpm/**` | [safe] | 0.5–2 GB | 直接删 | pnpm metadata 缓存 |
| `~/.bun/install/cache/**` | [safe] | 0.5–3 GB | 直接删 | Bun 安装缓存 |
| `~/.local/share/bun/install/cache/**` | [safe] | — | 直接删 | 同上（XDG 路径） |
| `<project>/node_modules/`（仓库内） | [confirm] | 项目级 100 MB–3 GB | 默认不勾 | 项目依赖，`npm i` 重建；只在用户主动选项目目录扫描时出现 |
| `~/.gradle/...`（RN 安卓侧） | — | — | 见 §2.3 | 复用 Android 规则 |
| `~/.pub-cache/hosted/**` | [confirm] | 0.5–3 GB | 默认不勾 | Flutter / Dart 全局 pub 缓存，删了 `flutter pub get` 重新下；但同一机器多项目共享 |
| `~/.pub-cache/git/**` | [confirm] | 0.3–2 GB | 默认不勾 | git 依赖缓存 |
| `~/.pub-cache/bin/**` | [forbid] | — | 引擎拦截 | 全局 dart 工具二进制（`dart pub global activate` 装的），删了 PATH 工具失效 |
| `<flutter_sdk>/.pub-cache/**` | [confirm] | 0.3–1 GB | 默认不勾 | Flutter SDK 内置 pub cache |
| `<flutter_sdk>/bin/cache/artifacts/**` | [safe] | 1–4 GB | 直接删（等价 `flutter clean` 全局） | Flutter engine 二进制缓存，`flutter precache` 重建 |
| `<flutter_sdk>/bin/cache/dart-sdk/**` | [forbid] | — | 引擎拦截 | Flutter 内嵌 dart-sdk |
| `<project>/build/`（Flutter 项目） | [confirm] | 0.5–3 GB | 默认不勾 | 项目级，等价 `flutter clean` |
| `<project>/.dart_tool/` | [confirm] | 100–500 MB | 默认不勾 | 项目级元数据 |
| `~/Library/Caches/com.facebook.metro-bundler/**` | [safe] | 100 MB–1 GB | 直接删 | Metro bundler haste-map 缓存 |
| `~/Library/Caches/Watchman/**` | [safe] | 100 MB–500 MB | 直接删（先 `watchman shutdown-server`） | Watchman watch 数据 |
| `~/.expo/**` | [confirm] | 100 MB–1 GB | 默认不勾 | Expo CLI 状态 + 登录 token |
| `~/.eas/**` | [confirm] | 50–500 MB | 默认不勾 | EAS 构建凭证缓存 |

### 2.6 其它后端 / 通用工具链

| 路径 | verdict | 典型量 | 推荐姿势 | reason |
|---|---|---|---|---|
| `~/.cargo/registry/cache/**` | [safe] | 1–4 GB | 直接删 | Rust crate 下载包缓存 |
| `~/.cargo/registry/src/**` | [safe] | 1–5 GB | 直接删 | 解压后的 crate 源码 |
| `~/.cargo/git/db/**` | [safe] | 0.5–2 GB | 直接删 | git 依赖 bare 仓库 |
| `~/.cargo/bin/**` | [forbid] | — | 引擎拦截 | `cargo install` 装的二进制 |
| `~/.cargo/config.toml` | [forbid] | — | 引擎拦截 | 用户级 cargo 配置（registry / token） |
| `~/.rustup/toolchains/<OLD>/**` | [confirm] | 1–2 GB / 工具链 | 默认不勾 | 旧 Rust 工具链；推荐保留 stable + 当前项目 rust-toolchain 指定版本 |
| `~/.rustup/downloads/**` | [safe] | 0.5–2 GB | 直接删 | 工具链下载临时文件 |
| `~/Library/Caches/pip/**` | [safe] | 0.5–3 GB | 直接删（等价 `pip cache purge`） | pip wheel / http 缓存 |
| `~/Library/Caches/pypoetry/**` | [safe] | 0.5–2 GB | 直接删 | Poetry 缓存 |
| `~/.cache/pypoetry/**` | [safe] | — | 直接删 | 同上 XDG 路径 |
| `~/.pyenv/versions/<OLD>/**` | [confirm] | 100–500 MB / 版本 | 默认不勾 | 旧 Python 版本，可能被某些 venv 引用 |
| `~/Library/Caches/Homebrew/**` | [safe] | 1–4 GB | 直接删（等价 `brew cleanup -s`） | bottle 下载缓存。Homebrew 自 4.x 开始默认每 30 天 autoremove |
| `~/Library/Logs/Homebrew/**` | [safe] | 50–500 MB | 直接删 | brew 安装日志 |
| `<HOMEBREW_PREFIX>/Cellar/<formula>/<OLD_VERSION>` | [confirm] | 0.1–1 GB / 版本 | 默认不勾 | 旧版本 formula；推荐走 `brew cleanup` 而不是手 `rm`，避免 keg-only link 残留 |
| `~/go/pkg/mod/cache/download/**` | [safe] | 1–5 GB | 直接删（等价 `go clean -modcache`） | Go module 下载缓存 |
| `~/go/pkg/mod/<host>/<owner>/<repo>@<ver>/**` | [confirm] | 累计 2–8 GB | 默认不勾 | 解压后的 go module 源码，**只读权限**，rm 需 chmod；推荐 `go clean -modcache` |
| `~/Library/Caches/go-build/**` | [safe] | 1–4 GB | 直接删（等价 `go clean -cache`） | Go build cache |
| `~/.gem/**` | [confirm] | 0.3–2 GB | 默认不勾 | RubyGems 用户级 gem 安装目录 |
| `~/.bundle/cache/**` | [safe] | 100 MB–500 MB | 直接删 | Bundler HTTP 缓存 |
| `~/.rbenv/versions/<OLD>/**` | [confirm] | 100–300 MB / 版本 | 默认不勾 | 旧 Ruby 版本 |
| `~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw` | [confirm] | 单文件 5–80 GB | **走 `docker system prune -a --volumes` 或 Docker Desktop → Troubleshoot → Clean / Purge data** | Docker Desktop 虚拟磁盘镜像，直接删等同于全清；vendor 元数据已在 [vendors.yaml L81-L83](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml#L81-L83) |
| `~/Library/Group Containers/group.com.docker/**` | [forbid] | — | 引擎拦截 | Docker 凭证 / Kube 配置 |
| `~/.colima/_lima/**` | [confirm] | 5–30 GB | **走 `colima delete <profile>`** | Colima 虚拟机磁盘，直接 rm 会让 limactl 状态错乱 |
| `~/.kube/cache/**` | [safe] | 50–500 MB | 直接删 | kubectl discovery 缓存 |
| `~/.kube/config` | [forbid] | — | 引擎拦截 | 集群凭证 |
| `~/.minikube/cache/**` | [safe] | 1–5 GB | 直接删 | minikube ISO / images 缓存 |
| `~/.vagrant.d/boxes/<OLD>/**` | [confirm] | 1–3 GB / box | 默认不勾 | 旧 Vagrant box |

### 2.7 黄金禁区（绝不能动，引擎硬拒）

下列路径**任何 verdict 都不允许 `safe`**，与 [SafetyEngine.hardForbidPrefixes](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L35-L45) / [userRootForbidden](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L48-L62) 联防：

- 任何 `Documents/` / `Desktop/` / `Downloads/` 下的源码目录
- `~/.ssh/**`、`~/.gnupg/**`、`~/.aws/**`、`~/.config/gh/**`、`~/.netrc`、`~/.npmrc`、`~/.yarnrc`、`~/.pypirc`、`~/.gitconfig`、`~/.git-credentials`
- `~/Library/Keychains/**`、`~/Library/Application Support/com.apple.TCC/**`
- `*/.git/**`（任何路径下的 .git 目录，[hardForbidPrefixes L43](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L43-L43)）
- `~/.android/debug.keystore`、`~/.android/adbkey*`、`*.jks`、`*.p12`、`*.mobileprovision`
- `~/Library/MobileDevice/Provisioning Profiles/**`
- `~/.cargo/config*`、`~/.gradle/init.d/**`、`~/.gradle/gradle.properties`、`~/.m2/settings*.xml`
- 任何 `<project>/src/`、`<project>/lib/`、`<project>/app/`（即使 git 之外，也通过 [bundleHasGitMarker](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) 探测降级到 forbid）

---

## 3. 重点子主题（需要二次 probe 的"高价值低风险"清理）

### 3.1 iOS 模拟器 unavailable 设备（接续上轮讨论）

**思路**：扫到 `~/Library/Developer/CoreSimulator/Devices/<UDID>/` 时，读 [device.plist](file:///Users/guoshuyu/Library/Developer/CoreSimulator/Devices) 拿 `runtime` + `state`：

- 若 runtime 不在 `xcrun simctl list runtimes` 返回的可用集合（"unavailable"），且 `state == "Shutdown"` → UI 标"[推荐清理]"（仍归 confirm，但默认勾选 + 醒目说明）。
- 若 `state == "Booted"` → UI 灰掉，禁止删除（运行中）。
- 删除一律走 `xcrun simctl delete <UDID>`，不直接 rm。

竞品对照：[CleanMyMac.md L39](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/competitors/CleanMyMac.md#L39-L39) 只按 Runtime 整体勾，[Pearcleaner.md L39-L48](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/competitors/Pearcleaner.md#L39-L48) 按设备列但不区分 unavailable——unavailable 维度是我们的差异化。

### 3.2 Gradle 旧 wrapper 发行版

`~/.gradle/wrapper/dists/gradle-<version>-bin/<hash>/gradle-<version>/` 下每个目录就是一个 Gradle 发行版（130–285 MB）。

- probe：列出所有版本，按 SemVer 降序保留最新 N 个（默认 N=2），其余推荐勾选。
- 风险点：用户可能在某个老项目 [gradle-wrapper.properties](file:///) 钉了具体版本，删了首次 build 会重新下载（不致命）。

### 3.3 NDK 多版本

`<sdk>/ndk/` 下子目录是版本号。

- probe（可选）：扫描 `~` 下常见 Android 项目目录（Documents、Workspace、Code、AndroidStudioProjects），grep `ndkVersion =`，求并集得到"在用版本集合"，差集中的版本推荐勾选。
- 没法 probe 时退化为：保留最新两个版本。

### 3.4 JetBrains 旧版本目录

JetBrains 的 [Toolbox 文档](https://www.jetbrains.com/help/idea/migrating-from-windows-installer.html) 推荐用户保留两个版本即可。

- probe：列举 `~/Library/Caches/JetBrains/` 子目录，按 `<product><year>.<minor>` 命名解析，保留每个 product 最新 1 个版本，老版本归到"推荐勾选"。
- 旧 `~/Library/Application Support/JetBrains/<product><OLD>/` 仍保持 confirm（含 IDE 配置可被新版本导入，谨慎）。

### 3.5 Docker.raw 巨型文件

- 不能动，一动就是 50 GB 数据丢失风险。
- 正确姿势：UI 上发现该文件 ≥10 GB 时，弹一个**"打开 Docker Desktop → Troubleshoot → Clean / Purge data"**的引导卡片，对应 reason="Docker 镜像 / 卷虚拟磁盘，安全清理需通过 Docker Desktop 自身完成"。

---

## 4. 落地路线图（与现有代码的最小改动）

### Phase 1：纯数据驱动（仅改 yaml + 文案）

成本最低，一周内可上：

1. 在 [vendors.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml) 增加以下 vendor block（按现有 schema）：
    - `com.apple.CoreSimulator`（覆盖 §2.1 全部 Devices / Caches / DocumentationCache）
    - `com.jetbrains.toolbox.shared`（覆盖 §2.2 全部 JetBrains 共享路径）
    - `com.google.android.studio.shared`（覆盖 §2.3 Gradle / .android / AS）
    - `org.cocoapods.shared`、`com.facebook.metro-bundler`、`io.dart.flutter.shared`（§2.5）
    - `org.rust-lang.cargo`、`org.golang.shared`、`org.python.shared`、`com.docker.shared`（§2.6）
2. 把 §2 全部 `safe` 行同步加到 [safe_paths.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/safe_paths.yaml) 和 [SafetyEngine.safeCachePrefixes](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L66-L81) 硬编码白名单。
3. 把 §2.7 黄金禁区里**新增**的项加到 [SafetyEngine.hardForbidPrefixes](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L35-L45)（如 `~/.gradle/init.d`、`~/.cargo/config`、Flutter dart-sdk）。
4. 在 [SafetyKitTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Tests/SafetyKitTests/SafetyKitTests.swift) 新增一个 `testDeveloperArtifactRules()`，对每条规则断言 verdict，作为契约测试。

### Phase 2：增加"开发者清理"专区（推荐档）

中等成本，2–3 周：

5. 在 [ScanCategories](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCategory.swift#L79-L117) 新增 `dev.artifacts` 类目，rootPath 为 `~`，但 ScanWorker 内部按本表的路径白名单优先扫描，避免全盘 walk。
6. 在 [DevToolsView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/Views) 之类专门视图按 §2.1 / §2.2 / ... 分组展示，每组带 reason 副标题。
7. 接入 §3 的几个 probe（device.plist 解析、wrapper 版本排序、NDK 项目扫描）作为 `ScanItemEnricher`。

### Phase 3：进程协同（理想档，需评估）

高成本：

8. 引入"操作处方"概念：UI 不直接删，而是给出"一键执行 `xcrun simctl delete`/`brew cleanup`/`docker system prune`"的卡片，沿用现有 [TrashPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift) 之外的 `RecipePipeline`。
9. 评估是否突破 [PITFALLS §0](file:///Users/guoshuyu/workspace/GSYCleanMac/PITFALLS.md) "不调外部进程做删除"的红线——倾向于：CLI 仅作为**用户主动确认后**的辅助命令，引擎本身仍只负责 `recycle`。

---

## 5. 参考资料

社区共识 / 官方文档（路径与策略均交叉验证过 2 处以上）：

1. JetBrains 官方：[Directories used by the IDE](https://www.jetbrains.com/help/idea/directories-used-by-the-ide-to-store-settings-caches-plugins-and-logs.html)（Cache / Logs / Config / Plugins 四档定义）
2. Apple 官方：`xcrun simctl --help`、[CoreSimulator framework headers](https://developer.apple.com/documentation/xcode)（`device_set.plist` 一致性约束）
3. Gradle 官方：[Gradle User Manual - Caches](https://docs.gradle.org/current/userguide/dependency_resolution.html#sub:cache_cleanup)（自动 GC、wrapper dists 安全性）
4. Android 官方：[Android Studio - Working with AVDs](https://developer.android.com/studio/run/managing-avds)（`avdmanager delete` 推荐姿势）
5. CocoaPods：`pod cache clean --all` 文档；[CocoaPods Trunk repo](https://github.com/CocoaPods/Specs)
6. Flutter：[Flutter command - flutter clean / precache](https://docs.flutter.dev/reference/flutter-cli)
7. npm / pnpm / yarn：[npm cache](https://docs.npmjs.com/cli/v10/commands/npm-cache)、[pnpm store](https://pnpm.io/cli/store)、[yarn cache](https://classic.yarnpkg.com/lang/en/docs/cli/cache/)
8. Docker：[Docker Desktop - Reduce disk usage](https://docs.docker.com/desktop/troubleshoot/topics/#reduce-disk-usage-on-mac)
9. Homebrew：[`brew cleanup` man page](https://docs.brew.sh/Manpage#cleanup-options-formularcask-)（4.x 自动化策略）
10. Rust：[Cargo Book - Cache](https://doc.rust-lang.org/cargo/guide/cargo-home.html#caching-the-cargo-home-in-ci)
11. Go：[Go Modules Reference - mod cache](https://go.dev/ref/mod#module-cache)（解释为什么 mod cache 是只读）
12. 项目内既有材料：[FEATURE_GAP.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/FEATURE_GAP.md)、[PITFALLS.md](file:///Users/guoshuyu/workspace/GSYCleanMac/PITFALLS.md)、[CleanMyMac.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/competitors/CleanMyMac.md)、[Pearcleaner.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/competitors/Pearcleaner.md)

---

> **维护约定**：本文档与 [vendors.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml) / [safe_paths.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/safe_paths.yaml) **双向同步**——任何规则改动必须同时更新 yaml 与本表，并在 [SafetyKitTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Tests/SafetyKitTests/SafetyKitTests.swift) 增补对应断言。





