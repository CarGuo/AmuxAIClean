# AmuxAIClean v1.0 ROADMAP（功能对齐 plan）

> 本文件是 v1.0 范围的**最终结论**，由用户在 R-5 决策点上拍板。
> 上游依据：[docs/FEATURE_GAP.md](./FEATURE_GAP.md)（8 维度 × 11 家竞品矩阵）。
> 下游产物：每一项都标注「改动文件 / 验收脚本」，落地后逐项打勾。

---

## 0. v1.0 范围（用户已拍板）

| 决策点 | 用户选择 |
|---|---|
| P0 | **5 项全收**（任意目录扫描入口 / 隐藏文件 toggle / 多层下钻 / 大文件模块 / 拖文件夹） |
| P1 提前到 v1.0 | **3 项**：按列排序 + size 阈值过滤、整盘扫描入口、键盘导航 j/k/Enter/Delete |
| P2 可视化 | **v1.0 不做**，留 v1.1+ |
| 隐藏文件默认值 | **OFF + 显式开关** |
| 额外 | 用 `/Users/amuxuser/Desktop/mac-logo.png` 替换 AppIcon |

不做（明确划走）：
- treemap / sunburst 可视化（v1.1+）
- 多语言（v1.1+）
- 孤儿文件、Smart Care、性能监控、Automation 9 项（v1.2+）

---

## 1. 任务分解（按依赖顺序）

### T0 - LOGO 替换（前置，1 小时）

**改动文件**：
- 新建 `Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
- 新建 `Resources/Assets.xcassets/AppIcon.appiconset/icon_{16,32,64,128,256,512,1024}{,@2x}.png`（10 张）
- 在原生 [AmuxAIClean.xcodeproj](../AmuxAIClean.xcodeproj) 接入 `Assets.xcassets` 资源 + `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`

**验收**：
1. [AmuxAIClean.xcodeproj](../AmuxAIClean.xcodeproj) 可直接打开
2. `xcodebuild` 成功
3. `open build/.../AmuxAIClean.app` 后 Dock 图标 = 垃圾桶+扫帚
4. Finder 看 .app 包预览图也是新 logo

---

### T1 - 数据层（P0-1 / P0-2 / P1 size+排序，2 小时）

**改动文件**：
- 新建 [Packages/AppUI/Sources/AppUI/UserPathStore.swift](../Packages/AppUI/Sources/AppUI/UserPathStore.swift)
 - `actor UserPathStore`，`@AppStorage("user_paths")` JSON 数组持久化
 - API：`add(URL)` / `remove(URL)` / `list() -> [URL]`
- 新建 [Packages/AppUI/Sources/AppUI/AppSettings.swift](../Packages/AppUI/Sources/AppUI/AppSettings.swift)
 - `@AppStorage("show_hidden") includeHidden: Bool = false`
 - `@AppStorage("min_file_size_mb") minFileSizeMB: Int = 100`（大文件阈值）
 - `@AppStorage("sort_key") sortKey: SortKey = .sizeDesc`
- 改 [Packages/ScanKit/Sources/ScanKit/BulkScanner.swift](../Packages/ScanKit/Sources/ScanKit/BulkScanner.swift)
 - 已有 `ScanOptions.includeHidden` 透传到 `getattrlistbulk` mask，**不需改逻辑**，只确认开关链路
- 单测：`UserPathStoreTests`（add/remove/list/dedup） + `AppSettingsTests`（默认值/读写）

**验收**：
1. `swift test` 6 包全过（含 2 个新测试）
2. 删 UserDefaults plist 后启动，`includeHidden` 默认 false、`minFileSizeMB` 默认 100

---

### T2 - UI 入口（P0-1 任意目录 + P0-5 拖文件夹，3 小时）

**改动文件**：
- 改 [Packages/AppUI/Sources/AppUI/MainView.swift](../Packages/AppUI/Sources/AppUI/MainView.swift)
 - 顶部加 `+ 添加路径` 按钮 -> `NSOpenPanel.canChooseDirectories=true`
 - 整个窗口加 `.onDrop(of: [.fileURL])` 接收拖入文件夹
 - 自定义路径列表显示在硬编码 5 项下方，每项右键删除
- 改 [Packages/AppUI/Sources/AppUI/ScanCoordinator.swift](../Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
 - `scan(category:)` 增加 `scan(customURL:)` 重载
 - 复用 BulkScanner，权限被拒走 PermissionDeniedBanner
- 新建 [Packages/AppUI/Sources/AppUI/SettingsScene.swift](../Packages/AppUI/Sources/AppUI/SettingsScene.swift)
 - `Settings { Form { Toggle("显示隐藏文件"), Stepper("大文件阈值 MB"), List(自定义路径) } }`
 - 在 [App/AmuxAICleanApp.swift](../App/AmuxAICleanApp.swift) 接 `Settings { SettingsScene() }`（Cmd, 自动可用）

**验收**：
1. 启动 app -> 菜单 AmuxAIClean -> 设置（Cmd,）能打开
2. 点 + 添加路径 -> 选 ~/.cursor -> 列表出现
3. 拖 ~/Documents/某 100G 文件夹 进窗口 -> 自动开扫
4. 设置开 "显示隐藏文件" -> 重扫 ~/ -> 出现 .cursor/.npm/.cache 等

---

### T3 - 多层下钻 Tree 视图（P0-3，3 小时）

**改动文件**：
- 新建 [Packages/AppUI/Sources/AppUI/TreeBrowserView.swift](../Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
 - `OutlineGroup(fsNode, children: \.children)` + size 横条
 - 双击 / Enter 展开；Backspace 返回上级
 - 行内 contextMenu：移到废纸篓 / 在 Finder 中显示 / 复制路径
- 改 [Packages/AppUI/Sources/AppUI/MainView.swift](../Packages/AppUI/Sources/AppUI/MainView.swift)
 - 扫描结果切到 TreeBrowserView 显示（保留旧 ListView 作降级）
- 改 [Packages/ScanKit/Sources/ScanKit/FSNode.swift](../Packages/ScanKit/Sources/ScanKit/FSNode.swift)
 - 确认 children 已存（应该有，BulkScanner 已建树）

**验收**：
1. 扫 ~/Library 后能逐层进 Caches -> com.apple.xxx -> bundles
2. 每行右侧显示 `12.3 GB` + 横条比例
3. 键盘 j/k 上下移动，Enter 展开，Delete 进废纸篓

---

### T4 - 大文件模块（P0-4，2 小时）

**改动文件**：
- 新建 [Packages/AppUI/Sources/AppUI/LargeFilesView.swift](../Packages/AppUI/Sources/AppUI/LargeFilesView.swift)
 - 主侧栏加新分类 " 大文件"
 - 走整盘 BulkScanner，过滤 `size >= AppSettings.minFileSizeMB * 1024 * 1024`
 - 扁平 Top N 列表（N=200），列：路径 / 大小 / 修改日期 / 类型图标
 - Header 点击列名切排序（size↓ / size↑ / mtime↓ / mtime↑）
- 改 [Packages/AppUI/Sources/AppUI/ScanCategory.swift](../Packages/AppUI/Sources/AppUI/ScanCategory.swift)
 - 加 `case largeFiles`

**验收**：
1. 点"大文件" -> 显示 ≥100MB 的 Top 200
2. 点 size 列头 -> 升降序切换
3. 改设置阈值到 500 -> 重扫 -> 列表变短

---

### T5 - 整盘扫描 + 键盘导航完善（P1，1.5 小时）

**改动文件**：
- 改 [Packages/AppUI/Sources/AppUI/MainView.swift](../Packages/AppUI/Sources/AppUI/MainView.swift)
 - 路径栏加 `/` 快捷输入框，输 `/` 回车 = 扫整个根目录（提示 TCC 全盘权限）
- 改 [Packages/AppUI/Sources/AppUI/TreeBrowserView.swift](../Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
 - `.onKeyPress` 处理：j/k（上下）、h/l（折叠/展开）、Enter（进入）、Delete（移废纸篓）、Cmd+R（在 Finder 中显示）
 - Focus 管理：扫描完后自动聚焦第一行

**验收**：
1. 路径栏输 `/` 回车 -> 扫描整个 / 根（无 TCC 时显示 Banner 引导）
2. 焦点在 Tree 时按 j -> 高亮下移；按 Delete -> 弹确认 -> 移废纸篓
3. h 折叠当前节点，l 展开

---

### T6 - v1.0 总验收

**步骤**：
1. `swift test` × 6 包全过（≥113 + 新增测试）
2. `xcodebuild -project AmuxAIClean.xcodeproj -scheme AmuxAIClean` BUILD SUCCEEDED
3. `open build/.../AmuxAIClean.app` 启动
4. 手工跑 [docs/V1_SMOKE.md](./V1_SMOKE.md)（T6 时同步建）冒烟脚本：
 - [Y] Dock 图标是新 logo
 - [Y] Cmd, 打开设置
 - [Y] 添加 ~/.cursor 能扫
 - [Y] 拖文件夹能扫
 - [Y] 隐藏文件 toggle 默认 OFF，开后能看 .xxx
 - [Y] Tree 能下钻
 - [Y] 大文件模块能用
 - [Y] 整盘 / 入口能扫
 - [Y] 键盘 j/k/Enter/Delete 能用
5. `bash scripts/make_dmg.sh 1.1.0` -> 产 DMG

---

## 2. 每一项与 FEATURE_GAP.md 的对应关系

| 本 plan 任务 | FEATURE_GAP.md 编号 | 对齐的竞品 |
|---|---|---|
| T1+T2 P0-1 | P0-1 任意目录扫描 | DaisyDisk / OmniDS / GP / ncdu / Pearcleaner v5 |
| T1+T2 P0-2 | P0-2 隐藏文件 toggle | OnyX / Pearcleaner / GP |
| T2 P0-5 | P0-5 拖文件夹 | DaisyDisk / GP / OmniDS |
| T3 | P0-3 多层下钻 | DaisyDisk / OmniDS / GP / Pearcleaner |
| T4 | P0-4 大文件模块 | CleanMyMac / Sensei / MacFly / Pearcleaner |
| T5 | P1-3/4/5 整盘+排序+键盘 | OmniDS / Pearcleaner |

---

## 3. 不在 v1.0 范围（明确）

- treemap / sunburst -> v1.1
- 多语言 -> v1.1
- 修改日期范围过滤、孤儿文件 -> v1.1
- Smart Care、Automation 9 项、性能监控 -> v1.2+

---

## 4. 工程约束（继承 v0.9）

- [Y] Free Apple ID / `CODE_SIGNING_REQUIRED=NO` 走通
- [Y] NSWorkspace.recycle 主链路不动
- [Y] SafetyEngine 三道闸门 + VendorTrie 不动
- [Y] Helper XPC 不动
- [Y] 测试金字塔：每个新文件配单测，HL 启发式不动
- [Y] 一切新代码必须过 `OTHER_SWIFT_FLAGS: -warnings-as-errors` 严格并发

---

## 5. v1.4 已发布：开发者构建产物扫描（DevArtifacts）

发布日期：随 v1.1.0 上线（项目当前版本 1.1.0，已合入 main）。

### 5.1 范围与产物

- **30 条规则**：覆盖前端、Native、JVM、移动、Python、Swift/Xcode、Rust、Go、Docker/容器、IDE 缓存等开发者机器上常见的"反复升级、版本切换沉淀下来"的冗余产物。
- **8 个生态分组**：Node / iOS-Xcode / Android-Gradle / JVM-Maven / Python / Rust-Cargo / Go-Modules / IDE-Caches，UI 侧按生态分组渲染，便于开发者按手感选择。
- 规则定义沉淀在 [Resources/Rules/dev_artifacts.yaml](../Resources/Rules/dev_artifacts.yaml) 与 [docs/DEV_ARTIFACTS_RULES.md](DEV_ARTIFACTS_RULES.md)（手册），与 [SafetyEngine](../Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) 三色判定一致。

### 5.2 扫描策略：命中 + 兄弟脚手架兜底 + 整棵剪枝

为了贴合"开发者真实意图"——**只删冗余产物，不删源码与 lockfile**——v1.4 采用三步法：

1. **命中（hit）**：按 30 条规则的目录名 / glob / 文件 marker 命中候选产物路径（例如 `node_modules`、`DerivedData`、`.gradle`、`build/`、`target/`、`__pycache__`、`.next`、`Pods/`）。
2. **兄弟脚手架兜底（sibling-scaffold fallback）**：命中后向上看父目录是否存在该生态的"脚手架文件"（如 `package.json` / `Package.swift` / `Cargo.toml` / `pom.xml` / `build.gradle(.kts)` / `pyproject.toml` / `Podfile` / `go.mod`）。只有在脚手架兄弟存在时才确认归属，避免误删跟生态不相干的同名目录。
3. **整棵剪枝（subtree pruning）**：候选确认后，在结果树里把该目录连同子树一次性剪掉，不再向下递归扫描——这既消除了"`node_modules` 内部嵌套 `node_modules` 又被重复算大小"的双计，也大幅缩短大型 monorepo 的扫描时长。

三步法都跑在 `ScanKit` 上，保留 inode 去重 / firmlink 镜像识别 / APFS clone 修正等既有正确性保障；UI 侧由 [AppUI](../Packages/AppUI) 的 DevArtifacts 屏渲染分组结果，可一键移废纸篓（仍走 NSWorkspace.recycle，永不 unlink）。

### 5.3 测试与验证

- 30 条规则在 ScanKit / AppUI 双层有覆盖：ScanKit 117 条单测涵盖规则匹配、兄弟脚手架命中、整棵剪枝行为；AppUI 252 条单测涵盖 DevArtifacts 屏的分组渲染与批量勾选。
- 总测试 **370+ 全绿**，xcodebuild Release **BUILD SUCCEEDED**。
