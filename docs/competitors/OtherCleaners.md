# 其他清理类工具深调（OnyX / Sensei / MacFly Pro）

> 调研日期：2026-05-22
> 范围：Titanium Software OnyX（免费）、Sensei（订阅 / 终身）、MacFly Pro（订阅）
> 目的：补足 GSYCleanMac 在「维护脚本」「硬件监控」「订阅型一体化清理」三类竞品上的功能盲区
>
> 标签图例：
> - [Y] 核心清理（缓存 / 日志 / 残留 / 卸载 / 大文件 / 重复）
> - [周边] 周边（隐私、登录项、扩展、效率小工具，与清理同窗口但非主线）
> - [目录] 任意路径（支持用户自选目录扫描 / 操作）
> - [图] 可视化（带图表 / 仪表盘 / 进度可视化）
> - [工具] 维护脚本（封装 macOS 系统级 shell 脚本 / 重建索引 / SMART / Trim 等）

---

## 1. OnyX（Titanium Software，免费）

OnyX 是法国独立开发者 Joël Barrière 自 2003 年起维护的 macOS 维护工具，核心定位是「把 macOS 命令行维护任务包装成 GUI」。每个 macOS 大版本都有专门版本（当前 OnyX 5.0.0 对应 macOS Tahoe 26）。它**不是 CleanMyMac 类「智能扫描」清理器**，而是一组分类摆放的"开关 + 立即执行"的脚本面板，最大特色就是题目要求重点列的 **Maintenance / Automation / Utilities** 三块。

### 1.1 工具栏总览（顶部 Tab）

OnyX 主界面只有一个工具栏，所有功能按 8 个 Tab 平铺：

```
OnyX
├── Maintenance（维护） [工具]
│ ├── 验证（Verify）
│ │ └── 文件系统结构（Verify Filesystem Structure） [工具] 维护脚本
│ ├── 权限（Permissions）
│ │ └── 修复主目录权限 [工具] 维护脚本
│ ├── 脚本（Scripts，macOS periodic） [工具] 维护脚本
│ │ ├── 执行 daily 维护脚本（periodic daily） [工具] 维护脚本
│ │ ├── 执行 weekly 维护脚本（periodic weekly） [工具] 维护脚本
│ │ └── 执行 monthly 维护脚本（periodic monthly） [工具] 维护脚本
│ └── 重建（Rebuilding）
│ ├── LaunchServices 数据库（"打开方式"映射） [工具] 维护脚本
│ ├── Spotlight 索引（mdutil -E） [工具] 维护脚本
│ ├── Mail 邮箱索引（重建 / 删除并重建） [工具] 维护脚本
│ ├── 桌面图标 / 卷布局 [工具] 维护脚本
│ ├── dyld 共享缓存 [工具] 维护脚本
│ ├── XPC 缓存 [工具] 维护脚本
│ └── 帮助（Help）索引 [工具] 维护脚本
│
├── Cleaning（清理） [Y]
│ ├── System（系统缓存、内核缓存、启动缓存） [Y] 核心清理
│ ├── User（用户缓存、QuickLook 缓存、Dock 缓存、应用缓存） [Y] 核心清理
│ ├── Internet（浏览器缓存 / Cookies / 下载历史 / DNS 缓存）[Y] 核心清理
│ ├── Fonts（字体缓存 / ATS / Word & Photoshop 字体缓存） [Y] 核心清理
│ ├── Logs（系统日志、用户日志、诊断报告 .crash） [Y] 核心清理
│ ├── Misc.（最近项、计算器记忆、屏幕共享 My Computers） [Y] 核心清理
│ ├── Erasing（按指定路径安全擦除文件 / 文件夹） [目录] 任意路径
│ └── Trash（清空废纸篓 / 三遍覆盖安全清空） [Y] 核心清理
│
├── Automation（自动化任务） [工具]
│ └── 把 Maintenance 与 Cleaning 中的常用项打勾后一键 Execute
│ ├── 默认勾选：daily / weekly / monthly 脚本 [工具] 维护脚本
│ ├── 默认勾选：System & User 缓存 [Y] 核心清理
│ ├── 默认勾选：清空字体缓存 [Y] 核心清理
│ ├── 默认勾选：重建 LaunchServices [工具] 维护脚本
│ ├── 可选：清空 Internet 缓存 [Y] 核心清理
│ ├── 可选：重建 Spotlight 索引 [工具] 维护脚本
│ ├── 可选：清空诊断报告 / 系统日志 [Y] 核心清理
│ ├── 可选：清空 dyld / XPC / Help 缓存 [工具] 维护脚本
│ └── 可选：清空 Trash [Y] 核心清理
│
├── Utilities（实用工具） [工具]
│ ├── Filesystem Check（fsck 在线版，无需重启） [工具] 维护脚本
│ ├── APFS Snapshots（列出 / 创建 / 删除 APFS 快照） [工具] 维护脚本
│ ├── Process Accounting（开关 BSD 进程审计 sa/lastcomm） [工具] 维护脚本
│ ├── Schedule（定时启动 / 睡眠 / 关机，pmset） [工具] 维护脚本
│ ├── UNIX Manuals（man 页面图形化浏览） [周边] 周边
│ ├── Display Calibrator（呼出系统显示器校准助手） [周边] 周边
│ ├── Directory Utility（呼出系统目录实用工具） [周边] 周边
│ ├── Wireless Diagnostics（呼出系统 Wi-Fi 诊断） [周边] 周边
│ ├── 网络实用工具 / Bluetooth Explorer [周边] 周边
│ └── Safe Mode / Verbose Mode 启动开关 [工具] 维护脚本
│
├── Parameters（参数） [周边]
│ ├── General（系统通用参数） [周边] 周边
│ ├── Login（登录窗口外观、用户列表显隐） [周边] 周边
│ ├── Finder（显示扩展名、桌面文件、隐藏文件 toggle） [周边] 周边 / 隐藏文件 toggle
│ ├── Dock（位置 / 缩放 / 隐藏延迟 / 最小化效果） [周边] 周边
│ ├── Menus（菜单栏透明度、时间显示） [周边] 周边
│ ├── Safari（默认搜索、阅读列表行为） [周边] 周边
│ ├── Mail / iCal / iTunes / Messages 偏好微调 [周边] 周边
│ ├── Screen Capture（截图格式 / 阴影 / 文件名） [周边] 周边
│ └── Misc.（菜单栏电池百分比、Time Machine 本地快照开关） [周边] 周边
│
├── Files（文件） [目录]
│ ├── Visibility（隐藏 / 显示 任意文件、文件夹、卷） [目录] 任意路径 / 隐藏文件 toggle
│ ├── Erasing（多遍覆盖安全擦除指定路径） [目录] 任意路径 [Y] 核心清理
│ ├── AppleDouble（递归删除 ._* 元数据残留） [目录] 任意路径 [Y] 核心清理
│ ├── .DS_Store（递归删除 .DS_Store） [目录] 任意路径 [Y] 核心清理
│ ├── Checksums（MD5 / SHA-1 / SHA-256 校验任意文件） [目录] 任意路径
│ ├── Search Package by Checksum [周边] 周边
│ └── Uninstaller（应用卸载，扫描其支持文件） * [Y] 核心清理 / [目录] 任意路径
│ └── 4.8.5 起将"应用卸载"独立为 Files 子项；
│ 可拖入 .app 或选 Application 文件夹列表；
│ 不做"留存文件"反向扫描（不像 Sensei / CleanMyMac 那样
│ 按 bundle id 反查孤儿，仅遍历 ~/Library 常见 8 路径）
│
├── Find（查找） [目录]
│ ├── Locate（locate 命令前端，需先 createdb） [目录] 任意路径
│ └── Spotlight（mdfind 前端，按属性筛） [目录] 任意路径
│
└── Info（信息） [周边]
 ├── Mac 型号 / 序列号 / SoC（M 系列芯片识别） [图] 可视化
 ├── 启动磁盘容量 / SMART 状态 [图] 可视化
 ├── macOS 版本 / 内核版本 / Darwin 版本 [周边] 周边
 └── Gatekeeper / SIP / FileVault / XProtect 状态查询 [周边] 周边
```

> Files -> Visibility 是 **OnyX 唯一明确的"隐藏文件 toggle"**，作用域既包括 Finder 全局（等价 `defaults write com.apple.finder AppleShowAllFiles`），也支持给**任意指定文件 / 文件夹/卷**打 hidden flag（chflags hidden）。

### 1.2 OnyX 对四问的回答

| 问题 | 答案 |
|---|---|
| 任意目录扫描？ | [N] 没有"目录扫描出 N 个分类"的能力。`Find -> Locate / Spotlight` 是**搜索文件**，不是按文件夹下钻；`Files -> Erasing/AppleDouble/.DS_Store` 是**对指定路径执行操作**，不出现 "本目录占了多少 GB" 的视图 |
| 大文件查找？ | [N] **完全没有**。OnyX 不做体积排序，不做"Large Files"列表 |
| 隐藏文件 toggle？ | [Y] 有两层：1) Parameters -> Finder 全局开关；2) Files -> Visibility 可对**任意路径**单独切 hidden（chflags） |
| 多层下钻？ | [N] 没有树状下钻 / 旭日图。整个 App 是平铺 Tab，每个 Tab 内是一组并列复选框，和 DaisyDisk / GrandPerspective 完全不同流派 |

### 1.3 信息来源（OnyX）
- 官方下载与说明：https://www.titanium-software.fr/en/onyx.html （Titanium Software，OnyX 5.0.0 / 4.8.5 描述）
- MacKeeper OnyX Review（系统列出 Cleaning / Utilities / Parameters / Files / Security / Find / Info 全部 Tab）：https://mackeeper.com/blog/onyx-review/
- thesweetbits OnyX 评测（详细列 Maintenance / Utilities / Files 子项）：https://thesweetbits.com/tools/onyx-mac/
- Apple Gazette《Keep Your Mac Running Smoothly with Onyx》（Maintenance / Cleaning / Automation 三块逐项说明）：https://www.applegazette.com/mac/mac-maintenance-onyx/
- Grokipedia OnyX 词条（开发者背景与版本对应关系）：https://grokipedia.com/page/OnyX

---

## 2. Sensei（Cindori，订阅 $29/年 或 $59 终身）

Sensei 由瑞典 Cindori（Trim Enabler 的开发商）出品，定位是 **"性能监控为主 + 清理为辅"** 的一体化工具。结构上分三大区：Dashboard / Utilities / Hardware，外加 v2 引入的菜单栏小工具 Sensei Monitor。它是本次三家里**唯一把硬件传感器（温度、风扇、SMART、电池循环）作为主线**的工具——题目要求重点记录这块。

### 2.1 功能树

```
Sensei
├── Dashboard（一屏总览） [图] 可视化
│ ├── Mac 型号 / 序列号 / macOS 版本卡片 [周边] 周边
│ ├── 内 / 外置存储空间环形图 [图] 可视化
│ ├── RAM 使用环形图 + Top 占用进程列表 [图] 可视化
│ ├── CPU 负载环形图 + Top 占用进程列表 [图] 可视化
│ └── GPU 负载 / 显存 / 温度环形图 [图] 可视化
│
├── Utilities（软件优化区） [Y]
│ ├── Optimize（启动项管理） [周边] 周边
│ │ ├── Login Items 开关 [周边] 周边
│ │ ├── Launch Agents 开关 / 删除 [周边] 周边
│ │ └── Launch Daemons 开关 / 删除 [周边] 周边
│ ├── Uninstaller（应用卸载） [Y] 核心清理
│ │ ├── 列出已安装 .app + 体积 [Y] 核心清理
│ │ ├── 反查 Support Files / Preferences / Containers [Y] 核心清理
│ │ └── 单个文件粒度勾选删除（可只删 cache 留 prefs） [Y] 核心清理
│ ├── Clean（垃圾分类清理） [Y] 核心清理
│ │ ├── Large Files（≥ 用户阈值的大文件列表，按大小排序） [Y] 核心清理 / 大文件
│ │ ├── Downloads（下载文件夹遗留） [Y] 核心清理
│ │ ├── User Caches [Y] 核心清理
│ │ ├── User Logs [Y] 核心清理
│ │ ├── System Logs [Y] 核心清理
│ │ ├── Disk Images（.dmg 残留） [Y] 核心清理
│ │ ├── Installer Packages（.pkg 残留） [Y] 核心清理
│ │ └── Developer Files（Xcode DerivedData / Archives） [Y] 核心清理
│ └── Trim（SSD Trim Enabler，Apple-certified 驱动） [工具] 维护脚本
│
├── Hardware（硬件监控 本工具特色，纯监控不清理） [图]
│ ├── Storage（存储）
│ │ ├── 内置 / 外置驱动器列表 [图] 可视化
│ │ ├── Disk Benchmark（顺序读 / 写速率测试） [图] 可视化
│ │ ├── S.M.A.R.T. 健康报告（HDD/SSD 故障预警） [工具] 维护脚本
│ │ ├── Drive Statistics（实时 IOPS / 带宽图） [图] 可视化
│ │ └── Partition Map Explorer（分区表可视化） [图] 可视化
│ ├── Graphics（显卡）
│ │ ├── 70+ GPU 指标 [图] 可视化
│ │ ├── GPU Firmware Exporter（导出固件） [周边] 周边
│ │ ├── eGPU 详细报告 [图] 可视化
│ │ └── Display 模式 / 刷新率 [图] 可视化
│ ├── Power（电源）
│ │ ├── Battery Health Analyzer（设计容量 vs 当前容量） [图] 可视化
│ │ ├── Cycle Count（充电循环数） [图] 可视化
│ │ └── 电池状态实时图 [图] 可视化
│ ├── Memory（内存）
│ │ └── RAM Monitor（压力 / 已用 / 缓存 / 已压缩） [图] 可视化
│ ├── Processor（CPU）
│ │ ├── 每核心负载图 [图] 可视化
│ │ └── CPU 温度图 [图] 可视化
│ └── Cooling / Thermal Dashboard（散热大屏 ） [图] 可视化
│ ├── CPU 温度 [图] 可视化
│ ├── GPU 温度 [图] 可视化
│ ├── Logic Board 温度 [图] 可视化
│ ├── Memory 温度 [图] 可视化
│ ├── Enclosure（外壳）温度 [图] 可视化
│ ├── AirPort 无线芯片温度 [图] 可视化
│ ├── 风扇 RPM 实时图（多风扇分别绘制） [图] 可视化
│ └── Fan Control（指定 RPM，部分机型，roadmap 上） [工具] 维护脚本
│
└── Sensei Monitor（v2 新增的菜单栏小部件） [图] 可视化
 ├── 状态栏图表 / 数字（CPU / GPU / RAM / 网络 / 电池） [图] 可视化
 ├── Editor（自定义 widget 大小、颜色、阈值） [周边] 周边
 ├── Drop-down Panel（点开后的迷你仪表盘） [图] 可视化
 └── 主题（Light / Dark / 自定义配色） [周边] 周边
```

### 2.2 硬件监控模块特别说明（题目要求）

Sensei 的 **Hardware** 大区**与"清理"完全无关**，但它是该产品立足的核心，并且是 OnyX / MacFly Pro / CleanMyMac 都不具备的能力，要点：

1. **温度（Thermal Dashboard）**：实时读取 SMC / IOReport，覆盖 CPU、GPU、Logic Board、Memory、Enclosure、AirPort 等多个传感器；每条曲线自动按温度高低做蓝->红渐变。这是少数对 Apple Silicon 也持续维护温度读数的第三方工具。
2. **SMART（Drive Health Report）**：调用 `smartctl` 等接口对内置 SSD / HDD 给出健康分级（Healthy / Warning / Failing），并暴露 reallocated sector、temperature、power-on hours 等原始计数。
3. **风扇（Fans）**：列出每只风扇的当前 RPM、最低 / 最高阈值，并在 Thermal Dashboard 中绘制实时曲线；`Fan Control`（手动指定风扇转速）在路线图上但仅对带可控风扇的 Intel 旧款 Mac 有效。
4. **电池（Battery Health Analyzer）**：设计容量 / 当前最大容量 / 循环数 / 健康百分比 / 即时功率，并预警异常。

> 对 GSYCleanMac 的启示：硬件监控是一个**值得显式声明"不做"**的方向（Sensei 已经是这个细分赛道的 best-in-class，且数据来源高度依赖 SMC 反向工程，进入门槛与维护代价都高）。

### 2.3 Sensei 对四问的回答

| 问题 | 答案 |
|---|---|
| 任意目录扫描？ | [N] Clean 模块的 8 个分类全部是**预设根路径**（Downloads、~/Library/Caches、~/Library/Logs 等），用户不能自选根目录扫描；Large Files 也是全盘扫描，不可指定子树 |
| 大文件查找？ | [Y] 有，Utilities -> Clean -> **Large Files**，按文件大小降序列表（与 CleanMyMac Large & Old Files 类似），但**没有"年龄"过滤**，只有大小阈值 |
| 隐藏文件 toggle？ | [N] 没有 GUI 开关；扫描结果里隐藏文件可能因系统忽略规则而不显示 |
| 多层下钻？ | [警告] **半个**：Uninstaller 里点开一个 App 会展开它的关联文件树（Support / Caches / Preferences / Containers）算 2 层下钻；但磁盘空间维度没有 DaisyDisk 那种递归下钻视图 |

### 2.4 信息来源（Sensei）
- 官方主站：https://sensei.app/ （Performance Monitor / Storage / Hardware Tools / Thermal Dashboard 章节）
- MacUpdate Sensei 页（罗列了 19 项官方 feature checklist，包括 Trim Enabler / Partition Map Explorer / Battery Health 等）：https://sensei.macupdate.com/
- MacStories《Sensei: A Beautifully-Designed Dashboard and Set of Utilities》（详细描述 Dashboard / Utilities / Hardware 三大区子项）：https://www.macstories.net/stories/sensei-a-beautifully-designed-dashboard-and-set-of-utilities-for-your-mac/
- Cindori《Best Mac Performance Monitor Apps in 2026》（Sensei Monitor 菜单栏小部件 + 全功能列举）：https://cindori.com/reviews/best-mac-performance-monitor-apps

---

## 3. MacFly Pro（MacFly Pro LLC，订阅 ~$3.33–$4.99/月）

MacFly Pro 是 2017 年上线的订阅制 Mac 清理工具，主打「**Smart Assistant（智能助手）**」概念——每天自动扫一次，把所有建议汇总到一处。它的功能集与 CleanMyMac 高度同质（Cleaner + Manager + Privacy），**独有点**主要是 Assistant 的"自学习"行为模式 + 简化交互。

> 与 CleanMyMac 同质化的子项以一行带过；MacFly 独有 / 形式不同的展开写。

### 3.1 功能树

```
MacFly Pro
├── Cleaner（清理器） [Y]
│ ├── Smart Cleanup（一键智能扫描）≈ CleanMyMac Smart Care [Y] 核心清理
│ ├── User Cache（用户缓存）≈ 同质 [Y] 核心清理
│ ├── System Cache（系统缓存）≈ 同质 [Y] 核心清理
│ ├── System Logs（系统日志）≈ 同质 [Y] 核心清理
│ ├── User Logs（用户日志）≈ 同质 [Y] 核心清理
│ ├── Mail Attachments（邮件附件本地副本）≈ 同质 [Y] 核心清理
│ ├── Trash Bins（包含外置盘 Trash 与 iPhoto Trash）≈ 同质 [Y] 核心清理
│ ├── Browser Data（浏览历史 / Cookies / 表单缓存）≈ 同质 [周边] 周边
│ └── Broken Login Items（失效登录项）≈ 同质 [周边] 周边
│
├── Manager（管理器） [Y]
│ ├── Old Files（按"上次访问时间"挑出旧文件） 独有维度 [Y] 核心清理
│ │ └── 与 CleanMyMac 的 "Large & Old Files" 不同：
│ │ MacFly 把"旧"独立成一个维度，可单看 6 月 / 1 年 / 2 年未碰
│ ├── Large Files（大文件）≈ 同质，按大小阈值过滤 [Y] 核心清理 / 大文件
│ ├── Duplicates（重复文件 / 重复照片，hash 比对）≈ 同质 [Y] 核心清理
│ ├── Apps（卸载器，含 leftovers 反查）≈ 同质 [Y] 核心清理
│ ├── Extensions（浏览器扩展、Safari/Chrome/Firefox）≈ 同质 [周边] 周边
│ └── Login Items（登录项）≈ 同质 [周边] 周边
│
├── Tools（工具集） [周边]
│ ├── Memory Cleaner（一键释放 RAM，purge） [工具] 维护脚本
│ ├── Shredder（多遍覆盖永久删除任意文件） 独有按钮 [目录] 任意路径 [Y] 核心清理
│ │ └── 拖入任意文件 / 文件夹即可，类似 CleanMyMac
│ │ 的 Shredder 但是默认入口更显眼
│ ├── Privacy（清浏览器 / 即时通讯 / 最近文档痕迹）≈ 同质 [周边] 周边
│ └── Optimization（DNS Flush、解除程序假死、重启 Finder） [工具] 维护脚本
│
├── Smart Assistant（智能助手） MacFly 灵魂卖点 [周边]
│ ├── 后台 Daemon 每日扫一次（默认 24h） [周边] 周边
│ ├── 把 Cleaner / Manager / Tools 的建议聚合到一个收件箱 [周边] 周边
│ ├── "自学习"：会按你过去的接受/忽略习惯调整建议优先级 [周边] 周边
│ ├── 桌面通知（推送可清理体积、可优化项数量） [周边] 周边
│ └── 单击 "Apply All" 一次性接受全部建议 [Y] 核心清理
│
└── Settings & Subscription [周边]
 ├── Schedule（自定义 Assistant 扫描频率 / 时间） [周边] 周边
 ├── Ignore List（白名单：路径 / 应用） [周边] 周边
 ├── Notifications（通知开关） [周边] 周边
 ├── Promo Code / Activation [周边] 周边
 └── 订阅管理（月付 / 年付 / 自动续费） [周边] 周边
```

### 3.2 与 CleanMyMac 同质 / 独有的对比一览

| 维度 | MacFly Pro | CleanMyMac X / Mojave 后续 |
|---|---|---|
| Smart 一键扫 | [Y] Smart Assistant（带"日学习") | [Y] Smart Care |
| 缓存 / 日志 / 邮件附件 / 废纸篓 | [Y] 完全同质 | [Y] |
| Old Files 维度 | [Y] **独立模块**，可按未访问周期分桶 | [警告] 只有 Large & Old Files 合并 |
| 重复文件 | [Y] | [Y] |
| 卸载器 + leftovers 反查 | [Y] | [Y] |
| 隐私 / Browser Data | [Y] | [Y] |
| Memory Cleaner | [Y] Tools 一项 | [Y] |
| Shredder（碎纸机） | [Y] **入口显眼** | [Y] 但藏得更深 |
| 维护脚本（periodic / 重建索引） | [N] | [警告] 部分（Maintenance Scripts） |
| 恶意软件 / 病毒检测 | [N] | [Y] |
| 健康仪表盘 / 菜单栏 Menu | [N] | [Y] CleanMyMac Menu |
| 硬件传感器 | [N] | [警告] 仅 CPU 占用 |

> MacFly Pro 真正"独到"的就 3 件：1) **Old Files 单独成 Tab**；2) **Smart Assistant 自学习**；3) **Shredder 一级入口**。其余清理类功能基本是 CleanMyMac 减配版（缺恶意软件、缺 Menu 菜单栏、缺维护脚本），所以单价比 CleanMyMac 便宜（订阅 $3.33/月 vs CleanMyMac ~$3.99/月年付）。

### 3.3 MacFly Pro 对四问的回答

| 问题 | 答案 |
|---|---|
| 任意目录扫描？ | [N] Cleaner / Manager 全部是**预置根路径**；只有 **Tools -> Shredder** 接受任意路径，但 Shredder 是"删"不是"扫描分析" |
| 大文件查找？ | [Y] 有，Manager -> **Large Files**，可按大小阈值过滤；与 CleanMyMac 一致 |
| 隐藏文件 toggle？ | [N] 没有 GUI 开关；扫描结果默认包含某些 dotfile（caches/logs），但用户不能切换"看见全部隐藏文件" |
| 多层下钻？ | [警告] **半个**：Apps（卸载器）展开应用关联文件算 2 层；Old Files / Large Files 给出列表但**不带文件夹层级**——所有匹配文件平铺一张表，按大小或日期排序，没有 DaisyDisk 那种递归视图 |

### 3.4 信息来源（MacFly Pro）
- 官方主站：https://macflypro.com/ （Cleaner / Manager / Smart Assistant 三大模块）
- ProductHunt 创始人 Tomasz Jesko 自述（明确列出 Cleaner / Manager / Assistant 三件套及定价）：https://www.producthunt.com/products/macfly-pro
- AlternativeTo MacFly Pro 资料卡（feature checklist：Duplicate File Finder / Software Uninstaller / 1-click maintenance / Disk Maintenance / Optimization）：https://alternativeto.net/software/macfly-pro/about/
- BestMacTools MacFly Pro 评测（Cache / Login items / Leftovers / Browser extensions / Duplicates / Shredder 子项描述）：https://www.bestmactools.com/macfly-pro/

---

## 4. 三家横向 4 问汇总（一图速查）

| 工具 | 任意目录扫描 | 大文件查找 | 隐藏文件 toggle | 多层下钻 |
|---|---|---|---|---|
| **OnyX** | [N]（仅"对路径执行操作"，非扫描分析） | [N] 无 | [Y] 全局 + 任意路径双向 | [N] 平铺 Tab，无树形 |
| **Sensei** | [N]（预设 8 个根路径） | [Y] Large Files（按大小） | [N] 无 | [警告] 仅卸载器展开 App 关联文件 |
| **MacFly Pro** | [N]（仅 Shredder 接收任意路径，但是"删"不是"扫"） | [Y] Large Files（按大小） + Old Files（按时间） | [N] 无 | [警告] 仅卸载器展开 App 关联文件 |

> 结论：**三家没有一家提供"任意目录递归下钻 + 多层可视化"** 这一组合——这是 DaisyDisk / GrandPerspective / Pearcleaner 系产品的差异化阵地，也是 GSYCleanMac BulkScanner 路线的留白机会。

---

## 5. 对 GSYCleanMac 的启示（产品决策参考）

1. **维护脚本**（OnyX 路线）：是一条**低维护成本但高用户感知**的支线，可以做一个轻量"一键执行 daily/weekly/monthly + 重建 LaunchServices/Spotlight"小面板，不冲突主线，但能补全"老 Mac 卡顿一键修"叙事。
2. **硬件监控**（Sensei 路线）：**建议明确不做**，理由是 SMC / IOReport 反向工程维护成本高，且 Sensei / iStat Menus 已霸位多年，进入意义不大。
3. **Smart Assistant / 后台日扫**（MacFly Pro 路线）：可考虑做**轻量级版本**——后台日扫只统计"可清理总体积 + 大文件超阈值数 + 重复 GB"，避免做"自学习"这种黑盒承诺。
4. **任意目录递归下钻** 仍是 GSYCleanMac 在 BulkScanner 上的核心杀招（参考 `Packages/ScanKit/Sources/ScanKit/BulkScanner.swift:261`），三家都没有，这是真正的护城河方向。

---

*文档结束*
