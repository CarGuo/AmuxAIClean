# 安装与首次使用

> v2026.07.18：本文只描述当前 AmuxAIClean 发行与权限合同。旧版 ad-hoc / ZIP 安装说明
> 不再代表当前公开产物；隐私字段、保留与完整清除顺序以
> [PRIVACY.md](../PRIVACY.md) 为准。

## 1. 系统要求

- macOS 13.5 Ventura 或更高；
- Apple Silicon 或 Intel x86_64（正式 DMG 为 universal binary）；
- 约 30 MB App 空间，扫描和废纸篓操作所需空间取决于用户数据；
- 本地扫描可在未授予完全磁盘访问时运行，但受阻位置会显示为不完整。

开发机的 Xcode / Swift 工具链要求见 [DEVELOPMENT.md](DEVELOPMENT.md)，不能把开发下限
写成用户安装下限。

## 2. 下载与完整性校验

当前公开发行合同是维护者本地生成的 **Developer ID Application 签名、最终 DMG 公证并
staple/validate** 的产物。仓库里的 GitHub Actions CI 和 Release job 均为 `if: false`，
不会自动构建或上传公开产物。

从 [Releases](https://github.com/CarGuo/GSYCleanMac/releases/latest) 下载已发布的
`AmuxAIClean-x.y.z.dmg` 及对应 `.sha256`，然后校验：

```bash
shasum -a 256 AmuxAIClean-x.y.z.dmg
```

输出首列应与同版本 `.sha256` 文件一致。SHA-256 证明下载字节一致；Developer ID、
Notary 与 Gatekeeper 验证发布身份和 Apple 公证状态。完整发布证据链见
[RELEASE.md](RELEASE.md)。

## 3. 安装与首次启动

1. 双击挂载 `AmuxAIClean-x.y.z.dmg`；
2. 把 `AmuxAIClean.app` 拖入 `/Applications`；
3. 从 Applications 启动 App。

正常的已公证正式产物应通过 Gatekeeper。若系统阻止启动：

1. 先确认文件名、版本和 SHA-256 与发布页一致；
2. 在 Finder 中右键 App 选择“打开”，或前往“系统设置 → 隐私与安全”查看系统给出的
   具体签名/公证提示；
3. 若仍失败，停止使用并提交 Issue，附 macOS 版本和系统原始提示。

不要用 `xattr -cr`、关闭 Gatekeeper 或移除 quarantine 来掩盖签名/公证故障；这些命令会
绕过本应保留的来源检查。

## 4. 磁盘与 App 数据权限

AmuxAIClean 不使用 App Sandbox，但 macOS 的 TCC 和文件权限仍会限制元数据读取，以及重复
文件扫描在本机执行 SHA-256 所需的文件字节读取。

- **完全磁盘访问**：可提高整盘、其他 App 数据和部分系统级位置的可见性。拒绝后 App
  保持可用，并把受阻范围显示为 incomplete，而不是伪装成 0 项；
- **其他 App 数据访问**：系统可能依据 `NSAppDataUsageDescription` 询问是否允许读取其他
  App sandbox container 的元数据；
- **App 管理访问**：系统可能依据 `NSAppBundlesUsageDescription` 询问是否允许读取已安装
  App bundle 的元数据；
- **用户选择的文件夹**：只在用户主动添加自定义扫描根时使用。

普通磁盘占用扫描只读取文件系统元数据；重复文件页默认检查桌面、文稿和下载，并可加入其它
目录，因此会在本机读取候选文件字节计算 SHA-256。文件内容和重复文件哈希不会上传或持久化，
具体分段与提交前重验见 [PRIVACY.md](../PRIVACY.md)。

Mail、Messages、Calendars、Photos Library 等 `TCCSkipList` 高敏位置是产品硬边界：
**即使已经授予完全磁盘访问也不会下钻或生成清理候选**。完全磁盘访问只改变允许扫描的其它
位置和权限错误呈现，不能扩大这条隐私边界。

如需授予完全磁盘访问：

1. 打开“系统设置 → 隐私与安全 → 完全磁盘访问权限”；
2. 添加 `/Applications/AmuxAIClean.app` 并打开开关；
3. 按系统提示重新启动 App，再重新扫描。

## 5. 网络与可选后台项目

本地安全判定和删除授权不依赖网络。当前 App 源码只有两类主动 HTTP 能力：

- 更新检查访问 GitHub Releases；启动自动检查首次安装默认开启、每个 App 进程最多一次，
  可在设置中关闭，手动检查只在用户点击后发生；
- AI 助手默认关闭；用户启用并主动发起询问/审核后，请求才会发给用户配置的
  OpenAI-compatible 最终端点；base URL 不能携带 userinfo/query/fragment，客户端不跟随
  HTTP redirect。

用户若选择 SMB/NFS 网络卷、iCloud/FileProvider 占位文件或 Quick Look，macOS、文件系统或
存储提供方仍可能远端读取/下载。这不属于 App 主动 HTTP 上传，但也不能理解成“扫描绝不会
触发网络 I/O”；完整边界见 [PRIVACY.md](../PRIVACY.md)。

AI 可能发送的路径上下文、元数据、默认脱敏和服务商边界见
[PRIVACY.md](../PRIVACY.md)，远程结果不能授权删除或覆盖本地 SafetyEngine。

Sentinel 也默认关闭。用户主动开启后，App 通过 ServiceManagement 注册当前登录用户的
非特权 Agent，在本机监听废纸篓和清理热点，不建立网络连接。升级自旧版时会分别检查并
注销 `com.guoshuyu.cleanmac.sentinel` 与 `com.amux.ai.Clean.sentinel` 两代错误 root
LaunchDaemon；任一旧注册未权威收敛时不会叠加启动新 Agent。关闭当前 Agent 属于降权动作，
不因旧描述符查询失败而跳过，但设置页会继续标为旧状态未验证。

## 6. 卸载 AmuxAIClean 自身

如果启用过 Sentinel，必须先在“设置 → 高级”关闭它，并确认状态为“未注册 /
Not registered”。删除偏好或 App 文件不能代替 `SMAppService.unregister()`。

随后：

1. 退出 AmuxAIClean；
2. 把 `/Applications/AmuxAIClean.app` 移到废纸篓；
3. 若要同时清除 Undo、pending ledger、白名单、统计、设置、日志和 AI Keychain 凭据，
   严格按 [PRIVACY.md 第 4 节](../PRIVACY.md#4-清除本地数据) 的顺序执行；
4. 在“系统设置 → 隐私与安全”中按需撤销完全磁盘访问、其他 App 数据和 App 管理授权。

删除 App 数据不会清空废纸篓，也不会恢复已经移入废纸篓的项目。

## 7. 常见问题

**扫描结果为什么比 `du` 少？**

先查看页面的 incomplete / permission 详情。权限拒绝、跨卷边界、扫描预算和产品
`TCCSkipList` 都可能形成差异；不能把所有差异都归因于完全磁盘访问。

**能否不进废纸篓直接删除？**

不能。生产删除统一走 `TrashPipeline → NSWorkspace.recycle`。恢复仅在匹配的废纸篓对象
仍存在且身份可验证时尝试，清倒废纸篓后不保证可恢复。

**为什么卸载页会阻止删除？**

安装 App 身份、候选发现、Spotlight/pkg receipt 或文件系统证据不完整时会 fail closed。
重新扫描并查看类型化问题；不要把“不完整”当作“没有残留”。
