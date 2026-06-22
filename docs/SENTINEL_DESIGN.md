# GSYCleanMac Sentinel daemon 设计文档

> Step 6 子专题。父文档：[docs/AUDIT_2026_06.md#L302-L319](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/AUDIT_2026_06.md#L302-L319)。
> 决策日期：2026-06-03。
> 状态：v1 spec，已实施 step6_design_spec / step6_daemon_core / step6_target，待做 step6_main_app + step6_verify。

---

## 1. 背景与问题

GSYCleanMac 当前是纯前台 App：用户主动 `⌘O` 才会扫描。两个场景下用户体验不及格：

1. **卸载残留场景**：用户把 `Foo.app` 拖进废纸篓后，`~/Library/Application Support/Foo` 等残留依然在硬盘上。要清掉这些残留，用户必须主动想起来开 GSYCleanMac → 找到 Uninstall 入口 → 输入 Foo → 走一遍。摩擦点 ≥ 4 步，结果是大部分用户根本不会做。
2. **推荐清理场景**：`~/Downloads` 累积一年的 dmg/zip、`~/Library/Caches` 几十 GB、Xcode `DerivedData` 几百 GB —— 这些目录用户**不知道自己有多少**，所以从不主动扫描。

竞品 Pearcleaner 用一个 80 行的 Sentinel daemon（[PearcleanerSentinel/main.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/tmp/competitors/Pearcleaner/PearcleanerSentinel/main.swift)）解决了场景 1。CleanMyMac Smart Care 模块解决了场景 2。GSYCleanMac v1.6 把两者用同一个 daemon 进程合并实现。

---

## 2. 设计原则（克制）

| 原则 | 落地 |
|---|---|
| **不打扰** | 默认 OFF。用户必须显式在「设置 → 高级 → 后台守护」勾选启用 |
| **不上报** | 0 网络请求。所有发现的清理候选只写本地 ringbuffer |
| **不上瘾** | 不做"今日为您节省 X GB"成长式 UI。candidate 出现就是出现了，用户点了就清，不做日报 |
| **不臃肿** | helper 二进制目标 RSS < 5 MB / CPU < 1% / 仅依赖 Foundation + CoreServices（FSEvents 在此 framework） |
| **不破坏** | 主 App 启用/禁用 Sentinel 不影响主 App 的任何现有功能。卸载主 App 时 SMAppService 自动清理 helper |

---

## 3. 架构总览

```
┌──────────────────────────────────────────────────────────────────────┐
│  GSYCleanMac.app                                                      │
│                                                                       │
│  Contents/MacOS/GSYCleanMac          ← 主 App 二进制 (SwiftUI)        │
│  Contents/MacOS/gsycleanmac-sentinel ← Sentinel helper 二进制          │
│  Contents/Library/LaunchDaemons/                                      │
│    com.guoshuyu.cleanmac.sentinel.plist  ← SMAppService 注册的 plist  │
│  Contents/Info.plist                                                  │
│    + CFBundleURLTypes: gsycleanmac://                                 │
└──────────────────────────────────────────────────────────────────────┘
                            ↑                              ↓
                            │ launchctl bootstrap          │ /usr/bin/open -g
                            │ (SMAppService.daemon)        │ (avoid linking AppKit)
                            │                              │
┌──────────────────────────────────────────────────────────────────────┐
│  gsycleanmac-sentinel daemon (常驻后台)                               │
│                                                                       │
│  - FSEventStream 监听 ~/.Trash       (场景 1: 卸载发现)               │
│  - FSEventStream 监听热点目录        (场景 2: 推荐清理)               │
│      ~/Downloads                                                      │
│      ~/Library/Caches                                                 │
│      ~/Library/Developer/Xcode/DerivedData                            │
│      [glob 命中的 node_modules]                                       │
│  - rolling top-100 ringbuffer 写到                                    │
│      ~/Library/Application Support/GSYCleanMac/sentinel-pending.json  │
│  - 检测到事件后 /usr/bin/open -g 唤起主 App URL                        │
│      gsycleanmac://uninstall?path=...    (场景 1)                     │
│      gsycleanmac://action/scan/full       (场景 2)                    │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 4. 关键技术决策（与用户对齐落定）

| 项 | 决策 | 备选未选原因 |
|---|---|---|
| **运行仓运** | SMAppService.daemon (macOS 13+) | LaunchAgent plist 是上一代 API，SMAppService 是 Apple 官方推荐的现代替代，卸载 App 时自动清理 helper |
| **场景** | 卸载 + 推荐双场景 (v1) | 不分两版本是因为 daemon 进程已经起来了，加一组 FSEventStream stream 几乎零成本 |
| **Helper target 形式** | 独立 PBXNativeTarget Command Line Tool + 主 App 加 Embed Helper Tools build phase（Apple 官方 [Embedding a command-line tool in a sandboxed app](https://developer.apple.com/documentation/Xcode/embedding-a-helper-tool-in-a-sandboxed-app) 路径） | SwiftPM executable + Copy Phase 路径在 Apple Developer Forum 2026-02 thread 814686 archive 阶段会撞 "Multiple commands produce .o" 冲突；scheme pre-action 子项目独立 xcodebuild 路径与现有项目风格反 |
| **URL Scheme** | 路由型 `gsycleanmac://uninstall + gsycleanmac://action/scan/full` | scheme 前缀 `gsycleanmac` 与 bundle id `com.guoshuyu.cleanmac` 后缀对齐；`gsyclean` 是原 spec 草案弃用 |
| **发现策略** | 轻手版 FSEvents + rolling top-100 | 重量版定时全屏扫描太贵（30s CPU + IO）；混合版 v1 不上 |
| **默认开关** | 默认 OFF | 避免存量用户升级后 "多了个守护进程" 反感；新用户首启不弹 onboarding 弹窗，把 Sentinel 藏在「设置 → 高级」里 |
| **本地存储** | `~/Library/Application Support/GSYCleanMac/sentinel-pending.json` | ringbuffer top-100；主 App 启动时读取此文件展示「最近被 Sentinel 发现的候选」（场景 2 落地形式） |

---

## 5. 模块切片

### 5.1 Helper target: `GSYCleanMacSentinel`

落地路径（按 Apple 官方文档 [Embedding a command-line tool in a sandboxed app](https://developer.apple.com/documentation/Xcode/embedding-a-helper-tool-in-a-sandboxed-app) 实施）：

- **独立 PBXNativeTarget**，类型 = `com.apple.product-type.tool`（Command Line Tool / macOS）
- 二进制名：`gsycleanmac-sentinel`（`PRODUCT_NAME`，小写连字符与 LaunchDaemon plist label 对齐）
- Bundle ID: `com.guoshuyu.cleanmac.sentinel`（`PRODUCT_BUNDLE_IDENTIFIER`，与 `OTHER_CODE_SIGN_FLAGS = $(inherited) -i $(PRODUCT_BUNDLE_IDENTIFIER)` 联动确保 codesign identifier 一致）
- 入口：[Tools/Sentinel/Sources/Sentinel/main.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Tools/Sentinel/Sources/Sentinel/main.swift) —— top-level code（`main.swift` 文件名 Swift 默认走 top-level，不能再用 `@main`）
- 仅依赖 Foundation + CoreServices（FSEvents 来自 CoreServices）
- Entitlements：[Tools/Sentinel/Sentinel.entitlements](file:///Users/guoshuyu/workspace/GSYCleanMac/Tools/Sentinel/Sentinel.entitlements) —— 极简空 plist + Hardened Runtime ON。**不上 sandbox**（`com.apple.security.app-sandbox = false`）以跨 sandbox 边界监听 `~/.Trash`
- 关键 build settings（按 Apple 文档强制）：
  - `SKIP_INSTALL = YES`（避免 archive 时产生独立 helper 副本）
  - `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`（避免与 `com.apple.security.inherit` 冲突）
  - `OTHER_CODE_SIGN_FLAGS = $(inherited) -i $(PRODUCT_BUNDLE_IDENTIFIER)`
  - `ENABLE_HARDENED_RUNTIME = YES`
  - `DEVELOPMENT_TEAM = 39PK4PKRP3` / `CODE_SIGN_STYLE = Automatic`
- 主 App target 接入：
  - 加 `PBXTargetDependency` → `GSYCleanMacSentinel`，确保 helper build 在前
  - 加 `PBXCopyFilesBuildPhase` 名为 `Embed Helper Tools`，`dstSubfolderSpec = 6`（Executables → `Contents/MacOS/`），引用 helper product 的 PBXBuildFile（`ATTRIBUTES = (CodeSignOnCopy, )` 在 copy 阶段重签）
- 二进制路径（落地）：`GSYCleanMac.app/Contents/MacOS/gsycleanmac-sentinel`
- 实测体积：~248 KB（无 SwiftUI / 无扫描数据库 / 无 AppUI 依赖，arm64 单架构 Debug build）
- LaunchDaemon plist embed `Contents/Library/LaunchDaemons/com.guoshuyu.cleanmac.sentinel.plist`：留待 step6_main_app 阶段，在主 App target 加第二个 `Copy Files Build Phase`（`dstSubfolderSpec = 1` Wrapper + `dstPath = Contents/Library/LaunchDaemons`）

> **历史失真说明**：原 spec v1 草案曾设想"主 App target 里插 Build Phase 生成 helper"或"SwiftPM executableTarget + .pbxproj copy phase embed binary"，落地时发现：（1）Build Phase 生成 helper 路径需要 Run Script 调用 swiftc 自治编译，与"原生 Xcode 路径"原则相违；（2）SwiftPM executable embed 路径在 [Apple Developer Forum thread 814686](https://developer.apple.com/forums/thread/814686)（2026-02）archive 阶段会撞 "Multiple commands produce .o" 冲突。最终回归 Apple 官方 PBXNativeTarget Command Line Tool 路径。

### 5.2 SMAppService 注册流程

主 App 在 [GSYCleanMacApp.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift) 启动时：

```swift
@MainActor
func registerSentinelIfEnabled() {
    guard AppSettings.shared.sentinelEnabled else { return }

    let service = SMAppService.daemon(
        plistName: "com.guoshuyu.cleanmac.sentinel.plist"
    )
    do {
        try service.register()
    } catch {
        Log.warn("[Sentinel] register failed: \(error)")
    }
}
```

`com.guoshuyu.cleanmac.sentinel.plist` 内容（embed 在 `Contents/Library/LaunchDaemons/`）：

```xml
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.guoshuyu.cleanmac.sentinel</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/gsycleanmac-sentinel</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>Nice</key>
    <integer>10</integer>
</dict>
</plist>
```

关闭 Sentinel 时调用 `try service.unregister()`，launchctl 会清掉。

### 5.3 Daemon core 逻辑（伪码）

```swift
// main.swift (~150 行预算)
import Foundation
import CoreServices

let trashPath = NSString("~/.Trash").expandingTildeInPath
let hotspots = [
    "~/Downloads",
    "~/Library/Caches",
    "~/Library/Developer/Xcode/DerivedData",
].map { ($0 as NSString).expandingTildeInPath }

let trashStream = FSEventStreamCreate(
    paths: [trashPath],
    callback: handleTrashEvent,  // 解析 .app 删除 → 写 sentinel-pending.json + open URL
    flags: .fileEvents
)

let hotspotStream = FSEventStreamCreate(
    paths: hotspots,
    callback: handleHotspotEvent,  // ringbuffer 累积，达阈值（如 5 GB 新增）后 open URL
    flags: .fileEvents
)

CFRunLoopRun()
```

事件去抖：每个事件入 `DispatchQueue.main.asyncAfter(deadline: .now() + 30s)` debounce，避免 dmg 解压时 200 个事件刷屏。

### 5.4 Main App URL routing

在 [GSYCleanMacApp.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift) `Scene` 上加：

```swift
.onOpenURL { url in
    switch url.host {
    case "uninstall":
        // 场景 1: gsycleanmac://uninstall?path=/Applications/Foo.app
        if let path = url.queryParameter("path") {
            navigationCoordinator.openUninstall(prefilling: path)
        }
    case "action":
        // 场景 2: gsycleanmac://action/scan/full
        switch url.path {
        case "/scan/full":
            navigationCoordinator.startFullScan()
        default:
            Log.warn("[URLScheme] unknown action: \(url.path)")
        }
    default:
        Log.warn("[URLScheme] unknown host: \(url.host ?? "nil")")
    }
}
```

`Info.plist` 里 `CFBundleURLTypes`：

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLName</key>
        <string>com.guoshuyu.cleanmac.scheme</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>gsycleanmac</string>
        </array>
    </dict>
</array>
```

### 5.5 [AppSettings](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppSettings.swift) 新增字段

```swift
@AppStorage("sentinelEnabled") public var sentinelEnabled: Bool = false
@AppStorage("sentinelLastEnabled") public var sentinelLastEnabled: Date?  // 给「最近被 Sentinel 发现的候选」面板做时间戳
```

设置面板加 `SentinelSettingsView`：
- Toggle 「启用后台守护」（ON → register；OFF → unregister）
- 状态 chip：launchctl list 检查实时状态（绿点 / 灰点）
- 「立即查看候选」按钮 → 读 `sentinel-pending.json` 并打开 `MainView`

---

## 6. 测试矩阵

### 6.1 单元测试（新增）

- [Packages/AppUI/Tests/AppUITests/SentinelURLSchemeTests.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/SentinelURLSchemeTests.swift)
  - `test_uninstall合法url解析为UninstallIntent`：`gsycleanmac://uninstall?path=/Applications/Foo.app` → `UninstallIntent(path: "/Applications/Foo.app")`
  - `test_action合法url解析为ScanIntent`：`gsycleanmac://action/scan/full` → `ScanIntent.fullScan`
  - `test_非法scheme返回nil`：`gsyclean://uninstall?path=...` （前缀不对）→ nil
  - `test_非法host返回nil`：`gsycleanmac://hack?cmd=rm` → nil
  - `test_注入payload被过滤`：`gsycleanmac://uninstall?path=../../etc/passwd` → 校验后 nil

- [Packages/AppUI/Tests/AppUITests/SentinelTrashDetectionTests.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/SentinelTrashDetectionTests.swift)
  - `test_isInTrash用URLRelationship判定`：FixtureFS 在 `~/.Trash/Foo.app` 模拟，断言 isInTrash = true
  - `test_只识别app后缀`：`~/.Trash/foo.txt` 应被忽略
  - `test_去抖30秒内重复事件聚合为一次`

- step6_verify 阶段会在 [Packages/AppUI/Tests/AppUITests/](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests) 下重写 step6_daemon_core 阶段已写过的 14 个 SPM 单测（`TrashListenerTests` / `HotspotBlacklistTests` / `HotspotRingBufferTests` / `URLSchemeDispatcherTests`）。理由：step6_target 落地时为遵循 Apple 官方 PBXNativeTarget Command Line Tool 路径，删掉了 [Tools/Sentinel/Package.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Tools/Sentinel/Package.swift) SPM 子包（避免"同源 main.swift 被两处引用"风险）。这 14 个单测验证的纯逻辑（`isAppBundle` / `isBlacklisted` / RingBuffer 容量 / URL percent-encode）在 step6_verify 重写到 AppUI 测试包并通过 `@testable import` 访问 helper 内部符号 —— 实际执行因 helper 是独立 target，要么把这些纯函数提取到 [Packages/SafetyKit](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit) 共享，要么直接复制到 AppUITests 文件里（无外部依赖、纯 Foundation 函数）。

### 6.2 Regression case（新增）

[Tests/Regression/cases/sentinel-register-unregister.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Tests/Regression/cases/sentinel-register-unregister.swift)：
- 调 `SMAppService.daemon.register()` → 等 100ms → `launchctl list | grep cleanmac.sentinel` 应非空
- 调 `unregister()` → 等 100ms → grep 应空
- 超时 10s

### 6.3 真实场景验证（手动）

1. **卸载场景**：复制 `/Applications/Calculator.app` → `/tmp/Foo.app` → 拖到废纸篓 → 验证主 App 自动唤醒并跳到 UninstallScreen 预填 `/tmp/Foo.app`
2. **推荐场景**：往 `~/Downloads` 拖一个 5 GB 的 dmg → 等 30s（debounce） → 验证菜单栏托盘有红点（数字 1）
3. **资源占用**：`top -pid $(pgrep GSYCleanMacSentinel)` → 验证 RSS < 5 MB / CPU 静默期 < 1%
4. **稳定性**：跑 24h → 检查 `log show --predicate 'subsystem == "com.guoshuyu.cleanmac.sentinel"'` → 不应有 crash 或 EXC_BAD_ACCESS

---

## 7. 实施步骤映射

对应 Todo:

| Todo | 内容 | 输出 | 状态 |
|---|---|---|---|
| step6_design_spec | 写本文档 | [docs/SENTINEL_DESIGN.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/SENTINEL_DESIGN.md) | ✅ commit `9dae711` |
| step6_daemon_core | main.swift FSEvents listener + ringbuffer | [Tools/Sentinel/Sources/Sentinel/main.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Tools/Sentinel/Sources/Sentinel/main.swift) | ✅ commit `2376078`（SPM 子包形态，14 单测全绿；step6_target 阶段 SPM 子包被删，仅留 main.swift） |
| step6_target | Xcode 加 GSYCleanMacSentinel PBXNativeTarget Command Line Tool + Embed Helper Tools build phase + Sentinel.entitlements | .pbxproj diff (~140 行) + [Tools/Sentinel/Sentinel.entitlements](file:///Users/guoshuyu/workspace/GSYCleanMac/Tools/Sentinel/Sentinel.entitlements) | ✅ Step 6.2（本 commit） |
| step6_main_app | SMAppService register + URL routing + AppSettings + 设置面板 + LaunchDaemon plist embed | App/ + Packages/AppUI/ diff | ⏳ 待做 |
| step6_verify | 单测重写到 AppUITests + regression case + 手动 24h 烧测 | logs/ + last-run.json | ⏳ 待做 |

---

## 8. 风险与回滚

| 风险 | 缓解 |
|---|---|
| **SMAppService 在某些 macOS 版本注册失败** | try/catch + 降级到「主 App 进程内 Timer 轮询」非守护态 |
| **FSEventStream 误报（Spotlight / TimeMachine 触发）** | 30s debounce + 黑名单（`.fseventsd` / `.Spotlight-V100`） |
| **TCC 弹窗「允许 GSYCleanMacSentinel 访问 Downloads」干扰用户** | 文档提示用户首次启用 Sentinel 时会有系统弹窗；第二次起 cdhash 稳定后不再弹 |
| **用户卸载主 App 但 helper 还在跑** | SMAppService 自动清理；额外提供 `Scripts/uninstall_sentinel.sh` 兜底 |
| **大量并发 FSEvents 事件冲爆 daemon** | DispatchQueue serial + ring buffer 上限 100 + 内存 watermark > 50 MB 自杀重启 |

---

## 9. 验收标准

- [ ] regression.sh 21/21 全绿（含 sentinel-register-unregister）
- [ ] AppUITests SentinelURLSchemeTests + SentinelTrashDetectionTests 全绿
- [ ] 手动验证场景 1 + 场景 2 各 1 次成功
- [ ] `top` 24h 后 RSS < 5 MB
- [ ] 默认 OFF：升级用户从 v1.5.5 → v1.6.0 不会出现新进程
- [ ] 设置面板「启用后台守护」开关 ON/OFF 正确触发 register/unregister

---

## 10. 不在本期范围

- IPC（XPC / unix socket）—— v1 Daemon 只用 URL Scheme 单向通知主 App
- 智能推荐引擎（基于历史清理习惯学习）—— v2
- 多设备同步候选清单 —— 永不
- App Store 提交 —— 永不（SMAppService.daemon 在 sandboxed App 受限多）
