# 安装与首次使用

GSYCleanMac 采用 ad-hoc 签名（不依赖 Apple Developer Program 99 美元/年），首次启动需要用户手动 trust 一次。这是 macOS 的预期行为，与同类开源项目（Pearcleaner、Stats、Rectangle 早期版本等）流程一致。

---

## 1. 系统要求

- macOS 15 Sequoia 或更高
- Apple Silicon 或 Intel x86_64（DMG 内为 universal binary）
- 大约 30 MB 可用磁盘
- 首次扫描需要"完全磁盘访问"权限（Full Disk Access）才能读取系统级目录与他人 Library

---

## 2. 下载

打开 [Releases 页面](https://github.com/CarGuo/GSYCleanMac/releases)，下载最新的 `GSYCleanMac-x.y.z.dmg`，例如 `GSYCleanMac-1.1.0.dmg`。

可选：同时下载 `GSYCleanMac-x.y.z.dmg.sha256`，校验完整性：

```bash
shasum -a 256 GSYCleanMac-1.1.0.dmg
# 输出应与 .sha256 文件一致
```

---

## 3. 安装

1. 双击 `GSYCleanMac-1.1.0.dmg` 挂载磁盘镜像
2. 把窗口里的 `GSYCleanMac.app` 拖进 `/Applications` 文件夹
3. Finder 弹出"替换/保留两者"时，选"替换"（升级安装）

---

## 4. 首次启动（重要）

由于使用 ad-hoc 签名，Gatekeeper 会拦下首次启动并提示"无法打开，因为 Apple 无法检查它是否包含恶意软件"。**这是预期行为**，按以下步骤 trust 一次：

### macOS 15 Sequoia（推荐流程）

1. 在 `/Applications` 双击 `GSYCleanMac.app`，看到拦截弹窗后点 "完成" 或 "取消"
2. 打开 系统设置 -> 隐私与安全
3. 滚动到底部 "安全性" 区域，能看到一行："已阻止 GSYCleanMac 的使用，因为它不是来自被认证的开发者"
4. 点击该行右侧的 "仍要打开"
5. 弹出二次确认窗口，点 "仍要打开"，输入登录密码
6. 之后双击 `GSYCleanMac.app` 即可正常启动

### macOS 13–14（右键打开 fallback）

1. 在 Finder 进入 `/Applications`
2. 右键 `GSYCleanMac.app`，选 "打开"（不是双击）
3. 弹出 "Apple 无法检查… 是否仍要打开？" 时点 "打开"
4. trust 一次后，之后双击直接启动

> Trust 是按"具体二进制 + 路径"绑定的；如果 DMG 升级了 .app 内容（不同 hash），可能需要重新 trust 一次。

---

## 5. 授予完全磁盘访问（强烈建议）

GSYCleanMac 不使用 Sandbox，但 macOS TCC 仍会限制非系统 app 读取这些目录：

- `~/Library/Mail`、`~/Library/Messages`
- 其他用户的 Home
- `/Library/Application Support` 部分子目录
- iCloud Drive 占位文件

授予完全磁盘访问后扫描数据才完整：

1. 系统设置 -> 隐私与安全 -> 完全磁盘访问权限
2. 点 + 按钮，定位 `/Applications/GSYCleanMac.app`，添加并打开开关
3. 重启 GSYCleanMac

应用内首次扫描时若检测到 errno=1（Operation not permitted）超过阈值，会弹出引导按钮直接跳到上述系统设置页（依赖 [TCCProbe](../Packages/AppUI/Sources/AppUI/TCCProbe.swift)）。

---

## 6. 卸载 GSYCleanMac 自身

1. 把 `/Applications/GSYCleanMac.app` 拖进废纸篓
2. 删除 `~/Library/Application Support/GSYCleanMac/`（包含 heuristic.json 启发式数据）
3. 删除 `~/Library/Preferences/com.guoshuyu.cleanmac.plist`
4. （可选）从系统设置 -> 隐私与安全 -> 完全磁盘访问 中移除 GSYCleanMac 条目

---

## 7. 常见问题

**Q：看不到 "仍要打开" 按钮？**
A：先双击一次 .app（即使被拦），让 macOS 知道这次启动尝试，然后再去系统设置。

**Q：提示 "应用已损坏，无法打开"？**
A：执行 `xattr -cr /Applications/GSYCleanMac.app` 清除隔离属性，再用上面的右键打开流程。

**Q：扫描结果远小于 du 输出？**
A：通常是没授予完全磁盘访问。先授权再 Cmd+R 重扫。

**Q：能不能不进废纸篓直接 unlink？**
A：不能。GSYCleanMac 设计上**永远不 unlink**，所有删除都走 NSWorkspace.recycle 进废纸篓。详见 [SECURITY.md](../SECURITY.md)。

**Q：卸载残留扫描里看到 "为什么我建议删它"？**
A：每条候选都带 MatchReason，包括 bundleID 严格前缀命中、Vendor 字典命中、Orphan 反扫（bundleID 已注销 / appName 已不在装机列表 + mtime ≥ 30 天）。
