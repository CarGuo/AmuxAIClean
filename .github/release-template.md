# GSYCleanMac vX.Y.Z

> Release date: YYYY-MM-DD
> Build: <CFBundleVersion 由 CI 自动注入>

## ✨ Highlights

<!-- 用 1-3 句话告诉用户本版本最值得关注的事，避免列表式枯燥 -->
- 

## ➕ Added

<!-- 新功能 / 新规则 / 新菜单 -->
- 

## 🔧 Changed

<!-- 行为变化、UI 调整、默认值改动 -->
- 

## 🐛 Fixed

<!-- 修复的 bug，附 issue 编号 #xxx -->
- 

## 🔐 Security / Privacy

<!-- 任何影响权限、网络、删除安全性的变更必须列在这里；零变更也写"无"，不留空 -->
- 无遥测变更：本版本仍只在启动 / 用户手动触发时向 `api.github.com` 发一次 GET，详见 [PRIVACY.md](https://github.com/CarGuo/GSYCleanMac/blob/main/PRIVACY.md)

## ⚠️ Known Issues

<!-- 已知问题 + 临时绕过 -->
- 

## 📦 安装

下载下面的 `GSYCleanMac-X.Y.Z.dmg`，挂载后拖入 `应用程序`。

如果下载的是未公证构建，首次启动会被 Gatekeeper 拦截，请：
1. 不要双击；
2. 「系统设置」→「隐私与安全」→ 滚到底部「安全性」→ 点「仍要打开」→ 输密码确认；
3. 之后双击即可正常启动。

完整安装步骤、SHA256 校验、卸载方式见仓库 [docs/INSTALL.md](https://github.com/CarGuo/GSYCleanMac/blob/main/docs/INSTALL.md)。

## ✅ 完整性校验

```bash
shasum -a 256 GSYCleanMac-X.Y.Z.dmg
shasum -a 256 GSYCleanMac-X.Y.Z.app.zip
```

应与同名 `.sha256` 文件输出一致。

## 🖥️ 系统要求

- macOS 15 Sequoia 或更高
- Apple Silicon / Intel x86_64（universal binary）
- 约 30 MB 磁盘空间

## 🔗 链接

- 完整变更日志：[CHANGELOG.md](https://github.com/CarGuo/GSYCleanMac/blob/main/CHANGELOG.md)
- 隐私协议：[PRIVACY.md](https://github.com/CarGuo/GSYCleanMac/blob/main/PRIVACY.md)
- 使用条款：[TERMS.md](https://github.com/CarGuo/GSYCleanMac/blob/main/TERMS.md)
- 反馈问题：[Issues](https://github.com/CarGuo/GSYCleanMac/issues)
