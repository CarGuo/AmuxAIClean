import XCTest
import AIKit
@testable import AppUI

/// v2026.07.15：视图组 A 的即时语言回归边界。
/// 既验证长生命周期语义状态可在同一进程内重新投影，也阻止六个界面重新引入
/// 依赖进程启动语言的字符串解析。
final class SurfaceGroupALiveLocalizationTests: XCTestCase {
    private let english = Locale(identifier: "en")
    private let simplifiedChinese = Locale(identifier: "zh-Hans")

    func test_duplicateScanPhase_reprojectsSameSemanticStateWithinOneProcess() {
        let phase = DuplicateScreen.ScanPhase.prefixHash

        XCTAssertEqual(phase.localizedTitle(locale: english), "Prefix hash")
        XCTAssertEqual(phase.localizedTitle(locale: simplifiedChinese), "前缀 hash")
    }

    func test_aiAdviceFailure_reprojectsTypedMessage_withoutRawPayload() {
        let failure = AIAdviceSheet.FailurePresentation.http(
            status: 503
        )
        let englishMessage = failure.localizedMessage(locale: english)
        let chineseMessage = failure.localizedMessage(locale: simplifiedChinese)

        XCTAssertEqual(englishMessage, "The server returned HTTP 503. Review the app log for technical details.")
        XCTAssertEqual(chineseMessage, "服务端返回 HTTP 503，可在应用日志中查看技术详情。")

        let unexpected = AIAdviceSheet.FailurePresentation.unexpected
        XCTAssertFalse(unexpected.localizedMessage(locale: english).contains("POSIX"))
        XCTAssertNotEqual(
            unexpected.localizedMessage(locale: english),
            unexpected.localizedMessage(locale: simplifiedChinese)
        )
    }

    @MainActor
    func test_stashGlobalError_reprojectsSameTypedPayloadWithinOneProcess() {
        let notConfigured = StashAIQueue.GlobalError.notConfigured
        XCTAssertNotEqual(
            StashScreen.localizedGlobalError(
                notConfigured,
                locale: english
            ),
            StashScreen.localizedGlobalError(
                notConfigured,
                locale: simplifiedChinese
            )
        )

        let insecure = StashAIQueue.GlobalError.insecureBaseURL(
            scheme: "http",
            host: "remote.example"
        )
        let englishMessage = StashScreen.localizedGlobalError(insecure, locale: english)
        let chineseMessage = StashScreen.localizedGlobalError(insecure, locale: simplifiedChinese)
        XCTAssertTrue(englishMessage.contains("http://remote.example"))
        XCTAssertTrue(chineseMessage.contains("http://remote.example"))
        XCTAssertNotEqual(englishMessage, chineseMessage)
    }

    @MainActor
    func test_stashItemFailure_reprojectsWithoutRawTransportOrResponseText() {
        // v2026.07.16：逐行 tooltip 也必须保存 typed 状态；不能只修 footer 的
        // global error，而让单条 transport/body 继续以英文原文泄漏。
        let failure = StashStore.AIVerdictCache.Failure.http(status: 429)
        XCTAssertEqual(
            StashScreen.localizedItemAIFailure(failure, locale: english),
            "The server returned HTTP 429. Review the app log and try again."
        )
        XCTAssertEqual(
            StashScreen.localizedItemAIFailure(failure, locale: simplifiedChinese),
            "服务端返回 HTTP 429，可查看应用日志后重试。"
        )

        let transport = StashScreen.localizedItemAIFailure(.transport, locale: english)
        XCTAssertFalse(transport.contains("NSURLError"))
        XCTAssertFalse(transport.contains("file://"))
        XCTAssertNotEqual(
            transport,
            StashScreen.localizedItemAIFailure(.transport, locale: simplifiedChinese)
        )
    }

    @MainActor
    func test_stashQueue_preflightAndPreparationErrorsRemainTyped() {
        let suite = "SurfaceGroupALiveLocalizationTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = AISettings(testSuite: suite)
        settings.enabled = false

        let queue = StashAIQueue()
        queue.start(stash: StashStore(), aiSettings: settings)
        XCTAssertEqual(queue.lastGlobalError, .notConfigured)

        XCTAssertEqual(
            StashAIQueue.globalError(for: OpenAIChatClient.Error.invalidBaseURL),
            .invalidBaseURL
        )
        XCTAssertEqual(
            StashAIQueue.globalError(for: OpenAIChatClient.Error.insecureBaseURL(
                scheme: "http",
                host: "remote.example"
            )),
            .insecureBaseURL(scheme: "http", host: "remote.example")
        )
    }

    func test_largeFileLabels_useExplicitViewLocale() {
        XCTAssertEqual(FileKind.video.label(locale: english), "Video")
        XCTAssertEqual(FileKind.video.label(locale: simplifiedChinese), "视频")
        XCTAssertEqual(AppSettings.MtimeFilter.last30Days.label(in: english), "≤ 30 days")
        XCTAssertEqual(AppSettings.MtimeFilter.last30Days.label(in: simplifiedChinese), "≤ 30 天")
    }

    func test_groupASources_haveNoProcessLevelLocalizedStringResolution() throws {
        let root = try repositoryRoot()
        let files = [
            "DuplicateScreen.swift",
            "StashScreen.swift",
            "LargeFilesView.swift",
            "AIAdviceSheet.swift",
            "UninstallScreen.swift",
            "MaintenanceScreen.swift"
        ]

        let violations = try files.filter { file in
            let source = try String(
                contentsOf: root
                    .appendingPathComponent("Packages/AppUI/Sources/AppUI")
                    .appendingPathComponent(file),
                encoding: .utf8
            )
            return source.contains("String(localized:")
        }

        XCTAssertTrue(
            violations.isEmpty,
            "视图组 A 重新引入了进程级字符串解析：\(violations.joined(separator: ", "))"
        )
    }

    private func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        guard FileManager.default.fileExists(
            atPath: url.appendingPathComponent("Packages/AppUI/Package.swift").path
        ) else {
            throw NSError(
                domain: "SurfaceGroupALiveLocalizationTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Repository root not found from #filePath"]
            )
        }
        return url
    }
}
