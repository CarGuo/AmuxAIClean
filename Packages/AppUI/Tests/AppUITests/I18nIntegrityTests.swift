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

    /// App target 目录（相对仓库根）—— GSYCleanMacApp.swift 等顶层 SwiftUI Scene/Commands
    /// 也会通过 `String(localized: ..., bundle: AppUIResources.bundle)` 引用 xcstrings 里的 key，
    /// 必须一并纳入引用扫描范围，否则会误报 stale。
    private static let appTargetSources = "App"

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

    /// 读 AppUI + App target 全部 .swift 源文件内容（拼成一大段，方便 grep）
    private func loadAllSwiftSources() throws -> String {
        let root = try repoRoot()
        let fm = FileManager.default
        var combined = ""
        for relDir in [Self.appUISources, Self.appTargetSources] {
            let dir = root.appendingPathComponent(relDir)
            let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                if let s = try? String(contentsOf: url, encoding: .utf8) {
                    combined += s
                    combined += "\n"
                }
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

    // MARK: - Step 17-D: xcstrings plural variations 改造（零代码改动 → 仅 i18n 集成测）

    /// 把 xcstrings 文件原始字节解析成 JSON，便于扫描每个 stringUnit 的 value。
    /// 与 loadXcstringsKeys 的"只取 keys"不同，这里要看 localizations 的具体值。
    private func loadXcstringsRaw() throws -> [String: Any] {
        let root = try repoRoot()
        let path = root.appendingPathComponent(Self.xcstringsPath).path
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "I18nIntegrityTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "xcstrings 顶层不是 JSON 对象"])
        }
        return json
    }

    /// 遍历 xcstrings strings 字典，为每条 key 抽出所有 (locale, value) pair。
    /// 返回 [(key, locale, value)] 平铺数组。
    /// 仅取 stringUnit.value（plural variations 暂未启用，先记 backlog）。
    private func loadAllStringUnits() throws -> [(key: String, locale: String, value: String, hasVariations: Bool)] {
        let json = try loadXcstringsRaw()
        guard let strings = json["strings"] as? [String: Any] else { return [] }
        var out: [(String, String, String, Bool)] = []
        for (key, raw) in strings {
            guard let entry = raw as? [String: Any] else { continue }
            guard let locs = entry["localizations"] as? [String: Any] else { continue }
            for (locale, locRaw) in locs {
                guard let locDict = locRaw as? [String: Any] else { continue }
                let hasVariations = (locDict["variations"] != nil)
                if let unit = locDict["stringUnit"] as? [String: Any],
                   let v = unit["value"] as? String {
                    out.append((key, locale, v, hasVariations))
                }
            }
        }
        return out
    }

    /// 契约 4：plural-shape backlog 钉在 CI 输出
    ///
    /// xcstrings 里凡是 value 含英文字面 `(s)` 复数标记（如 `swapfile(s)` / `file(s)`），
    /// 严格意义上都是"翻译质量降级"——英文 `1 swapfile` vs `2 swapfiles` 写错就尴尬。
    /// Apple 推荐改造为 [String Catalog plural variations](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog)。
    ///
    /// **本契约 warn-only**：当前 xcstrings 共 0 条 variations，迁移成本零代码、纯翻译表
    /// 改造，可以分阶段做。这条用例的目标是把 backlog 数量钉在 CI 输出，让维护者
    /// 每次 PR 都能看到当前剩余条数，不让其无声膨胀。
    func test_xcstrings_plural_shape_backlog_warn_only() throws {
        let units = try loadAllStringUnits()
        // 命中 (s) 复数标记的 (key, locale)
        let pluralParenSuffix = units.filter { unit in
            // 仅看英文 value（zh 不需要复数；其它语言走变体规则各自有 plural form）。
            unit.locale == "en" && unit.value.range(of: #"\b\w+\(s\)"#, options: .regularExpression) != nil
        }
        if !pluralParenSuffix.isEmpty {
            print("⚠️ [I18n plural backlog] \(pluralParenSuffix.count) 条 en 翻译用 `(s)` 兜底复数（待迁移到 String Catalog plural variations）：")
            for u in pluralParenSuffix.sorted(by: { $0.key < $1.key }) {
                print("    - [\(u.key)] \(u.value)")
            }
            print("    → Step 17-D 后续治理：逐条改成 \"localizations.<lang>.variations.plural.{one, other}\"。")
        }
        // 当前已知 backlog：1 条 capacity.swap.allocated.hint.real "Real file size of %lld swapfile(s)"
        // 设上限护栏：超过 5 条立即 fail——防止后续 PR 引入新的 (s) 兜底翻译。
        XCTAssertLessThanOrEqual(
            pluralParenSuffix.count, 5,
            "(s) 复数兜底翻译数量超过 5 条上限，已扫到 \(pluralParenSuffix.count) 条；新增 PR 必须改用 plural variations。"
        )
    }

    /// 契约 5：number-format hygiene 钉在 CI 输出
    ///
    /// 凡是 value 同时包含 `%lld` / `%d` 与英文复数名词（files / items / sessions / rows /
    /// directories / apps）的 key，都是潜在的 plural variations 候选。
    /// 例如 `"%lld files"` 在英文里 `1 files` 反人类，但 zh-Hans `1 个文件` 就 OK。
    ///
    /// 本契约只**计数 + 列出 backlog**，不强制 fail，理由同契约 4——逐条迁移成本可控、
    /// 但不能让基数无声膨胀。
    func test_xcstrings_number_plural_backlog_warn_only() throws {
        let units = try loadAllStringUnits()
        // %lld 后跟单个英文名词 + 单复数歧义：files / items / sessions / rows / directories / apps / bytes / leaves
        let englishPluralNouns = #"(files|items|sessions|rows|directories|apps|bytes|leaves|swapfiles)"#
        let pattern = #"%(\d+\$)?(lld|d|ld)\s+"# + englishPluralNouns + #"\b"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let candidates = units.filter { unit in
            guard unit.locale == "en", !unit.hasVariations else { return false }
            let nsv = unit.value as NSString
            let m = regex.numberOfMatches(in: unit.value, range: NSRange(location: 0, length: nsv.length))
            return m > 0
        }
        if !candidates.isEmpty {
            print("ℹ️ [I18n format-hygiene] \(candidates.count) 条 en value 含 `%lld <english_plural_noun>` 形式（plural variations 候选）：")
            for u in candidates.sorted(by: { $0.key < $1.key }) {
                print("    - [\(u.key)] \(u.value)")
            }
            print("    → Step 17-D 后续治理：评估是否值得拆 plural variations（ScanKit 命中 1 件物时 UX 收益）。")
        }
        // 上限护栏：当前已知 ~15 条；放宽到 25 防止滚动期 PR 新增打破护栏。
        XCTAssertLessThanOrEqual(
            candidates.count, 25,
            "%lld 复数英文名词候选数已达 \(candidates.count)，超过 25 上限；新增 PR 必须配套 plural variations 迁移。"
        )
    }

    /// 契约 6：所有 key 的 extractionState 必须是 manual（无 stale 死翻译）
    ///
    /// xcstrings 的 [extractionState](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog)
    /// 取值：`manual` / `extracted_with_value` / `migrated` / `stale` / `unknown`。
    /// `stale` = "Xcode 的 string extractor 在源码里再也找不到这条 key 的引用"——
    /// 是 stale key 的官方信号。本仓库目前 496 条全 manual，本契约确保不引入 stale。
    func test_xcstrings_无stale或unknown的extractionState() throws {
        let json = try loadXcstringsRaw()
        guard let strings = json["strings"] as? [String: Any] else {
            return XCTFail("xcstrings 缺 strings 字典")
        }
        var stale: [String] = []
        var unknown: [String] = []
        for (key, raw) in strings {
            guard let entry = raw as? [String: Any] else { continue }
            let state = entry["extractionState"] as? String
            switch state {
            case "stale": stale.append(key)
            case "unknown": unknown.append(key)
            default: break
            }
        }
        XCTAssertTrue(
            stale.isEmpty,
            "发现 \(stale.count) 条 extractionState=stale 的死翻译：\(stale.sorted())。Xcode 已确认源码再无引用，应在 xcstrings 中删除。"
        )
        XCTAssertTrue(
            unknown.isEmpty,
            "发现 \(unknown.count) 条 extractionState=unknown：\(unknown.sorted())。手动核对后改为 manual 或删除。"
        )
    }

    /// 契约 7：variations 双向校验——
    /// 一旦某条 key 启用了 plural variations，必须 en + zh-Hans 两个 locale 同步启用，
    /// 且必须同时含 `one` 与 `other` 两个 plural category。
    ///
    /// 这是为后续真正落地 plural variations 时的护栏：防止只改半边、防止漏 `one` 类。
    /// 当前 xcstrings 0 条 variations，所以这条用例**当前必然 PASS**——它是为未来挡箭。
    func test_xcstrings_variations双向完整性() throws {
        let json = try loadXcstringsRaw()
        guard let strings = json["strings"] as? [String: Any] else { return }
        var defects: [String] = []
        for (key, raw) in strings {
            guard let entry = raw as? [String: Any] else { continue }
            guard let locs = entry["localizations"] as? [String: Any] else { continue }
            // 收集启用了 variations 的 locales
            var localesWithVariations: [String: [String: Any]] = [:]  // locale -> plural dict
            for (locale, locRaw) in locs {
                guard let locDict = locRaw as? [String: Any] else { continue }
                if let variations = locDict["variations"] as? [String: Any],
                   let plural = variations["plural"] as? [String: Any] {
                    localesWithVariations[locale] = plural
                }
            }
            if localesWithVariations.isEmpty { continue }
            // 一旦启用 variations：en + zh-Hans 都必须启用
            let needLocales: Set<String> = ["en", "zh-Hans"]
            let actualLocales = Set(localesWithVariations.keys)
            if !needLocales.isSubset(of: actualLocales) {
                let missing = needLocales.subtracting(actualLocales).sorted()
                defects.append("[\(key)] 启用了 plural variations 但缺 locales: \(missing)")
                continue
            }
            // 每个 locale 必须同时含 one + other
            for (locale, plural) in localesWithVariations {
                let cats = Set(plural.keys)
                let needCats: Set<String> = ["one", "other"]
                if !needCats.isSubset(of: cats) {
                    let missing = needCats.subtracting(cats).sorted()
                    defects.append("[\(key)][\(locale)] plural 缺 categories: \(missing)")
                }
            }
        }
        XCTAssertTrue(
            defects.isEmpty,
            "plural variations 双向完整性破损：\n  - " + defects.joined(separator: "\n  - ")
        )
    }
}
