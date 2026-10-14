import Foundation
import SafetyKit
import XCTest
@testable import AppUI

final class DeletionPreflightPresentationTests: XCTestCase {
    func testPreSubmitSafetyReasonsUseDedicatedLocalizationNamespace() {
        XCTAssertTrue(DeletionPreflightNotice.Message.rejected.rawValue
            .hasPrefix("delete.preflight."))
        XCTAssertTrue(DeletionPreflightNotice.Message.scanChanged.rawValue
            .hasPrefix("delete.preflight."))
        XCTAssertTrue(DeletionPreflightNotice.Message.scanInProgress.rawValue
            .hasPrefix("delete.preflight."))
        let rejections: [SafetyRejection] = [
            .relativePath, .dotDotInPath, .symbolicLinkResolutionFailed, .rootOrAboveHome, .outsideUserDeletionScope,
            .preflightCancelled, .hardForbidPrefix, .userDocumentsRoot, .systemVolume,
            .insideAppBundle, .sensitiveCredential, .vendorPathRule, .accessDenied,
            .userWhitelisted, .batchContainsForbidden, .bundleSystemCritical,
            .bundleDataProtected, .ok,
        ]
        for rejection in rejections {
            let key = DeletionPreflightReasonPresentation.localizationKey(
                for: rejection.rawValue
            )
            XCTAssertTrue(key.hasPrefix("delete.preflight.reason."))
            XCTAssertFalse(key.hasPrefix("op.result."))
        }
        XCTAssertEqual(
            DeletionPreflightReasonPresentation.localizationKey(for: "future-reason"),
            "delete.preflight.reason.generic"
        )
    }

    // v2026.10.14: the user corrected the former non-modal preflight contract. Rejections
    // now own a failure sheet, while only receipt-backed success may use transient feedback.
    func testAllDeletionSurfacesPresentPreSubmitFailureThroughSharedSheet() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AppUI")
        for name in ["MainView.swift", "BrewScreen.swift", "DuplicateScreen.swift",
                     "UninstallScreen.swift", "WorkflowDetailView.swift", "StorageAnalysisView.swift"] {
            let source = try String(contentsOf: sourceRoot.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(source.contains(".deletionPreflightNoticeSheet(")
                || source.contains("DeletionPreflightNoticeSheet(notice:"), name)
            XCTAssertFalse(source.contains(".deletionPreflightNoticeOverlay("), name)
            XCTAssertTrue(source.contains("OperationResultSheet"), name)
        }
        let shared = try String(contentsOf: sourceRoot.appendingPathComponent("DeletionPreflightNotice.swift"), encoding: .utf8)
        XCTAssertTrue(shared.contains("localizedSheet(item: notice)"))
        XCTAssertTrue(shared.contains("notice.rejections.enumerated()"), "Every rejected item must be inspectable")
        XCTAssertFalse(shared.contains("prefix(2)"))
        XCTAssertFalse(shared.contains(".overlay(alignment:"))
    }

    func testStorageFailureAndExpiredQueueHaveActionableReasonsInBothLanguages() {
        let cases: [(TrashPendingOperationRejection.Reason, String)] = [
            (.ledgerUnavailable, "delete.preflight.reason.history_unavailable"),
            (.submissionQueueExpired, "delete.preflight.reason.queue_expired")
        ]
        for (reason, key) in cases {
            XCTAssertEqual(DeletionPreflightReasonPresentation.localizationKey(for: reason.rawValue), key)
            for language in ["zh-Hans", "en"] {
                let text = DeletionPreflightReasonPresentation.text(for: reason.rawValue, locale: Locale(identifier: language))
                XCTAssertFalse(text.isEmpty)
                XCTAssertNotEqual(text, key)
                XCTAssertFalse(text.contains(reason.rawValue))
            }
        }
    }

    func testEveryKnownSafetyRejectionUsesAnExplicitTypedPresentation() {
        let expected: [(SafetyRejection, String)] = [
            (.relativePath, "op.result.reason.outside_user_scope"),
            (.dotDotInPath, "op.result.reason.outside_user_scope"),
            (.symbolicLinkResolutionFailed, "op.result.reason.symbolic_link_resolution_failed"),
            (.rootOrAboveHome, "op.result.reason.user_root"),
            (.outsideUserDeletionScope, "op.result.reason.outside_user_scope"),
            (.preflightCancelled, "op.result.reason.preflight_cancelled"),
            (.hardForbidPrefix, "op.result.reason.hard_forbid"),
            (.userDocumentsRoot, "op.result.reason.user_root"),
            (.systemVolume, "op.result.reason.system_volume"),
            (.insideAppBundle, "op.result.reason.hard_forbid"),
            (.sensitiveCredential, "op.result.reason.sensitive_credential"),
            (.vendorPathRule, "op.result.reason.vendor_path_rule"),
            (.accessDenied, "op.result.reason.access_denied"),
            (.userWhitelisted, "op.result.reason.user_whitelist"),
            (.batchContainsForbidden, "op.result.reason.batch_atomic"),
            (.bundleSystemCritical, "op.result.reason.hard_forbid"),
            (.bundleDataProtected, "op.result.reason.hard_forbid"),
            (.ok, "op.result.reason.generic")
        ]

        for (rejection, key) in expected {
            XCTAssertEqual(
                DeletionSafetyReasonPresentation.localizationKey(for: rejection.rawValue),
                key,
                "Missing typed presentation for \(rejection.rawValue)"
            )
        }
    }

    func testUnknownAndLookalikeRawReasonsRemainGeneric() {
        let unknownReasons = [
            "futureSafetyReason",
            "vendorPathRule-but-not-a-real-enum-value",
            "permissionFailure",
            "hard_forbid_typo"
        ]

        for reason in unknownReasons {
            XCTAssertEqual(
                DeletionSafetyReasonPresentation.localizationKey(for: reason),
                "op.result.reason.generic"
            )
        }
    }

    func testOperationResultPayloadHasNoPreflightProjectionInitializer() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Packages/AppUI/Sources/AppUI/OperationResultSheet.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("init(preflightRejections:"))
        XCTAssertFalse(source.contains("init(preflight: DeletionPreflight"))
        XCTAssertFalse(source.contains("submissionReceipt: DeletionSubmissionReceipt?"))
        XCTAssertFalse(source.contains("onForceDelete"))
        XCTAssertFalse(source.contains("vendorOverrideCandidates"))
        XCTAssertTrue(source.contains("init(completion: OperationResultCompletion"))
    }
}
