# 使用条款 / Terms of Use

最后更新：2026-06-06
适用版本：GSYCleanMac v1.5.6+

## 0. 接受条款

下载、安装或运行 GSYCleanMac 即表示你已阅读并同意本条款。如不同意，请勿安装或立即卸载（卸载方式见 [README.md](README.md)）。

## 1. 许可协议

GSYCleanMac 基于 **MIT License** 发布，完整许可文本见仓库根目录 [LICENSE](LICENSE)。

> 简要说明：你可以免费使用、复制、修改、合并、出版、分发、再授权及/或销售本软件副本，唯一的要求是在所有副本中保留原版权声明与本许可声明。

## 2. 软件性质

- GSYCleanMac 是一款本地 macOS 清理 / 优化工具
- 完全在用户本机运行，不依赖任何服务端
- 不收取费用，不内购，无广告
- 详细隐私政策见 [PRIVACY.md](PRIVACY.md)

## 3. 免责声明（重要 —— 请务必阅读）

### 3.1 删除操作不可完全逆转

GSYCleanMac 提供的删除功能：

| 删除方式 | 可恢复性 |
|---|---|
| **移入废纸篓**（默认） | 在你「清倒废纸篓」之前可通过「最近删除」面板或 Finder 还原 |
| **直接抹除**（高级，需双重确认） | **不可逆**，等同于 `rm -rf`，文件系统层面立刻释放 |

**一旦你选择了「直接抹除」并完成二次确认，被删除的文件无法通过本软件或任何常规手段恢复。** 请务必：

1. 重要数据先做 Time Machine / 云盘备份
2. 优先使用「移入废纸篓」模式
3. 删除前认真核对预览列表
4. 不要在没有备份的情况下勾选「直接抹除」

### 3.2 启发式扫描的局限

GSYCleanMac 的「可清理项」基于公开的、社区维护的 [Vendor Rules](Packages/CleanMacKit/Resources/vendor-rules.json) 和启发式规则推断，**无法保证 100% 准确**：

- 极少数情况下可能把仍在使用的缓存识别为可清理
- 第三方 App 的私有数据格式如发生变化，旧规则可能误判
- 用户自定义路径完全由用户决定，软件不做合理性校验

**因此，所有删除前的最终判断责任在用户，软件仅做建议性提示。**

### 3.3 系统兼容性

- 仅支持 macOS 15 Sequoia 或更高
- 在 macOS 14 及以下版本运行行为未定义，可能扫描结果异常或崩溃
- 不支持 iOS / iPadOS / visionOS / watchOS / tvOS

### 3.4 "AS IS" 条款（与 MIT 一致）

本软件按"现状"提供，**不附带任何明示或暗示的担保**，包括但不限于：

- 适销性（merchantability）
- 适用于特定用途（fitness for a particular purpose）
- 不侵权（non-infringement）

**在任何情况下，作者或版权持有人均不对任何索赔、损害或其他责任负责**，无论该等责任源于合同、侵权或其他原因，亦无论是否源于、起因于或与本软件或其使用或交易有关。这包括但不限于：

- 因误删文件造成的数据丢失
- 因清理系统缓存导致第三方 App 短暂异常
- 因停止维护、不再更新导致的兼容性问题
- 因 macOS 更新导致功能不可用
- 任何形式的间接损失、利润损失、业务中断

## 4. 用户责任

使用本软件即表示你确认：

- ✅ 你拥有被扫描磁盘上数据的合法访问权
- ✅ 你已理解删除操作的不可逆性并自行承担风险
- ✅ 你不会在生产服务器、关键业务系统上未经备份地运行删除操作
- ✅ 你已知晓本软件不附带商业级 SLA、不保证 7×24 可用
- ✅ 你不会将本软件用于任何违反所在地法律法规的目的

## 5. 第三方内容

- App 内未嵌入任何第三方静态库、动态库或 Swift Package
- 检查更新功能访问 GitHub Releases API，使用即表示同意 [GitHub 服务条款](https://docs.github.com/en/site-policy/github-terms/github-terms-of-service)

## 6. 商标

- "GSYCleanMac" 仅为项目名称，无商标注册
- "macOS"、"Apple"、"Finder"、"Sequoia"、"Apple Silicon" 等是 Apple Inc. 的注册商标，本项目仅做指称性使用，与 Apple Inc. 无任何关联或背书

## 7. 终止

你可以随时通过卸载本软件终止本条款；作者保留随时停止维护、归档项目的权利，停止维护后已分发版本仍按本条款继续可用。

## 8. 适用法律

本条款的解释和执行不指定特定司法管辖区。如使用本软件产生争议，应在用户所在地依据当地法律解决，作者不承担跨境诉讼成本。

## 9. 联系方式

技术问题与改进建议：请通过 GitHub Issues 提交。

---

**English Summary**

GSYCleanMac is released under the MIT License and provided "AS IS" without warranty of any kind. **Deletion is irreversible** when "Direct Erase" mode is chosen — back up first. You are solely responsible for verifying scan results before deleting any file. The author is not liable for any data loss or consequential damages. By installing the software you accept these terms.
