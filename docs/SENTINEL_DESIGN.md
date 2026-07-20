# AmuxAIClean Sentinel 用户态 Agent 设计合同

> 首版决策：2026-06-03。按生产实现重建：2026-07-18。
>
> 本文描述当前代码合同，不再把历史 root LaunchDaemon 草案当成现状。旧任务名
> `step6_daemon_core` 仅作为历史标识保留。

## 1. 目标与非目标

Sentinel 是默认关闭的本地发现能力。用户在“设置 → 高级”明确开启后，它监听当前登录
用户的文件系统变化，并通过 `amuxaiclean://` 深链接把意图交给主 App：

1. `~/.Trash` 中出现 `.app` / `.bundle` 后，邀请用户进入应用卸载分析；
2. `~/Downloads`、`~/Library/Caches`、
   `~/Library/Developer/Xcode/DerivedData` 发生变化后，记录本地热点事件；累计的
   `st_size` 提示达到 5 GiB 时，邀请用户重新进行全盘扫描。

它不执行扫描、不判定 Safety verdict、不生成删除授权，也不移动或删除任何候选。它没有
网络请求，不能绕过 TCC，也不是特权删除 Helper。

## 2. 为什么必须是用户 Agent

监听目标都位于登录用户的 Home。`FileManager.default.homeDirectoryForCurrentUser` 只有在
登录用户域执行时才会指向正确账户。旧实现使用 `SMAppService.daemon`，进程进入系统/root
域后 Home 会解析为 `/var/root`，因此监听到的不是产品 UI 所属用户的 Trash、Downloads 和
Application Support。这是身份域错误，不是通过写死用户名或猜测 `/Users/<name>` 可以修复
的问题。

当前实现使用 `SMAppService.agent`：

- 以当前登录用户身份运行；
- 不设置 `UserName`，不要求 root；
- 仍由 ServiceManagement 管理注册、审批和状态；
- Helper 只依赖 Foundation 与 CoreServices。

## 3. App Bundle 布局与三描述符迁移

```text
AmuxAIClean.app/
└── Contents/
    ├── MacOS/
    │   ├── AmuxAIClean
    │   └── amuxaiclean-sentinel
    └── Library/
        ├── LaunchAgents/
        │   └── com.amux.ai.Clean.sentinel.agent.plist
        └── LaunchDaemons/
            ├── com.guoshuyu.cleanmac.sentinel.plist
            └── com.amux.ai.Clean.sentinel.plist
```

三个 plist 的职责严格分离：

| 描述符 | Label | 唯一允许动作 |
|---|---|---|
| 当前 `LaunchAgents/com.amux.ai.Clean.sentinel.agent.plist` | `com.amux.ai.Clean.sentinel.agent` | `status`、`register`、`unregister` |
| 原品牌迁移专用 `LaunchDaemons/com.guoshuyu.cleanmac.sentinel.plist` | `com.guoshuyu.cleanmac.sentinel` | `status`、`unregister` |
| 改品牌后迁移专用 `LaunchDaemons/com.amux.ai.Clean.sentinel.plist` | `com.amux.ai.Clean.sentinel` | `status`、`unregister` |

`c8a57e8` 品牌迁移曾在原文件
`com.guoshuyu.cleanmac.sentinel.plist` 内直接把 Label 从
`com.guoshuyu.cleanmac.sentinel` 改为 `com.amux.ai.Clean.sentinel`。这会让同一个 descriptor
在不同版本代表两份 authority，当前版本无法证明“查询新 Label”也能注销早期旧 Label。
v2026.07.18 P1 修复因此把两代 root 注册拆成稳定、独立、文件名与 Label 对应的迁移描述符；
`SMAppService.daemon(plistName:)` 对两项分别构造 service、分别查询和注销，不能再通过改写单个
plist 的 Label 猜测另一代注册已经退出。

两个 root 描述符都不是现行服务，生产代码没有调用其 `register()` 的入口；它们的
`BundleProgram` 指向当前包内已签名 helper，仅保持 descriptor 可解析，不能被当成重新部署
root daemon 的许可。`/tmp/com.{guoshuyu.cleanmac,amux.ai.Clean}.sentinel.{out,err}.log`
也只是对应历史身份的兼容字段，当前 Agent 不使用这些位置。迁移窗口结束且确认不再需要升级
任一历史安装后，可在后续版本整体删除两个描述符、两个 `SMAppService.daemon` 适配器和相应
release contract，但同一身份的文件、代码、测试和合同必须同批删除。

这里存在自动化不能消除的真实升级边界：原品牌已安装 descriptor 历史上使用
`Contents/MacOS/gsycleanmac-sentinel`，当前迁移 descriptor 使用包内实际存在的
`Contents/MacOS/amuxaiclean-sentinel`；`c8a57e8` 同时把签名 Team ID 从 `39PK4PKRP3` 切换为
`W6H34N9728`。当前包没有、也不得为了测试臆造旧二进制 alias。单测与 release contract 只能
证明“两份 Label 对应的注销通道已入包、代码永不注册它们”，不能证明当前签名身份一定能注销
历史系统数据库中的真实注册；必须用两代已注册旧版分别升级做 C4。

## 4. 注册与状态事务

唯一协调者是
[`SentinelManager`](../Packages/AppUI/Sources/AppUI/SentinelManager.swift)。开启是能力增加，
关闭是能力减少，两者不能机械套用同一顺序。v2026.07.19 P1 另把“用户期望”与“历史
authority 证据”拆开：`sentinelEnabled` 只表示期望；持久化的
`sentinelRequiresShutdownVerification` 只表示某代服务曾成功注册、系统曾明确报告 active，或旧
ON/启用时间迁移得出的可信证据。该证据只有三份 identity 都明确 `.notRegistered` 才能清除。

```text
读取持久化期望 + authority 证据
  ├─ 期望 ON（增加能力）
  │    → 逐项查询/注销/复读两代旧 Daemon
  │    → 两项未全部明确 notRegistered：阻断新注册；若 current Agent 已经存在，尝试注销并复读
  │    → current Agent 已权威停止：发布 typed legacyMigrationFailed(ON)
  │    → current Agent 也未能权威停止：发布 typed legacyMigrationSafetyShutdownFailed，
  │      user 手势回滚 OFF；startup 仅保留 ON 期望，实际状态仍投影 unverified
  │    → 两项均收敛：查询当前 Agent，执行 no-op / register / 请求审批，再复读
  └─ 期望 OFF（减少能力）
       → 先查询当前 Agent；enabled/requiresApproval 本身会建立 authority 证据，随后 unregister 并复读
       → 当前 Agent 已明确 notRegistered：开关保持 OFF，清 sentinelLastEnabled
       → current status 为 notFound/unknown：
          · 用户刚主动关闭，或已有 authority 证据：发布 shutdownVerificationUnavailable，
            明确说明“未执行关闭操作”并引导检查登录项
          · fresh/default-OFF 且无证据：只写结构化诊断，不弹窗、不要求用户打开系统设置
       → 随后逐项查询/注销/复读两代旧 Daemon
       → legacy 未全部收敛：不回滚 ON，发布 typed legacyMigrationFailed(OFF)，
         presentation 为 desiredOffUnverified，且不宣称所有历史后台项已停；但三项均只返回
         notFound/unknown 且没有任何 authority 证据时仍仅记录诊断，不制造用户任务
       → 只有当前 Agent 自身未能权威关闭时，交互手势才沿用失败回滚合同
       → current + 两代 legacy 全部明确 notRegistered 后，才清持久化 authority 证据
  → 一次性提交 Toggle、时间戳、presentation 与 typed failure
```

关键不变量：

- 默认值是 OFF；fresh/default-OFF 且没有历史 authority 证据时，即使开发构建或
  ServiceManagement 对三份 descriptor 都返回 `.notFound`，也只能记结构化诊断，不得弹启动
  modal、不得要求用户修复从未启用的登录项；
- 两代旧 Daemon 必须逐项明确确认 `.notRegistered`，才允许注册/保留 ON 的新 Agent；`.notFound` 表示
  ServiceManagement 无法定位服务，是配置/查询错误，不是“已经注销”的证明，也不是“仍在运行”的
  证明；不能在没有执行 `unregister()` 时把它包装成“关闭失败”；
- ON 迁移失败时不能只阻止新的 `register()`：已经 enabled/requiresApproval 的 current Agent
  也必须按最小权限尝试注销并复读；注销失败必须保留真实 status 和独立 typed failure，不能
  因为 Toggle 已回写 OFF 就声称 Agent 已停；
- 某代旧服务的 `unregister()` 抛错后仍复读该项权威状态：若已是 `.notRegistered` 可视为
  收敛，否则失败关闭；同时继续检查另一代，最后统一决定迁移是否完整；
- 当前 Agent 的用户手势失败时，Toggle 回到手势前值；当前 Agent 已权威关闭但 legacy
  migration 失败时，OFF 是最小权限意图，不能回滚 ON。启动修复失败保留持久化意图，UI
  必须明确显示“期望与系统状态不一致”；
- 用户主动关闭、系统明确 active 或持久化 authority 证据存在时，状态查询失败仍 fail-closed；
  用户提示必须说明具体动作“系统设置 → 通用 → 登录项与扩展 → 关闭 AmuxAIClean”，并指向
  App 内“设置 → 存储 → 日志”，不得裸露账户路径、raw Error 或 errno；
- `requiresApproval` 是独立状态，交给“系统设置 → 通用 → 登录项”处理；
- raw `NSError` 只进入结构化日志，UI 使用类型化、本地化错误；
- SwiftUI `onChange` 的程序性回写携带事务 ID，不能再次触发注册或注销；
- 清除产品数据前必须先调用同一关闭事务。删除 defaults、JSON 或日志不能证明系统服务已停止。

macOS 在用户把 `.app` 直接拖入废纸篓时不提供本 App 可依赖的卸载回调。因此产品不能承诺
“删除 App 时自动注销”。真实清除流程是：App 仍可运行时关闭 Sentinel，确认状态为
“未注册”，再删除本地数据或 App。若未来增加产品内“清除全部数据”入口，该入口必须先调用
上述事务，并在新 Agent 或任一代旧 Daemon 注销失败时阻止清除。

## 5. Helper 运行合同

入口是 [`Tools/Sentinel/Sources/Sentinel/main.swift`](../Tools/Sentinel/Sources/Sentinel/main.swift)。

v2026.07.18 起，Helper 的第一条可执行语句必须检查 `geteuid()`。root 身份只向 stderr
写入固定、无路径的拒绝标记，随即以 `EX_NOPERM` 退出；在此之前不得初始化 Home
路径、日志、持久化文件或任何监听器。这是对旧 root LaunchDaemon 残留的进程级
fail-closed 边界，不依赖主 App 迁移成功才能保证当前 Agent 逻辑不会在 `/var/root` 下运行。

### 5.1 监听与去抖

- `TrashListener` 使用 file-events FSEvents，接收 created / renamed 的 `.app`、`.bundle`；
- `HotspotListener` 使用 file-events FSEvents，接收 created / modified；
- 两类事件各自在 utility serial queue 上进行 30 秒去抖；
- Spotlight、`.fseventsd`、DocumentRevisions 和 `.tmp` 路径被忽略；
- FSEvents 只形成发现信号。主 App 收到深链接后仍走自己的扫描、安全和确认合同。

### 5.2 本地状态

热点事件以 `{ path, detectedAt, sizeHint }` 保存到
`~/Library/Application Support/AmuxAIClean/sentinel-pending.json`：

- 相同路径保留最新一条；
- 最多 100 条，超出后移除最旧事件；
- 原子覆盖写入；
- 关闭 Sentinel 不自动删除该文件；
- 文件损坏或不可读时保留原文件并记录错误，不用空数组覆盖。

当前主 App 尚未读取该 JSON 展示历史列表；现有用户可见行为来自深链接。该文件是本地待处理
证据，不得在文档中宣称已经实现“最近候选”页面。

### 5.3 日志

当前 Agent 写入
`~/Library/Logs/AmuxAIClean/AmuxAIClean-Sentinel-YYYY-MM-DD.log`，可能包含监听路径和技术
错误。Agent 启动时、之后每小时定时检查，并在休眠唤醒后的下一次写入再次检查，按修改时间
清理超过 7 天的 Sentinel 日志；不能把只在进程启动时清理描述成长期保留策略。日志失败只
回退到 stderr，不能停止 FSEvents；stderr 只允许写固定失败标记，不能回显原始路径或技术消息。
不得记录 API Key、AI 响应正文或文件内容。完整披露和清除步骤以 [`PRIVACY.md`](../PRIVACY.md)
为准。

### 5.4 深链接边界

- `amuxaiclean://uninstall?path=...`：由主 App 的 `SentinelURLRouter` 校验后进入卸载页面；
- `amuxaiclean://action/scan/full`：只形成邀请，由主 App 交互决定是否开始扫描；
- Helper 通过 `/usr/bin/open -g` 发送 URL，不链接 AppKit；
- 未知 scheme、host、action 和越界路径必须拒绝，不能转成删除意图。

## 6. 构建与发布合同

- Helper 是独立 `PBXNativeTarget` Command Line Tool；
- 主 App 依赖 Helper target，并以 `CodeSignOnCopy` 嵌入 `Contents/MacOS`；
- 当前 Agent plist 嵌入 `Contents/Library/LaunchAgents`；
- 两代旧 Daemon plist 只作为迁移描述符嵌入 `Contents/Library/LaunchDaemons`；
- `Scripts/test_release_contract.sh` 锁定三个文件名、三个不同 Label、两份 root plist 的
  文件名/Label 对应关系、BundleProgram、Copy Phase、`SMAppService.agent` 当前注册路径、
  逐项 legacy `unregister` 和 never-register 静态合同；
- 任何删除某一旧迁移描述符的版本都必须提供该身份的迁移窗口证据，不能只删文件而留下代码、
  测试或合同，反之亦然。

## 7. 验证边界

自动化应覆盖：

- 默认 OFF、幂等状态决策、审批与未知状态；其中 fresh/default-OFF + 无 authority 证据 +
  current/legacy 全部 notFound 必须无 modal，而明确 active 仍必须注销；
- ON 时两代旧 Daemon 都在新 Agent register 之前逐项查询；OFF 时 current Agent 必须先注销，
  再迁移两代 root，legacy lookup 不能阻断降权动作；
- 一代查询失败时仍清理另一代，但整体阻断新注册并产生 typed failure；
- ON 迁移失败且 current Agent 早已存在时，覆盖 user/startup × 安全注销成功/失败矩阵；
- current Agent 已权威 OFF、legacy 仍失败时保持 Toggle OFF、清时间戳并投影
  `desiredOffUnverified`；只有 current Agent 自身关闭失败才执行交互回滚；
- 持久化 authority 证据由成功 register、明确 active 和旧 ON/启用时间迁移建立；仅三 identity
  全部 notRegistered 时清除。交互 OFF 或可信证据下的 lookup failure 必须使用
  `shutdownVerificationUnavailable`，不能冒充执行过 unregister；
- 当前 Agent 与两代旧 Daemon 使用三个不同文件名/Label；release contract 同时核对 root
  descriptor 的文件名与 Label 相同；
- 用户手势失败回滚不会形成 `onChange` 反馈循环；
- URL 路由、事件过滤、ring buffer 容量与损坏文件行为；
- AppUI 包测试、目标 Debug 构建与 release contract。

包测试和 Debug 构建最多构成 C3，不能证明真实 ServiceManagement 授权、登录项 UI、TCC、
FSEvents 或 24 小时资源占用。下列动作只允许用户明确授权后在一次持续 C4 中完成：

1. 分别从 `com.guoshuyu.cleanmac.sentinel` 与 `com.amux.ai.Clean.sentinel` 已启用的旧版升级，
   覆盖旧 `gsycleanmac-sentinel` BundleProgram、改品牌后 BundleProgram 与 Team ID 变化，验证
   对应 root Label 被真实注销、另一项也被查询，且新 Agent 不自动启用；
2. 在设置中开启当前 Agent，处理系统审批，验证进程的 UID 和 Home 是登录用户；
3. 对 Trash 与三个热点各做一次真实事件，观察去抖、深链接和 UI；
4. 关闭并确认当前 Agent 与两代 root 服务均未注册；
5. 持续观察 CPU、RSS、日志轮换和 24 小时稳定性。

在 C4 完成前只能表述“代码与构建合同已验证”，不能表述“真实后台监控已验收”。

## 8. 仍未完成

- 主 App 没有 `sentinel-pending.json` 历史列表；
- 没有可依赖的 App 拖拽卸载回调，用户必须在删除 App 前主动关闭并验证；
- 两代旧 root 描述符仍处于迁移窗口，后续分别移除都需要版本分布证据；
- 两代真实升级迁移、系统审批、TCC、持续资源占用与 24 小时烧测仍需 C4。
