<div align="center">

<img src="docs/assets/logo.png" width="128" alt="AmuxAIClean" />

# AmuxAIClean

**面向 macOS 的开源、可审计、安全清理管家。**

[English](README.en.md) | 简体中文

[![License MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
<!-- v2026.07.16：产品部署下限统一为已纳入兼容合同的 Ventura 13.5。 -->
[![macOS 13.5+](https://img.shields.io/badge/macOS-13.5%2B-success)](docs/INSTALL.md)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange)](https://swift.org)
[![Tests 9 Packages](https://img.shields.io/badge/tests-9%20packages-brightgreen)](#质量与安全)
[![i18n zh-Hans EN](https://img.shields.io/badge/i18n-zh--Hans%20%7C%20EN-informational)](#多语言)

[下载最新版](https://github.com/CarGuo/AmuxAICleanRelease/releases/latest) ·
[安装指南](docs/INSTALL.md) ·
[安全模型](SECURITY.md) ·
[路线图](docs/ROADMAP_V1.md)

</div>

> **特别鸣谢**：感谢 [https://amux.ai/](https://amux.ai/) 中转平台赞助本项目的开发 Token 与 Apple 开发者账号，这也是本项目命名为 **AmuxAIClean** 的原因。

---

## 它能为你做什么

- 一键找出 Mac 里**真正能删的垃圾**：用户缓存、应用日志、Xcode 构建产物、下载历史、废纸篓。
- **找回被代码项目偷走的硬盘**：识别 Android / Flutter / iOS / RN / Electron / Rust / Go / Python 等十多种生态的 build / node_modules / target / .gradle / DerivedData。
- **一目了然看大文件**：≥100 MB Top 200 一屏看完，按大小或修改日期排序。
- **彻底卸载残留**：选中已安装 App，自动列出它在系统各处留下的配置 / 缓存 / Preferences / Group Containers。
- **检查传统启动代理**：只读列出三个 launchd plist 目录下的 LaunchAgents / LaunchDaemons；现代“登录项与扩展”仍由系统设置管理。
- **删除保留恢复窗口**：所有删除统一走废纸篓，永远不调用 `unlink(2)`；清倒废纸篓前可尝试从最近记录或 Finder 恢复。

---

## 截图

<table>
  <tr>
    <td align="center" width="50%">
      <img src="docs/screenshots/02-scan-result.png" alt="推荐扫描结果" /><br/>
      <sub><b>推荐清理</b>：选中类目实时扫描，三色徽章标注安全度，按物理占用降序</sub>
    </td>
    <td align="center" width="50%">
      <img src="docs/screenshots/03-large-files.png" alt="大文件 Top 200" /><br/>
      <sub><b>大文件</b>：≥100 MB Top 200 一屏看完，名称 / 路径 / 大小 / 修改日期四列排序</sub>
    </td>
  </tr>
  <tr>
    <td align="center" width="50%">
      <img src="docs/screenshots/04-uninstall.png" alt="卸载残留" /><br/>
      <sub><b>卸载残留</b>：识别已安装 App 在系统各处的配置 / 缓存 / Preferences 残留</sub>
    </td>
    <td align="center" width="50%">
      <img src="docs/screenshots/01-overview.png" alt="主界面" /><br/>
      <sub><b>主界面</b>：推荐清理 / 自定义路径 / 大文件 / 整盘 / 开发者构建产物 五类入口</sub>
    </td>
  </tr>
</table>

> 想自己复现这些截图？跑一次 `./Scripts/screenshots.sh` 即可。

---

## 我们做什么、不做什么

**做的**

- 本地扫描磁盘占用、定位大文件、清卸载残留、识别启动项、检测重复文件、扫描开发者构建产物。
- 一切删除走废纸篓；在废纸篓项目仍存在且身份未变化时可尝试恢复。
- 可选 Sentinel 默认关闭；用户主动开启后以当前登录用户的非特权 Agent 在本机监听废纸篓和清理热点。当前版本会自动注销历史错误 root 注册，具体记录、迁移、注销与清除边界见 [PRIVACY.md](PRIVACY.md)。
- 本地安全判定不依赖网络；App 主动 HTTP 只有 GitHub 更新检查（首次安装默认开启启动检查，
  设置中可关闭）和用户主动启用/触发的 AI 请求。扫描网络卷、云端占位文件或使用 Quick Look
  仍可能由 macOS/存储提供方产生网络读取。
  AI 可能发送的路径上下文与元数据、默认脱敏和服务商边界以 [PRIVACY.md](PRIVACY.md) 为准。

**不做的**

- 网络流量监控、伪「内存释放」、伪「启动加速」、浏览器历史清理。
- 订阅、遥测、广告、捆绑安装。

为什么不做？详见 [PITFALLS.md](PITFALLS.md) 和 [SECURITY.md](SECURITY.md)。

---

## 多语言

支持 **简体中文** 与 **English**，跟随系统语言自动切换。也可以在系统设置里给单个 App 单独指定语言。

---

## 安装

最快路径：

1. 去 [Releases](https://github.com/CarGuo/AmuxAICleanRelease/releases/latest) 下载已发布的 `.dmg`。
2. 拖入 Applications，首次启动按系统提示「仍要打开」。
3. 如需完整扫描，在「系统设置 → 隐私与安全 → 完全磁盘访问」里允许 AmuxAIClean；拒绝后 App 仍可用，但会明确标记结果不完整。

完整安装、TCC 授权、签名校验步骤见 [docs/INSTALL.md](docs/INSTALL.md)。

> 当前公开发布路径只来自维护者本地的 **Developer ID Application 签名 + 最终 DMG 公证**。当前发布和校验边界见 [docs/RELEASE.md](docs/RELEASE.md)。

---

## 质量与安全

- **9 个第一方 SPM 包测试**：[ScanKit](Packages/ScanKit) / [SafetyKit](Packages/SafetyKit) / [AppUI](Packages/AppUI) / [HeuristicKit](Packages/HeuristicKit) / [LogKit](Packages/LogKit) / [BrewKit](Packages/BrewKit) / [FileSearchKit](Packages/FileSearchKit) / [AIKit](Packages/AIKit) / [TestHarness](Packages/TestHarness)；具体测试数以本次运行输出为准。
- **三档安全引擎**：每条删除候选都过 `safe / confirm / forbid` 三色判定，规则在 [vendors.yaml](Resources/Rules/vendors.yaml) 公开可读。
- **TCC 高敏目录硬 skip**：Mail / Messages / Calendars / Photos Library 等永远不进入扫描候选，从源头规避「删用户邮件」类事故。
- **端到端集成测试钉契约**：[V12SafetyIntegrationTests](Packages/AppUI/Tests/AppUITests/V12SafetyIntegrationTests.swift) 把「不许删什么」写成断言。
- **永不 `unlink(2)`**：所有删除路径都强制 `NSWorkspace.recycle()` 移废纸篓。

完整威胁模型见 [SECURITY.md](SECURITY.md)。

---

## 自己跑起来

```bash
git clone git@github.com:CarGuo/AmuxAIClean.git
cd AmuxAIClean
./Scripts/setup_dev.sh
```

> **fork 用户必读**：[AmuxAIClean.xcodeproj/project.pbxproj](AmuxAIClean.xcodeproj/project.pbxproj) 当前 Debug 走 `Automatic + Apple Development`，Release 走 `Manual + Developer ID Application: SentenceEnd Inc (W6H34N9728)`。第一次 build 必须改成你自己的 Team / signing 配置。详见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) "签名配置" 段。

```bash
xcodebuild -project AmuxAIClean.xcodeproj -scheme AmuxAIClean -configuration Debug build
```

完整开发环境、签名、调试技巧见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) 与 [CONTRIBUTING.md](CONTRIBUTING.md)。

---

## 路线图

| 版本 | 主题 | 状态 |
|---|---|---|
| v1.0 | 整盘扫描 / 推荐清理 / 大文件 / 卸载残留 / SafetyEngine 三档 | 已发布 |
| v1.1 | 应用占用 / 启动项 / TCCSkipList / 修改日期过滤 / 自动检查更新 | 已发布 |
| v1.2 | 类型分桶 / Quick Look / 导出 / 重复文件检测（只读） | 已发布 |
| v1.3 | 灵动岛 HUD / 状态栏托盘 / 设置面板重构 | 已发布 |
| v1.4 | 开发者构建产物扫描（Android / Flutter / iOS / RN / 等 12+ 生态）| 已发布 |
| v1.5 | 树视图增量化（O(N flat) prune patch + 原生 String 路径切分 + DirIndex 祖先对称减法 + store 错误日志化）| 已发布 |

详见 [docs/ROADMAP_V1.md](docs/ROADMAP_V1.md)。

---

## 文档地图

| 文档 | 内容 |
|---|---|
| [docs/INSTALL.md](docs/INSTALL.md) | 安装、Gatekeeper、TCC 完全磁盘访问授权 |
| [docs/RELEASE.md](docs/RELEASE.md) | 维护者本地 Developer ID、最终 DMG 公证与 SHA256 校验 |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | 开发环境、构建脚本、本地调试 |
| [docs/DEV_ARTIFACTS_RULES.md](docs/DEV_ARTIFACTS_RULES.md) | 开发者构建产物扫描规则与拓展 |
| [docs/FEATURE_GAP.md](docs/FEATURE_GAP.md) | 与同类产品 23 维 × 8 家竞品对比 |
| [docs/ROADMAP_V1.md](docs/ROADMAP_V1.md) | 版本规划与每个里程碑的范围 |
| [SECURITY.md](SECURITY.md) | 威胁模型、Hard Rules、漏洞上报 |
| [PRIVACY.md](PRIVACY.md) | 联网字段、本地存储、权限、Sentinel 与清除顺序 |
| [PITFALLS.md](PITFALLS.md) | 同类项目踩过的坑总览 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | PR 红线、commit 规范 |

---

## 致谢

- 感谢 [https://amux.ai/](https://amux.ai/) 中转平台赞助本项目的开发 Token 与 Apple 开发者账号。
- 致谢同类开源项目 [Pearcleaner](https://github.com/alienator88/Pearcleaner) 在 TCC skip / vendor 规则维护上的实践参考。规则文件全部独立清洗，未引用任何竞品源码。

---

## License

[MIT](LICENSE) · Copyright (c) 2026 CarGuo
