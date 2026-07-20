# GSYCleanMac 开发文档

面向想自己改 / 编 / 跑测试 / 贡献代码的人。用户向的安装看 [INSTALL.md](INSTALL.md)。

---

## 工程概览

- **Swift 6.0 + SwiftUI，产品部署下限 macOS 13.5**（strict concurrency / warnings-as-errors）
  <!-- v2026.07.16：部署下限与开发机工具链解耦；本地开发仍统一使用 macOS 15+ / Xcode 16+。 -->
- 工程描述：原生 Xcode 工程 [GSYCleanMac.xcodeproj](../GSYCleanMac.xcodeproj)（直接入仓，无 xcodegen / project.yml）
- 9 个独立 SwiftPM 包（AIKit / AppUI / BrewKit / FileSearchKit / HeuristicKit / LogKit / SafetyKit / ScanKit / TestHarness）+ 主 App，作为 Local SPM 在 Xcode UI 的 Package Dependencies 区域引用
- 删除走 [TrashPipeline](../Packages/AppUI/Sources/AppUI/TrashPipeline.swift) 直接调 `NSWorkspace.recycle`，无特权进程
- GitHub Actions 配置当前只保留手动入口，CI 与 Release job 都以 `if: false` 显式停用；提交质量证据来自本地 9 包测试和目标 Xcode 构建

---

## 前置依赖

| 工具 | 版本 | 备注 |
|---|---|---|
| macOS | 15 Sequoia 或更高 | 开发机要求；不是产品的 macOS 13.5 部署下限 |
| Xcode | 16+ | 自带 Swift 6 toolchain |
| Apple Developer 账号 | 企业账号 / 个人账号均可 | 当前仓库 Debug 默认使用 Apple Development 自动签名；Release 默认使用 Team `W6H34N9728` + Developer ID Application 手动签名；fork 需要替换为自己的 Team / signing 配置 |
| Homebrew | optional | 仅 `xcbeautify` 装饰输出 / `create-dmg` 打 DMG 时需要 |

> 不再需要 `xcodegen` —— v1.5.x 起项目回归原生 Xcode 工程，[GSYCleanMac.xcodeproj](../GSYCleanMac.xcodeproj) 直接入仓。

---

## 一键初始化

```bash
git clone git@github.com:CarGuo/GSYCleanMac.git
cd GSYCleanMac
./Scripts/setup_dev.sh
```

[Scripts/setup_dev.sh](../Scripts/setup_dev.sh) 会：检查 macOS / Xcode / Homebrew，确认 [GSYCleanMac.xcodeproj](../GSYCleanMac.xcodeproj) 已就绪，并提示你在 Xcode 里确认 Team / signing 配置。

---

## 签名配置

> **fork 用户必读**：仓库里 [GSYCleanMac.xcodeproj/project.pbxproj](../GSYCleanMac.xcodeproj/project.pbxproj) 当前 Debug 配置为 `CODE_SIGN_STYLE = Automatic` + `CODE_SIGN_IDENTITY = Apple Development`，Release 配置为 `DEVELOPMENT_TEAM = W6H34N9728` + `CODE_SIGN_STYLE = Manual` + `CODE_SIGN_IDENTITY = Developer ID Application: SentenceEnd Inc (W6H34N9728)`。没有对应证书时，第一次跑必须改成你自己的 Team / signing 配置。

**方式 A（图形化，推荐新手）**：

1. 双击打开 [GSYCleanMac.xcodeproj](../GSYCleanMac.xcodeproj)
2. Xcode → Settings → Accounts → 用你的 Apple Developer 账号登录
3. 选中 `GSYCleanMac` target → `Signing & Capabilities`
   - 本地调试：保持 Automatically manage signing，`Team` 下拉选你自己的 Team
   - Release 分发：保持 Manual signing，选择自己的 Team / Developer ID Application 证书
   - `Bundle Identifier` 必要时改成你自己的（如 `com.<你的id>.cleanmac.AmuxAIClean`）
4. ⌘S 保存（会写进 [project.pbxproj](../GSYCleanMac.xcodeproj/project.pbxproj) 的 `DEVELOPMENT_TEAM` 字段）
5. 点 `Run` 跑起来

**方式 B（命令行，老司机）**：

```bash
# 在 https://developer.apple.com/account 右上角找到自己的 Team ID（10 位）
sed -i '' 's/W6H34N9728/<你的Team ID>/g' GSYCleanMac.xcodeproj/project.pbxproj
xcodebuild -project GSYCleanMac.xcodeproj -scheme GSYCleanMac -configuration Debug build
```

**为什么要稳定 Team 签名而不是 ad-hoc**：TCC（含完全磁盘访问）不是看"有没有签名"这么粗，而是用 bundle id + code requirement（签名身份 / Team / 证书链等）去匹配授权记录。Apple Development / Developer ID Application 的 designated requirement 可以跨普通 rebuild 保持同一类身份；ad-hoc (`-`) 没有稳定身份，代码变化后更容易让 TCC 记录失配。排查 Debug 反复掉授权时，用 [diagnose_debug_tcc.sh](../Scripts/diagnose_debug_tcc.sh) 对比两次 build 的 designated requirement / Authority / TCC 记录，而不是只看 cdhash。

---

## 命令行 Debug 构建

```bash
xcodebuild -project GSYCleanMac.xcodeproj -scheme GSYCleanMac -configuration Debug build
```

Debug 签名由 [GSYCleanMac.xcodeproj](../GSYCleanMac.xcodeproj) 里的 `CODE_SIGN_STYLE = Automatic` + `CODE_SIGN_IDENTITY = Apple Development` + `DEVELOPMENT_TEAM = W6H34N9728` 决定。产物路径用 `xcodebuild -showBuildSettings` 动态查（脚本已封装，见 [Scripts/run_debug.sh](../Scripts/run_debug.sh)）。

---

## Release 打包 + DMG

```bash
./Scripts/build_release.sh --no-notarize
AMUX_CLEAN_NOTARY_KEYCHAIN_PROFILE=amux-notary ./Scripts/build_release.sh --notarize
```

[Scripts/build_release.sh](../Scripts/build_release.sh) 走 `xcodebuild -configuration Release`。Release 签名由 [project.pbxproj](../GSYCleanMac.xcodeproj/project.pbxproj) 里的 Manual + Developer ID Application 配置决定；`--notarize` 会额外执行 Apple Notary、staple 与 Gatekeeper 校验。
未传 `VERSION` 时脚本使用工程当前 `MARKETING_VERSION`；只有明确制作另一个版本候选时才传入
`VERSION=x.y.z`，避免文档示例固化并回写过期版本。

---

## 跑测试

### 全部 9 个包

```bash
for pkg in ScanKit SafetyKit AppUI HeuristicKit LogKit BrewKit FileSearchKit AIKit TestHarness; do
  (cd "Packages/$pkg" && swift test) || exit 1
done
```

### 当前测试矩阵

| 包 | 关键覆盖 |
|---|---|
| AppUI | UninstallStore / AppUninstaller / OrphanScanner / TreeBrowserSort / LargeFiles / ScanCoordinatorFullDisk / TCCProbe / HeuristicRecorder / DevArtifacts UI / PortCleaner / TrashPipeline dry-run |
| SafetyKit | 三色判定 / hardForbid / firmlink 镜像 / VendorTrie / RuleLoader / vendor 自检 / CommonAppCache 规则 |
| ScanKit | 隐藏文件 / inode 去重 / 引擎一致性 / golden 快照 / DevArtifacts 规则 / 多 worker 并发 / DerivedData per-project / SimCtl / NodeModules |
| HeuristicKit | 评分公式 / forbid 红线 / JSON round-trip |
| LogKit | IOErrorClassifier / GSYLog round-trip |
| BrewKit | BrewCleanup / BrewController / BrewRegistry |
| FileSearchKit | FileSearchEngine（含扩展过滤器） |
| AIKit | AISettings / OpenAIChatClient / PathRedactor / PromptBuilder |
| TestHarness | FixtureFS / ScenarioBuilder / GoldenSnapshot |

> 具体测试数以本地 / CI 实际 `swift test` 输出为准；本表只列覆盖面，避免因新增用例后过时。

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
GSYCleanMac/
├─ App/                          # SwiftUI 入口（@main + 加载 vendors.yaml + 注入 MainView/UninstallScreen）
├─ Helper/                       # 特权 Helper（v1 不部署，留给 v2 Premium）
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
│     ├─ vendors.yaml            # 36 条已清洗 vendor 规则（v1.0）
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
│  ├─ PerfBench/                 # 性能基准 CLI
│  └─ SeedingTool/               # vendor 规则自动生成 CLI（一次性）
├─ docs/
│  ├─ INSTALL.md                 # 用户安装与 TCC 授权步骤
│  ├─ DEVELOPMENT.md             # 本文件
│  ├─ ROADMAP_V1.md              # v1.0 范围与验收清单
│  ├─ FEATURE_GAP.md             # 与 CleanMyMac/AppCleaner/Pearcleaner/DaisyDisk 等差距分析
│  ├─ COMPETITORS.md             # 竞品总览
│  └─ competitors/               # 单家竞品分析
├─ .github/workflows/
│  ├─ ci.yml                     # 仅保留 workflow_dispatch；全部 job 当前 if: false
│  └─ release.yml                # 仅保留 workflow_dispatch；release job 当前 if: false
├─ GSYCleanMac.xcodeproj/        # 原生 Xcode 工程（v1.5.x 后入仓，xcuserdata 仍 ignore）
├─ PITFALLS.md                   # 避坑手册（开工必读）
├─ SECURITY.md                   # 安全模型与威胁模型说明
├─ CONTRIBUTING.md               # 贡献指南
├─ LICENSE                       # MIT
└─ README.md                     # 用户向首页
```

---

## CI / Release 工作流

<!-- v2026.07.18：按 workflow 的真实触发器和 job 条件重写，禁止把停用配置描述成可执行发布链。 -->

### CI（[.github/workflows/ci.yml](../.github/workflows/ci.yml)）

- 仅声明 `workflow_dispatch`；push / pull request 不触发。
- `swift-test` 和 `xcode-build` 两个 job 当前都为 `if: false`，手动 Run workflow 也不会分配 runner 或产生测试结果。
- 因此 GitHub 上没有可称为“CI 绿”的自动证据。提交前必须按根目录 [AGENTS.md](../AGENTS.md) 在本地跑对应包测试；跨主链路改动跑全部 9 包，再做目标 Debug 构建。

### Release（[.github/workflows/release.yml](../.github/workflows/release.yml)）

- 仅声明 `workflow_dispatch`，但 `release-disabled` job 当前为 `if: false`。
- push tag 不触发；手动 dispatch 也不会构建、上传 artifact 或创建 GitHub Release。
- 当前有效发布路径是维护者本地 Developer ID 构建和最终 DMG-only Notary 链路。

### 发版步骤

版本、签名、公证、staple、Gatekeeper、最终 SHA256 及 tag 顺序只以
[RELEASE.md](RELEASE.md) 为准，本开发文档不复制易漂移的命令。构建本地 Release/DMG 不等于已上传
GitHub；commit、tag、push 和创建 Release 是分别授权的外部操作。

---

## 安全模型简述

GSYCleanMac 的删除链路设计上**永远拒绝 unlink**，所有候选只在用户确认后通过
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
