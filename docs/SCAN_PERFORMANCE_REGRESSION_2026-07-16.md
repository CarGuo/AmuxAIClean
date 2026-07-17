# 扫描性能回归专项记录（2026-07-16）

> 状态：**v2026.07.17 新一轮根因修复已完成实现与静态自审，当前工作树尚未重跑
> C2/C3；此前一次持续 C4 已执行但整体失败，失败现场见 3.2**。本文同时保留前一代码
> 快照的历史 C3 证据；历史通过不能继承到当前工作树，任何“性能已验证/真实 UI 已验收”
> 的结论都必须等待本轮统一验证。

## 1. 结论

这次“Large Files 接近 4 分钟仍未结束、推荐扫描也要约 4 分钟”的主要瓶颈，
不是 SSD 读取能力，也不是 `getattrlistbulk` 原始枚举突然慢了数倍，而是扫描生产者与
App 消费者之间的架构失配：后台在几十秒内产生了数百万条节点数据，UI 所属的
`MainActor` 却要逐节点投影、聚合并触发 SwiftUI 更新。无界无损事件队列没有丢数据，
但把生产者与消费者的速差转化成了数分钟队列积压、内存增长和取消延迟。

本次根因修复的方向是：保留一次完整、权威的文件系统枚举，把 UI 真正需要的结果在
ScanKit worker 侧预聚合成有界投影；UI 只接收节流后的绝对进度与同一轮枚举产生的终态
`ScanSummary`。这不是“少扫文件”，也不是“丢掉来不及消费的事件”。

## 2. 用户可见症状

- Large Files 已运行约 3m55s，仍显示扫描中、707,622 个文件、95.27 GB，列表只有
  第一批 1 个候选；最终由用户取消。
- 紧接着运行推荐扫描，用户观察约 4 分钟才完成。
- 扫描期间计数长时间落后于后台实际枚举，取消后旧工作仍可能阻碍下一入口及时收敛。
- 此前只通过裸扫描或无 SwiftUI coordinator benchmark 判断性能，未覆盖真实 App 中
  `AsyncStream -> MainActor -> Observation/SwiftUI` 的完整排空时间，因而没有拦住回归。

## 3. 现场证据

证据来自 `~/Library/Logs/AmuxAIClean/AmuxAIClean-2026-07-16.log` 与同机
Release benchmark。时间均按同一日志时钟计算。

| 场景 | 后台/基准证据 | App 端观察 | 能说明什么 |
|---|---|---|---|
| Large Files 扫 HOME | `BulkScanner` 14:16:49.396 开始，14:17:27.349 完成；3,272,465 files、595,992 dirs、300,753,965,056 B，scanner elapsed 37.31s | 约 3m55s 时 UI 仍未终结，14:21:12.806 由用户取消 | producer 已完成数分钟，consumer 仍在排空旧节点；问题位于交付/消费/UI 链路 |
| 推荐扫描 | 14:21:16.916 开始；Logs 0.25s、Downloads 0.17s、Trash 0.21s、DerivedData 0.64s、Caches 9.63s | 下一个明确的扫描后 Tree prefetch marker 在 14:24:48.786，距开始约 211.87s | 五个根的原始枚举都不支持“磁盘本身需要 4 分钟”的解释 |
| CoordinatorBench（无 SwiftUI） | 同机约 385,050 个 Caches 文件，约 7.185s 收敛 | 不含视图 invalidation/layout/render | 扫描器与 coordinator 裸路径可在秒级完成；不能代表真实 UI 端到端已通过 |

注意：推荐扫描的 Tree prefetch marker 不是专门的 `coordinator.finished` 时间戳，只能作为
扫描后续阶段已经开始的上界证据；它不能替代新的 producer/consumer 双时间戳遥测。
但结合所有根均在约 10 秒内完成和用户的 4 分钟观察，足以否定“只是 Caches 原始遍历慢”。

### 3.1 前一代码快照的同机 CoordinatorBench 证据

2026-07-17 在没有启动 App 的条件下，曾使用 Release `CoordinatorBench` 对当时代码快照执行
同机只读验证。两条生产投影路径均直接收到同一轮枚举的终态，没有排队完整节点：

| 场景 | 文件数 | allocated bytes | 有界投影 | coordinator 终结 |
|---|---:|---:|---:|---:|
| `~/Library/Caches` + `.topLevel` | 385,054 | 17,791,373,312 | 248 rows | 6.944s |
| `$HOME` + `.largeFiles` | 3,331,139 | 313,285,234,688 | 404 candidates | 24.406s |

命令行进程受自身 TCC 可见范围约束，两轮都保留了 typed partial 证据；这些数字用于证明
“完整节点不再积压到 coordinator”及投影有界，不能冒充已获 Full Disk Access 的 App
容量结果。HOME 的文件集合也已较事故现场变化，因此 24.406s 与原 37.31s 只能证明该快照的
链路秒级收敛，不能解读为严格的同比加速比例，更不能替代本轮修改后的重跑结果。

### 3.2 第一次持续 C4 的 Common App Cache 失败现场

2026-07-17 已按“单次启动、持续操作”的约束真实运行 Debug App。System & Logs 阶段在
0.536s 进入 UI 终态；随后 Common App Cache 虽声明 12s deadline，却在约 368.47s 后才
返回 partial（3 rows、80 incomplete paths）。对该持续进程做 sample/LLDB 只证明线程同步
阻塞在 `Darwin.open`，路径为 WPS 容器下的 `.kingsoft`；**不能据此把“WPS 正在运行”当成
原因，也不能把运行中 App 排除出扫描**。

该现场暴露两个独立问题：

1. 新增共享森林用最外层父目录做 owner，把宽泛的 `confirm` 父路径提前到更具体的
   `safe` 子路径之前，形成访问顺序回归；
2. Swift Task cancellation 和同线程 deadline 都只能在同步 syscall 返回后被观察，不能把
   卡在内核里的 `open(2)` 变成 12s 硬终态。

本轮修复因此同时要求：同 verdict 内才共享森林且严格 `safe → confirm`；每组发布真实
checkpoint/pending paths；shipped App 通过同一签名可执行文件的私有 worker mode 扫描，
父进程作为唯一 `waitpid` owner 在硬上限到达后 TERM → KILL → reap，并用最后 checkpoint
发布可信 partial。worker 在 SwiftUI/`NSApplication` 构造前分流，一次扫描只启动一个
子进程，不是“反复快速启动/关闭 App”的 UI 壳测试。

## 4. 根因链路

修改前的关键路径是：

```text
getattrlistbulk workers
  -> 每个文件构造 FSNode
  -> AsyncStream(.unbounded) 保留全部 .node/.nodes
  -> @MainActor ScanCoordinator 逐节点 ingest/聚合/Top-N/索引
  -> Observation 发布
  -> SwiftUI diff/layout/render
```

### 4.1 生产者快于消费者

`BulkScanner` 为避免历史上的容量少算事故，使用无界 `AsyncStream` 保存完整节点流。
这保证了节点不被静默丢弃，却没有背压。当 worker 数十秒产生数百万节点、MainActor
每个节点都要做多次字典/路径/安全投影工作时，队列会在后台扫描完成后继续排空数分钟。

### 4.2 MainActor 承担了与总 inode 数成正比的工作

普通列表只需要扫描根的一级聚合，Large Files 只需要固定数量的最大文件；旧路径仍把
全部节点送到 `ScanCoordinator`。深层索引还会沿祖先路径回溯写入 `dirIndex`、
`childEdges` 和 `fileLeaves`。这使主线程工作量接近 `O(全部节点 * 路径深度)`，
并与 SwiftUI 更新争用同一个执行器。

### 4.3 多根入口放大同一问题

推荐、Smart Care 和开发者扫描还经过 `MultiRootScanner`，旧实现会再次包裹并观察完整
节点流。多个根并行完成得越快，MainActor 的突发积压反而越大；单纯调低根并发只会
掩盖消费者模型错误。

### 4.4 重复估算制造额外 I/O

历史代码为了 ETA 同时启动 `TreeSizeEstimator` 重走同一棵树。ETA 已不再展示后，这轮
I/O 没有用户价值，取消后还可能与新扫描争抢磁盘。它不是数分钟积压的唯一根因，但会
放大体感和取消延迟。

### 4.5 `CACHEDIR.TAG` 修正不是应回滚的性能开关

命中 `CACHEDIR.TAG` 的目录仍然占用真实磁盘空间。把它从“跳过子树”修正为“继续计量”
会让被枚举文件变多，这是正确性恢复，不是可以为了性能撤回的功能。性能必须通过交付
架构解决，不能重新漏扫缓存目录。

## 5. 修复架构与统一合同

### 5.1 消费者先声明所需交付

[BulkScanner.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift)
的 `EventDelivery` 定义统一交付模式：

| 模式 | 适用消费者 | 增量节点 | 终态结果 |
|---|---|---:|---|
| `.summaryOnly` | 只需容量与完整性证据、且不需要可见进度的测量任务 | 无 | 权威 `ScanSummary` |
| `.summaryWithProgress` | Workflow 等需要可见长任务状态、但不需要节点 DTO 的容量任务 | 无；只有节流后的绝对进度 | 权威 `ScanSummary`，并在 `finished` 前紧邻发布终态绝对进度 |
| `.topLevel` | 普通列表、整盘一级结果、多根一级结果 | 无 | `ScanSummary.projection.topLevel` |
| `.largeFiles(minimumAllocatedBytes:maximumResults:)` | Large Files | 无 | 有硬上限的 `ScanSummary.projection.largeFiles` |
| `.fileCandidates(minimumLogicalBytes:)` | Duplicate size/hash 分桶 | 无 | 达标普通文件 + 权威 summary |
| `.complete` | 明确需要全节点的后台消费者、显式 deep-index 调试/测试 | 完整无损流 | 传统完整 summary |

生产 UI 不得把 `.complete` 直接连接到 MainActor。`.complete` 保留无损语义，是为了真正
需要全节点的消费者与兼容测试；它不是普通扫描的默认 UI 数据源。

### 5.2 worker 局部累计，目录结束后合并

投影不能改成“每个文件 `await` 一次投影 actor”，否则只是把瓶颈从 MainActor 搬到另一
actor。当前架构要求每个 worker 在一个目录内用局部容器累计：

- `.topLevel` 按扫描根的一级 bucket 累加 allocated/logical bytes、file count、类型和 mtime；
- `.largeFiles` 只保留超过阈值的局部候选，并按固定上限裁剪；
- 每个目录处理完，最多跨 actor 合并一次；全局 Large Files 结果继续维持固定上限。

### 5.3 终态 summary 是唯一权威值

[FSNode.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/FSNode.swift)
把投影附着到同一次枚举产生的 `ScanSummary`。扫描期的绝对 progress 可以节流或合并，
但最终必须由 summary 覆盖，并保持：

- `totalAllocatedBytes` 与 `totalLogicalBytes`；
- file/directory count；
- hardlink dedup；
- permission denied 与 TCC skipped 计数；
- typed `incompleteIssues` 与 `completionStatus`；
- 与同一 generation 绑定的 UI 投影。

因此允许丢掉过时的进度画面，不允许丢掉决定容量、候选或完整性的终态证据。

**v2026.07.17 顺序收口**：进度 merge 与 `yield` 必须在同一个统计 actor turn 内完成；禁止
把快照返回给并发 worker 后再各自发布，否则“较早 merge、较晚恢复”的 worker 会把旧绝对值
排到新值之后。所有承诺进度的 delivery（包括 timeout/watchdog 合成的 partial 终态）都必须在
`finished` 前紧邻发布同一 summary 的最终绝对 bytes/files；AppUI 对非终态帧只取单调下界，
只有终态 summary 可以权威替换该根数值。进度从不决定 success/partial/failure。

### 5.4 Coordinator 只做有界应用

[ScanCoordinator.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
应只在 MainActor 上应用一级可见行或固定 Top-N，而不是全部 inode：

- Large Files 使用 `.largeFiles`，当前硬上限为 1000；
- 普通、custom、整盘一级页使用 `.topLevel`；
- 推荐、Smart Care core、开发者多根入口通过 `MultiRootScanner` 透传 `.topLevel`；
- 显式 `enableTreeDeepIndex` 才使用 `.complete`，且整盘/开发者生产入口强制关闭；
- Tree 深层内容只在用户显式展开后于后台按需获取，首轮终态不再自动
  prefetch/第二轮遍历；切换 size/name/date 只复用已测量 rows 做内存排序；
- 非整盘入口不再并发启动第二轮 `TreeSizeEstimator`；整盘进度可直接复用卷快照，
  不增加文件遍历。
- Duplicate 不再订阅 `.complete`；worker 只收集达到最小逻辑大小的普通文件，
  typed incomplete 从终态 summary 耐久交付。外层 evidence stream 是 lossless，hash progress
  节流；取消会停止补任务并在每个 read batch 边界收敛。
- 所有普通、推荐、开发者和自定义 root 固定在 root device；用户直接选外置卷
  仍能扫完该卷，但不会意外进入其中另一个嵌套网络/FileProvider mount。
- **v2026.07.17 目录身份冻结**：`BulkScanner` 不能只把 pathname 放入并发队列。root 与每个
  后代目录在入队前冻结 `(device, inode)`；默认分支用
  `open(O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) → fstat` 证明打开的仍是同一目录。只有调用方
  明确启用 `followSymlinks` 时，才允许跟随最终 symlink component，但仍须冻结并复核 link 与
  target identity。排队期间发生目录替换、symlink 置换或 descriptor 不匹配，只能形成 scoped
  incomplete，禁止扫描替换后的树。descriptor fallback 同样只在已经验证的目录 fd 上枚举。

### 5.5 页面与专用扫描器也遵守同一生命周期

性能根因不只存在于 Large Files。全局调用点审计同时收紧了任务所有权和专用扫描器：

- 模式、主分类和专用页面切换是明确的扫描所有权边界；离开仍在运行的页面会取消该轮，
  旧 revision 不得覆盖新页面。已经完成的主扫描结果会保留，Tree 的瞬时按需任务则在离开
  Tree 页面时单独取消，不为保留快照而继续后台 I/O；
- App Footprint 的 producer 变为可取消、可等待的 session。重载或离开页面时先取消旧轮；
  下一轮重 I/O 开始前必须等待旧 producer 收敛。文件遍历移出 cooperative/UI executor，
  UI 只批量提交有界增量；
- App Uninstaller 的同步 `FSSnapshot` 遍历移到后台执行，并携带真实类型、存在性、
  completion 与 typed issues。取消轮次不发布候选，partial 只显示下限且 fail-closed，不能
  选择或提交删除；Orphan 候选采用相同的完整快照合同；
- Common App Caches 在**同 verdict** 内对重叠 parent/child roots 只遍历一次 forest；跨
  verdict 严格 safe 优先，允许为正确风险顺序重复读取重叠子树，但物理 totals 仍按 inode
  并集去重。扫描通过同可执行文件 isolated worker 形成真正可终止边界，逐组 checkpoint
  让硬终止后仍保留已完成结果并把 pending path 标为 typed deadline；Workflow
  的嵌套静态 roots 先折叠，容量型文件系统卡使用 `.summaryWithProgress`：保持 summary-only
  内存/完整性语义，同时发布有界的真实绝对进度，避免同一子树重复扫描或恢复 node 流；
- v2026.07.17 的专用链路复核继续收紧两个局部热点，但不改变容量口径：DerivedData 的
  单次 root snapshot 只为 `st_nlink > 1` 的真实 hardlink 保留 `(device, inode)` 归属，普通
  单链接文件立即计量，避免巨量工程把所有 inode 常驻字典；已经登记的 identity 会先于
  单链接快路径查询，避免扫描中其他链接删除导致重复计量。反向的“首次单链接、扫描中才
  新增 hardlink”仍属于 live namespace 非原子边界，不能用恢复全 inode 常驻来伪装快照；
  App Footprint 对
  `NSWorkspace.icon(forFiles:)` 使用页面生命周期内的异步硬上限 LRU：row body 的 miss 只
  进入有界 pending queue，utility worker 并发也有硬上限，完成后才在 MainActor 发布；reload
  会取消旧 generation 并失效缓存，避免 body 重算同步触发 LaunchServices/bundle metadata I/O；
- Duplicate 只接收达标文件候选并在 hash read batch 边界响应取消；`.prefixOnly` 明确不能
  产生删除目标。完整性证据、generation 和最终 Trash 安全链路没有因性能优化而放宽；
- 整盘扫描的数据卷/firmlink 容量与证据使用同一 namespace，普通、推荐、开发者和自定义
  root 保持 root-device 边界，避免无意跨入嵌套网络卷或 FileProvider mount。
- NodeModules 等“固定 HOME 开发根”不等同于用户显式选择的 Custom Path；其 depth-zero root
  若本身是 symlink，必须跳过而不是进入目标。否则既制造无价值的大扫描，也会展示最终无法
  通过 HOME 删除边界的候选。

### 5.6 复杂度边界

- 文件系统枚举仍是必要的 `O(全部条目)`；安全与容量正确性不允许绕过。
- 普通扫描的 MainActor 终态工作降为 `O(扫描根一级行数)`。
- Large Files 的 MainActor 工作和终态内存为 `O(N)`，其中 `N <= 1000`。
- `.topLevel` 投影内存随一级子项数量增长，不随全部后代 inode 数增长。
- 只有显式 `.complete` 仍可能产生与全部节点成正比的无界队列；它必须与生产 UI 隔离。

## 6. 入口覆盖矩阵

| 入口 | 正式枚举/结果模式 | UI 工作量边界 | 备注 |
|---|---|---|---|
| 普通 preset / custom path / Library browse | `.topLevel` | 根一级行数 | 下钻走按需 Tree |
| 整盘扫描 | `.topLevel` | 数据卷/根一级行数 | 单卷边界保留；强制关闭 deep index |
| Large Files | `.largeFiles(..., maximumResults: 1000)` | Top-1000 | 阈值过滤、allocated 口径、mtime 均保留 |
| 推荐扫描 | `MultiRootScanner + .topLevel` | 各根一级行数之和 | 每根 summary 独立保留 partial/failure 证据 |
| Smart Care core | `MultiRootScanner + .topLevel` | 各根一级行数之和 | generation 必须与当前会话绑定 |
| Developer 多根容量扫描 | `MultiRootScanner + .topLevel` | 各根一级行数之和 | 生产路径强制关闭 deep index |
| Workflow 文件系统容量卡 | `.summaryWithProgress` | 常数级状态 + 有界绝对进度 | 不生成 node/cache-tag；终态进度与 summary 同源 |
| Duplicate Files | `.fileCandidates(minimumLogicalBytes:)` | 达标候选数 | 候选必须全部保留，但不排队无关小文件 DTO |
| 显式 deep-index 调试/测试 | `.complete` | 全节点 | 非生产默认；不得直连真实 UI 主线程 |
| Common App Caches 等专用 scanner | 专用终态聚合 | 不得逐文件驱动 MainActor | 不强行复用 `EventDelivery`，但必须满足同一性能/安全合同 |

所有扫描入口都必须回答两个问题：消费者是否真的需要每个节点；如果不需要，结果能否在
worker 侧变成 summary、一级投影或有界 Top-N。新增入口默认不得选择 `.complete`。

## 7. 不可退让的安全与正确性边界

1. 投影和 summary 必须来自同一 scan transaction，不能用 `du`、Spotlight 或另一轮估算
   拼接一个看似更快的结果。
2. 不得把 `AsyncStream` 改成 `.bufferingNewest` 后静默丢节点。历史上已有 195k+ 文件下
   Finder 18.86 GB、应用仅 552.6 MB 的少算事故。
3. 不能因 `CACHEDIR.TAG`、目录类型、名称或扫描耗时而跳过用户可见容量。
4. hardlink、稀疏文件、allocated/logical、TCC、POSIX permission 与 scoped incomplete
   合同保持不变。
5. 取消不伪造 incomplete 或成功 summary；旧 generation、超时 root 和迟到终态不得覆盖
   新页面。
6. whitelist 快照仍须在第一个扫描结果进入 UI 前冻结；删除 tombstone 必须在应用投影时
   重验，已删除路径不能因迟到 summary 回来。
7. 本次只改变扫描结果的交付/投影边界，不放宽 `SafetyEngine`、删除预检或
   `TrashPipeline -> NSWorkspace.recycle` 链路。
8. Duplicate `.prefixOnly` 只比较 size + 前 64KB，不是删除证明；完整复核与最终
   身份重验链路就绪前，计划层不得生成任何 Trash 目标。

## 8. 明确禁止的“性能修复”

- 只调大 `.nodes` batch、降低 UI 刷新率、增加 `Task.yield()` 或减小根并发，然后宣称根治；
- 通过 `.bufferingNewest`、随机采样、达到时间上限后假装 complete 来减少事件；
- 恢复 `CACHEDIR.TAG` 子树跳过，或新增按目录名跳过的硬编码；
- 让 MainActor 逐文件调用另一个 actor，以为跨 actor 就等于后台聚合；
- 为了快而用逻辑大小替代 allocated size，或取消 hardlink 去重；
- 只跑 `PerfBench` 或只看 scanner 的 `elapsed`，不测 coordinator drain lag 与真实 UI；
- 以“启动 App 后立即退出”的脚本冒充交互性能回归。

## 9. 验证门槛

### 9.1 C2：合同与聚焦行为测试

至少覆盖：

- `.summaryOnly` 不发布 node/progress/cache-tag，仍保留 root failure、typed incomplete 和 finished；
- `.summaryWithProgress` 不发布 node/cache-tag，只发布有界绝对进度；进度在并发 worker 下保持
  单调，真实与 synthetic partial 两种 `finished` 前都有与 summary 一致的最终绝对帧；
- `.topLevel` 与同 fixture 的 `.complete` 在 allocated/logical、file count、一级 bucket、
  hardlink、稀疏文件和 mtime 上等价；
- `.largeFiles` 只返回超过阈值的文件、顺序稳定、数量不超过上限，终态总量仍等于
  `.complete`；
- permission denied、TCC skip、descendant incomplete、root failed 与 multi-root timeout
  的 completion status 不因投影模式改变；
- MultiRoot 透传 delivery，进度按每根绝对值折算，不因重复帧重复累加；
- 目录在排队后被同卷 symlink/另一 inode 替换时不进入替换树；默认 no-follow 与显式
  follow-symlink 两条分支都在 descriptor 边界核对冻结 identity；
- 所有公开时长/timeout 输入覆盖 `NaN`、负数、零、`+infinity` 和纳秒换算溢出：无效/非正值
  立即到期，`+infinity` 饱和为无实际 deadline，不能因浮点比较恒 false 变成意外无界扫描；
- 取消 Large Files 后立即启动推荐扫描，旧 generation 不再写入状态；
- Common App Cache 明确断言 safe 子路径先于 confirm 父路径被打开；每个 group 开始/完成
  都携带 checkpoint 与 pending paths；阻塞 worker 在硬上限内被 TERM/KILL/reap，已完成
  checkpoint 保留、pending 标为 deadline，worker 缺失/协议错误禁止回退到 in-process；
  private worker 只接受同 executable/signing identity 父进程继承的只读、已 unlink request FD，
  ambient FD 不得跨 spawn；坏帧、截断、重复 final、异常退出与无 pending checkpoint 均须
  fail closed 为 typed partial，并发布与最终结果一致的唯一 terminal；
- 百万节点合成 fixture 验证 projection 有界，不能在真实 `$HOME` 制造测试数据或删除证据。

### 9.2 C3：相关包全测、基准和构建

扫描、MainActor 投影和多根主链路跨 AppUI/ScanKit，完成前按仓库门槛执行全部 9 包测试、
目标 Debug build，并运行两个互补基准：

```bash
for pkg in ScanKit SafetyKit AppUI HeuristicKit LogKit BrewKit FileSearchKit AIKit TestHarness; do
  (cd "Packages/$pkg" && swift test --parallel) || exit 1
done

xcodebuild -project GSYCleanMac.xcodeproj -scheme GSYCleanMac -configuration Debug build

swift run -c release --package-path Tools/PerfBench PerfBench --root "$HOME/Library/Caches"
swift run -c release --package-path Tools/CoordinatorBench CoordinatorBench \
  --root "$HOME/Library/Caches" --timeout 300
```

端到端自动化验收目标：

- `.topLevel` / `.largeFiles` / `.summaryOnly` / `.summaryWithProgress` 下不出现 `.node` 或 `.nodes`；
- producer summary 与 coordinator 最终容量、文件数及完整性证据严格一致；
- Large Files 候选不超过 1000，投影内存不随全部 inode 线性增长；
- coordinator terminal 相对 producer terminal 的 drain lag 不超过
  `max(3s, producer elapsed * 20%)`。在本次现场 37.31s 基线上，对应 App coordinator
  应在约 44.8s 内终结；推荐扫描最慢根 9.63s 的参考上界约 12.63s。

最后一条是本次回归的完成闸门，不是对所有硬盘、网络卷和数据集的营销承诺。若环境不同，
必须同时记录文件数、目录数、介质、raw producer elapsed、coordinator terminal 和峰值内存，
不能只报一个总秒数。

### 9.3 C4：一次持续运行的真实交互验收

C3 通过后，经用户明确授权，只启动一次 App 并持续完成以下场景：

1. 从 Large Files 入口扫描 HOME，记录开始、后台 finished、页面终态、候选数、峰值内存；
2. 扫描期间滚动/切换筛选，确认窗口无持续 beachball、点击与取消可响应；
3. 完成或取消 Large Files 后立即启动推荐扫描，确认旧计数、候选和状态不串入新页面；
4. 展开一个 Tree 子目录，确认按需扫描不会重启整树，也不会冻结列表；
5. 对照结构化日志确认 partial/TCC/permission 证据没有因性能投影消失。
6. 从 Common App Caches 入口触发同一真实受保护容器现场，确认 UI 持续显示真实 group
   计数/当前路径；终态不突破 worker hard limit；若仍有阻塞，已完成 safe rows 保留，pending
   paths 进入 typed partial，App 主进程与后续扫描继续可响应。

不得按 case 反复启动/关闭 App，也不得把看到窗口出现当成 C4。需要保留截图、结构化时间戳、
峰值内存和操作观察记录。

## 10. 当前验证状态与尚未验证项

### 10.1 历史 C3 证据与当前失效边界

2026-07-17 曾对前一代码快照完成以下验证，均未启动 App：

- AppUI：1,036 个 XCTest + 11 个 Swift Testing 测试全部通过；其中覆盖 projection、
  generation、页面切换取消、Tree 生命周期、App Footprint、Uninstaller、Orphan、Duplicate、
  多语言和删除安全合同；
- 其余 8 个 package：共 731 个测试全部通过（ScanKit、SafetyKit、HeuristicKit、LogKit、
  BrewKit、FileSearchKit、AIKit、TestHarness）；
- `xcodebuild -project GSYCleanMac.xcodeproj -scheme GSYCleanMac -configuration Debug build`
  成功，部署目标为 macOS 13.5；这只证明 availability/链接/编译合同，不代表已在 13.5
  真实运行；
- 两组 CoordinatorBench 的最终数据见 3.1：Caches 385,054 files / 248 rows / 6.944s，
  HOME 3,331,139 files / 404 candidates / 24.406s。两者都没有把完整节点流交给 MainActor。

这些结果只能证明当时快照达到 C3。其后当前工作树又修改了扫描目录身份、进度发布顺序、
Workflow 长任务、卸载快照、Duplicate 最终复核/提交边界和实时本地化传播，因此旧 C3 不得
自动继承。遵循用户“先安全落地、提交推送、再统一测试”的顺序，**当前新增实现只完成源码与
文档静态自审，尚未运行本轮 C2/C3；第一次 C4 已因 Common App Cache 阻塞而整体失败**。
在聚焦测试、九包全测、目标 Debug build、两组性能基准和修复后的单次持续 App 验收依次
完成前，不能声称 Large Files、推荐扫描、
Workflow、页面切换或删除 sheet 的真实性能/交互已经通过。Instruments/Memory Graph 和
macOS 13.5 真机/VM 持续运行证据也仍缺失。

### 10.2 审计推进状态

2026-07-17 已关闭跨根 hardlink 重复计量：`MultiRootScanner` 现在为每个返回 stream 创建
独立的 transaction-level allocation ledger，并注入该轮所有 `BulkScanner` 根。文件
`(device, inode)` 在所有根合计中只贡献一次 allocated/logical bytes，增量节点、
`.topLevel` 投影和终态 summary 共用同一判定；目录 inode 去重仍按根独立，以保留每根
枚举与 typed completeness。账本使用 64-way 分片锁，避免把最多 24 个文件 worker 重新
串行化到单锁；并发下单个 hardlink 的根归属采用 first observer，只有所有根合计是权威
物理口径。对应回归覆盖 complete/topLevel、projection/summary 等价及并发唯一 winner。

2026-07-17 同时关闭 AppUI typed incomplete 的极端二次复杂度：`ScanCoordinator` 不再对
每条 issue 做数组线性查重并同步重建四份公开/Tree 投影，而是通过 exact issue key 与
`(path, reason)` scope key 的有序哈希索引 O(1) 记录。generic companion 到达在前时由 rich
typed evidence 原位替换；generic 到达在后时忽略；不同 stage/errno 的 rich evidence 继续
完整保留。公开 projection 绑定既有 snapshot/per-root throttle、Tree 权威批次和删除安全读
边界一次提交；Tree row 的 ancestor lookup 改为 path-depth hash lookup，strict descendants
在 commit 时一次预计算。新增聚焦回归钉住 5,000 issue 只重建一次、rich 语义、删除前强制
flush 和 reset 丢弃未提交旧 revision。

同一轮静态落地还包括以下共享边界；它们同样尚未取得新的 C2/C3：

- `BulkScanner` 队列冻结目录 `(device, inode)`，默认 `O_NOFOLLOW` 打开并以 `fstat` 复核；
  显式 follow-symlink 分支也冻结 link/target identity，拒绝排队期间的路径置换；
- 绝对进度在统计 actor turn 内按 merge 顺序发布，所有 progress-capable delivery 在真实或
  synthetic `finished` 前发布权威终态帧；AppUI 非终态只推进下界、终态 summary 才可替换；
- Workflow 文件系统卡改为 `.summaryWithProgress`，保留 summary-only 的常数级状态，同时给
  card/session/revision 绑定的真实 bytes/files；DerivedData 同一轮 traversal 产生有界进度；
- App Uninstaller 的公开 snapshot 时长把 `NaN`、负数和零收敛为立即到期，`+infinity` 保持
  无实际 deadline；避免 NaN 比较恒 false 把受限扫描静默变成无界任务；
- Duplicate 完整 rehash、retained-copy identity 与 claim fence 已进入持久 reservation 后的
  pre-submit 链路；`.submittingToTrash` 只在 claim/fence 完成后、实际调用
  `NSWorkspace.recycle` 的 worker 邻接边界同步发布。进度和 UI phase 不是授权来源；
- 长期存活的行、Tree、Smart Care、Stash、删除/结果模型携带 `LocalizedTextDescriptor`，在
  当前显式 locale 消费时投影；path/ID/verdict/rejection/authorization 不读取展示文案。

> 验证边界：按本轮“先收敛实现、后统一测试”的执行顺序，目前只完成代码与静态自审，新增
> 测试源码尚未执行。主任务必须重新完成聚焦测试、全包测试、目标构建和基准，才能把这些
> 实现计入新的 C2/C3；C4 仍只能来自一次持续、可观察的真实 App 验收。

#### 仍未关闭

以下问题不是重新启用逐 inode MainActor 消费的理由，但必须作为后续工作显式管理：

1. 极端“单层包含海量直接子项”的 root 会让 `.topLevel` 投影自身变大，需要分页或窗口化
   合同；当前有界性只针对深层 inode，不等于一级行数有固定上限。
2. cooperative cancellation 仍不能中断已经卡在内核、故障 mount 或单个同步 syscall
   内的调用。Common App Cache 已新增可终止进程边界；其它仍在主进程直接访问不可信
   外部挂载点的链路若出现同类实证，必须复用这一 ownership/checkpoint 合同，不能把
   Task deadline 重新包装成“硬超时”。
3. Workflow 动态独立 roots 目前仍顺序执行。不能在单卡内部直接再开一层并发，否则会
   绕过现有卡片级并发预算并使 HDD、网络卷或故障 mount 退化；后续应先建立全 Workflow
   共享的 I/O budget，再做介质分组与并发。DerivedData 已把 inode 归属表缩到真实
   multi-link identities，但 live scan 不是文件系统 namespace 快照：首次观察为单链接后
   才新增 hardlink 的反向竞态无法强一致去重。仍需在 C4/Instruments 中记录巨量工程的
   实际峰值内存，并在高频变化场景记录该合同边界。
4. FileSearchKit 遗留路径仍有无界结果与重复 metadata 读取；当前没有生产调用点，但重新
   接入前必须先改为有界/流式合同。
5. App Footprint icon 已使用异步硬上限 LRU，cache/pending/active load 都有界且 reload
   会失效旧轮；仍需 C4 实际滚动记录主线程 sample，验证真实 LaunchServices 首次 miss。
6. Common App Caches 的行是 inclusive 风险视图：重叠 parent/child 行相加可能大于全局唯一
   physical total。同 verdict 共享遍历，跨 verdict 为保证 safe 优先可能重复读取；两种情况
   都不能在 UI 端把行直接相加，footer 只能使用 scanner 发布的 unique total。
7. `.complete` 仍保留无界无损事件合同供明确的后台/调试消费者使用；调用点审计和测试
    必须持续保证它不会重新直连生产 UI。
8. 外接 HDD、网络卷、文件高频变化、Spotlight/Time Machine 同盘竞争不在本次 SSD
    基线内，必须记录介质和竞争环境后单独验证，不能外推本机秒数。
9. `Resources/Rules/vendors.yaml` 是受保护规则库；其中现有 common-app-cache 原文仍缺英语
   数据。当前 descriptor 能让运行时 catalog 文案即时切换，但不能凭 AppUI 硬编码翻译受保护
   规则数据。规则 schema/数据的双语迁移必须另获授权，当前属于明确未关闭项。

### 10.3 专用链路审计决策（v2026.07.17）

本轮没有把“审计到债”机械等同于“立刻改代码”。以下三项维持现有实现，是为了避免在
缺少全局合同或产品决策时制造新回归；它们不是遗漏：

| 链路 | 已核实现状 | 本轮不改的合同原因 | 真正可实施的前置条件 |
|---|---|---|---|
| Workflow 动态 roots | 卡片层已有全局有界 work queue；单张动态 filesystem 卡内部仍顺序量各独立 root | 局部再开 TaskGroup 会绕过卡片层 I/O budget，使总并发乘法增长；SSD 上可能更快，但 HDD、网络卷、FileProvider 或故障 mount 会退化，取消也更难收敛 | 先建立覆盖卡片与 root 的共享 I/O semaphore/budget，再按同介质分组，并同时测吞吐、峰值内存、取消延迟与 typed partial |
| Common App Caches inclusive rows | 重叠 parent/child 只遍历一次 forest；每行保持自身完整 subtree，snapshot 总量使用候选路径并集的 unique physical total | 把行改成 exclusive 会改变风险解释、默认选择与“这一路径有多大”的产品语义；仅在 footer 相减也无法正确处理 sibling hardlink | 产品先决定行展示 inclusive 还是 exclusive；若需可相加行，ScanKit 必须发布可证明的 exclusive attribution，而不是 UI 猜差值 |
| FileSearchKit legacy engine | `rg` 核对 App 与非测试 package 源码后，没有生产调用点；当前只存在独立 package、测试和一处文档注释 | 把无界 `AsyncStream` 直接换成 `bufferingNewest` 会静默丢搜索命中，属于需求改变；在未接入生产前改 API 只增加本轮风险，不能改善当前 App 性能 | 重新接入前先定义结果完整性、背压/分页、取消终态和 filter-driven metadata projection，再以消费方端到端测试迁移 |

已实施的两项不依赖上述决策：DerivedData 只保留真实 hardlink identity ledger；App
Footprint icon miss 从 SwiftUI body 的同步读取改为有界后台加载。两者均不改变容量、partial、
候选、风险或删除语义。

## 11. 防回归记录要求

后续任何涉及 `BulkScanner`、`MultiRootScanner`、`ScanCoordinator`、Observation/SwiftUI
订阅、Tree 预取、扫描进度或 CACHEDIR 规则的改动，提交说明必须包含：

1. 影响哪些入口、选择何种 `EventDelivery`；
2. raw producer 与 coordinator/UI terminal 两个耗时，不能只写 scanner elapsed；
3. 最终容量/数量/完整性是否与权威基线一致；
4. 峰值内存与取消后立即重扫结果；
5. 实际达到 C1–C4 的哪一级，以及还差什么。

若端到端 drain lag、MainActor 工作量或内存重新随全部 inode 线性增长，必须视为阻塞级
性能回归，不得以“扫描结果最后还是会出来”降级为体验问题。
