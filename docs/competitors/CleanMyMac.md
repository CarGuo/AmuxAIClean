# CleanMyMac X 完整功能菜单（v2024-2026）

> 说明：本文同时覆盖 **CleanMyMac X（4.x，最高 4.15.x，停在 macOS Tahoe 26）** 与 **新版 CleanMyMac（5.x，2024 重构版，截至 2026-04 / 5.5.x）** 两套菜单结构。MacPaw 在 2024 把模块重排成"任务导向"，并把若干 X 时代的子模块合并/拆分；为方便对齐 GSYCleanMac，两版主菜单都列出。
>
> 标签说明：
> - [Y] 核心扫描清理（占空间 / 删文件类）
> - [周边] 周边（登录项 / 维护脚本 / 监控 / 加速 / 元信息类，不直接删用户文件）
> - [图] 可视化（气泡图 / 树状下钻 / 大小分布）
> - [目录] 任意路径（用户可自选目录 / 卷 / 外置盘）
> - [隐私] 隐私安全（恶意软件 / 隐私痕迹 / 权限）
>
> 一个功能可同时带多个标签，例如 Space Lens = [Y] + [图] + [目录]。

---

## 一、CleanMyMac X（4.x，老版菜单，2018-2026 仍维护）

- # CleanMyMac X
 - ## Smart Scan（聚合入口）
 - Smart Scan > Cleanup（合并 System Junk + Mail Attachments + Trash Bins） — [Y]
 - Smart Scan > Protection（合并 Malware Removal） — [隐私]
 - Smart Scan > Speed（合并 Maintenance + Optimization） — [周边]
 - Smart Scan > Large & Old Files（仅 App Store 版替换 Speed） — [Y] [目录]
 - ## Cleanup（清理）
 - ### System Junk（系统垃圾）
 - Cleanup > System Junk > User Cache Files — [Y]
 - Cleanup > System Junk > System Cache Files — [Y]
 - Cleanup > System Junk > User Log Files — [Y]
 - Cleanup > System Junk > System Log Files — [Y]
 - Cleanup > System Junk > Language Files — [Y]
 - Cleanup > System Junk > Universal Binaries — [Y]
 - Cleanup > System Junk > Broken Login Items — [Y]
 - Cleanup > System Junk > Broken Preferences — [Y]
 - Cleanup > System Junk > Document Versions — [Y]
 - Cleanup > System Junk > iOS Device Backups（iPhone/iPad/Apple Watch） — [Y]
 - Cleanup > System Junk > Old Updates — [Y]
 - Cleanup > System Junk > Unused Disk Images（DMG） — [Y]
 - Cleanup > System Junk > Deleted Users（残留用户目录） — [Y]
 - Cleanup > System Junk > Xcode Junk（DerivedData / Archives / Module Cache / iOS Simulators / Documentation Cache / Device Support） — [Y]
 - Cleanup > System Junk > macOS Localizations（仅 ≤10.11） — [Y]
 - ### Mail Attachments（邮件附件）
 - Cleanup > Mail Attachments > Local Mail Downloads — [Y]
 - Cleanup > Mail Attachments > Inline Attachments / 缓存附件 — [Y]
 - ### Photo Junk（照片库垃圾，非 App Store）
 - Cleanup > Photo Junk > Photos Cache — [Y]
 - Cleanup > Photo Junk > Faces 数据 — [Y]
 - Cleanup > Photo Junk > 已下载的 iCloud 本地拷贝 — [Y]
 - ### iTunes / Apple Music Junk
 - Cleanup > iTunes Junk > Old iOS Software Updates(.ipsw) — [Y]
 - Cleanup > iTunes Junk > Broken Downloads — [Y]
 - Cleanup > iTunes Junk > Outdated Device Backups — [Y]
 - Cleanup > iTunes Junk > Local Copies of streamed media — [Y]
 - ### Trash Bins（垃圾桶）
 - Cleanup > Trash Bins > Startup Drive Trash — [Y]
 - Cleanup > Trash Bins > External Drive Trash — [Y]
 - Cleanup > Trash Bins > Local Mail Trash — [Y]
 - Cleanup > Trash Bins > Photos Library Trash（非 App Store） — [Y]
 - Cleanup > Trash Bins > Photos Library Duplicates（Gemini 2 创建的相册，非 App Store） — [Y]
 - ## Protection（保护）
 - Protection > Malware Removal（Moonlock Engine：病毒/广告软件/键盘记录器/间谍软件/PUA） — [隐私]
 - Protection > Malware Removal > Background Threat Monitoring（实时监控） — [隐私]
 - Protection > Malware Removal > Suspicious Files / Quarantine — [隐私]
 - Protection > Privacy > Application Permissions（相机/麦克风/屏幕录制/文件夹访问） — [隐私]
 - Protection > Privacy > Recent Items List — [隐私]
 - Protection > Privacy > Wi-Fi Networks（已加入网络记录，非 App Store） — [隐私]
 - Protection > Privacy > Browser: Safari（Browsing History / Cookies / Downloads History / Autofill / HTML5 Storage / Saved Passwords / Tabs from Last Session） — [隐私]
 - Protection > Privacy > Browser: Google Chrome（同上 + Search Queries） — [隐私]
 - Protection > Privacy > Browser: Mozilla Firefox（同上） — [隐私]
 - Protection > Privacy > Chat History（如 Skype/Messages） — [隐私]
 - ## Speed（速度）
 - ### Optimization（优化）
 - Speed > Optimization > Login Items（开机自启项管理） — [周边]
 - Speed > Optimization > Launch Agents（启动代理 plist） — [周边]
 - Speed > Optimization > Hung Applications（非 App Store） — [周边]
 - Speed > Optimization > Heavy Consumers（高 CPU 占用应用，非 App Store） — [周边]
 - ### Maintenance（维护脚本，非 App Store）
 - Speed > Maintenance > Free Up RAM（仅 Intel） — [周边]
 - Speed > Maintenance > Free Up Purgeable Space — [周边]
 - Speed > Maintenance > Run Maintenance Scripts（daily/weekly/monthly periodic） — [周边]
 - Speed > Maintenance > Reindex Spotlight — [周边]
 - Speed > Maintenance > Speed Up Mail — [周边]
 - Speed > Maintenance > Flush DNS Cache — [周边]
 - Speed > Maintenance > Repair Disk Permissions — [周边]
 - Speed > Maintenance > Thin Out Time Machine Snapshots — [周边]
 - ## Applications（应用程序）
 - Applications > Uninstaller（应用 + 残留同时移除） — [Y]
 - Applications > Uninstaller > Reset（应用重置到初始状态） — [周边]
 - Applications > Uninstaller > Leftovers（已被手动删除应用的残留） — [Y]
 - Applications > Uninstaller > Sort by last open date — [周边]
 - Applications > Uninstaller > Suspicious apps 标签 — [隐私]
 - Applications > Updater（App Store / Sparkle / Custom 应用更新） — [周边]
 - Applications > Extensions > Spotlight Plugins — [周边]
 - Applications > Extensions > Login Items（重复入口） — [周边]
 - Applications > Extensions > Internet Plugins — [周边]
 - Applications > Extensions > Preference Panes — [周边]
 - Applications > Extensions > Quick Look Plugins — [周边]
 - Applications > Extensions > Screen Savers — [周边]
 - Applications > Extensions > Web Browser Extensions（Safari/Chrome/Firefox/Opera） — [周边]
 - Applications > Extensions > Dictionaries — [周边]
 - Applications > Extensions > Mail Plugins — [周边]
 - ## Files（文件）
 - Files > Space Lens（气泡图可视化，可选任意卷/外置盘/文件夹，支持双击下钻 & 箭头返回上层） — [Y] [图] [目录]
 - Files > Space Lens > Cloud-stored 文件自动忽略（4.15.4+） — [周边]
 - Files > Space Lens > Purgeable Space（非 App Store） — [周边]
 - Files > Large & Old Files（>50MB，按 size/type/date 排序，可选任意目录/外置盘） — [Y] [目录]
 - Files > Large & Old Files > Remove Immediately — [Y]
 - Files > Large & Old Files > Remove Securely（不可恢复擦除） — [Y] [隐私]
 - Files > Large & Old Files > Move to Trash — [Y]
 - Files > Large & Old Files > Move to Folder（搬到任意目录） — [Y] [目录]
 - Files > Shredder（拖入任意文件 -> 安全粉碎，非 App Store） — [Y] [隐私]
 - ## CleanMyMac X Menu（菜单栏 App）
 - Menu > Protection（实时威胁监控） — [隐私]
 - Menu > Memory（RAM 实时占用 + Free Up RAM 按钮） — [周边]
 - Menu > CPU（温度 / 负载 / Uptime） — [周边]
 - Menu > Battery（健康度 / 温度 / 循环次数 / Bluetooth 设备低电量提醒） — [周边]
 - Menu > Network（实时上下行速度 / Wi-Fi 信号） — [周边]
 - Menu > Storage（磁盘剩余空间 / Purgeable） — [周边]
 - Menu > Connected Devices（鼠标/键盘/耳机/Trackpad 电量） — [周边]
 - Menu > External Drives（外置盘容量 + 一键扫描入口） — [周边] [目录]
 - Menu > Trash Monitor（垃圾桶大小提醒） — [Y]
 - Menu > Maintenance（快捷维护入口） — [周边]
 - ## Assistant（侧边推荐栏）
 - Assistant > Recommendations（基于使用习惯的清理 / 维护建议） — [周边]
 - Assistant > Cleanup Stats（已清理空间历史） — [周边]

---

## 二、CleanMyMac（5.x，2024 重构版，截至 2026 / macOS Tahoe ready）

- # CleanMyMac (new)
 - ## Smart Care（聚合入口，前身是 Smart Scan）
 - Smart Care > Cleanup（System Junk + Mail Attachments + Trash Bins） — [Y]
 - Smart Care > Protection（Malware Removal） — [隐私]
 - Smart Care > Performance（Maintenance Tasks + Login Items + Background Items） — [周边]
 - Smart Care > Applications（Updater：App Store / Custom / Sparkle） — [周边]
 - Smart Care > My Clutter（Duplicates + Similar Photos + Large & Old Files） — [Y]
 - ## Cleanup（清理）
 - Cleanup > System Junk（同 X 版子项，参见上文） — [Y]
 - Cleanup > Mail Attachments — [Y]
 - Cleanup > Trash Bins > Startup Drive Trash — [Y]
 - Cleanup > Trash Bins > External Drive Trash — [Y]
 - Cleanup > Trash Bins > Local Mail Trash — [Y]
 - ## Protection（保护，整合了 X 版的 Privacy）
 - Protection > Malware Finder（Moonlock Engine） — [隐私]
 - Protection > Privacy Items > Browsing History — [隐私]
 - Protection > Privacy Items > Cookies — [隐私]
 - Protection > Privacy Items > Saved Passwords / Autofill — [隐私]
 - Protection > Privacy Items > Recent Items — [隐私]
 - Protection > Privacy Items > Application Permissions — [隐私]
 - ## Performance（性能，整合 X 版 Optimization + Maintenance）
 - Performance > Login Items — [周边]
 - Performance > Background Items（macOS 13+ 新分类，对应 SMAppService） — [周边]
 - Performance > Maintenance Tasks > Flush DNS Cache — [周边]
 - Performance > Maintenance Tasks > Free Up Purgeable Space — [周边]
 - Performance > Maintenance Tasks > Reindex Spotlight — [周边]
 - Performance > Maintenance Tasks > Speed Up Mail — [周边]
 - Performance > Maintenance Tasks > Repair Disk Permissions — [周边]
 - Performance > Maintenance Tasks > Run Periodic Scripts（仅旧 macOS） — [周边]
 - Performance > Time Machine Snapshot（清本地快照） — [周边]
 - Performance > Free Up RAM（仅 Intel；Apple Silicon 移到 Menu） — [周边]
 - ## Applications（应用程序）
 - Applications > Uninstaller（应用 + 残留） — [Y]
 - Applications > App Leftovers（独立工具：扫已删应用残留） — [Y]
 - Applications > App Updater（App Store / Custom / Sparkle Updates） — [周边]
 - ## My Clutter（我的杂乱，替代 X 版 Large & Old Files 并扩展）
 - My Clutter > Large and Old Files（>50MB，可选任意目录 / 外置盘） — [Y] [目录]
 - My Clutter > Duplicate Finder（重复文件） — [Y]
 - My Clutter > Similar Images（相似图片） — [Y]
 - My Clutter > Downloads（Downloads 文件夹清理） — [Y]
 - ## Space Lens（独立顶级菜单 — 可视化）
 - Space Lens > Scan 任意卷 / 外置盘 / 任意文件夹 — [Y] [图] [目录]
 - Space Lens > Bubble Map（气泡图，按大小） — [图]
 - Space Lens > List View（双击下钻 / 箭头返回上层） — [图]
 - Space Lens > Quick Look 预览 — [周边]
 - Space Lens > Reveal in Finder — [周边]
 - Space Lens > Auto-ignore Cloud Files — [周边]
 - Space Lens > 隐藏文件可见性（隐式：扫描根目录或 Home 时显示 dotfile，可选删除） — [Y] [目录]
 - ## Cloud Cleanup（5.x 新增）
 - Cloud Cleanup > 大文件（云端） — [Y]
 - Cloud Cleanup > 本地冗余拷贝（与云端重复的本地副本） — [Y]
 - Cloud Cleanup > iCloud Drive 支持 — [Y]
 - ## My Tools（5.x 新增 — 工具箱聚合入口）
 - My Tools > Favorites（用户星标） — [周边]
 - My Tools > App Leftovers — [Y]
 - My Tools > App Updater — [周边]
 - My Tools > Application Permissions — [隐私]
 - My Tools > Background Items — [周边]
 - My Tools > Downloads — [Y]
 - My Tools > Duplicate Finder — [Y]
 - My Tools > Large and Old Files — [Y] [目录]
 - My Tools > Login Items — [周边]
 - My Tools > Mail Attachments — [Y]
 - My Tools > Maintenance Tasks — [周边]
 - My Tools > Malware Finder — [隐私]
 - My Tools > Privacy Items — [隐私]
 - My Tools > Similar Images — [Y]
 - My Tools > System Junk — [Y]
 - My Tools > Time Machine Snapshot — [周边]
 - My Tools > Trash Bins — [Y]
 - My Tools > Uninstaller — [Y]
 - ## My Activity（5.x 新增）
 - My Activity > Cleanup History（清理历史记录 / 已恢复空间） — [周边]
 - My Activity > Mac Health（健康评分 + 建议） — [周边]
 - ## Menu（菜单栏 App）
 - Menu > Mac Health 概览 — [周边]
 - Menu > Memory / RAM Real-time — [周边]
 - Menu > CPU — [周边]
 - Menu > Battery — [周边]
 - Menu > Network — [周边]
 - Menu > Storage — [周边]
 - Menu > Connected Devices — [周边]
 - Menu > External Drives — [周边] [目录]
 - Menu > Smart Care 一键入口 — [Y]

---

## 三、4 个特别留意点的具体出处（GSYCleanMac 主战场对照）

| 留意点 | CleanMyMac 中的功能名 | 所在菜单 | 出处 URL |
|---|---|---|---|
| **任意目录扫描** | **Space Lens** + **Large & Old Files** 的"drive selector / 选择目录"控件 | X 版：`Files > Space Lens` & `Files > Large & Old Files`；新版：`Space Lens` 顶级菜单 + `My Clutter > Large and Old Files` | https://macpaw.com/support/cleanmymac-x/knowledgebase/space-lens（"Specify drive or directory for scanning... To scan another volume or a particular folder, click the drive selector"） + https://macpaw.com/support/cleanmymac-x/knowledgebase/large-and-old（"Choose a location: ... a drive, an external device, or a directory you want to tidy up"） |
| **大文件查找** | **Large & Old Files**（≥ 50MB 阈值） | X 版：`Files > Large & Old Files`；新版：`My Clutter > Large and Old Files` | https://macpaw.com/support/cleanmymac-x/knowledgebase/large-and-old（"filters out files occupying at least 50MB of disk space"） + https://macpaw.com/how-to/find-large-files-mac |
| **多层下钻**（drill-down 进子目录） | **Space Lens** 的 Bubble + List 双视图："double-clicks or arrows (>)" 进入，"arrows (< >)" 返回 | X 版：`Files > Space Lens`；新版：`Space Lens` 顶级 | https://macpaw.com/support/cleanmymac-x/knowledgebase/space-lens（"Look through the list and use double-clicks or arrows (>), or click the bubble... To go back, click outside the bubbles in the lens or use the arrows (< >) above the list"） |
| **隐藏文件 toggle** | CleanMyMac **没有显式的 "show hidden files" 开关**；它的处理方式是：**Space Lens 默认会扫描并展示以 `.` 开头的隐藏文件 / 目录**（被算在父目录大小内，可在列表中直接看到），官方文档把它当成"用 Space Lens 可视化隐藏文件"的方案来宣传。Finder/Terminal 才有显示开关。 | `Space Lens`（间接） | https://macpaw.com/ja/how-to/show-hidden-files-on-mac（"スマートな「スペースレンズ」機能を搭載しており... 目に見えない隠しファイルを確認するだけの場合においても、同じツールの使用が可能です"） + 同一系列英文版 https://macpaw.com/how-to/show-hidden-files-on-mac |

> 关键结论（写给 GSYCleanMac 设计参考）：
> - CleanMyMac **把"任意目录扫描 + 大文件 + 多层下钻"三件事捏在 Space Lens 里**，并用气泡图当卖点。Large & Old Files 是同一引擎的"列表化、加阈值（≥50MB）+ 排序"快捷视图。
> - **CleanMyMac 实际上没有给用户一个"显示隐藏文件"开关** —— 它默认就把隐藏项算进去并显示在列表里，把"Finder 里看不到的东西也能在我这看到"包装成 Space Lens 的差异化卖点。这是 GSYCleanMac BulkScanner 可以直接对齐 / 反超的点（GSYCleanMac 已经有显式 `showHiddenFiles` toggle）。
> - 新版 CleanMyMac **拆掉了 X 版的 Maintenance 大部分 RAM/Repair 项**（macOS 沙盒收紧），重心更倾向"扫描清理 + 应用管理 + 可视化"，与 GSYCleanMac 的功能边界高度重合。

---

## 四、信息来源（实际访问过的 URL）

1. https://macpaw.com/cleanmymac — 官方新版产品页（含 Smart Care 五大模块说明）
2. https://macpaw.com/support/cleanmymac-x/knowledgebase — CleanMyMac X 知识库总目录（左侧栏即是完整模块清单）
3. https://macpaw.com/support/cleanmymac/knowledgebase/missing-features — 新版 CleanMyMac 功能矩阵（按 MacPaw Store / Setapp / App Store 三版列出每个子项），覆盖 Smart Care、Cleanup、Protection、Performance、Applications、My Clutter、Space Lens、Cloud Cleanup、My Tools、My Activity、Menu
4. https://macpaw.com/support/cleanmymac/knowledgebase/my-tools — 新版 My Tools 工具清单表
5. https://macpaw.com/support/cleanmymac-x/knowledgebase/system-junk — System Junk 全部 15+ 子类
6. https://macpaw.com/support/cleanmymac-x/knowledgebase/optimization — Optimization（Login Items / Launch Agents / Hung Apps / Heavy Consumers）
7. https://macpaw.com/support/cleanmymac-x/knowledgebase/privacy — Privacy 全部子项（含浏览器、Wi-Fi、权限）
8. https://macpaw.com/support/cleanmymac-x/knowledgebase/space-lens — Space Lens 工作机制（任意目录、双击下钻、气泡图）
9. https://macpaw.com/support/cleanmymac-x/knowledgebase/large-and-old — Large & Old Files（任意目录、≥50MB、四种移除方式）
10. https://macpaw.com/support/cleanmymac-x/knowledgebase/missing-features — App Store 版被砍的功能清单（反向印证完整功能边界）
11. https://macpaw.com/cleanmymac-x/whats-new — CleanMyMac X 4.13 / 4.14 / 4.15 更新记录（Moonlock Engine、Connected Devices、External Drives、Trash Monitor）
12. https://macpaw.com/how-to/find-large-files-mac — 官方"如何找大文件"教程，提到 My Clutter / Large & Old Files / Space Lens 三件套
13. https://macpaw.com/ja/how-to/show-hidden-files-on-mac — 官方"如何显示隐藏文件"教程（关键证据：CleanMyMac 用 Space Lens 处理隐藏文件，无独立 toggle）
14. https://cleanmymac.com/blog/cleanmymac-vs-cleanmymac-x — MacPaw 自家博客对 X -> 5.x 模块迁移做的官方对照
15. https://apps.apple.com/us/app/cleanmymac-x/id1339170533 — App Store 页面（30+ tools 概要）
16. https://grokipedia.com/page/cleanmymac — 第三方综述，交叉验证 Smart Care 流程与模块演进
