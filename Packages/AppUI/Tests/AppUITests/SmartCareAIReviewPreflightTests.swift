import AIKit
import Foundation
import XCTest
@testable import AppUI

@MainActor
final class SmartCareAIReviewPreflightTests: XCTestCase {
    func test_remoteCredentialFailure_happensBeforeWorkerStarts_andLoadsOnce() async {
        let settings = makeReadySettings(baseURL: "https://api.openai.com")
        let probe = CredentialLoaderProbe(mode: .failure)

        do {
            _ = try await SmartCareAIReviewWorker.makeOpenAI(
                settings: settings,
                credentialLoader: { try await probe.load() }
            )
            XCTFail("远程端点的 Keychain 错误必须在逐项 worker 启动前失败")
        } catch CredentialProbeError.unavailable {
            // expected
        } catch {
            XCTFail("意外错误：\(error)")
        }

        let callCount = await probe.callCount()
        XCTAssertEqual(callCount, 1, "一次批处理只能读取一次 Keychain")
    }

    func test_remoteEmptyCredential_failsAsGlobalMissingKeyPreflight() async {
        let settings = makeReadySettings(baseURL: "https://api.openai.com")
        let probe = CredentialLoaderProbe(mode: .missing)

        do {
            _ = try await SmartCareAIReviewWorker.makeOpenAI(
                settings: settings,
                credentialLoader: { try await probe.load() }
            )
            XCTFail("远程端点空凭证不能等到第一条 item 才失败")
        } catch OpenAIChatClient.Error.missingAPIKey {
            // expected
        } catch {
            XCTFail("意外错误：\(error)")
        }

        let callCount = await probe.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func test_loopbackCredentialFailure_preservesOptionalAuthentication() async throws {
        let settings = makeReadySettings(baseURL: "http://127.0.0.1:11434")
        let probe = CredentialLoaderProbe(mode: .failure)

        _ = try await SmartCareAIReviewWorker.makeOpenAI(
            settings: settings,
            credentialLoader: { try await probe.load() }
        )

        let callCount = await probe.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func test_preparationGate_rejectsReentry_andCancellationClearsBusyState() async {
        let gate = SmartCareAIReviewPreparationGate()

        XCTAssertTrue(gate.start { await Task.yield() })
        XCTAssertTrue(gate.isPreparing)
        XCTAssertFalse(gate.start {}, "Keychain 预检期间不能启动第二批")

        gate.cancel()
        XCTAssertFalse(gate.isPreparing)
        XCTAssertTrue(gate.start {})
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(gate.isPreparing)
    }

    /// v2026.07.16：准备态是按钮 loading/cancel 的唯一信号。MainView 必须订阅 gate，
    /// 防止以后把 `@StateObject` 退化回只保存 class 引用、但不观察发布值的 `@State`。
    func test_mainView_observesPreparationGateBusyState() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot.appendingPathComponent("Sources/AppUI/MainView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains(
            "@StateObject private var smartCareAIPreparationGate"
        ))
        XCTAssertFalse(source.contains(
            "@State private var smartCareAIPreparationGate"
        ))
    }

    private func makeReadySettings(baseURL: String) -> AISettings {
        let suite = "SmartCareAIReviewPreflightTests.\(UUID().uuidString)"
        let settings = AISettings(testSuite: suite)
        settings.enabled = true
        settings.baseURL = baseURL
        settings.model = "test-model"
        return settings
    }
}

private enum CredentialProbeError: Error {
    case unavailable
}

private actor CredentialLoaderProbe {
    enum Mode: Sendable {
        case missing
        case failure
    }

    private let mode: Mode
    private var calls = 0

    init(mode: Mode) {
        self.mode = mode
    }

    func load() throws -> String? {
        calls += 1
        switch mode {
        case .missing:
            return nil
        case .failure:
            throw CredentialProbeError.unavailable
        }
    }

    func callCount() -> Int {
        calls
    }
}
