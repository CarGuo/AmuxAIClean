import XCTest
import AIKit
import SafetyKit
@testable import AppUI

private actor SmartCareAIReviewTestGate {
    private var started = false
    private var released = false

    func markStarted() { started = true }
    func release() { released = true }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func waitUntilReleased() async {
        while !released { await Task.yield() }
    }
}

private actor SmartCareAIReviewCallCounter {
    private var count = 0

    func increment() { count += 1 }
    func value() -> Int { count }
}

@MainActor
final class SmartCareAIReviewSessionTests: XCTestCase {
    private enum MockError: Error, Sendable {
        case failed
    }

    private func item(
        _ id: String,
        verdict: SafetyVerdict = .safe,
        path: String? = nil
    ) -> SmartCareItem {
        SmartCareItem(
            id: id,
            bucketID: .systemJunk,
            path: path ?? "/tmp/\(id)",
            title: id,
            bytes: 128,
            verdict: verdict
        )
    }

    nonisolated private static func advice(
        _ verdict: SafetyVerdict = .safe,
        marker: String = "ok"
    ) -> AIAdvice {
        AIAdvice(
            summary: "summary-\(marker)",
            canDelete: verdict,
            reason: "reason-\(marker)",
            sideEffects: ["side-effect-\(marker)"]
        )
    }

    private func awaitReport(
        _ session: SmartCareAIReviewSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> SmartCareAIReviewReport {
        for _ in 0..<2_000 {
            if case .result(let report) = session.phase { return report }
            await Task.yield()
        }
        XCTFail("Timed out waiting for AI review report", file: file, line: line)
        throw MockError.failed
    }

    func test_success保留完整Advice与选择快照() async throws {
        let session = SmartCareAIReviewSession()
        let first = item("first")
        let second = item("second", verdict: .confirm)
        let expected = Self.advice(.confirm, marker: "full")

        let runID = session.start(
            items: [first, second],
            selectedItemIDs: [first.id],
            summaryRevision: 17,
            using: SmartCareAIReviewWorker { _ in expected }
        )
        let report = try await awaitReport(session)

        XCTAssertEqual(report.runID, runID)
        XCTAssertEqual(report.status, .success)
        XCTAssertEqual(report.sourceSummaryRevision, 17)
        XCTAssertTrue(report.isCurrent)
        XCTAssertEqual(report.requestedCount, 2)
        XCTAssertEqual(report.succeededCount, 2)
        XCTAssertEqual(report.items[0].advice, expected)
        XCTAssertTrue(report.items[0].selectedAtStart)
        XCTAssertFalse(report.items[1].selectedAtStart)
    }

    func test_partial报告同时保留成功和完整失败() async throws {
        let session = SmartCareAIReviewSession()
        let worker = SmartCareAIReviewWorker { item in
            if item.id == "bad" { throw MockError.failed }
            return Self.advice(.safe, marker: item.id)
        }

        _ = session.start(
            items: [item("good"), item("bad")],
            summaryRevision: 1,
            using: worker
        )
        let report = try await awaitReport(session)

        XCTAssertEqual(report.status, .partial)
        XCTAssertEqual(report.succeededCount, 1)
        XCTAssertEqual(report.failedCount, 1)
        XCTAssertEqual(report.items.first(where: { $0.id == "bad" })?.failure?.kind, .unknown)
    }

    func test_allFailed形成失败报告() async throws {
        let session = SmartCareAIReviewSession()
        _ = session.start(
            items: [item("a"), item("b")],
            summaryRevision: 1,
            using: SmartCareAIReviewWorker { _ in throw MockError.failed }
        )

        let report = try await awaitReport(session)
        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.failedCount, 2)
        XCTAssertEqual(report.remainingCount, 0)
    }

    func test_鉴权与限流类错误立即停批并保留剩余项() async throws {
        let session = SmartCareAIReviewSession()
        let counter = SmartCareAIReviewCallCounter()
        _ = session.start(
            items: [item("good"), item("auth"), item("remaining")],
            summaryRevision: 6,
            using: SmartCareAIReviewWorker { item in
                await counter.increment()
                if item.id == "good" { return Self.advice(marker: "good") }
                throw OpenAIChatClient.Error.http(status: 401, body: "must not be stored")
            }
        )

        let report = try await awaitReport(session)
        let callCount = await counter.value()
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(report.status, .partial)
        XCTAssertEqual(report.succeededCount, 1)
        XCTAssertEqual(report.failedCount, 1)
        XCTAssertEqual(report.remainingCount, 1)
        XCTAssertEqual(report.globalFailure?.kind, .authentication)
        XCTAssertTrue(report.items.last?.isNotReviewed == true)

        _ = session.retryFailed(using: SmartCareAIReviewWorker { item in
            Self.advice(marker: item.id)
        })
        let recovered = try await awaitReport(session)
        XCTAssertEqual(recovered.status, .success)
        XCTAssertEqual(recovered.succeededCount, 3)
        XCTAssertNil(recovered.globalFailure)
    }

    func test_不可解析的AI响应计为可重试失败而不是成功() async throws {
        let session = SmartCareAIReviewSession()
        _ = session.start(
            items: [item("unparsable")],
            summaryRevision: 7,
            using: SmartCareAIReviewWorker { _ in
                AIAdvice.unparsable(rawText: "secret provider payload")
            }
        )

        let report = try await awaitReport(session)
        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.succeededCount, 0)
        XCTAssertEqual(report.failedCount, 1)
        XCTAssertEqual(report.items.first?.failure?.kind, .decoding)
        XCTAssertTrue(report.items.first?.failure?.canRetry == true)
        XCTAssertFalse(String(describing: report).contains("secret provider payload"))
    }

    func test_empty输入也形成明确终态() async throws {
        let session = SmartCareAIReviewSession()
        let runID = session.start(
            items: [],
            summaryRevision: 4,
            using: SmartCareAIReviewWorker { _ in Self.advice() }
        )

        let report = try await awaitReport(session)
        XCTAssertEqual(report.runID, runID)
        XCTAssertEqual(report.status, .empty)
        XCTAssertEqual(report.requestedCount, 0)
        XCTAssertTrue(report.isCurrent)
    }

    func test_preflight失败只记录一次全局错误() throws {
        let session = SmartCareAIReviewSession()
        let failure = SmartCareAIReviewFailure(
            kind: .configuration,
            canRetry: false,
            shouldOpenSettings: true
        )

        let report = try XCTUnwrap(session.failPreflight(
            items: [item("a"), item("b")],
            selectedItemIDs: ["b"],
            summaryRevision: 9,
            failure: failure
        ))

        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.globalFailure, failure)
        XCTAssertEqual(report.failedCount, 0)
        XCTAssertEqual(report.remainingCount, 2)
        XCTAssertTrue(report.items.allSatisfy(\.isNotReviewed))
        XCTAssertEqual(report.items.filter(\.selectedAtStart).map(\.id), ["b"])
        XCTAssertTrue(report.items.allSatisfy { $0.failure == nil })
    }

    func test_retryFailed可从全局预检失败恢复() async throws {
        let session = SmartCareAIReviewSession()
        _ = session.failPreflight(
            items: [item("a"), item("b")],
            summaryRevision: 9,
            failure: SmartCareAIReviewFailure(
                kind: .network,
                canRetry: true
            )
        )

        let runID = session.retryFailed(using: SmartCareAIReviewWorker { item in
            Self.advice(.safe, marker: item.id)
        })
        let recovered = try await awaitReport(session)
        XCTAssertNotNil(runID)
        XCTAssertNil(recovered.globalFailure)
        XCTAssertEqual(recovered.status, .success)
        XCTAssertEqual(recovered.succeededCount, 2)
    }

    func test_继续预检失败保留已成功结果且之后仍可重试() async throws {
        let session = SmartCareAIReviewSession()
        _ = session.start(
            items: [item("good"), item("bad")],
            summaryRevision: 9,
            using: SmartCareAIReviewWorker { item in
                if item.id == "bad" { throw MockError.failed }
                return Self.advice(.safe, marker: "preserved")
            }
        )
        let first = try await awaitReport(session)
        XCTAssertEqual(first.status, .partial)

        let preflightFailure = SmartCareAIReviewFailure(
            kind: .configuration,
            canRetry: false,
            shouldOpenSettings: true
        )
        let failedContinuation = try XCTUnwrap(
            session.failContinuationPreflight(failure: preflightFailure)
        )

        XCTAssertNotEqual(failedContinuation.runID, first.runID)
        XCTAssertEqual(failedContinuation.status, .partial)
        XCTAssertEqual(failedContinuation.globalFailure, preflightFailure)
        XCTAssertEqual(failedContinuation.succeededCount, 1)
        XCTAssertEqual(failedContinuation.failedCount, 1)
        XCTAssertEqual(failedContinuation.remainingCount, 0)
        XCTAssertEqual(
            failedContinuation.items.first(where: { $0.id == "good" })?.advice,
            first.items.first(where: { $0.id == "good" })?.advice
        )

        _ = session.retryFailed(using: SmartCareAIReviewWorker { item in
            XCTAssertEqual(item.id, "bad")
            return Self.advice(.confirm, marker: "recovered")
        })
        let recovered = try await awaitReport(session)
        XCTAssertEqual(recovered.status, .success)
        XCTAssertNil(recovered.globalFailure)
        XCTAssertEqual(recovered.succeededCount, 2)
        XCTAssertEqual(
            recovered.items.first(where: { $0.id == "good" })?.advice,
            first.items.first(where: { $0.id == "good" })?.advice
        )
    }

    func test_取消后的继续预检失败保留remaining语义并可恢复() async throws {
        let session = SmartCareAIReviewSession()
        let gate = SmartCareAIReviewTestGate()
        _ = session.start(
            items: [item("done"), item("remaining")],
            summaryRevision: 10,
            using: SmartCareAIReviewWorker { item in
                if item.id == "done" { return Self.advice(marker: "done") }
                await gate.markStarted()
                await gate.waitUntilReleased()
                return Self.advice(marker: "late")
            }
        )
        await gate.waitUntilStarted()
        session.cancel()
        let cancelled = try await awaitReport(session)
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(cancelled.succeededCount, 1)
        XCTAssertEqual(cancelled.remainingCount, 1)

        let continuationFailure = try XCTUnwrap(session.failContinuationPreflight(
            failure: SmartCareAIReviewFailure(
                kind: .configuration,
                canRetry: false,
                shouldOpenSettings: true
            )
        ))
        XCTAssertEqual(continuationFailure.status, .partial)
        XCTAssertEqual(continuationFailure.succeededCount, 1)
        XCTAssertEqual(continuationFailure.failedCount, 0)
        XCTAssertEqual(continuationFailure.remainingCount, 1)
        XCTAssertNotNil(continuationFailure.globalFailure)

        _ = session.retryFailed(using: SmartCareAIReviewWorker { item in
            XCTAssertEqual(item.id, "remaining")
            return Self.advice(marker: "resumed")
        })
        let recovered = try await awaitReport(session)
        await gate.release()
        XCTAssertEqual(recovered.status, .success)
        XCTAssertEqual(recovered.succeededCount, 2)
    }

    func test_cancel产生取消报告并保留未处理项() async throws {
        let session = SmartCareAIReviewSession()
        _ = session.start(
            items: [item("a"), item("b")],
            summaryRevision: 1,
            using: SmartCareAIReviewWorker { _ in
                try await Task.sleep(for: .seconds(30))
                return Self.advice()
            }
        )
        session.cancel()

        let report = try await awaitReport(session)
        XCTAssertEqual(report.status, .cancelled)
        XCTAssertEqual(report.remainingCount, 2)
        XCTAssertEqual(report.succeededCount, 0)
    }

    func test_cancel后worker包装出的迟到错误不会污染单项结果() async throws {
        let session = SmartCareAIReviewSession()
        let gate = SmartCareAIReviewTestGate()
        _ = session.start(
            items: [item("a")],
            summaryRevision: 1,
            using: SmartCareAIReviewWorker { _ in
                await gate.markStarted()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    throw MockError.failed
                }
                return Self.advice()
            }
        )
        await gate.waitUntilStarted()
        session.cancel()

        let report = try await awaitReport(session)
        XCTAssertEqual(report.status, .cancelled)
        XCTAssertTrue(report.items[0].isNotReviewed)
        XCTAssertNil(report.items[0].failure)
    }

    func test_cancel不依赖worker配合即可立即形成终态() async throws {
        let session = SmartCareAIReviewSession()
        let gate = SmartCareAIReviewTestGate()
        _ = session.start(
            items: [item("a")],
            summaryRevision: 1,
            using: SmartCareAIReviewWorker { _ in
                await gate.markStarted()
                await gate.waitUntilReleased()
                return Self.advice()
            }
        )
        await gate.waitUntilStarted()

        session.cancel()
        let report = try await awaitReport(session)
        await gate.release()

        XCTAssertEqual(report.status, .cancelled)
        XCTAssertTrue(report.items[0].isNotReviewed)
        XCTAssertFalse(session.phase.isRunning)
    }

    func test_旧run迟到取消不会污染随后启动的新run() async throws {
        let session = SmartCareAIReviewSession()
        let oldGate = SmartCareAIReviewTestGate()
        let newGate = SmartCareAIReviewTestGate()
        _ = session.start(
            items: [item("old")],
            summaryRevision: 1,
            using: SmartCareAIReviewWorker { _ in
                await oldGate.markStarted()
                await oldGate.waitUntilReleased()
                return Self.advice(marker: "old")
            }
        )
        await oldGate.waitUntilStarted()
        session.cancel()
        _ = try await awaitReport(session)

        _ = session.start(
            items: [item("new")],
            summaryRevision: 1,
            using: SmartCareAIReviewWorker { _ in
                await newGate.markStarted()
                await newGate.waitUntilReleased()
                return Self.advice(marker: "new")
            }
        )
        await newGate.waitUntilStarted()

        // 旧 task 现在才从不可取消的 worker 返回，并在 Task.checkCancellation 抛错。
        await oldGate.release()
        for _ in 0..<100 { await Task.yield() }
        await newGate.release()

        let report = try await awaitReport(session)
        XCTAssertEqual(report.status, .success)
        XCTAssertEqual(report.items.first?.id, "new")
        XCTAssertEqual(report.items.first?.advice?.summary, "summary-new")
    }

    func test_revision变化取消在途并产生过期报告() async throws {
        let session = SmartCareAIReviewSession()
        _ = session.start(
            items: [item("a")],
            summaryRevision: 2,
            using: SmartCareAIReviewWorker { _ in
                try await Task.sleep(for: .seconds(30))
                return Self.advice()
            }
        )
        session.synchronizeSummaryRevision(3)

        let report = try await awaitReport(session)
        XCTAssertEqual(report.status, .stale)
        XCTAssertEqual(report.sourceSummaryRevision, 2)
        XCTAssertEqual(report.observedSummaryRevision, 3)
        XCTAssertFalse(report.isCurrent)
    }

    func test_continueUnreviewed保留取消前结果并完成剩余项() async throws {
        let session = SmartCareAIReviewSession()
        _ = session.start(
            items: [item("a"), item("b")],
            summaryRevision: 5,
            using: SmartCareAIReviewWorker { _ in
                try await Task.sleep(for: .seconds(30))
                return Self.advice()
            }
        )
        session.cancel()
        let cancelled = try await awaitReport(session)
        XCTAssertEqual(cancelled.status, .cancelled)

        let continueRunID = session.continueUnreviewed(using: SmartCareAIReviewWorker { item in
            Self.advice(.safe, marker: item.id)
        })
        let resumed = try await awaitReport(session)
        XCTAssertNotNil(continueRunID)
        XCTAssertEqual(resumed.status, .success)
        XCTAssertEqual(resumed.succeededCount, 2)
    }

    func test_completed报告在revision变化后转为过期() async throws {
        let session = SmartCareAIReviewSession()
        _ = session.start(
            items: [item("a")],
            summaryRevision: 2,
            using: SmartCareAIReviewWorker { _ in Self.advice() }
        )
        _ = try await awaitReport(session)

        session.synchronizeSummaryRevision(8)
        let report = try XCTUnwrap(session.latestReport)
        XCTAssertEqual(report.status, .stale)
        XCTAssertEqual(report.observedSummaryRevision, 8)
    }

    func test_retryFailed只重试失败项并合并原报告() async throws {
        let session = SmartCareAIReviewSession()
        _ = session.start(
            items: [item("good"), item("bad")],
            selectedItemIDs: ["good"],
            summaryRevision: 12,
            using: SmartCareAIReviewWorker { item in
                if item.id == "bad" { throw MockError.failed }
                return Self.advice(.safe, marker: "first")
            }
        )
        let firstReport = try await awaitReport(session)
        XCTAssertEqual(firstReport.status, .partial)

        let retryID = session.retryFailed(using: SmartCareAIReviewWorker { item in
            XCTAssertEqual(item.id, "bad")
            return Self.advice(.confirm, marker: "retry")
        })
        let retried = try await awaitReport(session)

        XCTAssertNotEqual(retryID, firstReport.runID)
        XCTAssertEqual(retried.status, .success)
        XCTAssertEqual(retried.succeededCount, 2)
        XCTAssertEqual(retried.items.first(where: { $0.id == "good" })?.advice,
                       firstReport.items.first(where: { $0.id == "good" })?.advice)
        XCTAssertEqual(retried.items.first(where: { $0.id == "bad" })?.advice?.reason,
                       "reason-retry")
        XCTAssertTrue(retried.items.first(where: { $0.id == "good" })?.selectedAtStart == true)
    }

    func test_forbid条目不会被注入worker放行() async throws {
        let session = SmartCareAIReviewSession()
        let forbidden = item("system", verdict: .forbid, path: "/System/Library")
        _ = session.start(
            items: [forbidden],
            summaryRevision: 1,
            using: SmartCareAIReviewWorker { _ in Self.advice(.safe) }
        )

        let report = try await awaitReport(session)
        let result = try XCTUnwrap(report.items.first?.advice)
        XCTAssertEqual(result.canDelete, .forbid)
        XCTAssertTrue(result.reason.hasPrefix(AIAdviceClamp.localPolicyOverridePrefix))
    }

    func test_failure只保留结构化诊断不保存任意provider内容() {
        let body = "Bearer secret-token-value sk-abcdefghijk /Users/alice/" + String(repeating: "x", count: 3_000)
        let failure = SmartCareAIReviewFailure(
            error: OpenAIChatClient.Error.http(status: 500, body: body)
        )

        XCTAssertEqual(failure.kind, .server)
        XCTAssertEqual(failure.httpStatus, 500)
        XCTAssertTrue(failure.canRetry)
        let storedDescription = String(describing: failure)
        XCTAssertFalse(storedDescription.contains("secret-token-value"))
        XCTAssertFalse(storedDescription.contains("sk-abcdefghijk"))
        XCTAssertFalse(storedDescription.contains("/Users/alice"))
    }

    func test_HTTP配置错误映射为设置动作并触发停批() {
        for status in [400, 404, 422] {
            let failure = SmartCareAIReviewFailure(
                error: OpenAIChatClient.Error.http(status: status, body: "provider body")
            )
            XCTAssertEqual(failure.kind, .configuration)
            XCTAssertEqual(failure.httpStatus, status)
            XCTAssertFalse(failure.canRetry)
            XCTAssertTrue(failure.shouldOpenSettings)
            XCTAssertTrue(failure.stopsBatch)
        }
    }

    func test_selectionPolicy只接受报告内仍可选择的当前项目() {
        let safe = item("safe")
        let confirm = item("confirm", verdict: .confirm)
        let forbidden = item("forbid", verdict: .forbid)
        let unrelated = item("unrelated")
        let outcomes = [safe, confirm, forbidden].map { candidate in
            SmartCareAIReviewItemOutcome(
                item: candidate,
                selectedAtStart: candidate == safe,
                result: .advice(Self.advice(.safe))
            )
        }
        let report = SmartCareAIReviewReport(
            runID: UUID(),
            sourceSummaryRevision: 41,
            observedSummaryRevision: 41,
            status: .success,
            items: outcomes,
            startedAt: Date(),
            finishedAt: Date()
        )

        let changes = SmartCareAIReviewSelectionPolicy.validatedChanges(
            report: report,
            currentSummaryRevision: 41,
            currentItemIDs: [safe.id, confirm.id, forbidden.id, unrelated.id],
            proposedByPath: [
                safe.path: false,
                confirm.path: true,
                forbidden.path: true,
                unrelated.path: true,
                "/tmp/not-present": true
            ]
        )

        XCTAssertEqual(changes.map(\.item.id), [confirm.id, safe.id])
        XCTAssertEqual(changes.map(\.selected), [true, false])
    }

    func test_selectionPolicy拒绝过期报告() {
        let safe = item("safe")
        let report = SmartCareAIReviewReport(
            runID: UUID(),
            sourceSummaryRevision: 1,
            observedSummaryRevision: 2,
            status: .stale,
            items: [SmartCareAIReviewItemOutcome(
                item: safe,
                selectedAtStart: true,
                result: .advice(Self.advice())
            )],
            startedAt: Date(),
            finishedAt: Date()
        )

        XCTAssertTrue(SmartCareAIReviewSelectionPolicy.validatedChanges(
            report: report,
            currentSummaryRevision: 2,
            currentItemIDs: [safe.id],
            proposedByPath: [safe.path: false]
        ).isEmpty)
    }

    func test_selectionPolicy不允许失败项或非safe建议扩大confirm选择() {
        let failed = item("failed", verdict: .confirm)
        let review = item("review", verdict: .confirm)
        let avoid = item("avoid", verdict: .confirm)
        let report = SmartCareAIReviewReport(
            runID: UUID(),
            sourceSummaryRevision: 5,
            observedSummaryRevision: 5,
            status: .partial,
            items: [
                SmartCareAIReviewItemOutcome(
                    item: failed,
                    selectedAtStart: false,
                    result: .failure(SmartCareAIReviewFailure(
                        kind: .network,
                        canRetry: true
                    ))
                ),
                SmartCareAIReviewItemOutcome(
                    item: review,
                    selectedAtStart: false,
                    result: .advice(Self.advice(.confirm))
                ),
                SmartCareAIReviewItemOutcome(
                    item: avoid,
                    selectedAtStart: false,
                    result: .advice(Self.advice(.forbid))
                )
            ],
            startedAt: Date(),
            finishedAt: Date()
        )

        XCTAssertTrue(SmartCareAIReviewSelectionPolicy.validatedChanges(
            report: report,
            currentSummaryRevision: 5,
            currentItemIDs: [failed.id, review.id, avoid.id],
            proposedByPath: [failed.path: true, review.path: true, avoid.path: true]
        ).isEmpty)
    }
}
