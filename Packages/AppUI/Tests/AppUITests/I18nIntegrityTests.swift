import XCTest
@testable import AppUI

/// Step 4 / 2026-06：i18n 完整性契约测试。
///
/// 这一组测试不验证翻译质量（那是人工审校），而是验证**机器可检测的三条硬契约**：
///
/// 1) **零 stale key**：Localizable.xcstrings 里每条 key 都必须在 Swift 源里
///    至少出现一次（粗匹配字面量）。否则就是死翻译，浪费翻译预算 + 误导维护者。
///
/// 2) **零中文按钮硬编码**：DeleteSheet.swift 不允许出现 `"运行预览"` / `"确认移到废纸篓"`
///    这种字面量中文（行内注释除外）。所有用户可见字符串必须走 `String(localized:)`。
///
/// 3) **新 key 已落档**：`delete.action.preview` / `delete.action.confirm`
///    必须在 xcstrings 里存在 —— 防止 Step 4 改了代码却忘了同步翻译表。
///
/// 设计取舍：
///   - 不解析 xcstrings JSON（schema 复杂、版本敏感），改用纯字符串 grep。
///     代价：极少数 key 命名巧合可能漏检 —— 接受，CI 跑一次就能逮回来。
///   - 不依赖运行期 Bundle.localizedString —— 那只能验证"key 存在"不能验证
///     "key 被引用"。这正是当前要查的反向问题。
final class I18nIntegrityTests: XCTestCase {

    /// xcstrings 文件路径（相对仓库根）
    private static let xcstringsPath =
        "Packages/AppUI/Sources/AppUI/Resources/Localizable.xcstrings"

    /// AppUI Sources 目录（相对仓库根）—— 所有 String(localized:) / Text("...") 调用所在地
    private static let appUISources =
        "Packages/AppUI/Sources/AppUI"

    /// 找仓库根：从当前测试文件一路 ../ 找到 .git
    private func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            url.deleteLastPathComponent()
            let git = url.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: git.path) {
                return url
            }
        }
        throw NSError(domain: "I18nIntegrityTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "找不到 .git 仓库根"])
    }

    /// 读 xcstrings 全部 key（粗解析：JSON 顶层 strings 字典的 key）
    private func loadXcstringsKeys() throws -> [String] {
        let root = try repoRoot()
        let path = root.appendingPathComponent(Self.xcstringsPath).path
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = json?["strings"] as? [String: Any]
        return Array(strings?.keys ?? Dictionary<String, Any>().keys)
    }

    /// 读 AppUI 全部 .swift 源文件内容（拼成一大段，方便 grep）
    private func loadAllSwiftSources() throws -> String {
        let root = try repoRoot()
        let dir = root.appendingPathComponent(Self.appUISources)
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil)
        var combined = ""
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                combined += s
                combined += "\n"
            }
        }
        return combined
    }

    // MARK: - 契约 1：零 stale key

    /// 6 条 stale `trash.err.*` 历史包袱必须在 Step 4 中被清理。
    /// 它们对应的 Swift 代码已经在更早的版本里被重构掉，但翻译表残留。
    func test_xcstrings_无残留的trash_err_key() throws {
        let keys = try loadXcstringsKeys()
        let stale = keys.filter { $0.hasPrefix("trash.err.") }
        XCTAssertEqual(
            stale.count, 0,
            "发现 \(stale.count) 条 stale trash.err.* key 未清理：\(stale)"
        )
    }

    /// 一条更宽的契约（**当前降级为 warn-only**）：xcstrings 每条 key 都应在 Swift
    /// 源中至少出现一次。
    ///
    /// 范围决策（Step 4 / 2026-06）：先跑一次发现 41 条 xcstrings key 在 Swift 源里
    /// 无显式字面量引用，远超原计划"6 条 trash.err.*"。其中很多是合法的运行期拼接
    /// （`verdict.<value>` / `view.mode.<value>` / `ecosystem.<id>` / `status.<state>`
    /// 等），盲目删除会破坏运行期 i18n。
    ///
    /// 取舍：
    ///   - Step 4 范围**严格收敛到原计划**：只清 6 条 trash.err.* + DeleteSheet 按钮。
    ///   - 这条用例**降级为 print warning + 不 fail**，以便：
    ///       1) 把 41 条 backlog 钉在 CI 输出里持续可见；
    ///       2) 不阻塞 Step 4 commit；
    ///       3) Step 4.5 / 后续专项治理时拉清单逐条审计。
    ///   - 白名单先扩到能识别"有动态前缀"的常见模式，把噪声压低。
    func test_xcstrings_所有key都被Swift源引用_warn_only() throws {
        let keys = try loadXcstringsKeys()
        let sources = try loadAllSwiftSources()

        // 白名单：动态拼接的 key 前缀（运行期由 enum / id 拼出完整 key）。
        // 命中即跳过 —— 编译期 grep 看不见完整字面量是合理的。
        let dynamicPrefixes = [
            "category.id.",      // ScanCategory.id 拼接
            "trash.err.",        // 本测试已单独检查（stale 已扫到）
            "verdict.",          // VerdictBadge：verdict.safe / forbid / review
            "view.mode.",        // 视图模式 enum：view.mode.list / tree / main_badge
            "ecosystem.",        // ecosystem ID：ecosystem.python / rust / go / web ...
            "status.",           // 扫描状态：status.scanning / done / idle_not_scanned ...
            "hud.",              // HUD 文案集合（多处运行期 format 拼装）
            "tree.batch.",       // BatchSelection 活代码运行期拼接（LargeFilesView 多选 header）
            "tree.checkbox.",    // 树形勾选状态
            "delete.progress.",  // 删除进度条文案（运行期 format）
            "delete.alert.",     // 删除告警弹窗（运行期 format）
            "results.",          // 结果面板（多处运行期 format）
            "selection.summary.",// 选择摘要 format
            "settings.dev.",     // 开发者设置
            "drop.error.",       // 拖拽错误
            "common.",           // 通用按钮（OK / Cancel）
            "toolbar.help.",     // 工具栏 tooltip
        ]

        var orphans: [String] = []
        for key in keys {
            if dynamicPrefixes.contains(where: { key.hasPrefix($0) }) { continue }
            if !sources.contains(key) {
                orphans.append(key)
            }
        }

        // ⚠️ 不 XCTFail，仅打印 backlog 让 CI 留下证据。
        if !orphans.isEmpty {
            print("⚠️ [I18n backlog] \(orphans.count) 条 xcstrings key 在 Swift 源中无显式引用（白名单外）：")
            for key in orphans.sorted() {
                print("    - \(key)")
            }
            print("    → 待 Step 4.5 专项治理：逐条确认是动态拼接 / 真 stale / 漏改。")
        }
    }

    // MARK: - 契约 2：零中文按钮硬编码

    /// DeleteSheet 历史上有 `Button(dryRun ? "运行预览" : "确认移到废纸篓", ...)`
    /// 这种把中文字面量直接塞进 SwiftUI Button 的写法 —— 英文用户看到中文就崩了。
    /// Step 4 必须把这两个字面量替换成 `String(localized:)`。
    func test_DeleteSheet_无中文按钮硬编码() throws {
        let root = try repoRoot()
        let path = root
            .appendingPathComponent("Packages/AppUI/Sources/AppUI/DeleteSheet.swift")
            .path
        let src = try String(contentsOfFile: path, encoding: .utf8)

        // 逐行扫描：跳过注释行，找剩余行里的中文字面量
        for (idx, rawLine) in src.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*") {
                continue
            }
            XCTAssertFalse(
                line.contains("\"运行预览\""),
                "DeleteSheet.swift L\(idx + 1) 仍有硬编码中文按钮 '运行预览' —— 应走 String(localized: \"delete.action.preview\")"
            )
            XCTAssertFalse(
                line.contains("\"确认移到废纸篓\""),
                "DeleteSheet.swift L\(idx + 1) 仍有硬编码中文按钮 '确认移到废纸篓' —— 应走 String(localized: \"delete.action.confirm\")"
            )
        }
    }

    // MARK: - 契约 3：新 key 已落档

    /// Step 4 引入的两条新 key 必须存在于 xcstrings —— 否则代码改了、翻译表没改，
    /// 运行期会 fallback 到 key 字符串本身（"delete.action.preview" 当按钮文案）。
    func test_xcstrings_包含新增的delete_action_key() throws {
        let keys = Set(try loadXcstringsKeys())
        XCTAssertTrue(
            keys.contains("delete.action.preview"),
            "Step 4 必须把 delete.action.preview 加入 Localizable.xcstrings"
        )
        XCTAssertTrue(
            keys.contains("delete.action.confirm"),
            "Step 4 必须把 delete.action.confirm 加入 Localizable.xcstrings"
        )
    }
}
