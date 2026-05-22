<div align="center">

<img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="GSYCleanMac" />

# GSYCleanMac

**给 Mac 用一年就胀的硬盘减负 —— 开源、零网络、零订阅。**

[![CI](https://github.com/CarGuo/GSYCleanMac/actions/workflows/ci.yml/badge.svg)](https://github.com/CarGuo/GSYCleanMac/actions/workflows/ci.yml)
[![Release](https://github.com/CarGuo/GSYCleanMac/actions/workflows/release.yml/badge.svg)](https://github.com/CarGuo/GSYCleanMac/actions/workflows/release.yml)
[![Latest](https://img.shields.io/github/v/release/CarGuo/GSYCleanMac?display_name=tag)](https://github.com/CarGuo/GSYCleanMac/releases/latest)
[![License](https://img.shields.io/github/license/CarGuo/GSYCleanMac)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-15%2B-blue)](#系统要求)

[下载最新版](https://github.com/CarGuo/GSYCleanMac/releases/latest) ·
[安装指南](docs/INSTALL.md) ·
[功能一览](#你能用它干什么) ·
[安全模型](SECURITY.md) ·
[开发文档](docs/DEVELOPMENT.md)

</div>

---

## 这是什么

GSYCleanMac 是一款 **macOS 本地清理与卸载残留管家**：扫一次就知道硬盘里到底是什么在占空间、哪些 App 卸了之后还有几百兆配置赖在 `~/Library` 里没走。**所有删除都走废纸篓**，给反悔留窗口。代码完全开源，不联网、不上传任何路径，**也不会让你掏 99 美元/年**。

不是为了取代 CleanMyMac，是给那种"不想交订阅、不想被国外 App 把日志和遥测往云端怼一份"的人一个本地、可审计、敢上的备选。

---

## 你能用它干什么

- **看清磁盘** —— firmlink / iCloud 占位 / 硬链接 / APFS clone 全部按物理占用统计，结果跟 `du -h` 对得上，不再被 Finder "已使用 286 GB" 糊弄
- **大文件捕手** —— 一键列出按"几 GB 起、按修改时间倒序"过滤的大文件，行内 Finder 显示 / 复制路径 / 移废纸篓三连
- **卸载残留三连扫** —— 不光按 App 名匹配（短名容易误伤），还按 BundleID 严格前缀 + 厂商规则字典 + Orphan 反扫三路同时找
- **目录树下钻** —— 像 GrandPerspective / DaisyDisk 那样多层下钻，但用键盘 j/k/h/l/Enter/Space/⌘R 全程不碰鼠标
- **永远默认 dry-run** —— 三道闸门挡误删；删除链路从设计上就拒绝 unlink，所有"删"都是 NSWorkspace.recycle 移到废纸篓
- **真隐私** —— 0 网络出站、0 遥测、0 订阅、0 后台守护进程；首次会引导你授权"完全磁盘访问"，授权位完全在系统设置里你可以随时撤

---

## 截图

> 截图位（v1.1 补）。先看 [Releases v1.0.0](https://github.com/CarGuo/GSYCleanMac/releases/tag/v1.0.0) 里的 DMG 装上跑一次效果最直接。

```
[ 主界面：扫描进度条 + 三色徽章分类 ]
[ 大文件视图：按 size 降序，行内 Finder/复制/废纸篓 ]
[ 卸载残留：BundleID + Vendor + Orphan 三路命中 ]
[ 目录树下钻：j/k/h/l 键盘导航 ]
```

---

## 安装

### 方法 A：下载 DMG（推荐）

1. 到 [Releases 页](https://github.com/CarGuo/GSYCleanMac/releases/latest) 下载 `GSYCleanMac-x.y.z.dmg`
2. 双击挂载，把 `GSYCleanMac.app` 拖进 `/Applications`
3. **首次双击会被 Gatekeeper 拦下**（这是 ad-hoc 签名的预期）：
   - macOS 15+：系统设置 → 隐私与安全 → 滚到底点"仍要打开"
   - macOS 13–14：Finder 里右键 `GSYCleanMac.app` → "打开" → 弹窗再点 "打开"
4. 信任一次后双击直接开。完整截图步骤见 [docs/INSTALL.md](docs/INSTALL.md)
5. 想扫到完整结果，需要在 系统设置 → 隐私与安全 → 完全磁盘访问 中勾上 GSYCleanMac

### 方法 B：自己编译

```bash
git clone git@github.com:CarGuo/GSYCleanMac.git
cd GSYCleanMac
./Scripts/setup_dev.sh        # 装 xcodegen + 生成 .xcodeproj
open GSYCleanMac.xcodeproj    # Xcode 里 Free Apple ID 直接 Run
```

详细命令行/CI 构建步骤见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。

---

## 校验下载

```bash
shasum -a 256 GSYCleanMac-1.0.0.dmg
# 应与同 release 里附带的 GSYCleanMac-1.0.0.dmg.sha256 内容一致
```

---

## 系统要求

| 项 | 要求 |
|---|---|
| 系统 | macOS 15 Sequoia 或更高 |
| 架构 | Apple Silicon + Intel（universal） |
| 权限 | 首次扫全盘需"完全磁盘访问"，可随时回收 |
| 网络 | **不需要**（App 不主动联网） |
| Apple ID | 用户安装：不需要 / 自己编译跑 Debug：Free Apple ID 即可 |

---

## 为什么不收费 / 为什么不公证

- 主要是作者自用 + 顺手开源。一年 99 美元的 Apple Developer Program 对个人开发者没必要为"省一次 Gatekeeper 弹窗"买单
- ad-hoc 签名 + 用户首次手动信任，是 Pearcleaner / Stats / Rectangle / KeyCastr 等一众明星开源项目的通用做法
- 如果你愿意自己掏 Developer ID 公证，把 `IDENTITY="Developer ID Application: ..."` 传给 [Scripts/build_release.sh](Scripts/build_release.sh) 即可

---

## 安全红线（节选）

> 完整版见 [SECURITY.md](SECURITY.md)，下面 6 条是底线。

1. **删除一律走废纸篓**，永不调 `unlink(2)`
2. **默认 dry-run**，必须显式开关才会真动文件
3. **三道闸门**（连接级 mach service 白名单 + 消息级 HMAC + 语义级 SafetyEngine 三色判定）任何一道拒就直接拒
4. **hardForbid 黑名单写死在二进制里**，规则文件改不了它
5. **零网络**，扫描结果不出本机
6. **绝不抄竞品商业代码**，规则文件全部独立清洗

---

## 文档导航

| 文档 | 说明 |
|---|---|
| [docs/INSTALL.md](docs/INSTALL.md) | 用户安装、Gatekeeper 信任、TCC 完全磁盘访问授权 |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | 开发者构建、跑测试、目录结构、CI / Release 工作流 |
| [SECURITY.md](SECURITY.md) | 威胁模型、三道闸门细节、Hard Rules、漏洞上报方式 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | PR 红线、commit 规范、bug 报告模板 |
| [PITFALLS.md](PITFALLS.md) | 同类项目踩过的坑总览（开工必读） |
| [docs/ROADMAP_V1.md](docs/ROADMAP_V1.md) | v1.0 范围 + v1.1 / v2 路线 |
| [docs/FEATURE_GAP.md](docs/FEATURE_GAP.md) | 与 CleanMyMac / AppCleaner / Pearcleaner / DaisyDisk 的差距分析 |

---

## 贡献

欢迎 issue 与 PR。**先读 [CONTRIBUTING.md](CONTRIBUTING.md) 和 [PITFALLS.md](PITFALLS.md)**：新增删除路径必须先实现 dryRun，绝不削弱已有测试，绝不抄竞品源码。

---

## License

[MIT](LICENSE) · Copyright (c) 2026 CarGuo
