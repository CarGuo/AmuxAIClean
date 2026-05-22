# GSYCleanMac · 功能缺漏对齐表（FEATURE_GAP）

> 编写日期：2026-05-22
> 数据源：[docs/competitors/](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/competitors/) 6 份功能菜单深调（CleanMyMac.md / DaisyDisk.md / Pearcleaner.md / OmniDiskSweeper.md / AppCleaner.md / TreemapTools.md / OtherCleaners.md）合计 ~700 条叶子
> 目的：让你在动代码前先看清"我们和别人比到底差什么"，逐项评估优先级，再决定 v1.0 范围

---

## 0. TL;DR

我们 v0.9 当前覆盖了**预设类目清理 + 卸载残留**（CleanMyMac / Pearcleaner 派的核心），但**完全没做**：
- [目录] 任意目录扫描（DaisyDisk / OmniDiskSweeper / GrandPerspective / ncdu / Pearcleaner v5.x **5 家都有**）
- [图] 大目录可视化（DaisyDisk sunburst / GrandPerspective + Disk Inventory X treemap / CleanMyMac Space Lens **4 家有**）
- [搜] 大文件查找模块（CleanMyMac / Sensei / MacFly Pro / Pearcleaner File Search **4 家有**，独立菜单入口）
- [隐] 隐藏文件 UI 开关（Pearcleaner / OmniDiskSweeper 默认显示 / OnyX 全有 / GrandPerspective 有 **4 家暴露**）
- [键] 多层下钻（DaisyDisk / GrandPerspective / DIX / OmniDiskSweeper / CleanMyMac Space Lens **5 家有**）
- [盒] 文件批量收集器（DaisyDisk Collector + 5s 倒计时是独门设计，1 家）

**结论**：我们要补的不是 1-2 个细节，而是**整个"任意路径派"功能轴**。这是一个新维度，不是边缘特性。

---

## 1. 功能 × 竞品矩阵（核心功能视角）

> 列名：CMM = CleanMyMac X / 5 · DD = DaisyDisk · PC = Pearcleaner v5.x · ODS = OmniDiskSweeper · AC = AppCleaner · GP = GrandPerspective · DIX = Disk Inventory X · ncdu · ONX = OnyX · Sen = Sensei · MFP = MacFly Pro · **[优化] = GSYCleanMac v0.9 已有 / [体验] = 部分有 / [阻塞] = 没有**

### 1.1 扫描入口（最关键的一组）

| 功能 | CMM | DD | PC | ODS | AC | GP | DIX | ncdu | ONX | Sen | MFP | **我们** |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **预设系统/用户缓存类目** | [Y] | — | [Y] | — | — | — | — | — | [Y] | [Y] | [Y] | **[优化]** |
| **任意目录扫描（Choose Folder…）** | [Y] Space Lens / Large&Old | [Y] Scan Folder | [Y] FileSearch | [Y] CmdO | [N] | [Y] | [Y] | [Y] | [N] | [N] | [N] | **[阻塞] P0** |
| **拖拽文件夹到窗口扫描** | [Y] | [Y] | [Y] | [Y] | — | [Y] | [Y] | — | — | — | — | **[阻塞] P0** |
| **整盘扫描（/）** | [Y] Space Lens 选盘 | [Y] Internal Drives | [Y] Volume Menu | [Y] | — | [Y] | [Y] | [Y] | — | — | — | **[阻塞] P1** |
| **外置卷扫描** | [Y] | [Y] | [Y] | [Y] | — | [Y] | [Y] | [Y] | — | — | — | **[阻塞] P1** |
| **网络卷/服务器扫描** | — | [Y] Connected Servers | — | [Y] | — | — | — | [Y] | — | — | — | **[阻塞] P3 不做** |
| **常用路径快捷入口（Documents/Desktop/Downloads）** | [Y] | [警告] Star 收藏 | [Y] Volume Menu | — | — | — | — | — | — | — | — | **[阻塞] P1** |
| **管理员权限扫描受限目录（sudo / FDA）** | [Y] Helper | [Y] Scan as Admin | [Y] FDA | [Y] sudo 启动 | [Y] FDA | — | — | [Y] root | — | — | — | **[体验]** v0 不部署 Helper，但有 [TCCProbe](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/Onboarding/TCCProbe.swift) 引导 |

### 1.2 隐藏文件处理

| 功能 | CMM | DD | PC | ODS | AC | GP | DIX | ncdu | ONX | Sen | MFP | **我们** |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **隐藏文件 UI toggle** | [N]（自动含） | [N]（默认含） | [Y] Toggle | [Y] 默认显示 | [N] 全显 | [Y] Filter | — | [Y] `e` 键 | [Y] Files Visibility | — | — | **[阻塞] P0** |
| **`.xxx` 默认是否纳入扫描** | [Y] 含 | [Y] 含 | [N] 默认关 | [Y] 含 | [Y] 含 | [警告] 可配 | [Y] 含 | [N] `e` 切换 | — | — | — | **[体验]** [ScanOptions.includeHidden](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/ScanOptions.swift) 默认 false，**UI 没暴露** |
| **批量改隐藏属性（chflags）** | [N] | [N] | [N] | [N] | [N] | [N] | [N] | [N] | [Y] Files Visibility | [N] | [N] | **[阻塞] P3 不做** |

### 1.3 大文件 / 大目录查找

| 功能 | CMM | DD | PC | ODS | AC | GP | DIX | ncdu | ONX | Sen | MFP | **我们** |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **独立"大文件"模块入口** | [Y] Large & Old Files | [N]（靠 sunburst） | [警告] FileSearch + Size Filter | — | — | — | — | — | — | [Y] Clean -> Large | [Y] Manager -> Large | **[阻塞] P0** |
| **按 size 阈值过滤（>50MB / >1GB）** | [Y] 滑块 | [警告] 自动小文件聚合 | [Y] Size Filter chip | [警告] 排序 | — | [Y] filter test | [Y] filter | — | — | [Y] | [Y] | **[阻塞] P1** |
| **按修改日期/访问时间过滤** | [Y] 30 天 / 1 年 | — | — | — | — | [Y] mtime test | [Y] | — | — | [警告] | [Y] Old Files | **[阻塞] P1** |
| **按文件类型分桶（媒体/文档/归档）** | [Y] | [警告] 颜色编码 | [Y] Type filter | — | — | [Y] 染色 | [Y] 染色 | — | — | — | — | **[阻塞] P2** |
| **按列排序点击表头切字段** | [Y] | — | [Y] TableColumn | [Y] Finder 列视图 | — | — | — | — | — | — | — | **[体验]** v0 只按 size desc 单一排序 |

### 1.4 可视化

| 功能 | CMM | DD | PC | ODS | AC | GP | DIX | ncdu | ONX | Sen | MFP | **我们** |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Sunburst 环形图** | [N] | [Y] 招牌 | [N] | [N] | — | [N] | [N] | — | — | — | — | **[阻塞] P2** |
| **Treemap 方块图** | [N] | [N] | [N] | [N] | — | [Y] 招牌 | [Y] 招牌 | — | — | — | — | **[阻塞] P2** |
| **Bubble / Pie 视图** | [Y] Space Lens Bubble | — | — | — | — | — | — | — | — | — | — | **[阻塞] P3 不做** |
| **三联同步视图（左树 / 中图 / 右详情）** | [警告] | — | — | — | — | [警告] | [Y] DIX 王牌 | — | — | — | — | **[阻塞] P3 不做** |
| **进度条/体积条（行内可视化）** | [Y] | — | [Y] | — | — | — | — | [Y] 百分比 | — | — | — | **[优化] RowItem 已有** |

### 1.5 下钻交互

| 功能 | CMM | DD | PC | ODS | AC | GP | DIX | ncdu | ONX | Sen | MFP | **我们** |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **点行进入子目录** | [Y] | [Y] click petal | [Y] | [Y] Finder 列视图 | — | [Y] 缩放 | [Y] 单击 | [Y] Enter | — | — | — | **[阻塞] P0** |
| **面包屑导航** | [Y] | [Y] Breadcrumb | [Y] | [Y] 列回退 | — | [警告] | [警告] | [警告] 路径栏 | — | — | — | **[阻塞] P0** |
| **键盘快捷键导航（↑↓ Enter Esc）** | [警告] | [Y] Return / Cmd[ / Cmd] | [警告] | [警告] Finder 默认 | — | [Y] Cmd+ Cmd- | [Y] | [Y] hjkl | — | — | — | **[阻塞] P1** |
| **Reveal in Finder** | [Y] | [Y] | [Y] | [Y] | [Y] | [Y] | [Y] | — | [Y] | [Y] | [Y] | **[优化]** [RowItem](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift) 已有 url，UI 加按钮即可 |
| **Quick Look（Spacebar 预览）** | — | — | — | — | — | [Y] Space | [Y] Space | — | — | — | — | **[阻塞] P2** |

### 1.6 删除流程

| 功能 | CMM | DD | PC | ODS | AC | GP | DIX | ncdu | ONX | Sen | MFP | **我们** |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **移废纸篓（NSWorkspace.recycle）** | [Y] | [N]（绕过） | [Y] | [Y] Trash 默认 | [Y] | [Y] | [Y] | — | [Y] | [Y] | [Y] | **[优化]** [TrashPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift) |
| **Permanent Delete（绕 Trash）** | [Y] Shredder | [Y] Collector | [警告] | [Y] Destroy | — | [Y] option | [Y] | [Y] d | [Y] | — | [Y] Shredder | **[阻塞] P3 自用不做** |
| **Collector 暂存批量删除** | [N] | [Y] 招牌 | [N] | — | — | — | — | — | — | — | — | **[阻塞] P2** |
| **删除前 5s 倒计时撤销** | — | [Y] | — | — | — | — | — | — | — | — | — | **[阻塞] P3 不做** |
| **二次确认弹窗** | [Y] | [Y] | [Y] | [Y] | [Y] | [Y] | [Y] | [Y] | [Y] | — | [Y] | **[优化]** [UninstallScreen 二次确认 sheet](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/UninstallScreen.swift) |
| **dryRun 预览（不真删）** | [N] | [N] | [N] | [N] | [N] | [N] | [N] | [N] | [N] | — | [N] | **[优化] 独门** [TrashPipeline.dryRun](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift#L19-L28) |

### 1.7 应用卸载与残留

| 功能 | CMM | DD | PC | ODS | AC | GP | DIX | ncdu | ONX | Sen | MFP | **我们** |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **拖 .app 卸载** | [Y] | [N] | [Y] | — | [Y] | — | — | — | [Y] | [Y] | [Y] | **[体验]** [AppUninstaller](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppUninstaller.swift) 后端有，**UI 没拖入** |
| **关联文件残留扫描** | [Y] | [N] | [Y] | — | [Y] | — | — | — | [Y] | [Y] | [Y] | **[优化]** [matchesStrictPrefix](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppUninstaller.swift) 11+1 目录 |
| **Sentinel 监听 ~/.Trash 拖入 -> 自动唤起卸残留** | — | — | [Y] | — | [Y] SmartDelete | — | — | — | — | — | — | **[阻塞] P2** |
| **孤儿文件扫描（已卸载 app 的残留）** | [警告] | — | [Y] Orphaned Files | — | [警告] Other 列表 | — | — | — | — | — | [Y] | **[阻塞] P1** |
| **Lipo 通用二进制瘦身** | — | — | [Y] Lipo 模块 | — | — | — | — | — | — | — | — | **[阻塞] P3 不做** |
| **Homebrew 残留清理** | — | — | [Y] Homebrew Cleanup | — | — | — | — | — | — | — | — | **[阻塞] P3 不做** |

### 1.8 其他通用功能

| 功能 | CMM | DD | PC | ODS | AC | GP | DIX | ncdu | ONX | Sen | MFP | **我们** |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Finder 上下文菜单扩展** | [Y] | [警告] | — | [Y] Open in ODS | — | [Y] | [Y] | — | — | — | — | **[阻塞] P3 自用不做** |
| **菜单栏小图标（Menu Bar）** | [Y] Menu | — | — | — | — | — | — | — | — | [Y] Monitor | [Y] | **[阻塞] P3 不做** |
| **导出扫描结果（JSON / 文本）** | — | — | — | [Y] Save | — | [Y] | [Y] | [Y] | — | — | — | **[阻塞] P2** |
| **保存/重载扫描快照对比** | — | — | — | [Y] | — | [Y] | — | [Y] -e -o 文件 | — | — | — | **[阻塞] P3 不做** |
| **多语言（至少中英）** | [Y] | [Y] | [Y] | — | [Y] | [Y] | [Y] | [Y] 多 | [Y] 多 | [Y] | [Y] | **[阻塞] P1** v0 写死中文 |
| **暗色模式适配** | [Y] | [Y] | [Y] | [警告] | [Y] | [Y] | [Y] | — | [Y] | [Y] | [Y] | **[优化]** SwiftUI 自动 |
| **Helper 维护脚本（daily/weekly/monthly）** | [警告] Maintenance | — | — | — | — | — | — | — | [Y] Automation 9 项 | — | — | **[阻塞] P3 不做（OnyX 这块独此一家）** |
| **硬件监控（温度/SMART/风扇）** | [N] | [N] | [N] | [N] | [N] | [N] | [N] | [N] | [N] | [Y] | [N] | **[阻塞] P3 不做** |
| **加速器/内存释放伪功能** | [Y] | — | — | — | — | — | — | — | — | — | [Y] | **[阻塞] 永不做（PITFALLS §0 红线）** |

---

## 2. 我们 v0.9 真正的覆盖度

### 2.1 已有（[优化] 14 项 / 总计约 50 项核心功能）
- 预设类目清理（Caches/Logs/DerivedData/Downloads/.Trash 5 个 [ScanCategory](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCategory.swift)）
- 高性能扫描（[BulkScanner getattrlistbulk](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift)，比 FileManager 快 3-8 倍）
- inode 去重（[InodeSet](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/InodeSet.swift)）
- 一级子目录聚合 + size desc 排序
- SafetyEngine 三态判定（[safe/confirm/forbid](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift)）
- 159 条 vendor 规则（[vendors.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml)）
- TrashPipeline + dryRun（**独门**）
- 二次确认弹窗
- AppUninstaller 残留扫描（11+1 目录，matchesStrictPrefix 防误吃）
- HL 启发式学习（HeuristicEngine 三元组）
- TCC 引导
- permissionDenied UI 露出（v0.9 新做）
- 暗色模式自动
- 行内体积条

### 2.2 缺漏（[阻塞] 共 30+ 项），按优先级
- **P0（v1.0 必须有，否则功能根本不对齐）**：5 项
- **P1（v1.1 强烈建议）**：7 项
- **P2（v1.2+，加分项）**：6 项
- **P3（明确不做或自用不需要）**：12+ 项

---

## 3. 缺漏分级表（你逐项 review 这一段）

### P0 — v1.0 必须有

| # | 功能 | 工程量估算 | 说明 |
|---|---|---|---|
| **P0-1** | **任意目录扫描入口**（侧边栏加 "[目录] 自定义路径" + Choose Folder + 拖入） | S | 后端 [BulkScanner.scan(root:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift#L23) 已支持任意 URL，纯 UI 新增 1 个 ScanCategory.custom + NSOpenPanel + drop target |
| **P0-2** | **隐藏文件 UI toggle**（设置或扫描栏开关） | XS | [ScanOptions.includeHidden](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/ScanOptions.swift) 已存在，UI 加一个 Toggle 绑定即可 |
| **P0-3** | **多层下钻**（点击行进入子目录 + 面包屑返回） | M | ScanCoordinator 当前一级聚合，要扩成"按当前 root 重扫" + 路径栈 + 后退 |
| **P0-4** | **大文件查找模块**（独立菜单 + 阈值滑块） | M | 复用 BulkScanner，UI 多一个 tab，按文件而非目录聚合，加 size 滑块 |
| **P0-5** | **拖文件夹到窗口扫描**（DragDelegate） | XS | SwiftUI `.onDrop` 即可 |

### P1 — v1.1 强烈建议

| # | 功能 | 工程量 | 说明 |
|---|---|---|---|
| P1-1 | 整盘扫描（/）+ 外置卷 + 常用路径快捷入口 | S | ScanCategory 加几条预设；整盘要 FDA 引导，已有 |
| P1-2 | 按列排序（点击表头切 size/name/mtime） | S | RowItem 已有字段，TableColumn sort 即可 |
| P1-3 | 按 size 阈值过滤滑块 | XS | 在大文件模块里 |
| P1-4 | 按修改日期过滤（30 天 / 1 年） | S | BulkScanner 已采集 modificationDate，UI 加 chip |
| P1-5 | 键盘导航（↑↓ Enter Esc Cmd+ Cmd-） | S | SwiftUI .keyboardShortcut |
| P1-6 | 多语言（中英切换） | M | Localizable.strings + 全文案外提 |
| P1-7 | 孤儿文件扫描（已卸 app 的残留） | M | AppUninstaller 反向：扫 ~/Library 找匹配不到任何已装 app 的 bundle id |

### P2 — v1.2+ 加分项

| # | 功能 | 工程量 | 说明 |
|---|---|---|---|
| P2-1 | Treemap 可视化（GP/DIX 派） | L | 需要 squarified 算法，独立 view 模块 |
| P2-2 | Sunburst 可视化（DaisyDisk 派） | L | 二选一，treemap 更易实现 |
| P2-3 | 文件类型分桶 + 染色 | S | 按扩展名映射颜色 |
| P2-4 | Quick Look（Spacebar 预览） | XS | NSURL.quickLook |
| P2-5 | Sentinel ~/.Trash 监听 + 自动唤起残留扫描 | M | FSEvents on ~/.Trash |
| P2-6 | 导出扫描结果（JSON / TSV） | XS | 已有 RowItem，序列化即可 |

### P3 — 不做（自用 + 开源 + 安全压倒一切，明确取舍）

| # | 功能 | 不做的理由 |
|---|---|---|
| P3-1 | 加速器/内存释放伪功能 | PITFALLS §0 红线 |
| P3-2 | Helper 维护脚本（OnyX 派） | v0 不部署 Helper |
| P3-3 | 硬件监控（温度/SMART/风扇） | 与清理无关 |
| P3-4 | Permanent Delete 绕过 Trash | 自用反而要更安全，不绕 |
| P3-5 | 网络卷扫描 | 自用场景少，TCC 复杂 |
| P3-6 | DaisyDisk Collector + 5s 倒计时 | dryRun 已经覆盖了"提交前预览" |
| P3-7 | Lipo / Homebrew Cleanup | 偏门，自用不需要 |
| P3-8 | 三联同步视图（DIX 王牌） | 工程量大且差异化弱 |
| P3-9 | Bubble / Pie 视图 | 选 1 个可视化够了 |
| P3-10 | 批量改隐藏属性（chflags） | 与清理无关 |
| P3-11 | Finder 上下文菜单扩展 | App Extension 自用不必 |
| P3-12 | 菜单栏小图标 | 自用单窗口足够 |

---

## 4. 我的推荐 v1.0 范围（你拍板）

**我建议 v1.0 = P0 全做（5 项）**，理由：
1. P0-1/3/5（任意目录 + 下钻 + 拖入）是**结构性缺漏**，不做的话产品定位都模糊
2. P0-2（隐藏文件 toggle）一行代码价值，且直接对接你提的"我本地一堆很大的目录"诉求——你那些目录可能就含 `.npm` `.gradle` `.cache` 这种隐藏大头
3. P0-4（大文件模块）是 CleanMyMac/Sensei/MacFly/Pearcleaner 4 家都有的标配，我们必须有
4. 工程量合计：**XS+XS+M+M+XS = 约 1-2 天并发推进** + 测试

**P1 7 项**作为 v1.1 follow-up，**P2 6 项** v1.2+ 看真人反馈，**P3 12+ 项**明确不做并写进 README。

---

## 5. 决策点（请你回答）

请逐项确认：

1. **P0 5 项是否全收**？还是要拆？
2. **P1 7 项是否有想提到 v1.0 的**？（我猜"按列排序" P1-2 + "按 size 阈值过滤滑块" P1-3 你可能想合进 v1.0 大文件模块）
3. **P2 可视化（treemap/sunburst）**是否完全跳过到 v1.2+？还是 v1.0 至少先做最简 treemap？
4. **P3 12 项**有没有你想加回的？（比如孤儿文件扫描 P1-7 你可能感兴趣）
5. **隐藏文件默认值**：UI toggle 的初始状态——默认 ON（与 Finder 不一致但更"看真实"）还是默认 OFF（与 Finder 一致）？我倾向默认 OFF，给个明显的"显示隐藏文件"开关

---

## 6. 信息来源

本表所有竞品数据来自：
- [docs/competitors/CleanMyMac.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/competitors/CleanMyMac.md) 250 行 / 163 叶子
- [docs/competitors/DaisyDisk.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/competitors/DaisyDisk.md) 202 行 / 130 叶子
- [docs/competitors/Pearcleaner.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/competitors/Pearcleaner.md) 243 行 / 153 叶子
- [docs/competitors/OmniDiskSweeper.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/competitors/OmniDiskSweeper.md) 125 行 / 49 叶子
- [docs/competitors/AppCleaner.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/competitors/AppCleaner.md) 206 行 / 65 叶子
- [docs/competitors/TreemapTools.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/competitors/TreemapTools.md) 403 行 / 146 叶子（GP+ncdu+DIX）
- [docs/competitors/OtherCleaners.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/competitors/OtherCleaners.md) 345 行 / 137 叶子（OnyX+Sensei+MacFly）

合计 **1774 行 / 843 条功能叶子**。每份文末贴有官方 URL 信息源。
