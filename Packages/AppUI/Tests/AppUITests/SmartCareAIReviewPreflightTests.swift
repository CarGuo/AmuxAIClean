import AIKit
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
