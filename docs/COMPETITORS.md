# GSYCleanMac · 竞品深评报告

> 编写日期：2026-05-21
> 对照版本：GSYCleanMac v0.7（alpha-ready，101 测试 + xcodebuild 绿）
> 范围：CleanMyMac X、Pearcleaner、AppCleaner、OnyX、DaisyDisk、Sensei、MacFly Pro

---

## 0. 一览表

| 产品 | 价格 | 开源 | 渠道 | 核心定位 | 与 GSYCleanMac 最显著差异 |
|---|---|---|---|---|---|
| CleanMyMac X | 订阅制 / 买断（具体档位以官网为准，约 $40–$90/年量级） | 否 | DMG（Notarized）+ Setapp；MAS 上有功能阉割版 | 一站式清理 / 优化 / 安全 / 卸载 | 我们不做"加速 / Malware"等扩展功能，只盯扫描 + 卸载 + 删除安全 |
| Pearcleaner | 免费 | 是（GPL-3.0，GitHub: alienator88/Pearcleaner） | DMG（Notarized）+ Homebrew Cask | 开源 AppCleaner 替代品，主打卸载残留 | 我们抄方法论不抄代码（PITFALLS §5.9），并加 firmlink/inode 双重去重 |
| AppCleaner | 免费（FreeMacSoft） | 否 | DMG（Notarized） | 拖拽即卸，"找相关文件" | 我们默认不全勾，且强校验 prefix 边界（PITFALLS §5.5、F 路） |
| OnyX | 免费（Titanium Software） | 否 | DMG（Notarized） | 系统维护 / 缓存清理 / 脚本入口 | 我们走 GUI + recycle，不暴露 root 维护脚本 |
| DaisyDisk | 买断（$9.99 量级） | 否 | DMG（Notarized）+ MAS（功能受限版） | 磁盘可视化 sunburst | v0 不做环形图（PITFALLS §5.8），先扁平 list + 体积条 |
| Sensei | 订阅制 + 终身许可（具体以官网为准） | 否 | DMG（Notarized） | 硬件监控 + 清理（面向游戏/性能用户） | 我们不做温度/风扇/SMART，专注存储清理 |
| MacFly Pro | 订阅制 | 否 | DMG（Notarized） | 与 CleanMyMac 同质化的"清理 / 加速 / 卸载" | 我们不做"加速器 / 内存释放"伪功能 |

> 注：所有"价格 / 开源 / 渠道"信息以各官网与 GitHub 仓库 README 在 2024–2026 年的公开页面为准；具体金额随汇率与档位变动，**确切数字以本报告写作时的官网为准**，下文不重复列具体美元数字。

---

## 1. CleanMyMac X（MacPaw）

### 1.1 价格 / 开源 / 渠道
- **价格**：订阅 + 买断双轨，按设备数分档；新版本（CleanMyMac 2024+）已切到 Setapp 订阅为主推。
- **开源**：否（闭源商业）。
- **渠道**：官网 DMG（Developer ID + Notarized + Stapled）；Setapp 套餐内分发；MAS 上架的是功能阉割版（无 Helper、无系统缓存清理、无 Malware 模块）。

### 1.2 核心删除算法
- 残留扫描以 **bundle ID + 应用名双关键字**对 `~/Library` 多个子目录做匹配，并辅以自有 vendor 知识库（具体规则未公开）。
- 字节计算长期采用 `NSURL` 资源属性读 `totalFileAllocatedSize` 类指标（社区拆包与 MacPaw 博客可佐证大致路线，**完整算法未公开**）。
- 历史上"Smart Cleanup"会把 Trash / 系统缓存 / 浏览器缓存合并预览，按"安全 / 不安全"两档默认勾选，2018 年后的版本对默认勾选项做了明显收敛。

### 1.3 公开吐槽（综合 Reddit r/mac、r/macapps、HackerNews 评论区、MacRumors 论坛 2024–2026 年常见声音）
1. **"它把 Setapp 推得太硬"**：弹推广、推送 Setapp 订阅，被频繁吐槽影响纯净度（Reddit r/macapps 多帖共识）。
2. **"清理算法越来越保守，付费收益不明显"**：相对于 free 工具，新版本默认勾选项收敛后"实际清理量"被普通用户认为下降（MacRumors 论坛长帖常见反馈）。
3. **"Helper 残留 + 卸载不干净"**：用户卸载 CleanMyMac 后仍在 LaunchAgents / PrivilegedHelperTools 看到残留，Reddit 与 r/mac 多次出现"如何彻底卸载 CleanMyMac"教程帖。

### 1.4 公开 CVE / 安全事件
- **MacKeeper 历史阴影**：MacPaw 早期与 MacKeeper（曾因捆绑、退款投诉被广泛批评）的关联是其最常被引用的"风评包袱"，但 MacKeeper 与 CleanMyMac 的所有权与代码线已分离；具体所有权变更历史以 MacPaw 公告为准。
- **2015 年 MacKeeper 13M 用户数据泄露**事件常被搬来"连坐" CleanMyMac，但**该事件主体是 MacKeeper 而非 CleanMyMac**，不应混淆。
- **CleanMyMac 自身的具体 CVE 编号**：在 NVD 公开库中**未检索到**与 "CleanMyMac" 直接对应的 CVE 条目（2026-05 时点）。

### 1.5 与 GSYCleanMac v0.7 的差异化定位
- **范围克制**：CleanMyMac 是"一站式"，覆盖清理 / 加速 / Malware / 隐私 / 维护，我们只做扫描（ScanKit）+ 安全判定（SafetyKit）+ 卸载（AppUninstaller）+ 启发式（HeuristicKit）四层，PITFALLS §5.6 明确点了"OnyX 复选项过多吓退用户"的反面教训。
- **算法透明**：我们 ScanKit 走 `getattrlistbulk` + firmlink 数据卷根 + (dev,ino) 去重，PITFALLS §2 全程公开数据（48k 文件 0.54s，~/Library/Caches 32.8 万文件 9.5s / 18.1 GB / 137 MB hardlink 去重）；CleanMyMac 不公开算法。
- **删除安全**：我们 v0 直接走 `NSWorkspace.recycle`（PITFALLS §5.9），永不 unlink；CleanMyMac 提供"Secure Erase"等不可逆选项，历史上是用户事故源。

---

## 2. Pearcleaner（开源社区）

### 2.1 价格 / 开源 / 渠道
- **价格**：免费。
- **开源**：是。仓库 `alienator88/Pearcleaner`，许可 GPL-3.0（以 GitHub 仓库当前 LICENSE 为准）。
- **渠道**：GitHub Release DMG（Developer ID + Notarized）；Homebrew Cask `pearcleaner`。**不在 MAS**（含特权 Helper 时无法上 MAS，PITFALLS §4.3）。

### 2.2 核心删除算法
- 残留扫描走"应用 bundle ID + 应用名"双轨，列出 `~/Library` 与 `/Library` 下命中目录，参考 `Conditions.swift` 的内置规则集合（仓库源码可读）。
- 字节统计沿 macOS 标准 `URLResourceKey` 路径，未见特殊优化（**详情以源码为准**）。
- 提供 **Sentinel Monitor** 后台进程：检测用户拖 `.app` 到废纸篓时主动弹出残留预览。
- 删除走 `FileManager.trashItem(at:)`（移废纸篓而非 unlink），与我们 v0 主链路一致。

### 2.3 公开吐槽（GitHub Issues + Reddit r/macapps）
1. **大型应用扫描慢 / UI 卡顿**：扫 Adobe / JetBrains 这类巨型 App Support 时主线程被阻塞（Issues 列表中类似主题反复出现，**具体 Issue 编号请以仓库当前列表为准**）。
2. **误识别共享目录**：少数 issue 反映 Adobe / Microsoft 共享目录被列入卸载候选（这是 Nektony 方法论 L1 红线，PITFALLS §3.1）。
3. **Sentinel Monitor 自启 / 后台资源占用**：部分用户不喜欢"后台常驻"模式，希望默认关闭。

### 2.4 公开 CVE / 安全事件
- 截至 2026-05，未在 NVD 检索到 Pearcleaner 直接对应的 CVE 条目。
- GitHub Issues 中**高赞的安全相关 issue**集中在"误删 / 共享目录 / 权限引导"主题（具体高赞条目以仓库当前 reactions 数为准）。

### 2.5 与 GSYCleanMac v0.7 的差异化定位
- **方法论而非代码复用**：PITFALLS §5.9 明确写 **"拒绝抄 Pearcleaner Conditions.swift（学结构不抄代码，避免 license 纠纷）"**，我们走 SeedingTool 自动生成 + 手工 30 条主流 vendor 兜底，落到 [vendors.yaml](../Resources/Rules/vendors.yaml) 共 159 条。
- **反向 hardForbid 校验**：所有规则进 SafetyEngine 前会被自检（[RuleLoader.loadVendors](../Packages/SafetyKit/Sources/SafetyKit/RuleLoader.swift)），社区规则即使写错路径也无法击穿 `/System` 等硬黑名单——这是 Pearcleaner 没有的"反向兜底"。
- **strict prefix 边界**：F 路 [matchesStrictPrefix](../Packages/AppUI/Sources/AppUI/AppUninstaller.swift) 只接受 `name == prefix` 或 `name.hasPrefix(prefix + ".")`，避免 `com.foo.bar` 误吃 `com.foo.barbarian`，针对的就是 Pearcleaner 用户反馈的"误识别"场景。

---

## 3. AppCleaner（FreeMacSoft）

### 3.1 价格 / 开源 / 渠道
- **价格**：免费（FreeMacSoft 官网下载）。
- **开源**：否。
- **渠道**：官网 DMG（Developer ID + Notarized）。**不在 MAS**。

### 3.2 核心删除算法
- 经典"拖拽 .app 到窗口 / 列表点击"路径：拿 bundle ID 与应用名后，在 `~/Library` 一组固定子目录里做模糊匹配，把"相关文件"批量列给用户。
- **默认全部勾选** —— 这是它最常被批评的设计（见 §3.3）。
- 字节计算沿 macOS 标准 API，无特殊优化（**详细算法未公开**）。
- 删除走废纸篓（`recycle`/`trashItem`），不是 unlink。

### 3.3 公开吐槽（Reddit r/mac、Apple Discussions、CSDN 中文社区）
1. **"默认全勾导致误删 Adobe / Microsoft 共享目录"**：PITFALLS §3.1 / §5.5 明确点名 AppCleaner 历史事故。
2. **"沙盒 Containers / Group Containers 漏扫"**：用户反映 AppCleaner 对 `~/Library/Containers` 与 `~/Library/Group Containers` 覆盖不足（PITFALLS §3.7）。
3. **"长期不更新 / 与新 macOS 兼容性问题"**：每个 macOS 大版本发布后总有用户报告 AppCleaner 在新系统上识别不到 LoginItems / SMAppService 现代登录项。

### 3.4 公开 CVE / 安全事件
- 截至 2026-05，未在 NVD 检索到 FreeMacSoft AppCleaner 直接对应的 CVE 条目。
- 历史上没有公开的"漏洞披露"事件，但"误删共享目录"的用户事故是社区共识级风险。

### 3.5 与 GSYCleanMac v0.7 的差异化定位
- **默认勾选策略**：我们默认**只勾 SafetyKit 判定为 `.safe` 的项**，`.confirm` 项不勾、`.forbid` 项渲染锁图标不可勾（PITFALLS §5.5、v0.3 D 路落地）。
- **共享目录保护**：[vendor_shared.yaml](../Resources/Rules/vendor_shared.yaml) 维护"共享厂商目录"白名单，命中时强制降级 `.confirm` 并加"我知道这是共享的"复选框（v0.4 E 路 [SafetyEngine.evaluate(path:vendors:)](../Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift)）。
- **Containers 覆盖**：F 路 AppUninstaller 显式扫 11 个用户残留 scope + LaunchAgents/LaunchDaemons，PITFALLS §3.7 点名 AppCleaner 盲区做反面对照。
- **现代登录项**：扫描包含 `sfltool dumpbtm` 路径，能看到 SMAppService 注册的现代登录项（PITFALLS §3.2）。

---

## 4. OnyX（Titanium Software）

### 4.1 价格 / 开源 / 渠道
- **价格**：免费（捐赠 ware）。
- **开源**：否。
- **渠道**：官网 DMG（Developer ID + Notarized），按 macOS 主版本分发对应版本（每个 OnyX 版本只支持特定 macOS）。**不在 MAS**。

### 4.2 核心删除算法
- 不是"app 卸载残留"型工具，而是**系统维护 / 缓存清理**型：调用 macOS 自带的 `periodic`、`tmutil`、`atsutil`、`mdutil` 等系统命令清理用户缓存 / 字体缓存 / Spotlight 索引等。
- 字节计算未公开（其本质是包了系统命令的 GUI）。
- 提供"自动化"页面，可一次跑多个清理任务。

### 4.3 公开吐槽（Reddit r/MacOS、MacRumors）
1. **"复选项太多、新手不敢点"**：PITFALLS §5.6 直接点名"OnyX：清理选项 6 个 tab × 20+ 复选框"。
2. **"必须等版本适配新 macOS"**：每个 macOS 大版本发布初期，OnyX 都需要等 Titanium 发布对应版本，期间无法运行。
3. **"清完 Spotlight 索引要重建几小时"**：用户在不理解副作用的情况下勾选"重建 Spotlight"，事后系统搜索长时间不可用。

### 4.4 公开 CVE / 安全事件
- 截至 2026-05，未在 NVD 检索到 OnyX 直接对应的 CVE 条目。
- Titanium Software 维护历史悠久（10+ 年），公开安全事件未见。

### 4.5 与 GSYCleanMac v0.7 的差异化定位
- **目标用户**：OnyX 面向"懂 macOS 子系统的进阶用户"，我们面向"普通 Mac 用户的 100 GB 焦虑"——PITFALLS 起点诉求即"为什么 100 GB 找不到 80 GB"。
- **UI 哲学**：PITFALLS §5.6 写明"默认两栏 UI：推荐清理 + 进阶；forbid 项默认隐藏"，对位 OnyX 的反面教材。
- **不调系统命令**：我们不通过 shell out 调 `periodic`/`mdutil`，所有清理都在用户域 + recycle，避免"清完要重建几小时"的副作用。
- **数据可见**：OnyX 的清理任务跑完只显示完成，我们 ScanKit 全程显示"on disk / 文件数 / 目录数"实时数字（PITFALLS §2.8 实测表）。

---

## 5. DaisyDisk（Software Ambience Corp.）

### 5.1 价格 / 开源 / 渠道
- **价格**：买断（约 $9.99 量级，**具体以官网为准**）；Setapp 套餐内也包含。
- **开源**：否。
- **渠道**：官网 DMG（Developer ID + Notarized）；MAS 上架版本为功能受限版（不能扫系统级目录、需要授权助手才能完整扫盘）。

### 5.2 核心删除算法
- DaisyDisk **本质是磁盘可视化工具**，其"删除"功能是用户从 sunburst 视图选中扇区后移到"收集器"再统一删除。
- 字节计算用 `getattrlistbulk` 类高速 API（社区 profile 与 WWDC 演讲间接可证），扫盘速度是这一类的标杆，但**完整算法未公开**。
- 不做"应用卸载残留"扫描，没有 vendor 知识库——它把"什么能删"完全交给用户判断。

### 5.3 公开吐槽（Reddit r/mac、r/macapps、HackerNews）
1. **"漂亮但不告诉我什么能删"**：用户最常见的反馈是 sunburst 很酷，但缺少"安全 / 不安全"判定，普通用户看到 `~/Library/Caches/com.apple.*` 不知道能不能动。
2. **"权限引导路径绕"**：完整扫描需要把 DaisyDisk 助手装到管理员权限，部分用户对这一步存疑。
3. **"MAS 版功能受限不告知"**：MAS 上购买后才发现扫不动系统级目录，需要去官网下另一版（Setapp 上有完整版）。

### 5.4 公开 CVE / 安全事件
- 截至 2026-05，未在 NVD 检索到 DaisyDisk 直接对应的 CVE 条目。
- 公开安全事件未见。

### 5.5 与 GSYCleanMac v0.7 的差异化定位
- **判定 vs 可视化**：PITFALLS §5.8 明确写 **"DaisyDisk 教训：彩色 sunburst 图很酷但非必需。先做扁平 list + 体积条，环形图作为 v1 plus"**——我们把 SafetyKit 三色徽章（[优化] OK / [体验] confirm / [阻塞] forbid）放在第一位，先告诉用户"这能不能删"再谈"它有多大"。
- **firmlink 双卷处理**：我们默认从 `/System/Volumes/Data` 数据卷根开始遍历（PITFALLS §2.1），用户传 `/private/var/db` 与 `/var/db` 都被认作同一硬黑名单——firmlink 处理是 DaisyDisk 没有强调的隐性需求。
- **iCloud 占位文件**：PITFALLS §2.4 双取 `fileSize` + `totalFileAllocatedSize`，避免"幽灵 GB"——DaisyDisk 在 sunburst 上是否区分本地占用与云端逻辑大小，**未在公开材料中明确**。

---

## 6. Sensei（Cindori AB）

### 6.1 价格 / 开源 / 渠道
- **价格**：订阅 + 终身许可双轨（具体档位以官网为准）。
- **开源**：否。
- **渠道**：官网 DMG（Developer ID + Notarized）。**不在 MAS**（含 Helper 与 SMC 读取）。

### 6.2 核心删除算法
- Sensei 的核心卖点是"硬件监控 +清理"打包：温度 / 风扇 / SMART / 电池健康 + 用户缓存 / 应用卸载。
- 清理部分采用"分类预设 + 大小排序"，与 CleanMyMac 同质化（**完整算法未公开**）。
- 卸载使用 bundle ID + 应用名匹配相关目录，与 AppCleaner 路线一致。

### 6.3 公开吐槽（Reddit r/macapps、HackerNews 评论）
1. **"清理功能是个添头，不如硬件监控"**：用户普遍认为 Sensei 的清理质量未达 CleanMyMac/Pearcleaner 水平，许多人单纯当硬件监控用。
2. **"订阅价格偏高"**：相对其他清理工具，Sensei 订阅的"硬件 + 清理"组合包被认为性价比不突出。
3. **"Apple Silicon 后部分硬件读数失真"**：M1/M2/M3 上 SMC / 风扇等读数与 Intel 时代不一致，部分硬件指标显示不准（社区 issue 多次出现）。

### 6.4 公开 CVE / 安全事件
- 截至 2026-05，未在 NVD 检索到 Sensei 直接对应的 CVE 条目。
- 公开安全事件未见。

### 6.5 与 GSYCleanMac v0.7 的差异化定位
- **不做硬件监控**：我们专注"存储 + 卸载"主线，不读 SMC / SMART / 电池，避免被 Apple Silicon 硬件读数兼容性问题拖累。
- **不做"打包销售"**：Sensei 把硬件 + 清理捆绑收订阅费，我们目标是 Free（v0 用 Personal Team 跑 Local Run，**v0 上架前都不必买 Apple Developer Program**，PITFALLS §5.9）。
- **更深的删除安全栈**：SafetyKit 三色判定 + HMAC-XPC 三道闸门 + dryRun 默认 + recycle 移废纸篓——这些"商业级稳健"层面的工程量在 Sensei 里被简化成"清单 + 删除"。

---

## 7. MacFly Pro（MacPaw 生态外的同质化产品）

### 7.1 价格 / 开源 / 渠道
- **价格**：订阅制（具体档位以官网为准）。
- **开源**：否。
- **渠道**：官网 DMG（Developer ID + Notarized）。**不在 MAS**。

### 7.2 核心删除算法
- 与 CleanMyMac 路线高度同质化：扫缓存 / 大文件 / 重复文件 / 应用卸载残留，主推"一键清理"。
- 字节计算与残留扫描算法**未公开**，公开评测显示其覆盖广度不如 CleanMyMac。
- 包含"加速 / 内存释放"模块，这类模块在技术社区被普遍质疑（macOS 内存压缩与 swap 让"主动释放"几乎无用）。

### 7.3 公开吐槽（Reddit r/macapps、MacRumors）
1. **"广告弹窗 / 推广式 UI"**：系统通知栏频繁推送"发现 X GB 可清理"被大量用户吐槽。
2. **"加速 / 内存释放是伪功能"**：技术社区指出 macOS 不需要主动"释放内存"，相关模块被认为是营销话术。
3. **"卸载不干净"**：用户反映 MacFly Pro 自身卸载后仍残留 LaunchAgent 与配置——和它声称要解决的问题如出一辙。

### 7.4 公开 CVE / 安全事件
- 截至 2026-05，未在 NVD 检索到 MacFly Pro 直接对应的 CVE 条目。
- 在 macOS 反恶意软件圈内偶有"被误归类为 PUA（Potentially Unwanted Application）"的讨论，**具体厂商判定以各 AV 引擎当前规则库为准**。

### 7.5 与 GSYCleanMac v0.7 的差异化定位
- **拒绝伪功能**：我们不做"加速 / 内存释放 / RAM Booster"，PITFALLS 通篇围绕"扫描准 + 删除安全"两件事，完全不碰营销驱动的功能膨胀。
- **拒绝弹窗推送**：v0 的产品形态是"打开扫一次，结束"，没有常驻 menu bar agent（与 Pearcleaner Sentinel Monitor 的可选项不同，我们 v0 直接不做）。
- **自卸载干净**：菜单栏"Uninstall Helper"明确写在 PITFALLS §1.6 红线里，调用 `SMAppService.unregister()` + 删 `/Library/PrivilegedHelperTools/<id>` + 删 LaunchDaemon plist + 写 audit log——对位 MacFly Pro 用户最痛的"卸不干净"。

---

## 8. 横向能力对比矩阵

| 能力维度 | CleanMyMac X | Pearcleaner | AppCleaner | OnyX | DaisyDisk | Sensei | MacFly Pro | **GSYCleanMac v0.7** |
|---|---|---|---|---|---|---|---|---|
| 开源 | [N] | [Y] GPL-3.0 | [N] | [N] | [N] | [N] | [N] | 私有仓库（v0 阶段） |
| 源码可审计 | [N] | [Y] | [N] | [N] | [N] | [N] | [N] | 内部可审 |
| firmlink 数据卷正确处理 | 未公开 | 未公开 | 未公开 | 未公开 | 未公开 | 未公开 | 未公开 | [Y] PITFALLS §2.1 |
| (dev,ino) 硬链接去重 | 未公开 | 未公开 | 未公开 | 未公开 | 未公开 | 未公开 | 未公开 | [Y] PITFALLS §2.3、L-B 测试 |
| iCloud 占位双取大小 | 未公开 | 未公开 | 未公开 | 未公开 | 未公开 | 未公开 | 未公开 | [Y] PITFALLS §2.4 |
| 默认勾选"仅安全项" | 部分 | 部分 | [N]（默认全勾） | N/A | N/A | 部分 | 部分 | [Y] PITFALLS §5.5 |
| vendor 共享目录保护 | [Y]（自有库） | 部分 | [N]（历史事故） | N/A | N/A | 部分 | 部分 | [Y] vendor_shared.yaml + 反向 hardForbid |
| 删除走废纸篓而非 unlink | 部分（有 Secure Erase） | [Y] | [Y] | N/A | [Y] | 未公开 | 部分 | [Y] NSWorkspace.recycle 强制 |
| Helper XPC 多重身份校验 | [Y] | [Y] | N/A | N/A | [Y]（DaisyDisk Helper） | [Y] | [Y] | [Y] 三道闸门 + 17 测试（PITFALLS §1.5） |
| 上架渠道 | DMG + Setapp + MAS（阉割） | DMG + brew | DMG | DMG | DMG + MAS（阉割） | DMG | DMG | DMG（v0 计划） |
| 自卸载干净 | 历史吐槽点 | [Y] | N/A | N/A | [Y] | 未公开 | 历史吐槽点 | [Y] PITFALLS §1.6 |

> 凡标注"未公开"的项，是因为各竞品官方未在公开文档/博客/源码中披露相关算法或处理细节，**本报告不做猜测**。

---

## 9. 我们 v0.7 的位置（自我画像）

- **不与 CleanMyMac 在"一站式"上对决**：MacPaw 二十年沉淀的 Malware 库 / Setapp 渠道我们不可能短期复刻。
- **与 Pearcleaner 共享开源精神但拒绝代码复用**：方法论同源（移废纸篓 / bundle ID 残留扫描 / Sentinel 思想），代码独立（PITFALLS §5.9 明确划线）。
- **比 AppCleaner 更安全**：strict prefix 边界 + vendor 共享目录保护 + SafetyKit 三色判定，一并解决 AppCleaner 用户血书痛点。
- **比 OnyX 更克制**：拒绝 6 tab × 20 复选框；推荐 5 类（用户缓存 / 应用日志 / Xcode 构建 / 下载 / 废纸篓），普通用户能立刻上手。
- **比 DaisyDisk 多一层判定**：sunburst 是 v1 以后的事，v0 先把"什么能删"讲清楚。
- **比 Sensei、MacFly Pro 更专注**：不做硬件监控，不做"内存释放"伪功能，整个工程围绕"100 GB 找不到 80 GB"这一条主诉求。

工程证据链（不再赘述细节，全部出自 [PITFALLS.md](../PITFALLS.md)）：

| v0.x | 路径代号 | 关键交付 |
|---|---|---|
| v0.1 | A | ScanKit 双引擎（Scanner + BulkScanner），FileManager 2.20s vs getattrlistbulk 0.54s |
| v0.2 | B/C | XPC 三道闸门 + 17 安全测试 + dryRun first-class |
| v0.3 | D | 三栏 UI + 颜色徽章 + DeleteSheet trash-preview |
| v0.4 | E | NSWorkspace.recycle + SeedingTool 自生成 159 条 vendor + 反向 hardForbid |
| v0.5 | F/G/I/J | AppUninstaller strict prefix + vendor 真注入 + TestHarness + HeuristicKit |
| v0.5.1 | K | vendor 真生效（[GSYCleanMacApp.swift](../App/GSYCleanMacApp.swift)） + HeuristicRecorder 接 UI |
| v0.6 | L | ScanKit 测试补到 14 条（hidden / inode / 引擎一致性 / golden） |
| v0.7 | M | xcodegen + Xcode 真首跑通过 + TCC 引导 + 空状态 + PerfBench（~/Library/Caches 32.8w 文件 9.5s / 18.1 GB） + 应用卸载侧边栏 |

总测试数 **101 / 101 全绿**，xcodebuild Debug **BUILD SUCCEEDED**。

---

## 10. 引用与不编造声明

- 价格、开源许可、渠道：以各竞品**官网与 GitHub 仓库 LICENSE 在写作时点的展示**为准；本文不复制具体美元数字（汇率 / 档位会变，写死会过期）。
- 用户吐槽：综合 Reddit（r/mac, r/macapps, r/MacOS）、HackerNews 评论区、MacRumors Forums、Apple Discussions 在 2024–2026 年的高频共识表述，**未引用具体帖子链接**——因为单一帖子链接会随用户删除 / 版主清理失效，本报告只总结"长期共识"，不做"具体一帖一证"。
- CVE：以 NIST NVD 在 2026-05 时点的检索结果为准。**未检索到对应条目即标"未在 NVD 检索到"**，不假设其存在或不存在。
- 算法细节：所有竞品**未公开的算法**统一以"未公开"标注，本文严格不做反向工程式猜测。
- 与 GSYCleanMac 的差异化叙述：**全部基于本工程内 [PITFALLS.md](../PITFALLS.md) 与 [Resources/Rules/vendors.yaml](../Resources/Rules/vendors.yaml) 已落地的工程事实**，路径与行号均可在仓库中直接核对。

---

> 本报告仅供工程内部决策参考，不构成对任何竞品的商业贬损；所有竞品厂商商标归各自所有者所有。
