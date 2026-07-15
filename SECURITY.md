# GSYCleanMac 安全模型

> 这份文档描述 GSYCleanMac 的威胁模型、删除链路设计、红线与漏洞上报方式。
> 任何与本文档不一致的实现都视为 bug，请优先修代码而不是改本文档。

---

## 重要：v1.3.zzzz 路线 B 删除链路简化（2026-05-25 更新）

原"App ↔ 特权 Helper" XPC 三道闸门设计已整段下线（[Helper/](file:///Users/guoshuyu/workspace/GSYCleanMac/Helper) / [Packages/XPCBridge/](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/XPCBridge) / [HelperClient.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HelperClient.swift) / [HelperDecision.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/HelperDecision.swift)）。本产品只删 `$HOME` 下用户态文件，不需要 root；删除链路收敛为唯一一份 [TrashPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift)。

**安全原则保留**："永远不 unlink / dryRun 执行层默认安全 / SafetyEngine 三色判定 / 批级原子拒绝"仍由主 App 进程内 SafetyEngine + TrashPipeline 双层闸门保证；当前 Release 交互和专业覆盖边界以下文现行章节为准，不再沿用历史 Helper UI。

下文若提到 Helper / XPC / HMAC 签名等内容均为**历史档案**。

---

## 1. 设计原则（Hard Rules）

按重要性递减：

1. **永远不 unlink**：所有"删除"操作只能通过 `NSWorkspace.shared.recycle(_:)` 走废纸篓。代码库内禁止出现 `unlink(2)` / `FileManager.removeItem(at:)` 用于"删除候选"路径，违反者视为 P0 安全 bug。
2. **dryRun 是执行层的一等公民**：删除流水线 [TrashPipeline](Packages/AppUI/Sources/AppUI/TrashPipeline.swift) 默认 `dryRun=true`；Release UI 不显示 dry-run/仅预览开关，用户在共享确认页明确选择“移到废纸篓”后才生成真实执行授权。自动化测试默认 dryRun；需要验证真实 recycle 时只能使用 `NSTemporaryDirectory()` 下的隔离 fixture。
3. **三色判定后才能删**：删除前必须经过 [SafetyEngine.evaluate](Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) 的 `safe / confirm / forbid` 三色。普通模式的 `forbid` 一律拒绝；专业模式只有命中显式可覆盖 reason、取得类型化授权并完成严格确认后才能尝试。`hardForbid` 与结构性边界永不可覆盖。
4. **批级原子拒绝**：普通请求中任意一条命中 `forbid`，整批拒绝并提示用户，不允许"删一半再回滚"。专业覆盖请求必须先把 normal / override-eligible / non-bypassable 分区并分别确认；执行前出现任意新的 non-bypassable 路径时整批拒绝。
5. **确认上下文完整性**：类型化删除授权必须绑定精确路径、来源、扫描 revision、风险 reason 和用户选择；确认后路径身份变化或风险增加必须重新预检。历史 HMAC/XPC 设计不再属于当前链路。
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

- Helper（v1 不启用，留 v2）走 `NSXPCListener`，`mach service` 名字写死 `com.amux.ai.Clean.helper`
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
  4. 命中 VendorTrie 路径前缀（vendors.yaml 展开后）-> `forbid / vendorPathRule`；普通模式拒绝，专业模式只能通过类型化严格覆盖请求尝试
  5. 默认 `confirm`，UI 必须用户勾选才会进 deletion 队列
- 卸载残留路 [AppUninstaller](Packages/AppUI/Sources/AppUI/AppUninstaller.swift) 候选必须再过一次 SafetyEngine
- Orphan 反扫 [OrphanScanner](Packages/AppUI/Sources/AppUI/OrphanScanner.swift) 多一道 mtime ≥ 30 天 + bundleID 注销 + appName 不在装机列表

### 专业模式覆盖边界

`SafetyVerdict.forbid` 表示普通删除不可提交，但不同 `SafetyRejection` 的安全含义不同；专业模式不能继续用一个裸 `Bool force` 一刀切。

- **永不可覆盖**：relative/empty path、`..`、`/`、HOME/Library/Documents/Desktop/Downloads 等整根、HOME 外路径、系统卷、hardForbid prefix、symlink 解析后越界、不可解释的路径身份变化。
- **可严格覆盖**：当前只允许由生产预检铸造的 `vendorPathRule` 类型化授权；其它产品策略必须逐类加入显式 allowlist 和测试，禁止字符串 contains 判断。
- **扫描不完整**：`incomplete` 是证据质量，不是 OS 删除权限。专业模式可在目标级 `lstat + resolved scope + parent write/search` 重验、展示“内容未完整检查”并严格确认后尝试移动整个目标；它不得被统一映射成 Full Disk Access。
- **真实 OS 权限**：TCC、POSIX owner/mode、ACL、immutable flag 必须保留来源。当前无 root helper，不能承诺绕过；`NSWorkspace.recycle` 返回失败时如实展示。
- **能力不可伪造**：覆盖授权必须绑定精确路径、精确 reason、扫描 revision 和确认上下文，执行前重新跑 Safety/路径解析。裸 `[String]` 回调和与 normal 等价的空心 `.force` 不构成授权。
- **统一交互**：完整状态机见 [DELETION_UX_CONTRACT.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/DELETION_UX_CONTRACT.md)。预检拒绝不能包装成执行结果，结果页不能承担首次授权。

---

## 4. 数据持久化、隐私与待决网络边界

本地扫描和删除链路不需要网络，也不得因网络状态改变安全判定。当前源码已存在可选远程 AI/自动更新方向，但它与项目原“完全离线/禁止 HTTP”定位冲突；该 P1 已由用户明确暂缓，本次审计不擅自放宽规则，也不再把现状描述成“已确认完全离线”。在形成单独决策前：

- 禁止新增或扩大网络请求；
- 必须先定义允许的域名、显式用户授权、发送数据范围、超时/取消、凭据保存和审计日志；
- 远程结果永远不能提高删除安全等级或绕过本地 `SafetyEngine`；
- 不收集遥测、不上报崩溃
- 唯一持久化文件：
  - `~/Library/Application Support/AmuxAIClean/heuristic.json`：仅存 bundleID 维度的 `(deleted, restored, kept)` 三元组计数，无路径
  - `~/Library/Preferences/com.amux.ai.Clean.plist`：UI 偏好（窗口大小、阈值等）
- 不读取剪贴板、不读取通讯录、不读取浏览器历史

---

## 5. v1 已知不防的攻击面（透明）

- 当前正式候选使用 Developer ID 签名，并只提交最终 DMG 公证；Notary、staple、Gatekeeper 与 SHA256 能证明来源和字节完整性，但不能证明业务逻辑没有缺陷
- 本地构建/公证与上传 GitHub 是两个独立授权边界；安全文档不得假设 GitHub Releases 是唯一或默认分发渠道
- v1 不启用 Helper -> 受 TCC 限制读不到的目录扫不到，这是预期；不会通过任何"曲线救国"绕过 TCC
- vendors.yaml 在 bundle 内只读，但用户如果自己 mod app 资源后果自负

---

## 6. 漏洞上报

如果你发现了**绕过 typed deletion intent / SafetyEngine / TrashPipeline 导致未授权移动**或**导致 SafetyEngine 错判**的漏洞，请：

- 不要公开 issue
- 发邮件到 `guoshuyu.gh@gmail.com`，标题前缀 `[SECURITY]`
- 包含：复现步骤、影响范围、建议修复方向
- 我会在 7 天内回复，确认后 30 天内发补丁

非安全 bug、误命中、性能问题请走正常 GitHub Issue。

---

## 7. 红线汇总（对开发者）

新增/修改代码时必须自检：

1. 没引入 `unlink` / `removeItem(at:)` 删除候选路径
2. 新增删除请求在执行层默认走 dryRun；Release UI 不显示 dry-run/仅预览开关
3. 新加规则跑 RuleLoader 反向校验过 hardForbid
4. 新加候选源（如 v2 增加 LaunchAgents 扫描）必须再过 SafetyEngine
5. 测试不允许通过减少断言来"修绿"
6. UI 上"危险操作"按钮必须用 `.destructive` role + 二次确认 sheet
7. 不允许 `try?` 静默吞错（错误必须 log 或上抛）
