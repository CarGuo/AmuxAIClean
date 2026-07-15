# GSYCleanMac - 前人踩坑实录与避坑清单

> 本文是开工前必读。每一条都来自真实社区（Apple DTS 论坛 / Sparkle issues / Pearcleaner 源码 / Nektony 卸载方法论 / ncdu macOS 适配 / AppCleaner 用户事故）。
> 目标：让我们一次性把这些坑都"知道"，而不是一个一个去"踩"。
> 编写日期：2026-05-21

---

## 重要：v1.3.zzzz 路线 B 删除链路简化（2026-05-25 更新）

[Helper/](file:///Users/guoshuyu/workspace/GSYCleanMac/Helper) / [Packages/XPCBridge/](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/XPCBridge) / [HelperClient.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HelperClient.swift) / [HelperDecision.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/HelperDecision.swift) **整段下线**。

**理由**：本产品仅删除 `$HOME` 下用户态文件（Caches / Application Support / .Trash 等），完全不需要 root 权限。Helper / SMAppService / LaunchDaemon / HMAC 三道闸门链路在此场景属于纯负担——增加进程数、首跑授权对话框、Free Apple ID 自签下根本跑不通的 Team ID 校验旁路、双端密钥共享心智负担。删除链路收敛为唯一一份 [TrashPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift)（直接走 `NSWorkspace.recycle`）。

**保留**：[DeletionPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/DeletionPipeline.swift) 协议本身，给未来如 dry-run-only 调试管道、远程 audit 管道留扩展点。

下文若提到 "Helper" / "XPC" / "SMAppService" / "Mach service"  / "HelperClient" / "MockHelperClient" / "DeletionTokenSigner" / "HelperDecision" 均为**历史档案**，不再适用。

---

## 0. 总览（按风险等级）

| 等级 | 描述 | 我们的处理 |
|---|---|---|
| [阻塞] 阻塞级 | 不绕过就根本跑不起来 / 无法上架 / 数据损坏 | 必须在 MVP 前跑通 |
| [体验] 体验级 | 偶发崩溃/数据偏差/用户困惑 | V1 之前必须处理 |
| [优化] 优化级 | 影响性能或观感 | 持续迭代 |

---

## 1. 特权 Helper（SMAppService / XPC）—— 全是坑的重灾区

### 1.1 [阻塞] `SMAppServiceErrorDomain Code=1 "Operation not permitted"`
- **现象**：注册一次成功，再次调用 `register()` 报 Code 1。
- **根因**：用户在"系统设置 -> 登录项与扩展"里把开关关了之后，状态机不刷新；或开发期间换了签名/Bundle ID。
- **避坑**：
 - 注册前先 `service.status` 判断；只有 `notRegistered` 才调用 `register()`。
 - **开发用一个 Bundle ID，发布用另一个 Bundle ID**（DTS 工程师 Quinn 明确建议），否则 LaunchServices 会"记仇"。
 - 调试遇到无解时执行 `sudo sfltool resetbtm` 后重启（这个命令仅给开发者用，绝不能让用户跑）。

### 1.2 [阻塞] `Codesigning failure loading plist code: -67054 (errSecCSBadResource)`
- **现象**：仅在 macOS 13.0/13.1 出现，13.5+ 正常。
- **根因**：早期 Ventura 的 `smd` 对资源签名计算有 bug。
- **避坑**：
 - 本项目最低系统版本锁定为 **macOS 15 Sequoia**（已直接绕开 Ventura 全部历史坑，并可放心使用 SwiftUI Observation / SwiftData 等现代 API）。
 - `Info.plist` 修改后必须**重新整体重签**，不能局部签。

### 1.3 [阻塞] 嵌套签名顺序错误 -> 整个 App 注册失败
- **现象**：直接 `codesign` 主 App，里面的 Helper / Sparkle / fileop 没签上 hardened runtime。
- **避坑**（顺序写死在 [Scripts/codesign.sh](file:///Users/guoshuyu/workspace/GSYCleanMac/Scripts/codesign.sh)）：
 1. 先签所有内嵌的小可执行（`fileop`, `Autoupdate`, `Helper` 主二进制）
 2. 再签 `.framework`（含 Sparkle.framework）
 3. **最后**签主 App `.app`
 4. 全部 `--options runtime`、`--timestamp`，禁用 `--deep`（`--deep` 在 macOS 11+ 已不推荐）

### 1.4 [阻塞] macOS 26 Launch Constraints 让旧版 helper 启动崩溃
- **现象**：用 macOS 26 SDK 编译的 helper，回到 macOS 13/14 启动直接 `CODESIGNING 4 Launch Constraint Violation`。
- **避坑**：在 helper 的 `Info.plist` 加上 `LaunchConstraint*` plist；CI 必须有 macOS 13 / 14 / 15 / 26 至少 4 套 VM 跑回归。

### 1.5 [阻塞] XPC 连接遭恶意进程冒用
- **现象**：第三方进程通过 mach name 连上你的 helper，调用 `removeFile(:)` 删任意文件。
- **避坑**：
 - Helper 端在 `shouldAcceptNewConnection` 里**强制校验** `auditToken` 对应进程的 `SecCodeCopySigningInformation` -> Team ID + designated requirement。
 - **不要**接受任意路径，所有路径必须由主 App 计算 + HMAC 签名后传过来，helper 校验签名再删。
 - 参考 LuLu / Pearcleaner 的实现。

#### v0.2 落地实测（2026-05-21）：三道闸门 + 17 个安全测试
落地后 Helper 的请求处理顺序固化为：

1. **闸门 1（连接级）** `shouldAcceptNewConnection`：从 `connection.processIdentifier` 取 `SecCode` -> `SecCodeCopySigningInformation` 拿 `kSecCodeInfoTeamIdentifier` / `kSecCodeInfoIdentifier`，bundle ID 必须在白名单、Team ID 必须匹配，否则 return false。**不接受 audit token 之外的任何身份证据**。
2. **闸门 2（消息级）** HMAC-SHA256：DeletionRequest 由主 App 用 keychain 里的共享 key 签名，Helper 用同 key `verify`，签名失败/过期/expires-too-far 一律拒。**这一关是 8/8 测试覆盖，包括关键的 "TamperedDryRun" 攻击场景**——攻击者把签名后的 dryRun=true 篡改为 false 试图越过 dry-run 模式，验签必败。
3. **闸门 3（语义级）** [HelperDecision](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/HelperDecision.swift)：批内任一路径过不了 [SafetyEngine](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) 立即 `rejectBatch`——这是**防"夹带私货"**：攻击者把 `/Users/me/Library/Caches/foo` 和 `/System/Library/CoreServices` 一起塞进同一个 batch，期望 Helper "至少删一个"，必须整批拒。

实测发现的两个**血泪坑**：

- **`URL.standardizedFileURL` 会把 `/private/var/db` 标准化成 `/var/db`** —— firmlink 第二次咬人。SafetyEngine 的 `hardForbidPrefixes` 必须**两份都写**：`/private/var/db` 和 `/var/db`，否则用户传 `/private/var/db/uuidtext` 会被判为 confirm。
- **`/System/Volumes/Data/...` 是**数据卷穿透**，不是 SIP 路径** —— 把 `/System` 写进硬黑名单时必须先放过 `/System/Volumes/Data/` 前缀，否则用户家目录的合法路径 `/System/Volumes/Data/Users/foo/Library/Caches/x` 会被错杀。

**dryRun 是 first-class citizen**：Helper 启动时读 `GSYCLEAN_ALLOW_REAL_DELETE`，没显式设成 `1` 就**永远 dry-run**——即使 HMAC 验签通过、SafetyEngine 放行，也只打 audit log 不动手。`HelperDecision.decide` 把这个全局开关与 request 自带的 `dryRun` 标志做 OR：任一为 dry 就 dry。

**永不 unlink**：真删也只走 `FileManager.trashItem(at:)`（即 NSWorkspace.recycle），给用户最后一道反悔窗口。`unlink(2)` 这个 API 在 Helper 里**不会出现**。


### 1.6 [体验] 卸载干净
- 用户反复抱怨"卸了清理软件还有 root daemon 在跑"——这就是 Nektony 方法论里的 L1 阻塞项。
- **避坑**：菜单栏必须有 "Uninstall Helper"，调用 `SMAppService.unregister()` + 删除 `/Library/PrivilegedHelperTools/<id>` + 删除 LaunchDaemon plist + 写 audit log。**绝不**留任何残留。

### 1.7 [体验] deadlock：同步 XPC 调用永不返回
- **现象**：发了 `synchronous` 消息，但 helper 那边没启动，主 App 卡死。
- **避坑**：所有 XPC 接口走 **async/await + 5s 超时**，永远不要用同步 reply block。

---

## 2. 扫描引擎 —— 数据正确性的雷区

### 2.1 [阻塞] firmlinks（macOS Catalina+）—— 这是你看到 "100G 找不到 80G" 的元凶
- **现象**：`/usr` 实际数据在 `/System/Volumes/Data/usr`，普通 `find` / `du` 会**重复计数**或**漏计**。
- **根因**：firmlinks 是 APFS 系统卷与数据卷之间的"双向虫洞"，不是符号链接也不是硬链接。
- **避坑**：
 - 默认从 **数据卷根** `/System/Volumes/Data` 开始遍历，**而不是** `/`。
 - 提供 `--follow-firmlinks` 开关（参考 ncdu 1.15）。
 - firmlinks 列表读取 `/usr/share/firmlinks`，把目标加入 inode 去重表。
 - `chdir` 后 `getwd` 会跳到 firmlink 目标，用绝对路径避免（Apple 论坛 FB11432545 已确认 "works as designed"）。

### 2.2 [阻塞] Full Disk Access (FDA) 没拿到时遍历静默失败
- **现象**：`FileManager.enumerator` 扫到 `~/Library/Mail` 直接返回空，不抛错。
- **避坑**：
 - 启动时先用 `~/Library/Safari/Bookmarks.plist` 做 FDA 探针（不存在或不可读 -> 引导跳转 `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`）。
 - 探针失败时**不要**继续扫，先弹引导。
 - FDA 是按 **app bundle ID + 路径** 授权的，开发期间换 Team ID 会失效。

### 2.3 [阻塞] 硬链接 / APFS clones / 稀疏文件 -> 大小算重
- **现象**：Time Machine 的 `Backups.backupdb` 全是硬链接，朴素 `du` 算出 5TB，实际 500GB。
- **避坑**：
 - **必须**按 `(dev_t, ino_t)` 建 `Set` 去重（参考 ncdu 1.15 修复）。
 - 用 `URLResourceKey.totalFileAllocatedSizeKey`（物理占用）而非 `.fileSizeKey`（逻辑大小）。
 - `URLResourceKey.fileResourceIdentifierKey` 可用做跨卷 ID。

### 2.4 [阻塞] iCloud 占位文件 (`.icloud`) 的"幽灵 GB"
- **现象**：开启 "Optimize Mac Storage"，文件显示 5GB 但实际本地 0 字节。
- **避坑**：
 - 双取 `fileSize`（云端逻辑）+ `totalFileAllocatedSize`（本地物理）。
 - UI 上**两栏并显**："本地占用 / 总大小"，让用户知道差距。
 - Get Info 在 macOS 上正是这么做的（"Size: 108 MB, 72.8 MB on disk"）。

### 2.5 [体验] `.Trashes`、`.fseventsd`、`.Spotlight-V100` 等系统隐藏目录
- **现象**：扫外置硬盘会算到 `/Volumes/X/.Trashes/<UID>`（每个用户一份）。
- **避坑**：把这类系统隐藏目录单独归类为"系统/废纸篓"，不要混进"用户文件"。

### 2.6 [体验] fts(3) 整数溢出 / 文件名 >2GB
- **现象**：ncdu 1.14 在 >2GiB 文件名总和的目录里溢出。
- **避坑**：所有累加用 `Int64`/`UInt64`，不要图省事用 `Int32`。

### 2.7 [体验] chdir + 相对路径 + firmlink -> 跳到错误目录
- 见 1.5 节 Apple 论坛 FB11432545。
- **避坑**：**永远**用绝对路径，禁止 `chdir(.)` + 相对路径。

### 2.8 [优化] `getattrlist` vs `FileManager.enumerator` 性能差 3-5x
- 大目录扫描走 `getattrlistbulk`（一次 syscall 拿一批属性）。
- 写一个 C bridging shim，避免 Swift 端来回拷贝。

#### 实测：v0.1 落地数据（2026-05-21，~/Downloads, 48k+ 文件 / 4.5k 目录 / 3.6 GB）

| 引擎 | 耗时 | files | dirs | on disk | 对比 du -sh |
|---|---|---|---|---|---|
| Scanner（FileManager.enumerator） | **2.20s** | 48692 | 4539 | 3.63 GB | 13.7x 慢 |
| BulkScanner（getattrlistbulk） | **0.54s** | 48879 | 4551 | 3.63 GB | **3.4x 慢** |
| `du -sh`（系统） | 0.16s | — | — | 3.4 G | 1x |
| `du -sh -A` | 0.16s | — | — | 3.3 G | 1x |

> ScanKit 比 du 还多算 0.2 GB —— **包含隐藏文件 + 全局硬链接去重 + APFS clone bonus**，这是数据更准的代价。

#### 实现要点（写血泪了）
1. **`u_short` not `u_int`**：`attrlist.bitmapcount` 在头文件里是 `u_short`，Swift 自动 import 容易写错。
2. **`UInt32(ATTR_*)`** 强转：所有 `ATTR_CMN_*` / `ATTR_FILE_*` 在 Swift 里是 `Int32`，跟 `attrgroup_t (UInt32)` 不兼容。
3. **`loadUnaligned` 不能用 `load`**：`getattrlistbulk` 返回的 entry 字段紧凑排布，arm64 上严格对齐会 `Fatal error: misaligned raw pointer`。
4. **[阻塞] 字段必须按 `attrgroup_t` 的 bit 升序解析**：
 - `commonattr`: NAME(bit0) -> DEVID(bit1) -> OBJTYPE(bit3) -> MODTIME(bit10) -> FILEID(bit25)
 - 写错顺序不会报错，会读到 `objType=0x01000010` 这种"看起来像数字其实是别的字段"的鬼数据，然后所有 isDir 永远 false -> 永远不递归子目录 -> 漏扫 97% 的内容。
5. **`VDIR/VLNK` 是 `vtype` enum**：要 `.rawValue` 才能跟 `fsobj_type_t (UInt32)` 比。
6. **DFS 用栈，不要递归**：根目录如 `~`，深度可达 20+，递归容易 stack overflow，且无法响应 `Task.cancel()`。
7. **失败要回退**：`open(O_RDONLY)` 在 Full Disk Access 缺失时会 -1，调用方必须 fallback 到 `Scanner` 的 FileManager 路径。

#### 性能可改进的点（v0.2 路线）
- **目录级并发**：当前 DFS 串行，多盘并发可再提 1.5–2x。
- **省 URL 创建**：`continuation.yield(.node(...))` 每次 new URL 是 hot path，UI 不实时画图时可走 `nodeBatch(_)` 一次发一批。
- **省 String**：`String(cString:)` 在中文文件名上分配开销大，可延迟到真要展示时再做。

---

## 3. 删除 / 安全判定 —— 用户数据丢一次就完蛋

### 3.1 [阻塞] 共享厂商目录被整删（Adobe / Microsoft / JetBrains 经典事故）
- **现象**：用户卸载 Photoshop，工具把 `~/Library/Application Support/Adobe/` 整个删掉，Illustrator、Premiere 全废。
- **避坑**（Nektony L1 红线）：
 - 维护"共享厂商目录"白名单：[Resources/Rules/vendor_shared.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendor_shared.yaml)
 - 命中时只允许删 **app 专属子目录**（如 `Adobe/Photoshop 2024/`），父目录保留。
 - 默认 unchecked，强提示"该目录被多个应用共用"。

### 3.2 [阻塞] LaunchAgents / LaunchDaemons 残留 -> 系统反复弹"找不到二进制"
- **现象**：删了 `.app` 但忘删 `~/Library/LaunchAgents/com.x.y.plist`，launchd 每分钟尝试启动一次 ghost 进程。
- **避坑**：
 - 残留扫描必须包含：`~/Library/LaunchAgents`、`/Library/LaunchAgents`、`/Library/LaunchDaemons`、`~/Library/LoginItems`，以及 `SMAppService` 注册的现代登录项（`sfltool dumpbtm`）。
 - 删 `.app` 前先 `launchctl bootout` 对应 plist，再删 plist 文件。

### 3.3 [阻塞] VPN / 网络扩展 / 配置描述文件残留
- **现象**：卸了 ExpressVPN，VPN profile 还在系统设置里跑，流量被劫持。
- **避坑**：
 - 卸载前枚举 `Network Extensions`、`System Extensions`、`Configuration Profiles`。
 - 提示用户"该应用安装了 N 个网络扩展，请先在系统设置中移除"，不能也不应该由我们替用户删（需要管理员二次确认）。

### 3.4 [阻塞] 不可逆删除 vs 移到废纸篓
- **现象**：CleanMyMac 早期版本"安全擦除"误删用户文档，无法恢复。
- **避坑**：
 - **默认全部** `NSWorkspace.shared.recycle(_:completionHandler:)` 移废纸篓。
 - "永久删除"必须二次确认 + 输入密码 + 写 audit。
 - Trash API 在 helper 里走不通（`recycle` 是用户态 API），helper 端需走 `mv -f` 到目标用户的 `.Trash`，并用 `_kMDItemUserTags` 标记。

### 3.5 [阻塞] SIP-protected 路径被传进删除接口
- **现象**：一些规则贪心匹配到 `/usr/libexec/foo`，删除时报 EPERM。
- **避坑**：
 - Helper 黑名单（写死，不可配置）：
 ```
 /System /usr (除 /usr/local /usr/share/firmlinks)
 /sbin /bin /Library/Apple
 /private/var/db /private/var/protected
 /Volumes/<*>/System
 ```
 - 删除前 `csrutil status` + `chflags` 检查 `schg` 标志。

### 3.6 [体验] 误删用户文档（`~/Documents` `~/Desktop`）
- **现象**：规则写错把用户文件夹标成"缓存"。
- **避坑**：
 - 这些路径**永久 read-only**，不在任何规则匹配范围。
 - 规则引擎单测覆盖：用户文档目录必须永远不可达。

### 3.7 [体验] AppCleaner 沙盒/Group Containers 盲区
- **来源**：CSDN / Apple Discussions 大量用户反馈。
- **避坑**：
 - 残留扫描必须包含 `~/Library/Containers`、`~/Library/Group Containers`、`/private/var/folders/<hash>/T/`（仅扫，不一定删）。
 - Bundle ID 模糊匹配 + Spotlight `kMDItemCFBundleIdentifier` 反查。

### 3.8 [体验] 删除时进程仍持有文件 -> 删而不释空间
- **避坑**：`lsof +D <path>` 检测；若有占用，提示"请先退出 X 应用"。

### 3.9 [阻塞] 统一 TrashPipeline 不等于统一删除交互
- **现象**：所有入口最终都走 `TrashPipeline`，但 Main、Smart Care、Brew、Duplicate、Uninstall、Workflow 各自维护确认 sheet；有的先确认，有的把预检拒绝直接画成 `Cleanup Failed 0/N`，还有的行按钮/右键/Delete 键行为不同。
- **根因**：只收敛了执行函数，没有收敛 `intent → preflight → confirmation → running-app choice → final revalidation → execution → result` 状态机。
- **避坑**：
 - 所有真实文件删除入口只提交 typed intent，必须进入 [DELETION_UX_CONTRACT.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/DELETION_UX_CONTRACT.md) 定义的共享 coordinator 和唯一确认页。
 - preflight rejection 是 confirmation plan，不是执行结果；`OperationResultSheet` 只能在用户确认并实际提交后呈现。
 - 禁止保留名称为 force、实现却回落 normal 或静默丢弃回调的空心 API。
 - 每次修改跑 `ProfessionalToolDeletionFlowTests`、`DeletionUXPolicyTests`，并维护删除入口矩阵。

### 3.10 [阻塞] 扫描不完整被误当删除权限，污染整棵 HOME 子树
- **现象**：一个 descendant 目录无法枚举，扫描器同时发 scoped incomplete 和全局 failed；上层再把整个 scan root 加入 incomplete。删除预检按祖先重叠后，所有 sibling 都变成 `accessDenied`，真实 vendor override 消失，UI 还错误提示 Full Disk Access。
- **根因**：fatal/partial 事件没有 scope，且 `incomplete / TCC / POSIX / OS delete permission` 被压进同一个字符串或 Set。
- **避坑**：
 - `ScanEvent.failed` 只用于扫描根/整轮没有可信终态的失败；后代权限、瞬时 ENOENT/rename、枚举失败只上报 typed incomplete。
 - 已有精确 child issue 时禁止把 root 补成 incomplete；兄弟路径不得继承无关拒绝证据。
 - 删除确认前做目标级重验；“内容没有完整扫描”不等于“不能把目录移到废纸篓”。
 - 用户可见层禁止 raw `"\(error)"`、`file:///`、percent encoding；permission/partial/fatal 只能有一个主 presentation。
 - 对应合同：`ScanCompletenessContractTests`、`MultiRootCompletionPolicyTests`、`ProfessionalToolDeletionFlowTests`。

### 3.11 [阻塞] 子孙 incomplete 被对称投影成祖先锁
- **现象**：真实受限路径位于 `~/Library/Containers/...`、`~/Library/Services/...` 等深层位置，Tree 却把 `Library`、`Containers` 等可访问父目录一起画成锁并去掉展开入口。如果该父目录保留了上一帧的 `expanded` 状态，还会出现“行已锁、没有披露三角，但旧子项仍显示”的矛盾 UI。
- **根因**：投影层用“相等 / 祖先 / 后代”对称 overlap 直接生成单一 `accessState`，再让同一字段同时决定锁图标、灰态、是否可展开、统计是否可信和是否可发起删除。这把“节点自身不可访问”与“子树内部有未完整后代”混成了一个概念；仅改 exact-match 又会让删除入口把父目录误当成完整可删。
- **正交模型**：
 - `accessState` 只表示当前节点 exact issue，或当前节点确实位于已锁上级范围内。只有这个维度可以画 lock、置灰、隐藏大小和禁止下钻。
 - `subtreeCompleteness` 独立表示当前行内部是否包含 strict-descendant issue。该维度只显示 partial/内部受限提示，父行保持正常可展开，统计值必须表达为下界或部分值，不得伪装精确。
 - 删除预检独立消费 `subtreeCompleteness`：祖先不画锁不代表能够盲删它包含的未完整子树；Professional 模式应进入目标级重验/严格确认，不得从视觉 lock 布尔值推导授权。
 - 旧展开状态不得绕过 `accessState`：真实锁节点变为不可访问后，必须停止递归其陈旧后代；只有 `subtreeCompleteness == .containsIncompleteDescendant` 的可访问祖先仍可继续下钻。
- **防复发测试**：
 - [ScanCoordinatorCompletenessProjectionTests.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/ScanCoordinatorCompletenessProjectionTests.swift) 覆盖 exact / ancestor / descendant / sibling 关系：真实 issue 行锁定，祖先 `accessState == .normal` 且 `subtreeCompleteness == .containsIncompleteDescendant`，兄弟完全正常。
 - [ScanCoordinatorFullDiskTests.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/ScanCoordinatorFullDiskTests.swift) 覆盖真实按需扫描中的深层权限拒绝；[FlatRowsIncrementalPatchTests.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/FlatRowsIncrementalPatchTests.swift) 覆盖 issue 到达后仍残留旧 `expanded` 状态时，真实锁节点不再展示陈旧后代，而 partial 祖先仍可展开。
 - 删除合同必须另断言祖先的 incomplete 证据仍进入预检，禁止为了修 UI 锁而放开父目录删除。

---

## 4. 签名 / 公证 / 分发 —— 商业化前置

### 4.1 [阻塞] Sparkle 自更新 + Hardened Runtime
- **现象**：Sparkle 内嵌的 `Autoupdate.app` 和 `fileop` 没启用 hardened runtime -> 公证失败。
- **避坑**：
 - 在 `Pods` 或 SPM 后执行脚本：
 ```
 codesign --force -o runtime --timestamp -s "$IDENTITY" \
 Sparkle.framework/Versions/A/Resources/Autoupdate.app/Contents/MacOS/Autoupdate
 codesign --force -o runtime --timestamp -s "$IDENTITY" \
 Sparkle.framework/Versions/A/Resources/Autoupdate.app/Contents/MacOS/fileop
 ```
 - 用 EdDSA 签 appcast，私钥用 Keychain 保管，CI 用 GitHub Actions Secrets。

### 4.2 [阻塞] `--deep` 害人
- `codesign --deep` 只是把同样参数往内层签，不会"修复"漏签的子组件，且在 macOS 11+ 行为不一致。
- **避坑**：用显式的"由内向外"循环签名脚本（[Scripts/codesign.sh](file:///Users/guoshuyu/workspace/GSYCleanMac/Scripts/codesign.sh) 里写明）。

### 4.3 [阻塞] Mac App Store ≠ Developer ID
- 含特权 helper 的 App **无法上架 MAS**（沙盒禁止 SMAppService daemon）。
- **避坑**：分发渠道选 **Developer ID + DMG + Sparkle**，不再考虑 MAS。

### 4.4 [体验] 公证后忘 staple
- **避坑**：CI 必须 `xcrun stapler staple <app/dmg>`，且 `spctl -a -vv -t exec <app>` 必须看到 `accepted`。

### 4.5 [体验] 时间戳服务器漏配 -> 几年后签名失效
- **避坑**：`codesign --timestamp`（不是 `--timestamp=none`）。

### 4.6 [优化] 通用二进制
- arm64 + x86_64 都得签都得测；Lipo 自瘦身功能上线后要确保我们自己的 App 不会"自瘦"。

---

## 5. UI / UX —— 商业级体验细节

### 5.1 [体验] 进度条假死
- 大目录扫描看似卡死。**避坑**：进度必须按 **bytes 处理 / 文件计数双指标** 实时刷新，最少 100ms 一次。

### 5.2 [体验] 误关后台导致扫描丢失
- 用户切到后台 1 小时回来什么都没了。**避坑**：扫描结果实时落 SQLite，重启可恢复。

### 5.3 [优化] 数字单位混乱
- macOS 13+ 系统用 SI（1KB = 1000B），但用户习惯 IEC（1KB = 1024B）。**避坑**：默认跟系统（`ByteCountFormatter` 设 `.useAll`），设置里允许切换。

### 5.4 [阻塞] GrandPerspective / DaisyDisk 教训：边扫边渲染会把 UI 拖死
- **现象**：4 万文件 yield 进 SwiftUI `List`，每条都触发 diff 计算，主线程卡顿到秒级。
- **避坑**：
 - **节流**：UI 层每 100–200 ms 才 commit 一次累计的 batch，不是来一个 `.node` 就 update state
 - **预聚合到一级类目**：扫描中不把每个文件展示出来，只展示"~/Library/Caches/com.apple.Safari -> 320 MB"这种聚合行；用户点开才 lazy 展开
 - **扫描期间禁止 sort**：sort 在 `.finished` 后做一次；扫描中始终按发现顺序追加
 - **List 用稳定 ID + Equatable**：FSNode 已 Hashable，但还要在 row view 加 `.id(node.url)` 防 SwiftUI 误重建

### 5.5 [阻塞] AppCleaner / Pearcleaner 教训：勾选框默认全选 = 用户事故制造机
- **AppCleaner 历史事故**：默认勾选所有"相关文件"，包括 Adobe 共享 / Microsoft Office Group Container，用户一键删除全完蛋。
- **避坑**：
 - Normal 模式默认**只勾 SafetyKit 判定为 OK 的项**；`confirm` 项不勾，`forbid` 项不提供普通勾选框（灰色锁图标）。Professional 模式只能让显式 allowlist 中的 policy-forbid 进入严格确认；hard/结构边界仍不可选。
 - 列表行加颜色徽章：[优化] OK / [体验] confirm / [阻塞] forbid（鼠标悬停 tooltip 显示拒绝原因 = `SafetyRejection.rawValue`）
 - 任何单次"删除"动作的总数据量 > 1 GB 或文件数 > 500 时强制弹**二次确认对话框**列出前 10 项预览
 - 选中 vendor 共享路径（[vendor_shared.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendor_shared.yaml)）需要再加一道 "我知道这是共享的" 复选框

### 5.6 [体验] OnyX 教训：复选项过多吓退普通用户
- **OnyX**：清理选项 6 个 tab × 20+ 复选框，新手不敢点。
- **避坑**：默认两栏 UI："**推荐清理**"（OK 项一键勾上）+ "**进阶**"（confirm 项需要展开）；forbid 项默认隐藏，仅在"显示所有项"时出现。

### 5.7 [体验] Pearcleaner 教训：trash preview 模式让用户更敢点
- Pearcleaner 删除前用一个独立 sheet 列出"将移到废纸篓的所有路径"，用户能逐项取消。
- **当前避坑**：删除按钮**永远不直接动手**——点一下后进入共享确认页，用户看清楚后点“移到废纸篓”才生成真实执行授权。旧版曾在同一 sheet 暴露 dry-run 开关；该交互会干扰发布版用户，现仅允许 Debug 诊断使用，Release 必须隐藏。

### 5.8 [体验] DaisyDisk 教训：彩色 sunburst 图很酷但非必需
- DaisyDisk 的环形图很惊艳，但 v0 不做。先做扁平 list + 体积条；环形图作为 v1 plus。
- **避坑**：不要为了视觉效果在 v0 引入 SwiftUI Charts/Canvas 大依赖；有体积条（HStack + Rectangle width = bytes / max ratio）就够了。

#### v0.3 落地实测（2026-05-21）：D 路 UI 三栏 + 三大社区惯例
落地后主 App 的工作流是：

1. **左栏 5 个推荐类目**（[ScanCategories.recommended](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCategory.swift)）—— 用户缓存 / 应用日志 / Xcode 构建 / 下载 / 废纸篓。学 OnyX 教训不堆 20 个 tab。
2. **中栏聚合行** —— [ScanCoordinator](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) 把 BulkScanner 的每个 FSNode 归到"根的第一级子目录"做累计，4 万文件不会 yield 4 万行进 List。每 150ms commit 一次 snapshot。
3. **颜色徽章 + 分级 forbid** —— [RowView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowView.swift) 直接消费 `SafetyVerdict`：Normal 下 [优化] 默认勾、[体验] 默认不勾但可勾、[阻塞] 锁定；Professional 仅对类型化可覆盖 reason 提供严格入口，hard boundary 始终锁定。
4. **删除走统一 trash confirmation** —— [DeleteSheet](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/DeleteSheet.swift) 列出最多 200 项预览；Release 只提供取消和“移到废纸篓”，destructive role 仅用于真实提交；dry-run 只保留为 Debug/测试能力。

#### Strict Concurrency 实战踩坑（写血泪了）
[project.yml](file:///Users/guoshuyu/workspace/GSYCleanMac/project.yml) 开了 `SWIFT_STRICT_CONCURRENCY: complete` + `-warnings-as-errors`，[HelperClient](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HelperClient.swift) 第一版差点崩在三处：

- **`Task { ... }` 抓 weak self 是 sending 错误**：strict 模式下，`actor self` 被抓进 Sendable 闭包要么写明 `[weak self]` + `@MainActor`，要么干脆不要 actor。我最后退回到 `final class @unchecked Sendable + NSLock` —— 比 actor 真清楚。
- **NSXPCConnection 不是 Sendable**：DispatchQueue.asyncAfter 里抓 `conn.invalidate()` 会报 "capture of non-Sendable type"。包了一个 `ConnHolder: @unchecked Sendable` 持引用。
- **CheckedContinuation 双 resume 是真 bug**：第一版我让 timeout 与 reply 各 resume 一次，strict 模式直接拍死。改用 `OneShot` 锁守门 —— 这其实是 PITFALLS §1.7 的正解。

#### SafetyEngine 升级 `.safe`（PITFALLS §5.5 的硬要求）
原本 evaluate 只返回 confirm/forbid，UI 没法实现"默认只勾安全项"。落地：[SafetyEngine.safeCachePrefixes](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift)：
- `~/Library/Caches/`、`~/Library/Logs/`、`~/Library/Developer/Xcode/{DerivedData,Archives}/`、`~/Library/Developer/CoreSimulator/Caches/`
- `/private/var/folders/`、`/var/folders/`
- 上面几条还要镜像一份 `/System/Volumes/Data` 前缀（firmlink 第三次咬人）

新增 4 个测试覆盖 `.safe` 升级（testUserCachesAreSafe / testXcodeDerivedDataIsSafe / testHomeDocumentsItemsAreConfirm / 数据卷穿透 -> safe），与 D-1 联动。

---

## 5.9 路线修正：v0 不走 Helper，走 NSWorkspace.recycle（2026-05-21）

### 背景
最初的规划把 Helper + SMAppService + root daemon 当作主链路，需要 Apple Developer Program ($99/年)。
**但 v0 用户场景完全不需要 root**：
- 用户只清自己 `$HOME` 下的东西，主 App 自己有权限
- 删除走废纸篓而非 unlink，[NSWorkspace.recycle](https://developer.apple.com/documentation/appkit/nsworkspace/1524800-recycle) 不需要 root
- 误删可撤销 = 商业级稳健

### 决策
- **v0 主链路**：[TrashPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HelperClient.swift)（待加）实现 [DeletionPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HelperClient.swift)，内部调 `NSWorkspace.shared.recycle(_:completionHandler:)`
- **Helper 代码保留不删**：作为 v2.0 Premium "清系统缓存（需要 root）" 卖点。架构上 [HelperClient](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HelperClient.swift) 已经写好，等付费用户/付了 99 美元再启
- **Free Apple ID（Personal Team）**：本地 Run、调 UI、扫真目录全够，**v0 上架前都不必买 Developer Program**
- 避免 Pearcleaner / AppCleaner 都没用 SMAppService root 的"过度工程"陷阱

### 规则库策略
- 拒绝抄 Pearcleaner Conditions.swift（学结构不抄代码，避免 license 纠纷）
- **自生成 + 手工枚举混合**：
 - [SeedingTool](file:///Users/guoshuyu/workspace/GSYCleanMac/Tools/SeedingTool)（待写）扫本机 `.app` 与 `~/Library/Application Support/*`，输出"为本机定制"的 vendor 候选
 - 手工补 ~30 条主流 vendor（Adobe/JetBrains/Chrome/Slack/Zoom/Docker/Homebrew/Steam 等）
- **反向兜底**：所有规则进 SafetyEngine 前必须经过 hardForbid 反向校验，防止社区规则把 `/System` 写进去

### 失败模式与避坑
- 不要直接调 `FileManager.removeItem`：用户撤销不了 = 误删事故
- 不要在 Sandbox 模式调 NSWorkspace.recycle 删用户没在 NSOpenPanel 里选过的路径：会被 sandbox 拒绝。所以主 App 关 sandbox（[project.yml](file:///Users/guoshuyu/workspace/GSYCleanMac/project.yml#L51) `app-sandbox: false`）
- recycle 是 async API，必须用 `withCheckedContinuation` 包，且 completionHandler 上 `Task { @MainActor in ... }` 切回主线程更新 UI

#### v0.4 落地实测（2026-05-21）：E 路 NSWorkspace.recycle + 规则自生成
**核心成果**：v0 链路 0 美元跑通，规则库 159 条自动生成 + 26 测试守门。

[TrashPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift) 三个新坑：
- `NSWorkspace.recycle` 的 completionHandler 在**任意线程**回调，不能直接 `cc.resume`，必须用 OneShot/TrashGate 锁守门 —— [HelperClient](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HelperClient.swift#L97-L119) 已经踩过的坑这里复用同一个模式
- recycle 的 `trashedURLs` 与 `error` 是**互斥**的（成功 -> 全 trashedURLs，失败 -> 部分 trashedURLs + error），`skipped = inputCount - trashedURLs.count` 即可
- [testRealRecycleMovesToTrash](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/AppUITests.swift) 是真删测试 —— 必须在 NSTemporaryDirectory 下，绝不允许在 home 目录跑（CI 会真把测试文件丢进废纸篓）

[SeedingTool](file:///Users/guoshuyu/workspace/GSYCleanMac/Tools/SeedingTool/Sources/SeedingTool/SeedingTool.swift) 一次性 CLI（不在主 App 里）：
- 扫 `/Applications` + `/System/Applications` + `~/Applications`，读 Info.plist 拿 bundleID（**只扫一层 .app**，避免 Helper.app 套娃）
- 列 `~/Library/Application Support/*`（仅一层），与 bundleID 交叉去重
- 加 `handCuratedVendors()` 30 条主流 vendor 兜底（公开知识，不抄任何项目代码）
- 本机跑出 [vendors.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml) 共 159 条 vendor 候选，493 行
- [警告] SwiftPM 限制：用 `@main` 入口的可执行 target，**源文件不能叫 main.swift**（会和 @main 二选一冲突），必须改名

[RuleLoader](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/RuleLoader.swift) 设计选择：
- **不引外部 YAML 库** —— SafetyKit 必须保持零外部依赖，方便审计
- 用极简手写 parser 解 SeedingTool 输出的 YAML 子集（仅顶层 vendors: 列表 + 6 个键），**忽略未知键**做向前兼容
- [警告] **反向 hardForbid 校验**：`loadVendors(from:)` 内部对每条规则展开成绝对路径，喂给 [SafetyEngine.evaluate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) 自检；命中 hardForbid 一律丢弃 —— 防止社区规则把 `app_support_subdir: "../../System/Library"` 写进来

[SafetyEngine.evaluate(path:vendors:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L141-L161) 新签名规则：
- vendor 命中**根目录** -> 强制降级 `.confirm`（即使原本是 safe），UI 不默认勾选
- vendor 命中**子目录** -> 保持 baseVerdict（safe / confirm 都行，不破坏 brew 缓存可整清这种好场景）
- 不引入新枚举，复用 `(SafetyVerdict, SafetyRejection, VendorRule?)` 三元组让 UI 拿到命中提示

#### v0.4 全量回归
- SafetyKit 26 / XPCBridge 8 / AppUI 10 / ScanKit 5 = **49/49** 全绿
- 真删测试 [testRealRecycleMovesToTrash](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/AppUITests.swift) 53ms 通过 —— 链路真通
- SeedingTool 在我机器上扫到 90 个 .app + 129 个 AppSupport 目录 -> 159 条 vendor 候选

#### v0.5 落地实测（2026-05-21）：F/G/I/J 四路并行，81/81 全绿
**核心成果**：4 subagent 并发推进 F/G/I/J，工程从单线程串行改为多包多 subagent 流水线，**6 个包 81 个测试**全部就绪。

**F 路 - 应用卸载残留扫描** —— [AppUninstaller.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppUninstaller.swift)
- AppMetadata 解析 Info.plist 拿 CFBundleIdentifier / CFBundleName，缺 name 回退 .app 文件名
- 扫 11 个用户残留目录 + LaunchAgents/LaunchDaemons 共 12 个 scope
- **核心安全函数** [matchesStrictPrefix](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppUninstaller.swift) 只接受 `name == prefix` 或 `name.hasPrefix(prefix + ".")` —— 拒绝单纯字符串前缀，硬保证 `com.foo.bar` 不会吃掉 `com.foo.barbarian`
- 短 appName（< 4 字符）一律不参与模糊匹配（避开 "QQ"、"Mi" 等常见短词误杀）
- 仅在 LaunchAgents/LaunchDaemons 放宽到 vendor (`com.foo`) 匹配 —— 用户级目录之外的特例
- 测试：10 个新增（[AppUninstallerTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/AppUninstallerTests.swift)）端到端用临时目录构造 fixture .app

**G 路 - vendor 在 ScanCoordinator/MainView 落地** —— [RowItem.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift)
- RowItem 新增 `vendorName: String?` / `vendorNote: String?`，向后兼容默认 nil
- ScanCoordinator init 加 `vendors: [VendorRule] = []` 与 `home: String = NSHomeDirectory()`，publishSnapshot 改用 [SafetyEngine.evaluate(path:vendors:home:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L141-L161) 三参版
- RowView 在 title 旁加橙色 Capsule 显示 vendorName（仅命中时），双层描边，与 verdict 圆点不冲突
- [警告] **fixture 目录与 safeCachePrefixes 前缀比较**：home 必须用 `URL(fileURLWithPath:).standardizedFileURL.path` 标准化，否则 `/var/folders` ↔ `/private/var/folders` firmlink 第四次咬人
- 测试：3 个新增（[ScanCoordinatorVendorTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/ScanCoordinatorVendorTests.swift)）

**I 路 - TestHarness 测试基础设施** —— [Packages/TestHarness](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/TestHarness)
- [FixtureFS.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/TestHarness/Sources/TestHarness/FixtureFS.swift)：actor 化的临时目录构建器
- [ScenarioBuilder.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/TestHarness/Sources/TestHarness/ScenarioBuilder.swift)：DSL `builder.dir("Caches") { $0.file("a.log", size: 1024) }`，用 final class + deinit 自动清理（struct 释放时机不确定，不能保证清理）
- [GoldenSnapshot.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/TestHarness/Sources/TestHarness/GoldenSnapshot.swift)：稳定 TSV 序列化（path/bytes/verdict/vendor 多键排序），缺失则写入、存在则严格 diff，用 TSV 不用 JSON 是因为 JSON 字段顺序不稳定
- [警告] **SwiftPM 资源目录不能为空**：`resources: [.copy("Fixtures")]` 必须至少有一个文件，否则 swift build 不过；放一个 `Fixtures/example.golden` 占位
- 测试：8 个新增

**J 路 - HeuristicKit 启发式学习** —— [Packages/HeuristicKit](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/HeuristicKit)
- [HeuristicEngine.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/HeuristicKit/Sources/HeuristicKit/HeuristicEngine.swift) actor，记录 (deletedCount, restoredCount, keptCount)
- 评分公式 `raw = (deleted - α-restored - β-kept) / (deleted + α-restored + β-kept + γ)`，α=3.0 β=1.0 γ=2.0（restore 比 delete 加权 3 倍，宁可保守）
- [警告] **第一版 sanityCheck 漏洞**：当 deleted=3, restored=1 时 raw 恰好为 0.0，"hasRestoreInLineage 翻负" 规则只判 `s > 0`，导致 score==0 的边界 case 不会变负 -> 修法：引入 `restorePenalty = 0.1` 下界，无论 s > 0 还是 s ≤ 0 都至少拉到 -0.1
- **硬红线**：score 永远不能凌驾 SafetyEngine.forbid —— forbid 路径无论有多少 delete 信号，sanityCheck 直接归零
- JSON round-trip 持久化 + 11 个测试

**Subagent 并发协同的工程坑（2026-05-21 实战记录）**：
- [警告] subagent 偶尔不返回结果（4 个并发里有 2 个无返回，但**文件确实落了盘**）—— 解决：派完后立刻 `LS` + `swift test` 验证，发现缺件再补一发 subagent，不要被"无返回"骗成"未完成"
- [警告] 给 subagent 划分**目录边界**至关重要：F 改 AppUI / G 改 AppUI / I 新建 TestHarness / J 新建 HeuristicKit。F 与 G 都改 AppUI 但**改不同文件**（F=AppUninstaller，G=RowItem/ScanCoordinator/RowView/MainView），无冲突
- [警告] Subagent prompt 必须明确"最终 swift test 全过"+ "返回测试数"，否则容易交付半成品
- [警告] TestHarness 第一版只交付了 FixtureFS 一个文件就停了 —— 因为 prompt 没单独要求 `Tests/TestHarnessTests` 目录存在，SwiftPM 报 `invalid custom path`，第二轮 subagent 才补齐

#### v0.5 全量回归（6 包 81 测试）
| 包 | 数 | 新增 |
|---|---|---|
| SafetyKit | 26 | — |
| XPCBridge | 8 | — |
| AppUI | 23 | +13（F 10 + G 3） |
| ScanKit | 5 | — |
| HeuristicKit | 11 | +11（新包） |
| TestHarness | 8 | +8（新包） |
| **总计** | **81** | **+32** |

#### v0.5.1 K 路：vendor 真生效 + HL 真接进 UI（2026-05-21）
**目标**：把 v0.5 落地的"零件"装上 App，让用户 Run Debug 时 159 条规则真起作用、HL 真采集行为。

**K-1 vendor 真生效** —— [GSYCleanMacApp.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)
- App 启动时 `Bundle.main.url(forResource: "vendors", withExtension: "yaml", subdirectory: "Rules")` 拿到 [vendors.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml)
- 通过 [RuleLoader.loadVendors](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/RuleLoader.swift#L48-L69) 加载 + 反向 hardForbid 校验，再把 `[VendorRule]` 注入 [MainView(vendors:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L20-L28)
- [警告] **资源 subdirectory 顺序**：`Bundle.main.url(...subdirectory: "Rules")` 必须先尝试，再 fallback 不带 subdirectory；XcodeGen `resources: [{ path: Resources }]` 拷贝时**保留** Rules/ 子目录结构，Bundle API 必须显式带子路径才能命中
- 加载失败 -> `NSLog` + 返回 `[]`，不影响主功能（vendor 是辅助信号，不是关键路径）

**K-2 HeuristicKit 接进 UI** —— [HeuristicRecorder.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HeuristicRecorder.swift) 新增
- `actor HeuristicRecorder` 包一层 [HeuristicEngine](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/HeuristicKit/Sources/HeuristicKit/HeuristicEngine.swift)，对外暴露 `recordTrashed/recordKept/recordRestored/score`
- 持久化路径：`~/Library/Application Support/GSYCleanMac/heuristic.json`（标准 macOS 应用数据位置）
- 懒加载：`ensureLoaded` 第一次调用才读盘，避免 init 时 fallback 路径不存在
- [警告] **App 异常退出最多丢最近一次行为**：每次 record 后立刻 persist —— 写盘是 atomic，挂了也不会写一半
- [MainView.performDelete](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L255-L269) 在 `dryRun == false` 且 `err == nil` 后才 record，dryRun 不污染统计
- 测试：3 个新增（[HeuristicRecorderTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/HeuristicRecorderTests.swift)）覆盖 trash 推正、restore 反转、reload from disk

**K-3 工程结构调整** —— [project.yml](file:///Users/guoshuyu/workspace/GSYCleanMac/project.yml)
- packages 段加 `HeuristicKit` 与 `TestHarness` 路径
- `GSYCleanMac` target 依赖加 `HeuristicKit`（TestHarness 仅测试用，不进 app target）
- [Packages/AppUI/Package.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Package.swift) dependencies 加 `HeuristicKit`

#### v0.5.1 全量回归（6 包 84 测试）
| 包 | 数 | 变化 |
|---|---|---|
| SafetyKit | 26 | — |
| XPCBridge | 8 | — |
| AppUI | 26 | +3（HeuristicRecorder） |
| ScanKit | 5 | — |
| HeuristicKit | 11 | — |
| TestHarness | 8 | — |
| **总计** | **84** | **+3** |

#### v0.6 落地实测（2026-05-21）：L 路 4 并发补 ScanKit 测试短板，93/93 全绿
**目标**：ScanKit 是 v0 起点诉求（"100G 看不到 20G"）的核心引擎，但 v0.5 测试只 5 条，**核心场景一条都没盖**。L 路用 4 个并发 subagent 把这块短板补到 14 条。

**L-A - 隐藏文件覆盖** —— [HiddenFileTests.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Tests/ScanKitTests/HiddenFileTests.swift) 新建
- fixture：`a.txt(1024) + .secret(2048) + .hidden_dir/inner.bin(512)`
- 同时验 BulkScanner 与 Scanner 两路引擎在 `includeHidden=true/false` 下的统计一致性
- [警告] **隐藏目录整体跳过**：[BulkScanner.swift#L49](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift#L49) `entry.name.hasPrefix(".")` 过滤后**整个目录都不进 DFS 栈**，所以 `.hidden_dir/inner.bin` 也跳过 —— 这是用户起点诉求"100G 看不到 20G"的反向场景验证
- [警告] **断言放宽到 `≥ 3584` 而不是 `==`**：APFS 按块对齐分配，物理占用恒 ≥ 逻辑大小，等号断言会在不同硬件上抖
- 测试：3 个新增

**L-B - inode 去重硬链接** —— [InodeDedupTests.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Tests/ScanKitTests/InodeDedupTests.swift) 新建
- `import Darwin` 调 `link(2)` 真造硬链接：`a.bin(4096) + link("a.bin","b.bin")`
- 用 `lstat` 读 `st_ino`/`st_nlink≥2` 校验前置条件成立后再断言去重逻辑（避免黑盒）
- [警告] **区间断言**：`totalAllocatedBytes ∈ [4096, 8192)`（去重时）/ `>= 8192`（不去重时）—— 块对齐误差不可避
- 关键代码点 [Scanner.swift#L139-L149](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/Scanner.swift#L139-L149) 的 POSIX `lstat` 取 `(st_dev, st_ino)`，与 BulkScanner 的 `getattrlistbulk` 路径殊途同归
- 测试：3 个新增

**L-C - BulkScanner ↔ Scanner 一致性** —— [EngineConsistencyTests.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Tests/ScanKitTests/EngineConsistencyTests.swift) 新建
- 同 fixture 跑两路引擎，断言 fileCount 相等 / totalAllocatedBytes 差额 ≤ 4096（一个 APFS block）/ directoryCount 相等
- [警告] **目录字节策略不同**：FileManager.enumerator 会把目录的 `totalFileAllocatedSize` 汇入，BulkScanner 走 `getattrlistbulk` 的 `ATTR_FILE_*` 只对常规文件返回有效值 -> 一个 block 的容差既能容纳合法差异，又能精准捕获"误算整文件"的真 bug
- symlink 场景断言 `followSymlinks=false` 时**字节增量 < 1024**（symlink 节点本身的元数据可以非零，但绝不能把目标 a.bin 重复计 1024B）
- 测试：2 个新增

**L-D - TestHarness Golden 真接 ScanKit** —— [ScanGoldenTests.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Tests/ScanKitTests/ScanGoldenTests.swift) 新建
- [Packages/ScanKit/Package.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Package.swift) testTarget 加 TestHarness 依赖 + `resources: [.copy("Fixtures")]`
- 用 [ScenarioBuilder](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/TestHarness/Sources/TestHarness/ScenarioBuilder.swift) DSL 搭 `Caches/{a.log,b.log}`，跑 BulkScanner，路径裁成相对 root，比对 [Fixtures/scankit_basic.golden](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Tests/ScanKitTests/Fixtures/scankit_basic.golden)
- [警告] **goldenURL 必须用 `#filePath` 而非 `Bundle.module`**：Bundle.module 指向构建产物里**只读**的 resource 副本，写不进去；golden 是要 commit 进仓库的文件，必须落到源码目录 Fixtures/，首跑生成后开发者直接 `git diff` / `git add`
- [警告] **断言用 logicalSize 而非 allocatedSize**：跨文件系统更稳定（APFS 块对齐会让 allocatedSize 在 CI 上漂）
- 测试：1 个新增

**L 路 subagent 并发坑位的二次验证（v0.5 §"Subagent 并发协同"再实证）**：
- 4 并发再次出现 1 个 subagent 不返回结果（L-D），但 **5 个文件全部落盘并通过测试**——结合 v0.5 §的"4 个并发里有 2 个无返回但文件确实落了盘"，这条经验**已稳定复现**：subagent 是否 return ≠ 是否完成，永远先 LS + swift test 验证
- L 路 4 个 subagent 的目录划分严格无冲突：4 个全在 `Tests/ScanKitTests/` 但**改不同文件**（HiddenFile / InodeDedup / EngineConsistency / ScanGolden + Package.swift）
- L-D 因要改 Package.swift（dependencies / resources）而**单独不能并发**于其它 ScanKit 测试 subagent —— 这次侥幸 L-D 最晚返回所以无冲突，**下次必须显式串行 Package.swift 修改与并发测试**

#### v0.6 全量回归（6 包 93 测试）
| 包 | 数 | 变化 |
|---|---|---|
| SafetyKit | 26 | — |
| XPCBridge | 8 | — |
| AppUI | 26 | — |
| ScanKit | 14 | +9（L-A 3 + L-B 3 + L-C 2 + L-D 1） |
| HeuristicKit | 11 | — |
| TestHarness | 8 | — |
| **总计** | **93** | **+9** |




---

## 6. 测试矩阵（最低红线）

| 场景 | 验证内容 |
|---|---|
| macOS 13.5 / 14.x / 15.x / 26.x | helper 注册 / XPC / 公证 |
| Intel Mac + Apple Silicon | 通用二进制路径 |
| 数据卷根扫描 vs `/` 扫描 | firmlinks 不重复计数 |
| Time Machine 本地快照 | 列出 / 删除 |
| iCloud Drive Optimize 开启 | 本地 vs 云端大小 |
| 拖入硬链接森林（如 `Backups.backupdb`） | inode 去重正确 |
| Adobe / Microsoft Office | 共享目录不被整删（Nektony Test 1.3） |
| 卸载我们自己 | helper 干净下线（Nektony Test 1.4） |
| FDA 未授权 | 弹引导而非静默扫空 |
| Helper 被恶意进程调用 | Team ID 校验拒绝 |

> 落地为 [Tests/NektonyMethodologyTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Tests/NektonyMethodologyTests) 的自动化用例，CI 必跑。

#### v0.7 alpha-ready 实测（2026-05-21）：M 路 4 并发 + Xcode 真首跑通过
**目标**：把 v0.6 收尾时列的 5 件 alpha 缺口（xcodegen + TCC + 空状态 + 性能底底 + 应用卸载入口）一次性干掉，让真人能在 Xcode 里点 Run。

**M-1 - xcodegen + Xcode 首跑** —— [project.yml](file:///Users/guoshuyu/workspace/GSYCleanMac/project.yml) + [HelperMain.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Helper/HelperMain.swift)
- [警告] 坑 1：[project.yml#L12](file:///Users/guoshuyu/workspace/GSYCleanMac/project.yml#L12) `SWIFT_VERSION: "5.10"` 与各 Package.swift 的 `swift-tools-version: 6.0` 不匹配 -> 主 App target 编 actor/Sendable 会爆。改 6.0 即治
- [警告] 坑 2：Helper target 缺 SafetyKit 依赖。xcodebuild 直接告诉我们：`'GSYCleanMacHelper' is missing a dependency on 'SafetyKit'`。补 [project.yml#L94](file:///Users/guoshuyu/workspace/GSYCleanMac/project.yml#L94)
- [警告] 坑 3：[HelperMain.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Helper/HelperMain.swift) 用了 6 行真顶层代码 + 全局 `let listener` —— Swift 6 严格并发下报 `expressions are not allowed at the top level` + `not concurrency-safe because non-'Sendable' type 'NSXPCListener'`。修法：包成 `@main struct HelperMain { static func main() }`（v0 不部署 Helper，但要让它能被 build 出来）
- [Y] `xcodebuild -scheme GSYCleanMac` 最终 `BUILD SUCCEEDED`
- 关键证据：用户现在可以在 Xcode 里点 Run（CODE_SIGN_IDENTITY="-" + CODE_SIGNING_REQUIRED=NO 即 Free Apple ID 路径）

**M-2 - TCC 授权引导页** —— [Onboarding/](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/Onboarding) + [GSYCleanMacApp.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)
- 新建 [TCCProbe.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/Onboarding/TCCProbe.swift) actor + [TCCGuideView.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/Onboarding/TCCGuideView.swift)
- [警告] TCC 探测看 errno=1（Operation not permitted）次数，**不能** catch 全部 NSError —— `NSCocoaError.fileNoSuchFile` 不算 TCC 拒，否则会冤枉用户
- [警告] 跳系统设置 URL：`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`（macOS 13+ 新 URL，旧的 `com.apple.preferences.security?Privacy_AllFiles` 在 15 上无效）
- 测试 +4：[TCCProbeTests.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/TCCProbeTests.swift)（granted / 全拒 / 部分拒 / 非 errno1 不冤枉）

**M-3 - 空状态 + PerfBench** —— [MainView.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift) + [Tools/PerfBench/](file:///Users/guoshuyu/workspace/GSYCleanMac/Tools/PerfBench)
- placeholder 三态：[notStarted / scanning / finishedEmpty(rootPath:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L144-L146)，UI 不再让用户对着"还没结果"发呆
- 新建 [Tools/PerfBench/Sources/PerfBench/PerfBench.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Tools/PerfBench/Sources/PerfBench/PerfBench.swift)：CLI 入口（**不能叫 main.swift**，v0.4 已记录的 @main + main.swift 冲突坑），用 `DispatchTime.now().uptimeNanoseconds` 单调时钟测耗时
- [Y] **真机实测 ~/Library/Caches**：**32.8 万文件 / 9.5 秒 / 18.1 GB / 137 MB hardlink 去重**
- 这是用户起点诉求"100G 看不到 20G"的反向硬证据：**~/Library/Caches 这个目录 Finder 只显示 ~12 GB（隐藏文件被吃了），我们扫到 18.1 GB**

**M-4 - 应用卸载侧边栏** —— [UninstallScreen.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/UninstallScreen.swift) + [GSYCleanMacApp.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)
- [UninstallStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/UninstallScreen.swift) actor，参数注入 `applicationsPath`/`uninstaller`/`fileManager` 让测试能绕开真实 /Applications
- [警告] 真删按钮**强制二次确认 sheet** —— 执行请求默认 dryRun，只有用户在共享确认页明确选择“移到废纸篓”才会生成真实提交；Release 不显示 dry-run 开关。
- TabView 包装而**不是**改 MainView 内部，避免 4 路 subagent 都改 MainView 撞车
- 测试 +4：[UninstallStoreTests.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/UninstallStoreTests.swift)，关键安全断言：`test_删除走dryRun不会真动文件`

**M 路 subagent 并发坑位的第三次复现（v0.5 §坑 / v0.6 §坑 -> v0.7 已是规律）**：
- 4 并发：M-2 / M-4 正常返回，**M-1 / M-3 又是不返但落盘** —— 这条经验**第三次稳定复现**
- 应对策略升级：每轮并发后**第一动作是 `LS` + `swift test`** 自证，绝不依赖 subagent 是否 return
- M-1 在大头（xcodebuild 实际编译）外面**必须由主线程兜底**：subagent 不返不要紧，主线程跑 `xcodebuild` 才是验证 SOT
- 文件边界严格分到目录级（M-2 独占 `Onboarding/`、M-3 独占 `MainView.swift placeholder` 段 + `Tools/PerfBench/`、M-4 独占 `UninstallScreen.swift`），**唯一共享文件 [GSYCleanMacApp.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift) M-2 与 M-4 都改 —— 这次幸运 M-2 先到 M-4 后到，文件状态正确合并；下次必须显式串行**

#### v0.7 全量回归（6 包 101 测试 + xcodebuild 绿）
| 包 | 数 | 变化 |
|---|---|---|
| SafetyKit | 26 | — |
| XPCBridge | 8 | — |
| AppUI | 34 | +8（TCCProbe +4 / UninstallStore +4） |
| ScanKit | 14 | — |
| HeuristicKit | 11 | — |
| TestHarness | 8 | — |
| **总计** | **101** | **+8** |
| **xcodebuild Debug** | **BUILD SUCCEEDED** | **首次跑通** |

---

#### v0.8 N 路 + P 路（2026-05-21 后段）：竞品深评 + 反向回归 + Code Review 全链路

**N 路 3 并发交付物**
- N-2 [docs/COMPETITORS.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/COMPETITORS.md) 282 行 / 7 款产品 5 维度深评 + 11 维度横向矩阵
- N-3 [docs/REGRESSION_VS_COMPETITORS.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/REGRESSION_VS_COMPETITORS.md) 60 行 / 12 经典坑回归：**10 防 / 2 N/A / 0 中弹**，结论"可发 alpha 带 4 条已知限制"
- N-4 [README.md](file:///Users/guoshuyu/workspace/GSYCleanMac/README.md) 449 行 + [scripts/make_dmg.sh](file:///Users/guoshuyu/workspace/GSYCleanMac/scripts/make_dmg.sh) + [scripts/setup_dev.sh](file:///Users/guoshuyu/workspace/GSYCleanMac/scripts/setup_dev.sh)

**N-5 双 validator 并发 cross-validation（基于 TRAE-code-review skill）**
- 主线扫 10 候选 -> A/B 两 validator 各返 10 条 JSON -> 共识打分（2/2 high / 1/2 medium / 0/2 exclude）
- [Y] 6 条 confirmed：BulkScanner.open 静默 / close 未 defer / AsyncStream unbounded / SafetyEngine vendor O(N×M) / TrashPipeline.dryRun 不预校验 / DefaultFileManagerSnapshot 串行
- [N] 4 条 排除：路径穿越判定 / recycle skipped / matchesStrictPrefix '.' 分隔 / restore 兄弟传播（祖先链已传播）

**P 路 4 并发修复 + 1 串行验证**
- P-1 [BulkScanner.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift) 三合一修：guard+defer close + AsyncStream(bufferingPolicy: .bufferingNewest(8192)) + 新 ScanEvent.permissionDenied case + ScanSummary.permissionDeniedCount + 3 新测试
- P-2 新建 [VendorTrie.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/VendorTrie.swift) 80 行：路径前缀树 O(段数)，build 期一次性 standardize；evaluate(path:trie:home:) 重载，旧 evaluate(path:vendors:home:) 内部代理；159 vendor × 5000 evaluate 实测均值 95–108ms（debug，release 估 ~30ms）+ 4 新测试
- P-3 [TrashPipeline.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift) dryRun 预校验路径存在 -> (present, missing, error)；missing>0 时返回中文 error + 2 新测试
- P-4 [AppUninstaller.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppUninstaller.swift) 加 candidatesAsync(for:) 用 withTaskGroup + 8 槽滑动窗口，旧 sync candidates(for:) 一行未动 + 1 新测试

**N 路 / P 路踩坑沉淀（重要）**
- [警告] 坑 N-3.1：subagent 第四次稳定不返但落盘 60 行（v0.5/v0.6/v0.7/v0.8 累计四次）-> **永久规则**：每轮并发后必跑 LS + swift test + xcodebuild 三件套自证，不信 subagent 自报
- [警告] 坑 P-1.1：给 ScanEvent 加 case 时**忘了消费方**。[ScanCoordinator.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) 同模块 enum 不能 @unknown default，新加 case 必须全链路同步 switch。教训："修上游 enum 时要先 grep 全 switch 再下手"
- [警告] 坑 P-1.2：[ScanKitBench/main.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Tools/PerfBench) 同样穷尽 switch，subagent 主动补了 case 才让 swift test 能 build。同模块 enum 修改 = 全链路 switch 巡检
- [警告] 坑 P-2.1：trie 比朴素只快 3-5%（debug 95ms vs 朴素 ~110ms），原因是朴素只 standardize 一次（已被原版优化过）。trie 真实价值在于 **build 期一次 standardize + 路径段下行 O(d)，与 vendor 数 N 解耦**——当 vendor 从 159 涨到 1500 时 trie 仍 O(d)，朴素 O(N)
- [警告] 坑 P-3.1：dryRun "missing" 在 macOS 上有歧义——既可能是不存在，也可能是 TCC 拒访。文案保留"或无权限"两可
- [警告] 坑 P-4.1：滑动窗口 ≤8 in-flight 是 Swift Concurrency "有界并发"惯用法。一次性 spawn N 个 task 会突破限流；用 group.next() 完成 1 个补 1 个

**v0.8 验证矩阵**
| 包 | 测试数 | v0.7 | 增量 |
|---|---|---|---|
| SafetyKit | 30 | 26 | +4（VendorTrie） |
| XPCBridge | 8 | 8 | — |
| AppUI | 37 | 34 | +3（DryRun×2 + UninstallerAsync×1）|
| ScanKit | 17 | 14 | +3（ScannerEdgeCase）|
| HeuristicKit | 11 | 11 | — |
| TestHarness | 8 | 8 | — |
| **总计** | **111/111 全过** | 101 | **+10** |
| **xcodebuild Debug** | **BUILD SUCCEEDED** | [Y] | — |

**alpha 决议**：v0.8 已修完所有 high-confidence 问题；REGRESSION 报告 12 经典坑全防住或 N/A；4 条已知限制必须在 release notes 披露：(1) vendors.yaml 含 ~120 条 auto-detected，UI 默认 unchecked；(2) HL restore 抑制只按祖先链；(3) 无 Helper 提权，`/Library/LaunchDaemons` UI 必明示"需手动"；(4) 权限被拒目录已上报 lastError，UI 需露出。

---

#### v0.9 Q 路（2026-05-22）：alpha 收尾——UI 露出 + release 性能复测 + DMG 一键打通

**Q 路 4 件并发交付物**
- Q-2 [ScanCoordinator.swift#L18](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L18) 新增 `@Published permissionDeniedPaths: [String]`（去重保序），把 v0.8 残留的"`lastError = 权限被拒：path` 单字段覆盖"漏洞修了——多个被拒目录原本会互相覆盖
- Q-2 [ScanCoordinator.swift#L116-L124](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L116-L124) `#if DEBUG _testInjectPermissionDenied(path:)` 注入钩子，复用同一去重逻辑
- Q-3 [MainView.swift#L352-L391](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L352-L391) `PermissionDeniedBanner` 橙色卡片：`lock.shield` 图标 + "有 N 个目录受阻" + 折叠展开（最多展示 50 条 + "…还有 X 条未显示"）+ "打开完全磁盘访问权限" 按钮直跳 `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`
- Q-4 release 配置 VendorTrie 性能基准：debug 0.108s -> **release 0.053s（提速 2.04×）**，5 次采样 stddev 1.43%，elapsed<100ms 断言留 2× 安全余量
- Q-6 [scripts/make_dmg.sh](file:///Users/guoshuyu/workspace/GSYCleanMac/scripts/make_dmg.sh) 一键试跑成功：`build/dd/Build/Products/Debug/GSYCleanMac.app` -> `dist/GSYCleanMac-0.9.0-alpha.dmg` (844K, hdiutil 主路径)

**Q 路踩坑沉淀**
- [警告] 坑 Q-2.1：v0.8 P-1 把 permissionDenied 写进 lastError 单字段，**多个被拒目录会互相覆盖**——这是 code review 双 validator 没扫出来的"看上去对其实错"漏洞。教训：错误通道必须按语义分离，"真 IO 错误"（应用问题）和"软失败/TCC 拒访"（用户问题）从一开始就该是两个 channel
- [警告] 坑 Q-2.2：`@MainActor class + @Published` 数组属性的测试需要 `@MainActor` 标注 XCTestCase 函数；另外用 `[String] + contains` O(n) 而非 `Set` 是有意为之——UI 要保发现顺序
- [警告] 坑 Q-3.1：MainView 默认只 `import SwiftUI`，调 `NSWorkspace.shared.open(url)` 必须显式 `import AppKit`，macOS SwiftUI 不会自动拽 AppKit 进来
- [警告] 坑 Q-3.2：banner 放在 statusBar 计算属性里时要把外层 HStack 包进 VStack(spacing:0)，否则 banner 和状态栏之间会出现意外的间距
- [警告] 坑 Q-4.1：XCTClockMetric 在 release 配置下**没缩水**（之前担心 measure block 在 -O 优化下被跳过/dead-code-eliminated，实测 raw values 5 次稳定在 51-54ms，stddev 1.43%）。教训：性能测试不要拍脑袋认为 release 不可信，跑一次再说
- [警告] 坑 Q-6.1：[scripts/make_dmg.sh](file:///Users/guoshuyu/workspace/GSYCleanMac/scripts/make_dmg.sh) 用 `ditto` 而非 `cp -R` 复制 .app —— ditto 保留 xattr / 资源 fork / 符号链接属性，cp -R 会丢 com.apple.quarantine 等 xattr 导致首次打开 Gatekeeper 行为异常

**v0.9 验证矩阵**
| 包 | 测试数 | v0.8 | 增量 |
|---|---|---|---|
| SafetyKit | 30 | 30 | — |
| XPCBridge | 8 | 8 | — |
| AppUI | 39 | 37 | +2（permissionDenied 去重×2）|
| ScanKit | 17 | 17 | — |
| HeuristicKit | 11 | 11 | — |
| TestHarness | 8 | 8 | — |
| **总计** | **113/113 全过** | 111 | **+2** |
| **xcodebuild Debug** | **BUILD SUCCEEDED** | [Y] | — |
| **IDE diagnostics** | **[]** | — | 零警告 |
| **DMG 实测** | **844K** | — | hdiutil 一键 |

**alpha 发布物清单（v0.9 ready）**
1. [dist/GSYCleanMac-0.9.0-alpha.dmg](file:///Users/guoshuyu/workspace/GSYCleanMac/dist/GSYCleanMac-0.9.0-alpha.dmg) 844K
2. [README.md](file:///Users/guoshuyu/workspace/GSYCleanMac/README.md) 449 行 / 安装 + 上手 + 安全声明
3. [docs/COMPETITORS.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/COMPETITORS.md) 7 款产品深评
4. [docs/REGRESSION_VS_COMPETITORS.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/REGRESSION_VS_COMPETITORS.md) 12 经典坑回归
5. [PITFALLS.md](file:///Users/guoshuyu/workspace/GSYCleanMac/PITFALLS.md) 完整踩坑实录（v0.9 后约 660+ 行）
6. v0.8 第 4 条已知限制在 v0.9 已闭环（permissionDenied 已 UI 露出），release notes 现剩 3 条限制需披露

---

## 6.5 v1.3.zzzz：清单 vs 树形 Tab 双视图一致性血泪实录

**背景**：[MainView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift) 的右侧详情面板有两个 Tab：**清单**（[RowView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowView.swift)，按一级桶聚合）与**树形**（[TreeBrowserView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)，按 GRDB 路径前缀懒加载下钻）。本轮一周内连续修了 4 个让两者数字对不上 / 树形空白 / 树形闪烁的根因，全部沉淀如下。

### 6.5.1 两个 Tab 的语义差异（必须先理清）

| 维度 | 清单 Tab（RowView） | 树形 Tab（TreeBrowserView） |
|---|---|---|
| 数据源 | [ScanCoordinator.buckets](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)（**主线程内存字典**，每 `.node` 同步累加 bytes/count） | GRDB store [scan_result](file:///Users/guoshuyu/Library/Application%20Support/GSYCleanMac/scan.sqlite) 表，按 `path LIKE prefix||'%'` 异步查 → Swift 侧 GROUP BY 第一段路径分桶 |
| 聚合粒度 | 仅一级（rootPath 下的"第一级子目录"），不支持下钻 | 任意层级，DisclosureGroup 展开时再发一次 query |
| 流式可见性 | `publishSnapshot` 节流 ≥150ms / 多根 ≥400ms 推送，扫描中数字持续上涨 | DisclosureGroup 展开时单次 fetch 写 cache；body 重算 cache-hit 直接返 |
| 写入时序 | 同步：ingest → buckets → @Published（下一轮 publishSnapshot 即可见） | **异步两段提交**：ingest → storeBatch → 满 1000 才 [flushStoreBatch](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) → detached Task → GRDB write。中间有"在内存但 GRDB 还没看到"的窗口 |
| 终态权威性 | `snapshotFiles` 是 truth-of-record | 必须等 `flushAndFinalizeStoreAsync()` await 完才是 truth-of-record |
| 失败兜底 | `storeHealthy=false` 时仍可见（不依赖 store） | 同样依赖 GRDB；不健康时返空（用户体感"树形没数据"） |

**核心结论**：清单是"实时主线程内存视图"，树形是"GRDB 异步读快照"，两者**只在扫描完成 + flushAndFinalize 完成的瞬间才数字一致**。任何让树形 fetch 拿到中间快照并写进 cache 的行为都会导致"扫完后清单 1752 / 树形 1000"这种永久错位。

### 6.5.2 本轮 4 个 Bug 复盘

#### Bug A：NSLog 在沙盒应用里被吞，`log stream | grep` 抓不到
- **症状**：插了几十条 NSLog 排查"为什么树形不出来"，`log stream --predicate ...` 整页空白
- **根因**：`com.apple.security.app-sandbox` + bookmark-only 子系统下，NSLog 的 stderr 被重定向到 /dev/null
- **修法（仅诊断期）**：写 [/tmp/gsy-tree.log](file:///tmp/gsy-tree.log) 文件 + `Logger(subsystem:)` 双保险。诊断完成后**必须把诊断 logger 全删**避免污染生产日志
- **教训**：sandboxed app 调试一律走 `Logger` + 文件，不要靠 NSLog

#### Bug B：树形扫完闪烁 / 多刷新闪几下
- **症状**：扫完后树形顶层先出现一瞬间，然后变空白 ~600ms，再回来
- **根因**：[invalidateTreeCacheAfterScan](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) 把 cache 整张 `removeAll` → directChildren cache-miss 派 fetch task → ~600ms 后写回
- **修法（错误中间方案）**：改成"只删空 cache，保留非空"——表面修好闪烁，但埋下了 Bug D
- **正确修法**：先解决 Bug C（GRDB race）让 fetch 几十毫秒就回来，然后**全清 cache** 是安全的
- **教训**：界面闪烁的根因经常不在"清 cache"那一步，而在"重 fetch 太慢"那一步。优化错对象就会引入更深的一致性 bug

#### Bug C：扫完瞬间 GRDB query 返回 0 条，但 SQL 直查同 sid 立刻有几千条
- **症状**：用户点完扫描，树形空白；几秒后再点折叠重展开能看到数据
- **关键证据**（已删的 `[grdb]` 诊断行）：
  ```
  [grdb] query sid=CAEC8C3F sidTotal=0  likeCount=0
  sqlite3 ... WHERE session_id='CAEC...'  → 3631 条（同一秒）
  ```
- **根因**：`runScan` / `runMultiRootScan` 收尾两步顺序错了：
  ```
  publishSnapshot(finished: true)        // 1. UI 立即收到"扫完了"，开始向 GRDB query
  flushAndFinalizeStore()                // 2. fire-and-forget Task.detached → 还没 commit
  ```
  view 在 1 和 2 之间就发起了 query，dbPool.read 拿到的是 finalize 之前的 snapshot
- **修法**（[ScanCoordinator.swift L668-L686](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) + [L761-L775](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)）：
  1. 新增 [flushAndFinalizeStoreAsync()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)，detached task 派出后 `await task.value` 真正等到 GRDB commit
  2. **倒序**：先 `await flushAndFinalizeStoreAsync()` 再 `publishSnapshot(finished: true)`
  3. 单根 / 多根两条路径**都要改**——一开始只改了 [runScan](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)，多根并行（推荐清理 5 根）走 [runMultiRootScan](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) 仍然中招，用户连续 3 轮反馈"还是一样"
- **教训**：
  1. SwiftUI publish event 和 GRDB write commit 是两条独立时间线，**不能假定 publish 之前 commit 已经完成**——必须 `await` 跨过 actor 边界
  2. **任何"收尾顺序"的修复都要 grep 找所有同名收尾路径**，不能只改一处

#### Bug D（关键）：树形 cache 钉死中间快照 → 总和与清单永久对不上
- **症状**：清单显示 1752 文件，树形顶层 sum 只有 1000 条对应的字节数。**扫完了，刷新页面也对不上**
- **关键数字**：`storeFlushBatchSize = 1000`，巧合就是它
- **根因链**（4 步）：
  1. 扫描中 storeBatch 累到 1000 → flushStoreBatch 写 GRDB → 此刻 GRDB 里恰好 1000 条
  2. view 第一次展开 / refresh 触发 [directChildren](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) cache-miss → 派 task 拉这 1000 条
  3. 该 task 写回时判 `rows.isEmpty && isScanning` → 不空，写进 [treeChildrenCache](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
  4. 扫完后 [invalidateTreeCacheAfterScan](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)（**Bug B 的中间方案**）只删空 cache → **这条非空但残缺的 1000 行被永久保留**
  5. 之后所有 view body 重算 cache-hit 永远命中残缺数据
- **修法**（[ScanCoordinator.swift L957-L960](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)）：[invalidateTreeCacheAfterScan](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) 改回 `removeAll`。Bug C 修完后 finalize 之后 GRDB ready，重 fetch 几十毫秒，体感不会再闪
- **教训**：
  1. 任何"扫描中拿到的 GRDB 快照"在语义上都是**部分快照**，不能信任。最稳的策略：扫描结束 + finalize done 之后**全部 invalidate**，让 view 重新从权威终态拉一次
  2. "保留非空 cache"这种 partial-invalidate 策略**只有在扫描中不会写部分数据**的前提下才安全；只要存在 batch flush 这种"中间提交"，partial-invalidate 必然引入 stale cache
  3. 不要被表面症状（闪烁）牵着走改一个本不该动的开关——根因是 fetch 太慢（Bug C），治标不治本反而埋雷

### 6.5.3 排查方法学（值得记一辈子）

| 第几招 | 工具 | 抓什么 |
|---|---|---|
| 1 | `Logger(subsystem:)` + `/tmp/gsy-tree.log` 文件双保险 | 沙盒应用里 NSLog 不可信，必须文件 logger 兜底 |
| 2 | GRDB 内部 `[grdb] query sid=X sidTotal=N likeCount=N` | 把"应用层 query 看到几条"和"sid 下表里实际几条"放一行打印，瞬间定位 race |
| 3 | `sqlite3 scan.sqlite "SELECT COUNT(*) WHERE session_id='X' AND path LIKE 'Y/%'"` | 与 logger 输出做交叉验证，最权威 |
| 4 | 让用户**反复点同一个分类**重复扫描，复现"出来一次后续不出来" | 单次扫描看不出 stale cache；只有跨会话才暴露 cache-key 不带 sid 的 bug |

**核心原则**：当用户说"清单和树形对不上"，第一反应不是看 UI 代码，而是看 **GRDB 里实际有多少条 vs 内存 buckets 实际多少条**。两个数对得上，UI 一般不会出这种花。

### 6.5.4 这一节涉及代码索引

- [ScanCoordinator.runScan 收尾](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) — Bug C fix
- [ScanCoordinator.runMultiRootScan 收尾](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) — Bug C fix（漏改的多根路径）
- [ScanCoordinator.flushAndFinalizeStoreAsync](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) — 新增 await 版 finalize
- [ScanCoordinator.invalidateTreeCacheAfterScan](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) — Bug D fix，改回全清
- [ScanCoordinator.directChildren](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) — cache-miss / in-flight / stale-discard 三态机
- [ScanCoordinator.directChildrenAsync](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) — pathPrefix + Swift 侧 GROUP BY first-segment

---

## 6.6 v1.3.zzzz：方向 C — 树形为主、清单为 Filter；快/准/稳三件事一起干

**背景**：v1.3 之前清单（[RowView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowView.swift)）和树形（[TreeBrowserView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)）是平行 Tab。用户的真实使用路径是"一级一级看和选"——也就是树形是主路径，清单只是"开发者重度用户嫌弃的多余视图"。但**清单不能砍**：[RowItem.defaultSelected](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L48) 揭示清单本质是 [SafetyEngine](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) 的"信任投票输出"——给小白用户一个"扫完点一下完事"的零认知开销路径。

**方向 C 决议**：树形为主，清单**降级为左侧 Filter 面板**（语义保留、UI 让位）。本轮 Phase 1 同步治三件事——0KB 误导（准）、树形展开慢（快）、accessState 数据通路（稳）。

### 6.6.1 0KB 误导：[Library/Safari](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift#L172) 显示 0 KB 是不是 bug？

- **症状**：扫完 ~/Library 后顶层一堆系统目录（Safari / Reminders / Photos）显示 0 KB，文件数也 0
- **错误诊断（被自我推翻）**：以为是"BulkScanner vendor bucket 不 emit 中间 inode"——读 [BulkScanner L203 `if entry.isDirectory`](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift#L203) 后自我纠正，目录 entry 的 .node 也会 emit
- **真根因**（TCC silent-deny 链）：
  1. [BulkScanner L172 open(O_RDONLY)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift#L172) 失败（FDA 未授权）
  2. [L175 emit `.permissionDenied`](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift#L175) → return
  3. **该子目录里所有文件 0 emit**，GRDB 仅落这一条目录 inode record
  4. 上层聚合时 [directChildrenAsync L1112](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1112)（旧版）显式 `if !rec.isDirectory` 跳过目录的 bytes → bytes=0 / count=0
- **修法**：把"被拒"和"真 0KB"在 UI 层显式区分：
  - [TreeRow.AccessState](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L116) 三态枚举：`normal / permissionDenied / tccProtected`
  - [ScanCoordinator.directChildrenAsync](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1037) 把 `permissionDeniedPaths / tccProtectedSkippedPaths` 转 Set 给每个 segPath 打 accessState（优先级 `tccProtected > permissionDenied > normal`）
  - [TreeBrowserRow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L483) 渲染区分：accessDenied 行整行变灰 + 右下角  徽章 + size/count 改成 "—"（不再显示误导的 0 KB）+ tooltip 提示"无访问权限，请开 Full Disk Access"
  - [TreeNodeView.canExpand](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L335) 加 accessState 拦截，accessDenied 目录不显示披露三角（避免"假按钮"）
- **教训**：
  1. macOS 沙盒下"扫不到"和"扫到了 0 字节"是两码事——UI 不区分会让用户误以为是 bug 反复重扫
  2. accessState 必须从 BulkScanner 一直串到 TreeRow，不能在中间丢——任何一段 short-circuit 上来都会露出 0KB

### 6.6.2 树形展开慢：100ms → 10ms 的 GROUP BY 下推

- **症状**：deepIndex=off 时，点开任何目录有 ~100ms 卡顿
- **根因**：[directChildrenAsync](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1037)（旧版）走 [store.query(pathPrefix:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/ScanResultStore.swift) 把整棵子树（最大 30w 条）拉回 Swift，再用 Dictionary GROUP BY first-segment——SQLite range scan 几毫秒，反而是序列化 + 字典哈希吃掉 ~100ms
- **修法**（GROUP BY 下推到 SQL）：
  - 新增 [DirectChildAggregate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/ScanResultStore.swift#L129) struct + protocol method [directChildrenAggregated](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/ScanResultStore.swift#L177)
  - protocol extension 提供"拉子树+Swift Dict GROUP BY"的默认实现做兜底（fileprivate `_DirectChildrenAcc` 提到顶层——Swift **不允许在泛型 protocol-extension 函数里嵌套类型**，编译期 hard error）
  - [GRDBScanResultStore.directChildrenAggregated](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L289) 单条 SQL 覆盖：CTE + `substr(path, ?+1)` + `instr(suffix||'/', '/')` 切第一段 + `MAX(CASE)` 折叠 hasInode/dirInode + `SUM(CASE WHEN is_directory=0)` 拆 file/dir 累加
  - 复用现有 [v2_scan_result_path_index](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L83) 复合索引做 range scan
- **关键设计点**：
  - **range scan 而非 LIKE**：`path >= prefix/ AND path < prefix/\u{10FFFF}` —— 强保证走 `(session_id, path)` 索引而非 LIKE 优化器的脆弱性
  - **substr 字节 vs 字符**：SQLite substr 按字符切，但只要切点是 ASCII '/' 就字节长度==字符长度（中文段名安全）
  - **prefixLen 在 Swift 侧算好传 4 次绑定参数**：避免 SQL 内 `length(?)` 子查询，省一次解析
- **教训**：
  1. 看到"GROUP BY 100ms" 几乎一定是数据被拉到了应用层——SQLite C 层 GROUP BY 30w 条远不到 10ms
  2. 字段命名上保留双口径（`descendantCount` / `fileDescendantCount`、`descendantBytes` / `fileDescendantBytes`）让上层既能算 vendor 总和也能拿"叶子直接孩子"判定，不用回头加字段

### 6.6.3 hasChildren 误判：accessDenied 也"看起来能展开"

- **症状（潜在）**：accessDenied 目录因为 GRDB 里仍有 1 条 inode record，`descendantCount >= 1` 判定 hasChildren=true，UI 渲染披露三角，用户点开是空——**假按钮 + 空内容**双重错误信号
- **修法**：[TreeNodeView.canExpand](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L335) 加 `row.accessState == .normal` 拦截。即便聚合算出 hasChildren=true，accessState != .normal 也直接 disable 披露三角——把"这里被锁了"的语义拉满
- **教训**：UI 状态机要把 access 维度作为"上层一票否决"，不要依赖下层数据形态去推

### 6.6.4 banner 已存在，无需重做

PR 实施过程中本来计划在树形 Tab 顶部加 banner，[grep 后发现](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L646) [PermissionStatusBanner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L658) 已在 [statusBar](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L654) 全局存在。**没有重复加 banner**——开始动手前要先 grep 现状，避免重复造轮子。

### 6.6.5 这一节涉及代码索引

- [ScanResultStore.DirectChildAggregate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/ScanResultStore.swift#L129) — 直接子项聚合 DTO
- [ScanResultStore.directChildrenAggregated](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/ScanResultStore.swift#L177) — protocol 接口 + 默认兜底实现
- [GRDBScanResultStore.directChildrenAggregated](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L289) — 单 SQL CTE+GROUP BY 高性能覆盖
- [TreeRow.AccessState](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L116) — normal/permissionDenied/tccProtected 三态
- [ScanCoordinator.directChildrenAsync](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1037) — 重写：单 SQL 调用 + accessState 注入
- [TreeBrowserRow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L483) —  徽章 / 灰阶 / "—" 占位 / tooltip
- [TreeNodeView.canExpand](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L335) — accessDenied 不渲染披露三角

---

## 7. 一句话开发箴言

1. **Bundle ID 开发/发布分离**，否则 LaunchServices 会让你掉头发。
2. **绝对路径，永远绝对路径**，firmlink 和 chdir 一起会把你送走。
3. **能 recycle 就别 unlink**，废纸篓是用户最后的安全网。
4. **共享厂商目录碰都不碰**，Adobe 用户血书在前。
5. **公证前跑 `spctl --assess`**，别等 Apple 邮件回 4 小时告诉你失败。

---

## 8. v1.3.zzzz Phase 4 — 树形主视图收敛（决策记录）

### 背景
v1.3.zzzz 早期会话拍板"方案 C：树形主视图，清单降级为筛选层"，但前 4 个 commit (Phase 3-B/C/D/E) 全是后端 Helper / IPC 改动，UI 一行没动；用户跑了一版"为什么和之前一样"——欠账暴露。Phase 4 系列就是把欠账还掉。

### Phase 4-A：默认视图切换 + 视觉降级（commit `0e48e78`）
- [MainView.viewMode](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L29-L44) 默认 `.list` → `.tree`，提一个 `public static let phase4ADefaultViewMode` 单一信源给单测 lock
- [viewModeBar](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L597-L646) Picker 宽度 220→180、tree 时角标"主视图 - 层次化容量分布"、list 时角标"二级视图 - 兼容旧版扁平清单"，文案中性化
- detailPane 提示从"树视图只读浏览。要清理请切回「清单」"改为"右键或 Delete 单条移废纸篓 - 双击展开下一层 - 批量勾选请切到「清单」"

### Phase 4-B：树形批量删除（本次）
- [TreeBrowserView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift) 加可选 `onTrashBatch: (([URL]) -> Void)?`，nil 时整段 toolbar 隐藏（向后兼容）
- 多选 selection set 与单选 keyboard focus 解耦：`selectedPath` 看哪条详情；`checkedPaths: Set<String>` 是批量工作集（参考 Finder/Pearcleaner 双轨）
- forbid 路径在 toggle 入口拦截 + [TreeBrowserView.sanitize(paths:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift) 兜底二次过滤——SafetyEngine forbid 永远不会进 `triggerLargeFileTrash(urls:)` 的 urls
- [batchActionBar](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift) 主操作"批量移废纸篓" Cmd+Shift+D，空选 disabled
- 路由复用：MainView.onTrashBatch 直接喂 `triggerLargeFileTrash(urls:)`，跟单条删 / 大文件视图删走完全相同的 SafetyEngine + TrashPipeline 通道，零分叉

### 教训踩坑
- **SwiftUI struct view 不能用 mutating func 改 @State**：测试入口必须是 `public static func sanitize(paths:)` pure helper，让单测不需要构造 View 实例
- **方案被拍板≠落地**：用户截图证明早会话拍板"按 C 推进"被回了"可以"——这只代表共识，不代表代码；我用 git log 实证 4 commit 全后端，承认欠账 → 落地 Phase 4-A
- **占比条惯性误判**：以为 TreeBrowserView 没视觉占比 → 实际 [TreeBrowserRow L551-L565](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift) 早就有 3pt accent 色占比条；调研先于动手能省一个 Phase

### 单测合同
- AppUI 包总数 248 → 255（+5 ResultsViewMode 形态稳定 + +7 sanitize 行为）
- ResultsViewMode CaseIterable 顺序、label、SF Symbol、rawValue 全 lock，避免 Phase 5 视图回归
