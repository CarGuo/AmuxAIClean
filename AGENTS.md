# AGENTS.md — GSYCleanMac

> 本文件只保留全仓库通用、长期有效且会影响安全或交付的指令。实现细节、事故复盘、
> 测试矩阵和发布步骤由末尾文档负责；开始对应任务前必须打开相应文档。

## 1. 项目与目录

- macOS 13.5+ 原生 SwiftUI 应用，Swift 6 strict concurrency，使用已入仓的原生
  [GSYCleanMac.xcodeproj](file:///Users/guoshuyu/workspace/GSYCleanMac/GSYCleanMac.xcodeproj)，禁止用 xcodegen 重建。
  <!-- v2026.07.16：产品部署下限降至 Ventura 13.5；macOS 15+ 仍是开发工具链门槛，不是用户安装门槛。 -->
- Developer ID 分发，非 MAS。构建本地 Release/DMG 不等于上传 GitHub。
- 文件清理仅限 `$HOME` 下用户态路径，最终操作是 `NSWorkspace.recycle` 移到废纸篓。
- 用户可见语言为 `zh-Hans` 与 `en`；不得新增或扩大网络请求，待决边界见
  [SECURITY.md](file:///Users/guoshuyu/workspace/GSYCleanMac/SECURITY.md)。

| 路径 | 职责 |
|---|---|
| `App/` | `@main` 入口、Info.plist |
| `Packages/AppUI/` | SwiftUI/AppKit 界面、扫描协调、删除交互 |
| `Packages/ScanKit/` | 文件扫描、容量统计、完整性证据 |
| `Packages/SafetyKit/` | 安全判定、hard-forbid、规则加载 |
| `Packages/{AIKit,BrewKit,FileSearchKit,HeuristicKit,LogKit,TestHarness}/` | 支撑能力与测试基础设施 |
| `Resources/Rules/` | vendor、安全前缀等运行规则 |
| `Scripts/` | Debug、性能、Release 脚本 |
| `docs/` | 开发、发布、产品合同与质量台账 |

关键入口：

- 删除：[TrashPipeline.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift)
- 安全：[SafetyEngine.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift)
- 扫描协调：[ScanCoordinator.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
- 多语言：[Localizable.xcstrings](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/Resources/Localizable.xcstrings)

## 2. 关键命令

```bash
# 单包测试示例
(cd Packages/AppUI && swift test)
(cd Packages/ScanKit && swift test --build-system native)

# 提交前的全包测试（ScanKit 在 Xcode 16+ 下需 --build-system native）
for pkg in ScanKit SafetyKit AppUI HeuristicKit LogKit BrewKit FileSearchKit AIKit TestHarness; do
  if [ "$pkg" = "ScanKit" ]; then
    (cd "Packages/$pkg" && swift test --parallel --build-system native) || exit 1
  else
    (cd "Packages/$pkg" && swift test --parallel) || exit 1
  fi
done

# 只构建，不启动 App
xcodebuild -project GSYCleanMac.xcodeproj -scheme GSYCleanMac -configuration Debug build

# 性能基准
./Scripts/bench.sh ~/Library/Caches
```

- 禁止直接运行 `xcodebuild test`；包测试统一走 `swift test`。
- `run_debug.sh` 等任何会启动 App 的命令，只有在写明场景、入口、观察点和数据边界并获得用户明确同意后才能运行。
- v2026.07.16 起禁止用“启动 App、只看窗口/进程后立即退出”的快速启停壳充当 UI 回归；
  也不得按 case 反复拉起 App。逻辑自动化放在 package tests，C4 必须是一次持续运行、
  明确业务操作与可观察结果的验收。
- Release、公证和 DMG 命令只从
  [docs/RELEASE.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/RELEASE.md) 读取，禁止在此复制版本化步骤。

## 3. 核心红线

### 代码与界面

- Swift 6 并发问题必须通过 actor/隔离修正；禁止用无说明的 `@unchecked Sendable`。业务错误不得用 `try?` 静默吞掉；明确的 best-effort cleanup 必须写明原因。
- UI 和必须主线程的 API 之外，扫描、排序、规则计算和文件遍历必须后台执行。扫描期禁止在主线程重建大列表、重算 verdict 或 materialize partial tree。
- 禁止用局部硬编码或兜底掩盖共享根因；修复应落在共同数据边界/状态合同，并有防回归测试。
- 所有用户可见文案先进入 String Catalog，并同时提供 `zh-Hans`、`en`；禁止局部硬编码。
- 用户可见错误必须经过类型化 presentation 和本地化；raw Error、Swift enum、`file:///`、percent encoding、errno 只能进入结构化日志或技术详情。
- 用户可见异步流程必须收敛到明确终态并绑定发起 revision，旧任务不得覆盖新页面。

### 扫描、删除与安全

- 删除候选只能走 `TrashPipeline → NSWorkspace.recycle`；禁止 `unlink(2)` 和 `FileManager.removeItem(at:)`。
- 执行层默认 dry-run；Release UI 不显示 dry-run 开关。真删授权只能由统一确认状态机生成，View 不得自行决定 force。
- 所有删除入口遵守
  [DELETION_UX_CONTRACT.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/DELETION_UX_CONTRACT.md)。专业覆盖必须类型化、严格确认并在执行前重验；hard-forbid、系统卷、HOME/Library 整根、越界和路径穿越永不可覆盖。
- `incomplete`、TCC、POSIX ownership/mode 和真实删除权限必须保持类型化来源，不得合成一个通用 `accessDenied`。
- `ScanEvent.failed` 只用于整轮/扫描根没有可信终态；后代问题使用 scoped incomplete。Tree 的节点访问状态与子树完整性不得合并，具体合同见
  [PITFALLS.md](file:///Users/guoshuyu/workspace/GSYCleanMac/PITFALLS.md)。
- 真删测试只能操作 `NSTemporaryDirectory()` 内预先创建的 fixture，禁止用真实 `$HOME` 数据制造证据。
- 不得绕过 `SafetyEngine`；HeuristicKit/AIKit 永不凌驾 `.forbid`。vendor 匹配必须使用严格 Bundle ID 边界，禁止仅用 appName 前缀。

### 修改权限与工作树

- 修改 `.xcodeproj`、`Package.swift`、Info.plist、entitlements、规则库、`hardForbid*`、第三方依赖、CI 或 Release 脚本前，必须先取得用户明确授权。
- `hardForbid*` 列表变更还必须给出真实事故来源；SafetyKit 不得引入外部依赖。
- 未获明确指令，禁止 commit、push、force-push、创建/上传 GitHub Release。
- 禁止提交 secrets、签名证书、p12、API token 或公证凭据。
- 工作树可能含用户修改；先检查状态，只修改任务范围，禁止重置或覆盖无关内容。
- 禁止为过测试削弱断言、删除测试或改变需求。若测试判据错误，先说明合同为何错误，再修改判据。

## 4. 完成门槛

| 改动范围 | 最低验证 |
|---|---|
| 单个包 | 该包 `swift test` |
| 跨 AppUI / ScanKit / SafetyKit 主链路 | 全部 9 包 `swift test` |
| 扫描、删除、Tree 或 UI 交互 | 上述测试 + 目标 Debug 构建；若宣称真实交互正确，另需用户授权的一次持续 C4 |
| Release、签名、Info.plist | `test_release_contract.sh` + Release 构建；最终 DMG 另做 C5 |

- 证据等级使用
  [QUALITY_CLOSURE_LEDGER_2026-07-14.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/QUALITY_CLOSURE_LEDGER_2026-07-14.md) 的 C1–C5：聚焦行为测试是 C2；相关包全测加目标构建才是 C3；二者都不得表述为真实 UI 已测试。
- 禁止把“启动后马上退出”当功能测试。没有 C4 必须明确写“未做运行交互验收”。
- 交付时必须说明：已改内容、实际运行的验证、未验证风险以及还差什么。

## 5. 文档路由

| 任务 | 首选详细入口 |
|---|---|
| 环境、工程、完整目录、开发命令 | [docs/DEVELOPMENT.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/DEVELOPMENT.md) |
| 安全边界、删除闸门、网络决策 | [SECURITY.md](file:///Users/guoshuyu/workspace/GSYCleanMac/SECURITY.md) |
| 扫描/并发/UI/签名事故与技术避坑 | [PITFALLS.md](file:///Users/guoshuyu/workspace/GSYCleanMac/PITFALLS.md) |
| 编码、依赖、PR、Commit 规范 | [CONTRIBUTING.md](file:///Users/guoshuyu/workspace/GSYCleanMac/CONTRIBUTING.md) |
| 本地 Release、签名、公证、DMG | [docs/RELEASE.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/RELEASE.md) |
| 删除状态机、专业覆盖、入口矩阵 | [docs/DELETION_UX_CONTRACT.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/DELETION_UX_CONTRACT.md) |
| 当前问题状态与 C1–C5 证据 | [docs/QUALITY_CLOSURE_LEDGER_2026-07-14.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/QUALITY_CLOSURE_LEDGER_2026-07-14.md) |

维护规则：`AGENTS.md` 只增加全仓库、长期有效、反复违反且可执行的规则。需要事故背景、示例、测试矩阵或实现细节时，更新对应专门文档并在这里保留一行链接；禁止加入固定版本号、固定测试数量和易失效代码行号。
