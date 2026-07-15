import Foundation
import SafetyKit
import XCTest
@testable import AppUI

final class DeletionPreflightPresentationTests: XCTestCase {
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
