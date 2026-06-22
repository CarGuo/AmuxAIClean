# 开发者一键清理规划（v1.7 主线）

> 制定日期：2026-06-15
> 上游决策：[REVIEW_2026_06.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/REVIEW_2026_06.md) §2 / §5
> 协同文档：[MOLE_ALIGNMENT.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/MOLE_ALIGNMENT.md) §1.2 / §1.6
> 目标：把"开发者向"从分散的 vendors.yaml 行散点，整合为**侧边一级入口 + 子卡片工作流**，让 iOS / Android / Flutter / Web / JVM 开发者一键看到自己能释放多少 G。

---

## 0. 设计原则（先确定再写代码）

1. **整合不重写**：底层 Scanner / SafetyEngine / KnownVersionedRoots 已具备能力，本规划主要做"workflow 工厂 + UI 一级入口"，避免重复造路径匹配。
2. **永不 sudo / 永不 unlink**：所有删除走 [TrashPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift)。
3. **守护进程感知**：清理 Docker / OrbStack / Simulator 类目录前**必须** probe 后台进程，活跃则只展示不勾选并给提示。
4. **保留至少一版**：`KnownVersionedRoots` 模式 `keepLatest=N`（默认 2）适用于所有"老版本"场景，不做"全删"按钮。
5. **二级 verdict**：用户即使开了 safe 默认勾选，对 CoreSimulator Devices / SimRuntime / Xcode.app 这类必须强制 `confirm`。
6. **CLI 优先验证**：能用 `xcrun simctl delete` / `xcode-select -p` / `pkgutil --pkgs` 的优先走 CLI，避免裸 `rm` 损坏 device_set.plist 这类元数据。

---

## 1. 侧边栏信息架构（新）

### 1.1 当前
```
[推荐扫描]    [自定义路径]    [大文件]    [整盘]    [开发者构建产物]
```

### 1.2 v1.7 后
```
[推荐扫描]
[大文件]
[整盘]
─────── 开发者 ───────
  iOS / Apple                  ← 新增（本规划 §2）
  Android / Flutter            ← 新增（本规划 §3）
  Web / Node                   ← 新增（本规划 §4）
  JVM / Rust / Go / Python     ← 新增（本规划 §5）
  IDE 老版本                   ← 新增（本规划 §6）
  Docker / VM                  ← 新增（本规划 §7）
  容器化 AI Agent              ← 复用已有 vendor，独立卡片
[自定义路径]
[卸载残留]
[启动项]
[重复文件]
```

每个"开发者子项"是一个 **DeveloperWorkflow**，由若干 sub-card 组成。

---

## 2. iOS / Apple 一键清理工作流（M1，本规划核心）

### 2.1 UI 卡片清单（点开"iOS / Apple"出现）

| Card | 数据源 | 默认 verdict | 备注 |
|---|---|---|---|
| **DerivedData** | `~/Library/Developer/Xcode/DerivedData` | safe（全清） | 已有 |
| **Xcode Archives**（按日期保留最近 N） | `~/Library/Developer/Xcode/Archives/YYYY-MM-DD` | confirm，老于 90d 默认勾 | 新增 ArchivesRetentionScanner |
| **iOS DeviceSupport 旧版本** | KnownVersionedRoots[0]，keepLatest=2 | safe | UI 露出"将保留：17.5, 18.1" |
| **watchOS DeviceSupport 旧版本** | KnownVersionedRoots[1] | safe | 同上 |
| **macOS DeviceSupport 旧版本** | KnownVersionedRoots[2] | safe | 同上 |
| **CoreSimulator Caches** | `~/Library/Developer/CoreSimulator/Caches` | safe | 已有 |
| **CoreSimulator Volumes** | `~/Library/Developer/CoreSimulator/Volumes` | safe | 已有 |
| **模拟器实例（按 runtime 分组）** | `xcrun simctl list devices -j` | confirm | **新增 SimctlDevicesScanner**，按 runtime version 分组，每条带 (name, udid, state, bytes)；删除走 `xcrun simctl delete <udid>` 而非裸 rm |
| **过期/未使用模拟器 runtime** | `xcrun simctl runtime list -j` | confirm | **新增 SimctlRuntimeScanner**；保留当前 Xcode 默认 + 最新一版 |
| **多 Xcode.app** | `/Applications/Xcode*.app` + `mdfind kMDItemCFBundleIdentifier=com.apple.dt.Xcode` | confirm | **不主动建议删 Xcode**，仅列出 (版本, 大小, lastUsed, 是否 xcode-select 当前)。点删除等同 NSWorkspace.recycle(Xcode.app) |
| **Xcode Toolchains 旧版** | `~/Library/Developer/Toolchains/*.xctoolchain` | confirm | 新增小 scanner |
| **CocoaPods 全局** | `~/.cocoapods/repos` | safe | 新增一级入口；底层规则已在 vendors.yaml 内 |
| **SwiftPM 全局缓存** | `~/Library/Caches/org.swift.swiftpm`、`~/.swiftpm/cache` | safe | 同上 |
| **Carthage 全局缓存** | `~/Library/Caches/org.carthage.CarthageKit` | safe | 同上 |
| **Provisioning Profiles 过期** | `~/Library/MobileDevice/Provisioning Profiles/*.mobileprovision` | confirm | **新增 ProvisioningProfileScanner**：解析 plist 内 `ExpirationDate`，过期或同 UUID 多份保留最新 |
| **Instruments 旧 .trace** | `~/Library/Developer/Xcode/UserData/Instruments` | confirm，按 mtime > 30d | 复用 [MtimeFilter](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/MtimeFilterTests.swift) 能力 |

### 2.2 新增模块

| 文件 | 责任 |
|---|---|
| `Packages/ScanKit/Sources/ScanKit/SimctlDevicesScanner.swift` | 调 `xcrun simctl list devices -j`，解析为分组结果，含每个 device 的字节占用（统计该 `~/Library/Developer/CoreSimulator/Devices/<UDID>/`） |
| `Packages/ScanKit/Sources/ScanKit/SimctlRuntimeScanner.swift` | 调 `xcrun simctl runtime list -j` |
| `Packages/ScanKit/Sources/ScanKit/ProvisioningProfileScanner.swift` | 解析 .mobileprovision，按 ExpirationDate 与 UUID dedup |
| `Packages/ScanKit/Sources/ScanKit/ArchivesRetentionScanner.swift` | 按子目录日期保留最新 N，复用 [VersionedRetainScanner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/VersionedRetainScanner.swift) 的 Ordering 扩展，加入 `.dateDescending` |
| `Packages/AppUI/Sources/AppUI/Developer/AppleDeveloperScreen.swift` | 上述卡片的 SwiftUI 组合 |
| `Packages/AppUI/Sources/AppUI/Developer/DeveloperWorkflow.swift` | DeveloperWorkflow 协议 + 注册表 |

### 2.3 删除路径的特殊处理

| 场景 | 处理 |
|---|---|
| `~/Library/Developer/CoreSimulator/Devices/<UDID>` | **必须**走 `xcrun simctl delete <UDID>`；裸删会污染 `device_set.plist`，下次 Simulator 启动崩。已在 [vendors.yaml L70](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml#L70-L70) `recipe` 字段标注。 |
| `~/Library/Developer/CoreSimulator/Profiles/Runtimes/*.simruntime` | 走 `xcrun simctl runtime delete <id>` |
| `/Applications/Xcode*.app` | `NSWorkspace.recycle`；若是当前 `xcode-select -p` 指向，必须红字警告且默认不勾 |
| `.mobileprovision` | 移废纸篓即可，Xcode 重启自动重建 |

### 2.4 安全门

- 所有"调子进程"的扫描结果只参与本次实时展示，不写入持久缓存（输出可能因系统状态变化），避免假数据。
- 检测到 Simulator.app / Xcode.app 正在运行（`NSWorkspace.shared.runningApplications`）时，**整组**改为只读，不可勾选删除。

### 2.5 测试

| 测试 | 验证点 |
|---|---|
| `SimctlDevicesScannerTests` | JSON fixture（含 0 设备 / 单 runtime / 多 runtime / unavailable runtime） |
| `ProvisioningProfileScannerTests` | 过期识别、同 UUID dedup、解析失败兜底 |
| `ArchivesRetentionScannerTests` | 按 mtime 保留最近 N |
| `XcodeBundleNotRunningTests` | mock RunningApplications，校验勾选被禁用 |
| 集成测试：`AppleDeveloperWorkflowGoldenTests` | 与 [V12SafetyIntegrationTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/V12SafetyIntegrationTests.swift) 同档次，确保 forbid 路径绝不出现 |

---

## 3. Android / Flutter（M2）

### 3.1 子卡片
| Card | 路径 | verdict | 新增工作量 |
|---|---|---|---|
| Flutter `~/.pub-cache` | `~/.pub-cache` | confirm | 加 vendor 规则 + 一级入口 |
| Android SDK build-tools 旧版本 | `~/Library/Android/sdk/build-tools` | confirm，keepLatest=2 | 加入 [KnownVersionedRoots](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/KnownVersionedRoots.swift) |
| Android SDK system-images 旧版本 | `~/Library/Android/sdk/system-images/android-XX` | confirm，keepLatest=2 | 同上 |
| Android SDK platforms 旧版本 | `~/Library/Android/sdk/platforms/android-XX` | confirm，keepLatest=2 | 同上 |
| Android AVD 实例 | `~/.android/avd/*.avd` | confirm | 新增 AVDListScanner（读 `*.ini` 拿 `target`/`abi`） |
| Android Gradle 全局 | `~/.gradle/caches`、`~/.gradle/daemon` | safe（caches）/ confirm（daemon） | 加入 vendors.yaml + 一级入口 |
| Ohpm（鸿蒙） | `~/.ohpm` | safe | vendors.yaml 新增条目 |

### 3.2 风险
- 删 system-images 后，**对应 AVD 启动失败**——必须在 UI 显示"会影响以下 AVD：…"反向依赖告警。

---

## 4. Web / Node（M1 并行）

| Card | 路径 | verdict |
|---|---|---|
| **pnpm 全局 store** | `~/.pnpm-store`、`~/Library/pnpm/store` | safe |
| **npm 全局缓存** | `~/.npm/_cacache` | safe |
| **yarn classic 全局缓存** | `~/Library/Caches/Yarn`、`~/.yarn/cache` | safe |
| **yarn berry 全局缓存** | `~/.yarn/berry/cache` | safe |
| **Bun 全局缓存** | `~/.bun/install/cache` | safe |
| **Turbo 全局缓存** | `~/.cache/turbo` | safe |
| **Electron prebuilt** | `~/Library/Caches/electron`、`~/.electron`、`~/.electron-gyp` | safe |
| **playwright 浏览器** | `~/Library/Caches/ms-playwright` | confirm |
| **Cypress 缓存** | `~/Library/Caches/Cypress` | safe |

实现：纯 vendors.yaml 追加 + 一级 UI 卡片，无需新 scanner。

---

## 5. JVM / Rust / Go / Python（M2/M3）

| Card | 路径 | verdict |
|---|---|---|
| Gradle 全局 | `~/.gradle/caches` | safe |
| Maven 仓库 | `~/.m2/repository` | confirm（重新下载非常慢） |
| sbt | `~/.sbt` | confirm |
| Ivy2 | `~/.ivy2` | safe |
| Cargo registry | `~/.cargo/registry/{cache,index,src}` | safe |
| Go build cache | `~/Library/Caches/go-build` | safe |
| Go mod cache | `~/go/pkg/mod` | confirm |
| pip cache | `~/Library/Caches/pip` | safe |
| poetry cache | `~/Library/Caches/pypoetry` | safe |
| uv cache | `~/Library/Caches/uv` | safe |
| conda envs | `~/miniconda3/envs/*`、`~/anaconda3/envs/*` | confirm（按 env 单独勾选） |

---

## 6. IDE 老版本（M2）

### 6.1 JetBrains 升级残留
- 现象：升级 IntelliJ 2024.1 → 2024.3 后，老版本目录残留：
  - `~/Library/Application Support/JetBrains/IntelliJIdea2024.1`
  - `~/Library/Caches/JetBrains/IntelliJIdea2024.1`
  - `~/Library/Logs/JetBrains/IntelliJIdea2024.1`
- 新增 [KnownVersionedRoots](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/KnownVersionedRoots.swift) entries：每个 IDE 三个目录（AppSupport/Caches/Logs），ordering `.semverPreferred`，keepLatest=1。
- UI：合并展示"IntelliJ 2024.1（残留，1.2 GB）"为一个卡片。

### 6.2 Toolbox apps 已有 → 一级入口
- 现已纳入 [KnownVersionedRoots L70-L74](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/KnownVersionedRoots.swift#L70-L74)，但 UI 在"老版本残留"二级菜单。
- v1.7：抽出独立 IDE 卡片。

### 6.3 VS Code / Cursor 老版本
- VSCode/Cursor 自身就一个版本目录，无残留概念，跳过。
- 但 **VSCode 插件全局缓存** `~/.vscode/extensions` / `~/.cursor/extensions` 可加入"插件缓存"子项（confirm，按 mtime > 180d）。

---

## 7. Docker / VM（M3）

| 平台 | 大目录 | verdict | 守护进程检测 |
|---|---|---|---|
| Docker Desktop | `~/Library/Containers/com.docker.docker/Data/vms` | confirm | `pgrep -f "Docker Desktop"` |
| OrbStack | `~/.orbstack/data` | confirm | `pgrep -f "OrbStack"` |
| Colima | `~/.colima/_lima/<profile>` | confirm | `colima status` |
| Lima | `~/.lima/<vm>` | confirm | `limactl list` |
| Podman | `~/.local/share/containers/storage` | confirm | `pgrep podman` |

**安全门**：检测到 daemon 在跑时，**禁止勾选**整组，UI 红字"请先停止 Docker Desktop"。

---

## 8. 数据模型与基础设施

### 8.1 DeveloperWorkflow 协议

```swift
public protocol DeveloperWorkflow: Sendable {
    var id: String { get }
    var displayName: String { get }
    var ecosystem: DevArtifactRule.Ecosystem { get }
    func makeCards(home: URL) async -> [DeveloperCard]
}

public struct DeveloperCard: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let bytes: Int64
    public let verdict: SafetyVerdict
    public let entries: [DevCardEntry]   // 删除候选
    public let runtimeGate: RuntimeGate? // 守护进程检测
    public let deletionRecipe: DeletionRecipe // 默认 .recycleViaWorkspace，特殊用 .commandLine
}

public enum DeletionRecipe: Sendable {
    case recycleViaWorkspace
    case commandLine(tool: String, args: [String])  // e.g. xcrun simctl delete
}
```

### 8.2 注册表
新建 `Packages/AppUI/Sources/AppUI/Developer/DeveloperWorkflowRegistry.swift`：

```swift
public enum DeveloperWorkflowRegistry {
    public static let all: [any DeveloperWorkflow] = [
        AppleWorkflow(),
        AndroidFlutterWorkflow(),
        WebNodeWorkflow(),
        JVMRustGoPythonWorkflow(),
        IDEOldVersionWorkflow(),
        DockerVMWorkflow(),
    ]
}
```

### 8.3 UI
- 复用 [TreeBrowserStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserStore.swift) 增量 patch 能力，每个 card 内的 entries 平铺，外层是分组 disclosure。
- 顶部"一键全选 safe 项" 按钮；分组级"全选" / "全清"。

---

## 9. 里程碑

| 里程碑 | 包含 | ETA |
|---|---|---|
| **M1 (1.5w)** | iOS Apple Workflow（§2）+ Web/Node 全局缓存（§4） | 2026-07-08 |
| **M2 (1w)** | Android/Flutter（§3）+ IDE 老版本（§6） | 2026-07-15 |
| **M3 (1w)** | JVM/Rust/Go/Python（§5）+ Docker/VM（§7） | 2026-07-22 |
| **M4 (0.5w)** | 端到端集成测试 + 文档 + 截图回归 | 2026-07-26 |

---

## 10. 验收清单（PR 合并前必过）

- [ ] 所有新 scanner 单测覆盖 fixture 0/1/N 三档
- [ ] `xcrun simctl` / `xcode-select` 子进程调用全部走 [HeavyTask](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HeavyTask.swift)，禁止主线程阻塞
- [ ] 所有 commandLine 删除都有 dryRun 模式
- [ ] V12SafetyIntegrationTests 扩展：DeveloperWorkflow 任何卡片不能输出 forbid 路径
- [ ] 守护进程检测的所有路径有 UI 提示文案 i18n（中/英）
- [ ] AUDIT_2026_06 / FEATURE_GAP / ROADMAP_V1 / README 路线图章节同步更新

---

## 11. 与已有规划的对齐

| 已有 | 关系 |
|---|---|
| [MOLE_ALIGNMENT.md §1 #2 Xcode 全家桶](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/MOLE_ALIGNMENT.md) | 本规划 §2 是其超集（加了模拟器实例分组管理、多 Xcode 版本、Provisioning 过期） |
| [MOLE_ALIGNMENT.md §1 #3 Go/Rust/Python](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/MOLE_ALIGNMENT.md) | 本规划 §5 |
| [MOLE_ALIGNMENT.md §1 #5 Docker/OrbStack](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/MOLE_ALIGNMENT.md) | 本规划 §7 |
| [MOLE_ALIGNMENT.md §1 #6 JetBrains Toolbox](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/MOLE_ALIGNMENT.md) | 本规划 §6.2 |
| [KnownVersionedRoots](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/KnownVersionedRoots.swift) | 仅扩 entries，不改协议 |
| [vendors.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml) | 本规划新增条目 ≈ 25-30 行，全部走 PR + RuleLoader 校验 |
