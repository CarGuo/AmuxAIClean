# AmuxAIClean 开发文档

面向具有源码仓库访问权限的维护者与贡献者。用户操作看 [USER_GUIDE.md](USER_GUIDE.md)，安装看 [INSTALL.md](INSTALL.md)。

---

## 工程概览

- **Swift 6.0 + SwiftUI，产品部署下限 macOS 13.5**（strict concurrency / warnings-as-errors）
  <!-- v2026.07.16：部署下限与开发机工具链解耦；本地开发仍统一使用 macOS 15+ / Xcode 16+。 -->
- 工程描述：原生 Xcode 工程 [AmuxAIClean.xcodeproj](../AmuxAIClean.xcodeproj)（直接入仓，无 xcodegen / project.yml）
- 9 个独立 SwiftPM 包（AIKit / AppUI / BrewKit / FileSearchKit / HeuristicKit / LogKit / SafetyKit / ScanKit / TestHarness）+ 主 App，作为 Local SPM 在 Xcode UI 的 Package Dependencies 区域引用
- 删除走 [TrashPipeline](../Packages/AppUI/Sources/AppUI/TrashPipeline.swift) 直接调 `NSWorkspace.recycle`，无特权进程
- 当前仓库没有 `.github` 工作流；测试、构建和公开发布按本地合同执行。

---

## 前置依赖

| 工具 | 版本 | 备注 |
|---|---|---|
| macOS | 15 Sequoia 或更高 | 开发机要求；不是产品的 macOS 13.5 部署下限 |
| Xcode | 16+ | 自带 Swift 6 toolchain |
| Apple Developer 账号 | 企业账号 / 个人账号均可 | 当前仓库 Debug 默认使用 Apple Development 自动签名；Release 默认使用 Team `W6H34N9728` + Developer ID Application 手动签名；fork 需要替换为自己的 Team / signing 配置 |
| Homebrew | optional | 仅 `xcbeautify` 装饰输出 / `create-dmg` 打 DMG 时需要 |

> 不再需要 `xcodegen` —— v1.5.x 起项目回归原生 Xcode 工程，[AmuxAIClean.xcodeproj](../AmuxAIClean.xcodeproj) 直接入仓。

---

## 一键初始化

```bash
git clone git@github.com:CarGuo/AmuxAIClean.git
cd AmuxAIClean
./Scripts/setup_dev.sh
```

[Scripts/setup_dev.sh](../Scripts/setup_dev.sh) 会：检查 macOS / Xcode / Homebrew，确认 [AmuxAIClean.xcodeproj](../AmuxAIClean.xcodeproj) 已就绪，并提示你在 Xcode 里确认 Team / signing 配置。

---

## 签名配置

> **fork 用户必读**：仓库里 [AmuxAIClean.xcodeproj/project.pbxproj](../AmuxAIClean.xcodeproj/project.pbxproj) 当前 Debug 配置为 `CODE_SIGN_STYLE = Automatic` + `CODE_SIGN_IDENTITY = Apple Development`，Release 配置为 `DEVELOPMENT_TEAM = W6H34N9728` + `CODE_SIGN_STYLE = Manual` + `CODE_SIGN_IDENTITY = Developer ID Application: SentenceEnd Inc (W6H34N9728)`。没有对应证书时，第一次跑必须改成你自己的 Team / signing 配置。

**方式 A（图形化，推荐新手）**：

1. 双击打开 [AmuxAIClean.xcodeproj](../AmuxAIClean.xcodeproj)
2. Xcode → Settings → Accounts → 用你的 Apple Developer 账号登录
3. 选中 `AmuxAIClean` target → `Signing & Capabilities`
   - 本地调试：保持 Automatically manage signing，`Team` 下拉选你自己的 Team
   - Release 分发：保持 Manual signing，选择自己的 Team / Developer ID Application 证书
   - `Bundle Identifier` 必要时改成你自己的（如 `com.<你的id>.AmuxAIClean`）
4. ⌘S 保存（会写进 [project.pbxproj](../AmuxAIClean.xcodeproj/project.pbxproj) 的 `DEVELOPMENT_TEAM` 字段）
5. 点 `Run` 跑起来

**方式 B（命令行，老司机）**：

```bash
# 在 https://developer.apple.com/account 右上角找到自己的 Team ID（10 位）
sed -i '' 's/W6H34N9728/<你的Team ID>/g' AmuxAIClean.xcodeproj/project.pbxproj
xcodebuild -project AmuxAIClean.xcodeproj -scheme AmuxAIClean -configuration Debug build
```

**为什么要稳定 Team 签名而不是 ad-hoc**：TCC（含完全磁盘访问）不是看"有没有签名"这么粗，而是用 bundle id + code requirement（签名身份 / Team / 证书链等）去匹配授权记录。Apple Development / Developer ID Application 的 designated requirement 可以跨普通 rebuild 保持同一类身份；ad-hoc (`-`) 没有稳定身份，代码变化后更容易让 TCC 记录失配。排查 Debug 反复掉授权时，用 [diagnose_debug_tcc.sh](../Scripts/diagnose_debug_tcc.sh) 对比两次 build 的 designated requirement / Authority / TCC 记录，而不是只看 cdhash。

---

## 命令行 Debug 构建

```bash
xcodebuild -project AmuxAIClean.xcodeproj -scheme AmuxAIClean -configuration Debug build
```

Debug 签名由 [AmuxAIClean.xcodeproj](../AmuxAIClean.xcodeproj) 里的 `CODE_SIGN_STYLE = Automatic` + `CODE_SIGN_IDENTITY = Apple Development` + `DEVELOPMENT_TEAM = W6H34N9728` 决定。产物路径用 `xcodebuild -showBuildSettings` 动态查（脚本已封装，见 [Scripts/run_debug.sh](../Scripts/run_debug.sh)）。

---

## Release 打包与公开发布

唯一版本化操作入口是 [RELEASE.md](RELEASE.md)：Developer ID 构建、最终 DMG 公证、签名校验、
源码 tag、公开仓库上传与匿名下载验收均按该文档执行。公开安装包位于
[CarGuo/AmuxAICleanRelease](https://github.com/CarGuo/AmuxAICleanRelease/releases)，与源码仓库分开。

---

## 跑测试

### 全部 9 个包

```bash
# ScanKit 在 Xcode 16+ 下因 TestHarness 菱形依赖需指定 --build-system native 避免链接器符号重复
for pkg in ScanKit SafetyKit AppUI HeuristicKit LogKit BrewKit FileSearchKit AIKit TestHarness; do
  if [ "$pkg" = "ScanKit" ]; then
    (cd "Packages/$pkg" && swift test --build-system native) || exit 1
  else
    (cd "Packages/$pkg" && swift test) || exit 1
  fi
done
```

### 单包测试示例

```bash
# 普通包直接运行
(cd Packages/AppUI && swift test)

# ScanKit 需附加 --build-system native
(cd Packages/ScanKit && swift test --build-system native)
```

### 当前测试矩阵

| 包 | 关键覆盖 |
|---|---|
| AppUI | 普通工作台 / Tree 与大文件投影 / 扫描终态 / 统一确认与回执 / SQLite 历史与迁移 / 恢复所有权 / 应用卸载 / 工作流 / AI / 本地化 |
| SafetyKit | 三色判定 / hardForbid / firmlink 镜像 / VendorTrie / RuleLoader / vendor 自检 / CommonAppCache 规则 |
| ScanKit | 隐藏文件 / inode 去重 / 引擎一致性 / golden 快照 / DevArtifacts 规则 / 多 worker 并发 / DerivedData per-project / SimCtl / NodeModules |
| HeuristicKit | 评分公式 / forbid 红线 / JSON round-trip |
| LogKit | IOErrorClassifier / AmuxLog round-trip |
| BrewKit | BrewCleanup / BrewController / BrewRegistry |
| FileSearchKit | FileSearchEngine（含扩展过滤器） |
| AIKit | AISettings / OpenAIChatClient / PathRedactor / PromptBuilder |
| TestHarness | FixtureFS / ScenarioBuilder / GoldenSnapshot |

> 具体测试数以本地实际 `swift test` 输出为准；本表只列覆盖面，避免因新增用例后过时。

### CI 与本地的性能 budget 差异

[VendorTrieTests](../Packages/SafetyKit/Tests/SafetyKitTests/VendorTrieTests.swift) 中的 `test_trie匹配159条vendor性能基准` 用环境变量 `CI=true / GITHUB_ACTIONS=true` 区分 budget：本地 100ms，GitHub Actions runner 250ms（runner 慢 ~35%）。新增性能基准测试请遵循同样 split。

### 扫描引擎 bench

```bash
./Scripts/bench.sh ~/Downloads
./Scripts/bench.sh ~/Library/Caches

# 生产协调器链路（不会启动 App）
swift run -c release --package-path Tools/CoordinatorBench CoordinatorBench \
  --root "$HOME/Library/Caches"
swift run -c release --package-path Tools/CoordinatorBench CoordinatorBench \
  --root "$HOME" --large-files
swift run -c release --package-path Tools/CoordinatorBench CoordinatorBench \
  --root "$HOME" --developer
```

`bench.sh` 会跟 `du -h` 对比物理占用（含 firmlink / iCloud 占位 / 硬链接 / APFS clone
修正）。CoordinatorBench 分别覆盖普通投影、HOME Large Files 与 Developer discovery +
candidate forest 全链路；三者不能互相替代。

---

## 目录结构

```
AmuxAIClean/
├─ App/                          # SwiftUI 入口（@main + 加载 vendors.yaml + 注入 MainView/UninstallScreen）
├─ Packages/
│  ├─ ScanKit/                   # 扫描引擎 + bench CLI
│  ├─ SafetyKit/                 # 安全评分 + 规则引擎（零外部依赖）
│  ├─ AppUI/                     # SwiftUI 视图层 + 业务 actor（最大包）
│  ├─ HeuristicKit/              # 启发式学习
│  ├─ LogKit/                    # 结构化日志
│  ├─ BrewKit/                   # Homebrew 集成
│  ├─ FileSearchKit/             # 通用文件搜索
│  ├─ AIKit/                     # 可选 AI 建议（默认关闭；仅用户主动请求时访问其配置端点）
│  └─ TestHarness/               # 测试基础设施
├─ Resources/
│  └─ Rules/
│     ├─ vendors.yaml            # 厂商路径与 Bundle ID 规则；以当前文件为准
│     ├─ vendor_shared.yaml      # 共享厂商目录白名单
│     └─ safe_paths.yaml         # 已知安全前缀
├─ Scripts/
│  ├─ setup_dev.sh               # 新机器开发环境初始化（v1.5.x 后不再装 xcodegen）
│  ├─ run_debug.sh               # ⌘R 同款（命令行版，APP_PATH 用 -showBuildSettings 动态查）
│  ├─ build_release.sh           # Release 构建（签名由 project.pbxproj 决定）
│  ├─ make_dmg.sh                # hdiutil 打 DMG，create-dmg fallback
│  ├─ codesign.sh                # 显式 Developer ID 签名辅助脚本
│  ├─ make_app_icon.swift        # 22.37% squircle + 12% 留白生成 AppIcon 套装
│  ├─ make_icns.sh               # 生成 .icns
│  └─ bench.sh                   # ScanKit vs du 对比
├─ Tools/
│  ├─ CoordinatorBench/          # 生产协调器性能基准 CLI
│  ├─ PerfBench/                 # 性能基准 CLI
│  └─ SeedingTool/               # vendor 规则自动生成 CLI（一次性）
├─ docs/
│  ├─ INSTALL.md                 # 用户安装与 TCC 授权步骤
│  ├─ DEVELOPMENT.md             # 本文件
│  ├─ USER_GUIDE.md              # 当前用户操作（另有 English）
│  ├─ CURRENT_STATE.md           # 当前实现与验证范围
│  ├─ screenshots/              # 当前中英文视图素材及来源
│  ├─ ROADMAP_V1.md              # 历史范围与验收计划
│  ├─ FEATURE_GAP.md             # v1.2 历史竞品研究
│  ├─ COMPETITORS.md             # 竞品总览
│  └─ competitors/               # 单家竞品分析
├─ AmuxAIClean.xcodeproj/        # 原生 Xcode 工程（v1.5.x 后入仓，xcuserdata 仍 ignore）
├─ PITFALLS.md                   # 避坑手册（开工必读）
├─ SECURITY.md                   # 安全模型与威胁模型说明
├─ CONTRIBUTING.md               # 贡献指南
├─ LICENSE                       # MIT
└─ README.md                     # 用户向首页
```

---

## 截图维护

<!-- v2026.10.14：截图改为生产视图的离屏采集，移除 AppleScript 猜位置和全桌面截图流程。 -->

```bash
./Scripts/screenshots.sh
./Scripts/screenshots.sh --output-dir build/documentation-capture/images
```

命令只运行显式开启的 `DocumentationScreenshotTests`，生成中英文六种场景；不启动 App、
不扫描真实 HOME、不移动文件、不发 AI 请求。空间分析使用临时文件，清理/专业结果使用示例指标；
状态卡片是采集时本机只读读数。Retina JPEG 用于网页展示；图片不是 C4/C5 验收。
生成后逐张检查文字、背景、裁切、路径和中英文差异，更新素材 manifest，再同步公开仓库。
详细数据边界、文件表及复现信息见 [screenshots/README.md](screenshots/README.md)。

## 测试与发布责任

当前 checkout 没有 `.github` 工作流，不存在自动 CI 或 push tag 自动发版链路。
本地测试和目标构建遵循 [AGENTS.md](../AGENTS.md) 的改动范围门槛；不能把静态审阅、离屏采集
或网页展示当作真实交互证据。真实 App 启动仍需按项目要求写清持续验收场景并取得用户同意。

正式发布、两个仓库的职责与已批准 DMG 的复用按 [RELEASE.md](RELEASE.md) 执行。
文档或图片更新不要求重打包，也不能移动已发布的源码 tag。

---

## 安全模型简述

AmuxAIClean 的删除链路设计上**永远拒绝 unlink**，所有候选只在用户确认后通过
`NSWorkspace.recycle` 移入废纸篓。完整威胁模型与红线见 [SECURITY.md](../SECURITY.md)。

三道闸门：

1. **候选级**：[SafetyEngine.evaluate](../Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) 对路径、解析后身份、HOME/系统卷边界和 hard-forbid 做三色判定；
2. **授权级**：确认状态机把精确路径、扫描 revision、风险 reason 和用户选择冻结为类型化 intent，View 不能自行决定 force；
3. **执行级**：[TrashPipeline](../Packages/AppUI/Sources/AppUI/TrashPipeline.swift) 在提交前重新验证身份、Safety、白名单、权限与完整性证据，最终只调用 `NSWorkspace.recycle`。当前无特权 Helper/XPC。

---

## 贡献

见 [CONTRIBUTING.md](../CONTRIBUTING.md)。

第一步永远是读 [PITFALLS.md](../PITFALLS.md)。新增删除路径必须先实现 dryRun，绝不削弱已有测试，绝不抄竞品源码。

---

## 致谢

- [PITFALLS.md](../PITFALLS.md) 中所有提到的项目（CleanMyMac / AppCleaner / Pearcleaner / OnyX / DaisyDisk / GrandPerspective / ncdu / Sparkle / LuLu / Nektony 方法论 / Apple DTS Quinn）
- macOS 社区的真实用户事故反馈，每一条红线都来自真金白银的教训
