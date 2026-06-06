# 隐私协议 / Privacy Policy

最后更新：2026-06-06
适用版本：GSYCleanMac v1.5.6+

## 一句话承诺

**GSYCleanMac 不收集、不上传、不分析任何用户数据，没有任何形式的遥测（telemetry）、行为埋点、崩溃自动上报或匿名统计。**

## 1. 我们不做什么

- ❌ 不上传文件列表、文件路径、文件内容、扫描结果到任何服务器
- ❌ 不收集设备 UUID / MAC / IMEI / 序列号 / 硬件指纹
- ❌ 不收集 macOS 版本、机型、CPU 架构、内存、磁盘容量
- ❌ 不收集用户行为（点击、停留时长、扫描频率、删除数量）
- ❌ 不嵌入 Google Analytics / Firebase / Sentry / Bugsnag / Crashlytics / 友盟 / 神策 等任何第三方 SDK
- ❌ 不在启动、运行、退出时建立除「检查更新」外的任何对外网络连接

## 2. 我们做什么（仅一项主动联网行为）

**唯一对外网络请求**：

| 行为 | 检查更新 |
|---|---|
| 触发时机 | App 启动时一次，或用户菜单点击「检查更新…」 |
| 目标地址 | `https://api.github.com/repos/<owner>/<repo>/releases/latest` |
| 携带数据 | 仅标准 HTTP header（含 macOS 自带的 `User-Agent`），无任何 query / body |
| 是否可关闭 | 是。菜单 → 「设置」 → 关闭「启动时自动检查更新」即可永久禁用 |
| 第三方接收方 | GitHub（受 [GitHub Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-privacy-statement) 约束） |
| 代码位置 | [UpdateChecker.swift](Packages/AppUI/Sources/AppUI/Updater/UpdateChecker.swift) |

> 即使该请求成功，App 也不会把任何本地信息回传给 GitHub。GitHub 只会按其惯例记录访问 IP / User-Agent（与你在浏览器直接访问 github.com 完全相同）。

## 3. 本地数据存储

GSYCleanMac 完全本地运行，以下数据**只存在你本机**，从不离开你的设备：

| 类型 | 路径 | 用途 | 保留时长 |
|---|---|---|---|
| 启发式扫描缓存 | `~/Library/Application Support/GSYCleanMac/HeuristicScanStore.json` | 复用上次扫描结果，加速二次扫描 | 直到你手动清除 / 卸载 |
| 撤销历史 | `~/Library/Application Support/GSYCleanMac/UndoHistory.json` | 支持「最近删除」恢复 | 默认保留最近 200 条 |
| 偏好设置 | `~/Library/Preferences/com.guoshuyu.cleanmac.plist` | 主题、语言、扫描偏好 | 直到卸载 |
| 运行日志 | `~/Library/Logs/GSYCleanMac/*.log` | 调试排错 | 自动滚动保留 ≤ 7 天 |

你可在「关于」面板或终端执行 `rm -rf ~/Library/Application\ Support/GSYCleanMac ~/Library/Logs/GSYCleanMac` 随时彻底清除。

## 4. 权限说明

| 权限 | 用途 | 拒绝后果 |
|---|---|---|
| 完全磁盘访问（FDA） | 扫描 `~/Library/Mail`、其他用户目录、iCloud 占位文件 | 仅扫描覆盖你 Home 公开目录，结果不完整但 App 仍可用 |
| 用户选定文件夹（NSOpenPanel） | 自定义扫描位置 | 无法添加自定义扫描目录 |
| 网络出站（仅 api.github.com） | 检查更新 | 无法收到新版本提示，需手动到 GitHub Releases 查看 |

GSYCleanMac **不请求**：通讯录、日历、相机、麦克风、位置、提醒事项、照片、辅助功能（Accessibility）、屏幕录制、自动化（AppleScript 控制其他 App）。

## 5. 源代码与可审计性

本项目 100% 开源（MIT License），所有联网代码可在 [GitHub 仓库](https://github.com/) 公开审计。你可以：

- 直接搜索 `URLSession` / `dataTask` / `URLRequest` 等关键字验证联网点
- 在防火墙工具（如 Little Snitch / LuLu）中观察实际网络行为
- Fork 后自行编译，得到字节级可复现的二进制（universal binary）

## 6. 第三方依赖

GSYCleanMac 只链接：

- Apple 系统框架（SwiftUI / Foundation / AppKit / Combine / os.log）
- 0 个第三方 Swift Package
- 0 个 ObjC / C 静态库

## 7. 儿童隐私

GSYCleanMac 不面向 13 岁以下儿童，不区分用户年龄，不收集任何可识别个人身份的信息（PII）。

## 8. 变更

本协议如有变更，将在新版本 CHANGELOG.md「Security / Privacy」段落中显式说明。重大变更（例如引入任何形式的遥测）将**默认关闭**并提供醒目的 opt-in 提示。

## 9. 联系

如对本协议有任何疑问，请到 GitHub Issues 提出。

---

**English Summary**

GSYCleanMac collects **zero** telemetry. The only outbound network call is a one-shot GitHub Releases API request for update checking (can be disabled in settings). No analytics SDK is bundled. All scan data stays on your Mac. Source code is MIT-licensed and fully auditable.
