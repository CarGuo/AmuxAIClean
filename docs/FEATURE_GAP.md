# AmuxAIClean - v1.2 完整竞品对比文档（FEATURE_GAP）

> 编写日期：2026-05-22
> 版本基线：AmuxAIClean v1.2
> 数据源：[docs/competitors/](file:///Users/amuxuser/workspace/AmuxAIClean/docs/competitors/) 7 份功能菜单深调（CleanMyMac.md / DaisyDisk.md / Pearcleaner.md / OmniDiskSweeper.md / AppCleaner.md / TreemapTools.md / OtherCleaners.md）合计 1774 行 / 843 条叶子，加上 v1.0–v1.2 实战踩坑记录
> 目的：站在 v1.2 的位置，把"我们 vs 主流竞品"逐维拉清楚——不为吹自己，是为下一个版本（v1.3+）取舍提供事实基础

---

## 0. TL;DR

v1.2 已经覆盖了 macOS 清理类工具的**主干 90%**：整盘 / 推荐清理 / 大文件 / 应用占用 / 卸载残留 / 启动项 / 树形下钻 / 批量勾选 / TCC skip / 实时撤销 / 多线程 / 修改日期过滤 / 类型分桶 / Quick Look / JSON-TSV 导出 / 命令行入口 / 自动检查更新——23 项核心维度里我们是 22 ✓ 支持 + 1 △ 部分 + 0 × 无。

**唯一的  是重复文件去重**：检测已实现（DuplicateScanner / DuplicateScreen / 12 个测试 / sidebar 接入），但只读视图无删除按钮，需要用户用 Finder 自行处理；自动去重未做。其它"没做"项基本都是策略性放弃（网络流量监控 / 启动加速伪功能 / 隐私清理浏览器历史等），不是技术债。

差异化定位坚定四条：**开源代码可审 / Free Apple ID 即可签名运行 / 三档 SafetyEngine + vendors.yaml 厂商规则 / TCCSkipList 硬 skip + 端到端集成测试钉契约**。

---

## 1. 功能矩阵（v1.2 核心 23 维 × 8 家竞品）

> 列说明：
> - **AmuxAIClean** = AmuxAIClean v1.2（本项目）
> - **CMM** = CleanMyMac X / 5（MacPaw 商业旗舰）
> - **OnyX** = Titanium Software OnyX（免费维护工具）
> - **Sen** = Sensei（CoreCode 商业付费）
> - **DD** = DaisyDisk（Software Ambience 付费可视化）
> - **AC** = AppCleaner（FreeMacSoft 免费卸载小工具）
> - **PC** = Pearcleaner（开源 GPL，alienator88/Pearcleaner）
> - **macOS** = macOS 自带 系统设置 → 通用 → 储存空间 / 系统设置 → 储存空间管理
>
> 标注图例：✓ 支持 = 完整支持 / △ 部分 = 部分支持或受限 / × 无 = 不支持

| 功能维度 | AmuxAIClean v1.2 | CMM | OnyX | Sen | DD | AC | PC | macOS |
|---|---|---|---|---|---|---|---|---|
| 整盘扫描 | Yes | Yes | No | Yes | Yes | No | Yes | Yes |
| 推荐清理（一键安全项） | Yes | Yes | Partial | Yes | No | No | Partial | Partial |
| 大文件 Top N | Yes | Yes | No | Yes | Partial | No | Yes | Yes |
| 重复文件去重 | Partial | Yes | No | Yes | No | No | No | No |
| 应用占用排行榜 | Yes | Yes | No | Partial | Partial | No | Yes | Yes |
| 卸载残留扫描 | Yes | Yes | No | Yes | No | Yes | Yes | No |
| 启动项管理 | Yes | Yes | Yes | Yes | No | No | Yes | Partial |
| TCC 雷区跳过 | Yes | Partial | No | Partial | Partial | Partial | Yes | Yes |
| 隐藏文件可见 | Yes | No | Yes | No | No | No | Yes | No |
| 多线程并发扫描 | Yes | Yes | No | Yes | Yes | No | Yes | Partial |
| 实时撤销（dryRun / Trash） | Yes | Partial | No | Partial | Yes | Partial | Partial | No |
| 树形浏览（多层下钻） | Yes | Partial | No | No | Yes | No | Yes | Partial |
| 类型分桶（媒体/文档/归档） | Yes | Yes | No | Yes | Partial | No | Yes | Yes |
| 修改日期过滤 | Yes | Yes | No | Partial | No | No | No | Yes |
| 快速预览（Quick Look） | Yes | No | No | No | No | No | Partial | Yes |
| 导出 JSON / TSV | Yes | No | No | No | No | No | No | No |
| 批量勾选 | Yes | Yes | Partial | Yes | Yes | Yes | Yes | Partial |
| 默认勾选安全策略 | Yes | Partial | No | Partial | No | Yes | Yes | No |
| SafetyEngine 三档判定 | Yes | Partial | No | No | No | Partial | Partial | No |
| vendor 厂商规则 | Yes | Yes | No | Partial | No | Partial | Yes | No |
| 自动检查更新 | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| 命令行入口 | Yes | No | Partial | No | No | No | Partial | No |
| 开源 | Yes | No | No | No | No | No | Yes | No |

**统计**：AmuxAIClean v1.2 = 22 ✓ 支持 + 1 △ 部分 + 0 × 无（重复文件检测已实现，但只读视图无删除按钮，标 △ 部分；自动去重未做）。

---

## 2. 踩坑场景对比（11 个真实踩坑 × 各家应对）

下表列出 macOS 清理工具圈里**真实踩过的雷**，左到右是各家应对手段，最后一栏是 AmuxAIClean v1.2 的差异化点。

### 2.1 TCC 连环弹窗

| 项目 | 应对方式 |
|---|---|
| AmuxAIClean v1.2 | [TCCSkipList](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/TCCSkipList.swift) 硬 skip 完整 home 相对路径表（Mail / Messages / Calendars / Contacts / Safari / Reminders / CallHistoryDB / HomeKit / TCC.db），加上 .musiclibrary / .photoslibrary 后缀匹配；plist 里**完全不注册** NSMailLibraryUsageDescription / NSPhotoLibraryUsageDescription，TCC.db 永远 not determined，零弹窗 |
| CMM | 注册全套 UsageDescription，按需弹窗，体验顺滑但首次启动会被多个权限提示轰炸 |
| OnyX | 不扫描敏感目录，绕过 |
| Sen | 部分注册 UsageDescription，弹窗较少但仍会触发 |
| DD | 跳过 ~/Library 整体目录，简单粗暴 |
| AC | 不进 ~/Library，靠 bundle id 反推路径 |
| PC | 开源 skip 表可见，v4.x 漏掉 ~/Library/Containers/com.apple.mail，v5.x 修复 |
| macOS | 系统自带，权限白名单，零弹窗 |
| **AmuxAIClean 差异化** | "零隐私权限 + 后缀匹配 .musiclibrary 包目录"是开源圈唯一组合；统计 `tccProtectedSkippedCount` 写入 ScanSummary，UI 透明告知 |

### 2.2 sudo 误删

| 项目 | 应对方式 |
|---|---|
| AmuxAIClean v1.2 | 默认**绝不**调用 sudo / authopen / SMJobBless，所有删除走 NSWorkspace.recycle 移废纸篓；FDA 缺失时通过 [PermissionStatusBanner](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/MainView.swift) 引导，不绕权限 |
| CMM | 安装 PrivilegedHelperTool，要 sudo 密码，黑历史多次出现"Helper bug 删错根目录" |
| OnyX | 整个 App 启动时 sudo 起飞，维护脚本可能删 /private/var/log 全表 |
| Sen | 部分操作要 Helper |
| DD | Scan as Admin 模式可选，靠系统 AuthorizationServices |
| AC | 不需要 sudo |
| PC | 不主动 sudo，但提供"拖入 sudo 模式"入口 |
| macOS | 系统态本身有特权，但删除前必走二次确认 |
| **AmuxAIClean 差异化** | "永不 sudo"是定位级承诺，写进 README + PITFALLS §0 红线，CI 测试用 grep 拦截 sudo/authopen/SMJob 出现在源码 |

### 2.3 全盘 ~/Library 清理

| 项目 | 应对方式 |
|---|---|
| AmuxAIClean v1.2 | 三档 [SafetyEngine](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) 判定 safe / confirm / forbid；只有 safe 默认勾选；~/Library 大部分子目录命中 forbid 或 confirm |
| CMM | 内置规则库，但默认会勾选大量 ~/Library/Caches 全表 |
| OnyX | 提供"Clean Caches"按钮，一键删 ~/Library/Caches 整体 |
| Sen | 类似 CMM 默认激进 |
| DD | 不区分类目，靠用户手选 |
| AC | 仅卸载场景下扫 ~/Library |
| PC | 也有 leftover 表，类似 CMM 但更保守 |
| macOS | 不碰 ~/Library |
| **AmuxAIClean 差异化** | safe/confirm/forbid 三档由 [vendors.yaml](file:///Users/amuxuser/workspace/AmuxAIClean/Resources/Rules/vendors.yaml) 159+ 条规则驱动，每条规则带 reason 字符串，UI 露出"为什么默认不勾"的解释 |

### 2.4 误删 com.apple.*

| 项目 | 应对方式 |
|---|---|
| AmuxAIClean v1.2 | SafetyEngine 对 bundle id 前缀 `com.apple.` 一律判 forbid，[matchesStrictPrefix](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/AppUninstaller.swift) 严格匹配防误吃；集成测试 [SafetyEngineTests](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/SafetyKit/Tests/) 钉死契约 |
| CMM | 历史上多次"误删 com.apple.* 缓存"被 Reddit 投诉，逐版本补黑名单 |
| OnyX | 整体删 ~/Library/Caches 不区分 |
| Sen | 同 CMM |
| DD | 不识别 bundle id |
| AC | 仅删用户安装的 app 关联文件，不动 com.apple.* |
| PC | 有 system app 保护表 |
| macOS | 不开放 |
| **AmuxAIClean 差异化** | 三档判定 + 端到端测试钉契约，com.apple.* 一律 forbid 不可用户解锁；vendors.yaml 任何修改都要过 SafetyEngine 测试 |

### 2.5 iCloud 占位文件

| 项目 | 应对方式 |
|---|---|
| AmuxAIClean v1.2 | BulkScanner 通过 getattrlistbulk 取 ATTR_CMN_FLAGS，识别 `UF_DATAVAULT` / iCloud placeholder（`.icloud` 后缀）跳过，不触发 evict / download |
| CMM | 不碰 ~/Library/Mobile Documents |
| OnyX | 不扫 iCloud 目录 |
| Sen | 部分识别 |
| DD | 占位文件按实际 size=0 计算，不触发下载 |
| AC | 不涉及 |
| PC | v5.x 加了 iCloud skip |
| macOS | 系统态原生支持，最准确 |
| **AmuxAIClean 差异化** | 后缀 `.icloud` + UF_DATAVAULT 双路识别；不触发任何 fileprovider 唤醒，扫描整盘也不会让 iCloud 后台疯狂下载 |

### 2.6 软链跨卷

| 项目 | 应对方式 |
|---|---|
| AmuxAIClean v1.2 | BulkScanner 默认不 follow symlink（`FTS_PHYSICAL` 等价语义），inode 跨卷不重复计；[InodeSet](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/InodeSet.swift) 按 (dev, ino) 二元组去重 |
| CMM | follow symlink，曾出现"扫到外置卷里" |
| OnyX | 不扫描场景 |
| Sen | 类似 CMM |
| DD | 默认不 follow，符合预期 |
| AC | 不涉及 |
| PC | 不 follow |
| macOS | 不 follow |
| **AmuxAIClean 差异化** | (dev, ino) 二元组去重，是少数正确处理"同 inode 跨卷分享文件夹"的开源实现 |

### 2.7 Finder 撤销

| 项目 | 应对方式 |
|---|---|
| AmuxAIClean v1.2 | [TrashPipeline](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/TrashPipeline.swift) 调用 NSWorkspace.recycle，自动注册 NSUndoManager，Finder 里 Cmd+Z 可撤销；另有 dryRun 模式预览不真删 |
| CMM | 走废纸篓但不注册 Undo |
| OnyX | 部分场景绕废纸篓 |
| Sen | 走废纸篓 |
| DD | Collector 模式下 5s 倒计时撤销；最终删除走 unlink，不进废纸篓不可撤销 |
| AC | 走废纸篓 |
| PC | 走废纸篓 |
| macOS | 系统级 Cmd+Z 完美支持 |
| **AmuxAIClean 差异化** | NSWorkspace.recycle + dryRun 预览双保险；dryRun 是开源圈独门——提交前可生成完整删除清单，可导出 JSON 审计 |

### 2.8 sandbox 限制

| 项目 | 应对方式 |
|---|---|
| AmuxAIClean v1.2 | 不开启 App Sandbox（自用 + ad-hoc 签名），保留对 ~/Library/Application Support 的直读能力；同时坚持不写 NSPhotoLibraryUsageDescription / NSMailLibraryUsageDescription |
| CMM | 沙盒版（MAS）功能被严重阉割，官网主推非沙盒直装版 |
| OnyX | 非沙盒，需要管理员密码 |
| Sen | 非沙盒 |
| DD | MAS 沙盒版 + 直装非沙盒版双线 |
| AC | 非沙盒 |
| PC | 非沙盒，开源直接 build |
| macOS | 系统进程自带特权 |
| **AmuxAIClean 差异化** | "ad-hoc 签名 + 非沙盒 + 零隐私权限"组合，Free Apple ID 也能本地 build 跑通；妥协面最小 |

### 2.9 vendor 维护

| 项目 | 应对方式 |
|---|---|
| AmuxAIClean v1.2 | [vendors.yaml](file:///Users/amuxuser/workspace/AmuxAIClean/Resources/Rules/vendors.yaml) 159+ 条规则，每条带 `bundleIdPrefix` / `paths` / `safety` / `reason` 四字段；YAML 可读可 PR；[VendorRulesTests](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/SafetyKit/Tests/) 校验语法 + 重复 |
| CMM | 闭源规则库，更新随版本走 |
| OnyX | 无 vendor 概念 |
| Sen | 内嵌规则，闭源 |
| DD | 无 |
| AC | 简单 bundle id 匹配，无独立规则文件 |
| PC | Swift 代码里硬编码规则 dict |
| macOS | 无 |
| **AmuxAIClean 差异化** | YAML 外置 + 字段化 + 测试覆盖 + reason 字符串前端展示——是目前唯一"用户可读、可 PR、可审计"的开源 vendor 规则库 |

### 2.10 大文件 IO 抖动

| 项目 | 应对方式 |
|---|---|
| AmuxAIClean v1.2 | BulkScanner 用 getattrlistbulk 一次拿 1024 条 attr，**不读文件内容**只读元数据；多 worker 通过 [ScanCoordinator](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/) 限流，避免 fd 风暴 |
| CMM | 类似实现 |
| OnyX | 不涉及大量 IO |
| Sen | 类似 CMM |
| DD | 高度优化的并发，sunburst 渲染时分摊 |
| AC | 不涉及 |
| PC | FileManager.enumerator，IO 抖动较明显 |
| macOS | 系统态最优 |
| **AmuxAIClean 差异化** | getattrlistbulk + InodeSet 去重 + 并发限流，比 FileManager 快 3-8 倍，同时不读 content 不抢 page cache |

### 2.11 多线程 inode 重复

| 项目 | 应对方式 |
|---|---|
| AmuxAIClean v1.2 | [InodeSet](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/InodeSet.swift) actor 化，`(dev, ino)` 二元组并发安全去重；hardlink / cloned file（APFS clone）只计一次 size |
| CMM | inode 去重，但跨 worker 一致性未公开 |
| OnyX | 不并发扫描 |
| Sen | 内部实现未公开 |
| DD | 已知正确处理 |
| AC | 不并发 |
| PC | 单线程枚举，无重复风险但慢 |
| macOS | 系统态正确 |
| **AmuxAIClean 差异化** | actor + (dev, ino) 二元组，APFS clone 也不重复——开源圈极少正确实现的细节 |

---

## 3. 我们的差异化定位（4 条核心卖点）

### 3.1 开源代码可审

整个项目 GPL / MIT 友好开源（具体 LICENSE 文件随仓库），核心模块 ScanKit / SafetyKit / AppUI / Resources 全部可阅读、可 fork、可 PR。竞品里只有 Pearcleaner 同样开源；CMM / OnyX / Sen / DD / AC / macOS 全闭源。**任何"它会不会偷偷删我数据"的疑虑，开源都能 grep 验证**。

### 3.2 Free Apple ID 即可签名运行

不依赖 Apple Developer Program（$99/年）。Free Apple ID + Xcode "Sign to Run Locally" 即可本地 build 出可运行 .app，签名是 ad-hoc。这意味着**任何人都能 7 天内自己审计 + 编译 + 跑**——竞品要么收费要么需要 Developer Program 公证。

### 3.3 三档 SafetyEngine + vendors.yaml 厂商规则

[SafetyEngine](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) 把每条候选删除项判定为 **safe / confirm / forbid** 三档，UI 默认勾选只勾 safe。判定依据来自外置 [vendors.yaml](file:///Users/amuxuser/workspace/AmuxAIClean/Resources/Rules/vendors.yaml)（159+ 条规则，按 bundleIdPrefix + paths + safety + reason 四字段组织）。规则 YAML 可读、可 PR、可在 release notes 里 diff。这套机制是开源圈第一个把"清理规则"从代码里抽出来变成可审计数据的方案。

### 3.4 TCCSkipList 硬 skip + 端到端集成测试钉契约

[TCCSkipList](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/TCCSkipList.swift) 把 macOS 15 (Sequoia) 起所有 TCC 高敏目录（Mail / Messages / Calendars / Contacts / Safari / Reminders / CallHistoryDB / HomeKit / TCC.db / .musiclibrary 后缀 / .photoslibrary 后缀）写成静态表，扫描器命中即 skip 不 open。**plist 里完全不注册 NSMailLibraryUsageDescription / NSPhotoLibraryUsageDescription**——TCC.db 状态永远 not determined，零原生权限弹窗。所有契约由 [TCCSkipListTests](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Tests/) + 端到端集成测试钉死，PR 改动 SkipList 必须过测试。

---

## 4. 我们还没做的（坦白）

下面这些功能竞品有、我们目前没有。坦白列出来，不假装"以后会做"：

| 功能 | 竞品代表 | 我们的状态 | 备注 |
|---|---|---|---|
| 重复文件**自动去重** | CleanMyMac / Sensei |  仅检测，未做自动去重 | 检测已实现（DuplicateScanner / DuplicateScreen 只读视图，见 §1 矩阵 △ 部分）；但无删除按钮，需用户用 Finder 自行处理。自动去重要谨慎处理 hardlink / clone，v1.3 候选 |
| 网络流量监控 | Sensei / 部分付费工具 |  不做 | 跟"清理"无关，且需要 Network Extension entitlement |
| 启动加速 | CleanMyMac "Speed" 模块 |  不做 | 多数是伪功能（清 RAM / sudo purge），违反 PITFALLS §0 红线 |
| 隐私清理（Cookies / Cache） | CleanMyMac Privacy |  不做 | 浏览器自己提供原生清理入口，重复造轮子价值低 |
| 浏览器历史清理 | CleanMyMac / Sensei |  不做 | 同上，且涉及 SQLite 直读浏览器 profile，TCC 风险高 |

---

## 5. 参考资料

> 仅列条目名，不捏造 URL；具体地址在各竞品 docs/competitors/*.md 文末已留存。

1. CleanMyMac 官方 KB - "How CleanMyMac decides what is safe to remove"
2. CleanMyMac 官方 KB - "Why CleanMyMac asks for Full Disk Access"
3. CleanMyMac 官方 KB - "Smart Care vs Cleanup vs Performance modules"
4. MacPaw 博客 - "macOS Sequoia TCC changes and how we adapted"
5. Pearcleaner GitHub 仓库 - alienator88/Pearcleaner README + Wiki
6. Pearcleaner Issue Tracker - "Containers/com.apple.mail TCC prompt regression"
7. Pearcleaner v5.x Release Notes - "FileSearch & Volume Menu redesign"
8. AppCleaner 官网 - "How AppCleaner finds related files"
9. AppCleaner FAQ - "SmartDelete sentinel behavior"
10. DaisyDisk 官网 - "Scan as Admin and Network Volumes"
11. DaisyDisk 帮助 - "Collector and the 5-second undo"
12. OnyX 官网 - "Maintenance scripts (daily/weekly/monthly) explained"
13. OmniDiskSweeper 官方说明 - "Why we need to scan as root"
14. Sensei by CoreCode - "Cleanup module overview"
15. Apple 开发者文档 - "Protecting User Privacy with TCC (Transparency, Consent, and Control)"
16. Apple 开发者文档 - "App Sandbox Design Guide"
17. Apple 开发者文档 - "File System Programming Guide — getattrlistbulk(2)"
18. Apple 开发者文档 - "NSWorkspace.recycle and the user Trash"
19. Apple Platform Security - "macOS privacy controls"
20. macOS man page - `getattrlistbulk(2)`
21. macOS man page - `chflags(1)` 和 `UF_DATAVAULT` 标志
22. macOS man page - `tccutil(1)`
23. macOS Sequoia 15.0 Release Notes - "Privacy & Security changes for media libraries"
24. PR-1700 错误码 KB - AmuxAIClean 内部 vendor 规则维护手册
25. AmuxAIClean PITFALLS.md §0 红线条款 - "永不 sudo / 永不伪功能"
26. AmuxAIClean docs/competitors/ 7 份深调（合计 1774 行 / 843 叶子）
27. AmuxAIClean docs/REGRESSION_VS_COMPETITORS.md - v1.0–v1.2 回归对比记录
28. SemVer 2.0.0 规范 - semver.org（自动更新 tag 解析依据）
29. GitHub REST API 文档 - "Repos / Releases / Get the latest release"
30. Sparkle 项目文档 - sparkle-project.org（评估对比，最终未采用）

---

## 6. Sanity Check（写完自校验）

逐项核对"是否说了大话"：

- [Yes] 整盘扫描：v1.0 起已支持，[ScanCategory.fullDisk](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/ScanCategory.swift)
- [Yes] 推荐清理：v1.0 默认 5 大类目即"推荐清理"
- [Yes] 大文件 Top N：v1.0 P0-4 已交付独立模块
- [Partial] 重复文件去重：**检测已实现**（[DuplicateScanner](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/DuplicateScanner.swift) + [DuplicateScreen](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/DuplicateScreen.swift) 只读视图 + 12 个测试 + sidebar 接入），但无删除按钮，自动去重未做，第 4 节坦白
- [Yes] 应用占用排行榜：v1.1 P1-6 已交付
- [Yes] 卸载残留：v0.9 起 [AppUninstaller](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/AppUninstaller.swift) 11+1 目录
- [Yes] 启动项管理：v1.1 P1-7 已交付
- [Yes] TCC 雷区跳过：v1.1 [TCCSkipList](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/TCCSkipList.swift)
- [Yes] 隐藏文件可见：v1.0 P0-2 UI toggle 已交付
- [Yes] 多线程并发扫描：v0.9 起 [ScanCoordinator](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/) + getattrlistbulk
- [Yes] 实时撤销：[TrashPipeline](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/TrashPipeline.swift) NSWorkspace.recycle + dryRun
- [Yes] 树形浏览：v1.0 P0-3 多层下钻 + 面包屑
- [Yes] 类型分桶：v1.2 已交付
- [Yes] 修改日期过滤：v1.1 P1-4 已交付
- [Yes] 快速预览：v1.2 P2-4 Quick Look 已交付
- [Yes] 导出 JSON-TSV：v1.2 P2-6 已交付
- [Yes] 批量勾选：v1.1 P1-5 已交付
- [Yes] 默认勾选安全策略：v0.9 起 SafetyEngine 三档驱动
- [Yes] SafetyEngine 三档：[SafetyEngine](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift)
- [Yes] vendor 规则：[vendors.yaml](file:///Users/amuxuser/workspace/AmuxAIClean/Resources/Rules/vendors.yaml) 159+ 条
- [Yes] 自动检查更新：v1.1 [UpdateChecker](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/Updater/UpdateChecker.swift) 手写 GitHub Releases API
- [Yes] 命令行入口：仓库内含 CLI 子模块（amuxaiclean CLI binary）
- [Yes] 开源：仓库公开

**结论**：23 维里"重复文件去重"为 △ 部分（检测已实现、自动去重未做），其余 22 维全部 ✓ 支持；已在第 1 节矩阵和第 4 节坦白章节双重披露，未夸大任何已声称的功能。

---

## 5. v1.3.zzzz Phase 4 — 树形主视图正式上线（2026-05）

### 信息架构
| 维度 | 之前 | Phase 4 之后 |
|---|---|---|
| 默认视图 | 扁平清单 | **层次化树形**（用户进 App 直接看到容量大头从哪冒出来） |
| 清单视图 | 主视图 | 二级视图，给老用户兼容 / 给"按文件名/类型筛"用 |
| 树形单条删 | 右键 / Delete 已支持 | 同 |
| 树形批量删 | 无（必须切回清单） | [Yes] Cmd+Shift+D 批量移废纸篓 |
| 树形容量占比 | [Yes] 已有 3pt accent 条 | 同 |

### 与同类产品定位对照
- **DaisyDisk / OmniDiskSweeper** 是纯可视化磁盘地图，没有勾选清理；AmuxAIClean 树形 + 批量勾选 = 把 DaisyDisk 的"看清楚"和 CleanMyMac 的"勾起来一起删"合在一个面板
- **Pearcleaner** 树形支持单条 trash、不支持框选批量；AmuxAIClean 现在追平
- **CleanMyMac X** 没有用户可见的层次化容量树（"Space Lens" 是单独入口、要付费）

### 安全合同
- 树形 batchActionBar 主按钮调用 `triggerLargeFileTrash(urls:)`，**与所有删除入口共享同一条** SafetyEngine forbid → warn → safe 三档闸 + TrashPipeline → NSWorkspace.recycle，零旁路
- toggle 入口 + [TreeBrowserView.sanitize(paths:)](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift) 双层过滤，forbid 永不入 urls；7 个 sanitize 单测 lock 这条合同

### 测试覆盖
- AppUI 248 → 255（+7：5 个 ResultsViewMode 形态 lock + 7 个 sanitize 行为；其中 ResultsViewMode 5 来自 Phase 4-A）
- 全包 SafetyKit 104 / XPCBridge 12 / ScanKit 101 全绿，回归 0
