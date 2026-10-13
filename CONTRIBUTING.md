# 贡献指南 - AmuxAIClean

感谢愿意贡献。这份文档说明开 PR 前必须做的事、commit 规范、PR 红线。在写代码前请先读：

1. [PITFALLS.md](PITFALLS.md)：本项目踩过的所有坑，特别是涉及 APFS / TCC / firmlinks / NSXPC 的红线
2. [SECURITY.md](SECURITY.md)：安全模型与红线
3. [docs/ROADMAP_V1.md](docs/ROADMAP_V1.md)：v1.0 范围与验收

---

## 1. 开发环境

- macOS 15 Sequoia 或更高（开发机工具链要求；产品部署下限为 macOS 13.5）
  <!-- v2026.07.16：保留 Swift 6/Xcode 16 的统一开发环境，同时避免把它误写成用户安装下限。 -->
- Xcode 16+
- Homebrew（可选，只在装 `xcbeautify` 装饰输出或 `create-dmg` 打 DMG 时需要；**不再需要 xcodegen** —— v1.5.x 起原生 [AmuxAIClean.xcodeproj](AmuxAIClean.xcodeproj) 已入仓）

```bash
git clone https://github.com/CarGuo/AmuxAIClean.git
cd AmuxAIClean
./Scripts/setup_dev.sh
```

---

## 2. 工作流

1. 从 `main` fork & branch（命名：`fix/xxx`、`feat/xxx`、`chore/xxx`、`docs/xxx`）
2. 每个 PR 只解决一件事，避免大 PR
3. **写代码前先写测试**或同步增加测试（红线见下文）
4. 本地跑通全部 9 个包的单测（v1.5.x 起 XPCBridge 已下线，新增 BrewKit / FileSearchKit / AIKit）：

   ```bash
   for pkg in ScanKit SafetyKit AppUI HeuristicKit LogKit BrewKit FileSearchKit AIKit TestHarness; do
     (cd "Packages/$pkg" && swift test) || exit 1
   done
   ```

5. 跑通 xcodebuild Debug：

   ```bash
   xcodebuild -scheme AmuxAIClean -configuration Debug \
     CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
     -derivedDataPath build/dd build
   ```

6. 提交 PR 前保留本地测试与构建摘要。当前 GitHub Actions job 全部显式停用，不能把
   Actions 页面或“未运行”状态当作质量证据；恢复 CI 前以 `AGENTS.md` 完成门槛为准。

---

## 3. PR 红线（违反一律 close）

按重要性递减：

1. **不允许新增 unlink / removeItem(at:)**：任何"删除候选"路径必须走 [TrashPipeline](Packages/AppUI/Sources/AppUI/TrashPipeline.swift) -> NSWorkspace.recycle
2. **不允许削弱已有测试**：删测试、把断言改成 `XCTAssertTrue(true)`、改 expected 值"修绿"一律 reject。如果测试本身有 bug，必须先在 PR 描述里说明判据，再修测试
3. **不允许默认 dryRun=false**：新加的删除路径默认必须 dryRun
4. **不允许 try?**：错误必须 log 或上抛；如果确实想忽略，必须写注释说明为什么
5. **不允许抄竞品源码**：可以参考思路、读 commit message，但不能复制粘贴有 license 限制的代码（特别是 GPL 项目如 ncdu）
6. **不允许在 actor / Sendable 上偷懒**：Swift 6 strict concurrency 必须严格满足，warnings-as-errors 不能放过
7. **新加 vendor 规则必须有 BundleID 严格前缀**：不允许只用 appName 模糊匹配
8. **新加 hardForbid 路径必须有真实事故来源链接**：不允许"我觉得这条路径危险"就加进去
9. **不允许新增或扩大网络请求**：当前只允许 GitHub Release 更新检查，以及默认关闭、
   用户主动发起的 OpenAI-compatible AI 请求。任何新 host、触发方式、发送字段或后台重试
   都必须先定义用户授权、HTTPS/loopback 边界、超时取消、凭据、日志脱敏、隐私披露和测试；
   AI base URL 不得携带 userinfo/query/fragment，客户端不得跟随 redirect；远程结果不得改变
   SafetyEngine verdict、默认勾选或删除授权。网络卷/FileProvider/Quick Look 的系统代办读取
   也必须在隐私合同中单独披露，不能把“仅两类 App HTTP”写成“整个扫描绝不联网”

---

## 4. Commit 规范

格式：

```
<type>(<scope>): <subject>

<body>

<footer>
```

`type` 取值：

- `feat`：新功能
- `fix`：bug 修复
- `docs`：文档
- `test`：仅改测试
- `refactor`：重构（不改外部行为）
- `perf`：性能优化
- `chore`：构建脚本 / CI / 依赖
- `style`：代码格式

`scope`：包名或模块名，例如 `scankit`、`safetykit`、`appui`、`uninstaller`、`ci`、`docs`。

示例：

```
feat(scankit): BulkScanner 多 worker 并行（4~6 worker work-stealing）

- actor DirQueue + inFlight 计数 + stack 双判定终止
- worker_count = min(activeProcessorCount, 6)，cap=6
- 跨卷停下钻：lstat 取 root.dev_t，子目录 dev != root.dev 不入队
- 5 条新并发测试覆盖饥饿/漏扫/staySingleVolume/actualConcurrency cap

参考：Pearcleaner v5 / DaisyDisk / OmniDS 业界甜点 N=4~6
```

---

## 5. Bug 报告模板

提 issue 时请尽量包含：

```
## 环境
- macOS 版本：例如 15.2
- Mac 型号：例如 M2 Pro
- AmuxAIClean 版本：例如 v1.1.0
- 是否授予完全磁盘访问：是 / 否

## 复现步骤
1. ...
2. ...
3. ...

## 期望表现
...

## 实际表现
...

## 日志 / 截图
（可附 App 内“在 Finder 中显示日志”导出的本地文件；若文件 sink 不可用，可在
Console.app 中过滤当前 subsystem `com.amux.ai.Clean`，并附上界面显示的
`stage / domain / code`。请先移除不愿公开的路径或用户名。）
```

如果是**误命中类**（建议删了不该删的）：请额外注明被建议删除的路径、命中规则名（截图 MatchReason 行）、对应 app 的 bundleID。

---

## 6. 行为守则

- 友善、专业、就事论事
- 不接受人身攻击 / 政治议题 / 非技术冲突
- 维护者保留 close issue / lock 讨论的最终解释权
