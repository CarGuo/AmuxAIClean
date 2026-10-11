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
 - **v2026.07.19 P1 防回归**：`.notFound` 表示查询失败且找不到 service；它既不是
   `.notRegistered`，也不是“仍在运行”，更不是一次 `unregister()` 失败。fresh/default-OFF 且
   没有任何历史 authority 证据时只能写结构化日志，不得在启动时弹“关闭失败”或要求用户打开
   登录项。用户主动关闭、系统明确 `.enabled/.requiresApproval`，或持久化证据表明曾注册时仍
   fail-closed；证据必须独立于 Toggle/最近启用时间，并且只有 current Agent 与所有 legacy
   identity 都明确 `.notRegistered` 后才能清除。用户提示写具体系统设置路径并指向 App 内日志，
   禁止裸露账户目录、raw Error 或 errno。

### 1.2 [阻塞] `Codesigning failure loading plist code: -67054 (errSecCSBadResource)`
- **现象**：仅在 macOS 13.0/13.1 出现，13.5+ 正常。
- **根因**：早期 Ventura 的 `smd` 对资源签名计算有 bug。
- **避坑**：
 - **v2026.07.16**：当前产品部署下限统一为 **macOS 13.5 Ventura**；这是避开 13.0/13.1 已知系统缺陷并覆盖 Ventura 用户的兼容基线。所有更高版本 API 必须走共享兼容层或明确 availability，不能再依赖 macOS 15 的隐含下限。
 - **v2026.07.17 防回归**：装饰性 API 也属于部署合同。`Animation.smooth/snappy`、symbol/focus effects、`openSettings` 和新式 `NSApplication.activate()` 不得因为“只影响动画/窗口”而裸用；统一进入 `PlatformCompatibility.swift`，Ventura 保留等价公开行为，较新系统再启用增强效果。
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

### 2.9 [阻塞] 裸扫描几十秒已完成，UI 却继续“扫描中”数分钟

> **v2026.07.16 事故记录**：详细证据、入口矩阵和验收门槛见
> [SCAN_PERFORMANCE_REGRESSION_2026-07-16.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/SCAN_PERFORMANCE_REGRESSION_2026-07-16.md)。

#### 症状与实证

- Large Files 扫描 HOME：`BulkScanner` 在 **37.31s** 内已遍历
  **3,272,465 files / 595,992 directories**，但 UI 到约 3m55s 仍只显示
  707,622 个文件和第一批 1 个候选，最后由用户取消。
- 紧接着的推荐扫描：最慢的 `~/Library/Caches` 裸遍历仅 **9.63s**，
  其它四根均小于 1s；下一个明确的扫描后 Tree prefetch marker 却在
  启动后约 **211.87s** 才出现，与“4 分钟才扫完”的交互观察一致。
- 同一套当时代码的无 SwiftUI `CoordinatorBench` 扫约 38.5 万个 Caches 文件
  约 7.2s 收敛。因此瓶颈不在 SSD 或 `getattrlistbulk`，而在 App 内的
  事件交付、MainActor 消费和 SwiftUI invalidation 竞争。

#### 根因

1. `BulkScanner` 产生数百万 `FSNode` / `.nodes` 事件，为了不少算而使用
   `.unbounded` `AsyncStream`。生产者几十秒完成后，未消费事件仍可以在内存中排队。
2. `ScanCoordinator` 是 `@MainActor`，历史路径在主线程逐节点做 path 投影、
   bucket 聚合、Top-N 维护、安全投影和快照发布。
3. 实际 App 还要同时做 SwiftUI diff/layout/render；主线程越慢，无界队列越大，
   又进一步延长取消和下一轮扫描的收敛时间。
4. `MultiRootScanner` 历史上再包一层事件流，并在 progress clock 里重复遍历
   node batch，使推荐/开发者多根入口更容易暴露同一架构缺陷。

#### 长期性能/安全合同

- **先决定消费者需要什么，再决定交付粒度**：
  - `.summaryOnly`：只需终态容量和完整性证据；
  - `.summaryWithProgress`：Workflow 等只需 summary、但用户必须看到真实长任务状态的入口；
    只发布节流后的绝对 bytes/files 和 terminal summary，不恢复 node/cache DTO；
  - `.topLevel`：默认列表/按需 Tree 入口，在 ScanKit worker 侧聚合扫描根的
    一级可见行；
  - `.largeFiles(minimumAllocatedBytes:maximumResults:)`：在 worker 侧过滤并只保留
    有硬上限的 Top-N；
  - `.fileCandidates(minimumLogicalBytes:)`：给 Duplicate 这类必须保留所有
    达标候选的后台消费者；终态携带候选和 typed completeness，不交付
    无关小文件的逐节点 DTO；
  - `.complete`：仅给确实需要全部节点的后台消费者、显式 deep-index
    调试/测试。**生产 UI 不得再把 `.complete` 直接接到 MainActor。**
- 投影在每个 worker 的目录局部先累计，目录结束后最多跨 actor merge 一次；
  禁止把“MainActor 每文件一次”换成“投影 actor 每文件一次”。
- 多根容量是**一次物理 allocation transaction**：所有根必须共享文件 `(dev, ino)`
  账本，跨根 hardlink 只计一份 allocated/logical bytes；目录回环账本仍按根独立，避免
  一个根吞掉另一个根的枚举和 scoped incomplete。v2026.07.17 起该共享账本采用分片锁，
  防止 4 根 × 多 worker 在单锁上串行化。并发下具体由哪个根承载该 inode 字节属于
  first-observer attribution，不保证单根归属稳定；所有根合计才是权威物理占用，UI 禁止
  事后按路径猜测相减。
- 扫描期可合并的只有**绝对 progress 快照**；终态 `ScanSummary` 是容量和完整性
  的权威来源。最终投影必须与 summary 来自同一轮枚举，并同时保留：
  allocated/logical bytes、file/directory count、hardlink dedup、
  `permissionDeniedCount`、`tccProtectedSkippedCount`、`incompleteIssues` 和
  `completionStatus`。
- 并发 worker 不得先从统计 actor 取出 progress、恢复后再各自 `yield`；这会让旧 snapshot
  晚于新 snapshot 到达。merge 与 progress publish 必须在同一个 actor turn 内有序完成；所有
  progress-capable delivery 在真实或 synthetic partial `finished` 前紧邻发布 summary 对应的
  最终绝对帧。上层非终态只推进单调下界，只有 terminal summary 可以权威替换。
- pathname 不是可冻结的目录身份。目录进入共享队列前必须冻结 `(device, inode)`；默认分支
  用 `O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC` 打开并 `fstat` 核对。仅显式
  `followSymlinks=true` 可跟随最终 component，且 link/target identity 都须在入队/打开边界复核。
  目录或 symlink 在排队期间被替换时只能报告 scoped incomplete，禁止扫描替换对象。
- 取消是独立终态：不生成假 incomplete，旧 generation 不得覆盖新页面；
  取消大扫描后立即开始另一入口必须有专门回归。
- 没有可信分母时只显示真实已扫字节/文件/已用时间；禁止为了 ETA 与
  正式扫描并发重走同一棵树。
- Tree 终态不自动 prefetch，只在用户显式展开时读直接子项；切换排序必须
  复用同一份测量结果，不得把 sort key 变化当 cache miss 重扫磁盘。
- **v2026.07.20 Tree 展开终态合同**：真实事故日志显示 `/Users` 的直接子项枚举约
  116ms，后续 3,130,624 文件的精确容量与排序则耗时 31.4s。浅层 identity 必须立即发布，
  不能用 deep 工作阻塞首帧；但 fetching/loading ownership 必须保留到 exact bytes、file count
  与当前排序原子提交，不能在指标仍 pending 时提前消失。普通全盘和开发者构建产物入口必须
  强制 `deepIndex=false`：浅层帧一次发布全部直接子项，不能泄漏到下面的 64 行预览分支；超过
  64 个直接子项的产品入口 fixture 必须同时证明完整行数、`fetching=true` 且后台 enrichment
  仍由同一 owner 持有，并在 exact 终态证明 `fetching=false`。仅显式 deep-index 基准/fixture
  的已有 `childEdges` 完成索引第一帧
  必须非空，但 SwiftUI getter 也不得因此遍历、materialize 或 sort 任意宽
  `childEdges[parent]`：cache miss 最多检查 128 个 identity、生成 64 个真实预览行，并把预览
  独立于权威 children cache；同 path/sort/source revision/generation/locale 的后续 getter 必须
  O(1)。父节点在后台完整投影提交前保持 loading，不能进入删除等破坏性动作；切换 sort 的
  exact-cache miss 只能暂时复用已有完整顺序并派发后台排序，禁止在 getter 对宽数组 `.sorted`。
  单点展开/收起只 patch 对应连续 segment，且新交互不得等待被取消的旧 projection。任务
  ownership 只能影响所属 path，无关 path 的开始/结束不得让当前 Tree projection 判 stale。
  回归测试必须覆盖 100k fan-out heartbeat、有界首帧/重复 getter、切 sort、终态全局排序、
  revision/cancel 与删除 authority，禁止用定时轮询弥补丢失的终态通知。
- 同一个全盘会话必须冻结一份可双向投影的物理/公开路径合同：容量、TCC、Tree、
  incomplete/permission 都使用公开命名空间，真正枚举前才逆投影到 Data 卷。
  禁止各层自行拼接前缀；尤其 Data 根 fallback 到 `/` 时必须走 POSIX join，不能产生
  `//System` 后被一级 bucket 静默丢弃。否则 `/Users` 行既无法命中 Data 卷后代的删除拒绝，
  `/System` Tree 还会重新进入错误物理根。

#### 生命周期与生产者所有权（v2026.07.17 补充）

- **页面、模式和扫描入口切换都是扫描所有权边界**：离开当前页面/模式时，必须
  取消它拥有的进行中扫描；进入专业扫描页前也必须先取消普通扫描，禁止让旧入口
  在不可见页面继续争抢磁盘、MainActor 和发布通道。已经完成的主扫描快照属于
  用户结果，不得因离开 Tree 或切换展示方式一并清空。
- Tree 的按需展开、排序测量等属于**依附于页面的瞬时工作**。Tree 消失或主结果
  revision 改变时，应取消这些 transient task，并同时旋转 generation 阻止迟到写回；
  已完成的主扫描 snapshot、completeness evidence 和可复用 cache 必须保留。若下一轮
  会复用同一重 I/O producer，则还必须等待上一轮收敛后再启动，禁止两轮叠加扫盘。
- `AsyncStream` consumer Task 结束不等于 detached filesystem producer 已退出。可替换的
  扫描流必须显式持有 producer session：取消时同时 cancel producer，并在释放下一轮所有权前
  await producer termination；只等待 coordinator consumer 仍可能让旧 walker 与新扫描重叠。
- **v2026.07.19 Tree 租约回归红线**：Tree 测量身份只包含 standardized public path 与
  physical path，sort 纯属展示，不得生成另一轮磁盘测量。shallow 直接子项、deep
  `ScanSession` 和显式 indexed-subtree refresh 都必须在创建真实 producer 前登记路径租约，
  并以组件边界判断 same/ancestor/descendant；`/Users2` 绝不能被 `/Users` 误伤。只有重叠路径
  等待真实 producer termination，无关路径可并发；Tree-to-Tree 禁止重新接入全局 primary
  settlement。cache 写回、TreeRow 映射、排序、locale/verdict 投影和 COW retirement 必须在租约
  外；浅层完整枚举写回后 identity 立即可见，但 loading 必须与 deep exact measurement 同生共灭。
  primary cancel 必须
  原子关闭新租约准入、取消 pending/active producer 并等待快照内真实生产者退出；presentation
  owner 不得成为 barrier。对应回归至少覆盖不同 sort、祖先/后代、物理别名、无关路径、字符串
  前缀、pending cancellation、gate permit、cancel-all drain 与 presentation-only owner。
- 专业页面若自行拥有 producer（例如应用占用、卸载残留或工作流扫描），重新加载、
  离开页面或开始下一轮前必须先 `cancel` 并 `await` 上一 producer 收敛，再启动新的
  重 I/O。只递增 revision 而放任旧 producer 在后台继续遍历，不是生命周期隔离。
- 同步文件系统 snapshot（包括不可协作取消的 `FileManager` / POSIX 遍历）必须移出
  cooperative executor，在受控后台执行上下文中运行，并通过生命周期句柄支持
  `cancel + await`。结果必须携带 typed `complete / partial / cancelled` 终态及具体
  issues；partial 只能显示可信下界且默认不可提交删除，cancelled 不得发布成完成结果。
- **线程级 deadline 不是 syscall 硬超时**。v2026.07.17 Common App Cache 现场中，12s
  deadline 因线程卡在 `open(2)`，约 368s 后才被观察。需要硬上限的同步 I/O 必须放到可
  回收进程：父进程是唯一 `waitpid` owner，只有 WNOHANG 证明 child 仍归属当前 generation
  才能 TERM → KILL → reap；超时后从最近一个完整 group checkpoint 恢复，pending paths
  形成 typed incomplete。shipped App 的同可执行文件 worker 必须在 SwiftUI/NSApplication
  构造前分流，一次扫描一个 worker；不得用启动窗口后立即退出的壳冒充此边界或 C4。
- **同一可执行文件不等于可信调用者**。私有 worker flag 和同 UID 临时路径都不是能力边界；
  请求只能通过父进程显式继承、已 unlink 的只读 0600 descriptor 传入，child 必须复核实时
  parent generation、同 executable vnode、designated requirement 与 unique signing digest。
  `posix_spawn` 使用 `POSIX_SPAWN_CLOEXEC_DEFAULT`，只显式保留 stdin/stdout/stderr，禁止把
  App 的日志、数据库、目录或锁 FD 带入阻塞 worker。NDJSON 必须是严格单终态协议：exit 0
  不能替代 EOF、未截断、无坏帧且恰好一个 final 的联合证明；任何协议异常都只能形成 typed
  partial，协调器再依据最终 `ScanResult` 权威发布 terminal，旧 measuring 帧不得让 UI 继续 loading。
- 风险顺序不能被遍历去重反转。Common App Cache 只允许同 verdict 父子共享 forest，跨
  verdict 严格 `safe → confirm → forbid`；宽泛 confirm 父目录不得抢在具体 safe 子目录
  之前访问。运行状态不是扫描 admission gate，运行中 App 仍可扫描；它只参与既有删除前
  警告/强制确认合同。
- **App Data 保护从候选解析就开始**。macOS 对其它开发者的 `~/Library/Containers` 与
  `~/Library/Group Containers` 访问，可能在 glob、`lstat` 或 `open` 任一阶段同步弹系统窗；
  把阻塞工作放进 worker 只保护主进程，不会绕过 TCC。FDA 未被正向证明时，必须在触碰
  pattern 前按结构化 container boundary 形成 typed skip，继续扫描普通缓存；不得等 12s
  hard timeout 后把系统授权等待伪装成普通 I/O partial。glob/static ancestor 必须逐组件
  `openat + O_NOFOLLOW`，否则普通路径中的 symlink 仍可绕进 Containers。此边界同样与目标
  App 是否运行无关；已白名单路径必须在 TCC boundary 前排除，不能制造假 partial。
- DevArtifact 的“发现根”也是正式扫描热路径，不能用单线程 `FileManager.enumerator` 对 HOME
  每个普通文件重复做 URL/resource-values bridge，再为 marker 二次读取父目录。v2026.07.17
  真实 C4 在 1,636,452 entries 上仅 discovery 就耗时 51.49s。目录发现必须复用 descriptor
  no-follow/frozen identity + `getattrlistbulk`，每个父目录一次批量读取同时得到 child directory
  与 sibling marker，并由统一介质并发策略调度；媒体库 package 在入队前按既有 TCC 业务范围
  剪枝。timeout/maxHits 仍只能产生明确 partial，不能用于制造“快”的完整结果。
- 多根性能统计不能用“总耗时 - 最慢单根 `ScanSummary.elapsed`”推导 UI drain。Sliding window
  排队的 root 尚未开始单根计时，Developer discovery 也发生在 MultiRoot 之前；两者会被错误
  归责给 MainActor。root terminal 必须携带 producer 生成时冻结的绝对时间戳，协调器统一减去
  同一 scan session 的 `startedAt`；不得拼接两个相对时钟。只有最终 terminal 生成到 UI publish
  的尾差可记为 consumer drain；0-hit discovery 则使用 scanner 内部冻结的 elapsed 作为终态。
- 所有公开 `TimeInterval`/timeout 输入必须先在共享边界规范化：`NaN`、负数与零立即到期，
  `+infinity` 明确表示无实际 deadline，换算纳秒时饱和而不是溢出。直接写
  `elapsed >= duration` 会因 NaN 比较恒 false 把“有限扫描”静默变成无界任务。
- producer 的投影必须与实际 UI 消费合同一致：只需要容量、一级行、Top-N 或候选时，
  就在 worker 侧生成对应的有界投影。权威 terminal summary 必须拥有独立、可收敛的
  交付路径，绝不能排在数百万个逐文件事件之后；否则“扫描器已完成、UI 仍 loading”
  会在任何新入口重新出现。
- 渐进式 producer 的“交付阶段”和“证据完整度”必须是两个字段。v2026.07.17 的
  App Footprint 用 `deliveryPhase=intermediate/terminal` 表示是否仍有后续更新，
  用 `isComplete` 表示容量是精确值还是可信下界；partial terminal 也必须结束进度，
  intermediate 则不得提前移出 pending。禁止再用一个 `isComplete=false` 同时表达
  “仍在扫描”和“扫描已结束但不完整”，终态之后也不得接受迟到中间态倒退 UI。
- 需要按 inode 做 hardlink 归属时，不等于必须把每个普通文件都常驻字典。v2026.07.17
  的 DerivedData snapshot 先读取 `st_nlink`：已登记 identity 必须先查 ledger，防止扫描中
  其他链接被删除后同一 inode 降为单链接而重复计量；首次观察即为单链接的文件立即累计，
  只有真实 multi-link identity 才进入 `(device, inode)` ledger。稳定目录下这会保留精确
  去重/跨项目唯一归属，同时避免内存随全部普通文件线性增长。反向竞态——首次观察为单
  链接、扫描中才新增 hardlink——无法在不保留全部 inode 或使用文件系统快照的前提下强
  保证；live scan 不是原子 namespace snapshot。修改此路径必须同时回归普通文件 ledger
  为 0、跨项目 hardlink 仍只计一次，并在高频变化 C4 中记录容量漂移。
- `NSWorkspace.icon(forFile:)` 等看似 UI 的 helper 也可能触发 LaunchServices 和 bundle
  metadata I/O，禁止直接放在会反复重算的 row body 中。cache miss 也不能同步留在 MainActor：
  使用系统明确允许跨线程读取的 API，在受控 utility worker 中加载，并只把冻结的结果交回
  UI。缓存、pending queue、active loads 都必须有硬上限、页面级生命周期和 reload generation
  失效；无界全局字典或无界预取只是把滚动卡顿换成内存/I/O 增长。
- **任何 MainActor 元数据 cache miss 都不能用“通常是亚毫秒”合理化同步 I/O**（v2026.07.18）。
  `FileManager.attributesOfItem`、`fileExists`、`lstat/stat` 在慢盘、卸载卷或系统服务等待时没有
  UI 延迟上限。Tree/list/detail 同步投影只能读缓存；miss 必须进入有硬上限且去重的后台 producer，
  在首次物理 touch 前执行 TCC hard-skip，并用 session generation + source revision CAS 拒绝迟到
  结果。旧/新宽 COW cache 的最终析构同样要由后台 owner 完成，不能只把 syscall 移出去。
- `.topLevel` 的空间复杂度是 `O(真实一级可见行数)`，不是固定 Top-N。它已经与全部后代
  inode 数解耦，但若根目录自身有百万个直接子项，当前 `ScanSummary.topLevel([row])`
  完整数组仍必须承载百万行。没有先建立分页游标、稳定排序、完整容量与删除证据如何跨页
  保留的产品合同前，ScanKit 禁止静默截断；这类根只能作为明确的分页化后续项管理。
- typed incomplete 在 ScanKit 内部必须用 `Set`/hash index 去重，终态只排序一次；上层
  消费者也不得在每条 `.incomplete` 到达时线性查数组并重建全部 Tree 投影，否则大量
  issue 会退化为 `O(n²)`。兼容 companion event 与 richer typed event 应在索引键边界合并，
  不能靠反复全表扫描替换。v2026.07.17 起 AppUI 使用“稳定有序数组 + exact/scope 哈希索引”
  记录：rich evidence 原位替换 generic、不同 stage/errno 继续保留；公开 path 与 Tree
  投影只允许在 snapshot throttle、per-root publish、Tree 权威批次或删除安全读取边界提交。
  Tree 行查找使用 issue path `Set` 加预计算 strict-ancestor `Set`，复杂度按路径深度而不是
  `rows × issues` 增长。禁止为省一次 commit 让 SwiftUI row synthesis 反向写 `@Published`。
- 后台 presentation worker 若跨 `await` 读取 staging/COW 快照，**每一条直接 mutation 路径都必须
  推进同一个 source revision**（v2026.07.18）。不能只在常规 ingest helper 里 bump，而漏掉
  discovery partial/final、progress reconcile、finished/failed/fallback 等旁路；否则旧 DTO 会通过
  CAS 并短暂覆盖新状态。commit 至少复核 session generation、source revision 与相关 locale/sort
  token，且必须有确定性 stale-write 回归，而不能依赖下一次 throttle “稍后会补回来”。

#### 严禁的“提速”方法

- 不得把节点流改为 `.bufferingNewest` / 丢弃旧节点；这会重现历史上
  195k+ 文件场景容量少算的数据事故。
- 不得因 `CACHEDIR.TAG` 而跳过内容。它是“可视为缓存”的分类信号，
  不是“允许少算容量”的许可。
- 不得通过调大 batch、调低 UI 刷新率或反复增加 `Task.yield()` 宣称根治；
  这些只改常数，没有消除 MainActor 的 O(全部节点) 工作量。
- 不得用 `du`、Spotlight 或独立估算值替换同一轮 `BulkScanner` 证据；
  这会破坏 allocated/logical、hardlink、TCC 和 partial 合同。

#### 防回归门槛

- 每次修改扫描、Observation/视图订阅、多根调度或结果投影，必须同时跑：
  1. 投影与 `.complete` 的容量/数量/完整性等价测试；
  2. 百万节点合成性能测试，验证投影有界、主线程不接收 node；
  3. Large Files 取消后立即推荐扫描的 generation/终态回归；
  4. `PerfBench` 裸扫描与 `CoordinatorBench` 端到端对比，不能只看其中一边。
- 自动化和 Debug build 最多是 C3；还必须在用户授权的一次持续 C4 中
  验证真实 Large Files、推荐扫描、取消后立即重扫、内存峰值和 UI 响应性。

---

## 3. 删除 / 安全判定 —— 用户数据丢一次就完蛋

### v2026.10.08 `7b96b02` 复审：路径、恢复和容量必须保留原始证据

- **正向安全规则不能无条件转小写**。大小写敏感卷上，`Library/Caches` 和
  `library/caches` 可以是两个目录。缓存前缀和 vendor literal/glob 的 `.safe` 匹配先做
  精确匹配，只有目标路径所在文件系统明确返回大小写不敏感时才接受折叠匹配；查询失败
  不得升级 `.safe`。保护性 forbid 维持保守匹配，不能借本次修复放宽安全列表。
- **Undo 不是清缓存**。完整 prune 已移除行、索引、聚合与 Top-N；解除 tombstone 不会把
  数据变回来。恢复通知只发布实际 destination，重名恢复不能复活被占用的 original。
  在后台重测受影响父目录，按发起 scan session/revision 原子提交全部来源和 tombstone；
  保留原始扫描根，才能恢复已经整根 prune 的多根结果。断开的软链要用 `lstat` 验证目录项，
  不能用跟随 target 的 `fileExists` 判断恢复是否发生。通知路径的父级别名须通过同一
  `ScanPathNamespace` 映射回扫描命名空间，不能跟随最后一级软链或写死临时目录别名。
- **子树 refresh 不是新的容量域**。独立 inode 去重只能保证局部正确，不能直接把局部值
  加回原始全局统计。原始扫描保留目录直系合计及多链接 `(device,inode)` 的计费路径；
  refresh/prune 共用归属对账，原计费路径消失时把 allocated/logical 贡献转移到存活别名，
  文件数仍按普通文件目录项计数。普通单链接文件名不常驻账本。若两轮扫描之间新增硬链接，
  稀疏账本无法知道旧单链接路径的归属，必须使该容量基线失效并重放原始扫描计划，不能猜局部差值。
  多链接别名集合必须原位更新，不能每次追加都复制整个集合导致二次方增长。
  这不提供文件系统快照语义；扫描中持续变化的目录仍按 §2 的 live namespace 限制验收。
- **非目录不等于普通文件**。`FSNode.isRegularFile` 必须从 bulk/descriptor metadata 透传至
  coordinator、Tree、prune 和刷新；FIFO、socket、symlink 可显示，但不能凭“非目录”变成
  一个普通文件或进入大文件候选。
- **历史别名不是相互覆盖的记录**。初始化与 JSON 迁移统一合并 canonical alias 的删除、
  恢复、保留计数及最新时间；计数溢出饱和而不崩溃，不能因字典迭代顺序丢失恢复负反馈。
- **active version 用目录身份排除**。current 的 readlink 拼写可能不同于目录枚举名称，
  多跳软链也不能按名字保护。比较目录 `(device,inode)`、父目录身份，并在返回候选前重验
  current；symlink 子项和跨卷子项不作为旧版本候选。

回归入口：`FilesystemMutationReconciliationTests`、`FileAllocationSnapshotTests`、
`PermissivePathSemanticsTests`、`HistoryAliasMigrationTests`、`VersionsScannerTests` 与
`DeletionPublicationBoundaryTests`。测试必须先完整 prune 再恢复，覆盖所有 Tree 排序、
Top-N、多根结果、重名恢复、硬链接刷新顺序和计费路径消失；仅解除 tombstone 的测试不能证明 Undo 正确。
自动化与离屏原生表格仍只属于 C2/C3，真实回收/Undo 要另外完成持续 C4。

### v2026.10.08 删除成功后 Tree 仍显示旧行：发布边界事故

- 现场 `dryRun=false` 且 `moved=1`，权威 prune 已提交；最后一次 Tree projection 却因
  `source_current=false` 被拒绝。根因是 structural/tick 通知先发布，source revision 后递增，
  同步订阅冻结的 source 因此必定过期。children-cache 入口曾修正同类问题，但未覆盖另外
  两条共享通知入口。
- 另一条 receipt 快速删除链路在 `@Published` 的 willSet 回调中重读 revision，取得旧值，
  导致 worker 完成后也被 CAS 丢弃。回执发布必须携带同一不可变 matcher/revision；订阅方
  消费 emitted value，不能忽略参数再读属性。保留会话/revision 校验，禁止放宽 CAS 或增加重试点击。
- 验证不能只在 `await pruneDeleted` 后检查数组。必须在真实 publisher 回调内冻结 source，
  验证后台投影仍可提交，并把 production Tree 挂到 NSHostingView/NSTableView，验证回执到达后
  无额外交互即移除行。离屏原生集成属于 C2，真实 App 回收/Undo 仍单列 C4。
- 完整成功使用上下文内提示，异常终态保留详情 sheet。成功弹窗的 remount 曾偶然触发重建，
  不能把它当成同步机制。详细原因、入口审计和运行证据见
  [删除回执与呈现回归记录](docs/regression/DELETION_PRESENTATION_2026-10-08.md)。

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

### 3.9.1 [P0] 包测试不得继承生产 Trash 恢复域

- **现象**：`swift test` 的真实临时文件回收用例使用裸 `TrashPipeline()`，却继承 production
  pending ledger、completion journal 与 `UndoHistoryStore.shared`。测试 callback 于是留在用户
  Application Support；下一次真实删除在提交前被恢复闸门阻止，UI 又把它错误呈现成阻塞结果框。
- **根因**：只把被删除文件放进 `NSTemporaryDirectory()`，没有隔离删除事务自身的持久化 owner；
  coordinator/ViewModel 的 `.shared` 默认参数还允许 scripted moved pairs 直接写用户 Undo。
- **v2026.07.20 防复发规则**：
  - 生产只能经具名 `TrashPipeline.production(...)` 取得共享恢复域；裸 package initializer 只创建
    每实例 UUID 临时域。
  - ledger、completion journal、Undo store、active registry 与 recovery single-flight identity 是
    一个不可拆分 dependency domain，测试不得只替换其中一部分。
  - 所有可能持久化 moved pairs 的 coordinator / ViewModel 都必须显式接收 Undo store；禁止
    `.shared` 默认值。生产调用显式传 `.shared`，测试显式传临时 store。
  - public View 若允许注入 pipeline，必须把 Undo owner 作为同一个无默认依赖同时注入；不得在
    View 内硬编码 `.shared`，也不得在 scripted pipeline 旁边偷偷构造 production pipeline 并触发
    recovery prewarm。组合根的嵌套卸载、最近清理等导航页面必须继续透传同一对 owner；只读/恢复
    页面也不能自行回落到 `.shared`。App composition root 是唯一显式选择 `.shared` 的 UI 入口。
  - production ledger / completion journal 的无参构造只能由各自 `shared` owner 私有调用；测试
    必须显式提供临时 URL，pending ledger 还必须显式提供独立 active registry。
  - 回归必须同时断言测试 URL 位于 temp、完全不在任何 Application Support、两个 pipeline 的三套
    URL 全不同，并在测试前后核对生产恢复文件快照未变化。
  - 不得用 `ProcessInfo`、环境变量或 XCTest 类名猜测运行环境；构造 API 本身必须表达 production /
    isolated 的选择。

### 3.9.2 [P1] 审阅对象和保护目录必须贯穿最终提交

**v2026.09.06 审查补充（SR-01/SR-02）**：扫描 revision 不能证明某个路径仍指向用户审阅的
对象。修复必须在确认前冻结对象身份，在 durable reserve 后比较，并保留后续 claim fence；
不能只在最后一刻读取当前 inode。普通分析、Tree 和一键清理使用同一份
`ReviewedDeletionObjects`，无证据的 legacy 真删调用明确拒绝。固定凭据路径的保护还必须
向祖先闭合，否则 `.config/gh` 拒绝而 `.config` 可删会把保护内容一起移走。回归见
`SafetyReviewRegressionTests`、`CredentialAncestorProtectionTests`；真实测试始终使用隔离临时
文件和完整的隔离恢复域，不能用测试替身的成功响应代替真实对象替换验证。

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

### 3.12 [阻塞] Duplicate 的 `.full` 结果在确认后被替换或改写

- **现象**：扫描阶段算过完整 SHA256，但结果只保留 path/展示状态；用户打开确认页后，
  同一路径可被替换为另一 inode，或原 inode 内容被改写。最终 Safety 预检只证明路径目前可移动，
  不能证明它仍是扫描时那份重复内容。
- **根因**：把 hash 当成 UI 可靠度而不是执行能力；只冻结待删路径，没有冻结一份明确保留副本；
  重 hash 如果发生在 View 或持久 reservation 之前，仍留下新的检查—使用窗口。
- **v2026.07.17 合同**：
  - hash 必须通过 `open(O_NOFOLLOW) → fstat → read → fstat → lstat(path)` 产生；仅普通文件，
    且读前后 descriptor identity 与读后 pathname identity 完全一致才可发布。该顺序遵循
    [Apple Secure Coding 的 race-condition 指南](https://developer.apple.com/library/archive/documentation/Security/Conceptual/SecureCodingGuide/Articles/RaceConditions.html)。
  - `.full` 删除证据必须类型化携带完整 SHA256、逻辑大小及每个文件的
    device/inode/type/size/mtime/ctime；缺一项只能查看，不能生成删除目标。
  - intent 同时冻结所有待移动项和至少一份确定的 retained copy。最终执行先 reserve 待移动项，
    再在后台完整重 hash 两类文件；任何读取、身份或内容变化都释放未 claim reservation，
    返回 pre-submit block，禁止 receipt/结果页。
  - 重 hash 成功后，持久 ledger claim 继续比较 reservation 的 path/inode/type 身份；
    每个 batch/单项 retry 还要在串行提交队列中、ledger claim 前后同时重验本批 targets 的
    full-hash identity 与 retained copy 的 identity。完整 SHA 只做一次，避免把安全检查退化成
    `批次数 × 全量文件` I/O；size/mtime/ctime 的轻量 fence 覆盖普通原地写与路径替换。
  - GCD hash worker 不继承调用方 Swift Task 的取消上下文；必须把显式线程安全 cancellation token
    传入每个 read chunk，并在每次 concrete claim 前后复查。取消仍在 pre-submit 边界时必须释放
    reservation、零 recycle、零 receipt；progress 最多按文件/阶段有界发布，禁止按 read chunk
    淹没 MainActor。
  - claim 后到基于 URL 的 `NSWorkspace.recycle` 调用之间仍受 AppKit path API 的固有极小窗口约束，
    不能虚构成 descriptor-based 原子移动。实际动作仍且只能是
    [NSWorkspace.recycle](https://developer.apple.com/documentation/appkit/nsworkspace/recycle(_:completionhandler:))。
  - `.submittingToTrash` 只能在串行 worker 已完成 reservation、最终复核、claim 前后 fence 和
    durable claim 后，紧邻第一次真实 `NSWorkspace.recycle` 调用同步发布。rehash、排队、claim
    都仍是可取消的 pre-submit；异步 UI phase 可能滞后，不能充当取消或授权的唯一依据。
- **性能边界**：最终全量 hash 是确认后的安全成本，必须在后台执行；扫描 evidence 去重使用
  Set + 稳定数组，禁止在 MainActor 对每条 incomplete issue 做 `Array.contains` 形成 O(n²)。

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

---

## 9. v2026.07.17：扫描结果不能保存“已翻译字符串”

### 事故根因

应用内语言可在进程不退出、扫描结果不重建的情况下切换。旧链路在扫描阶段调用本地化，
再把结果写入 `RowItem.title`；随后 Tree、Smart Care、待处理、删除确认和 AI 又复制这个
`String`。因此设置切换语言后，长期存活的快照仍显示旧语言，只有重扫或重启才能恢复。

### 长期合同

- 扫描/聚合模型保存 `LocalizedTextDescriptor`（catalog key + typed arguments + verbatim
  用户数据），View/AppKit/tooltip/AI 请求在消费时用当前显式 `Locale` 投影。
- path、ID、verdict、rejection、完整性证据和删除授权永远不读取展示描述；切语言只能重排
  已有“按名称排序”投影，不能清缓存、重扫磁盘或改变删除候选身份。
- 文件名、版本号、App 名称和规则库原文必须是 `verbatim`。不能因为某个原文碰巧等于
  String Catalog key 就猜测它可翻译。
- `Resources/Rules/vendors.yaml` 属于受保护规则库。现有 common-app-cache 原文缺英文是
  规则数据迁移问题，必须在获得规则库修改授权后扩展双语 schema；禁止在 AppUI 写
  中文到英文的硬编码映射。本次只对运行时生成的标准 macOS App 缓存提供中英模板。

### 防回归消费点

主列表与名称排序、Tree SwiftUI/AppKit 行、详情、删除意图与运行中 App 冲突、Smart Care
checkpoint/预览/AI、待处理列表，以及 Workflow 文件系统删除投影，都必须携带同一份语义
描述。新增复制模型时，若只复制 `.title` 而不复制 `.titlePresentation`，即视为回归。

### 当前验证边界

v2026.07.17 本轮已完成 descriptor 传播与静态调用点审阅，新增实时切换/排序/复制模型测试源码；
遵循“先完整落地、后统一测试”，这些测试、全包 build 与真实 App 切语言尚未运行，当前只能记为
C1。受保护 rules 数据的双语迁移也仍待单独授权，不能把 catalog 路径通过等同于所有 vendor
原文已有英文。

---

## 10. v2026.07.18：Trash completion 与 Undo 不是两个松散异步步骤

### 事故根因

`NSWorkspace.recycle` 返回的 path pair 只说明系统回调观察到一次移动。若此后再从废纸篓路径
`lstat` 生成身份，callback 与 probe 之间的同名替换会把另一对象铸造成恢复能力；若先清 pending
ledger、再异步写 Undo，进程崩溃会留下“文件已经移动、历史和 pending 都没有”的不可恢复空窗。
旧 Undo JSON 又缺少跨进程 RMW，`open -n` 的两个实例会按各自旧快照 last-writer-wins。

### 长期协议

1. 删除 reservation 冻结统一 `TrashObjectIdentity` 与恢复 scope root；callback 只能把这份身份
   连同系统 pair 写入 deterministic-ID completion journal，禁止事后从 Trash pathname 重新铸造。
2. pending ledger、completion journal 与 UndoHistory 共用同一 durable replacement 原语，各自用
   独立稳定 `<file>.lock` 串行 RMW。`reserve` 与尤其是进入 AppKit 前的 `claim` 都必须完成
   temp-fd full write、file `fsync`、atomic rename、parent-directory `fsync`；仅有
   `Data.write(.atomic)` 不足以证明断电后仍能看到 claim，未耐久 claim 永远不能调用 recycle。
3. UndoHistory 使用独立稳定 `<history>.lock` 做 read-modify-write 合并；完成协议必须严格按
   `record + replay receipt → exact-attempt ledger ack → journal receiptPrunePending → receipt prune
   → journal remove` 单调推进。journal row/ID 是 receipt prune 完成前的最后证据，禁止先删 row 再做
   best-effort prune，否则固定上限会被 crash window 永久耗尽。任一步崩溃都由 journal 幂等重放，
   不能用“写失败也先解除 pending”换取表面可用。receipt ID 必须绑定 operation、attempt、
   normalized original 与 trashed path 的 opaque SHA-256，Undo pair 必须另存
   attempt ID 并在 decode 时重算验证；禁止把绝对路径写入可能长期残留的字典 key。旧 path-bearing
   ID 可严格迁移；缺 attempt 的旧 opaque pair 只能保留为无 receipt 的历史事实，等 exact pending
   journal 升级，不能猜测 capability。旧 plaintext receipt 要在 read/RMW 时清除。
4. callback ledger transition 必须返回 `applied / stale / storageUnavailable`；`stale` 只否定旧 ledger
   ownership，不能否定已经 fsync 的 callback journal fact，禁止据此删 journal。启动 replay 先按 exact
   operation+attempt 分组：live owner 跳过，dead/stale owner 都从 journal 幂等合并。整个
   `snapshot → Undo merge → exact ack → phase → receipt prune → remove → empty proof` 必须持有稳定
   `<journal>.recovery.lock`，不能只锁单次 JSON RMW；否则两个 App 进程会同时读到 replayable，迟到者
   重新制造 receipt。任一 journal group 未收敛时禁止运行可能清 ledger 的通用 reconciliation。
5. Undo 的普通 snapshot、journal merge 与 receipt prune 必须进入同一实例 FIFO persistence queue，
   每次都在 history flock 内把本次 mutation 应用到最新磁盘 union，再做全局 recency 与稳定 tie-break。
   禁止 stale 十条快照先占满 LRU 后把另一实例的新记录截成第十一条；revision 只用于拒绝旧 UI 投影，
   不能代替 mutation 串行化。
6. corrupt、permission/read failure、file-size 超限、单 record pair 超限与 journal write failure 都是
   类型化 UI 状态，绝不能投影成“暂无历史”。completion-journal blocked 与 history storage 状态正交，
   普通成功 save/bootstrap 或单个 receipt ack 不得清除；只有 journal 已证明为空、所有 replay/ack/remove
   完成、ledger authority 可读且 durable/local blocked 集合都为空的完整 terminal 才能恢复 ready。
   生产初始化、品牌迁移、读取、JSON decode 与 late-bootstrap 大合并在 utility task 完成；
   8 MiB store 与 10,000 pairs/record 是拒绝而非静默截断合同。
7. 恢复目标必须仍是删除时 scope root 的严格后代。逐级目录通过 fd-relative `openat` +
   `O_NOFOLLOW` 打开/创建并复核设备，最终提交用 `renameatx_np(RENAME_EXCL)`，永不覆盖后来出现的
   同名项目。
8. callback 已观察与 `undoJournalBlocked` 不是两个可分离的 ledger 步骤。callback journal 写失败时，
   `callbackObserved + journalBlocked 精确路径` 必须在同一把 ledger 锁、同一次 RMW、同一次 durable
   replace 中提交；禁止先写 callbackObserved 再补第二次 transition，否则两次写之间崩溃会永久丢失
   Undo 失败证据。
9. completion-journal health 必须由所有 `operationID + attemptID` 的权威 blocked 集合推导，禁止用全局
   Bool，也禁止让操作 B 的 save、receipt prune 或 ack 清除操作 A。ledger 无法完整读取时是 authority
   unavailable，只能保持 blocked；进程内 callback settlement 另有 local-unsettled 集合，空 ledger
   snapshot 不能清它。非结构化 MainActor 投影必须携带单调 revision，较新的 terminal 永远不能被迟到
   pending 覆盖；重启后再从 reconciliation 的完整集合恢复 durable 投影。
10. callback transition 返回 `storageUnavailable` 时，活 owner 不能等待进程重启才收敛。必须在同进程按
    exact operation+attempt 重试**结算持久化**并保留 journal/gate；重试路径绝不能再次调用
    `NSWorkspace.recycle`。瞬时失败恢复后，无论回调仍在等待窗内还是已经迟到，都只能结算一次。
11. startup recovery 是真实删除授权的一部分：init 只可在 utility task 预热；每次 `dryRun=false` 都必须
    在 `ledger.reserve` 前 join 同进程 single-flight recovery terminal，blocked 就类型化拒绝。`dryRun`
    不进入此 barrier。single-flight 不能替代第 4 条跨进程 flock，且每轮终态后必须允许后续请求重新
    证明，以观察刚追加的 journal 或重试瞬时存储失败。
12. durable replace 在 temp `open(O_EXCL)` 后、atomic rename 前崩溃会留下私有 JSON sibling。v2026.07.18
    起 pending ledger、completion journal 与 UndoHistory 只能在各自稳定跨进程 flock 已持有后，清理
    本 store 的 `.trash-pending.<UUID>.tmp`、`.trash-completion.<UUID>.tmp`、
    `.UndoHistory.<UUID>.tmp`。匹配必须是 writer 实际生成的 canonical UUID 完整语法，并用 no-follow
    metadata 只移除普通文件；相似前缀、额外 suffix、目录和 symlink 一律保留。禁止在通用 writer 内或
    flock 外做目录级 sweep，否则另一个活 writer 的仍打开 temp 会被当成 crash 遗留删除。清理后 parent
    directory fsync 失败只记录并留给下一锁 owner 重试，不能把非权威垃圾回收伪装成 store RMW 失败。

### 不可消除的 Darwin 边界

`renameatx_np(RENAME_EXCL)` 提供的是**目标 no-replace**，不是 source inode compare-and-swap。
Darwin 没有“按已打开 source fd 原子 rename”的公开 API，所以 source parent fd 上相邻的
`fstatat` 与 `renameatx_np` 之间仍有极小 name-to-inode 竞态。实现会在目标 fd 上立即复核身份，
不匹配时执行 best-effort `RENAME_EXCL` 回滚并报告 identity changed；不得把这描述成已获得真正
source CAS。要完全消除此边界只能由系统提供新的原子 API，而不是继续增加 pathname probe。

### 防回归证据

- callback path ABA 必须证明 journal 保存 reservation 身份而非 replacement 身份；重复 callback
  的 timestamp 变化不构成 deterministic-ID collision。
- crash-after-Undo-fsync/before-phase 与 phase-after-ledger-ack/before-receipt-prune 都必须重放为同一
  record/pair；后一窗口必须保留 `receiptPrunePending` journal 证据，重启后 receipt 与 row 都收敛为空。
  两个 recovery 实例强制重叠时，第二个必须阻塞在稳定 recovery flock，最终 Undo pair 单份、journal
  空、receipt 空；旧 journal/history 的 path-bearing ID 迁移也必须有测试。
- corrupt、chmod 读失败、8 MiB 超限、wide record、durable-writer 失败和稳定 lock 阻塞均须有测试。
- callback 返回本 attempt 以外的 pair 必须被 scope fence 拒绝；任意两个 pair 复用同一 non-nil
  journal ID 或 receipt 出现非 ASCII lowercase hex 都属于损坏数据，必须 fail-closed。
- claim durable-writer failure 必须证明 AppKit 调用次数为零；callback journal 已 durable 后的 ledger
  写失败必须返回 storageUnavailable 并保留 journal。mark-prune、receipt-prune、journal-remove 三处
  失败都必须保留 exact health block；remove 失败后的 finalizer 从 prune-pending 阶段继续。live-owner
  replay 不得写 Undo，dead/stale-owner 组独立收敛。
- journal writer 失败必须证明 callbackObserved 与 blocked 精确路径只产生一次 ledger replace，重启仍
  恢复 exact attempt；操作 B 的真实 receipt ack 后 A 仍 blocked，只有完整集合移除 A 才 ready。
- callback ledger 的一次瞬时 durable-writer 失败必须在同进程重试成功，并断言 workspace recycle 调用
  始终为一次；逆序执行 terminal/pending health 投影仍必须 ready，空 ledger snapshot 不得清 local
  unsettled；不能靠重启测试掩盖 live-owner 不会被 replay 的事实。
- 两个都预载 10 条历史的实例并发各新增一条后，两条新记录必须都在最终 10 条中；snapshot 被钩子
  阻塞时 journal mutation 不得越过 FIFO。duplicate record UUID、duplicate journal row/ID 必须返回
  typed corruption，禁止 `Dictionary(uniqueKeysWithValues:)` trap。
- 三个 store 都必须用 integration fixture 证明：持有其稳定 flock 的活 writer 期间 temp sweep 不运行；
  释放后只清 canonical `<prefix>.<UUID>.tmp` 普通文件，malformed UUID、额外 suffix 与 exact-looking
  symlink 仍保留且 symlink target 内容不变。
- check→move 测试在 source `fstatat` 后替换 pathname，必须检测目标身份不符、no-replace 回滚，
  且不得在原目标留下 replacement。

---

## 11. v2026.07.18：卸载扫描的 App 身份不能代替残留候选身份

### 事故根因

选中 `.app` 的 device/inode 只能证明“扫描的是哪个产品”。残留目录从扫描到确认再到
`NSWorkspace.recycle` 仍可能被同路径替换；若 intent 只保存 pathname，后来对象会继承旧候选的
匹配理由与用户确认。与此同时，12 个 root 的第一层 `readdir` 与 Spotlight result extraction 即使
放在异步函数里，未绑定 owner、预算、逐项取消或 MainActor 小批次 yield，仍会让旧轮扫盘叠加或
单次占满主线程。

### 长期合同

1. 每个可删除残留必须保存扫描时 no-follow `TrashObjectIdentity`，并通过 interaction snapshot、
   `DeletionIntent` 与 source-specific execution verification 进入 Trash。durable reservation 冻结
   当前 identity 后、任何 AppKit claim 前必须比较；后续继续复用 ledger 的 claim-adjacent fence。
   选中 App identity 永远不能替代这份逐候选能力，partial、缺 identity 与特殊文件只能展示。
2. App Footprint 的 bundle bytes 必须与 `InstalledApp.fileIdentity` 匹配。路径已替换、identity 缺失
   或根不再是目录时，发布 typed incomplete 的 0 下界，禁止把 App B 的字节标成 App A。
3. 残留第一层枚举与后代 snapshot 共用一轮 cancellation token、全局 entry/deadline 预算；页面/store
   只允许一个 producer。新选择必须 `cancel` 并 `await` 旧 producer terminal 后再启动，revision gate
   只管发布权，不能代替 I/O 结算。
4. `NSMetadataQuery.result(at:)` 属于 MainActor 工作，数量上限不是响应性保证。必须以小批次读取、
   每项检查 deadline/cancellation、批间 `Task.yield()`；timeout/cancel 要能在批间停止 query 与
   extraction。路径规范化和去重继续放后台，partial paths 与 typed incomplete 同时保留。

### 防回归证据

- 候选扫描后同路径换 inode，必须在 durable reserve 后返回 typed identity-changed，ledger claim 与
  workspace recycle 调用次数都为零。
- 快速切换 App 时旧 residual producer 带结算尾巴退出，最大并发 producer 仍为 1；entry/time budget
  命中必须形成 typed incomplete。
- Spotlight 虚拟时钟要证明 deadline 在少于一个 32-item chunk 内生效；batch yield 后取消不得再读
  下一项。App Footprint replacement fixture 不得发布 replacement bytes。

---

## 12. v2026.07.18：日志文件名不是删除、导出或健康证明

### 事故根因

滚动日志曾以 `AmuxAIClean-` 前缀和 `.log` 后缀筛选，再交给
`FileManager.removeItem` / `Data(contentsOf:)`。同名目录会被递归删除，同名 symlink 会把导出读取
带到目标文件；活跃文件被 rename、路径被 replacement 或目录被 unlink 后，旧 fd 仍可能写成功，
但 Finder 看不到任何新日志。若只把 raw Error 写 stderr，用户界面也无法解释“为什么没有日志”。

### 长期合同

1. 只有精确 `AmuxAIClean-YYYY-MM-DD.log`、no-follow `lstat/fstatat` 证明为普通文件且满足链接数
   合同的目录项，才是本 sink 的枚举候选；前缀、扩展名、URL 或 `fileExists` 都不是 ownership。
2. 打开使用 directory fd + `openat(O_NOFOLLOW)`，随后比较 path 与 fd 的 device/inode。清理使用不带
   `AT_REMOVEDIR` 的 `unlinkat`，导出从重新验证的只读 fd 读取；目录、symlink、hardlink、malformed
   date 和 identity replacement 一律不递归、不跟随、不猜测。
3. 写入只可使用与同一次 no-follow 打开事务绑定的已验证 directory fd + file fd。打开、跨日滚动和
   显式 `prepareDirectoryForAccess` 必须完整重验可见 path identity；append 热路径复用这两个稳定
   descriptor，并以“每 256 条或 1 秒（先到者）”作为可见路径重验边界。v2026.07.19 曾把完整路径
   遍历放到每一条结构化日志前，1500 条 append 因而产生 9020 次 `lstat/fstat/fstatat`，直接把扫描
   日志放大为元数据 I/O；稳定 fd 不会因 pathname replacement 被重定向，所以逐行重验没有增加写入
   安全。自上次可见 identity 证明后接受的行必须同时保留在最多 4 MiB 的 visibility window；边界前
   只能写原冻结 inode，绝不能写 replacement/symlink 目标。边界发现 unlink、普通 replacement 或目录
   换位时，必须先关闭两个 descriptor，通过 `O_NOFOLLOW` 重绑，再把窗口按原序回放到新的可见 inode；
   超过字节上限要写 `dropped_lines/dropped_bytes` marker，不能静默清空。symlink/越界路径失败时保持
   typed unavailable 与有界窗口，安全普通路径恢复后再回放。被移位的旧文件可能仍保留同一窗口副本，
   但当前约定路径中的每条接受行必须恰好一次；不可继续向旧 inode 写完后把 health 标回 ready。
   此基准只证明 file-sink append 的独立 hot-path 回归；不得据此宣称真实 App 中 78–221 秒的
   DevArtifact 扫描根因已经闭合，端到端结论必须另有同构 scanner/App 证据。
4. `GSYLog.emit` 与 sink replacement/disable 的配置锁只负责确定 ingress 顺序，不能持锁等待文件队列。
   append block 必须强持有已接受它的 sink；配置切换后由独立 retirement owner 在锁外把 terminal close
   排到旧 sink 串行队列尾部，先 drain 所有已接受行、完成可见性重验/回放并关闭 descriptor，再释放
   生命周期。弱持有 append、只 detach observer 或直接清全局引用都会让排队日志无 marker 消失。
5. create、enumerate、fsync、retention、export 和 clear 都是文件 I/O，不得从 SwiftUI body、
   `App.init` 或 MainActor 同步执行。启动只能先建立无文件 I/O 的有界内存缓冲，再由后台 revision
   构造 sink；安装时必须先按序 flush 缓冲，溢出留计数，旧 revision 永远不能覆盖新配置。
6. writer health 与 maintenance/operation issue 是两份合同：open/write/prepare/clear 可使 writer
   unavailable；retention/enumerate/export 失败即使仍可 append 也必须独立可观察。问题按 stage 保留，
   只有同 stage 的完整成功才能清除；初始化中不得伪装为“文件日志已禁用”。所有失败以本地化操作名
   和闭集 `stage/domain/code` 展示，并另写只包含白名单字段的独立 Unified Logging 事件。
7. 合并导出不得把所有日志 materialize 成一个 `Data`。源文件继续做 no-follow + identity 重验，目标
   使用固定大小块流式写入用户所选目标的同目录 `0600` 随机临时文件，`fsync`、关闭后以 `renameat`
   原子替换；失败只能清理自己的精确临时项，不能破坏既有目标。
8. 业务日志继续写入用户可读的本地滚动文件。隐私收紧只要求 API Key、网络正文等敏感负载不落盘，
   不能借此删除扫描、删除、规则和存储错误；否则“没有敏感日志”会退化成“没有诊断能力”。

### 防回归证据

- matching-name directory 内 marker、matching-name symlink target、hardlink sibling 和 malformed-name
  普通文件在 purge/clear 后必须原样存在；export 不得包含 symlink/hardlink target 内容。
- 活跃日志被 rename/replacement、目录被删除或 final component 变 symlink 后，下一次写/prepare 必须
  在固定重验边界重新绑定可见 identity 或进入 typed unavailable；边界前的窗口必须有界保留，普通
  路径恢复后按序回放，不得跟随 replacement。unlink、普通 replacement、symlink fail-closed/恢复、
  父目录换向与 replay 超限 marker 都要分别覆盖。
- 1500 条 append 必须逐条保留，并断言路径重验次数按固定批次增长（当前 256 条边界为 5 次），禁止
  回归为 O(日志行数) 的完整路径校验；受控 syscall 基准必须同时记录耗时与 `lstat/fstat/fstatat` 数量。
- disable/reconfigure 竞态测试必须在旧 sink 队列前放 barrier、释放测试侧强引用，再证明全部已接受行
  只进入交接两侧之一且恰好一次；配置 API 必须立即返回，测试通过显式 retirement wait 等待 drain。
- Settings 已打开后制造 write/open failure，health stream 必须主动更新；Help/Settings 的准备、枚举、
  导出和清理测试必须证明文件工作不在 MainActor，错误不得降为空列表或成功计数 0。
- 启动缓冲测试必须证明初始化态与 disabled 不同、溢出 marker 在保留早期行之前、早期/晚期日志顺序
  不变且旧 bootstrap revision 被拒绝；retention fixture 必须证明 writer 仍 ready、问题可见且只被同
  阶段成功重试清除。
- 导出复制 seam 必须以小于内容体量的固定块验证最大驻留 chunk、字节顺序、既有目标原子替换、`0600`
  权限和失败/成功后无随机临时文件遗留。

---

## 13. v2026.07.19：Undo 品牌迁移不能用 pathname preflight 授权最终对象

### 事故根因

旧迁移先对 `GSYCleanMac/UndoHistory.json` 读 attributes，再用 `Data(contentsOf:)`
解码，最后 `moveItem` 到新品牌路径。这是三次独立 pathname lookup：大小、解码和最终
迁移的可能不是同一 inode，final symlink、hardlink、原地改写或同名 replacement 都可以
穿过其中的窗口。更严重的是，迁移失败后 bootstrap 继续读不存在的新路径，会把
“旧历史仍在但无法安全迁移”伪装成 `.ready` 的空历史。

### 长期合同

1. legacy 最终文件必须通过 source parent fd 上的 `openat(O_NOFOLLOW | O_NONBLOCK)`
   打开；只接受普通、单链接、0…8 MiB 文件。symlink、目录、FIFO、hardlink 和超限必须
   fail closed，不能回退 `Data(contentsOf:)`。
2. 数据只能从同一 fd 分块有界读取；读前、读后与 commit 紧邻边界都要比较
   device/inode/type/link-count/size/mtime/ctime/birthtime/generation，并用 source-parent
   `fstatat(AT_SYMLINK_NOFOLLOW)` 证明可见名仍是该完整版本。任一改写或替换都拒绝。
3. legacy 被保留后，就不能再使用“一次复制、以后 destination 单独权威”的模型。每次 bootstrap
   都必须在 current store 的稳定 `flock` 内，对 current 与 legacy 分别做 fd-bound、no-follow、
   8 MiB 有界读取；schema 4 持久化 `observedRecordIDs` 与 `observedReceiptIDs`，只导入尚未见过的
   legacy UUID/receipt。当前仍保留的同 UUID 记录只允许按单调终态与 journal 前缀合并；已经从
   current 删除或确认清理的 UUID/receipt 必须由水位阻止复活。两类水位各最多 50,000，溢出必须
   返回 typed failure，禁止静默裁剪后重新导入旧数据。
4. current 提交只能在它的 directory fd 上创建 `0600` 随机 sibling temp，full write 后 file
   `fsync`，再原子替换，并验证目标 identity、对 parent directory `fsync`；首次创建仍使用
   `renameatx_np(RENAME_EXCL)`，不得覆盖并发出现的目标。读、合并和写入必须全部处于同一 current
   `flock` 临界区。
5. 成功后也不自动删除 legacy 源文件。Darwin 没有 unlink-by-fd/identity-CAS，
   `fstatat(name) → unlinkat(name)` 仍有最后一跳 replacement 竞态，禁止把它写成“已绑定 inode
   删除”。最终 source fence 只能证明本次提交包含的快照；不合作的旧进程若在 fence 后写入，
   该记录必须由下一次 bootstrap 对账导入，而不能声称同一次启动已让两个 pathname 原子静止。
6. 对账必须返回 typed outcome。symlink/replacement/解码/大小/水位/写入失败必须映射到
   `.readFailed` / `.corrupt` / `.storeTooLarge` / `.recordRejected` / `.writeFailed`；bootstrap
   不得在 rejected 后继续把 destination 当成权威空文件。

### 防回归证据

- 成功用例必须证明 destination 可完整解码且 legacy 源仍存在；重复 bootstrap 不重复导入，
  current 已删除的旧记录和已确认清理的 receipt 不得从 legacy 复活，而 legacy 后续新增 UUID/receipt
  必须在下一次 bootstrap 导入。
- final symlink 与 hardlink 必须拒绝且不读/不删 target；FIFO 必须通过 `O_NONBLOCK`
  及时拒绝而不能卡住启动；8 MiB + 1 sparse 文件必须在 decode 前拒绝并保留源文件。
- 在读取后、commit 前用钩子把 source 换 inode，必须保留原对象与 replacement、不发布
  destination；在同一边界抢占 destination，`RENAME_EXCL` 必须保留已有目标与 legacy。
- 在最终 source fence 后写入 legacy 的新记录，本轮允许不包含，但下一次 bootstrap 必须收敛；
  current 已有 receipt 与记录终态在对账中不得被旧快照降级或覆盖。
- 损坏 legacy 通过生产 bootstrap 时必须显示 typed corrupt，不能只测静态迁移函数后仍让
  History 页显示“暂无记录”。

---

## 14. v2026.07.20：扫描进度必须隔离 UI 广播，Tree 首帧与精确终态不能混为一谈

### 事故根因

`70fce59e` 之后，开发者构建产物的发现结果改为把 MainActor 上持续增长的
`perRootStaging` Dictionary 交给异步 projection worker。worker 跨 `await` 保留同一份 COW
storage 后，下一批发现结果每 20 项写入都会在 MainActor 复制越来越大的 Dictionary；扫描器遍历
本身没有变慢，变慢的是进度发布所有权。真实症状从约 12 秒退化到 78–221 秒，并伴随 UI 卡顿。

Tree 随后一轮修改把“直接子项已经完整提交”错误解释成“整个 item 已完成”，在 shallow rows
出现时提前清除了 `treeChildrenInFlight`。因此用户能看到名称，但 exact bytes/count 和当前排序
仍在运行时 spinner 已消失。正确合同不是阻塞首帧，也不是伪装完成：identity 立即可见，loading
持续到精确测量与排序终态。

全盘 `.topLevel` 的另一个独立 UI 卡顿来自发布边界：ScanKit 只上报绝对 progress，终态前没有
可见 rows，但 `ScanCoordinator` 仍每 0.4 秒替换一次完整 `ScanSnapshot`。`MainView` 与 HUD 都观察
整个 coordinator，elapsed 的单字段变化也会让 NavigationSplitView、侧栏和 HUD 广域重算。
进度节流没有解决观察范围错误；应让小状态栏/HUD 独占一个窄 ObservableObject。

同一轮修复后又暴露出第二层 Tree 回归：浅层 cache 虽然已在 20–77ms 内写回，但通用
`childrenCacheVersion` 监听把每次写回都升级成整棵可见 Tree 的 DFS、索引和 Safety 投影；随后
deep 指标写回还会取消上一轮 worker。结果是“数据已经有了”，界面仍长时间没有子项。开发者扫描
还把 primary `.topLevel` 已经测得的直接子项 cache 在终态后立即清空，首次展开又重复扫盘。

开发者扫描的另一个独立尾部回归来自终态批处理：`70fce59e` 会在 root 完成和 0.4 秒发布边界内
逐批填充 verdict cache；后续实现把全部 projection 留到 producer 结束后，才一次串行执行所有
`SafetyEngine.evaluate`（包含 symlink 解析）和八套全局 Tree 排序。真实 14,159 行现场因此出现
16.900s terminal drain；磁盘 producer 本身并不是这段尾差。

### 长期合同

1. MainActor 持续突变的 Array/Dictionary/Set 不得以完整 COW value 交给跨 `await` 的长生命周期
   worker。开发者发现进度沿用 `70fce59e` 的单 turn 发布所有权：0.4 秒节流边界内完成一次排序与
   publish，不允许在下一批写入窗口继续保留 staging storage。若未来要移出排序，后台 actor 必须
   成为 staging 的唯一所有者并接收增量，不能再次传完整 MainActor Dictionary。
2. 直接子项 identity 集合提交即发布 shallow frame，允许立即显示、选择和继续下钻；不得清除
   `treeChildrenInFlight`/ownership。后代精确容量、文件数、incomplete 与当前排序提交后，先清
   ownership 再发布唯一 exact terminal revision。删除等破坏性动作必须等待该终态。
3. Tree 的 DFS、宽数组/索引 materialize、Safety verdict 和旧 COW generation 释放必须留在后台
   worker；MainActor 只做有 revision/CAS 保护的 O(1) snapshot 交换和可见行刷新。
4. 扫描器耗时、进度发布耗时和 UI/Tree 投影耗时必须分开记录。不得因为扫描 stream 尚未 terminal
   就把所有卡顿归因于磁盘 I/O，也不得用单元测试耗时冒充真实 App C4。
5. children cache revision 必须携带发生变化的 parent path。已展开且可见的单一 parent 只允许
   后台 patch 自己的连续 segment；shallow identity 发布后 deep 更新只能替换大小、数量和排序值，
   不得清空 identity，也不得触发无关根的全局 DFS/Safety 投影。
6. Developer primary `.topLevel` 是本轮扫描的权威直接子项证据。终态必须按 producer root 保存为
   Tree cache，scan-end 清理不得把它和扫描期临时 cache 一起丢弃。Developer sentinel 不消费的
   全局 Tree 排序不得构建；需要的兄弟排序按 root 生成。
7. 终态仍有未缓存 Safety 判定时，必须在非 MainActor 的有界 worker 中执行并保持完整 evaluator、
   最终排序和 CAS 合同。日志至少分开记录 projection merge、Safety、主列表排序、Tree 投影/分组
   与 total，且只写数量和耗时，不写用户路径。
8. 生产 `.topLevel` 扫描的实时 bytes/files/rate/elapsed 只能写独立 progress store；不得替换完整
   `ScanSnapshot`，也不得 bump Tree revision。主窗口状态栏和 HUD 用小子视图观察该 store，侧栏、
   结果区和 Tree 不得订阅。终态 transaction 才发布权威 snapshot。

### 防回归证据

- 2,048 个 developer roots 的进度发布后，必须没有 active/pending async projection worker，也不能
  增加 live worker build count；该测试保护 COW ownership，不以放宽时间阈值代替。
- 全盘 Tree 的宽目录 fixture 必须证明 shallow identity 立即可见且 `fetching=true`；deep exact
  终态再证明容量不 pending、排序正确且 `fetching=false`。
- 投影扫描 progress fixture 必须证明 live store 有更新，而 `ScanCoordinator.objectWillChange`、
  `$snapshot` 与 Tree tick 在终态前均不发布。
- 20,000 行 Tree projection 必须证明 materialize 与 verdict evaluation 不在主线程。
- 大量无关可见行 + 单 parent cache bump 的 fixture 必须证明只评估新增 segment；deep 替换保持
  相同 identity revision。Developer terminal fixture 必须经过真实 scan-end finalization 后仍为
  cache hit，且没有新 task、in-flight 或 filesystem lease。
- 当前聚焦测试与 Debug build 只到 C2/C3；真实机器仍须一次持续 C4，记录开发者扫描总耗时、主线程
  卡顿、宽目录首帧与 loading 消失时间。没有这组证据不得宣称性能回归最终关闭。

## 15. v2026.07.20：删除结果不得等待宽 Tree prune

真实 Professional 删除日志把一次 10 秒以上的“系统删除慢”拆成了两个阶段：
`NSWorkspace.recycle` 对单项的 submit 约 `364ms`，随后 `ScanCoordinator.pruneDeleted` 对
`13,651` 行 snapshot 与 `11,872` 个 Tree cache entry 的 plan 却用了约 `11.45s`。旧调用顺序先
等待 `applyProfessionalDeletionSuccess` 完成，最后才 route 结果页，所以用户看到的延迟来自模型
整理，不是废纸篓 I/O，也不是结果 sheet 动画。

长期合同：

1. typed completion/receipt 是结果页的权威边界。先 route 结果并给 SwiftUI 一次 presentation
   调度机会，再执行扫描快照、Tree、选中项、统计与历史记录 reconciliation；后者不得成为结果
   可见性的前置条件。
2. Developer terminal 只拥有 per-root Tree projection 时，删除不能凭空重建八套全局 Tree 排序。
   `snapshotTreeRows` 为空是有效的表示边界，不是 cache miss。
3. Tree cache 贡献索引只能作为 snapshot、dir index、bucket、per-root、large-file 等权威来源均
   缺失后的 fallback。不得为了删除一个已存在于 snapshot 的 item，先扫描所有 sort cache。
4. 日志必须分别记录 recycle completion、result eligibility 与 model-sync completion；性能测试
   同时锁定“结果不等待 reconciliation”的顺序，以及宽 Developer Tree prune 不恢复全局投影、
   不构建全缓存贡献索引。不能仅通过提前弹框掩盖后台 11 秒浪费。

## 16. v2026.09.20：Simulator 路径校验不能要求 Foundation 规范化前后相等

现场 `simctl runtime list -j` 成功返回同机的两类挂载：iOS 26.2 使用
`/Library/Developer/CoreSimulator/Volumes/…`，iOS 27.0 使用
`/private/var/run/com.apple.security.cryptexd/mnt/…`。旧扫描器把
`standardizedFileURL.path == raw` 当成合法性条件；Foundation 会在对应目录存在时移除
`/private`，导致正常 runtime 被误判为 invalid payload，进而拒绝整份清单。仅用不存在路径
的 JSON fixture 不能复现这种依赖挂载状态的错误。托管卸载预检/冻结计划复核曾复制同一判据。

长期合同：

1. `SimctlResourcePath` 统一负责 simctl 资源路径的纯词法校验：拒绝空值、相对路径、根目录、
   NUL、`.`/`..`、重复分隔符及尾分隔符；保留系统返回的合法原始路径，不读取文件系统，
   不按 Xcode、iOS 或 macOS 版本硬编码前缀，不因挂载存在性改变解码或复核结果。
2. managed 与 legacy 解码、卸载预检和冻结计划复核共用该合同。bundle 与 mount 同时存在时
   仍须按完整路径组件证明包含关系；不能放过同前缀 sibling 或把两个不同路径猜成同一资源。
3. 词法有效不代表删除授权或物理身份证明。托管卸载继续依赖 UUID、deletable、冻结复核、
   执行前权威查询和原有 ledger；legacy 永不生成托管卸载 UUID，不能转为文件删除。
4. 回归覆盖旧 `/Library` 挂载、新 Cryptex 路径、确实存在的 `/private/var/run`、legacy、
   mount-only、路径穿越/NUL、mount sibling，以及 prepare/revalidate 的路径保真。
   本次不引入新系统 API，产品部署下限仍为 macOS 13.5；当前系统上的测试和 Debug 构建不能
   替代 macOS 13.5 真机/VM 与持续 UI 交互验收。

参考：[Apple NSURL.standardizingPath](https://developer.apple.com/documentation/foundation/nsurl/standardizingpath)
明确说明 `/private` 前缀的移除可能查询文件系统。

## 17. v2026.09.20：干净 worktree 不能证明发布包含当前完整产品

1.6.4 打包前只提交模拟器修复和版本号，原工作区已经完成的普通工作台、存储分析、
系统状态及配套安全改动仍未提交。随后从该提交创建的干净 worktree 不含这些内容，
即使构建、签名和测试通过，交付界面仍退回旧 Smart Care 单页。

发布范围必须从用户当前完整产品状态出发，不能擅自把既有未提交改动排除。提交前记录
tracked 与 untracked 源文件的内容基线，提交后逐项核对；固定版本 tag 后，以同一 tag
指向的源码构建，并核对最终 provenance。普通模式生产入口、实现和本地化资源必须都
包含在产物中。具体流程见 [RELEASE.md](docs/RELEASE.md)；源码、离屏渲染与真实运行
交互的证据等级仍分别记录，不能把“clean”或“编译成功”当成用户已完成界面被保留的证明。

## 18. v2026.10.08：搜索、成功反馈与原生语言必须跟随各自状态边界

真实 App 回归中，应用占用/卸载只筛选左侧列表，右侧仍保留被隐藏应用；卸载的候选与
预检也仍属于旧应用。搜索不是纯视觉过滤：可见 identity 集合必须约束详情和操作 owner。
`AppListSearchProjection` 统一这个合同，卸载的点击、搜索、刷新和删除终态共用同步选择
切换，立即清候选、取消任务并旋转 revision。迟到结果继续通过原有 gate 拒绝，不能只在
详情 View 上遮住旧数据。应用占用 progressive commit 和删除后的 fallback 同样遵守当前搜索。
候选头部的总量必须与候选数量同源，不能拿勾选量显示“共 N 项”的容量。

端口与 Dart 的人工进程真实结束后仍有纯成功模态。两者现在共用确认全部退出的非模态
反馈；SIGTERM 已提交但未退出、未提交和失败继续显示明细。反馈计时器绑定新的 receipt ID，
文本保存 Catalog 语义，在显示时本地化，不以发送信号成功冒充进程退出。

切语言后延迟一个 runloop 刷新菜单无法覆盖后续 SwiftUI scene 重建。当前保留 AppKit
`applicationDidUpdate` 的幂等标题协调、声明式新建窗口命令和 Settings 标题 attachment，
但真实展开原生菜单仍观察到子项回到启动语言，**此问题尚未关闭**，不能靠菜单图单测宣布通过。
本轮诊断还证实：在菜单变更通知里同步读取 accessibility 属性会触发 AppKit 菜单重新
populate，重入其 key-equivalent 内部锁并挂起主线程。已撤销整组通知/target 接管/AX 实验，
相关人工 validator 模型不代表实际 sideband 更新；不把这些实验或其测试作为交付修复。
原有标题 attachment 与标准 action/快捷键不变的测试保留。后续修复必须通过同进程切页、
展开、键盘操作的真实 C4，不能在更新中递归请求菜单构建。

SwiftPM 原样复制 xcstrings，不支持把 DEBUG 的原始字符串读取当成复数格式运行验证。
本轮复数集成测试使用 Apple `xcstringstool` 编译真实 Catalog，再经同一格式化边界断言中英
文；不为包测试写一套产品复数解析器，也不删减精确文案断言。完整测试还暴露旧 Undo 用例
把 append 发布 `.ready` 误当第二次 bootstrap 完成；改为等待第二次 bootstrap hook，仍严格
断言重读次数、两个 journal identity 与最终 history，不改变存储需求。

## 19. v2026.10.08：目录刷新终态必须在通知前结束请求 owner

真实 App 在 Assets 的“刷新此目录”后一直转圈，但 worker 与 indexed transaction 已在约
0.1 秒内完成。`commitIndexedSubtreeMeasurement` 发布最终 children/structural 通知时，
`indexedSubtreeRequests` 仍持有刷新 token；同步订阅的 Tree source 因此冻结 `fetching=true`。
调用者随后移除 token，却没有新的最终通知。只检查 `await rescanSubtree` 后的模型会通过，
实际画面仍保留忙碌状态，不能用超时隐藏 spinner 或额外点击重绘掩盖。

请求 owner、行、容量、完整性证据与 source identity 必须在同一个无挂起提交内结束，再发布
最终 Tree 通知。成功调用者只记录已提交结果；拒绝/取消仍按 token 结束自身，不能清除新的
重叠请求。测量、准备与退休继续在后台，不为 UI 增加遍历或等待。

防回归测试同步订阅生产 children-cache 通知，冻结真实 Tree source，再运行生产投影 worker，
同时断言新文件可见、终态 owner 已结束、source 仍有效且目录没有 loading 状态。原代码两项
断言失败；现有重叠请求 CAS 与 incomplete 证据测试保持严格。参考 Apple
[`Published`](https://developer.apple.com/documentation/combine/published)：通知发生在属性更新
边界，订阅者读取的关联状态必须已经一致；不能依赖下一个 runloop 恰好修正。

## 20. v2026.10.08：空结果不是扫描终态

真实重复扫描已枚举完 16 文件、没有达到最小尺寸的候选，UI 却仍显示“还没有结果，点开始
扫描”。`isScanning=false && groups.isEmpty` 同时可能表示尚未开始、完整空结果、停止、异常
结束或读取不完整；不能根据集合是否为空猜测业务终态。

`DuplicateResultsStore` 与 groups 共用 session owner，保存类型化终态。驱动只在实际 producer
结算后提交完成/停止/未取得完整结果；旧 session 和重复终态不能覆盖新状态。完整空结果与
typed incomplete 分开呈现，文案进入中英 Catalog。修改扫描根或最小尺寸必须旋转同一个
owner、取消旧任务、清选择/结果/证据并回到待扫描，避免用新输入解释旧结果。原有生产者
settlement barrier、最终内容/身份复验与删除授权不变。

测试验证空完成不是初始态、incomplete 不声称完整空、取消/异常明确、改输入后旧结果与终态
均被拒绝；真实 App 再验证扫描、连续重扫、输入变更与只读跳过根。不能为凑正向重复组降低
产品最小尺寸或修改判定；正向 full hash、部分失败和真实回收仍须人工 fixture 独立验收。

## 21. v2026.10.08：隐私规则必须匹配扫描器实际采用的路径表示（未关闭）

真实重复扫描通过系统选取器选中 `/private/var/folders/...` 内人工测试目录；页面和扫描根规划
调用 Foundation `standardizedFileURL` 后变为 `/var/folders/...`。`TCCSkipList` 仍只按原始
`/private/var/folders` 字面前缀比较，结果实际枚举了两个人工文件。独立调用当前实现也证实
`/var/db/locationd` 未命中相应规则；未实际扫描该敏感目录。

这是共同匹配边界的问题，不能通过增加某个用户的随机临时路径、放宽 HOME 删除边界、改名
fixture 或使用路径别名来通过验收。保持当前规则范围的候选方案是：在共同 TCC 边界保留原始
系统前缀并一次计算其 Foundation 表示，输入无论来自选择器还是 scanner 都命中同一条规则；
不能对每个目录项反复查询文件系统，也不能因此推断任意软链均已安全。

候选补丁尚未应用：规则库修改按 AGENTS.md 等待明确授权。当前实现红探针与候选绿探针仅是
独立原型证据，不是包测试或真实 App 修复通过；后续必须在原场景复验“跳过且不枚举”。
参考 Apple [`NSURL.standardizingPath`](https://developer.apple.com/documentation/foundation/nsurl/standardizingpath)
对移除 `/private` 的说明；该 Foundation 行为也曾影响本仓库的 simctl 路径校验，见第 16 节。

## 22. v2026.10.08：Undo 必须重建当前模式的数据源，不能按缓存是否为空猜模式

外部复审指出 Undo 的三处遗漏，新增断言均已在修复前失败：多根恢复只修复 Tree/总量，未恢复
清单与 bucket；版本/常用缓存使用 sentinel 且没有可对账根，恢复直接返回；普通结果尚未生成
Tree 投影时，增量刷新继续沿用空字典。完整空扫描通常已包含八个排序键的空数组，第三项并非
“所有完整空结果都失败”，实际合同是投影尚未生成时仍应按当前模式建立它。

长期合同：

1. 普通及多根扫描的清单是枚举根的一级子项。恢复整个根时，同一后台 indexed transaction
   必须重建其 rows/buckets，并保留其他根；Tree、容量、数量和 tombstone 仍在同一 revision
   提交，不能只检查 Tree 已出现就认为清单正确。
2. 版本/缓存列表保存的是规则候选本身，不是候选内部文件。使用类型化 discovery state 保存
   原计划与候选历史，不能把候选路径混入通用枚举根，否则显式刷新会把候选替换成内部文件。
   恢复命中候选的父目录域后，通过原 primary admission 重放生产者，重新判定版本保留策略、
   缓存选项、安全证据和白名单；重名恢复只负责使发现结果失效，不能为新名字授予规则资格。
3. 候选历史在 prune 和连续恢复重扫间保留，用来识别后续恢复；结果 owner 取消或跨模式失效
   时必须撤销重放计划。旧生产者须真实退出才可启动下一轮，迟到通知不能重启已退出的页面。
   新扫描在 admission 时一起清理旧投影与 tombstone，不能先清标记而把未重测的旧行暴露出来。
4. Tree 投影依照结果模式决定：真正的 per-root 模式与大文件 Top-N 不构造全局排序；普通和
   discovery snapshot 按需构造。sentinel 集合还含版本/缓存，不能把所有 sentinel 都当 per-root。
   版本候选经过显式刷新仍保持语义叶子，不能因物理目录有内容就改变产品展示。
5. v2026.10.09：默认浅层 primary scan 不保存 deep index，不能把缺少索引解释成旧容量为零。
   partial indexed refresh 的目录容量统一来自合并后的稀疏 allocation catalog；可读目录新增
   容量与不可读目录保留容量必须相加，不能只取旧根与本轮根的最大值。清单和已展开 Tree
   缓存保留未被观测的已发布成员，仍发布类型化不完整证据；只有 complete 才有权按缺席移除。
   硬链接保留 owner 的修正若已更新展示总量，必须同步推进子树 delta 基线，不能再次计入。
6. v2026.10.09：单根、多根及开发者 primary producer 的完整 `ScanOptions` 与结果账本一起
   保存，显式 indexed refresh 和 Undo 对账读取其不可变副本，不能重新构造固定选项或读取
   后来改变的 UI 偏好。新扫描安装新配置，结果 owner 失效时撤销旧配置；发现型列表继续
   按原类型化计划重放。必须用真实浅层 primary scan 覆盖 `includeHidden=false`，只注入
   完整 deep index 的 fixture 无法发现生产数据源缺口。

回归断言同时覆盖清单、bucket、八种 Tree 排序、其他根保留、真实 producer 的规则/选项重放、
重名恢复、连续通知的结算、取消后通知和专用候选显式刷新。测试只使用系统临时 fixture，未
调用真实回收；包测试及挂载 NSHostingView 仍不能代替真实 App 的回收/Undo C4。

## 23. v2026.10.09：路径解析、扫描身份与不可变规则编译

`1f48352` 复审通过生产 API 复现三项问题：多跳悬空链接留在缓存路径而被判为 safe；
白名单解析互指链接不终止；Duplicate 根规划把 `/private/var/folders` 转成获当前进程
临时目录豁免的 `/var/folders`，使相同根在 Bulk 与 Duplicate 中获得不同 TCC 结果。

1. **安全解析只有一个实现**：SafetyEngine 的基础、vendor 与 bundle 能力查询，以及
   WhitelistStore 共用 `SymbolicLinkResolver`。存在的目标先走 libc `realpath`；缺失目标
   按组件解析全部链接，先展开中间链接再处理目标中的 `..`，保留缺失后缀。用系统
   `_SC_SYMLOOP_MAX` 限制遍历；循环、权限和 I/O 错误返回 typed failure，不能留在原路径
   假装成功。`realpath` 要求组件存在，见 [Apple 手册](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/realpath.3.html)，不能单独用于悬空链接证明。
2. **缺失不等于无法解析**：已解析的存在祖先先转换为政策命名空间，再附加不存在的
   后缀，不能让叶子是否存在决定 `/private` alias 的匹配结果。白名单只对成功解析的
   alias 做成员证明；安全评估把解析失败保留为 `symbolicLinkResolutionFailed`。
   专业覆盖消费 `.protected / .unprotected / .unresolved` 证据，只有明确 unprotected
   才满足 bundle 条件，禁止通过否定 Bool 把未知变成授权。
3. **扫描身份只做词法规范化**：用户根持久化、Duplicate/UI 根规划、扫描前估算和
   incomplete evidence 共用 ScanKit `ScanPathIdentity`，不读取文件系统、不解析 alias。
   root symlink 是否跟随由 ScanOptions 决定；跨 Data/public 命名空间继续由显式
   `ScanPathNamespace` 管理。不能在某个 View 里拼回 `/private`，也不能在下游再次调用
   `standardizedFileURL` 抹去已经保存的政策身份。
4. **规则在构造时编译**：BundleProtectionMatcher 保存不可变 NSRegularExpression，
   不在逐路径查询中拼接或编译正则，不做可能陈旧的路径 verdict 缓存。保持原规则优先级、
   exact/prefix/contains 顺序、ICU 大小写行为与原 matched pattern；直接 NSRegularExpression
   的 `$` 接受末尾换行之前的位置，用 `\z` 保持原 String 正则搜索的严格尾边界。
5. **确认身份与账本身份必须显式交接（v2026.10.10）**：历史上确认路径与持久 Trash
   ledger 都先折叠系统别名，字符串直接比较恰好一致。扫描政策与确认入口改为保留词法
   身份后，这个隐含假设失效：同一对象被误报为身份变化，或系统已执行后的回执被另一套
   字符串核算拒绝。`DeletionExecutionIdentity` 在统一交接处建立一一对应关系，普通审阅、
   卸载和扫描不完整严格请求均比较账本冻结的完整对象身份；重复执行别名仍拒绝。确认前的
   策略路径不改写，回执、结果分区和成功通知回到选中命名空间，durable journal 能力保持
   原执行身份。完整结果核算只在副作用之前运行一次，不得在后续 UI 再用另一套路径口径
   把已验证回执当预检失败。验证必须跨真实 ledger reserve/claim 和结果呈现边界，不能只测
   候选构造或 mock 中前后相同的路径字符串。

回归只创建临时 HOME/文件：完整 dangling chain 与后代、循环终止和 actor 后续可用、
中间 symlink/相对 `..`/非 ASCII 目标、权限来源、物理 TCC 根在估算和 Duplicate 中一致跳过，
以及逐条 shipped wildcard 的原语义对照。基准必须对相同输入核对结果 checksum；局部
评估变快不能写成整个 App 或真实扫描同比加速。

## 24. v2026.10.10：SwiftPM 测试链接与 ScanKit 构建系统选择

`Packages/ScanKit` 的测试目标 `ScanKitTests` 同时直接依赖 `ScanKit`，并通过测试辅助包 `TestHarness`
间接依赖 `ScanKit`。在 Xcode 16+ 默认的 SwiftPM 构建系统（xcbuild/PIF）下，生成的 LinkFileList 会将
`ScanKit.o` 重复引入两次，触发 `ld: 2900 duplicate symbols`。

1. **禁止随意破坏包依赖结构**：不应为规避构建器 bug 而移除 `TestHarness` 对 `ScanKit` 的必要引用，
   也不应将测试脚手架拆散或降低测试完整性。
2. **使用原生构建驱动**：`Packages/ScanKit` 运行测试时使用 `swift test --build-system native`。
   原生 llbuild 后端能正确去重目标对象文件并顺利链接全部测试。
3. **多包测试脚本统一注入**：在全包测试循环中针对 `ScanKit` 单独传递 `--build-system native`，
   其余 8 个包保持默认构建系统。

## 25. v2026.10.10：引导请求不能依赖窗口存活，呈现不能有两个 owner

`f5b26ad` 的 Help 入口先异步重建主窗口，再立即发送通知。原窗口已关闭时，新 MainView
尚未订阅，手动指引请求就丢失。另一个根因是 App 独立呈现 TCC/更新，而 MainView 的
指引门只知道自己的业务状态；检查返回与关闭动画之间没有共同的呈现合同。

- `MainWindowPresentationCoordinator` 由 App 持有，Help 先入队再打开窗口。首启指引、
  手动指引、TCC 与更新使用各 MainView 的单一准入 owner；工具栏绑定发起窗口，Help
  跟随原生主窗口焦点，不得永久固定第一个 WindowGroup。忙时保留请求，空闲时按当前
  模式定位。主窗口消失会保留未完成请求，不能冒充用户完成指引。
- 原生 sheet 的呈现绑定变成 nil 只代表开始关闭。直到 SwiftUI `onDismiss` 和宿主窗口
  sheet 结束均已到达，才释放 slot。控件引导则在所属窗口的 overlay 实际移除后结束；
  两种呈现均用 host ID 与 presentation ID 拒绝旧窗口的迟到回调。预留下一轮调度期间也算
  occupied，Sentinel 不能越过已预留的应用提示。
- **v2026.10.10 `4ccd712` 外部复审修正**：不能把“sheet 可见”当成“事务仍活动”。
  Brew、Workflow、Duplicate、Uninstall 从预检、确认交接、执行到结果收敛都在共同边界
  登记真实 owner 的 phase；准入直接重读该 phase，View 的变更观察只负责唤醒队列，不能
  以“已经重绘/已发回调”作为前置条件。异步执行必须在 Task 开始时才消费 pending，不能
  在创建 Task 前暴露空闲阶段。Main 的模式/分类变更同样遵守事务边界。
- 所有业务 sheet 在 `localizedSheet` 登记待呈现生命周期；报告→清理、暂存→AI 与暂存→
  删除共享一次性交接，不能以 `Task.yield` 或主队列下一帧代替关闭。原生 SwiftUI 回归证实
  `onDismiss` 可能早于窗口的 sheet 结束通知；共同边界必须等待两个信号，应用提示也遵守
  此合同。原生通知可能发生于 SwiftUI 更新栈中，因此权威状态同步更新、观察发布合并到
  栈外；不能在 View 更新中发布，也不能让准入依赖发布调度的一帧。
  presenter 移除必须无条件、幂等地释放自身登记；实际关闭屏障由宿主窗口的
  [NSWindow.didEndSheetNotification](https://developer.apple.com/documentation/appkit/nswindow/didendsheetnotification)
  独立持有，不能依赖被卸载 View 的回调。租约归属窗口，关闭一个窗口不能清掉另一窗口。
- TCC 自动评估由 App 会话持有，不能由每个 WindowGroup 重跑。“稍后”仅本次启动生效；
  不写成永久偏好，也不因为关闭发起窗口而丢掉评估结果。
- **本轮产品纠正**：说明页/功能卡片不是逐控件引导，旧页面与文案全部删除。参考
  [Enlighten 的原生控件 spotlight 方式](https://github.com/chriszielinski/Enlighten)，直接注册
  当前窗口真实控件，逐步高亮，提供下一步/完成/跳过；不运行扫描、删除或切换模式来制造
  指引目标。结果/暂存等控件仅在实际显示时加入；窗口大小、控件布局与语言变化使用实际
  几何重算。工具栏与正文的 SwiftUI hosting 树不同，不能假设 Preference 跨树传递；
  `NSView.visibleRect` 在不裁剪的视图上也可能大于自身 bounds，必须先取交集再转换坐标。
  新完成标记不能沿用旧说明页的已读状态，中英文本仍统一进入 Catalog。
- **v2026.10.11 持续运行发现**：用 Preference 回传气泡高度会在原生 hosting 中拿到初始
  零高度，底部控件的气泡虽然按零高度定位成功，真实文字和按钮却伸出窗口。不得加延时
  或为删除按钮写位置特例；使用 [SwiftUI Layout](https://developer.apple.com/documentation/swiftui/layout)
  在同一次布局中测量实际子视图并放置。回归必须测量生产气泡（含中英文与操作按钮行）在
  原生窗口中的真实 bounds，不能只向坐标函数传入假定高度后宣称没有裁切。
- **v2026.10.11 常驻操作合同**：`NSToolbar` 的分组、placement 和 SwiftUI
  `layoutPriority` 都不承诺项目永不溢出；
  [visibilityPriority](https://developer.apple.com/documentation/appkit/nstoolbaritem/visibilitypriority-swift.property)
  也只决定折叠顺序，扫描引起的 SwiftUI 重建还会重新配置原生条目。不能靠不断改分组、
  监听布局回写优先级或强制展开菜单保证常驻。暂存、重扫、指南使用
  [右侧原生标题栏 accessory](https://developer.apple.com/documentation/appkit/nstitlebaraccessoryviewcontroller)，
  从布局合同上退出 `NSToolbar` 的溢出集合；AppKit 按实测内容宽度预留位置，并处理窗口
  缩放和全屏。暂存为空、没有扫描目标时入口也保留，仅数量/可用状态变化。
  这些控件继续保留独立动作、可访问标识和指引锚点。原生回归必须断言三控件的真实
  frame 在支持的窗口宽度和内容重建后都可见，C4 另验证真实扫描和暂存更新。
- **侧栏按块教学**：只给推荐扫描一行加指引会漏掉整个左侧操作区。每个语义分组登记
  标题和行的真实弱引用锚点，聚合当前可见 bounds；`ScrollViewReader` 使用稳定分组 ID
  展示视口外的工具，再测量高亮。滚动只改变视口，不选中栏目、不启动业务；不得用写死
  坐标框住一片区域或把屏幕外栏目默默过滤。左下角容量与虚拟内存另有独立步骤。
  实际滚动只改变 `NSClipView.bounds`，不必改变行的 frame；锚点必须观察原生
  [boundsDidChangeNotification](https://developer.apple.com/documentation/appkit/nsview/boundsdidchangenotification)，
  否则从列表中部重放指引会在回到顶部时停住。等待可见锚点期间 `orderOut` 会解除子窗口
  的 parent，重新显示前必须恢复同一 owner。Help 的激活请求返回时，App 可能尚未成为
  active，owner 的 main/key 均为 false；扩大到 main 判断仍不能完成键盘交接。工具栏的
  明确请求先选择对应 host，指引保留该 owner 的键盘意图，观察实际应用激活事件；交互
  指引使用可激活的 panel，不能沿用非激活 HUD 的窗口样式。滚动临时隐藏时保留键盘
  意图，结束时只在自己持有 key 的情况下归还原窗口，不能抢走另一窗口的焦点。
  [AppKit 的 key/main 合同](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/WinPanel/Concepts/ChangingMainKeyWindow.html)
  要求输入落在当前交互窗口，不能让回车落到遮罩后的路径输入框。键盘行为须另做生产 App C4，
  命令行 native fixture 的非前台 NSApplication 不能冒充这项证据。
- 真实删除纯成功继续由 opaque receipt 生成短暂提示；部分失败与未知结果仍显示明细。
  Debug 预览成功同样不弹 modal，但保留明确的“预览”语义，不生成真实回收凭据。

复审后的回归同时覆盖真实 Workflow owner 的跨 await phase、原生窗口通知、SwiftUI
`localizedSheet` 的原生交接，以及无窗口 Help、旧回调、双窗口路由、更新和 TCC 会话。
原生 fixture 的自动化仍是 C2；模型测试和目标构建不能证明生产 App 运行交互，交付必须
继续单独说明 C4 是否执行。

