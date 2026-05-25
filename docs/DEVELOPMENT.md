# GSYCleanMac 开发文档

面向想自己改 / 编 / 跑测试 / 贡献代码的人。用户向的安装看 [INSTALL.md](INSTALL.md)。

---

## 工程概览

- **Swift 6.0 + SwiftUI + macOS 15**（strict concurrency / warnings-as-errors）
- 工程描述：[XcodeGen](https://github.com/yonaskolb/XcodeGen) 的 [project.yml](../project.yml)
- 5 个独立 SwiftPM 包 + 主 App（v1.3.zzzz 路线 B 删 Helper / XPCBridge 后；删除走 [TrashPipeline](../Packages/AppUI/Sources/AppUI/TrashPipeline.swift) 直接调 `NSWorkspace.recycle`，无特权进程）
- CI 用 GitHub Actions macos-15 runner

---

## 前置依赖

| 工具 | 版本 | 备注 |
|---|---|---|
| macOS | 15 Sequoia 或更高 | |
| Xcode | 16+ | 自带 Swift 6 toolchain |
| Homebrew | latest | |
| xcodegen | latest | `brew install xcodegen`（[Scripts/setup_dev.sh](../Scripts/setup_dev.sh) 自动装） |
| create-dmg | optional | 仅打 DMG 用，[Scripts/make_dmg.sh](../Scripts/make_dmg.sh) 会 fallback 到 hdiutil |

---

## 一键初始化

```bash
git clone git@github.com:CarGuo/GSYCleanMac.git
cd GSYCleanMac
./Scripts/setup_dev.sh
```

这一步会：检查 macOS / Xcode / Homebrew，安装 xcodegen，跑 `xcodegen generate`，最后 `open` xcodeproj。

---

## Free Apple ID Run（Debug 跑）

1. 打开 `GSYCleanMac.xcodeproj`
2. `Settings -> Accounts` 用 Apple ID 登录（不用 Developer Program）
3. 选中 `GSYCleanMac` target -> `Signing & Capabilities` -> `Team` 选 `Personal Team`
4. 点 `Run`

---

## 命令行 Debug 构建

```bash
xcodebuild -scheme GSYCleanMac -configuration Debug \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  -derivedDataPath build/dd \
  build
```

产物在 `build/dd/Build/Products/Debug/GSYCleanMac.app`。

---

## Release 打包 + DMG

```bash
VERSION=1.0.0 ./Scripts/build_release.sh
./Scripts/make_dmg.sh dist/GSYCleanMac.app dist/GSYCleanMac-1.0.0.dmg
```

[Scripts/build_release.sh](../Scripts/build_release.sh) 默认 ad-hoc 签名（`CODE_SIGN_IDENTITY="-"`）；如有 Developer ID，传 `IDENTITY="Developer ID Application: ..."` 覆盖。

---

## 跑测试

### 全部 6 个包

```bash
for pkg in ScanKit SafetyKit XPCBridge AppUI HeuristicKit TestHarness; do
  (cd "Packages/$pkg" && swift test) || exit 1
done
```

### 当前测试矩阵

| 包 | 测试数 | 关键覆盖 |
|---|---|---|
| AppUI | 97 | UninstallStore / AppUninstaller / OrphanScanner / TreeBrowserSort / LargeFiles / ScanCoordinatorFullDisk / TCCProbe / HeuristicRecorder |
| SafetyKit | 30 | 三色判定 / hardForbid / firmlink 镜像 / VendorTrie / RuleLoader / vendor 自检 |
| XPCBridge | 8 | DeletionToken HMAC / TamperedDryRun |
| ScanKit | 22 | 隐藏文件 / inode 去重 / 引擎一致性 / golden 快照 / 5 条多 worker 并发 |
| HeuristicKit | 11 | 评分公式 / forbid 红线 / JSON round-trip |
| TestHarness | 8 | FixtureFS / ScenarioBuilder / GoldenSnapshot |
| **总计** | **176** | xcodebuild Release BUILD SUCCEEDED |

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
│  ├─ setup_dev.sh               # 新机器开发环境初始化
│  ├─ build_release.sh           # Release 构建 + ad-hoc 签名（CI 也走这条）
│  ├─ make_dmg.sh                # hdiutil 打 DMG，create-dmg fallback
│  ├─ codesign.sh                # 显式 Developer ID 签名（可选）
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
│  ├─ ci.yml                     # push/PR -> 6 包 swift test + xcodebuild Debug
│  └─ release.yml                # tag v*.*.*  -> Release 构建 + DMG + sha256 + GitHub Release
├─ project.yml                   # XcodeGen 工程描述
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
- 步骤：actions/cache@v4 缓存 SwiftPM build → 跑 6 个包 `swift test --parallel` → 跑 `xcodebuild Debug`
- 全部 176 测试通过才算绿

### Release（[.github/workflows/release.yml](../.github/workflows/release.yml)）

- 触发：push 形如 `v*.*.*` 的 tag（也支持 workflow_dispatch 手动）
- runner：macos-15
- 步骤：`brew install xcodegen` → [Scripts/build_release.sh](../Scripts/build_release.sh) → [Scripts/make_dmg.sh](../Scripts/make_dmg.sh) → `shasum -a 256` → upload-artifact + softprops/action-gh-release@v2 自动建 Release

### 发版步骤

```bash
# 1. 改 project.yml 里 CFBundleShortVersionString，跟 git tag 对齐
# 2. 提交、合并到 main
git push origin main

# 3. 打 tag 触发
git tag -a v1.0.1 -m "v1.0.1 - <change summary>"
git push origin v1.0.1

# 4. 几分钟后 Releases 页会自动出现 GSYCleanMac-1.0.1.dmg + .sha256
gh release view v1.0.1 --repo CarGuo/GSYCleanMac
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
