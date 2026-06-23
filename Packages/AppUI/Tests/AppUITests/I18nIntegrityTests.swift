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

    /// 兄弟包根目录 —— ScanKit / AIKit / BrewKit / SafetyKit / FileSearchKit / HeuristicKit /
    /// LogKit / TestHarness 等子包里大量声明 `WorkflowCard.title/summary = "card.xxx.title"`
    /// 等 i18n key 字面量。若不纳入扫描，会把这些活引用全部误报为 stale。
    private static let siblingPackagesRoot = "Packages"

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

    /// 读 AppUI + App target + 所有兄弟包 Sources 的全部 .swift 源文件内容（拼成一大段，方便 grep）
    ///
    /// **范围决策（2026-06-21 修订）**：旧实现只扫 AppUI + App，导致 ScanKit / AIKit 等
    /// 子包里以字面量声明的 i18n key（如 `WorkflowCard.title = "card.apple.archives.title"`）
    /// 被全部误判为 stale，把 backlog 从真实的 ~10 条膨胀到 75 条。
    /// 现在改为递归扫整个 `Packages/` 目录下所有 `.swift`，但排除：
    ///   - 所有 `Tests/` 目录（避免测试夹具里的样例字面量自污染）；
    ///   - SwiftPM `.build/` 构建产物 + 第三方 `checkouts/` 签出（如 GRDB.swift 的 DemoApps，
    ///     里面的 `"category.foo.bar"` 字面量可能与我们 i18n key 巧合命中，造成 false negative
    ///     掩盖真 stale；硬失败契约下尤其危险）；
    ///   - 用户级 `DerivedData/`（Xcode 构建目录可能被 enumerator 遍历到）。
    private func loadAllSwiftSources() throws -> String {
        let root = try repoRoot()
        let fm = FileManager.default
        var combined = ""
        // App target 单独处理（不在 Packages 下）
        for relDir in [Self.appTargetSources] {
            let dir = root.appendingPathComponent(relDir)
            let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                if Self.shouldSkipSwiftSource(url: url) { continue }
                if let s = try? String(contentsOf: url, encoding: .utf8) {
                    combined += s
                    combined += "\n"
                }
            }
        }
        // 兄弟包：递归扫 Packages/ 下所有 .swift，跳过 Tests/ 与构建/依赖目录
        let pkgRoot = root.appendingPathComponent(Self.siblingPackagesRoot)
        if let enumerator = fm.enumerator(at: pkgRoot, includingPropertiesForKeys: nil) {
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                if Self.shouldSkipSwiftSource(url: url) { continue }
                if let s = try? String(contentsOf: url, encoding: .utf8) {
                    combined += s
                    combined += "\n"
                }
            }
        }
        return combined
    }

    /// 统一的 .swift 源过滤：跳过测试目录、SwiftPM 构建/签出、Xcode DerivedData。
    /// 同时用于 [loadAllSwiftSources](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/I18nIntegrityTests.swift)
    /// 与契约 8 的裸字面量扫描，保证两边扫描范围一致——避免 stale 检测漏报、裸字面量检测误报。
    private static func shouldSkipSwiftSource(url: URL) -> Bool {
        let comps = url.pathComponents
        if comps.contains("Tests") { return true }
        if comps.contains(".build") { return true }
        if comps.contains("checkouts") { return true }
        if comps.contains("DerivedData") { return true }
        return false
    }

    // MARK: - 契约 1：trash.err.* 双向同步（修订版）

    /// **历史**：Step 4（2026-06）原计划是把 6 条 stale `trash.err.*` key 从 xcstrings
    /// 清掉，因为对应 Swift 代码被重构没了。但 Step 4 后续 TrashPipeline 又重写为
    /// "面向用户的失败原因（dryrun 拦截 / 移动失败 / 安全策略阻断）必须可翻译"，
    /// 9 条 `trash.err.*` 复活进入活代码（见 [TrashPipeline.swift L268-L344](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift#L268-L344)）。
    ///
    /// **新契约**（2026-06-21 修订）：不再"必须 0 条"，而是**双向同步**——
    ///   1) xcstrings 里每条 `trash.err.*` key 必须在 TrashPipeline.swift 中至少出现一次；
    ///   2) TrashPipeline.swift 里每个 `trash.err.*` 字面量必须在 xcstrings 中有 key。
    ///
    /// 取舍：
    ///   - 不全仓 grep（避免被本测试文件自身的字面量 "trash.err." 自检自污染）。
    ///   - 只锁定 TrashPipeline.swift —— 这是 trash.err.* 的唯一活引用点。
    ///     如果未来出现第二个活引用点（如 BatchTrashCoordinator），需扩展本测试。
    func test_xcstrings_trash_err_key_双向同步() throws {
        let root = try repoRoot()
        let pipelinePath = root
            .appendingPathComponent("Packages/AppUI/Sources/AppUI/TrashPipeline.swift")
            .path
        let pipelineSrc = try String(contentsOfFile: pipelinePath, encoding: .utf8)

        let xcstringsTrashKeys = try loadXcstringsKeys().filter { $0.hasPrefix("trash.err.") }

        // 1) xcstrings → 源码：每条 key 必须被 TrashPipeline 引用
        var unreferenced: [String] = []
        for key in xcstringsTrashKeys {
            if !pipelineSrc.contains(key) {
                unreferenced.append(key)
            }
        }
        XCTAssertTrue(
            unreferenced.isEmpty,
            "xcstrings 中 \(unreferenced.count) 条 trash.err.* key 在 TrashPipeline.swift 找不到引用（疑似 stale，应在 xcstrings 删除）：\(unreferenced.sorted())"
        )

        // 2) 源码 → xcstrings：每个 "trash.err.XXX" 字面量必须在 xcstrings 中存在
        // 抓 pipeline 中所有 "trash.err.<rest>" 字面量（截到下一个空白 / " / ) 之前）。
        let pattern = #""(trash\.err\.[A-Za-z0-9_.]+(?:\s+%(?:lld|d|@|ld|\.\d+f))*)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = pipelineSrc as NSString
        let matches = regex.matches(in: pipelineSrc,
                                    range: NSRange(location: 0, length: ns.length))
        var sourceKeys = Set<String>()
        for m in matches where m.numberOfRanges >= 2 {
            sourceKeys.insert(ns.substring(with: m.range(at: 1)))
        }
        let xcSet = Set(xcstringsTrashKeys)
        let missingInCatalog = sourceKeys.subtracting(xcSet).sorted()
        XCTAssertTrue(
            missingInCatalog.isEmpty,
            "TrashPipeline.swift 引用了 \(missingInCatalog.count) 条 trash.err.* key 但 xcstrings 缺翻译（运行期会 fallback 到 key 字符串）：\(missingInCatalog)"
        )
    }

    /// 一条更宽的契约（**2026-06-23 升级为硬失败**）：xcstrings 每条 key 都必须在 Swift
    /// 源中至少出现一次（或匹配白名单动态前缀）。
    ///
    /// **历史**：
    ///   - Step 4 / 2026-06 首跑发现 41 条 backlog（实测 75 条），先**降级为 warn-only**
    ///     钉在 CI 输出，让维护者每次 PR 都能看到；同时保留 6 条 trash.err.* 硬契约。
    ///   - 2026-06-21 用户决定"激进治理"——逐条 grep 全仓 + 排除测试夹具污染，
    ///     先把测试源扫描范围扩到 `Packages/` 全部子包（修复 ScanKit / AIKit 等
    ///     字面量 key 被误判 stale 的根因），再核实剩余 68 条**全部源码 0 引用**——
    ///     从 xcstrings 真删，使 backlog 回归 0。
    ///   - 2026-06-23：本契约从 warn-only 升级为**硬失败**——任何新 PR 引入
    ///     orphan key（白名单外、源码 0 引用）将立即中断 CI，逼迫维护者要么
    ///     补字面量引用，要么扩白名单（带 PR 说明），要么删 xcstrings。
    ///
    /// 白名单语义（任一前缀命中即跳过）：
    ///   - **运行期由 enum.rawValue / ID 拼接出完整 key**（编译期 grep 看不见完整字面量）；
    ///   - 已在其它专项契约中单独覆盖的家族（如 trash.err.* 已被契约 1 双向校验）。
    ///
    /// **函数名保留 `_warn_only` 后缀**：CI 脚本 / 文档 / git blame 历史可能引用，
    /// 重命名会断裂；语义已在文档与断言上明确升级，名称仅作历史标记。
    func test_xcstrings_所有key都被Swift源引用_warn_only() throws {
        let keys = try loadXcstringsKeys()
        let sources = try loadAllSwiftSources()

        // 白名单：动态拼接的 key 前缀（运行期由 enum / id 拼出完整 key）。
        // 命中即跳过 —— 编译期 grep 看不见完整字面量是合理的。
        // 维护规则：扩白名单必须在 PR 里说清"哪段代码拼出哪些 key"，并在此处加注释。
        let dynamicPrefixes = [
            "category.id.",      // ScanCategory.id 拼接
            "trash.err.",        // 本测试已单独检查（契约 1 双向同步）
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

        // 硬契约：任何 orphan 即 fail。打印完整清单方便维护者快速定位。
        XCTAssertTrue(
            orphans.isEmpty,
            """
            发现 \(orphans.count) 条 xcstrings key 在 Swift 源中无显式引用（白名单外）。
            处理选项（择一）：
              1) 补源码引用（如新增 Text("key", bundle: .module)）；
              2) 若 key 实际由运行期 enum / ID 拼接生成，在 dynamicPrefixes 中扩白名单前缀并加注释；
              3) 若 key 已废弃，从 Localizable.xcstrings 中删除。
            orphan 列表：
              - \(orphans.sorted().joined(separator: "\n              - "))
            """
        )
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
        // 当前已知 backlog（2026-06-21 重测）：6 条 (s) 兜底翻译，分别来自
        //   - capacity.swap.allocated.hint.real
        //   - op.result.force_delete.button %lld
        //   - op.result.force_delete.confirm.message %lld
        //   - op.result.summary.success %lld
        //   - workflow.detail.delete.commandline_skipped %lld
        //   - workflow.detail.simctl.blocked_running %lld
        // 设上限护栏：超过 8 条立即 fail——防止后续 PR 引入新的 (s) 兜底翻译。
        // 治理目标：随着 Step 17-D plural variations 迁移完成，回收上限到 5、3、0。
        XCTAssertLessThanOrEqual(
            pluralParenSuffix.count, 8,
            "(s) 复数兜底翻译数量超过 8 条上限，已扫到 \(pluralParenSuffix.count) 条；新增 PR 必须改用 plural variations。"
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
        // 上限护栏：当前已知 ~29 条（2026-06-21 重测）；放宽到 32 防止滚动期 PR 新增打破护栏。
        // 治理目标：随着 plural variations 迁移完成，逐步回收上限到 25、20、15。
        XCTAssertLessThanOrEqual(
            candidates.count, 32,
            "%lld 复数英文名词候选数已达 \(candidates.count)，超过 32 上限；新增 PR 必须配套 plural variations 迁移。"
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

    // MARK: - 契约 8：禁止 Text("ASCII 大写字面量") 形式的裸 SwiftUI Text

    /// **契约目标**：所有 SwiftUI `Text(...)` 调用必须满足下列任一条件：
    ///   1) 走 i18n key：`Text("some.key", bundle: .module)` —— xcstrings 翻译；
    ///   2) 走非 i18n 文本：`Text(verbatim: ...)` —— 显式声明此字符串不需翻译（用户名、版本号、动态拼接等）；
    ///   3) 走静态非 i18n 短文本：`Text("—")` / `Text("/")` 等 1~2 字符符号 —— 由后续白名单覆盖（当前 0 例）。
    ///
    /// **禁止**：`Text("Help")` / `Text("File Not Found")` —— 任何**首字符是 ASCII 大写字母**
    /// 的英文字面量都属于"用户可见英文按钮 / 标签 / 提示"，必须 i18n。
    /// 若非英文用户看到中文系统时仍显示英文，会与已有翻译体系不一致。
    ///
    /// **历史**：2026-06 review-swarm 找到 [LaunchAgentScreen.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/LaunchAgentScreen.swift)
    /// 的 `Text("RunAtLoad")` 和 [PortCleanerScreen.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/PortCleanerScreen.swift)
    /// 的 `Text("PID")` 两处漏 i18n（commit 043718c 已修），暴露了缺少自动化契约的盲区。
    /// 本契约把这条规矩固化为 grep 硬失败，防止未来再漏。
    ///
    /// **扫描范围**：整个 `Packages/` 下所有 Source 代码（不含 Tests/、不含 Resources/），
    /// 以及 App target（顶层 Scene/Commands）。
    ///
    /// **匹配策略**（保守）：
    ///   - 只扫 `Text("X..."` 形式（双引号 + 紧跟首字符为 ASCII 大写 A-Z）；
    ///   - 排除同一行包含 `verbatim:` / `bundle:` / `String(format:` 关键字（这些都是合法用法）；
    ///   - 排除注释行（首字符 `//` 或 `///` 或 `*`）；
    ///   - 排除 SwiftUI `Image(systemName:)` / `.help(Text(...))` 等场景的 i18n key（带 bundle 必然有）。
    func test_no_bare_capitalized_Text_literal() throws {
        let root = try repoRoot()
        let fm = FileManager.default
        var violations: [String] = []

        // 扫所有 .swift 源（与 loadAllSwiftSources 同范围：App target + Packages 下所有非 Tests 文件）
        let dirs = [
            root.appendingPathComponent(Self.appTargetSources),
            root.appendingPathComponent(Self.siblingPackagesRoot),
        ]
        // 正则：Text("X...") 中 X 是 ASCII 大写字母；不含其它"]/n/" 之类（保守，只锁定 Text 之后到第一个 " 的内容）。
        // 注意：必须排除 Text("xxx" + "yyy") / Text(String(...)) 等非字面量分支——本正则只匹配"Text 开头 + 单段双引号字面量"。
        let textLiteralPattern = try NSRegularExpression(
            pattern: #"\bText\("([A-Z][^"]*)"\s*\)"#,
            options: []
        )

        for dir in dirs {
            guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                if Self.shouldSkipSwiftSource(url: url) { continue }
                // 跳过测试本身（防止本测试的正则字面量自污染）
                if url.lastPathComponent == "I18nIntegrityTests.swift" { continue }

                guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let lines = src.split(separator: "\n", omittingEmptySubsequences: false)
                for (idx, rawLine) in lines.enumerated() {
                    let line = String(rawLine)
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*") {
                        continue
                    }
                    // 同一行含合法关键字 → 跳过（说明该 Text 调用已显式声明 bundle / verbatim / format）。
                    // 注意：必须在 regex 检查前过滤，避免 Text("Foo", bundle: .module) 被误判。
                    if line.contains("bundle:") || line.contains("verbatim:") {
                        continue
                    }

                    let ns = line as NSString
                    let matches = textLiteralPattern.matches(
                        in: line,
                        range: NSRange(location: 0, length: ns.length)
                    )
                    for m in matches where m.numberOfRanges >= 2 {
                        let literal = ns.substring(with: m.range(at: 1))
                        let relPath = url.path.replacingOccurrences(of: root.path + "/", with: "")
                        violations.append("\(relPath):\(idx + 1)  Text(\"\(literal)\")")
                    }
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            发现 \(violations.count) 处裸 SwiftUI `Text("[A-Z]...")` 字面量（英文用户可见但未走 i18n）：
              \(violations.joined(separator: "\n  "))
            修复（择一）：
              1) 改为 `Text("some.i18n.key", bundle: .module)` 并在 Localizable.xcstrings 添加翻译；
              2) 若该字符串不需翻译（运行期拼接 / 用户输入 / 版本号等），改为 `Text(verbatim: ...)`；
              3) 若是注释中的示例，请确保整行以 `//` 开头。
            """
        )
    }
}
