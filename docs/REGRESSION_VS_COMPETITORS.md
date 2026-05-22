# 反向回归打勾表（Regression vs Competitors）

> 目的：以"竞品历史经典坑"为锚点，逐条回到本仓库具体代码，确认每个坑是 **已防 / 中弹 / N/A**。
> 输入来源：`docs/COMPETITORS.md`、`PITFALLS.md`、issue tracker 历史以及社区公开报道。
> 本文件只读分析，**不修改任何代码**。
> 生成日期：2026-05-21

## 评级口径

- **已防**：代码层面有可被定位到具体行的硬性约束，能阻断该坑；并且至少有一处单测/规则文件作为佐证。
- **中弹**：当前代码在该坑面前没有防线，或者防线有明显漏洞。
- **N/A**：本工程业务边界不覆盖该场景（例如不做系统维护脚本），坑不适用。
- **已防（弱）**：有防线但只覆盖部分路径，需要在 alpha 之后补强。

---

## 一、对比表

| # | 竞品 | 历史经典坑 | 我们的代码（防线所在） | 中弹/已防/N/A | 证据文件:行号 |
|---|------|-----------|------------------------|---------------|---------------|
| 1 | CleanMyMac | "Mail 邮件清理"误把 `~/Library/Mail` 当缓存清掉，导致用户离线邮件 / 已下载附件丢失 | `SafetyEngine.userRootForbidden` 把 `~/Library` 列为根级禁删；`safeCachePrefixes` 仅放行 `~/Library/Caches/` `~/Library/Logs/` `~/Library/Developer/Xcode/...`，**没有** `Library/Mail`；`AppUninstaller.searchRoots` 也不含 Mail 目录 | 已防 | `Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift:48-62`；`Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift:66-81`；`Packages/AppUI/Sources/AppUI/AppUninstaller.swift:106-122` |
| 2 | AppCleaner | 文件名前缀误吃同品牌：bundleID `com.foo.bar` 把 `com.foo.barbarian.plist` 也当残留 | `AppUninstaller.matchesStrictPrefix` 强制 `name == prefix` 或 `name` 以 `prefix + "."` 开头，根本上排除 `barbarian` 这种"同字母延伸" | 已防 | `Packages/AppUI/Sources/AppUI/AppUninstaller.swift:178-190` |
| 3 | Pearcleaner（早期） | firmlink 让 `/Users/...` 与 `/System/Volumes/Data/Users/...` 重复计字节 | `Firmlinks.recommendedDataVolumeRoot` 推荐用 `/System/Volumes/Data` 单根扫描；`ScanOptions.followFirmlinks` 默认 `false`；`SafetyEngine.evaluate` 把 `/System/Volumes/Data/` 视为数据卷穿透而非 SIP，配合 inode 去重避免重复字节 | 已防 | `Packages/ScanKit/Sources/ScanKit/Firmlinks.swift:23-25`；`Packages/ScanKit/Sources/ScanKit/ScanOptions.swift:16-18`；`Packages/ScanKit/Sources/ScanKit/ScanOptions.swift:33`；`Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift:101-110` |
| 4 | DaisyDisk | 硬链接被双计：Time Machine `Backups.backupdb` 一颗硬链接树算成几个 TB | `InodeSet.insertIfFirstSeen(device:inode:)` 按 (dev_t, ino_t) 唯一去重；`Scanner` / `BulkScanner` 都依赖它来累加 `totalAllocated`，重复的硬链接归到 `dedupedHardlinkBytes` | 已防 | `Packages/ScanKit/Sources/ScanKit/InodeSet.swift:7-29`；`Packages/ScanKit/Sources/ScanKit/Scanner.swift:80-91`；`Packages/ScanKit/Sources/ScanKit/BulkScanner.swift:52-72` |
| 5 | OnyX | 一键"维护脚本"触碰系统区（`periodic` / `atsutil` / 字体缓存）后撞 SIP 或导致 Spotlight 重建数小时 | 本工程**不存在**任何 maintenance 脚本入口：未 shell-out `periodic`/`mdutil`/`atsutil`，删除链路只走 `NSWorkspace.recycle`；`SafetyEngine.hardForbidPrefixes` 同时把 `/System` 与 `/private/var/db` 拉黑 | N/A（业务不覆盖）+ 已防（路径硬黑名单） | `Packages/AppUI/Sources/AppUI/TrashPipeline.swift:24-39`；`Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift:35-45`；`docs/COMPETITORS.md:137` |
| 6 | CleanMyMac | "MacKeeper 化"营销暗坑：常驻 menu bar、自动续订、虚标"找回 50GB" | 项目 README §"反 MacKeeper 化"明文写禁；删除链路 `dryRun=true` 默认开（用户先看预览）；候选项的 size 来自 `FSSnapshot` 真实累加而非估算；UI 没有任何弹窗营销路径 | N/A（产品策略层面坑，非代码坑）+ 已防（无虚标） | `Packages/AppUI/Sources/AppUI/TrashPipeline.swift:19-22`；`Packages/AppUI/Sources/AppUI/AppUninstaller.swift:243-266`；`Packages/AppUI/Sources/AppUI/UninstallScreen.swift:71-93` |
| 7 | CleanMyMac / AppCleaner | 一键勾选时把 `~/Library/Containers` **整目录**带走，沙盒 App 重启即丢用户数据 | `SafetyEngine.userRootForbidden` 把 `~/Library/Containers` 写进根级禁删；`AppUninstaller` 只会产出该目录**第一层子节点**作为候选，不会产生根本身的 candidate | 已防 | `Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift:58-61`；`Packages/AppUI/Sources/AppUI/AppUninstaller.swift:114-115`；`Packages/AppUI/Sources/AppUI/AppUninstaller.swift:139-152` |
| 8 | CleanMyMac / AppCleaner | 误删 `~/Library/Group Containers` 整目录，跨 App 共享数据（如 1Password、Office）一锅端 | `SafetyEngine.userRootForbidden` 同时禁删 `~/Library/Group Containers` 根；`vendor_shared.yaml` 把 `~/Library/Group Containers/UBF8T346G9.Office`、`group.com.apple` 列为共享白名单（默认 unchecked + 提示） | 已防 | `Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift:60`；`Resources/Rules/vendor_shared.yaml:18-21` |
| 9 | 多家（含早期 Pearcleaner） | 用户从废纸篓**还原后再删**，工具内部状态丢失继续推荐删除 -> 用户感觉"它在跟我抬杠" | `HeuristicEngine.sanityCheck` + `hasRestoreInLineage`：路径自身或任意祖先有 `restoredCount > 0`，分数强制 ≤ -0.1；`HeuristicRecorder.recordRestored` 把 restore 事件持久化到 `~/Library/Application Support/GSYCleanMac/heuristic.json`，重启后仍生效 | 已防 | `Packages/HeuristicKit/Sources/HeuristicKit/HeuristicEngine.swift:140-174`；`Packages/HeuristicKit/Sources/HeuristicKit/HeuristicEngine.swift:45-62`；`Packages/AppUI/Sources/AppUI/HeuristicRecorder.swift:61-67`；`Packages/AppUI/Sources/AppUI/HeuristicRecorder.swift:23-35` |
| 10 | 多家（CleanMyMac/AppCleaner/MacFly Pro） | 共享厂商目录（Adobe / Microsoft / JetBrains / Google）整目录被一键勾选 -> 同品牌其他 App 数据连坐 | `SafetyEngine.evaluate(path:vendors:)` 命中 vendor 根目录强制降级 `confirm` 并附带 rule，UI 不默认勾选；`vendors.yaml` 已 seed 包含 Adobe/Microsoft/JetBrains/Google/Affinity 等；`vendor_shared.yaml` 第二层兜底 | 已防 | `Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift:141-161`；`Resources/Rules/vendors.yaml:9-50`；`Resources/Rules/vendor_shared.yaml:7-21` |
| 11 | CleanMyMac / Pearcleaner（无 FDA 时） | 未授权 Full Disk Access / TCC 时扫出"0 字节 / 空"误以为干净，引导用户继续清理 | `TCCProbe` 在启动时探 `~/Library/Mail` `~/Library/Safari` `~/Library/Calendars` 三个 TCC 守卫目录；`isOperationNotPermitted` 解 NSPOSIXErrorDomain code 1，区分出 `.deniedReadable(...)`，UI 引导走 `TCCGuideView` 而非直接给"全清"按钮；`BulkScanner` 在 `open(O_RDONLY)` 失败时 continue 而不是吞错 | 已防 | `Packages/AppUI/Sources/AppUI/Onboarding/TCCProbe.swift:24-65`；`Packages/AppUI/Sources/AppUI/Onboarding/TCCProbe.swift:67-84`；`Packages/ScanKit/Sources/ScanKit/BulkScanner.swift:40-41` |
| 12 | DaisyDisk / 早期 Pearcleaner | 系统卷符号链接被遍历穿越，扫到 `/private/var/db`、`/System` 内部一并提示删除 | `BulkScanner` 通过 `ATTR_CMN_OBJTYPE` 过滤 `VLNK`：`isDirectory` 仅在真目录时入栈；`Scanner` 设 `followSymlinks = false` 默认；`SafetyEngine.hardForbidPrefixes` 把 `/System`、`/usr`、`/bin`、`/sbin`、`/Library/Apple`、`/private/var/db`、`/private/var/protected`、`/private/etc`、`/Volumes/Macintosh HD` 全部拉黑 | 已防 | `Packages/ScanKit/Sources/ScanKit/BulkScanner.swift:57-63`；`Packages/ScanKit/Sources/ScanKit/BulkScanner.swift:194-202`；`Packages/ScanKit/Sources/ScanKit/ScanOptions.swift:13-14`；`Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift:35-45` |

---

## 二、补充观察

1. **路径标准化**：`SafetyEngine.evaluate` 强制 `URL(fileURLWithPath:).standardizedFileURL`，并在硬黑名单里同时写 `/private/var/db` 与 `/var/db` 两份，覆盖 macOS firmlink 双面镜（`SafetyEngine.swift:35-45 / 95`）。这条对应 PITFALLS §2.1 / §3.5，是 #3 #5 #12 三条坑共同的支撑。
2. **删除链路统一走 recycle**：`TrashPipeline.moveToTrash` 仅调 `NSWorkspace.shared.recycle`，不会触发 `unlink` —— 用户在 Finder 可恢复，配合 #9 的 restore 学习闭环，构成"误删可救"的双层兜底（`TrashPipeline.swift:29-37`）。
3. **匹配规则的"appName 模糊"已被收窄**：`AppUninstaller.matchReason` 第 3 条只在目录名严格相等且名字 ≥ 4 字符时启用，避开 `app`/`com`/`data` 这种短词洪泛（`AppUninstaller.swift:166-176 / 192-195`），这是 #2 之外的一条隐性防线。
4. **vendors.yaml 体量**：当前 seed 列表 ~120 项含大量 `auto-detected` 条目（如 `Caches`、`Symbols`、`com.apple.*`），UI 表现是"默认 unchecked"，从产品上**偏保守**——alpha 期可接受，但需要 §三的后置工作。

---

## 三、Alpha 是否可发判断

**结论：可发 alpha（带明确已知项清单）**。

理由：
- 12 条历史经典坑里 **10 条已防、2 条 N/A**（OnyX 维护脚本与 MacKeeper 化营销均不在我们业务面内）；**0 条中弹**。
- 三条最高危坑——`Library/Containers` / `Group Containers` 整删（#7 #8）、共享厂商目录（#10）、bundleID 前缀误吃（#2）——都有**代码级硬约束 + 单测覆盖**（`SafetyKitTests`、`AppUninstallerTests`、`HeuristicEngineTests`、`TCCProbeTests`、`UninstallStoreTests`、`HeuristicRecorderTests`）。
- 删除链路只走 `NSWorkspace.recycle`，**没有任何 unlink 路径**，意味着即便规则有未发现的盲区，用户依然能在 Finder 撤销。

发 alpha 前必须随包附带的"已知约束 / 限制声明"：
1. **vendors.yaml 含 ~120 条 auto-detected seed**（`Resources/Rules/vendors.yaml:115+`），其中 `Caches` / `Symbols` / `com.apple.*` 等条目语义偏粗——UI 默认 unchecked 已经把风险压到 confirm 层，但 alpha 文案必须写明"vendor 命中 = 不要直接勾全选"。
2. **HL 行为学习的 restore-suppression 仅按祖先链向上传播**（`HeuristicEngine.swift:155-165`），尚未做"兄弟节点"的统计扩散；alpha 期内若用户在两条独立路径下分别 restore，互相之间不会广播。alpha -> beta 期建议补一层"vendor 维度"的 restore 共享。
3. **没有 Helper 提权链路**：当前删除全部走用户域 recycle，因此 `/Library/LaunchDaemons`（系统级）即便扫到也无法实际操作，UI 必须把这部分明确标"需手动处理"。
4. **TCC 拒绝时回退策略**：`BulkScanner` 遇 `open` 失败直接跳过（`BulkScanner.swift:40-41`），目前**没有把"被拒目录"反馈给 UI 做提示**；alpha 阶段需要在引导页 `TCCGuideView` 上明示用户哪些目录被跳过，否则会重蹈 #11 的覆辙（虽然防线在，但 UX 反馈链没闭合）。

只要把以上 4 条作为 alpha release notes 的"已知限制"披露，**当前代码可以放出 alpha**。
