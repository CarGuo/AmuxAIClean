import Foundation
import ScanKit
import SafetyKit
import XCTest
@testable import AppUI

final class DeletionTargetRevalidatorBehaviorTests: XCTestCase {
    func test_professionalTreeMayInitiateRevalidationButNeverHardForbid() {
        XCTAssertTrue(DeletionEntryPolicy.canInitiate(
            verdict: .safe,
            rejection: .ok,
            hasCompleteAccessEvidence: false,
            allowsTargetRevalidation: true,
            allowsVendorPathOverride: true
        ))
        XCTAssertFalse(DeletionEntryPolicy.canInitiate(
            verdict: .forbid,
            rejection: .hardForbidPrefix,
            hasCompleteAccessEvidence: false,
            allowsTargetRevalidation: true,
            allowsVendorPathOverride: true
        ))
    }

    func test_descendantEnumerationFailureCanReachStrictConfirmationWithoutReadingDescendant() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Android/sdk/system-images/android-36.1", isDirectory: true)
        let lockedChild = target.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedChild, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(lockedChild.path, 0), 0)
        defer { _ = chmod(lockedChild.path, S_IRWXU) }

        let pipeline = TrashPipeline(home: root.path)
        let result = await pipeline.prepareScanIncompleteOverride(
            rows: [row(target)],
            scanIssues: [.init(
                path: lockedChild.path,
                reason: .enumerationFailed,
                stage: .enumerate,
                posixErrorCode: EIO
            )],
            scanSessionID: UUID()
        )

        guard case .strictConfirmation(let request, let vendorRequest) = result else {
            return XCTFail("Expected target-level strict confirmation, got \(result)")
        }
        XCTAssertEqual(request.paths, [target.path])
        XCTAssertNil(vendorRequest)
    }

    func test_snapshotHardForbidWinsBeforeFilesystemProbe() async {
        let path = "/System/Library/DoNotTouch"
        let pipeline = TrashPipeline()
        let result = await pipeline.prepareScanIncompleteOverride(
            rows: [row(
                URL(fileURLWithPath: path),
                verdict: .forbid,
                rejection: .hardForbidPrefix
            )],
            scanIssues: [.init(path: path, reason: .enumerationFailed)],
            scanSessionID: UUID()
        )

        guard case .blocked(let rejections) = result else {
            return XCTFail("Hard forbid must never become strict confirmation")
        }
        XCTAssertEqual(rejections.first?.reason, SafetyRejection.hardForbidPrefix.rawValue)
    }

    func test_parentWithoutWriteAndSearchCapabilityHasTypedPosixBlock() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let target = parent.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(parent.path, S_IRUSR | S_IXUSR), 0)
        defer { _ = chmod(parent.path, S_IRWXU) }

        let result = await TrashPipeline(home: root.path).prepareScanIncompleteOverride(
            rows: [row(target)],
            scanIssues: [.init(path: target.path + "/unreadable", reason: .permissionDenied)],
            scanSessionID: UUID()
        )

        guard case .blocked(let rejections) = result else {
            return XCTFail("A non-mutable parent must not reach confirmation")
        }
        XCTAssertEqual(
            rejections.first?.reason,
            ScanIncompleteTargetRejectionReason.posixPermissionDenied.rawValue
        )
    }

    func test_symlinkEscapingHomeNeverBecomesStrictOverride() async throws {
        let container = try makeRoot()
        defer { try? FileManager.default.removeItem(at: container) }
        let home = container.appendingPathComponent("home", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = home.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let result = await TrashPipeline(home: home.path).prepareScanIncompleteOverride(
            rows: [row(link, isDirectory: true)],
            scanIssues: [.init(path: link.path, reason: .enumerationFailed)],
            scanSessionID: UUID()
        )

        guard case .blocked(let rejections) = result else {
            return XCTFail("Resolved path outside HOME must remain non-bypassable")
        }
        XCTAssertEqual(rejections.first?.reason, SafetyRejection.outsideUserDeletionScope.rawValue)
    }

    func test_inodeReplacementAfterConfirmationIsRejectedBeforeRecycle() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let issue = ScanIncompleteIssue(path: target.path + "/child", reason: .enumerationFailed)
        let pipeline = TrashPipeline(home: root.path)
        let preparation = await pipeline.prepareScanIncompleteOverride(
            rows: [row(target)],
            scanIssues: [issue],
            scanSessionID: UUID()
        )
        guard case .strictConfirmation(let request, _) = preparation else {
            return XCTFail("Expected strict request")
        }

        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let disposition = await pipeline.submitToTrashReturningDisposition(
            paths: [target.path],
            accessDeniedPaths: [issue.path],
            vendorOverrideRequest: nil,
            scanIncompleteOverrideRequest: request
        )

        guard case .preSubmitRejected(.invalidScanIncompleteOverride(let rejections)) = disposition else {
            return XCTFail("Identity replacement must stop before NSWorkspace.recycle")
        }
        XCTAssertEqual(
            rejections.first?.reason,
            ScanIncompleteTargetRejectionReason.identityChanged.rawValue
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func test_newDeniedPathNotPresentInTypedRequestFailsClosed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let frozenIssue = ScanIncompleteIssue(path: target.path + "/known", reason: .enumerationFailed)
        let pipeline = TrashPipeline(home: root.path)
        let preparation = await pipeline.prepareScanIncompleteOverride(
            rows: [row(target)],
            scanIssues: [frozenIssue],
            scanSessionID: UUID()
        )
        guard case .strictConfirmation(let request, _) = preparation else {
            return XCTFail("Expected strict request")
        }

        let newlyDenied = target.path + "/new-denial"
        let disposition = await pipeline.submitToTrashReturningDisposition(
            paths: [target.path],
            accessDeniedPaths: [frozenIssue.path, newlyDenied],
            vendorOverrideRequest: nil,
            scanIncompleteOverrideRequest: request
        )

        guard case .preSubmitRejected(.invalidScanIncompleteOverride(let rejections)) = disposition else {
            return XCTFail("New evidence must require a new confirmation")
        }
        XCTAssertEqual(rejections.first?.path, newlyDenied)
        XCTAssertEqual(
            rejections.first?.reason,
            ScanIncompleteTargetRejectionReason.missingTypedEvidence.rawValue
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func test_vendorAndScanIncompleteCapabilitiesAreBothCarried() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Library/Android/sdk/system-images", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let vendor = VendorRule(
            name: "Android SDK",
            paths: [PathRule(path: target.path, verdict: .forbid)]
        )
        let pipeline = TrashPipeline(vendors: [vendor], home: root.path)

        let result = await pipeline.prepareScanIncompleteOverride(
            rows: [row(target, verdict: .forbid, rejection: .vendorPathRule)],
            scanIssues: [.init(path: target.path + "/android-36.1", reason: .metadataUnavailable)],
            scanSessionID: UUID()
        )

        guard case .strictConfirmation(let scanRequest, let vendorRequest) = result else {
            return XCTFail("Both strict risks must survive preparation")
        }
        XCTAssertEqual(scanRequest.paths, [target.path])
        XCTAssertEqual(vendorRequest?.paths, [target.path])
    }

    func test_toolExecutionPlanCarriesExactScanRequest() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let preparation = await TrashPipeline(home: root.path).prepareScanIncompleteOverride(
            rows: [row(target)],
            scanIssues: [.init(path: target.path + "/child", reason: .enumerationFailed)],
            scanSessionID: UUID()
        )
        guard case .strictConfirmation(let request, _) = preparation else {
            return XCTFail("Expected strict request")
        }

        let plan = ToolTrashExecutionPlanner.makePlan(
            candidates: [.init(path: target.path, title: "target", bundleIDPrefix: nil)],
            resolution: .moveAllToTrash,
            runningApplications: [],
            scanIncompleteOverrideRequest: request,
            strictConfirmationToken: "DELETE"
        )

        XCTAssertEqual(plan.paths, [target.path])
        XCTAssertEqual(plan.scanIncompleteOverrideRequest, request)
        XCTAssertEqual(plan.strictConfirmationToken, "DELETE")
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TargetRevalidator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func row(
        _ url: URL,
        isDirectory: Bool = true,
        verdict: SafetyVerdict = .safe,
        rejection: SafetyRejection = .ok
    ) -> RowItem {
        RowItem(
            id: url.path,
            url: url,
            title: url.lastPathComponent,
            isDirectory: isDirectory,
            bytes: 1,
            logicalBytes: 1,
            fileCount: 1,
            verdict: verdict,
            rejection: rejection
        )
    }
}
