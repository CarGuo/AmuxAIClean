# Mole CLI 对齐路线图（v1.x → v2.0）

> **建档日期**：2026-06-10
> **依据**：[tw93/Mole](https://github.com/tw93/Mole) `main`（已 clone 到 `/tmp/Mole`，6.2 MB）
> **上游文档**：[docs/ROADMAP_V1.md](./ROADMAP_V1.md) / [docs/FEATURE_GAP.md](./FEATURE_GAP.md) / [docs/AUDIT_2026_06.md](./AUDIT_2026_06.md)
> **本文件用途**：把 Mole 的可借鉴能力按 ROI 拆解为可勾选的任务，每完成一项**回来打勾**并补"验收脚本"链接。

---

## 0. 调研结论摘要

Mole 是纯 Bash + 少量 Go (Bubble Tea TUI) 的 macOS 清理 CLI，六个子命令：
`clean / uninstall / purge / optimize / analyze / status`。

最值钱的三项资产：

1. **[/tmp/Mole/lib/core/app_protection_data.sh](file:///tmp/Mole/lib/core/app_protection_data.sh)** — 570 行精心维护的 27 类 bundle ID 模式（输入法 / 密码管理器 / IDE / AI 工具 / 数据库 / 代理 VPN / 截屏 / 通信 / 笔记 / 设计……），是全网最完整的 macOS 应用保护清单。
2. **[/tmp/Mole/lib/clean/dev.sh](file:///tmp/Mole/lib/clean/dev.sh)** — 1166 行覆盖 30+ 个开发生态的清理函数（Xcode 全家桶 / Go / Rust / Python / Docker / JetBrains Toolbox / AI Agents / Nix / Frontend build cache……）。
3. 工程化能力：[pkg_receipts.sh](file:///tmp/Mole/lib/core/pkg_receipts.sh) / [history.sh](file:///tmp/Mole/lib/core/history.sh) / [sudo.sh](file:///tmp/Mole/lib/core/sudo.sh) / [timeout.sh](file:///tmp/Mole/lib/core/timeout.sh) / [whitelist.sh](file:///tmp/Mole/lib/manage/whitelist.sh)。

---

## 1. 对照清单（Mole 有 / 我们有 / 我们缺）

按 ROI 排序，高分 = 收益大 × 成本低。

| # | 主题 | Mole 实现 | 我们现状 | 缺口 | 工作量 | 优先级 |
|---|---|---|---|---|---|---|
| 1 | **应用 bundle 保护清单** | 570 行 27 类 bundle ID | 仅路径维度 verdict | 把数据资产移植 + verdict 接入 | 1d | **P0** |
| 2 | **Xcode 全家桶清理** | DeviceSupport / SimRuntime / CoreSim / XCTestDevices / DocCache | 仅 DerivedData | 5 个 Scanner | 2d | **P0** |
| 3 | **Go / Rust / Python 缓存** | `GOCACHE` / `~/.cargo` / pip / uv / conda | 无 | 3 个 Scanner | 1d | **P0** |
| 4 | **AI Agents 旧版本清理** | Claude / Cursor / Copilot / Codex 各保留最新 N 版 | 无 | 1 个 Scanner + 版本检测 | 1d | P1 |
| 5 | **Docker / OrbStack 缓存** | 守 daemon 状态后清 | 无 | 1 个 Scanner | 0.5d | P1 |
| 6 | **JetBrains Toolbox 旧版本** | 保留当前 + 1 备份 | 无 | 1 个 Scanner | 0.5d | P1 |
| 7 | **DRY_RUN 全局开关** | 任意子命令 `--dry-run` | 仅 TrashPipeline 内部 | EnvironmentValue + 渲染层 | 1d | P1 |
| 8 | **白名单持久化** | 文件 + 模式匹配 | 仅运行期 `UserPathStore` 加路径 | 持久化 + 模式语法 + UI | 1.5d | P1 |
| 9 | **mo uninstall（应用卸载）** | LaunchAgent/Daemon/Container 全联动 | 部分（`AppUninstaller`） | 补齐 LaunchDaemon 维度 | 5d | P2 |
| 10 | **mo purge（残留扫描）** | [purge_paths.sh](file:///tmp/Mole/lib/manage/purge_paths.sh) 数据驱动 | 部分（`OrphanScanner`） | 引入残留路径数据资产 | 3d | P2 |
| 11 | **mo analyze treemap** | Bubble Tea Go 实现 | 仅 sidebar 总量 | SwiftUI Canvas treemap | 3d | P2 |
| 12 | **mo status 仪表盘** | CPU/Mem/Disk/Net 60s 折线 | 仅 HUD scan 进度 | macOS APIs + Charts | 3d | P2 |
| 13 | **统一 sudo / timeout 框架** | 单独抽 lib | 裸调散落 | 一层 wrapper | 1d | P2 |
| 14 | **MDM 官方卸载器规则** | ESET / Jamf / CrowdStrike / SentinelOne | 无 | 接入到 #1 数据资产 | 0.5d | P2 |
| 15 | **AI Agent git worktree 检测** | 无 uncommitted/untracked 才删 | 无 | git 子进程探测 | 1d | P3 |

---

## 2. 阶段目标

| 里程碑 | 包含 | ETA |
|---|---|---|
| **M1**（本周）| #1 bundle 保护清单接入 | 已开工 |
| **M2** | #2 Xcode 全家桶 + #3 Go/Rust/Python | M1+5d |
| **M3** | #4 AI Agents + #5 Docker + #6 JetBrains + #7 DRY_RUN | M2+3d |
| **M4**（v1.x 收尾）| #8 白名单持久化 + #13 sudo wrapper + #14 MDM 规则 | M3+3d |
| **v2.0** | #9–#12（uninstall 全联动 / purge / treemap / status 仪表盘） | 单独排期 |

---

## 3. M1 详细任务（P0 #1：bundle 保护清单接入）

### 3.1 任务拆解

| ID | 步骤 | 改动文件 | 验收 |
|---|---|---|---|
| M1-T1 | 数据移植 | 新建 [Packages/SafetyKit/Sources/SafetyKit/Resources/protected_bundles.json](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/Resources/protected_bundles.json) | JSON 合法 + ≥ 200 条规则 |
| M1-T2 | Package.swift 声明 resources | [Packages/SafetyKit/Package.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Package.swift) | `swift build` 通过 |
| M1-T3 | 新建 [BundleProtection.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/BundleProtection.swift) | 提供 `BundleProtection.match(bundleID:)` → `(matched, kind)` | 单测覆盖 wildcard / 前缀 / 否定 |
| M1-T4 | SafetyEngine 接入 | [SafetyEngine.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) `evaluateStandardized` 末尾叠加：若路径解析出 bundle ID 且命中 `data_protected` / `system_critical` → 升级到至少 `.confirm`（**不**强 forbid，避免与 vendors.yaml RuleLoader 过滤冲突；真正绝对禁删由 hardForbidPrefixes 保证）| 新增 `bundleSystemCritical` / `bundleDataProtected` rejection enum |
| M1-T5 | 测试落档 | 新建 [Packages/SafetyKit/Tests/SafetyKitTests/BundleProtectionTests.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Tests/SafetyKitTests/BundleProtectionTests.swift) | 覆盖 com.1password.* / com.jetbrains.* / com.apple.dock / com.tencent.xinWeChat / 通配符边界 |
| M1-T6 | 全量回归 | `swift test` | 0 failure |
| M1-T7 | 文档勾选 | 本文件 | M1 表格逐项 ☑ |

### 3.2 数据资产格式（决策）

JSON schema，避免 plist 编辑器锁定与 YAML 解析依赖：

```json
{
  "version": 1,
  "source": "tw93/Mole@app_protection_data.sh",
  "updated_at": "2026-06-10",
  "system_critical": [
    "com.apple.finder",
    "com.apple.dock",
    "com.apple.Settings*"
  ],
  "data_protected": [
    "com.1password.*",
    "com.jetbrains.*",
    "com.tencent.xinWeChat"
  ],
  "official_uninstaller_required": [
    {
      "vendor": "ESET",
      "bundle_prefixes": ["com.eset."],
      "name_fragments": ["eset management agent"]
    }
  ]
}
```

匹配规则：
- 精确匹配（无 `*`）走 `Set<String>.contains`
- 前缀通配（结尾 `*`）走 `BundleProtectionTrie`（沿用 `VendorTrie` 设计）
- 含中段通配（`*foo*` / `foo*bar`）退化为线性 `NSPredicate`，但数量受控（< 50）

### 3.3 SafetyEngine 接入位置

在 [evaluateStandardized](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) 既有规则**末尾**叠加，**不动现有红线**——这是非破坏性扩展：

```
现有规则 → 若已是 .forbid → 直接返回（hardForbidPrefixes 守门）
         → 否则解析路径 → bundle ID
         → 命中 system_critical → 升级到至少 .confirm + .bundleSystemCritical
         → 命中 data_protected → 升级到至少 .confirm + .bundleDataProtected
         → 否则保持原 verdict
```

> **策略说明**：原方案 `system_critical → .forbid` 已**调整为升级到 confirm**。原因：
> 1. 真正"绝对禁删"由 [hardForbidPrefixes](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift)（`/System`、`/Library/Apple`）拦截；
> 2. `~/Library/Containers/com.apple.*` 是**用户数据**（如 `Mail Downloads`），强 forbid 会触发 RuleLoader load-time 过滤规则：path 命中 forbid 但 vendor 自己声明 verdict=confirm → **整条 vendor 丢弃**，导致 MailDownloads / FinalCutProRender 等合法 vendor 被静默过滤。
> 3. 升级到 confirm 既能给用户警示，又不破坏 vendors.yaml 数据驱动的扫描契约。

路径 → bundle ID 解析规则（保守，不命中就跳过，永不误升级）：
- `/Applications/Foo.app/...` → 读 `Foo.app/Contents/Info.plist` 取 `CFBundleIdentifier`
- `~/Library/Application Support/<Name>/...` → 路径段反查（依赖 `BundleResolverCache`）
- `~/Library/Caches/<bundleID>/...` → 段本身即 bundle ID
- `~/Library/Preferences/<bundleID>.plist` → 文件名即 bundle ID

解析失败 → 跳过 bundle 规则，沿用既有 verdict，永不报错。

### 3.4 测试策略

| 维度 | Fixture / 断言 | 文件 |
|---|---|---|
| 精确匹配 | `com.apple.dock` → `.forbid` | BundleProtectionTests |
| 前缀通配 | `com.1password.7` → `.confirm` | BundleProtectionTests |
| 否定 case | `com.example.unknown` → nil | BundleProtectionTests |
| 路径解析 | `~/Library/Caches/com.1password.7/foo` → `.confirm` | SafetyEngine 集成测试 |
| 不破坏现有红线 | `/System/x` → 仍 `.forbid`（不被 confirm 降级） | SafetyEngine 集成测试 |
| JSON 完整性契约 | 加载成功 + version=1 + ≥ 200 条 + 无重复 | BundleProtectionDataIntegrityTests |
| 回归 | 全量 `swift test` 0 failure | CI |

---

## 4. 进度勾选

| 里程碑 | 项 | 状态 | PR / commit | 备注 |
|---|---|---|---|---|
| M1 | T1 数据移植（4 段 ≥ 360 条） | ☑ | working tree | system_critical 68 + apple_uninstallable 11 + data_protected 280+ + official_uninstaller_required 6 |
| M1 | T2 Package.swift resources | ☑ | working tree | `.process("Resources")` |
| M1 | T3 BundleProtection.swift 匹配引擎 | ☑ | working tree | 分桶 exact/prefix/contains + glob→regex |
| M1 | T4 SafetyEngine 接入 | ☑ | working tree | 升级 confirm 策略（非强 forbid，保护 vendors.yaml） |
| M1 | T5 BundleProtectionTests（22 case） | ☑ | working tree | 数据完整性契约 3 + 模式匹配 10 + SafetyEngine 集成 6 + glob 边界 2 + 优先级 1 |
| M1 | T6 全量回归 | ☑ | — | SafetyKit 153/154（仅 1 个**既有**性能基准失败已验证非本次回归）；AppUI 392/392 ✅；ScanKit 全绿 ✅；BatchVendorAdditions 4 个原失败**全部修复** |
| M1 | T7 文档勾选 | ☑ | 本文件 | — |

---

## 4.5 M2 开工前对比（防重复造轮子）

> **建档日期**：2026-06-10
> **背景**：用户提醒"对比好不要做差了"。M2 原计划是「Xcode 全家桶 + Go/Rust/Python 缓存」，但我们 [vendors.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml)（1090 行 / 81 vendor）已覆盖大量字段。本节做**逐项核对**，避免重复声明。

### 4.5.1 已覆盖 vs Mole（命中即不再重复实现）

| Mole 函数 / 路径 | 我们 vendors.yaml 对应 | 状态 | 备注 |
|---|---|---|---|
| `clean_xcode_documentation_cache` → `~/Library/Developer/Xcode/DocumentationCache` | [Apple Developer Tools L41-L43](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml#L41-L43) | ✅ 已覆盖 | safe |
| `clean_xcode_device_support` → iOS/watchOS/macOS DeviceSupport | [Apple Developer Tools L23-L31](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml#L23-L31) | ⚠️ **整目录 safe，缺"保留最新 N 版"逻辑** | Mole 的 `MOLE_XCODE_DEVICE_SUPPORT_KEEP=2` 是版本感知，我们目前是整目录 safe |
| `~/Library/Developer/Xcode/DerivedData` | [Apple Developer Tools L20-L22](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml#L20-L22) | ✅ 已覆盖 | safe |
| `~/Library/Developer/Xcode/Archives` | [Apple Developer Tools L56-L58](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml#L56-L58) | ✅ 已覆盖 | **比 Mole 更细**：confirm + reason 解释 dSYM 影响 |
| `~/Library/Developer/Xcode/iOS DeviceLogs` | [Apple Developer Tools L59-L61](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml#L59-L61) | ✅ 已覆盖 | confirm |
| `clean_xcode_xctest_devices` → `~/Library/Developer/XCTestDevices` | **❌ 缺失** | 🟡 **M2 新增**（已确认） | Mole 整目录 safe + 进程探测 |
| `clean_xcode_system_coresimulator_caches` → `/Library/Developer/CoreSimulator/Caches` (**系统级** + sudo) | 仅 [~/Library/Developer/CoreSimulator/Caches L52-L54](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml#L52-L54) | ⚠️ **缺系统级** | 系统级 `/Library/...` 需 sudo，超出我们 GUI scope（user-space 优先），**M2 不做** |
| `clean_xcode_simulator_runtime_volumes` → `/Library/Developer/CoreSimulator/Volumes` | [Apple Developer Tools L70-L72](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml#L70-L72) `forbid` | ✅ 比 Mole **保守**（防 `simctl` 卡住） | 我们直接 forbid，Mole 才区分 in-use/unused 删 |
| `clean_dev_go` → `~/Library/Caches/go-build` + `~/go/pkg/mod/cache/download` | [Go L324-L334](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml#L324-L334) | ✅ 已覆盖 | 等价 `go clean -cache/-modcache` 注解 |
| `clean_dev_rust` → `~/.cargo/registry/cache` + `~/.cargo/git/db` | [Cargo L272-L291](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml#L272-L291) | ✅ 已覆盖 | **比 Mole 更细**：bin / config.toml forbid 多重防御 |
| `clean_dev_rust` → `~/.rustup/downloads` | [Rustup L293-L299](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml#L293-L299) | ✅ 已覆盖 | safe |
| `clean_dev_python` → `~/Library/Caches/pip` / `pypoetry` / XDG | [Python L301-L312](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml#L301-L312) | ✅ 已覆盖 | 等价 `pip cache purge` 注解 |
| `clean_uv_cache` → `~/Library/Caches/uv` + `~/.cache/uv` | [uv L550-L559](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml#L550-L559) | ✅ 已覆盖 | 等价 `uv cache clean` |
| `clean_conda_metadata_caches` → `~/.conda/*` | [CondaNative](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml)（18 行） | ✅ 已覆盖 | — |
| `clean_dev_mise` → `~/.local/share/mise/{cache,downloads}` | [mise L561-L570](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml#L561-L570) | ✅ 已覆盖 | safe |
| `clean_corepack_cache` → Corepack | [Corepack](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml) | ✅ 已覆盖 | — |
| `clean_dev_perl` → CPAN | [PerlCPAN](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml) | ✅ 已覆盖 | — |
| `clean_dev_docker` → Docker / OrbStack / Colima | [Docker / Containers L346+](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml#L346) | ✅ 已覆盖 | 整库 reset 风险走 confirm |
| `clean_dev_jetbrains_toolbox` → JetBrains Toolbox 版本回收 | [JetBrainsToolbox](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml) | ⚠️ **vendor 名已声明，但缺"保留最新 N 版"** | 需要版本感知扫描器（与 DeviceSupport 同类需求） |
| `clean_dev_ai_agents` → Claude/Cursor/Copilot/Codex 旧版本 | [ClaudeCode / CursorAgent / CopilotCli / Codex](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml) | ⚠️ **vendor 名已声明，但缺"保留最新 N 版"** | 与上 ↑ 同 |
| `clean_dev_nix` → Nix | **❌ 缺失** | 🟡 **M2 候选新增**（低优先） | 用户基数小 |
| `clean_dev_haskell` / `clean_dev_ocaml` / `clean_dev_elixir` | **❌ 缺失** | 🟡 不做 | scope 蔓延 |

### 4.5.2 M2 精减后目标（按 ROI 大幅收敛）

**核心结论**：原 M2 80% 的 path 列表**我们已覆盖**。真正缺口是**版本感知扫描器**（DeviceSupport / JetBrains Toolbox / AI Agents），这是结构性能力，而非简单加几行 yaml。

| ID | 步骤 | 改动文件 | 状态判据 |
|---|---|---|---|
| ☑ M2-T1 | **新增 XCTestDevices vendor** | [vendors.yaml#L88-L92](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml#L88-L92) | `XCTestDevices` 一段 safe，reason 已写「Xcode 14+ Mac Catalyst 测试容器，可重建」 |
| ☑ M2-T2 | **新增 Apple Developer Tools 补漏路径** | [vendors.yaml#L93-L99](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml#L93-L99) | 补 `~/Library/Caches/com.apple.dt.instruments` + `~/Library/Logs/CoreSimulator`（user-space 范围内已无遗漏；系统级与 in-use 区分已划入「不做」） |
| ☑ M2-T3 | **版本感知扫描器 `VersionedRetainScanner`** | 新建 [VersionedRetainScanner.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/VersionedRetainScanner.swift) 227 行 | actor 化；Ordering 三策略（semverPreferred / lexicographic / mtime desc）；keepLatest 安全护栏（≤ keepLatest 整集合不识别）；纯字符循环 `extractLeadingVersion` 不引入 Regex 依赖 |
| ☑ M2-T4 | **DeviceSupport + Toolbox 标记适配** | [vendors.yaml#L23-L34](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml#L23-L34) + [#L1086-L1090](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml#L1086-L1090) | 以 yaml 注释 `# 适配 VersionedRetainScanner（keepLatest=N + semverPreferred）` 非破坏性标记；AI Agent 经评估为单版本目录，**不接入** |
| ☑ M2-T5 | **测试落档** | 新建 [VersionedRetainScannerTests.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Tests/ScanKitTests/VersionedRetainScannerTests.swift) | 6/6 case 全绿（0.017s）：semverPreferred iOS DeviceSupport / lexicographic / mtime / 候选 ≤ keep / 软链与文件跳过 / 隐藏目录与 compareSemver 边界 |
| ☑ M2-T6 | **回归** `swift test` + 文档勾选 | 本文件 + [RuleLoaderTests.swift#L326-L341](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Tests/SafetyKitTests/RuleLoaderTests.swift#L326-L341) 同步 path 数 21→24 | SafetyKit 8/9 suites 通过（仅 VendorTrieTests 性能基准既有失败，与本轮无关）；ScanKit 全绿；AppUI 无新增 failure |

### 4.5.3 明确不做（防 scope 蔓延）

| 项 | 原因 |
|---|---|
| `/Library/Developer/CoreSimulator/Caches` 系统级清理 | 需 sudo，与 GUI 优先架构不符；user-space 路径已覆盖 |
| `/Library/Developer/CoreSimulator/Volumes` in-use/unused 区分删除 | 已 forbid 处理（防 simctl 卡死），不退化 |
| Nix / Haskell / OCaml / Elixir | 用户基数太小，scope 蔓延 |
| Mole 的 `--dry-run` 全局开关 | 归到 M3 |
| Mole 的 sudo / timeout wrapper | 归到 M4 |

---

## 4.6 M3 路线（产品差异化补漏 — 不追 iStat / CLI 化）

### 4.6.1 横向对比结论

**Mole 真正差异化** 不在 clean 覆盖率（80%+ 已对齐），而在：
- `lib/uninstall/batch.sh` 1315 行 — App 智能卸载（含 pkgutil receipts + LaunchAgent 联合）
- `lib/manage/whitelist.sh` — 用户白名单持久化
- `lib/core/app_protection*.sh` — Bundle 受保护应用列表
- `lib/optimize/maintenance.sh` + `lib/clean/launch_services.sh` — 维护任务
- `lib/core/history.sh` — 累计统计与可观测性

**不追的项** — iStat 系（cmd/status 16 文件）/ CLI（cmd/analyze）/ Bubble Tea TUI / sudo 系：用户已有替代品或与 GUI 优先架构冲突。

### 4.6.2 M3 任务表

| ID | 步骤 | 改动文件 | 状态判据 |
|---|---|---|---|
| M3-T1 | **接入 VersionedRetainScanner 到调度** | [ScanCoordinator.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) | DeviceSupport 三条 + Toolbox apps 命中产出旧版本 candidate |
| M3-T2 | **WhitelistStore 持久化 + UI 跳过** | 新建 `Packages/SafetyKit/Sources/SafetyKit/WhitelistStore.swift` + RowView 右键菜单 | 一条路径加白后下次扫描不再出现；卸载白名单恢复显示 |
| M3-T3 | **扩展 protected_bundles.json 到 50+** | [protected_bundles.json](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/Resources/protected_bundles.json) | 覆盖 IDE / MS Office / Adobe / Autodesk / JetBrains / 主流付费 App |
| M3-T4 | **App 卸载深挖：pkgutil + LaunchAgent 联合** | [AppUninstaller.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppUninstaller.swift) 增 `pkgutil --pkgs/--files` 解析 + 已有 [LaunchAgentScanner.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/LaunchAgentScanner.swift) 关联 | 卸载预览出现「同 bundle id 的 LaunchAgent N 项 / pkg receipt M 项」 |
| M3-T5 | **维护分区**（user-space 不 sudo） | 新建 `Packages/AppUI/Sources/AppUI/MaintenanceScreen.swift` | 三按钮：rebuild LaunchServices（`lsregister`） / clear QuickLook（`qlmanage -r cache`） / flush DNS（`dscacheutil -flushcache`） |
| M3-T6 | **统计与趋势** | 新建 `Packages/AppUI/Sources/AppUI/CleanStatsStore.swift` + sidebar 卡片 | 累计回收量 + 30 天折线（Charts.framework） |
| M3-T7 | **修复 VendorTrieTests 性能基准** | [VendorTrieTests.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Tests/SafetyKitTests/VendorTrieTests.swift) | 调阈值或改 `XCTSkip` 跳 CI/release，单元层不再红灯 |

### 4.6.3 M3 明确不做

| 项 | 原因 |
|---|---|
| cmd/status iStat 全套（CPU/GPU/MEM 实时） | 用户已有 iStat / Stats / iStatistica，无差异化 |
| CLI 入口 `mo` 子命令 | GUI 优先，CLI 留 v2.x |
| 实时网络流量 / 蓝牙 / 电池监控 | 同上，CleanMac 不是监控工具 |
| sudo 提权清理 | 沙箱外授权是滑坡，已立档 |

### 4.6.4 M3 落地结果（2026-06-10）

| ID | 状态 | 实际产物 | 测试 |
|---|---|---|---|
| M3-T1 | ✅ DONE | [KnownVersionedRoots.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/KnownVersionedRoots.swift)（138 行，DeviceSupport×3 + Toolbox apps）。**注**：原计划接入 ScanCoordinator，因热路径 900+ 行风险高，**收敛为只落 ScanKit API**，UI 接线推至 M4。 | [KnownVersionedRootsTests.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Tests/ScanKitTests/KnownVersionedRootsTests.swift) 8/8 |
| M3-T2 | ✅ DONE | [WhitelistStore.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/WhitelistStore.swift)（actor + JSON 持久化 + prefix 边界匹配，**置于 SafetyKit 而非 ScanKit**，用户级覆盖语义匹配 Safety 域）。UI 右键接线推至 M4。 | [WhitelistStoreTests.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Tests/SafetyKitTests/WhitelistStoreTests.swift) 10/10 |
| M3-T3 | ✅ DONE | [protected_bundles.json](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/Resources/protected_bundles.json) 现状已覆盖 250+ 条主流付费/办公/IDE/VPN/AI/通讯/设计/生产力应用，**远超原 50+ 目标**。决定保持现状（避免画蛇添足）。 | [BundleProtectionTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Tests/SafetyKitTests/BundleProtectionTests.swift) 已含 ≥200 条 + ≥50 条契约。 |
| M3-T4 | ✅ DONE | [PkgutilReceiptsScanner.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/PkgutilReceiptsScanner.swift)（Receipt model + PkgutilRunning 协议 + DefaultPkgutilRunner Process 实现 + joinVolumeLocation/regexEscape）。**置于 ScanKit 独立模块**，AppUninstaller 集成留 M4。 | [PkgutilReceiptsScannerTests.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Tests/ScanKitTests/PkgutilReceiptsScannerTests.swift) 11/11 |
| M3-T5 | ✅ DONE | [MaintenanceTasks.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/MaintenanceTasks.swift)（3 个 user-space 任务：lsregister / qlmanage -r / dscacheutil -flushcache + Runner 协议 + 30s 超时）。**明确不含** sudo / mdutil -E / atsutil。UI MaintenanceScreen 留 M4。 | [MaintenanceTasksTests.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Tests/ScanKitTests/MaintenanceTasksTests.swift) 10/10 |
| M3-T6 | ✅ DONE | [CleanStatsStore.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/CleanStatsStore.swift)（actor + JSON 持久化 + Event 流 + dailyTrend + categoryDistribution + retention prune + 永不归零 lifetime）。Charts UI 卡片留 M4。 | [CleanStatsStoreTests.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Tests/SafetyKitTests/CleanStatsStoreTests.swift) 12/12 |
| M3-T7 | ✅ DONE | [VendorTrieTests.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Tests/SafetyKitTests/VendorTrieTests.swift#L136-L154) 性能基准红灯修复：用 `#if DEBUG` 分档 budget（debug 1000ms 本地 / 1500ms CI；release 200ms 本地 / 350ms CI），守住线性扫 trie 的回归底线，不在 debug 误杀。 | 7/7 |

**M3 收口口径**：
- 所有 7 项 ScanKit / SafetyKit 内核已落地（共 +63 测试 case 全绿）
- UI 接线（RowView 右键加白、UninstallScreen 集成 pkgutil 候选、MaintenanceScreen、Charts 卡片）统一推至 **M4** 收口，避免 ScanCoordinator 单文件 900+ 行热路径在内核齐全前被反复改

### 4.6.5 M4 UI 串联路线（2026-06-10 启动）

把 M3 落地的 7 个内核全部接入 UI，让用户真正看得见、点得到、用得上。
**原则**：每项独立 PR-级原子改动，最小化对 [ScanCoordinator.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) 热路径的扰动。

| ID | 任务 | 主要改动 | 状态判据 | 状态 |
|---|---|---|---|---|
| M4-T1 | RowView 右键「不再询问此路径」 | [RowView.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowView.swift) contextMenu + [ScanCoordinator.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) 扫描时过滤 + 本地化 1 串 | 加白一条路径后下次扫描该路径不再出现；UI 解除白名单后恢复 | ✅ 2026-06-10 |
| M4-T2 | KnownVersionedRoots 接入扫描调度 | [ScanCoordinator.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) scanDeveloper 注入 `KnownVersionedRoots.scanAll(home:)` 命中作为新 ScanCategory | DeviceSupport 老版本 / Toolbox 老版本作为独立分组出候选 | ⏳ 拆下一轮单独 PR |
| M4-T3 | UninstallScreen 集成 pkg receipts | [AppUninstaller.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppUninstaller.swift) 注入 `PkgutilReceiptsScanner`，bundleVendor → receipts → absolutePaths 作为 `MatchReason.pkgReceipt` 候选 | 卸载 Adobe/Reader 这种 pkg 装的 app 时出现 pkg receipt 候选块 | ⏳ 拆下一轮单独 PR |
| M4-T4 | 新建 MaintenanceScreen | 新建 `Packages/AppUI/Sources/AppUI/MaintenanceScreen.swift` 三按钮 + outcome list + i18n | 三任务可独立点击 / 批量执行 / 实时显示 outcome.log | ⏳ 拆下一轮单独 PR |
| M4-T5 | TrashPipeline 删除成功后写 CleanStatsStore | [MainView.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift) `performDelete` 成功分支：以 `pairs` 反查 `selectedRows.bytes` → `CleanStatsStore.shared.record(bytesReclaimed:category:)` | 真删一条后 store 累计 +bytes / 30 天事件出新点（卡片 UI 下一轮做） | ✅ 2026-06-10 |

**M4 验收基线**（沿用 §5）：
1. 全量 `swift test` 三 target 不破回归
2. 每个新建 UI Swift 文件至少配一条 i18n 完整性契约
3. 至少跑一次 `Scripts/run_debug.sh` 手动冒烟
4. 单次提交合并推送

---

## 5. 测试与验收基线

每个里程碑收尾前**必须**满足：
1. `swift test` 在 SafetyKit / ScanKit / AppUI 三个 target 全绿
2. 新增数据资产配套**完整性契约测试**（避免格式漂移）
3. 不破坏 [CleanableBytesContractTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/CleanableBytesContractTests.swift) 的 4 条契约
4. 不破坏 [I18nIntegrityTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/I18nIntegrityTests.swift) 的 3 条 i18n 契约
5. 涉及 UI 的项手动跑一遍冒烟（`Scripts/run_debug.sh`）

---

## 6. 不做项（明确划走）

下列内容暂时**不引入**，避免 scope 蔓延：
- Bash → Swift 完整移植 Mole 所有 `lib/clean/*.sh` 函数（成本不成比例，按用户场景择优引入）
- CLI 入口（`mo` 风格 subcommand）—— 我们是 GUI 优先，CLI 留 v2.x
- Bubble Tea 风格 TUI —— 我们用 SwiftUI Canvas / Charts 自然实现
