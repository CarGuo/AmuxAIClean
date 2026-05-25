# Pearcleaner 完整功能菜单（最新版本 v5.4.3 / 2025-11-26）

> 版本：v5.4.3（README 显示 Status: On Hold）
> 调研基于：上游仓库 README、最近 10+ 次 Releases notes、Wiki（Deep Link Guide）以及源码 `Pearcleaner/Views/*` + `PearcleanerSentinel/*`
> 图例：[卸载] 卸载 - [清理] 清理 - [设] 设置 - [搜] 扫描 - [工具] 工具 - [特权] 表示需要 Privileged Helper Tool 提权

---

## 顶部全局菜单（Toolbar Page Selector）

Pearcleaner 在 macOS 26 风格的工具栏左上方使用一个 **Page Selector Menu**（不是经典 SwiftUI Sidebar），所有"侧边栏式"主功能都在此切换。源码：`Pearcleaner/Views/MainWindow.swift` 中 `CurrentPage.availablePages` 枚举。

- # Pearcleaner 完整功能菜单（最新版本）
 - ## 主页面切换菜单（Toolbar > Page Selector）
 - ### [卸载] Applications（已安装应用列表）
 - 左侧 `AppSearchView` 列表（System / User 两段折叠 + 搜索框）
 - 列表/网格切换；Web App、iOS Wrapped App 角标
 - 点击应用 -> 进入 `FilesView`（详情）
 - [搜] 自动扫描该 App 的相关残留文件（Application Support / Caches / Preferences / LaunchAgents / Logs / Saved State 等）
 - 多层下钻：详情视图本身就是单 App 的"二级页面"，文件按 **Category 分类视图** 或 **Simple List** 切换（v5.4.2 新增 toolbar 切换按钮）
 - [卸载][特权] 一键 Uninstall（系统级路径写操作走 Helper Tool）
 - [卸载][特权] Move only the .app（不删残留）
 - [清理] Prune unused translations（按 Settings 偏好语言保留）
 - [工具] Lipo（瘦身：单 App 入口，亦在 Lipo 主页面）
 - Export bundle / 导出文件清单
 - "Adopt into Homebrew"（v5.4.2 新增，从 sidebar > options 入口）
 - 拖放 .app 到主窗口直接进入卸载流程
 - 自卸载（Pearcleaner 卸载自身）
 - ### [清理] Orphans（孤儿文件 / Zombie Files）
 - 源码：`Pearcleaner/Views/ZombieView/ZombieView.swift`
 - [搜] 全盘扫描"已卸载应用残留"（`~/Library`、`/Library` 等系统路径）
 - 显示总大小、已选数量
 - **侧边栏（Info Sidebar）展示已排除路径**，并标注"是否被某个 App 关联"（`ZombieSidebarView.swift`）
 - 支持 List / Category 两种视图（v5.4.2 toolbar 切换）
 - [卸载][特权] 批量删除选中条目
 - 文件可恢复（v5.4.0 后所有删除走 UndoManager -> 移到 Trash）
 - CLI: `pear list-orphaned`
 - ### [清理] Development（开发者残留专区）
 - 源码：`Pearcleaner/Views/DevelopmentView.swift`（约 76KB，规模最大的工具页之一）
 - [搜] 扫描多种开发环境产物：
 - Xcode（DerivedData / Archives / DeviceSupport / iOS DeviceLogs / CoreSimulator / SwiftPM / Toolchains）
 - Homebrew Cache / Cellar 旧版本
 - npm / yarn / pnpm cache、node_modules 全局
 - pip 缓存 + **pip packages 视图**（v5.3.6 新增）
 - Gradle / Maven / Cocoapods cache
 - Go modcache、Cargo registry、Bun cache（v5.x 加入）
 - 每个环境单独一行，显示尺寸；勾选后 [卸载] 删除
 - Deep Link：`pear://checkDevEnv?name=xcode`
 - ### [工具] Lipo（通用二进制瘦身）
 - 源码：`Pearcleaner/Views/LipoView/LipoView.swift` + `Logic/Lipo.swift`
 - [搜] 列出所有 Universal Binary 应用，显示当前架构（x86_64 + arm64）
 - [工具][特权] 选中后剥离非本机架构（自实现，**不依赖 Xcode 的 lipo CLI**）
 - 支持 Bundle thinning（v5.x，PearcleanerHelper 实现）和按 App 单独计算节省空间
 - 操作系统路径写入需 Helper Tool 提权
 - ### [搜] File Search（任意目录文件搜索 / 高级搜索）
 - 源码：`Pearcleaner/Views/FileSearchView.swift`（约 49KB） + `Logic/FileSearch/*`
 - **Volume 选择器**：Startup Disk / 已挂载卷 / **Choose Folder...（选择任意目录）**
 - SearchType：Files Only / Folders Only / Files & Folders
 - 选项 Toggle：
 - Include subfolders（**递归子目录**，多层下钻）
 - Exclude system folders
 - **Include hidden files（显式开关，默认关闭）**
 - Case sensitive
 - **可叠加 Filter Chips**：Name / Extension / **Size（大文件查找）** / Date / Tags / Comment
 - 结果表格：Name / Type / Size / Modified，可排序
 - 操作：Open / Rename / Delete / Bulk Delete（删除走 UndoManager）
 - 显示 Elapsed Time、结果计数
 - ### [工具] Homebrew Manager
 - 源码：`Pearcleaner/Views/Brew/*` + `Logic/Brew/*`
 - 已安装 formulae / casks 列表，按尺寸/拼音排序（v5.4.3）
 - [清理][特权] install / update / uninstall（v5.4.0 起全部走 brew CLI；sudo 凭据缓存到 Keychain）
 - **Maintenance 选项卡**：cleanup（直接读文件系统，v5.3.5 优化为瞬时）
 - Auto Update Schedule（Daily/Weekly/Monthly，LaunchAgent）
 - Bottom Console（v5.4.0+）显示 brew 输出、Stop 按钮中止
 - ### [清理] Packages (PKG Manager)
 - 源码：`Pearcleaner/Views/PackageView.swift`
 - [搜] 列出 macOS receipts（`pkgutil --pkgs` 等价）
 - [卸载][特权] forget receipt + 删除已安装文件清单（系统路径写入）
 - ### [清理] Plugins Manager
 - 源码：`Pearcleaner/Views/PluginsView.swift`
 - [搜] 扫描 Internet Plug-Ins / Audio Units / VST/VST3 / AAX / Quick Look / Spotlight Importer / Screen Savers / Print 等
 - [卸载][特权] 删除选中插件
 - ### [清理] Services / Daemons（LaunchAgents & LaunchDaemons）
 - 源码：`Pearcleaner/Views/DaemonView.swift`（约 44KB）
 - [搜] 列出所有 LaunchAgents/LaunchDaemons（user / system 范围）
 - 启用/禁用（launchctl bootout/bootstrap）
 - [卸载][特权] 删除 plist（系统级 Daemons 走 Helper Tool）
 - 显示 TCC Permissions（v5.x 加入资源 list）
 - ### Apps Updater
 - 源码：`Pearcleaner/Views/AppsUpdaterView/*`
 - 综合 Sparkle / Mac App Store / Homebrew Cask 三类更新源
 - "Update All" 按钮 + Toolbar 进度
 - Ignore / Skip 单 App 或单版本
 - MAS 更新 workaround（v5.3.8 引入 receipt import 绕过 installd 阻断）
 - 启动时后台预扫描（Settings > General 可关）
 - ## 全局工具栏右侧通知按钮
 - 更新可用（`updater.updateAvailable`）
 - 新功能公告（announcements.json）
 - [特权] 权限缺失（点击弹 `PermissionsSheetView`）
 - [设] Helper 未安装（点击直达 Settings > Helper）
 - ## 应用菜单栏（macOS 顶部 Edit 菜单）
 - **Edit > Delete History**（v5.4.0 引入）
 - 持久化最近 10 次删除记录，可恢复（前提：bundle 仍在 Trash）
 - 源码：`Pearcleaner/Views/DeleteHistoryView.swift`
 - File / 系统 Services 菜单：v5.4.2 注册 "Uninstall with Pearcleaner"（系统级 Service）
 - Help > Log file（导出日志）
 - CMD+D 调出 Debug 控制台
 - ## 命令行 / 集成
 - [工具] CLI 符号链接 `pear`（Settings > General 启用）
 - 命令：`pear list-orphaned`、`pear uninstall <app>` 等
 - 源码：`Pearcleaner/Logic/CLI.swift`
 - [工具] Finder Extension（`FinderOpen` target）：右键 .app -> "Uninstall with Pearcleaner"
 - [工具] Deep Links（`pear://`，详见 Wiki Deep-Link-Guide）
 - openPearcleaner / openSettings / openPermissions / uninstallApp / checkOrphanedFiles
 - checkDevEnv / appLipo / appsPaths(add/remove) / orphanedPaths(add/remove)
 - checkUpdates / refreshAppsList / resetSettings
 - ## Settings（CMD+,）
 - 源码：`Pearcleaner/Views/Settings/*`，共 6 个标签
 - ### [设] General（`General.swift`）
 - **Functionality 区**
 - Homebrew cleanup after uninstall（联动卸载时清理 brew 缓存）
 - Confirmation alerts（写操作二次确认）
 - Close after uninstall（One-shot 模式：从 Sentinel/Finder/DeepLink 启动后用完即关）
 - Load app updates on startup
 - [特权] Password cache timeout（Keychain 缓存 sudo 凭据时长 + 立即清除按钮）
 - **Search Sensitivity 区**：Strict / Enhanced / Deep 三档滑杆
 - Deep 档额外 toggle：Search file content（搜文本文件内容，v5.4.1+）
 - **[特权] Sentinel Monitor 区**：toggle "Detect when apps are moved to Trash"
 - ### [设] Interface（`Interface.swift`）
 - Theme 系统、Accent 自定义颜色
 - 动画、滚动条样式
 - **Startup View**（v5.3.3+ 选启动时打开哪个页面）
 - **Hide unused utility pages from global menu**（v5.4.3 新增）
 - 是否在菜单栏显示 App 图标
 - Greeting 欢迎语
 - ### [设] Folders（`Folders.swift`）
 - **"Search these folders for applications"**：可拖放/选择/锁定默认路径，添加任意 .app 扫描根（默认含 `/Applications`、`~/Applications`）
 - **"Exclude these files and folders"** 排除清单（v5.3.6 引入 Apps/Orphans 双开关 + 关键词排除）
 - 每条目可单独勾选 "Orphans" 与 "Apps" 两栏，控制对孤儿扫描或应用相关扫描生效
 - 支持关键字（敲回车保存）
 - ### [设][特权] Helper（`Helper.swift`）
 - **"Perform privileged operations seamlessly without password prompts"** Toggle
 - 启用 -> 通过 SMAppService 安装 `PearcleanerHelper`（一次性输入密码）
 - 之后所有特权操作（删除 /Library、Lipo 改写、PKG forget、System LaunchDaemons 等）通过 XPC 调用 Helper，无需再弹密码框
 - 说明文字明确：`AuthorizationExecuteWithPrivileges` 已被 Apple 弃用，仅 Helper 一种方案
 - **Helper Playground**：测试运行 whoami / systemsetup -getsleep / 自定义命令以验证 Helper 状态
 - ### [设] Update（`Update.swift`）
 - 自身更新源（GitHub Releases via Sparkle 风格）
 - 频率（Daily/Weekly/Monthly/Never）
 - 立即检查按钮
 - ### [设] About（`About.swift`）
 - 版本、Repo、License、Sponsor、Translations
 - ### [设] Permissions（独立 Sheet，非 Settings 标签）
 - 入口：Toolbar 红锁图标 / `pear://openPermissions`
 - 列表式权限自检：Full Disk Access / Accessibility / Automation 等
 - 不直接授予权限（macOS 限制），只引导跳转 System Settings 对应面板

---

## 重点详细考据

### 1. 任意目录扫描 —— [Y] **有**（颠覆原假设）
- 入口：**Toolbar > Page Selector > File Search**
- 实现：`Pearcleaner/Views/FileSearchView.swift` Volume Menu -> "Choose Folder..." 调用 `NSOpenPanel`，将 `selectedVolume` 设为任意用户选定的目录路径
- 还可选已挂载外部卷（`appState.volumeInfos`）
- 与系统级"启动磁盘"扫描共用同一个 `FileSearchEngine`（`Logic/FileSearch/*`）
- 来源：`https://raw.githubusercontent.com/alienator88/Pearcleaner/main/Pearcleaner/Views/FileSearchView.swift`

### 2. 大文件 / 大目录查找 —— [Y] **有**（通过 Filter Chip）
- 在 File Search 页面工具栏 **Add Filter** 菜单中可加入 Size 过滤器（`showSizeFilterDialog` 状态变量；`FilterType.size`）
- Size 过滤器作为 Filter Chip 叠加，可设置 ">= X MB / GB" 等阈值（FilterChip UI）
- 结果表格 `Size` 列默认可点击列头排序，等价于"按大小倒序找大文件"
- 文件夹尺寸异步计算，缓存于 `calculatedFolderSizes`（即"大目录"也能识别，但需用户手动触发或排序时计算）
- 注意：**没有独立的 "Big Files / Big Folders" 入口**，必须通过 File Search + Size Filter 组合使用
- 来源：`FileSearchView.swift` 中 `showSizeFilterDialog`、`SizeCell`、`calculatedFolderSizes` 字段

### 3. 隐藏文件处理 —— [Y] **有显式开关**
- File Search 顶部工具栏 Toggle：`Include hidden files`（默认 false）
- 源码：`@State private var includeHiddenFiles: Bool = false` + 复选框 `Toggle("Include hidden files", isOn: $includeHiddenFiles)`
- 在 Application 详情视图（FilesView）的相关文件扫描中，`.` 开头的隐藏支持目录默认会被纳入（因为属于 App 自身的 Library 残留），但全局 File Search 默认排除
- 来源：`FileSearchView.swift` 顶部状态字段定义

### 4. 多层下钻
- **Applications 主页**：左侧应用列表（一级） -> 点击进入 `FilesView`（二级，列出该 App 所有相关文件） -> 文件可按 **Category 分组视图** 或 **Simple List** 切换（v5.4.2 toolbar）
- **Orphans 页**：扁平列表 + 右侧 Info Sidebar（关联应用追溯，看到一个孤儿文件归属哪个曾经的 App）
- **File Search**：单层 Table（不分组），通过 `Include subfolders` 实现深度递归（默认 true，多层）
- 增量数据源：`AppPathsFetch.swift`（42KB）扫描 1~2 层 Library 子目录（v5.4.2 加入 "2 level depth search for Library folders"）
- **没有像 CleanMyMac 那样的 4-5 层折叠树**，整体属"一级清单 + 详情面板"两层模型
- 来源：`MainWindow.swift` `appState.currentPage / currentView` 状态机；`Pearcleaner/Views/FilesView/FilesView.swift`、Releases v5.4.2 changelog

### 5. Sentinel 是什么机制
- **独立的 launchd agent**，与主 App 解耦
 - target 目录：`PearcleanerSentinel/`
 - `main.swift` —— 进程入口
 - `FileWatcher.swift` —— FSEvents 监听实现（约 7KB）
 - `com.alienator88.PearcleanerSentinel.plist` —— LaunchAgent 配置
- 监听对象：**用户的 Trash 目录**（`~/.Trash`）。当任意 .app bundle 被丢入垃圾桶时：
 1. FSEvents 触发回调，识别新路径是否为 .app
 2. Sentinel 进程通过 `pear://uninstallApp?path=...` Deep Link 唤起主 Pearcleaner
 3. 主 App 弹出该 App 的 Files 视图，用户确认后批量清理残留
- 资源占用：README 标榜 "~2MB RAM"
- 启停：Settings > General > Sentinel Monitor toggle（`@AppStorage("settings.sentinel.enable")`）
- [警告] 不是监听 `~/Applications` 的拖入，**而是监听 Trash 的拖入**（即"用户拖 .app -> 垃圾桶"时介入）
- 来源：`PearcleanerSentinel/FileWatcher.swift`、README "Sentinel Monitor: Automatic cleanup when apps hit Trash"

---

## 权限矩阵速查

| 功能区 | 是否需要 Helper Tool [特权] | 备注 |
|---|---|---|
| Applications - 用户级 .app 卸载 | 否 | 仅 `~/Library` 写入 |
| Applications - 系统级路径残留删除 | **是** | `/Library`、`/private/var` 等 |
| Orphans 删除 | 视路径而定 | 含系统路径时需要 |
| Development 缓存清理 | 否 | 全在用户域 |
| Lipo 写回 .app 二进制 | **是** | 写 `/Applications` 系统签名应用 |
| File Search 任意目录扫描 | **读取**需 Full Disk Access；**删除**视路径 | 跨卷扫描需 FDA |
| Homebrew install/uninstall | sudo 凭据走 Keychain（不走 Helper） | brew 命令本身需要 sudo 时弹自有 askpass |
| Packages PKG forget | **是** | `pkgutil --forget` 需 root |
| Plugins 系统级删除 | **是** | `/Library/Audio/Plug-Ins` 等 |
| Services / Daemons 删除 | **是**（system 范围） | `/Library/LaunchDaemons` |
| Sentinel 自身 | LaunchAgent 自启动 | 不需 Helper |

> Helper 模型：`Pearcleaner/Logic/HelperToolManager.swift` 通过 `SMAppService.daemon(plistName:)` 注册，XPC 通信。一次密码授权后所有特权操作免密。

---

## 信息来源 URL

1. README（含 Features、Sentinel/Lipo 简介、Project Status: On Hold）
 - https://github.com/alienator88/Pearcleaner
2. Releases（最近 10+ 版本逐项 changelog，覆盖 v5.4.3 … v5.3.3）
 - https://github.com/alienator88/Pearcleaner/releases
3. Wiki - Home + Deep Link Guide（深链命名直接揭示功能页 URL Schema）
 - https://github.com/alienator88/Pearcleaner/wiki
 - https://github.com/alienator88/Pearcleaner/wiki/Deep-Link-Guide
4. 关键源码（一手凭据，胜于截图）
 - Views 目录树：https://github.com/alienator88/Pearcleaner/tree/main/Pearcleaner/Views
 - `MainWindow.swift`（主页面分发）：https://raw.githubusercontent.com/alienator88/Pearcleaner/main/Pearcleaner/Views/MainWindow.swift
 - `FileSearchView.swift`（任意目录/大文件/隐藏）：https://raw.githubusercontent.com/alienator88/Pearcleaner/main/Pearcleaner/Views/FileSearchView.swift
 - `Settings/General.swift` / `Settings/Helper.swift` / `Settings/Folders.swift`：https://github.com/alienator88/Pearcleaner/tree/main/Pearcleaner/Views/Settings
 - `ZombieView/ZombieSidebarView.swift`（孤儿扫描下钻）：https://raw.githubusercontent.com/alienator88/Pearcleaner/main/Pearcleaner/Views/ZombieView/ZombieSidebarView.swift
 - `PearcleanerSentinel/`（Sentinel 监听 Trash 实现）：https://github.com/alienator88/Pearcleaner/tree/main/PearcleanerSentinel
