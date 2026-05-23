<div align="center">

<img src="docs/assets/logo.png" width="128" alt="GSYCleanMac" />

# GSYCleanMac

**macOS 清理管家 —— 开源、可审、安全。**

[![License MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-success)](#5-分钟跑起来)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange)](https://swift.org)
[![Tests 285+ Pass](https://img.shields.io/badge/tests-285%2B%20pass-brightgreen)](#四-运维类)

[下载最新版](https://github.com/CarGuo/GSYCleanMac/releases/latest) ·
[安装指南](docs/INSTALL.md) ·
[功能矩阵](#功能矩阵v12) ·
[安全模型](SECURITY.md) ·
[路线图](#路线图)

</div>

---

## TL;DR

- **我们做的**：本地扫描磁盘占用、定位大文件、清卸载残留、识别启动项、检测重复文件；所有删除都是 `NSWorkspace.recycle` 移废纸篓。
- **我们不做的**：网络流量监控、伪「内存释放」、浏览器历史清理、订阅、遥测、广告。
- **安全保证**：[SafetyEngine](Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) 三档判定（safe / confirm / forbid）+ [TCCSkipList](Packages/ScanKit/Sources/ScanKit/TCCSkipList.swift) 硬 skip + 端到端集成测试钉契约 + `unlink(2)` 链路从设计上拒绝。
- **可跑性保证**：开源、ad-hoc 签名、Free Apple ID 即可本地 build 运行；不需要 99 美元/年的 Apple Developer Program。

---

## 截图

<table>
  <tr>
    <td align="center" width="50%">
      <img src="docs/screenshots/02-scan-result.png" alt="清理 - 用户缓存扫描结果" /><br/>
      <sub><b>清理</b>：选中"用户缓存"实时扫描，三色徽章标注安全度，单文件按物理占用降序</sub>
    </td>
    <td align="center" width="50%">
      <img src="docs/screenshots/03-large-files.png" alt="大文件 - Top 200" /><br/>
      <sub><b>大文件</b>：≥100 MB Top 200 一屏看完，名称 / 路径 / 大小 / 修改日期四列排序</sub>
    </td>
  </tr>
  <tr>
    <td align="center" width="50%">
      <img src="docs/screenshots/04-uninstall.png" alt="卸载残留 - 已安装应用" /><br/>
      <sub><b>卸载残留</b>：BundleID + 厂商规则字典联合命中已安装 App 的配置 / 缓存 / Preferences 残留</sub>
    </td>
    <td align="center" width="50%">
      <img src="docs/screenshots/01-overview.png" alt="主界面 - 推荐清理类目" /><br/>
      <sub><b>主界面</b>：推荐清理 / 自定义路径 / 大文件 / 整盘扫描 四类入口；删除一律走废纸篓</sub>
    </td>
  </tr>
</table>

---

## 功能矩阵（v1.2）

> 状态图例：✅ = 完整支持 / ⚠️ = 部分支持或受限 / ❌ = 未支持
> 完整 23 维 × 8 家竞品对比见 [docs/FEATURE_GAP.md](docs/FEATURE_GAP.md)

### 一、扫描类

| # | 能力 | 状态 | 说明 |
|---|---|:---:|---|
| 1 | 整盘扫描 | ✅ | 入口 [ScanCategory.fullDisk](Packages/AppUI/Sources/AppUI/ScanCategory.swift)；inode 去重 + getattrlistbulk |
| 2 | 推荐清理（一键安全项） | ✅ | 5 大类目默认勾选只勾 SafetyEngine 标 safe 的 |
| 3 | 大文件 Top N | ✅ | [LargeFilesView](Packages/AppUI/Sources/AppUI/LargeFilesView.swift) 阈值 / 时间双过滤 |
| 4 | 应用占用排行榜 | ✅ | [AppFootprintScreen](Packages/AppUI/Sources/AppUI/AppFootprintScreen.swift) 按 BundleID 聚合 |
| 5 | 卸载残留扫描 | ✅ | [AppUninstaller](Packages/AppUI/Sources/AppUI/AppUninstaller.swift) BundleID 严格前缀 + 厂商规则 + Orphan 反扫 |
| 6 | 启动项管理 | ✅ | [LaunchAgentScreen](Packages/AppUI/Sources/AppUI/LaunchAgentScreen.swift) 覆盖 LaunchAgents / LaunchDaemons |
| 7 | 重复文件检测 | ⚠️ | [DuplicateScreen](Packages/AppUI/Sources/AppUI/DuplicateScreen.swift) 只读视图，size + 前缀/全文 SHA256；不带删除按钮 |

### 二、安全类

| # | 能力 | 状态 | 说明 |
|---|---|:---:|---|
| 8 | SafetyEngine 三档判定 | ✅ | [SafetyEngine](Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) safe / confirm / forbid，每条带 reason |
| 9 | vendors.yaml 厂商规则 | ✅ | [vendors.yaml](Resources/Rules/vendors.yaml) 159+ 条，YAML 可读可 PR |
| 10 | TCCSkipList 硬 skip | ✅ | [TCCSkipList](Packages/ScanKit/Sources/ScanKit/TCCSkipList.swift) 覆盖 Mail / Messages / Calendars / .photoslibrary 等 |
| 11 | NSWorkspace.recycle 主链路 | ✅ | [TrashPipeline](Packages/AppUI/Sources/AppUI/TrashPipeline.swift) 永不 `unlink(2)`，自动注册 NSUndoManager |

### 三、体验类

| # | 能力 | 状态 | 说明 |
|---|---|:---:|---|
| 12 | 多线程并发扫描 | ✅ | [ScanCoordinator](Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) actor 化限流 |
| 13 | 类型分桶（媒体/文档/归档） | ✅ | [FileKind](Packages/AppUI/Sources/AppUI/FileKind.swift) 8 类 |
| 14 | 修改日期过滤 | ✅ | mtime 区间筛选，配合大文件 / 整盘 |
| 15 | 快速预览（Quick Look） | ✅ | [QuickLookController](Packages/AppUI/Sources/AppUI/QuickLookController.swift) 空格键预览 |
| 16 | 批量勾选 | ✅ | [BatchSelection](Packages/AppUI/Sources/AppUI/BatchSelection.swift) 全选 / 反选 / 按安全度选 |
| 17 | 导出 JSON / TSV | ✅ | [Exporter](Packages/AppUI/Sources/AppUI/Exporter.swift) 扫描结果可外发审计 |
| 18 | 隐藏文件可见 | ✅ | UI toggle，dotfile / `.app` 包内透视 |
| 19 | 树形浏览（多层下钻） | ✅ | [TreeBrowserView](Packages/AppUI/Sources/AppUI/TreeBrowserView.swift) 键盘 j/k/h/l 全程不碰鼠标 |

### 四、运维类

| # | 能力 | 状态 | 说明 |
|---|---|:---:|---|
| 20 | 自动检查更新 | ✅ | [UpdateChecker](Packages/AppUI/Sources/AppUI/Updater/UpdateChecker.swift) 启动时一次 ~2 KB GET，可关 |
| 21 | 命令行入口 | ✅ | `gsy-cleanmac` CLI binary，支持 `--dry-run` / `--export-json` |
| 22 | 端到端集成测试 | ✅ | [V12SafetyIntegrationTests](Packages/AppUI/Tests/AppUITests/V12SafetyIntegrationTests.swift) 钉死契约 |

**统计**：22 项 ✅ + 1 项 ⚠️（重复文件检测仅只读，不带删除）。

---

## 5 分钟跑起来

### 1. Clone 并生成项目

```bash
git clone git@github.com:CarGuo/GSYCleanMac.git
cd GSYCleanMac
./Scripts/setup_dev.sh         # 装 xcodegen + 生成 .xcodeproj
xcodebuild -scheme GSYCleanMac -configuration Debug build
```

### 2. 用 Free Apple ID 信任运行

```bash
open GSYCleanMac.xcodeproj
# Xcode → Signing & Capabilities → Team 选你的 Apple ID（Personal Team）
# Signing Certificate 选 "Sign to Run Locally"
# Cmd+R 直接跑；首次会被 Gatekeeper 拦，按 系统设置 → 隐私与安全 → 仍要打开
```

### 3. 卸载

```bash
osascript -e 'tell application "GSYCleanMac" to quit'
rm -rf /Applications/GSYCleanMac.app
defaults delete com.guoshuyu.GSYCleanMac 2>/dev/null || true
# 想彻底清自己留下的 prefs / Application Support：
rm -rf "$HOME/Library/Preferences/com.guoshuyu.GSYCleanMac.plist"
rm -rf "$HOME/Library/Application Support/GSYCleanMac"
```

完整安装与 TCC 授权步骤见 [docs/INSTALL.md](docs/INSTALL.md)；构建/打包/CI 细节见 [CONTRIBUTING.md](CONTRIBUTING.md)。

---

## 差异化定位

1. **开源代码可审** —— 全套 [Packages](Packages) / [Resources](Resources) 公开，任何"会不会偷偷删数据"的疑虑 grep 即可验证。
2. **Free Apple ID 可跑** —— 不依赖 Apple Developer Program（99 美元/年），ad-hoc 签名 + 本地信任就能 build 出可运行 .app。
3. **三档 SafetyEngine + vendors.yaml + VendorTrie** —— 删除候选必过 [SafetyEngine](Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) 三色判定；规则外置 YAML 可读可 PR；[VendorTrie](Packages/SafetyKit/Sources/SafetyKit/VendorTrie.swift) 把 BundleID 前缀匹配做到 O(len)。
4. **TCCSkipList 硬 skip + 端到端集成测试钉契约** —— [TCCSkipList](Packages/ScanKit/Sources/ScanKit/TCCSkipList.swift) 把 Sequoia 全部 TCC 高敏目录写成静态表；plist 里完全不注册 `NSMailLibraryUsageDescription` / `NSPhotoLibraryUsageDescription`，TCC.db 永远 not determined，零原生权限弹窗；契约由 [V12SafetyIntegrationTests](Packages/AppUI/Tests/AppUITests/V12SafetyIntegrationTests.swift) 钉死。

---

## 路线图

### v1.0（已发布）

- 整盘扫描 / 推荐清理 / 大文件 Top N / 卸载残留 / 树形下钻 / 隐藏文件可见 / SafetyEngine 三档 / NSWorkspace.recycle 主链路

### v1.1（已发布）

- 应用占用排行榜 / 启动项管理 / TCCSkipList / 修改日期过滤 / 批量勾选 / 自动检查更新

### v1.2（已发布，当前）

- 类型分桶 / 快速预览（Quick Look）/ JSON-TSV 导出 / **重复文件检测（只读视图）** / 端到端集成测试 / vendors.yaml 扩展至 159+ 条

### 暂未规划

- ❌ 重复文件**自动去重**（v1.2 仅只读，删除留给用户在 Finder 自行处理）
- ❌ 网络流量监控（与"清理"无关，且需 Network Extension entitlement）
- ❌ 启动加速 / 内存释放（多数是伪功能，违反 [PITFALLS.md](PITFALLS.md) §0 红线）
- ❌ 浏览器历史 / Cookies 清理（浏览器原生入口已足够，且 SQLite 直读 profile TCC 风险高）

---

## 致谢与文档

| 文档 | 内容 |
|---|---|
| [docs/FEATURE_GAP.md](docs/FEATURE_GAP.md) | v1.2 完整 23 维 × 8 家竞品对比 + 11 个真实踩坑场景 |
| [SECURITY.md](SECURITY.md) | 威胁模型、三道闸门、Hard Rules、漏洞上报 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | PR 红线、commit 规范、构建 / 测试 / 打包细节 |
| [PITFALLS.md](PITFALLS.md) | 同类项目踩过的坑总览，开工必读 |
| [docs/INSTALL.md](docs/INSTALL.md) | 用户安装、Gatekeeper 信任、TCC 完全磁盘访问授权 |
| [docs/ROADMAP_V1.md](docs/ROADMAP_V1.md) | v1.0 / v1.1 / v1.2 详细范围与下一版候选 |

致谢同类开源项目 [Pearcleaner](https://github.com/alienator88/Pearcleaner) 在 TCC skip / vendor 规则维护上的实践参考；规则文件全部独立清洗，未引用任何竞品源码。

---

## License

[MIT](LICENSE) · Copyright (c) 2026 CarGuo

---

## 开发环境一次性配置

ad-hoc 签名（`CODE_SIGN_IDENTITY="-"`）每次重 build 都会生成一个新的 cdhash，macOS 把"全磁盘访问 / 通讯录"等 TCC 授权挂在 cdhash 上，所以每次都会被系统当成新 App，需要反复在"系统设置 → 隐私与安全"里重新勾一遍，开发体验极差。

解决办法是用一个稳定的本地自签 codesign 身份。在新机器上首次拉代码后，跑一次：

```bash
./Scripts/setup_codesign.sh
eval "$(./Scripts/setup_codesign.sh --export)"   # 导出 GSYCLEAN_CODESIGN_IDENTITY
```

之后 `./Scripts/build_release.sh` 与 Xcode Debug 构建都会自动用这个稳定 SHA-1，TCC 授权一次到位、长期有效；该脚本幂等，重复运行会跳过已有证书。
