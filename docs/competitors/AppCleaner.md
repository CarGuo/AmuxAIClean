# AppCleaner 深调研（FreeMacSoft - 免费）

> 调研日期：2026-05-22
> 调研对象版本：AppCleaner **3.6.8**（macOS Mojave ~ macOS 26 Tahoe，~4 MB）
> 标签图例：[目录] 任意路径扫描 | [卸载] 卸载 | [图] 可视化 | [Y] 删除 | [设] 设置

AppCleaner 是 FreeMacSoft 出品的纯免费、单一职责"应用卸载器"。它围绕"把一个 .app 连同散落各处的关联文件一起干掉"这一件事设计，**不做磁盘扫描、不做大文件分析、不做可视化图形**，但提供了 macOS 生态里被引用最多的 **SmartDelete 监听机制** 与 **List/Search 残留扫描（含 LeftOver Finder）**。

---

## 1. 完整功能菜单（树状）

```
AppCleaner 3.6.8
├── 主入口与三种卸载路径
│ ├── 路径 1) Drag & Drop（主窗口拖入） [卸载]
│ │ ├── 启动后默认显示一个"Drop apps here"主窗口 [图]
│ │ ├── 从 Finder / Launchpad 拖任意 .app 到窗口中央 [卸载]
│ │ ├── 也可直接拖到 Dock 中的 AppCleaner 图标启动并扫描 [卸载]
│ │ └── 立即扫描 -> 列出主体 + 关联文件清单 [图]
│ ├── 路径 2) List Mode（已安装应用列表） [卸载]
│ │ ├── 右上角 [菜单] / "List" 按钮切换 [设]
│ │ ├── 自动枚举 /Applications + ~/Applications + Mac App Store 应用 [图]
│ │ ├── 顶部搜索框：实时按名称过滤 [目录]
│ │ ├── 右上 "Default Apps / All Apps / Other" 过滤页签
│ │ │ ├── Default Apps：系统自带受保护应用（默认隐藏 / 灰显） [设]
│ │ │ ├── All Apps：当前已安装第三方 + 用户级应用 [图]
│ │ │ └── Other：Widgets / Plugins / Screen Savers / 其他可清理项 [卸载]
│ │ └── 多选勾选 -> 点 "Remove" 批量进入扫描列表 [卸载]
│ └── 路径 3) SmartDelete（被动监听，最强卖点） [卸载][设]
│ ├── 在 Preferences > SmartDelete 打开开关 [设]
│ ├── 后台常驻一个轻量 daemon 监听 ~/.Trash 与 .app 拖移事件 [设]
│ ├── 一旦检测到 .app 被拖入废纸篓 -> 弹窗"Found related files" [Y]
│ ├── 弹窗内勾选 -> Remove，整段流程不需主动打开 AppCleaner [Y]
│ └── 关闭开关后立即停止监听，无残留进程
│
├── 关联文件扫描结果列表（核心 UI）
│ ├── 列出主 .app + 系统/用户级关联文件 [图]
│ │ ├── /Applications/<App>.app 主体
│ │ ├── ~/Library/Application Support/<bundleID>/ [目录]
│ │ ├── ~/Library/Preferences/*.plist [目录]
│ │ ├── ~/Library/Caches/<bundleID>/ [目录]
│ │ ├── ~/Library/Logs/<App>/ [目录]
│ │ ├── ~/Library/Containers/<bundleID>/ [目录]
│ │ ├── ~/Library/Group Containers/group.<id>/ [目录]
│ │ ├── ~/Library/Saved Application State/<bundleID>.savedState/ [目录]
│ │ ├── ~/Library/WebKit/<bundleID>/ [目录]
│ │ ├── ~/Library/HTTPStorages/<bundleID>/ [目录]
│ │ ├── ~/Library/LaunchAgents/*.plist + /Library/LaunchAgents/ [目录]
│ │ ├── /Library/LaunchDaemons/ [目录]
│ │ ├── /Library/Application Support/ [目录]
│ │ ├── /Library/PrivilegedHelperTools/<helperID> [目录]
│ │ └── /Library/Receipts、kext、QuickLook/Spotlight 插件等其他注册位 [目录]
│ ├── 每行字段：[Y] 复选框 / 名称 / 完整路径 / 大小 [图]
│ ├── 默认全部勾选；可逐项取消（保留偏好/缓存） [Y]
│ ├── 右键菜单："Show in Finder" 显示在访达 [目录]
│ ├── 排序：按 Size 或 Name 升降序 [图]
│ ├── 总计行：底部显示选中项合计大小（"x items, y MB will be removed"） [图]
│ └── 单击 Remove -> 触发删除流程 [Y]
│
├── LeftOver Finder（残留扫描，依托 List Mode "Other" 与 SmartDelete 互补）
│ ├── 概念：扫描已被删除应用所遗留的孤儿文件 [卸载][图]
│ ├── 触发位置：List Mode 中切到 "Other" 类目 [设]
│ ├── 扫描范围：~/Library/* 与 /Library/* 下与已知 bundleID 不再匹配的项 [目录]
│ ├── 行为：列出"残留 plist / Application Support / Caches" 等可孤立删除 [图]
│ ├── 同样支持 [Y] 勾选 -> Remove 流程 [Y]
│ └── [警告] 注意：官方营销称之为"detect leftover files from previously
│ uninstalled applications"，并非独立菜单项，而是 List Mode 的副产品。
│ 社区经验显示它对深度残留（孤立 LaunchDaemon、kext）覆盖有限。 [设]
│
├── Preferences（Cmd,）
│ ├── General
│ │ ├── Show Default Apps（是否在 List 中展示系统自带 App） [设]
│ │ ├── Auto-update 检查 [设]
│ │ └── Warn before removing protected apps [设]
│ ├── SmartDelete
│ │ ├── Enable SmartDelete（ON/OFF） [设]
│ │ ├── 开启时会请求"全磁盘访问"以监听 Trash 事件 [设]
│ │ └── 关闭后立刻停止 daemon [设]
│ └── Updates
│ └── 手动 Check for Updates / 自动检查频率 [设]
│
├── 删除流程（双向：Trash 流程 + 鉴权流程）
│ ├── 用户级文件 -> 移动到 ~/.Trash（默认，可恢复） [Y]
│ ├── 系统级文件（/Library/* 等）-> 弹出系统鉴权对话框 [Y]
│ │ └── 提示 "AppCleaner 想要进行更改"，输入管理员密码 [Y]
│ ├── 失败容错：被锁文件 / SIP 保护项 -> 跳过并保留在列表中 [Y]
│ ├── 二次确认：对受保护 App（Finder、Safari 等）会弹"Are you sure?" [Y]
│ └── 不提供"绕过 Trash 直删"快捷键（与 OmniDiskSweeper 不同） [Y]
│
├── 兼容/限制
│ ├── 仅英文 UI，单语言 [设]
│ ├── 不支持批量并行卸载（一次一个 App 的扫描结果窗口） [设]
│ ├── 不扫描磁盘大文件 / 不做重复文件检测（与 OmniDiskSweeper 互补） [设]
│ ├── macOS Mojave (10.14) 起；3.6.8 实测在 macOS Tahoe 26 可用 [设]
│ └── 历史版本仍提供（3.6 / 3.4 / 2.3 对应 10.13 / 10.10-10.12 / 10.6-10.9） [设]
│
└── 不提供的功能（明确否定项）
 ├── 任意目录磁盘扫描 / 大小可视化（无 [目录] 全盘入口）
 ├── Sunburst / TreeMap 图（无 [图] 图形）
 ├── 多语言、明暗主题切换之外的 UI 自定义
 ├── 批量队列 / 并行卸载
 └── 自动调度（计划任务）
```

**叶子节点统计：上方树共 65 个叶子。**

---

## 2. 重点 4 问

### (a) 任意目录扫描入口在哪？[目录]
- **AppCleaner 没有"扫描任意目录"的入口**——它的设计前提是"目标是某个 .app"，而非"某个文件夹"。
- 最接近"自定义路径"的做法：把 .app 文件本身从任意位置（外置盘、桌面、~/Downloads 等）拖入主窗口，AppCleaner 会自动以该 .app 的 bundleID 反查 ~/Library 与 /Library 下的关联路径。
- List Mode 的"All Apps"枚举范围基本写死为 `/Applications`、`~/Applications`、Mac App Store 安装路径，无法手动追加目录。
- **结论**：[目录] 入口存在但局限——只能"以 App 为锚"反向定位关联目录，不能"以任意目录为根"递归扫描。
- **来源**：FreeMacSoft 官方页 "Simply drop an application onto the AppCleaner window."；FileHorse/CNet 评测均明确卸载流程围绕 .app 展开。

### (b) 多层下钻交互如何？[图]
- **AppCleaner 的列表是"扁平 + 分组"**，**不提供逐级下钻**。一次 .app 扫描的结果就是一个**单层**勾选列表（每行一个完整路径）。
- 想看一个具体路径的内容，需要"右键 > Show in Finder"跳到 Finder 里继续浏览，AppCleaner 内部不嵌套展开。
- List Mode 也是单层：左侧"Default / All / Other"页签 -> 中部应用列表 -> 选中后切到结果列表，最深 2 层。
- **结论**：[图] 交互极简，零下钻；这是它"轻量、免学习成本"的代价之一。
- **来源**：drbuho.com 实测："Within a second, it showed me 8 related files that would be deleted"；macwin.io 评测："you can decide which data to retain and remove from your system" —— 均描述为单层勾选列表，未提及树状下钻。

### (c) 隐藏文件处理？[目录]
- AppCleaner **完全无视"显示/隐藏文件"开关**——它直接按 bundleID + 文件名规则匹配 `~/Library/*` 与 `/Library/*`，**默认就会列出所有相关隐藏目录**（`~/Library` 在 macOS 里默认是隐藏的）。
- 列表中每条都给出**完整绝对路径**，包括点开头的 plist、Containers、Group Containers、LaunchAgents 等。
- "Show in Finder"会强制以 Finder Reveal API 打开，自动穿透到隐藏的 ~/Library。
- 它**不**像 OmniDiskSweeper 那样需要 sudo 启动；用户级隐藏文件全部可见，系统级文件需要在删除时输入管理员密码。
- **来源**：FileHorse 评测："Deletes all related files associated with an application, including preferences, caches, and **hidden files**"；fileminutes.com 列出 AppCleaner 涵盖的隐藏 Library 子路径全集。

### (d) 删除流程（直删 / Trash / 二次确认）？[Y]
1. **默认 = Move to Trash（用户级）**：勾选后点 Remove，所有用户家目录下的关联文件被移动到 `~/.Trash`，可在废纸篓里恢复。
2. **系统级文件 = 鉴权 + 移除**：当列表里包含 `/Library/*`、`/Library/LaunchDaemons/*`、`/Library/PrivilegedHelperTools/*` 等系统级路径时，会触发 macOS 鉴权对话框（"AppCleaner is trying to make changes / 想要进行更改"），输入管理员密码后才执行。这部分是否走 Trash、还是直接 unlink，社区记录不一致；FileHorse 与 itea30.jp 描述等价于"提权后立即移除"。
3. **二次确认**：
 - 对系统保护 App（Finder、Safari、System Settings 等）勾选时，列表会高亮警示并需要二次确认；普通 App 不再弹额外确认框，所见即所删。
 - SmartDelete 路径下的弹窗本身就是一次显式确认（"是否清理残留？"），用户必须点 Remove 才会触发删除。
4. **失败处理**：被锁定文件 / SIP 保护文件保留在结果中并标红，删除继续推进其余项，不会整体回滚。
5. **不提供"绕过 Trash 直删"**（与 OmniDiskSweeper 的 Destroy 不同）——这是 AppCleaner 比较保守的安全选择。
- **来源**：itea30.jp 教程截图显示"AppCleaner が変更を加えようとしています"鉴权对话框；FileHorse 操作步骤："grant permissions … allow AppCleaner to scan and delete files effectively"。

---

## 3. SmartDelete 监听机制 - 深度解析 [设][卸载]

> SmartDelete 是 AppCleaner 区别于"纯拖拽卸载器"的关键卖点，常被推荐为"装机必开"的功能。

| 维度 | 行为 |
|---|---|
| 触发开关 | `AppCleaner > Preferences > SmartDelete > ON` |
| 实现形态 | 后台轻量 daemon / agent，开关 ON 时常驻；OFF 后立即退出（无残留） |
| 监听对象 | **`~/.Trash` 目录的写入事件 + .app 拖移到 Trash 的系统通知**（综合 itea30.jp、fileminutes.com、drbuho.com 描述，等价于 FSEvents/NSWorkspace 监听） |
| 触发条件 | 任何 `.app` Bundle 被移入 `~/.Trash`（拖拽 / Cmd / 右键"移到废纸篓"均生效） |
| 响应动作 | 弹出 AppCleaner 的"Found related files"对话框，自动以该 .app 的 bundleID 反扫所有关联路径，并展示勾选清单 |
| 用户决策 | 点 Remove -> 关联文件随之移入 Trash；点 Cancel -> 仅 .app 主体留在 Trash，关联文件保留 |
| 与主窗口关系 | **无需事先打开 AppCleaner 主窗口**，弹窗由 daemon 直接拉起 |
| 权限要求 | 首次开启需授予 **Full Disk Access**（系统设置 > 隐私与安全性 > 完全磁盘访问），否则无法读取 `/Library/*` 与其他用户域 |
| 性能开销 | 体积仅几 MB，社区普遍反馈 CPU/内存占用可忽略；不主动扫描磁盘，仅事件驱动 |
| 关闭后 | daemon 退出；已经在 Trash 中的 App 不再追问；倒回手动模式 |
| 局限 | 只对"用户主动把 App 拖到 Trash"生效；命令行 `rm -rf /Applications/Foo.app` 不会触发；macOS 系统更新的内置 App 替换也不会触发 |

**典型工作流**：
1. 用户从 Finder 选中 `Foo.app`，Cmd 移到 Trash。
2. SmartDelete daemon 监听到 Trash 写入事件，识别到 .app Bundle。
3. 立即弹出弹窗，列出 `~/Library/Preferences/com.foo.plist`、`~/Library/Application Support/Foo/`、`~/Library/Caches/com.foo/` 等。
4. 用户点 Remove -> 关联文件一并进 Trash -> 倒废纸篓时一次性彻底清理。

---

## 4. LeftOver Finder（残留扫描）- 深度解析 [卸载][图]

> AppCleaner 没有一个独立菜单叫 "Leftover Finder"，但官方与第三方测评一致使用此称谓描述其"对历史卸载残留的处置能力"。它由两条机制叠加实现：

### 4.1 List Mode "Other" 类目
- 切到 List Mode -> 顶部页签 "Other"。
- 扫描范围：
 - `~/Library/Widgets`、`~/Library/Internet Plug-Ins`、`~/Library/PreferencePanes`
 - `~/Library/Screen Savers`、`~/Library/Services`
 - `/Library/*` 下的对应同类目录
 - 旧版 Dashboard `*.wdgt`
- 列表条目本身就是"非主 App"的可清理对象：插件、Widget、屏保、PrefPane 等；其中**已无对应宿主 App 的项**就是典型残留。
- 处置：勾选 -> Remove，与卸载流程同。

### 4.2 Bundle ID 反向匹配
- 当用户在 List Mode 选中某 App 进行扫描时，AppCleaner 会按 `bundleID + appName` 在所有 Library 子目录里做**前缀 / 包含**匹配。
- 这套规则在"目标 App 仍存在"时是"卸载"；当目标 App 已经消失但相关文件还在时，社区测试显示它**只对"曾用 List 看见过的 App"有记忆**——并不会主动遍历整盘扫描所有孤立 plist。
- 因此**"扫描整机所有残留"严格意义上 AppCleaner 并不提供**；macwin.io 与 drbuho.com 都明确指出这点："Doesn't support batch uninstall"、"No real-time monitoring of leftover files when you delete apps manually"。

### 4.3 残留扫描的真实边界
- [Y] 能识别：旧 Widget / Plugin / PrefPane / Screen Saver、SmartDelete 监听到的 .app 卸载残留、List 中显式选中的目标 App 关联文件。
- [N] 不能识别：用 `rm` 删除过、备份恢复留下的孤儿目录、只剩 LaunchDaemon 没主体的"半身鬼"。
- 因此社区常见组合拳：**OmniDiskSweeper 找大块孤儿目录 + AppCleaner 处理已知 App 卸载链路**，互补使用（见 ezone.co.uk 联合教程）。

---

## 5. 信息来源

1. AppCleaner 官方主页（功能与下载权威说明）：https://freemacsoft.net/appcleaner/
2. FileHorse - AppCleaner 3.6.8 完整功能 + 三种卸载方法（Drag / List / SmartDelete）：https://mac.filehorse.com/download-appcleaner/change-log/
3. macwin.io - AppCleaner 评测（SmartDelete + Widgets/Plugins Removal + 限制）：https://macwin.io/appcleaner/
4. drbuho.com - 2026 实测评测（SmartDelete 工作流、缺点列表）：https://www.drbuho.com/review/appcleaner-review
5. itea30.jp - 日文教程（SmartDelete 设置截图 + 鉴权对话框）：https://itea30.jp/appcleaner/
6. fileminutes.com - macOS 卸载方法大全（Library 全路径清单 + SmartDelete 后台行为）：https://www.fileminutes.com/blog/how-to-uninstall-apps-on-macos/
7. ezone.co.uk - OmniDiskSweeper + AppCleaner 联合实战（残留覆盖边界）：https://www.ezone.co.uk/blog/optimise-mac-cleanup-using-omnidisksweeper-and-appcleaner.html
8. descargatic.com - AppCleaner 全功能清单（LaunchAgents/Daemons/Widgets/Plist 处置）：https://descargatic.com/appcleaner/
