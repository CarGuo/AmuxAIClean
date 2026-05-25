# OmniDiskSweeper 深调研（The Omni Group - 免费）

> 调研日期：2026-05-22
> 调研对象版本：OmniDiskSweeper 1.13（macOS Mojave+，含 Apple Silicon / macOS 26 Tahoe 兼容版）
> 标签图例：[目录] 任意路径扫描 | [卸载] 卸载 | [图] 可视化 | [Y] 删除 | [设] 设置

OmniDiskSweeper 是一款定位极其克制的"列式磁盘分析器"：只做一件事——把硬盘按"占用大小降序"列成一棵可下钻的目录树，让用户自己决定是否清理。它**不做应用卸载、不做按类聚合、不做可视化图形**，因此在与 DaisyDisk / CleanMyMac 的对比中以"轻量、快、透明"取胜。

---

## 1. 完整功能菜单（树状）

```
OmniDiskSweeper
├── 启动与扫描入口
│ ├── 启动后默认弹出"Drive List"窗口（列出所有本地卷 / 外置卷 / 网络卷） [图]
│ ├── 选中目标卷 -> 点击底部 "Sweep "<Volume>" Drive" 开始全盘扫描 [图]
│ ├── File > Sweep Drive…（菜单等价入口） [目录]
│ ├── File > Size Folder…（CmdO）—— 任选任意目录扫描 [目录][Y]【任意路径入口】
│ ├── 把 Finder 中的文件夹拖到 Dock/App 图标 -> 计算该文件夹大小 [目录]
│ └── 终端以 root 启动：sudo /Applications/OmniDiskSweeper.app/Contents/MacOS/OmniDiskSweeper
│ └── 解锁系统受保护文件 / 其他用户文件的尺寸读取 [设][目录]
│
├── 扫描结果浏览（核心 UI：Finder 式列视图）
│ ├── 多列下钻（Column / Browser View，类似 Finder 列模式） [图]
│ │ ├── 第 1 列：根目录 / 卷顶层
│ │ ├── 第 2 列：选中项的子目录
│ │ ├── 第 N 列：随选择继续向右展开（无层级深度限制） [图]
│ │ └── 列内默认按 Size 降序排序，"空间大头"始终置顶 [图]
│ ├── 行字段：Name / Size / Kind [图]
│ ├── 颜色编码（按尺寸深浅着色，肉眼快速辨识"大块"） [图]
│ ├── 包/Bundle 展开：可进入 .app / .bundle 内部继续下钻 [目录][图]
│ ├── 隐藏文件 / Dotfile 默认显示（无需开关，直接列出 .Trash / .DS_Store / ~/Library 等） [目录]
│ ├── Package Receipt 反查：选中文件 -> 显示其归属的安装包（受 ReceiptFolders 控制） [设]
│ └── 实时统计窗格：底部状态栏显示当前选中项总大小 [图]
│
├── 操作与删除
│ ├── 默认按钮："Trash"（移入废纸篓，可恢复） [Y]【Trash 流程】
│ │ ├── 快捷键 Cmd 或左下角 Trash 按钮
│ │ └── 多选删除：Cmd 点选 /  连选后批量 Trash [Y]
│ ├── 按住 Option 键 -> Trash 按钮变为 "Destroy"（绕过废纸篓直接销毁） [Y]【二次确认/警示】
│ │ └── 选中项已在 Trash 内 -> 自动变为 Destroy，并显示大号[警告]警告标志 [Y]
│ ├── 已知不可删除项（权限/系统保护）-> Trash 按钮自动禁用并预先提示 [Y]
│ ├── Reveal in Finder（在访达中显示） [目录]
│ └── 错误报告：删除失败时弹出错误清单（1.10 起强化） [设]
│
├── 视图与导航
│ ├── View > Show/Hide hidden columns（部分版本提供包归属列） [设]
│ ├── 键盘箭头 <- -> ↑ ↓ 在列与项之间穿梭 [图]
│ ├── CmdR 重新扫描当前卷 [图]
│ └── 多窗口：可同时打开多个卷或多个 "Size Folder" 任务 [图][目录]
│
├── 设置与隐藏偏好（Preferences / defaults）
│ ├── App 几乎无 GUI 偏好面板（极简哲学） [设]
│ ├── 隐藏偏好 ReceiptFolders：控制扫描哪些目录的包收据，或彻底关闭 [设]
│ │ └── 用 `defaults write com.omnigroup.OmniDiskSweeper …` 设置
│ ├── Sandboxing 自 1.10 起启用（首次访问会弹权限请求） [设]
│ ├── 自动跳过带 "don't browse" 标志的系统卷 / Time Machine 备份卷 [设]
│ └── APFS 卷被识别为本地卷而非网络卷 [设]
│
├── 兼容性与运行模式
│ ├── 普通双击启动：仅看到当前用户有权访问的内容 [设]
│ ├── sudo 启动（root 模式）：看到全盘所有用户文件，但风险更高 [设][目录]
│ ├── 兼容 macOS Mojave (10.14) ~ macOS 26 Tahoe，Universal (Intel + Apple Silicon) [设]
│ └── 历史版本仍提供（10.4 / 10.6 / 10.8 / 10.12 / 10.13 各自独立 dmg） [设]
│
└── 不提供的功能（明确否定项，便于对比）
 ├── 应用卸载（无 [卸载]）—— 不识别 ~/Library 关联文件
 ├── 图形化 Sunburst / 矩形树图（与 DaisyDisk 形成对比）
 ├── 重复文件 / 大文件类别聚合
 ├── 后台监听 / 常驻进程 / Dock 角标
 └── 多语言（仅英文 UI）
```

**叶子节点统计：上方树共 49 个叶子（每行末尾以单条说明结尾的项）。**

---

## 2. 重点 4 问

### (a) 任意目录扫描入口在哪？[目录]
- **菜单**：`File > Size Folder…`，快捷键 **CmdO**，弹出标准目录选择面板，可选任意路径（包括外置卷、~/Library、/private/var 等）。
- **拖放**：把 Finder 中任意文件夹拖到 OmniDiskSweeper 的 Dock 图标 / 应用图标上，触发同等"指定目录扫描"。
- **效果**：以选中目录为根，独立打开一个"列视图"窗口，与全盘扫描互不干扰，可同时存在多个窗口。
- **来源**：`maczd.com` 中文教程明确写出"在顶部选择 File - Size Folder 或快捷键 Cmd+O，进行手工选择需要扫描分析的文件夹"；官方 1.10 Release Notes 同时确认 "Folder Drop — Dragging a folder from Finder and dropping it onto the OmniDiskSweeper app icon will now calculate that folder's size"。

### (b) 多层下钻交互如何？[图]
- **形态**：Finder 风格的 **多列浏览器视图（Column / Browser View）**，**不是**树形 Outline、也**不是**图形地图。
- **交互**：选中左列任一项 -> 右侧立即追加下一列展示其子项；继续往右选 -> 再追加一列。**层级无硬上限**，列可水平滚动。
- **排序**：每列默认 **Size 降序**，颜色按尺寸深浅着色，最大占用始终置顶（informer.com / softwarevs.com 复述："sorts files and folders strictly from largest to smallest"）。
- **包穿透**：可进入 `.app / .bundle / .pkg` 内部继续下钻，便于定位 Xcode 模拟器缓存等"App 内大文件"。
- **来源**：ezone.co.uk 实测："OmniDiskSweeper enables people to drill down into specific folders, revealing subfolders and files which may be hidden within applications…I have drilled right down into my Users > Username > Library…"。

### (c) 隐藏文件处理？[目录]
- **默认即显示所有点文件 / Dotfile / 隐藏目录**，无需切换开关。这是与 Finder 最大的差异，也是它常被推荐用来排查"~/Library 黑洞"的关键原因。
- **系统受保护 & 其他用户的文件**：普通启动看不到大小（权限不足）。要看到完整尺寸，需要以 root 启动：
 `sudo /Applications/OmniDiskSweeper.app/Contents/MacOS/OmniDiskSweeper`
- **System Volume / Time Machine 卷**：自动跳过（带 "don't browse" 标志），即使隐藏也不显示。
- **来源**：maczd.com："OmniDiskSweeper 可以分析显示包括隐藏文件在内的所有磁盘文件夹占用"；macdownload.informer.com："it also displays hidden files and lets you remove them with minimum effort"；bioniccat 客服文档详述 sudo 启动法。

### (d) 删除流程（直删 / Trash / 二次确认）？[Y]
1. **默认 = Trash 流程（1.10 起为新默认）**：
 - 选中项后点击左下角 **Trash 按钮** 或按 **Cmd**。
 - 文件被移动到用户废纸篓，可在废纸篓中恢复。
2. **直删 = Destroy 流程（绕过 Trash）**：
 - 按住 **Option () 键**，Trash 按钮文字变为 **Destroy**，并显示警告图标。
 - 也可在 Edit 菜单按 Option 直接选 Destroy 项。Destroy 不可恢复。
3. **隐式二次确认**：
 - 当所选文件已经在 Trash 中，按钮自动变为 Destroy + [警告]，相当于强提醒"再删一次就真没了"。
 - 若选中项含不可删除文件，Trash 按钮直接置灰，并提前列出错误，避免点了才报错。
4. **批量**：Cmd/ 多选后一次性 Trash / Destroy。
5. **不会自动删除任何东西**——OmniDiskSweeper 始终是"诊断工具"，所有删除都需用户明确点击。
- **来源**：官方 Release Notes 1.10：`Replaced ... Delete button with a Trash button … If the selected files are already in your trash, it becomes a Destroy button … You can also get to the Destroy button … by holding the Option key`；softwarevs.com 评测："it won't automatically delete anything … you still have to click … before you delete it"。

---

## 3. 信息来源

1. OmniDiskSweeper 官方下载与简介页：https://www.omnigroup.com/more
2. OmniDiskSweeper 1.10 官方 Release Notes（Trash/Destroy 行为权威定义）：https://www.omnigroup.com/releasenotes/omnidisksweeper/1.10
3. Bionic Cat 知识库 - sudo 启动以查看全盘所有用户文件：https://bioniccat.freshdesk.com/support/solutions/articles/3000061295-running-omnidisk-sweeper-as-root-to-discover-space-eating-files-and-folders
4. maczd.com - 中文使用教程（含 CmdO Size Folder 入口、隐藏文件支持）：https://www.maczd.com/post/omnidisksweeper.html
5. macdownload.informer.com - 1.9 评测（隐藏文件 / 直删特性确认）：https://macdownload.informer.com/omnidisksweeper/1.9/
6. softwarevs.com - 2025/2026 实测评测（性能、列视图、诊断哲学）：https://softwarevs.com/omnidisksweeper-review/
7. ezone.co.uk - OmniDiskSweeper + AppCleaner 联合清理实战：https://www.ezone.co.uk/blog/optimise-mac-cleanup-using-omnidisksweeper-and-appcleaner.html
