# GitHub Copilot / Coding Agent 指令

> **本文件只是指针**。所有规则的**唯一权威**是仓库根的 [AGENTS.md](../AGENTS.md)。
> Copilot / Cursor / Claude Code / Trae 等任何 AI coding agent 在此仓库开工前，**必须先完整读一遍 [AGENTS.md](../AGENTS.md)**，本文件不重复其内容以避免双份维护漂移。

## 快速指引

- 项目形态、命令、编码约定、三层边界（Always / Ask first / Never）→ [AGENTS.md](../AGENTS.md)
- 前人踩过的坑（修 bug 前必读）→ [PITFALLS.md](../PITFALLS.md)
- 威胁模型 / 安全红线 → [SECURITY.md](../SECURITY.md)
- PR 规范 / commit 规范 → [CONTRIBUTING.md](../CONTRIBUTING.md)
- 开发环境 / 签名 / 目录结构 → [docs/DEVELOPMENT.md](../docs/DEVELOPMENT.md)

## 五条最关键的硬红线（详见 AGENTS.md §7）

1. 删除**永远**走 [TrashPipeline](../Packages/AppUI/Sources/AppUI/TrashPipeline.swift) → `NSWorkspace.recycle`，**禁止 `unlink(2)` / `FileManager.removeItem(at:)`**。
2. 新增删除路径**默认 `dryRun=true`**。
3. **零网络**是 hard rule，禁止引入任何 HTTP / telemetry / crash report 请求。
4. **不许为过测试改需求**，测试红了先改代码；测试本身有 bug 需先在 PR 描述里说明判据再改。
5. 用户可见字符串**从第一个字符起就走** [Localizable.xcstrings](../Packages/AppUI/Sources/AppUI/Resources/Localizable.xcstrings)，禁止硬编码中/英文字面量。

## 有疑问时

不要猜，先问用户。参考 [AGENTS.md §8](../AGENTS.md) 的第一性原理思维方式：目标模糊时停下讨论，不假设用户已知全部目标。
