# AGENTS.md — GSYCleanMac

> 面向 AI coding agent 的操作手册。用户向说明请看 [README.md](file:///Users/guoshuyu/workspace/GSYCleanMac/README.md)；开发环境细节看 [docs/DEVELOPMENT.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/DEVELOPMENT.md)；贡献规范看 [CONTRIBUTING.md](file:///Users/guoshuyu/workspace/GSYCleanMac/CONTRIBUTING.md)；红线全景看 [SECURITY.md](file:///Users/guoshuyu/workspace/GSYCleanMac/SECURITY.md) 与 [PITFALLS.md](file:///Users/guoshuyu/workspace/GSYCleanMac/PITFALLS.md)。
>
> 本文件只写「agent 干活时必须遵守什么」。任何与本项目关系不密切的通用建议不写。
>
> 更新原则：**规则随 agent 犯错逐条补齐**，而不是一次性写全。凡新增/修改规则，必须能对应到一条命令、一个测试或一个具体文件位置。

---

## 1. 项目一句话画像

- **形态**：macOS 15+ 原生 SwiftUI 桌面应用（本地扫描 / 清理 / 卸载残留 / 大文件 / 开发者构建产物）。
- **Stack**：Swift 6.0（strict concurrency + warnings-as-errors）· SwiftUI · AppKit 插桩 · 原生 [GSYCleanMac.xcodeproj](file:///Users/guoshuyu/workspace/GSYCleanMac/GSYCleanMac.xcodeproj)（**不再使用 xcodegen**）· 9 个 Local SwiftPM 包（AIKit / AppUI / BrewKit / FileSearchKit / HeuristicKit / LogKit / SafetyKit / ScanKit / TestHarness）。
- **分发**：Developer ID / 企业分发，非 MAS；ad-hoc + SHA256 校验路径见 [docs/RELEASE.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/RELEASE.md)。
- **数据边界**：只删 `$HOME` 下用户态文件，走 `NSWorkspace.recycle` 移废纸篓，**永不 `unlink(2)`**，**零网络**。
- **多语言**：`zh-Hans` + `en`，统一入口 [Localizable.xcstrings](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/Resources/Localizable.xcstrings)。任何新 UI 文案**从写下第一个字符开始就必须走 xcstrings**，禁止字面量硬编码中文/英文。

---

## 2. 项目结构（agent 必须先认识的目录）

```
GSYCleanMac/
├─ App/                                # SwiftUI @main 入口 + 回归 runner
│  └─ GSYCleanMacApp.swift             # 加载 vendors.yaml、注入 MainView
├─ GSYCleanMac.xcodeproj/              # 原生 Xcode 工程（入仓，禁止 xcodegen 重建）
├─ Packages/
│  ├─ AppUI/          Sources/AppUI/   # SwiftUI 视图层 + 业务 actor（最大包，252 测试）
│  ├─ ScanKit/        Sources/ScanKit/ # 扫描引擎（getattrlistbulk / FileManager 双路，117 测试）
│  ├─ SafetyKit/      Sources/SafetyKit/ # 三色安全判定 + hardForbid + vendor（30 测试）
│  ├─ HeuristicKit/   Sources/HeuristicKit/ # 用户删除行为启发式
│  ├─ FileSearchKit/  Sources/FileSearchKit/ # 通用文件搜索
│  ├─ BrewKit/        Sources/BrewKit/ # Homebrew 集成
│  ├─ AIKit/          Sources/AIKit/   # 可选 AI 建议（零网络硬约束由 UI 层守）
│  ├─ LogKit/         Sources/LogKit/  # 结构化日志
│  └─ TestHarness/    Sources/TestHarness/ # 测试基础设施（FixtureFS / GoldenSnapshot）
├─ Resources/
│  └─ Rules/
│     ├─ vendors.yaml         # 自动生成 + 手工兜底的厂商目录规则
│     ├─ vendor_shared.yaml   # 共享厂商目录白名单（Adobe/Microsoft/JetBrains…）
│     └─ safe_paths.yaml      # 已知安全前缀
├─ Scripts/
│  ├─ setup_dev.sh            # 新机器初始化（macOS/Xcode 版本检查）
│  ├─ run_debug.sh            # 命令行 ⌘R
│  ├─ build_release.sh        # Release 打包（签名走 project.pbxproj）
│  ├─ regression.sh           # 22 case 真机回归（跑真实 .app 进程）
│  ├─ e2e-smoke.sh            # Release .app 冒烟（AX 探针 + graceful quit）
│  └─ bench.sh                # ScanKit vs du 对比
├─ Tools/
│  ├─ PerfBench/              # 性能基准 CLI
│  ├─ CoordinatorBench/       # ScanCoordinator 基准
│  └─ SeedingTool/            # vendors.yaml 一次性生成器
├─ Tests/Regression/          # 回归 log + last-run.json
├─ docs/                      # 面向人的文档；agent 只在有明确指示时才修改
├─ AGENTS.md                  # ← 你在这里
├─ PITFALLS.md                # 前人踩过的坑（下钻前必读）
├─ SECURITY.md                # 威胁模型与红线
└─ CONTRIBUTING.md            # PR 规范
```

**关键单文件**：

- 删除链路唯一入口：[TrashPipeline.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift)
- 三色安全判定：[SafetyEngine.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift)
- 硬黑名单：[BundleProtection.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/BundleProtection.swift) + [protected_bundles.json](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/Resources/protected_bundles.json)
- 扫描协调：[ScanCoordinator.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
- 集成契约测试：[V12SafetyIntegrationTests.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/V12SafetyIntegrationTests.swift)

---

## 3. 命令手册（agent 优先复用，禁止自造）

### 构建

```bash
# Debug（本地首选）
./Scripts/run_debug.sh                              # kill 残留 → xcodebuild Debug → open .app
./Scripts/run_debug.sh --clean                      # 先 clean
./Scripts/run_debug.sh --no-build                   # 仅启动最近产物

# 纯 xcodebuild（fork 用户改完 Team 后）
xcodebuild -project GSYCleanMac.xcodeproj -scheme GSYCleanMac -configuration Debug build

# Release（默认 Developer ID 签名 + DMG，不公证）
VERSION=1.5.6 ./Scripts/build_release.sh --no-notarize

# 公证发布（Developer ID 签名 + App/DMG Notary + staple + Gatekeeper 校验）
VERSION=1.5.6 AMUX_CLEAN_NOTARY_KEYCHAIN_PROFILE=amux-notary ./Scripts/build_release.sh --notarize
```

### 测试（`swift test` 是**唯一**入口，不允许 agent 直接 `xcodebuild test`）

```bash
# 单包（改哪个包跑哪个包）
cd Packages/ScanKit && swift test
cd Packages/SafetyKit && swift test
cd Packages/AppUI && swift test

# 全部包（提交前必跑）
for pkg in ScanKit SafetyKit AppUI HeuristicKit LogKit BrewKit FileSearchKit AIKit TestHarness; do
  (cd "Packages/$pkg" && swift test --parallel) || exit 1
done
```

### 真机回归（改动扫描 / 删除 / UI 链路后**必跑**）

```bash
./Scripts/regression.sh                                    # 全部 22 case（见 Scripts/regression.sh 里 ALL_CASES 数组）
./Scripts/regression.sh --only scan-recommended,hud-toggle # 指定 case
./Scripts/regression.sh --no-build                         # 复用上次产物
./Scripts/e2e-smoke.sh <app-path> <log-dir>                # Release 冒烟
```

单 case 日志：`Tests/Regression/logs/<case>.log`；结果汇总：[Tests/Regression/last-run.json](file:///Users/guoshuyu/workspace/GSYCleanMac/Tests/Regression/last-run.json)。

### 性能基准

```bash
./Scripts/bench.sh ~/Downloads                             # ScanKit vs du -sh
swift run -c release --package-path Tools/PerfBench PerfBench ~/Library/Caches
```

### 诊断

```bash
xcodebuild -project GSYCleanMac.xcodeproj -scheme GSYCleanMac -configuration Debug -showBuildSettings
codesign -dv --verbose=2 dist/AmuxAIClean.app
pkill -9 -f "AmuxAIClean.app/Contents/MacOS/AmuxAIClean"    # 强制杀所有残留
```

---

## 4. 编码约定

### 4.1 Swift 6 严格并发

- **零警告**：`SWIFT_STRICT_CONCURRENCY=complete` + `-warnings-as-errors` 已启，禁止用 `@unchecked Sendable` 兜底问题；确要用必须加注释说明为什么这个类型永不跨 actor 共享可变状态。
- **actor 优先**：跨线程共享的可变状态一律走 `actor`；GUI 状态一律 `@MainActor`。
- **禁止 `try?` 吞异常**：错误必须 `log` 或上抛；如确要忽略，写注释说明理由（[CONTRIBUTING.md#L57](file:///Users/guoshuyu/workspace/GSYCleanMac/CONTRIBUTING.md#L57)）。
- **禁止在 Task 闭包中 unowned self 越线**：跨 actor 的 weak/strong 关系必须显式，参考 [PITFALLS.md](file:///Users/guoshuyu/workspace/GSYCleanMac/PITFALLS.md) "Strict Concurrency 实战踩坑" 段。

### 4.2 线程与主线程预算

- **UI 与 main-thread-only 业务外，能上后台的一律上后台**（`Task.detached` / `DispatchQueue.global` / `actor`）。
- **扫描期禁止**：重建大 SwiftUI/AppKit 列表、排序大集合、重算 verdict、查 store、materialize partial tree。这些是 [AGENTS 规则第 2 条](#7-核心红线) 的直接落地对象。
- **主线程只做**：状态发布、轻量 UI 更新。任何 >1ms 的计算必须挪走。

### 4.3 多语言（硬规则）

- **一切用户可见字符串走 [Localizable.xcstrings](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/Resources/Localizable.xcstrings)**，用 `String(localized: "key")` 或 SwiftUI `Text("key")`；禁止 `Text("中文")` / `Text("English")` 硬编码。
- 新增 key 必须同时补 `zh-Hans` 和 `en` 两栏，缺一由 [I18nIntegrityTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/I18nIntegrityTests.swift) 兜底红。
- log / 结构化字段等**非用户可见字符串**可留英文字面量。

### 4.4 命名

- 类型 `PascalCase`，方法/属性 `camelCase`，常量 `camelCase`（Swift 惯例，不用 `UPPER_SNAKE`）。
- 测试文件名 `<被测目标>Tests.swift`；避免 inline `mod tests`（Swift 无 Rust `mod`，写单独文件）。
- 包命名后缀 `Kit`；工具目录用 `Tools/<Bench|Tool>`。

### 4.5 依赖新增

- 新增 SwiftPM 依赖必须**先评估能否用系统 API 或已有包实现**（本项目现状是**零外部 runtime 依赖**）。
- [SafetyKit](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit) 永远**零外部依赖**（可审计前提）；`YAML` 用手写 parser [RuleLoader.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/RuleLoader.swift)。
- Package.swift 修改必须与其它测试文件的 subagent **串行**（并发改会撞车，见 PITFALLS "Subagent 并发协同"）。

---

## 5. 性能守则（本项目的 P0 规则，来自 workspace 规则）

以下 6 条是 [.trae/rules](file:///Users/guoshuyu/workspace/GSYCleanMac/AGENTS.md) 顶层规则的展开版；每一条都有对应的具体落地位置。

1. **性能是一等要求**。任何改动都要按"可能在大扫描 / 大列表 / 满盘工作流下运行"来设计。参考 baseline：[BulkScanner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift) 32.8 万文件 / 9.5s。
2. **不允许用"扫描期 UI churn"回补正确性**。扫描期禁止：重建 List、排序、重算 verdict、查 store、materialize partial tree —— 这些一律挪到 `.finished` 之后。
3. **能后台就后台**。主线程只做状态发布与轻量 UI，`throttle` 到 ≥150ms 才发一次 snapshot（见 [ScanCoordinator 文件顶部注释](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1-L20) 与 `publishSnapshot` 每帧调用 `engine.evaluate` 的说明 [#L276-L276](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L276-L276)）。
4. **区分 scan-time / final-state**。部分快照只喂进度指示；重结果视图消费 frozen / final snapshot。
5. **禁止局部硬编码打补丁**。修就修共享数据边界或渲染契约，让同类问题在其它扫描/列表面板无法复发。
6. **改动 scanning / tree-list rendering / store fallback / deletion / AI actions 前**，必须用聚焦测试或 profiling 证据验证正确性 + 性能风险。删除链路唯一入口是 [TrashPipeline.recycleInBatches](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift#L360-L360) → [recycleOnce](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift#L393-L396)，绕过即违规。

---

## 6. 测试规范

### 6.1 命令

见 [§3 命令手册](#3-命令手册agent-优先复用禁止自造)。

### 6.2 写测试的红线

- **不许为过测试改需求**。测试红了先分析代码，禁止改测试断言 / 删测试 / `XCTAssertTrue(true)` "修绿"。要改测试必须先在 PR 描述里说明该测试的判据本身有 bug（[CONTRIBUTING.md#L55](file:///Users/guoshuyu/workspace/GSYCleanMac/CONTRIBUTING.md#L55)）。
- **删除类 / 安全类改动必须先加测试再改代码**。参考 [V12SafetyIntegrationTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/V12SafetyIntegrationTests.swift) 的"不许删什么"契约风格。
- **性能测试要区分本地/CI budget**。参考 [VendorTrieTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Tests/SafetyKitTests/VendorTrieTests.swift#L147-L147) 用 `CI=true / GITHUB_ACTIONS=true` 环境变量分裂 budget（本地 100ms / CI 250ms）。
- **真删测试只能在 NSTemporaryDirectory**。任何真跑 `NSWorkspace.recycle` 的用例，工作目录必须在临时目录，禁止在 `$HOME` 下跑（会真把测试文件丢进废纸篓）。
- **APFS 块对齐容差**：物理占用断言用 `≥` 或区间，不用 `==`，否则跨硬件抖动（[HiddenFileTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Tests/ScanKitTests/HiddenFileTests.swift)）。
- **firmlink 双写**：涉及路径前缀断言，`/private/var/...` 与 `/var/...` 两份都要覆盖（[PITFALLS §2.1](file:///Users/guoshuyu/workspace/GSYCleanMac/PITFALLS.md)）。

### 6.3 交付前必过

| 场景 | 必跑 |
|---|---|
| 改动仅涉及某一个包 | 该包 `swift test` |
| 改动跨包 / 改到 SafetyKit / ScanKit / AppUI 主链路 | 全部 9 个包 `swift test` |
| 改动扫描 / 删除 / UI 主链路 | + `./Scripts/regression.sh` |
| 改动 Release 打包 / 签名 / Info.plist | + `./Scripts/build_release.sh` + `./Scripts/e2e-smoke.sh` |

---

## 7. 三层边界（Always / Ask first / Never）

### ✅ Always（必须做）

- 删除**永远**走 [TrashPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift) → `NSWorkspace.recycle`。
- 新增删除路径**默认 `dryRun=true`**，真删由 UI 显式二次确认切换。
- 新增用户可见字符串**先写 [Localizable.xcstrings](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/Resources/Localizable.xcstrings) 两栏再写代码**。
- 涉及扫描期渲染的代码，先跑 `./Scripts/regression.sh --only scan-recommended,tree-drilldown` 自证。
- 遇到问题**先查 [PITFALLS.md](file:///Users/guoshuyu/workspace/GSYCleanMac/PITFALLS.md) 相关小节**，同类坑高概率已经踩过。
- 每次工作结束**明确告知用户还差什么**（user_rules 第 5 条）。

### ⚠️ Ask first（必须先确认）

- 修改 [GSYCleanMac.xcodeproj](file:///Users/guoshuyu/workspace/GSYCleanMac/GSYCleanMac.xcodeproj)、任何 `Package.swift`、Info.plist、entitlements。
- 新增第三方 SwiftPM 依赖。
- 修改 [Resources/Rules/vendors.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml) / [vendor_shared.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendor_shared.yaml) / [safe_paths.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/safe_paths.yaml) 或往 [protected_bundles.json](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/Resources/protected_bundles.json) 新增条目。
- 修改 [SafetyEngine.hardForbid*](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L42-L164) 四组列表（Prefixes / Suffixes / PathSegments / PathContains）—— 必须附真实事故来源链接（[CONTRIBUTING.md#L60](file:///Users/guoshuyu/workspace/GSYCleanMac/CONTRIBUTING.md#L60)）。
- 修改 CI / release workflow / codesign 脚本。
- git commit / push（agent **绝不主动**执行，用户明确指示才做）。

### 🚫 Never（绝对红线）

1. **禁止新增 `unlink(2)` / `FileManager.removeItem(at:)`** 用于"删除候选" —— 一律走 recycle。
2. **禁止默认 `dryRun=false`**。
3. **禁止削弱 / 删除已有测试**（改断言、`XCTAssertTrue(true)`、注释掉、改期望值"修绿"）；测试本身有 bug 需先说明判据再改。
4. **禁止 `try?` 无声吞异常**。
5. **禁止抄竞品源码**（尤其 GPL 项目如 ncdu / Pearcleaner）；可以看思路 / commit message，不复制粘贴。
6. **禁止引入任何网络请求**（连 telemetry / crash report 也不可）。零网络是 hard rule。
7. **禁止只用 appName 前缀模糊匹配 vendor**；bundleID 严格前缀是硬要求（[AppUninstaller.matchesStrictPrefix](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppUninstaller.swift#L321-L329)，防 `com.foo` 误命中 `com.foobar`）。
8. **禁止提交 secrets、Developer ID p12、Apple ID token** 到仓库；[.gitignore](file:///Users/guoshuyu/workspace/GSYCleanMac/.gitignore) 已经守 `xcuserdata`，但 agent 要主动避免。
9. **禁止绕过 [SafetyEngine](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) 直接构造删除请求**。HeuristicKit / AIKit 的评分**永不凌驾** `.forbid`。
10. **禁止用 xcodegen / project.yml 重建 .xcodeproj**（v1.5.x 起原生工程已入仓）。
11. **禁止在扫描期主线程做重活**（详见 [§5 性能守则](#5-性能守则本项目的-p0-规则来自-workspace-规则)）。
12. **禁止 git commit / push / force-push**，除非用户明确指令。

---

## 8. 修改代码的思维方式（来自 user_rules，第一性原理）

1. **从原始需求和问题出发**，不做"看起来像"的补丁。目标模糊时停下和用户讨论，不假设用户已知全部目标。
2. **拒绝经验主义**：某种做法"以前这么用"不是理由；新场景可能已经变。参考竞品 / 开源实现，但不迷信。
3. **修问题修**其**核心**，不加兜底。同一问题反复出现 = 存在核心问题，进一步下钻而非再加一层 patch。
4. **改需求不算解决**。测试红了只能改代码（除非测试本身错），需求红了先和用户核对再动。
5. **每次工作交付时列出还差什么**（user_rules 第 5 条），例如：待补测试、未覆盖的边缘 case、性能待测的路径、跨包依赖尚未回归。

回答用户时保持两段式：
- **直接执行**：给出任务结果。
- **深度交互**：审慎挑战原始需求（是不是 XY 问题？当前路径的弊端？更优雅的替代方案？）。

---

## 9. Git 与提交

- 分支：`feat/*` / `fix/*` / `chore/*` / `docs/*` / `perf/*` / `refactor/*` / `test/*`。
- Commit 格式（[CONTRIBUTING.md#L66-L102](file:///Users/guoshuyu/workspace/GSYCleanMac/CONTRIBUTING.md#L66-L102)）：`<type>(<scope>): <subject>`，`scope` 为包名（`scankit` / `safetykit` / `appui` / `ci` / `docs` …）。
- **agent 不主动 commit**。用户明确说 "commit 一下" / "push" 才执行。
- PR 前 checklist：全部 9 包 `swift test` 绿 + 相关 `regression.sh` case 绿 + `xcodebuild Debug` 绿 + 无新的多语言遗漏。

---

## 10. Code Reference 规范（agent 输出格式）

在所有回复、注释、文档里引用文件 / 目录 / 函数，必须使用：

```
[display_name](file:///absolute/path[#L<start>-L<end>])
```

- 展示名用 basename，不要用完整路径，不要包 backtick。
- 路径必须绝对，正斜杠。
- 行号 `#L12-L15`，`L` 两侧都要写。

例：
- 引用文件：[SafetyEngine.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift)
- 引用范围：[matchesStrictPrefix](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppUninstaller.swift)
- 引用目录：[Packages/SafetyKit](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit)

---

## 11. 参考文档索引（agent 遇到问题的第一站）

| 主题 | 文档 |
|---|---|
| 前人踩坑（**修 bug 前必读**） | [PITFALLS.md](file:///Users/guoshuyu/workspace/GSYCleanMac/PITFALLS.md) |
| 威胁模型 / 红线 | [SECURITY.md](file:///Users/guoshuyu/workspace/GSYCleanMac/SECURITY.md) |
| PR 规范 / commit 规范 | [CONTRIBUTING.md](file:///Users/guoshuyu/workspace/GSYCleanMac/CONTRIBUTING.md) |
| 开发环境 / 签名 / 目录结构 | [docs/DEVELOPMENT.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/DEVELOPMENT.md) |
| 发版流程 | [docs/RELEASE.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/RELEASE.md) |
| 竞品差距分析 | [docs/FEATURE_GAP.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/FEATURE_GAP.md) |
| 路线图 | [docs/ROADMAP_V1.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/ROADMAP_V1.md) |

---

## 12. 何时更新本文件

- Agent 在某类问题上连续犯错 ≥ 2 次 → 在此新增一条规则 + 一个对应的测试或脚本兜底。
- 新增包 / 目录 / 关键脚本 → 更新 [§2 项目结构](#2-项目结构agent-必须先认识的目录) 与 [§3 命令手册](#3-命令手册agent-优先复用禁止自造)。
- 新增红线 → 更新 [§7 三层边界](#7-三层边界always--ask-first--never) 且必须能对应到 lint / 测试 / 目录约束。

**不写**：与 agent 无关的用户教程（去 README）、发版细节（去 docs/RELEASE.md）、架构讨论（去 docs/）。AGENTS.md 只保留"干活时的操作手册"。
