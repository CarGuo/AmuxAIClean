# 用户全盘自定义扫描 v2 规划

> 制定日期：2026-06-15
> 上游：[REVIEW_2026_06.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/REVIEW_2026_06.md) §3
> 目标：把"用户自定义扫描"从 v1 的"加个路径"升级为"加路径 + 加规则 + 保存 Profile + glob 黑白名单 + 热加载"。
> 协同：保留 vendors.yaml 的"仓库审计权威"地位，用户级规则**叠加不覆盖**，且**永远不能解锁 forbid**。

---

## 0. 设计原则

1. **用户规则永远是叠加层（overlay）**：vendors.yaml 仍是源真理，用户规则只能把 verdict **降级**（`safe → confirm`、不可 `forbid → safe`），不能新增任何 `~/System` 类路径。
2. **PathGlob 已存在**：[PathGlob](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/PathGlob.swift) 直接复用，无需重写。
3. **失败安全（fail-closed）**：自定义规则解析失败 → 整层 overlay 丢弃 + UI 红字提示；绝不让"规则坏掉"误导扫描行为。
4. **可导出可分享**：扫描 Profile JSON 可导出/导入，社区可分享"前端开发者 Profile / iOS 开发者 Profile"。
5. **可观测**：每条 overlay rule 在 RowView 的 reason 字段显式标"来自：用户规则 / vendors.yaml / KnownVersionedRoots"。

---

## 1. 现状回顾（哪些已经有）

| 能力 | 现状 |
|---|---|
| 加自定义路径 | [UserPathStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/UserPathStore.swift) ✓ |
| 整盘扫描 | [ScanCategory.fullDisk](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCategory.swift#L77-L85) ✓ |
| 路径 glob 匹配 | [PathGlob](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/PathGlob.swift) ✓ |
| 路径白名单 | [WhitelistStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/WhitelistStore.swift) ✓ |
| 规则装载 | [RuleLoader](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/RuleLoader.swift) ✓（仅启动时） |
| 用户规则 YAML | ✗ |
| 规则编辑 UI | ✗ |
| 扫描 Profile | ✗ |
| 热加载 | ✗ |
| 计划任务 | △（[SentinelManager](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/SentinelManager.swift) 已有，UI 未公开） |

---

## 2. 目标功能矩阵

| 功能 | 描述 | 目标版本 |
|---|---|---|
| **用户级 custom_rules.yaml** | `~/Library/Application Support/GSYCleanMac/custom_rules.yaml` | v1.8 |
| **规则编辑器 UI** | 仅支持 path / verdict / 兄弟脚手架 / 注释；不允许编辑 vendors.yaml | v1.8 |
| **glob 黑白名单 UI** | exclude:["~/Documents/**/.private_backup/**"] 类排除模式 | v1.8 |
| **扫描 Profile** | 保存一组（categories + custom_paths + exclude_globs + size_threshold + mtime_filter） | v1.8 |
| **Profile 导出/导入** | JSON 文件 | v1.9 |
| **vendors.yaml + custom_rules.yaml 热加载** | 文件监听 → 后台重建 SafetyEngine，UI 红/绿点示意 | v1.9 |
| **计划任务（Sentinel UI）** | 每天/每周后台扫一次推荐项，HUD 通知 | v1.9 |

---

## 3. custom_rules.yaml schema

```yaml
version: 1
source: "user"
updated_at: "2026-07-30T10:00:00Z"

# 用户自定义路径规则；ID 必须以 user. 开头，避免与 vendors.yaml 冲突
rules:
  - id: user.my_workspace_dist
    name: "我的项目 dist"
    paths:
      - "~/MyProjects/**/dist"
    verdict: safe   # 仅允许 safe / confirm；不允许 forbid（forbid 由 SafetyEngine 硬列表负责）
    sibling_markers: ["package.json"]   # 可选
    note: "前端打包产物，重新 npm run build 重建"

# 用户级 exclude（黑名单）；命中 = 整子树跳过
exclude_globs:
  - "~/Documents/**/.private_backup/**"
  - "/Volumes/MyBackupDrive/**"

# 用户级 force_confirm（把某条 vendors.yaml safe 降级为 confirm）
overlay_verdicts:
  - path: "~/Downloads"
    verdict: confirm   # 默认 confirm，用户可以强制 safe？→ 不可，仅可降级
```

### 3.1 安全约束（写入 RuleLoader 校验）
- `verdict` 仅允许 `safe` / `confirm`；含 `forbid` → 整文件拒绝。
- `paths` 不允许以 `/System`、`/Library/Apple`、`/private/var/db`、`/usr`、`/bin`、`/sbin`、`/etc` 开头。
- `paths` 不允许命中 [TCCSkipList](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/TCCSkipList.swift)。
- `overlay_verdicts` 只能降级（safe → confirm），不能升级（confirm → safe）。
- ID 必须以 `user.` 开头；缺前缀 → 拒绝整条。

### 3.2 失败安全
解析失败 → 整 overlay 丢弃，settings 面板红色 banner："规则文件 line 14 解析失败：…"，原始文件不动。

---

## 4. 模块改造

### 4.1 SafetyEngine
新增 `evaluateWithOverlay(...)`：
- 先走原 `evaluateStandardized`
- 若结果是 `safe`，再过 overlay_verdicts 看是否需要降级到 `confirm`
- 再过 exclude_globs（命中 → 整条剔除，不是 forbid，是 hide）

### 4.2 RuleLoader 扩展
- 新增 `loadOverlay(from url: URL) throws -> CustomRuleOverlay`
- 新增 `applyOverlay(_ overlay: CustomRuleOverlay)` 到 SafetyEngine

### 4.3 文件监听
- 用 `DispatchSource.makeFileSystemObjectSource(fileDescriptor:eventMask:.write, queue:.global())`
- 防抖 500ms 后调用 `applyOverlay`
- 出错回退到上一版 overlay，UI 提示

### 4.4 Profile 模型

```swift
public struct ScanProfile: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var categoryIDs: [String]          // ScanCategory.id 引用
    public var customPaths: [String]
    public var excludeGlobs: [String]
    public var minFileSizeMB: Int?
    public var mtimeOlderThanDays: Int?
    public var devArtifactRuleIDs: [String]?  // 允许在 profile 维度关闭某些规则
}

public actor ScanProfileStore {
    public func list() -> [ScanProfile] { ... }
    public func save(_ profile: ScanProfile) { ... }
    public func delete(id: UUID) { ... }
    public func export(id: UUID, to url: URL) throws { ... }
    public func importProfile(from url: URL) throws -> ScanProfile { ... }
}
```

### 4.5 UI

| 视图 | 内容 |
|---|---|
| `Settings → 自定义规则` | 表格列出用户规则，右上角 "+"；编辑/删除/启用切换 |
| `Settings → 排除规则（glob）` | 文本框列表，每行一条 glob，实时校验语法 |
| `Settings → 扫描 Profile` | 列表 + 编辑 + 默认 Profile + 导出/导入 |
| `MainView toolbar` | "Profile：开发者 ▾" 下拉，切换 Profile 立即应用 |
| `MainView 状态条` | 红/绿点：规则文件解析状态 |

### 4.6 测试

| 测试 | 验证 |
|---|---|
| `CustomRuleOverlayLoaderTests` | YAML 合法/非法/缺字段/含 forbid/含 /System 路径 全部拒绝 |
| `OverlayCannotElevateTests` | confirm → safe 升级被拒 |
| `OverlayCannotForbidTests` | forbid 一律拒绝整文件 |
| `OverlayExcludeGlobTests` | exclude_globs 在 BulkScanner 阶段就剪枝 |
| `RuleLoaderHotReloadTests` | 写入文件 → 监听触发 → SafetyEngine snapshot 替换；并发安全 |
| `ScanProfileStoreTests` | CRUD + import/export 往返 |
| `ProfileSwitchKeepsCacheValidTests` | 切换 Profile 不污染 ScanResultStore |

---

## 5. 里程碑

| 里程碑 | 包含 | ETA |
|---|---|---|
| **M1 (1w)** | custom_rules.yaml schema + RuleLoader.loadOverlay + SafetyEngine 接入 + 单测 | 2026-08-05 |
| **M2 (1w)** | UI 编辑器 + glob 黑名单 UI + Profile CRUD + Profile 切换 toolbar | 2026-08-12 |
| **M3 (0.5w)** | 文件监听热加载 + 状态条 + 出错回退 | 2026-08-16 |
| **M4 (0.5w)** | Profile 导出导入 + 内置示例 Profile（开发者 / 多媒体创作者 / 通用） + 文档 | 2026-08-20 |

---

## 6. 内置示例 Profile（M4 交付）

1. **iOS 开发者 Profile**：preset + Apple Workflow 全卡 + 大文件阈值 200MB + 排除 `~/Documents`
2. **前端开发者 Profile**：preset + Web/Node Workflow + node_modules 项目级 + 排除 `~/Sites`
3. **多媒体创作者 Profile**：preset + 大文件 1GB + 排除 `~/Movies`、`~/Pictures`（避免误识别原始素材）
4. **通用 Profile**：保留当前默认行为（=升级前的体验）

---

## 7. 风险与对策

| 风险 | 对策 |
|---|---|
| 用户写错 glob 导致整盘扫不出东西 | 实时语法校验 + Profile 切换 banner 显示"X 条规则生效，Y 条排除规则" |
| 热加载竞态：扫描中规则突变 | RuleLoader 用 immutable snapshot；当前扫描使用旧 snapshot 跑完，新扫描用新 snapshot |
| 用户分享 Profile 含敏感路径 | 导出时把 `/Users/<name>` 强制脱敏为 `~`；导入时 UI 显示完整列表请用户确认 |
| 高级用户期望 forbid 解锁 | 拒绝；issue 模板里给出"通过 WhitelistStore 加单条路径例外"的引导 |

---

## 8. 与已有体系的对齐

| 已有 | 关系 |
|---|---|
| [vendors.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml) | 不动，依旧是源真理 |
| [SafetyEngine](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) | 新增 overlay snapshot 字段，evaluate 末尾叠加 |
| [WhitelistStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/WhitelistStore.swift) | 现行的"绝对放行单条路径"行为不变；overlay 是规则维度，不是单条路径 |
| [UserPathStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/UserPathStore.swift) | 仍是 Profile 之外的快捷加路径入口；Profile 内可引用其全部 |
| [BundleProtection](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/BundleProtection.swift) | 不变，bundle 维度的 system_critical / data_protected 始终高于 overlay |
