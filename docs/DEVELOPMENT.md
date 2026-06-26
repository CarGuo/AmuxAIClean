# GSYCleanMac 开发文档

面向想自己改 / 编 / 跑测试 / 贡献代码的人。用户向的安装看 [INSTALL.md](INSTALL.md)。

---

## 工程概览

- **Swift 6.0 + SwiftUI + macOS 15**（strict concurrency / warnings-as-errors）
- 工程描述：原生 Xcode 工程 [GSYCleanMac.xcodeproj](../GSYCleanMac.xcodeproj)（直接入仓，无 xcodegen / project.yml）
- 6 个独立 SwiftPM 包（AppUI / HeuristicKit / LogKit / SafetyKit / ScanKit / TestHarness）+ 主 App，作为 Local SPM 在 Xcode UI 的 Package Dependencies 区域引用
- 删除走 [TrashPipeline](../Packages/AppUI/Sources/AppUI/TrashPipeline.swift) 直接调 `NSWorkspace.recycle`，无特权进程
- CI 用 GitHub Actions macos-15 runner（v1.5.x 起 `xcode-build` job 暂时屏蔽以省 Actions 额度，保留 6 包 `swift test`）

---

## 前置依赖

| 工具 | 版本 | 备注 |
|---|---|---|
| macOS | 15 Sequoia 或更高 | |
| Xcode | 16+ | 自带 Swift 6 toolchain |
| Apple Developer 账号 | 企业账号 / 个人账号均可 | 当前仓库默认使用企业 Team `W6H34N9728` + Apple Distribution 手动签名；fork 需要替换为自己的 Team / signing 配置 |
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

> **fork 用户必读**：仓库里 [GSYCleanMac.xcodeproj/project.pbxproj](../GSYCleanMac.xcodeproj/project.pbxproj) 当前按企业证书配置为 `DEVELOPMENT_TEAM = W6H34N9728` + `CODE_SIGN_STYLE = Manual` + `CODE_SIGN_IDENTITY = Apple Distribution`。没有对应企业证书时，直接 build 会报 `No matching profile` 或 codesign 身份缺失。**第一次跑必须改成你自己的 Team / signing 配置**，方法二选一：

**方式 A（图形化，推荐新手）**：

1. 双击打开 [GSYCleanMac.xcodeproj](../GSYCleanMac.xcodeproj)
2. Xcode → Settings → Accounts → 用你的 Apple Developer 账号登录
3. 选中 `GSYCleanMac` target → `Signing & Capabilities`
   - 企业分发：保持 Manual signing，选择自己的企业 Team / Apple Distribution 证书 / provisioning profile
   - 本地调试：也可以改回 Automatically manage signing，`Team` 下拉选你自己的 Team
   - `Bundle Identifier` 必要时改成你自己的（如 `com.<你的id>.cleanmac.AmuxAIClean`）
4. ⌘S 保存（会写进 [project.pbxproj](../GSYCleanMac.xcodeproj/project.pbxproj) 的 `DEVELOPMENT_TEAM` 字段）
5. 点 `Run` 跑起来

**方式 B（命令行，老司机）**：

```bash
# 在 https://developer.apple.com/account 右上角找到自己的 Team ID（10 位）
sed -i '' 's/W6H34N9728/<你的Team ID>/g' GSYCleanMac.xcodeproj/project.pbxproj
xcodebuild -project GSYCleanMac.xcodeproj -scheme GSYCleanMac -configuration Debug build
```

**为什么要稳定 Team 签名而不是 ad-hoc**：Apple Development / Apple Distribution 证书 SHA-1 稳定 → 跨 build cdhash 稳定 → TCC（含完全磁盘访问）授权不随每次构建反复失效；而 ad-hoc (`-`) 每次 cdhash 都变，TCC 每次都要重新授权（v1.5.x 之前的痛点）。

---

## 命令行 Debug 构建

```bash
xcodebuild -project GSYCleanMac.xcodeproj -scheme GSYCleanMac -configuration Debug build
```

签名完全由 [GSYCleanMac.xcodeproj](../GSYCleanMac.xcodeproj) 里的 `CODE_SIGN_STYLE = Manual` + `CODE_SIGN_IDENTITY = Apple Distribution` + `DEVELOPMENT_TEAM = W6H34N9728` 决定，命令行不用再传 `CODE_SIGN_IDENTITY` / `CODE_SIGNING_REQUIRED` 等 override。产物路径用 `xcodebuild -showBuildSettings` 动态查（脚本已封装，见 [Scripts/run_debug.sh](../Scripts/run_debug.sh)）。

---

## Release 打包 + DMG

```bash
VERSION=1.5.6 ./Scripts/build_release.sh
./Scripts/make_dmg.sh dist/AmuxAIClean.app dist/AmuxAIClean-1.5.6.dmg
```

[Scripts/build_release.sh](../Scripts/build_release.sh) 走 `xcodebuild -configuration Release` —— 签名由 [project.pbxproj](../GSYCleanMac.xcodeproj/project.pbxproj) 里的 Manual + Apple Distribution 企业证书配置决定。

---

## 跑测试

### 全部 6 个包

```bash
for pkg in ScanKit SafetyKit AppUI HeuristicKit LogKit TestHarness; do
  (cd "Packages/$pkg" && swift test) || exit 1
done
```

### 当前测试矩阵

| 包 | 测试数 | 关键覆盖 |
|---|---|---|
| AppUI | 252 | UninstallStore / AppUninstaller / OrphanScanner / TreeBrowserSort / LargeFiles / ScanCoordinatorFullDisk / TCCProbe / HeuristicRecorder / DevArtifacts UI |
| SafetyKit | 30 | 三色判定 / hardForbid / firmlink 镜像 / VendorTrie / RuleLoader / vendor 自检 |
| ScanKit | 117 | 隐藏文件 / inode 去重 / 引擎一致性 / golden 快照 / DevArtifacts 30 规则 / 多 worker 并发 |
| HeuristicKit | 11 | 评分公式 / forbid 红线 / JSON round-trip |
| TestHarness | 8 | FixtureFS / ScenarioBuilder / GoldenSnapshot |
| LogKit | 数项 | 结构化日志 round-trip |
| **总计** | **370+** | xcodebuild Release BUILD SUCCEEDED |

### CI 与本地的性能 budget 差异

[VendorTrieTests](../Packages/SafetyKit/Tests/SafetyKitTests/VendorTrieTests.swift) 中的 `test_trie匹配159条vendor性能基准` 用环境变量 `CI=true / GITHUB_ACTIONS=true` 区分 budget：本地 100ms，GitHub Actions runner 250ms（runner 慢 ~35%）。新增性能基准测试请遵循同样 split。

### 扫描引擎 bench

```bash
./Scripts/bench.sh ~/Downloads
./Scripts/bench.sh ~/Library/Caches
```

会跟 `du -h` 对比物理占用（含 firmlink / iCloud 占位 / 硬链接 / APFS clone 修正）。

---

## 目录结构

```
GSYCleanMac/
├─ App/                          # SwiftUI 入口（@main + 加载 vendors.yaml + 注入 MainView/UninstallScreen）
├─ Helper/                       # 特权 Helper（v1 不部署，留给 v2 Premium）
├─ Packages/
│  ├─ ScanKit/                   # 扫描引擎 + bench CLI
│  ├─ SafetyKit/                 # 安全评分 + 规则引擎
│  ├─ XPCBridge/                 # 主 App ↔ Helper XPC 协议
│  ├─ AppUI/                     # SwiftUI 视图层 + 业务 actor
│  ├─ HeuristicKit/              # 启发式学习
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
│  ├─ regression.sh              # 19 case 真实场景回归
│  ├─ make_dmg.sh                # hdiutil 打 DMG，create-dmg fallback
│  ├─ codesign.sh                # 显式 Developer ID 签名（可选 / 99/年才用）
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
│  ├─ ci.yml                     # push/PR -> 6 包 swift test（xcode-build job 暂屏蔽）
│  └─ release.yml                # workflow_dispatch 手动触发 -> Release + DMG + sha256（push tag 自动触发暂关）
├─ GSYCleanMac.xcodeproj/        # 原生 Xcode 工程（v1.5.x 后入仓，xcuserdata 仍 ignore）
├─ PITFALLS.md                   # 避坑手册（开工必读）
├─ SECURITY.md                   # 安全模型与威胁模型说明
├─ CONTRIBUTING.md               # 贡献指南
├─ LICENSE                       # MIT
└─ README.md                     # 用户向首页
```

---

## CI / Release 工作流

### CI（[.github/workflows/ci.yml](../.github/workflows/ci.yml)）

- 触发：push 到 main / PR 到 main
- runner：macos-15
- 步骤：actions/cache@v4 缓存 SwiftPM build → 跑 6 个包 `swift test --parallel` → `xcodebuild Debug` job 暂用 `if: false` 屏蔽（省 GitHub Actions 额度，将来可一键打开）
- 全部 370+ 测试通过才算绿

### Release（[.github/workflows/release.yml](../.github/workflows/release.yml)）

- 触发：**仅 `workflow_dispatch` 手动触发**（push tag 自动触发已暂时关掉省额度）
- runner：macos-15
- 步骤：inline `xcodebuild`（CI 需要注入对应企业证书和 provisioning profile）→ [Scripts/make_dmg.sh](../Scripts/make_dmg.sh) → `shasum -a 256` → upload-artifact + softprops/action-gh-release@v2 自动建 Release

### 发版步骤

```bash
# 1. 改 App/Info.plist 里 CFBundleShortVersionString，跟 git tag 对齐
# 2. 提交、合并到 main
git push origin main

# 3. 打 tag（仅做版本标记，不触发 CI 自动打包）
git tag -a v1.5.6 -m "v1.5.6 - <change summary>"
git push origin v1.5.6

# 4. 去 GitHub Actions UI 里 release.yml 点 "Run workflow" 手动触发
# 5. 几分钟后 Releases 页会自动出现 GSYCleanMac-1.5.6.dmg + .sha256
gh release view v1.5.6 --repo CarGuo/GSYCleanMac
```

---

## 安全模型简述

GSYCleanMac 的删除链路设计上**永远拒绝 unlink**，所有"删除"都走废纸篓，用户保留最后一次反悔窗口。完整威胁模型与红线见 [SECURITY.md](../SECURITY.md)。

三道闸门：

1. **连接级**：Helper 走 `NSXPCListener` + `mach service` 名字白名单
2. **消息级**：每条 DeletionToken 都带 HMAC，Helper 启动读 `GSYCLEAN_ALLOW_REAL_DELETE`，缺省永远 dry-run
3. **语义级**：[SafetyEngine.evaluate](../Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) 三色判定，hardForbid 黑名单写死不可配置；vendor 命中后强制降为 confirm

---

## 贡献

见 [CONTRIBUTING.md](../CONTRIBUTING.md)。

第一步永远是读 [PITFALLS.md](../PITFALLS.md)。新增删除路径必须先实现 dryRun，绝不削弱已有测试，绝不抄竞品源码。

---

## 致谢

- [PITFALLS.md](../PITFALLS.md) 中所有提到的项目（CleanMyMac / AppCleaner / Pearcleaner / OnyX / DaisyDisk / GrandPerspective / ncdu / Sparkle / LuLu / Nektony 方法论 / Apple DTS Quinn）
- macOS 社区的真实用户事故反馈，每一条红线都来自真金白银的教训
