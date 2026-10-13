# DaisyDisk 完整功能菜单

> 调研对象：DaisyDisk 4.33.x（截至 2026-02-26 最新版）
> 调研目的：作为 AmuxAIClean「任意目录扫描 + 大目录可视化」派别的功能对齐参考。
> 标注图例：[目录] 任意路径 / [图] 可视化 / [Y] 删除操作 / [设] 设置项 / [搜] 扫描入口 / [导航] 导航 / [安全] 安全 / [云] 云盘 / [键] 快捷键

---

- **Scan Locations（扫描入口）**
 - [搜][目录] **Internal Drives（内置磁盘）** —— 启动盘默认置顶，直接点 `Scan` 按钮
 - [搜] **External Drives（外置磁盘）** —— USB / Thunderbolt / Firewire / SD / CF / 光盘
 - [搜] **Removable Media（可移除介质）** —— Flash、内存卡、CD/DVD/Blu-ray
 - [搜] **Connected Servers（网络盘）** —— NAS、AFS、Samba、NFS、WebDAV、Novell、Windows、FTP（via FUSE）
 - [搜] **Virtual Disks（虚拟盘）** —— FUSE、disk images
 - [搜][目录] **Folder（任意目录扫描，独立按钮）** —— 主界面 `Scan Folder…` 按钮，或从 Finder 拖拽任意文件夹到 DaisyDisk 窗口 / Dock 图标
 - 支持 **App Bundle / Package** 直接拖入当作目录扫描（4.25 起）
 - 扫描过的文件夹会出现在 sources 列表，可 ** Star 收藏** 持久化到下次启动
 - [云] **Cloud Storage（独立 `Scan Cloud` 按钮，4.25 起从 Scan Folder 中拆出）**
 - [云] Dropbox（含 Team Account 共享文件夹）
 - [云] Google Drive
 - [云] Microsoft OneDrive（区分 personal / business）
 - [云] Box
 - [搜] **Time Machine 卷** —— 可扫，但耗时通常 20–30 分钟
 - [搜] **Parallel Scan（多盘 / 多目录并行扫描）** —— 同时启动多个扫描任务，互不阻塞
 - [搜][安全] **Scan as Administrator（以管理员权限扫描）** —— 磁盘下拉菜单中选「Scan as Administrator」并输入管理员密码（仅本地 APFS / HFS+，**仅 stand-alone 版**，Mac App Store 版不支持）
 - [搜] **Quick Rescan as Administrator** —— 增量重扫
 - [搜] 按住 触发 **Full rescan** —— 全量重扫
 - [搜][安全] **Hidden Areas / Hidden Space（隐藏空间专项入口，DaisyDisk 的特色）** —— 不是独立扫描入口，而是扫描结果中作为一个**虚拟扇区**直接出现，可下钻
 - [搜] child: **purgeable space**（可回收空间，含 Time Machine 本地快照、swap、sleep image）
 - [搜] child: **other volumes**（APFS 同物理盘内其他子卷）
 - [搜] child: **snapshots**（APFS 本地快照列表 + 估算大小）
 - [搜] child: **still hidden**（其他用户家目录、Spotlight 索引、文档版本、文件系统开销）

- **File System Support（文件系统支持）**
 - APFS（含 dataless files，4.31 起）
 - HFS+ / HFS
 - NTFS / FAT / exFAT（默认只读，需第三方驱动写）
 - FUSE 扩展更多文件系统

- **Visualization（可视化）**
 - [图] **Sunburst Map（同心环 / 太阳光 / 雏菊环图）** —— 主可视化，从中心向外为目录层级
 - [图] **Petals（花瓣 = 文件/目录）** —— 彩色花瓣 = 目录，灰色 = 文件；宽度 = 大小；自动按大小排序
 - [图] **Concentric Rings（同心层级）** —— 内圈 = 父目录、外圈 = 子目录，越靠中心越大
 - [图] **文件类型颜色编码** —— 按顶层类别上色（Yellow=System、Green=Applications、其他类型有各自配色）
 - [图] **Smaller Objects 聚合（半透明花瓣）** —— 太小无法单独显示的文件/目录被合并为一个半透明扇区，点击可展开
 - [图] **Sidebar List（右侧列表面板）** —— 鼠标悬停目录即在右侧实时显示其内容列表
 - [图] **Breadcrumb / 中心点反向导航** —— 点击图中心 = 返回父目录（充当面包屑作用）
 - [图] **Strikethrough Items（删除线）** —— 已删除/重命名/移走的文件，提示需要重扫
 - [图] **Purple Items（紫色项）** —— 受限文件/目录，需 Scan as Administrator 才能测量
 - [图] **Disk Usage Gauge（磁盘容量条）** —— 启动后总览页，绿/黄/红 三段提示剩余空间
 - [键] 按住 切换是否把 purgeable space 算入「已用」
 - [图] **Real-time Used/Free 更新** —— 总览页磁盘剩余空间实时刷新
 - [图] **Achievement Sharing** —— 释放空间后可分享到社交网络（4.33 拓宽支持的网络）

- **Drill-Down 下钻交互（重点细节 1）**
 - [导航] **单击 petal（扇区）** —— 直接钻入该子目录，sunburst 重绘以该目录为中心
 - [导航] **悬停 petal**（不点击）—— 右侧 sidebar 同步显示该目录内容
 - [导航] **点击 sunburst 中心圆心** —— 返回父级（"Go to enclosing folder"）
 - [导航] **Cmd↑** 键盘上行一级目录
 - [导航] **Pinch close（双指捏合）** —— Multi-Touch 触控板手势 = 上行一级目录
 - [导航] **Pinch open（双指张开）** —— 钻入指针所指目录 / 展开 smaller objects
 - [导航] **Return（回车）** —— 钻入指针所指目录
 - [导航] **Cmd[ / Cmd]** —— 浏览历史后退 / 前进（像浏览器）
 - [导航] **方向键 ↑↓** 在 sidebar 内逐项选择
 - [导航] **PgUp / PgDn / Home / End** 翻页 / 跳首尾
 - [导航] **Go 菜单 -> Expand "smaller objects"** 展开聚合花瓣（4.25 起）
 - [导航] **Go 菜单 -> Always expand "smaller objects"** 永久记忆每个目录的展开状态（4.25 起）
 - [导航] **Show Package Contents（右键菜单）** —— 把 .app / bundle 当作目录展开（与 Finder 一致）
 - [导航] **键盘导航**（4.25 起）—— 完整方向键 + Tab 在 sunburst / sidebar / collector 间切换

- **Hidden Files 隐藏文件处理（重点细节 2）**
 - [安全] **默认行为：不需要专门 toggle，DaisyDisk 默认把所有"看得见的"文件全部计入**（包含 dotfiles，因为它扫的是 inode 元数据，不是 Finder 的展示规则）
 - [安全] **没有 "Show Hidden Files" 开关** —— 不像 Finder 那样区分 dot 开头/不开头；只要权限够就算
 - [安全] **真正的"隐藏"在 DaisyDisk 语义中 = 受权限限制访问不到的区域**，作为虚拟扇区 **hidden space** 显示
 - [安全] **Full Disk Access toggle 入口**：`DaisyDisk -> Preferences… -> Full Disk Access` 标签页 [设]
 - [设] 提供拖拽弹跳图标的引导动画到 System Settings -> Privacy & Security -> Full Disk Access
 - [设] 实时显示当前是否已授予 FDA
 - [安全] **Scan as Administrator 命令** —— 揭露 root 权限才能看到的目录（其他用户家目录、/private 子项等）
 - [安全] **Restricted folders（受限目录）** —— 在结果中以**紫色**标记，提示需要管理员重扫
 - [安全] **Snapshots（APFS 本地快照）** —— 默认在 hidden space 子项中可见、可估算大小、可删除（stand-alone 版直接删；MAS 版需复制 DaisyDisk 给的脚本到 Terminal 执行）

- **Big File Locating 大文件查找（重点细节 3）**
 - [搜][图] **没有独立的"Find Large Files"列表入口** —— DaisyDisk 主打可视化，size 大 = 扇区大，**靠 sunburst 自然把"大头"推到最显眼位置**
 - [图] **petal 宽度排序** —— 同一层级所有文件/目录默认按 size 降序排列，最大的最显眼
 - [图] **Smaller Objects 聚合** —— 把"非大头"自动合并消失，相当于反向"只看大文件"
 - [导航] **Locating Space Wasters（用户手册章节）** —— 官方推荐排查路径：iTunes、~/Movies、~/Music、~/Downloads、Mac App Store / Steam 游戏、~/Library/Application Support、Hidden / Purgeable Space
 - [图] **物理大小 (allocated) 而非逻辑大小** —— 比 Finder 的 logical size 更准（仅网络盘例外）
 - [图] **Hard Link 处理** —— 见手册 Hard Links 条目；多硬链接共享 inode 不重复计算
 - [图] **APFS 子卷共享空间识别** —— "other volumes" 让你看清同物理盘内其他卷占了多少

- **Actions（操作）**
 - [Y] **Drag to Collector（拖入 Collector 暂存区）** —— sunburst 上扯下 petal 拖入底部 Collector 区域
 - [Y] **Right-click -> Move "Selected File" to Collector** —— 右键菜单加入 Collector
 - [Y][键] **Cmd** —— 把指针所指文件 / 目录加入 Collector 或从 Collector 移除
 - [Y] **Expand Collector（展开 Collector）** —— 点击 Collector 区域可放大查看待删列表，可拖出、可点 × 移除
 - [Y] **Delete 按钮触发实际删除** —— 在 Collector 中点 Delete
 - [Y] **5-second Cancel 倒计时** —— Delete 后弹出 5 秒倒计时，可点 Cancel 撤销
 - [Y] **永久删除（不进 Trash！）** —— 直接释放磁盘空间，无法 Undelete（要靠第三方恢复软件）
 - [Y] **Reveal in Finder** —— Cmd+鼠标点击 = 在 Finder 中显示该文件
 - [Y] **Quick Look 预览** —— Space 空格键预览，调用系统 Quick Look，自动应用插件
 - [Y] **Right-click -> Preview** —— 右键菜单预览
 - [Y] **Batch Deletion** —— Collector 支持一次累积多个文件再批删（典型做法）
 - [Y][安全] **Safety Stoppers（安全闸）** —— `/System` `/Library` 当前用户 home 等关键目录 Collector 拒绝接受
 - [Y][安全] **Semi-transparent (consolidated) petals 不可拖删** —— 必须先展开
 - [Y][安全] **写权限不足时自动尝试提权**（在支持的版本上）
 - [Y] **Purge Purgeable Space** —— 把 hidden space -> purgeable space 项拖入 Collector -> Delete，强制立即回收
 - [Y] **Delete Snapshots** —— 把 snapshots 项拖入 Collector 删除（stand-alone 直接删；MAS 版需 Terminal 脚本）
 - [Y] **Drop External Files via Drag-In** —— 从 Finder 直接拖入 Collector 待删（非扫描结果项）

- **Deletion Flow 删除流程（重点细节 4，串联）**
 1. 在 sunburst 上锁定目标 -> 拖出 petal **OR** Cmd **OR** 右键 Move to Collector
 2. 文件**进入 Collector 暂存**（可累积多次，可展开核对，可 × 移除）
 3. 点击 Collector 上 **Delete 按钮**
 4. 弹出 **5 秒倒计时确认条**，可 Cancel
 5. 倒计时结束后 **永久删除（绕过 Trash）**，磁盘空间立即可见释放
 6. **空间未立即释放？** 因 Time Machine 把删的文件挪到本地快照 -> purgeable space，需要等 macOS 自动清理或在 DaisyDisk 内强制 purge
 7. [N] **没有 Undo / Undelete** —— 删了就是删了

- **Settings / Preferences（[设] 设置项）**
 - [设] **Full Disk Access 面板**（Preferences 中独立 Tab）—— 引导授权
 - [设] **Forget Scan Results** 命令 —— 释放 RAM（扫描快照可能占数百 MB）
 - [设] **Star Folder（收藏常扫目录）** —— 持久化到 sources 列表
 - [设] **多语言**：英、法、德、意、波、俄、西、葡、瑞典、土、乌克兰、简中、繁中、日（共 14 种）
 - [设] **License 类型**：Mac App Store 版 vs Stand-alone 版（功能集略有差异，前者无 Admin Scan）
 - [设] **Free Trial（无期限免费试用）** —— 可扫描可可视化，删除需付费
 - [设] **Family Sharing（家庭共享）** —— MAS 版最多 6 人共享
 - [设] **学生折扣** —— 5 折（$4.99）
 - [设] **Dock 图标进度指示器** —— 扫描时显示进度
 - [设] **Real-time disk gauge in overview** —— 总览页持续刷新

- **Keyboard Shortcuts（[键] 快捷键完整表）**
 - ↑ / ↓ —— sidebar 上下选择
 - PgUp / PgDn / Fn-> / Fn↑ —— 翻页
 - Home / End / Fn↓ / Fn<- —— 跳首尾
 - **Cmd↑** —— 上行一级目录
 - **Cmd[ / Cmd]** —— 历史后退 / 前进
 - **Return** —— 钻入 / 展开 smaller objects
 - **Space** —— Quick Look 预览
 - **Cmd** —— 加入 / 移出 Collector
 - **Cmd+点击** —— Show in Finder
 - **CmdR** —— 重扫当前目录
 - **CmdR** —— 重扫整盘 / 顶层
 - ** 按住** —— 切换 disk gauge 中 purgeable 的归属

- **Multi-Touch Gestures（触控板手势）**
 - [导航] **Pinch close** —— 上行一级
 - [导航] **Pinch open** —— 下钻 / 展开 smaller objects

- **Privacy & Safety（隐私与安全）**
 - [安全] 仅扫元数据（name + size），不读文件内容
 - [安全] 不收集任何用户数据
 - [安全] 不外传任何数据
 - [安全] 不上报统计 / analytics
 - [安全] Safety Stoppers 阻止误删 system-critical 路径
 - [安全] 不做任何"自动清理"，全部由用户决定

- **Performance（性能基准，官方）**
 - HFS+ SSD 启动盘：6–12 秒
 - APFS SSD 启动盘：12–20 秒
 - HFS+ HDD 启动盘：20–40 秒
 - APFS HDD 启动盘：40–60 秒
 - NTFS / FAT / exFAT：3–5 分钟
 - Time Machine：20–30 分钟
 - 比同类软件快 6–32 倍（官方称）

- **AmuxAIClean 对照启示（备忘）**
 - [目录] 必须复刻：Folder Scan + Star Folder + Drag-In Folder
 - [图] 可借鉴但不必照搬 sunburst：可考虑 Treemap / 列表 hybrid
 - [安全] Hidden Space 的「虚拟扇区」表达方式很值得学：把"扫不到的"显式化、可下钻、可解释
 - [Y] Collector + 5s Cancel 是高安全感的成熟范式，比直接 Delete 更友好
 - [警告] 注意：DaisyDisk **永久删除**而非 Trash —— AmuxAIClean 是否要采用相同策略需讨论（可以做成可选）

---

## 信息来源 URL

- DaisyDisk 官网首页：https://daisydiskapp.com/
- Tech Specs（支持磁盘 / 文件系统 / 速度 / 隐私）：https://daisydiskapp.com/specs
- Hidden Space 专页：https://daisydiskapp.com/specs/hidden
- Speed 专页：https://daisydiskapp.com/specs/speed
- Safe 专页：https://daisydiskapp.com/specs/safe
- Disks 专页：https://daisydiskapp.com/specs/disks
- 用户手册首页：https://daisydiskapp.com/guide/4/en/
- Disk Overview & Scanning：https://daisydiskapp.com/guide/4/en/DisksOverview/
- Understanding the Disk Map（sunburst / 下钻）：https://daisydiskapp.com/guide/4/en/UnderstandingSunburst/
- Locating Space Wasters：https://daisydiskapp.com/guide/4/en/LocatingSpaceWasters/
- Previewing：https://daisydiskapp.com/guide/4/en/Previewing/
- Deleting Files（Collector & 5s 倒计时）：https://daisydiskapp.com/guide/4/en/DeletingFiles/
- Hidden Space：https://daisydiskapp.com/guide/4/en/HiddenSpace/
- Restricted folders：https://daisydiskapp.com/guide/4/en/Restricted/
- Local APFS Snapshots：https://daisydiskapp.com/guide/4/en/Snapshots/
- Full Disk Access：https://daisydiskapp.com/guide/4/en/FullDiskAccess/
- Scanning as Administrator：https://daisydiskapp.com/guide/4/en/AdminScan/
- Parallel Scanning：https://daisydiskapp.com/guide/4/en/ParallelScan/
- Cloud Scan：https://daisydiskapp.com/guide/4/en/CloudScan/
- Keyboard Shortcuts & Gestures：https://daisydiskapp.com/guide/4/en/Hotkeys/
- Tips & Tricks：https://daisydiskapp.com/guide/4/en/TipsAndTricks/
- Release Notes（版本变更，含 4.25/4.21/4.20.5 关键节点）：https://daisydiskapp.com/releases
- Today on Mac 评测（sunburst + drill-down 描述）：https://www.todayonmac.com/daisydisk-where-did-all-your-mac-storage-go/
- OWC Rocket Yard 评测（Collector 拖删 / 颜色编码描述）：https://eshop.macsales.com/blog/97883-reclaim-your-mac-storage-with-daisydisk/
- Dr.Buho DaisyDisk 评测（隐藏文件 / FDA / 倒计时印证）：https://www.drbuho.com/jp/how-to/daisydisk-review
- softwarevs 评测（reddit 社区口碑印证）：https://softwarevs.com/fr/daisydisk-avis/
