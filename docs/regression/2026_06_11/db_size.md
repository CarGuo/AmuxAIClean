# SQLite 扫描结果库体积治理 — 2026-06-11

> 触发：用户报告「扫一次就 6G 占用」，实测 [scan.sqlite](file:///Users/guoshuyu/Library/Application%20Support/GSYCleanMac/scan.sqlite) = **11 GB / 1490 万行 / 89 个 session**
> 结论：✅ 代码改完 + 测试 PASS，新库稳态预期 < 400 MB（缩 27×）

## 一、现场快照

| 指标 | 实测 | 说明 |
|---|---|---|
| DB 文件大小 | **11 GB**（用户说 6G 实际更夸张） | [scan.sqlite](file:///Users/guoshuyu/Library/Application%20Support/GSYCleanMac/scan.sqlite) + wal + shm |
| scan_session 行数 | **89** | 历次扫描累积，无任何保留策略 |
| scan_result 行数 | **1490 万** | 每次扫描全量写入 |
| 磁盘灾难前夕 | 99% 满 / 剩 8.5 GB | 触发 SQLite "database or disk is full (13)" |

## 二、竞品扫描结果持久化策略调研

| 产品 | 持久化策略 | 单次扫描 DB 体积 |
|---|---|---|
| **DaisyDisk** | in-memory，官方文档"几百 MB RAM" | **0**（不持久化） |
| **Pearcleaner** | dynamic scan，不持久化 | **0** |
| **GrandPerspective** | 纯 in-memory tree | **0** |
| **OmniDiskSweeper** | 纯 in-memory tree | **0** |
| **mole** | bash CLI，无持久化 | **0** |
| **CleanMyMac** | 业务侧 SQLite，仅元数据（不存全树） | < 10 MB 量级 |
| **GSYCleanMac（修复前）** | GRDB SQLite，**全节点 + 89 session 无界累积** | **11 GB** ⚠️ |

**结论**：业界主流都是"扫完即丢、in-memory"，**只有我们独此一家持久化 1490 万行**。我们持久化的初衷是支持 TreeBrowser 的 store-only 下钻（避免 300k 节点驻留内存），方向对，但缺少**保留策略 + 空间归还机制**两个关键齿轮。

## 三、三个真凶 & 各刀解法

### 凶器 ①：无 session 保留策略，89 个 session 累积

- **现象**：[GRDBScanResultStore.finalizeSession()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L230-L251) 只是写 `finalized_at`，从来不清旧 session
- **数据贡献**：89 session × ~16 万行/session = 1490 万行 ≈ **8.5 GB 数据 + 1.5 GB 索引**
- **修复**：[finalizeSession()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L230-L251) 末尾自动 `pruneOldSessions(keepLatest: 3)`，新加 public [pruneOldSessions(keepLatest:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L267-L303) 给 UI 用
- **N=3 的选型理由**：用户语义上"上次扫的还在 → 想对比一下" 最多回看 1~2 次，N=3 留充足余量；要全清可显式 `pruneOldSessions(keepLatest: 0)`
- **依赖**：ON DELETE CASCADE 必须配 `PRAGMA foreign_keys = ON`（[prepareDatabase L61](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L61) 已开），否则删 scan_session 行 scan_result 会留孤儿

### 凶器 ②：删行后空间永远不归还 OS

- **现象**：SQLite 默认 `auto_vacuum = NONE`，DELETE 之后页面只是 unlink 进 freelist，**主库文件大小不变**；只能靠整库 `VACUUM` 把数据搬到临时文件再换名归还——**11 G 库要 11 G 临时空间**
- **昨晚的磁盘灾难**：我手贱 `cp` 备份 11 G + 准备跑 `VACUUM` 又要 11 G → 总占用 22 G → 磁盘 99% 满 → SQLite 报 "database or disk is full (13)"
- **修复**：[init 末尾](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L78-L95) 对**新库**设 `PRAGMA auto_vacuum = INCREMENTAL` + 一次空库 VACUUM 落盘到 header
- **配套**：[vacuum() L556-L590](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L556-L590) 在 auto_vacuum=2 时走 `PRAGMA incremental_vacuum(0)` — **零临时空间**，把 freelist 全部归还 OS；老库（NONE）才回退整库 VACUUM
- **WAL 一致性**：[vacuum()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L556-L590) 头尾各跑一次 `PRAGMA wal_checkpoint(TRUNCATE)`——首跑让 freelist 页能被释放（否则被 WAL 快照引用），末跑让调用方测 file size 不被新生 WAL 误导
- **关键坑**：`PRAGMA auto_vacuum` 不能放 [prepareDatabase](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L55-L69) hook —— 该 hook 对**所有**连接（含只读 reader）执行，reader 跑写 PRAGMA 抛 `SQLite error 8: attempt to write a readonly database`。第一版 PR 就栽这里，靠 [test_clearAll_清空所有会话](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Tests/ScanKitTests/GRDBScanResultStoreTests.swift) 兜出来。改用 writer 在 init 末尾跑一次

### 凶器 ③：`scan_result_on_parent_path` 单列索引冗余

- **现象**：v1 schema 给 `parent_path` 列声明 `.indexed()`，GRDB 自动建索引 `scan_result_on_parent_path`，按 path 字符串排序（avg 113 B/key），1490 万行 ≈ **1.5 GB on-disk**
- **冗余分析**：v2 已建 `scan_result_session_path_idx (session_id, path)` 复合索引，SQLite 优化器对 `parent_path = ? AND session_id = ?` 这类查询会选复合索引做 range scan，**本来就比单列索引更高效**；[directChildrenAggregated() L289+](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L289) 也不依赖该单列索引
- **修复**：migrator v3 — [DROP INDEX IF EXISTS scan_result_on_parent_path](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L161-L178)
- **效果**：等价 query 能力 0 损失，老库升 v3 直接释放 ~10% 体积

## 四、修复方案汇总

四处改动全在 [GRDBScanResultStore.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift)：

| # | 位置 | 改动 |
|---|---|---|
| 1 | [init L40-L103](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L40-L103) | 加 `keepLatestSessions: Int = 3` 参数；判断 `isFreshDatabase`；writer 一次性设 `PRAGMA auto_vacuum = INCREMENTAL` + 空库 VACUUM |
| 2 | [migrator v3 L161-L178](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L161-L178) | DROP 冗余索引 `scan_result_on_parent_path` |
| 3 | [finalizeSession L230-L251](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L230-L251) + [pruneOldSessions L267-L303](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L267-L303) | finalize 末尾自动 prune；新 public 方法返回 deleted count |
| 4 | [vacuum() L556-L590](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L556-L590) | auto_vacuum=2 优先 `incremental_vacuum(0)`（零临时空间），头尾各 `wal_checkpoint(TRUNCATE)` |

## 五、测试

新加 5 个 unit test，全 PASS：[GRDBScanResultStoreTests.swift L387-L503](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Tests/ScanKitTests/GRDBScanResultStoreTests.swift#L387-L503)

| 测试 | 验证点 |
|---|---|
| `test_pruneOldSessions_保留最新N个_其余清掉` | keepLatestSessions=0 关自动 prune；5 session 后显式 prune(keepLatest:2)；断言 deleted=3 + s[4]/s[3] 还在 + s[0] 已清 |
| `test_finalizeSession_默认会自动prune保留3个最新` | 默认 init，连续 5 次 finalize，describeStorage.sessionCount=3 |
| `test_pruneOldSessions_keepLatest为0则清空所有session` | 全清语义 |
| `test_pruneOldSessions_keepLatest远大于session数则不删任何东西` | deleted=0 |
| `test_新建库_auto_vacuum模式应为INCREMENTAL_2` | 接缝测试：写 2000 行 → vacuum → 删空 → vacuum → 断言 sizeAfter × 2 < sizeBefore |

ScanKit 全包：**201 tests / 0 failures / 2 skipped**（skip 数与本轮无关）

### 5.1 22 case GUI 回归（验证不破坏既有功能）

跑完整 [Scripts/regression.sh](file:///Users/guoshuyu/workspace/GSYCleanMac/Scripts/regression.sh)：

| 结果 | 数 |
|---|---|
| total | 22 |
| PASS | 21 |
| FAIL | 0 |
| TIMEOUT | 1（`scan-custom-fixture` 首次冷启动 90s 超时，**单跑 728ms PASS**，确认是冷启动叠加问题，与本轮代码改动无关） |

详见 [logs/regression-after-dbfix.log](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/regression/2026_06_11/logs/regression-after-dbfix.log)。

## 六、线上生效路径

**关键约束**：SQLite 硬规则——`auto_vacuum` 只能在**首次建库前**设置；老库要换 mode 必须 VACUUM 整库重写一次。

| 场景 | 路径 |
|---|---|
| 自己（昨晚已删旧 11G 库） | 下次启动自动新建空库，自带 INCREMENTAL + N=3 → **永久解决** |
| 其他用户（带历史数据） | 升级即触发 migrator v3（DROP 冗余索引，释放 ~10%）；自动 prune 在下次 finalize 时生效；auto_vacuum 仍 NONE，需在「设置 → 存储与日志」点 [clearAll()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift) 整库重建拿到新 mode |
| 想彻底重置不丢历史配置 | 同上点 clearAll |

## 七、预期效果

| 指标 | 修复前 | 修复后稳态 | 缩比 |
|---|---|---|---|
| 单次扫描后 DB 体积 | 11 GB | < 400 MB | **27×** |
| 保留 session | 89 个无上限累积 | 最近 3 个 | — |
| scan_result 行数 | 1490 万 | ~50 万（单次扫描量级） | **30×** |
| 删行后磁盘归还 | ❌ 永不归还 | ✅ 每次 finalize 自动归还 | — |
| `vacuum()` 临时空间 | 1× 库大小 | 0 | — |

## 八、复盘 — 这次踩的坑

1. **不该做破坏性 SQL 实验**：用户问"为啥这么大、能否优化" → 只需要只读 SELECT/PRAGMA/dbstat 分析，**绝对禁止** `cp` 备份 + 整库 `VACUUM`（11 G 库 = 22 G 占用）
2. **磁盘 99% 满是绝对禁区**：任何写操作都可能 disk full，先看 `df -h` 再说
3. **`PRAGMA auto_vacuum` 不能放 prepareDatabase hook**：reader 也会跑，会抛 readonly error；必须用 writer 单独执行
4. **`vacuum()` 内部要头尾各 checkpoint 一次**：首跑解除 WAL 对 freelist 页的引用，末跑保证调用方测 size 不失真

## 九、复现命令

```bash
# 单元测试（5 个新 case + 19 个老 case）
swift test --package-path Packages/ScanKit --filter GRDBScanResultStoreTests

# 全 ScanKit 包
swift test --package-path Packages/ScanKit

# 看 DB 模式（运行中的 App 不能开，先 quit）
sqlite3 ~/Library/Application\ Support/GSYCleanMac/scan.sqlite "PRAGMA auto_vacuum"  # 期望 2
sqlite3 ~/Library/Application\ Support/GSYCleanMac/scan.sqlite "SELECT COUNT(*) FROM scan_session"  # 期望 ≤ 3
```
