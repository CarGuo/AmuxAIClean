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
            .relativePath, .dotDotInPath, .rootOrAboveHome, .outsideUserDeletionScope,
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

    func testFiveProfessionalSurfacesRoutePreSubmitNoticeThroughSharedFloatingOverlay() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AppUI")
        let names = [
            "MainView.swift",
            "BrewScreen.swift",
            "DuplicateScreen.swift",
            "UninstallScreen.swift",
            "WorkflowDetailView.swift",
        ]
        let sources = try Dictionary(uniqueKeysWithValues: names.map { name in
            (name, try String(
                contentsOf: sourceRoot.appendingPathComponent(name),
                encoding: .utf8
            ))
        })

        for name in names {
            let source = try XCTUnwrap(sources[name])
            XCTAssertTrue(source.contains(".deletionPreflightNoticeOverlay("), name)
            XCTAssertFalse(source.contains("DeletionPreflightNoticeBanner"), name)
            XCTAssertFalse(
                source.contains(".safeAreaInset(edge: .top, spacing: 0)"),
                "删除预检不得重新占用顶部 safe area：\(name)"
            )
            XCTAssertTrue(source.contains("OperationResultSheet"),
                          "真实提交结果仍必须保留共享 result sheet：\(name)")
        }
        // The localized presentation entry must enforce the same non-modal preflight contract.
        for presenter in [".sheet(", ".localizedSheet("] {
            XCTAssertFalse(try XCTUnwrap(sources["MainView.swift"])
                .contains(presenter + "item: $deletePreflightNotice)"))
        }
        XCTAssertFalse(try XCTUnwrap(sources["MainView.swift"])
            .contains(".message(AppLocalization.string(\"delete.preflight."),
            "Main 的预提交状态变化也不得回退到 modal message")
        XCTAssertFalse(try XCTUnwrap(sources["MainView.swift"])
            .contains("deleteResult = AppLocalization.string(\"delete.preflight."),
            "Main 的扫描中预提交状态也必须留在非模态 notice")
        for name in ["BrewScreen.swift", "DuplicateScreen.swift", "UninstallScreen.swift"] {
            XCTAssertFalse(try XCTUnwrap(sources[name]).contains("case preflightNotice("), name)
        }
        XCTAssertFalse(try XCTUnwrap(sources["WorkflowDetailView.swift"])
            .contains("case preflightNotice(id:"))
    }

    func testSharedPreflightCalloutIsBoundedAndDoesNotOwnModalPresentation() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AppUI/DeletionPreflightNotice.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertEqual(DeletionPreflightNoticeCalloutMetrics.maxWidth, 420)
        XCTAssertGreaterThan(DeletionPreflightNoticeCalloutMetrics.bottomActionClearance, 0)
        XCTAssertTrue(source.contains(".overlay(alignment: .bottomTrailing)"))
        XCTAssertTrue(source.contains("DeletionPreflightNoticeCallout"))
        XCTAssertTrue(source.contains("accessibilityIdentifier(\"delete.preflight.callout\")"))
        XCTAssertFalse(source.contains("safeAreaInset"))
        XCTAssertFalse(source.contains(".sheet("))
        XCTAssertFalse(source.contains(".alert("))
        XCTAssertFalse(source.contains(".confirmationDialog("))
    }

    func testEveryKnownSafetyRejectionUsesAnExplicitTypedPresentation() {
        let expected: [(SafetyRejection, String)] = [
            (.relativePath, "op.result.reason.outside_user_scope"),
            (.dotDotInPath, "op.result.reason.outside_user_scope"),
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
