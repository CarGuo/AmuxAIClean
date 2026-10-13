import Darwin
import Foundation
import SafetyKit
import XCTest
@testable import AppUI

// v2026.09.06 SR-01/SR-02: permanent regression cases promoted from the failing
// safety audit without weakening its assertions. All files and recovery stores are
// UUID-owned temporary fixtures; real recycle fixtures are identity-checked and restored.
final class SafetyReviewRegressionTests: XCTestCase {
    // v2026.10.10: real ledger reservations use execution aliases; all review proofs must
    // compare object identity across that boundary without rewriting the policy namespace.
    func test_physicalReviewProofsJoinRealLedgerAndStillRejectReplacement() async throws {
        let root = try fixture()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let target = root.appendingPathComponent("reviewed")
        try Data([1]).write(to: target)
        let pointer = try XCTUnwrap(target.path.withCString { realpath($0, nil) })
        let physical = String(cString: pointer)
        free(pointer)
        let execution = TrashPipeline.normalizePath(physical)
        XCTAssertNotEqual(physical, execution)
        let original = try identity(target)
        let birthSeconds = try XCTUnwrap(original.birthTimeSeconds)
        let birthNanoseconds = try XCTUnwrap(original.birthTimeNanoseconds)
        let generation = try XCTUnwrap(original.generation)
        guard case .ready(let reviewed) = await ReviewedDeletionObjects.capture(
            paths: [physical], expectedIdentities: [:]
        ) else { return XCTFail("Physical fixture must be reviewable") }
        let uninstall = try XCTUnwrap(UninstallCandidateVerificationRequest(candidates: [
            .init(path: physical, bytes: 1, fileCount: 1, objectIdentity: original,
                  matchReason: .bundleID("com.example.review"))
        ]))
        let incomplete = ScanIncompleteOverrideRequest(scanSessionID: UUID(), entries: [
            .init(candidateID: UUID(), path: physical, title: "reviewed", isDirectory: false,
                  bytes: 1, fileCount: 1, snapshotVerdict: .safe, snapshotRejectionRawValue: "ok",
                  identity: .init(device: original.device, inode: original.inode,
                                  fileType: original.fileType,
                                  birthTimeSeconds: birthSeconds,
                                  birthTimeNanoseconds: birthNanoseconds,
                                  generation: generation, resolvedPath: execution),
                  incompleteIssues: [])
        ])
        let ledger = PersistentTrashPendingOperationLedger(
            fileURL: root.appendingPathComponent("ledger.json"),
            activeOperationRegistry: TrashActiveOperationRegistry()
        )
        let operation = UUID()
        defer { XCTAssertTrue(ledger.finish(operationID: operation, retainingPendingPaths: [])) }
        guard case .reserved(let paths, _) = ledger.reserve(paths: [physical], operationID: operation)
        else { return XCTFail("Real ledger reservation must succeed") }
        XCTAssertEqual(paths, [execution])
        let frozen = try XCTUnwrap(ledger.frozenIdentities(paths: paths, operationID: operation))
        XCTAssertEqual(reviewed.changedPaths(comparedTo: frozen), [])
        XCTAssertEqual(uninstall.changedPaths(comparedTo: frozen), [])
        XCTAssertEqual(incomplete.changedPaths(comparedTo: frozen), [])
        XCTAssertTrue(reviewed.matchesExactTargets([physical]))
        XCTAssertFalse(reviewed.matchesExactTargets([execution]))
        guard case .ready(let duplicateAliases) = await ReviewedDeletionObjects.capture(
            paths: [physical, execution], expectedIdentities: [:]
        ) else { return XCTFail("Both spellings must name the owned fixture") }
        XCTAssertEqual(duplicateAliases.changedPaths(comparedTo: frozen), [execution])

        try FileManager.default.moveItem(at: target, to: root.appendingPathComponent("original"))
        try Data([2]).write(to: target)
        let replacement = [execution: try identity(target)]
        XCTAssertEqual(reviewed.changedPaths(comparedTo: replacement), [execution])
        XCTAssertEqual(uninstall.changedPaths(comparedTo: replacement), [execution])
        XCTAssertEqual(incomplete.changedPaths(comparedTo: replacement), [execution])
        guard case .rejected(let rejection, _) = ledger.claim(
            paths: paths, operationID: operation, attemptID: UUID()
        ) else { return XCTFail("Ledger claim must still reject the replacement") }
        XCTAssertEqual(rejection.reasonsByPath[execution], .freshReviewRequired)
        XCTAssertEqual(try Data(contentsOf: target), Data([2]))
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmuxSafetyReview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private func identity(_ url: URL) throws -> TrashObjectIdentity {
        guard case .present(let value) = TrashObjectIdentity.probe(path: url.path) else {
            throw NSError(domain: "SafetyReviewFixture", code: 1)
        }
        return value
    }

    private func vendors(home: String) throws -> [VendorRule] {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        return try RuleLoader.loadVendors(
            from: repo.appendingPathComponent("Resources/Rules/vendors.yaml"), home: home
        )
    }

    @MainActor
    func test_reviewedObjectReplacementMustNotInheritAuthorization_normal() async throws {
        try await exerciseReview(mode: .normal, replacing: true)
    }

    @MainActor
    func test_reviewedObjectReplacementMustNotInheritAuthorization_professional() async throws {
        try await exerciseReview(mode: .professional, replacing: true)
    }

    @MainActor
    func test_unchangedOwnedFixtureRecyclesOnlySelectedObject() async throws {
        try await exerciseReview(mode: .normal, replacing: false)
    }

    @MainActor
    func test_analysisWithoutScanIdentityStillFreezesTheObjectBeforeConfirmation() async throws {
        try await exerciseReview(mode: .normal, replacing: true, suppliesScanIdentity: false)
    }

    @MainActor
    private func exerciseReview(
        mode: DeletionUserMode, replacing: Bool, suppliesScanIdentity: Bool = true
    ) async throws {
        let root = try fixture()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let home = root.appendingPathComponent("home")
        let cache = home.appendingPathComponent("Library/Caches/review-probe")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let target = cache.appendingPathComponent("reviewed-\(UUID().uuidString).txt")
        let saved = root.appendingPathComponent("original-reviewed-object.txt")
        let sentinel = cache.appendingPathComponent("unselected-sentinel.txt")
        try Data("reviewed A".utf8).write(to: target)
        try Data("must remain".utf8).write(to: sentinel)
        let reviewedIdentity = try identity(target)
        let pipeline = TrashPipeline(
            vendors: try vendors(home: home.path), home: home.path,
            whitelistStore: WhitelistStore(storageURL: nil), externalDeletionRoots: []
        )
        let coordinator = DeletionInteractionCoordinator(
            pipeline: pipeline,
            undoHistoryStore: UndoHistoryStore(
                storeURL: root.appendingPathComponent("audit-undo.json"),
                allowedRestoreRoots: [home.path]
            )
        )
        let revision = DeletionSnapshotIdentity(sessionID: UUID(), revision: 1)
        let intent = try coordinator.makeIntent(
            origin: mode == .normal ? .storageAnalysis : .tree,
            mode: mode, snapshotIdentity: revision,
            candidates: [.init(
                path: target.path, title: "reviewed A", isDirectory: false,
                bytes: 10, fileCount: 1,
                sourceObjectIdentity: suppliesScanIdentity ? reviewedIdentity : nil
            )]
        )
        guard case .confirmation(let prepared) = await coordinator.prepare(
            intent: intent, currentSnapshotIdentity: revision
        ), case .authorized(let authorization) = coordinator.authorize(
            prepared: prepared,
            executionPlan: ToolTrashExecutionPlan(paths: [target.path], runningAppSkipped: [])
        ) else { return XCTFail("Fixture must reach ordinary shared confirmation") }

        if replacing {
            try FileManager.default.moveItem(at: target, to: saved)
            try Data("unreviewed replacement B".utf8).write(to: target)
            XCTAssertNotEqual(try identity(target), reviewedIdentity)
        }
        let submittedIdentity = try identity(target)
        let disposition = await coordinator.submit(authorization, accessDeniedPaths: [])
        switch disposition {
        case .blocked(let block):
            print("[SAFETY-AUDIT] mode=\(mode) replacement=\(replacing) blocked=\(block.rejections.map(\.reason))")
            XCTAssertTrue(replacing, "Unchanged positive control must actually recycle")
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        case .requiresConfirmation:
            XCTAssertTrue(replacing, "Unchanged positive control needs no second confirmation")
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        case .completed(let completed):
            print("[SAFETY-AUDIT] mode=\(mode) replacement=\(replacing) moved=\(completed.result.pairs.count)")
            XCTAssertEqual(completed.result.pairs.count, 1, "Must prove a real completed fixture move")
            for (original, trashed) in completed.result.pairs {
                XCTAssertEqual(original, target.path)
                let destination = URL(fileURLWithPath: trashed)
                // Restore only the exact fixture returned by recycle, after identity and
                // vacant-destination checks. Never enumerate or empty the user's Trash.
                guard original == target.path,
                      try identity(destination) == submittedIdentity,
                      !FileManager.default.fileExists(atPath: target.path) else {
                    return XCTFail("Refuse cleanup of any object other than this owned fixture")
                }
                try FileManager.default.moveItem(at: destination, to: target)
            }
            XCTAssertFalse(replacing, "SECURITY.md §1.5: a replacement object inherited the old authorization and was recycled")
        }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "must remain")
        if replacing {
            XCTAssertEqual(try identity(saved), reviewedIdentity)
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unreviewed replacement B")
        }
    }

    func test_sensitiveCredentialAncestorMustNotBypassProtectedLeaf() async throws {
        let root = try fixture()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let home = root.appendingPathComponent("home")
        let parent = home.appendingPathComponent(".config")
        let credential = parent.appendingPathComponent("gh/hosts.yml")
        try FileManager.default.createDirectory(at: credential.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic credential sentinel".utf8).write(to: credential)
        let pipeline = TrashPipeline(
            vendors: try vendors(home: home.path), home: home.path,
            whitelistStore: WhitelistStore(storageURL: nil), externalDeletionRoots: []
        )
        let leaf = await pipeline.preflight(paths: [credential.path], accessDeniedPaths: [])
        let ancestor = await pipeline.preflight(paths: [parent.path], accessDeniedPaths: [])
        print("[SAFETY-AUDIT] credentialLeafAllowed=\(leaf.canProceed) ancestorAllowed=\(ancestor.canProceed) ancestorRejections=\(ancestor.rejections)")
        XCTAssertFalse(leaf.canProceed)
        XCTAssertEqual(leaf.rejections.first?.reason, SafetyRejection.sensitiveCredential.rawValue)
        XCTAssertFalse(ancestor.canProceed, "A parent directory recycle also removes its hard-forbidden credential descendant")
        XCTAssertEqual(try String(contentsOf: credential, encoding: .utf8), "synthetic credential sentinel")
    }

    func test_replacementBeforeReviewAndMissingObjectCannotMintEvidence() async throws {
        let root = try fixture()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let target = root.appendingPathComponent("item")
        try Data([1]).write(to: target)
        let original = try identity(target)
        try FileManager.default.moveItem(at: target, to: root.appendingPathComponent("original"))
        try Data([2]).write(to: target)
        let pipeline = TrashPipeline(home: root.path, externalDeletionRoots: [])
        guard case .blocked(let replaced) = await pipeline.prepareReviewedObjects(
            paths: [target.path], expectedIdentities: [target.path: original]
        ) else { return XCTFail("Changed scan evidence must be rejected before review") }
        XCTAssertEqual(replaced.map(\.reason), [TrashPendingOperationRejection.Reason.identityChanged.rawValue])
        guard case .blocked(let missing) = await pipeline.prepareReviewedObjects(
            paths: [root.appendingPathComponent("missing").path], expectedIdentities: [:]
        ) else { return XCTFail("Missing objects cannot receive deletion proof") }
        XCTAssertEqual(missing.map(\.reason), [TrashPendingOperationRejection.Reason.targetMissing.rawValue])
        XCTAssertEqual(try Data(contentsOf: target), Data([2]))
    }

    func test_legacyRealDeleteAndTypedSubmissionWithoutProofLeaveTheObjectUntouched() async throws {
        let root = try fixture()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let target = root.appendingPathComponent("unreviewed")
        try Data([7]).write(to: target)
        let pipeline = TrashPipeline(home: root.path, externalDeletionRoots: [])
        let legacy = await pipeline.moveToTrash(paths: [target.path], dryRun: false)
        XCTAssertEqual(legacy.0, 0)
        XCTAssertTrue(legacy.3.isEmpty)
        XCTAssertEqual(try Data(contentsOf: target), Data([7]))
        guard case .preSubmitRejected(.pendingOperation(let rejection)) = await pipeline.submitToTrashReturningDisposition(
            paths: [target.path], accessDeniedPaths: [], vendorOverrideRequest: nil,
            scanIncompleteOverrideRequest: nil,
            reviewIdentity: DeletionSnapshotIdentity(sessionID: UUID(), revision: 1),
            executionVerification: nil
        ) else { return XCTFail("A scan revision without object proof must fail closed") }
        XCTAssertEqual(rejection.reasonsByPath[target.path], .freshReviewRequired)
        XCTAssertEqual(try Data(contentsOf: target), Data([7]))
    }

    @MainActor
    func test_smartCareRequestRetainsProofAcrossStampingAndRejectsReplacement() async throws {
        let root = try fixture()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let target = root.appendingPathComponent("cache")
        let skipped = root.appendingPathComponent("skipped-cache")
        try Data([1]).write(to: target)
        try Data([3]).write(to: skipped)
        let pipeline = TrashPipeline(home: root.path, externalDeletionRoots: [])
        let request = SmartCareCleanRequest(items: [target, skipped].map { url in
            SmartCareItem(id: url.path, bucketID: .appCache, path: url.path,
                          title: url.lastPathComponent, bytes: 1, fileCount: 1,
                          isDirectory: false, verdict: .safe)
        })
        guard case .ready(let objects) = await pipeline.prepareReviewedObjects(
            paths: request.paths, expectedIdentities: [:]
        ) else { return XCTFail("Owned fixtures must have reviewable identities") }
        let revision = DeletionSnapshotIdentity(sessionID: UUID(), revision: 2, categoryID: "smart-care")
        let bound = try XCTUnwrap(request.bindingReviewedObjects(objects))
            .stamped(summaryRevision: 2, selectionRevision: 1).bindingDeletionSnapshot(revision)
        XCTAssertEqual(bound.reviewedObjects, objects)
        XCTAssertEqual(bound.id, request.id)
        XCTAssertNil(objects.restricting(to: [root.appendingPathComponent("unselected").path]))
        XCTAssertNil(objects.restricting(to: [target.path, target.path]))
        let narrowed = try XCTUnwrap(bound.reviewedObjects?.restricting(to: [target.path]))
        XCTAssertTrue(narrowed.matchesExactTargets([target.path]))
        XCTAssertFalse(narrowed.matchesExactTargets(request.paths))
        try FileManager.default.moveItem(at: target, to: root.appendingPathComponent("original"))
        try Data([2]).write(to: target)
        let result = await TrashActionCoordinator(
            pipeline: pipeline,
            undoHistoryStore: UndoHistoryStore(storeURL: root.appendingPathComponent("undo.json"), allowedRestoreRoots: [root.path])
        ).submitConfirmed(
            paths: [target.path], source: "smart-care", accessDeniedPaths: [],
            reviewIdentity: bound.sourceDeletionSnapshotIdentity,
            executionVerification: .reviewedObjects(narrowed)
        )
        guard case .preSubmitRejected(.pendingOperation(let rejection)) = result else {
            return XCTFail("Smart Care must reject the replacement before any recycle")
        }
        XCTAssertEqual(rejection.reasonsByPath[target.path], .identityChanged)
        XCTAssertEqual(try Data(contentsOf: target), Data([2]))
        XCTAssertEqual(try Data(contentsOf: skipped), Data([3]))
    }
}
