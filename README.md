# GSYCleanMac

**macOS 本地清理与卸载残留管家**

[![CI](https://github.com/guoshuyu225/GSYCleanMac/actions/workflows/ci.yml/badge.svg)](https://github.com/guoshuyu225/GSYCleanMac/actions/workflows/ci.yml)
[![Release](https://github.com/guoshuyu225/GSYCleanMac/actions/workflows/release.yml/badge.svg)](https://github.com/guoshuyu225/GSYCleanMac/actions/workflows/release.yml)

> 当前版本：v1.0 · 最低系统：macOS 15 Sequoia · 工程：XcodeGen + SwiftPM + Swift 6（strict concurrency / warnings-as-errors）

---

## 项目定位

GSYCleanMac 是一款面向 macOS 个人用户的本地清理与卸载残留工具，开源、零网络、零订阅。
设计取舍：

- **数据正确性**：APFS firmlinks / iCloud 占位 / 硬链接 / APFS clone 一律按物理占用计算。
- **安全永远默认 dry-run**：删除链路三道闸门（连接级 + 消息级 HMAC + 语义级 SafetyEngine），删只走废纸篓，绝不 unlink。
- **零成本上手**：本机直接 `Run`/`Debug`，**不依赖 Apple Developer Program（99 美元/年）**，Free Apple ID 即可。
- **可分发**：ad-hoc 签名 + 用户首次右键打开（信任安装路径），与 Pearcleaner / Stats 等同类项目一致。

详细设计决策与社区踩坑记录见 [PITFALLS.md](PITFALLS.md)。

---

## v1.0 功能矩阵

| 模块 | 关键能力 |
|------|----------|
| 扫描引擎（[ScanKit](Packages/ScanKit)） | getattrlistbulk DFS / firmlinks 正确处理 / inode 去重 / iCloud 占位双取 / 4~6 worker 并行（actor DirQueue work-stealing） / 跨卷停下钻 |
| 安全引擎（[SafetyKit](Packages/SafetyKit)） | 三色徽章 safe/confirm/forbid + hardForbid 黑名单 + safeCachePrefixes + VendorTrie 路径前缀降级 + RuleLoader 反向校验 |
| 删除链路（[TrashPipeline](Packages/AppUI/Sources/AppUI/TrashPipeline.swift)） | 永不 unlink，仅 NSWorkspace.recycle / dryRun 一等公民 / 批级原子拒绝 |
| 卸载残留（[AppUninstaller](Packages/AppUI/Sources/AppUI/AppUninstaller.swift)） | bundleID 严格前缀 + Vendor 字典 + Orphan 反扫三路并举 / 12 个 scope 全覆盖 / 短 appName 禁止模糊 |
| 厂商规则（[vendors.yaml](Resources/Rules/vendors.yaml)） | 36 条已清洗的 vendor，bundleIDPrefix 命中后展开 appSupportSubdir / cachesPath，外加 hardForbid 反向校验 |
| 大文件视图（[LargeFilesView](Packages/AppUI/Sources/AppUI/LargeFilesView.swift)） | 阈值过滤 + 4 档排序（size/mtime × asc/desc）+ Top N 截断 + 行内 Finder 显示/复制路径/移废纸篓 |
| 树视图与键盘（[TreeBrowserView](Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)） | 三列排序（name/size/count）+ j/k/h/l/Enter/Space/Cmd+R 键盘导航 + ScrollViewReader 自动 scroll |
| TCC 引导（[TCCProbe](Packages/AppUI/Sources/AppUI/TCCProbe.swift)） | 探测 errno=1 次数判定，跳系统设置 URL `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` |
| 启发式学习（[HeuristicKit](Packages/HeuristicKit)） | deleted/restored/kept 三元组评分，sanityCheck 红线，`~/Library/Application Support/GSYCleanMac/heuristic.json` 持久化 |

测试矩阵：6 个包 / 149+ 单测全绿（详见下方"跑测试"）。

---

## 安装（用户）

下载 [Releases](https://github.com/guoshuyu225/GSYCleanMac/releases) 中最新的 `GSYCleanMac-x.y.z.dmg`，详细步骤见 [docs/INSTALL.md](docs/INSTALL.md)。

简要：

1. 下载 `GSYCleanMac-1.0.0.dmg`，双击挂载，把 `GSYCleanMac.app` 拖进 `/Applications`
2. 首次双击会被 Gatekeeper 拦下（这是 ad-hoc 签名的预期行为）
3. macOS 15+：打开 系统设置 -> 隐私与安全 -> 滚到底部点 "仍要打开"；macOS 13–14：在 Finder 里右键 `GSYCleanMac.app` -> 选 "打开" -> 弹窗点 "打开"
4. Trust 一次后，之后双击直接开
5. 首次扫描需要在 系统设置 -> 隐私与安全 -> 完全磁盘访问 中勾选 GSYCleanMac，否则只能扫到用户目录可读部分

---

## 构建（开发者）

### 0. 前置依赖

- macOS 15 Sequoia 或更高
- Xcode 16+（Swift 6 toolchain）
- Homebrew

### 1. 一键初始化

```bash
./Scripts/setup_dev.sh
```

这一步会：检查 macOS / Xcode / Homebrew，安装 xcodegen，跑 `xcodegen generate`，最后 open xcodeproj。

### 2. Free Apple ID Run

打开 `GSYCleanMac.xcodeproj` -> Settings -> Accounts -> 用 Apple ID 登录 -> 选中 GSYCleanMac target -> Signing & Capabilities -> Team 选 Personal Team -> 点 Run。

### 3. 命令行 Debug 构建

```bash
xcodebuild -scheme GSYCleanMac -configuration Debug \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  -derivedDataPath build/dd \
  build
```

产物在 `build/dd/Build/Products/Debug/GSYCleanMac.app`。

### 4. Release 打包 + DMG

```bash
VERSION=1.0.0 ./Scripts/build_release.sh
./Scripts/make_dmg.sh dist/GSYCleanMac.app dist/GSYCleanMac-1.0.0.dmg
```

[Scripts/build_release.sh](Scripts/build_release.sh) 默认 ad-hoc 签名（`CODE_SIGN_IDENTITY="-"`）；如已加入 Apple Developer Program，可传 `IDENTITY="Developer ID Application: ..."` 覆盖。

---

## 跑测试

### 全部 6 个包（推荐）

```bash
for pkg in ScanKit SafetyKit XPCBridge AppUI HeuristicKit TestHarness; do
  (cd "Packages/$pkg" && swift test) || exit 1
done
```

### 当前测试矩阵

| 包 | 测试数 | 关键覆盖 |
|---|---|---|
| AppUI | 97 | UninstallStore / AppUninstaller（17 含 vendor 路 6） / OrphanScanner（13） / TreeBrowserSort（8） / LargeFiles（14） / ScanCoordinatorFullDisk / TCCProbe / HeuristicRecorder |
| SafetyKit | 30 | 三色判定 / hardForbid / firmlink 镜像 / VendorTrie / RuleLoader / vendor 自检 |
| XPCBridge | 8 | DeletionToken HMAC / TamperedDryRun |
| ScanKit | 22 | 隐藏文件 / inode 去重 / 引擎一致性 / golden 快照 / **5 条多 worker 并发**（饥饿/漏扫/staySingleVolume/actualConcurrency cap）|
| HeuristicKit | 11 | 评分公式 / forbid 红线 / JSON round-trip |
| TestHarness | 8 | FixtureFS / ScenarioBuilder / GoldenSnapshot |
| **总计** | **176** | xcodebuild Release BUILD SUCCEEDED |

### 扫描引擎正确性 bench

```bash
./Scripts/bench.sh ~/Downloads
./Scripts/bench.sh ~/Library/Caches
```

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
│  ├─ codesign.sh                # 由内向外的显式 Developer ID 签名（可选）
│  ├─ make_app_icon.swift        # 22.37% squircle + 12% 留白生成 AppIcon 套装
│  ├─ make_icns.sh               # 生成 .icns
│  └─ bench.sh                   # ScanKit vs du 对比
├─ Tools/
│  ├─ PerfBench/                 # 性能基准 CLI
│  └─ SeedingTool/               # vendor 规则自动生成 CLI（一次性）
├─ docs/
│  ├─ INSTALL.md                 # 用户安装与 TCC 授权步骤
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
└─ README.md
```

---

## 安全模型简述

GSYCleanMac 的删除链路设计上**永远拒绝 unlink**，所有"删除"都走废纸篓，用户保留最后一次反悔窗口。完整威胁模型与红线见 [SECURITY.md](SECURITY.md)。

三道闸门：

1. **连接级**：Helper 走 `NSXPCListener` + `mach service` 名字白名单
2. **消息级**：每条 DeletionToken 都带 HMAC，Helper 启动读 `GSYCLEAN_ALLOW_REAL_DELETE`，缺省永远 dry-run
3. **语义级**：[SafetyEngine.evaluate](Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) 三色判定，hardForbid 黑名单写死不可配置；vendor 命中后强制降为 confirm

---

## v1.0 功能演进

详见 [docs/ROADMAP_V1.md](docs/ROADMAP_V1.md)：

- T1 数据层：UserPathStore / AppSettings 全量单测
- T2 / T2.5 / T2.6：UI 入口 / Logo squircle 修复 / BulkScanner 4~6 worker 并行（参考 Pearcleaner v5 / DaisyDisk / OmniDS）
- T3 多层下钻
- T3.5 卸载残留三路并举：
  - T3.5a AppUninstaller 接 VendorRule（含 strictPrefix 防 com.foo.bar 误命中 com.foo.barbarian）
  - T3.5b OrphanScanner 反扫 ~/Library/{Application Support, Caches, Preferences} 一层 + LSCopy bundleID 反查
  - T3.5c vendors.yaml 清洗（493 行 / 159 vendor -> 127 行 / 36 条有效）
- T4 大文件视图 + T5 列排序/整盘扫描/键盘导航
- T6 总验收 + GitHub Actions + DMG

---

## 贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。

简要：第一步永远是读 [PITFALLS.md](PITFALLS.md)，新增删除路径必须先实现 dryRun，绝不削弱已有测试，绝不抄竞品源码。

---

## License

[MIT](LICENSE)。Copyright (c) 2026 GuoShuYu。

---

## 致谢

- PITFALLS.md 中所有提到的项目（CleanMyMac / AppCleaner / Pearcleaner / OnyX / DaisyDisk / GrandPerspective / ncdu / Sparkle / LuLu / Nektony 方法论 / Apple DTS Quinn）
- macOS 社区的真实用户事故反馈，每一条红线都来自真金白银的教训
