# GSYCleanMac 安全模型

> 这份文档描述 GSYCleanMac 的威胁模型、删除链路设计、红线与漏洞上报方式。
> 任何与本文档不一致的实现都视为 bug，请优先修代码而不是改本文档。

---

## 重要：v1.3.zzzz 路线 B 删除链路简化（2026-05-25 更新）

原"App ↔ 特权 Helper" XPC 三道闸门设计已整段下线（[Helper/](file:///Users/guoshuyu/workspace/GSYCleanMac/Helper) / [Packages/XPCBridge/](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/XPCBridge) / [HelperClient.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HelperClient.swift) / [HelperDecision.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/HelperDecision.swift)）。本产品只删 `$HOME` 下用户态文件，不需要 root；删除链路收敛为唯一一份 [TrashPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift)。

**安全合同保留**：所有"永远不 unlink / dryRun 一等公民 / SafetyEngine 三色判定 / 批级原子拒绝"红线**完全不变**，全部由主 App 进程内 SafetyEngine + TrashPipeline 双层闸门保证。

下文若提到 Helper / XPC / HMAC 签名等内容均为**历史档案**。

---

## 1. 设计原则（Hard Rules）

按重要性递减：

1. **永远不 unlink**：所有"删除"操作只能通过 `NSWorkspace.shared.recycle(_:)` 走废纸篓。代码库内禁止出现 `unlink(2)` / `FileManager.removeItem(at:)` 用于"删除候选"路径，违反者视为 P0 安全 bug。
2. **dryRun 是一等公民**：删除流水线 [TrashPipeline](Packages/AppUI/Sources/AppUI/TrashPipeline.swift) 默认 `dryRun=true`，UI 必须显式让用户切换；自动化测试一律走 dryRun。
3. **三色判定后才能删**：删除前必须经过 [SafetyEngine.evaluate](Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) 的 `safe / confirm / forbid` 三色，`forbid` 一律拒绝，`confirm` 必须用户复选确认。
4. **批级原子拒绝**：批量删除时只要任意一条命中 `forbid`，整批拒绝并提示用户，不允许"删一半再回滚"。
5. **HMAC 完整性**：DeletionToken 必须带 HMAC（[XPCBridge](Packages/XPCBridge)），中途篡改一律拒收。
6. **能力最小化**：v1 不部署 Helper，所有操作以普通用户身份运行，依赖 Trash 机制做最后兜底。

---

## 2. 威胁模型

### 在范围内（v1 必须防）

- 用户误操作：手抖把 `~/Library` 整个删除 -> hardForbid 黑名单 + 三色判定 + 批级原子拒绝
- 错误规则：vendors.yaml 写成 `~/Library` 这种危险前缀 -> RuleLoader 启动期反向校验，命中 hardForbid 的规则直接 reject
- 路径欺骗：候选路径含 `..`、symlink 出 sandbox -> SafetyEngine resolveSymlinks + 真实路径白名单
- vendor 误命中：`com.foo.bar*` 命中 `com.foo.barbarian` -> matchesStrictPrefix 强制点号边界
- 短 appName 模糊：用 "X" 反扫导致大量误删 -> minimumStem 长度限制 + 严格 Levenshtein
- 隐藏文件误删：`.DS_Store` / `.git` 之类 dotfile -> OrphanScanner 显式跳过 dotfile
- TCC 失败被吞：扫描没结果但用户不知道 -> TCCProbe errno=1 累计阈值后弹引导

### 不在范围内（v1 不防）

- 物理攻击者本地 root 提权（系统已沦陷，不在工具能解决的范围）
- 恶意 vendors.yaml 投毒（v1 只用 bundle 内置 yaml，不读用户自定义；如未来开放，再补签名验证）
- 时序侧信道（v1 不处理加密敏感信息，无意义）

---

## 3. 删除链路：三道闸门

### 闸门一：连接级（Connection-Level）

- Helper（v1 不启用，留 v2）走 `NSXPCListener`，`mach service` 名字写死 `com.guoshuyu.cleanmac.helper`
- 主 App 用 `audit_token_t` + `SecCodeCopyGuestWithAttributes` 验证 connecting peer 的签名
- 任何不带预期 Team ID / bundle ID 的连接立即 invalidate

### 闸门二：消息级（Message-Level）

- 每条 [DeletionToken](Packages/XPCBridge/Sources/XPCBridge/DeletionToken.swift) 都带 HMAC（key 来自 Keychain）
- Helper 启动读环境变量 `GSYCLEAN_ALLOW_REAL_DELETE`，缺省永远走 dryRun（即使收到合法 token）
- TamperedDryRun 测试见 [XPCBridgeTests](Packages/XPCBridge/Tests/XPCBridgeTests)

### 闸门三：语义级（Semantic-Level）

- [SafetyEngine](Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) 三色判定流程：

  1. resolveSymlinks 取真实路径
  2. 命中 hardForbid 黑名单 -> `forbid`（黑名单写死在代码里，不可配置）
     - `/`、`/System`、`/usr`、`/bin`、`/sbin`、`/Library/Apple`、`~`、`~/Library`、`~/Documents`
  3. 命中 safeCachePrefixes 显式白名单 -> `safe`
     - `~/Library/Caches/<bundleID>`、`~/Library/Application Support/<bundleID>` 等已知 sandbox 容器
  4. 命中 VendorTrie 路径前缀（vendors.yaml 展开后）-> 强制降为 `confirm`
  5. 默认 `confirm`，UI 必须用户勾选才会进 deletion 队列
- 卸载残留路 [AppUninstaller](Packages/AppUI/Sources/AppUI/AppUninstaller.swift) 候选必须再过一次 SafetyEngine
- Orphan 反扫 [OrphanScanner](Packages/AppUI/Sources/AppUI/OrphanScanner.swift) 多一道 mtime ≥ 30 天 + bundleID 注销 + appName 不在装机列表

---

## 4. 数据持久化与隐私

GSYCleanMac 是**完全离线**应用：

- 不发起任何 HTTP 请求（NSAllowsArbitraryLoads=false）
- 不收集遥测、不上报崩溃
- 唯一持久化文件：
  - `~/Library/Application Support/GSYCleanMac/heuristic.json`：仅存 bundleID 维度的 `(deleted, restored, kept)` 三元组计数，无路径
  - `~/Library/Preferences/com.guoshuyu.cleanmac.plist`：UI 偏好（窗口大小、阈值等）
- 不读取剪贴板、不读取通讯录、不读取浏览器历史

---

## 5. v1 已知不防的攻击面（透明）

- ad-hoc 签名意味着无 notarization；理论上恶意者可以拿走 .app 篡改后重新 ad-hoc 签名再分发，**所以请只从 GitHub Releases 下载，并用 sha256 校验**
- v1 不启用 Helper -> 受 TCC 限制读不到的目录扫不到，这是预期；不会通过任何"曲线救国"绕过 TCC
- vendors.yaml 在 bundle 内只读，但用户如果自己 mod app 资源后果自负

---

## 6. 漏洞上报

如果你发现了**会绕过三道闸门导致 unlink 真删**或**导致 SafetyEngine 错判**的漏洞，请：

- 不要公开 issue
- 发邮件到 `guoshuyu.gh@gmail.com`，标题前缀 `[SECURITY]`
- 包含：复现步骤、影响范围、建议修复方向
- 我会在 7 天内回复，确认后 30 天内发补丁

非安全 bug、误命中、性能问题请走正常 GitHub Issue。

---

## 7. 红线汇总（对开发者）

新增/修改代码时必须自检：

1. 没引入 `unlink` / `removeItem(at:)` 删除候选路径
2. 新增删除路径默认走 dryRun
3. 新加规则跑 RuleLoader 反向校验过 hardForbid
4. 新加候选源（如 v2 增加 LaunchAgents 扫描）必须再过 SafetyEngine
5. 测试不允许通过减少断言来"修绿"
6. UI 上"危险操作"按钮必须用 `.destructive` role + 二次确认 sheet
7. 不允许 `try?` 静默吞错（错误必须 log 或上抛）
