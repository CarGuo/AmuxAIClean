import Dispatch
import Foundation
import ScanKit

/// Machine-readable final Duplicate verification failures. They remain pre-submit blocks: no
/// receipt or operation-result payload may be created from any of these cases.
public enum DuplicateDeletionVerificationRejectionReason: String, Sendable, Equatable {
    case invalidEvidence = "duplicateVerification.invalidEvidence"
    case targetIdentityChanged = "duplicateVerification.targetIdentityChanged"
    case targetContentChanged = "duplicateVerification.targetContentChanged"
    case retainedReferenceChanged = "duplicateVerification.retainedReferenceChanged"
    case verificationCancelled = "duplicateVerification.cancelled"
}

/// Explicit cancellation shared by the caller Task and the GCD hashing worker.
///
/// v2026.07.17 root-cause record: a `DispatchQueue.async` closure has no caller Swift-Task
/// cancellation context, so consulting `Task.isCancelled` inside POSIX read loops can remain
/// false forever. Every read chunk now consults this lock-protected token instead. The unchecked
/// conformance is limited to one Boolean whose every access is protected by `NSLock`.
final class DuplicateDeletionVerificationCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Bounded item-level progress for UI/logging integration. The verifier emits at most
/// `targetCount + 4` values; it never reports one event per read chunk. Callbacks arrive on the
/// hashing worker queue, so a UI consumer must explicitly hop to MainActor and revision-gate it.
public struct DuplicateDeletionVerificationProgress: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case verifyingTargets
        case verifyingRetainedReference
        /// Emitted by TrashPipeline only after the verifier returned with no rejection. This is
        /// distinct from `.completed`, which means all reads finished but may still carry a
        /// content/identity rejection.
        case submittingToTrash
        case completed
        case cancelled
    }

    public let phase: Phase
    public let completedItems: Int
    public let totalItems: Int
    public let currentPath: String?

    public init(
        phase: Phase,
        completedItems: Int,
        totalItems: Int,
        currentPath: String?
    ) {
        self.phase = phase
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.currentPath = currentPath
    }
}

/// Typed execution progress crossing the shared deletion boundary.
///
/// v2026.07.17 root-cause record: Duplicate's final full-content verification already emitted
/// bounded item progress, but the shared `DeletionPipeline` API discarded it. The confirmation
/// sheet therefore disappeared into an unobservable multi-gigabyte rehash. Keep this source-
/// typed so ordinary Trash submissions remain behaviorally unchanged and future sources cannot
/// accidentally project Duplicate-specific phases.
public enum DeletionExecutionProgress: Sendable, Equatable {
    case duplicate(DuplicateDeletionVerificationProgress)
    case trash(TrashExecutionProgress)
}

public typealias DeletionExecutionProgressObserver = @Sendable (DeletionExecutionProgress) -> Void

/// Observable phases of an ordinary `NSWorkspace.recycle` transaction. `completedItems` means
/// the pipeline has received a terminal/typed state for those inputs; it never means every item
/// succeeded. Success/failure remains exclusively in `TrashSubmissionDisposition`.
public struct TrashExecutionProgress: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case finalValidation
        case submitting
        case diagnosingItems
        case finalizing
    }

    public let phase: Phase
    public let completedItems: Int
    public let totalItems: Int
    public let currentPath: String?

    public init(phase: Phase, completedItems: Int, totalItems: Int, currentPath: String?) {
        self.phase = phase
        self.completedItems = max(0, min(completedItems, max(0, totalItems)))
        self.totalItems = max(0, totalItems)
        self.currentPath = currentPath
    }
}

/// Exact content/identity proof frozen into a Duplicate deletion intent.
///
/// A valid request always binds every selected target plus one deterministic, unselected copy.
/// Verifying only the targets would prove that they still match an old digest, but would not
/// prove that the user still retains a matching copy after the move to Trash.
public struct DuplicateDeletionVerificationRequest: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let path: String
        let identity: DuplicateFileIdentity
    }

    let targetEntries: [Entry]
    let retainedReference: Entry
    let fingerprint: DuplicateContentFingerprint

    var targetPaths: [String] { targetEntries.map(\.path) }
    var retainedReferencePath: String { retainedReference.path }
    var verificationItemCount: Int { targetEntries.count + 1 }

    init?(group: DuplicateGroup, targetPaths: [String]) {
        guard group.reliability == .full,
              let fingerprint = group.contentFingerprint,
              fingerprint.logicalBytes == group.logicalBytes,
              !targetPaths.isEmpty else { return nil }

        let normalizedTargets = targetPaths.map(Self.normalize)
        let selected = Set(normalizedTargets)
        guard selected.count == targetPaths.count,
              Set(normalizedTargets.map(TrashPipeline.normalizePath)).count == targetPaths.count,
              selected.count < group.files.count else { return nil }

        var entriesByPath: [String: Entry] = [:]
        entriesByPath.reserveCapacity(group.files.count)
        var executionPaths = Set<String>()
        for file in group.files {
            let path = Self.normalize(file.path)
            guard entriesByPath[path] == nil,
                  executionPaths.insert(TrashPipeline.normalizePath(path)).inserted,
                  let identity = file.snapshotIdentity,
                  identity.isRegularFile,
                  identity.logicalBytes == fingerprint.logicalBytes else { return nil }
            entriesByPath[path] = Entry(path: path, identity: identity)
        }
        guard selected.isSubset(of: Set(entriesByPath.keys)),
              let retained = group.files.lazy
                .map({ Self.normalize($0.path) })
                .first(where: { !selected.contains($0) })
                .flatMap({ entriesByPath[$0] }) else { return nil }

        let orderedTargets = normalizedTargets.compactMap { entriesByPath[$0] }
        guard orderedTargets.count == normalizedTargets.count else { return nil }
        self.targetEntries = orderedTargets
        self.retainedReference = retained
        self.fingerprint = fingerprint
    }

    func restricting(to paths: [String]) -> DuplicateDeletionVerificationRequest? {
        let normalized = paths.map(Self.normalize)
        let wanted = Set(normalized)
        let available = Dictionary(uniqueKeysWithValues: targetEntries.map { ($0.path, $0) })
        guard !normalized.isEmpty,
              wanted.count == normalized.count,
              wanted.isSubset(of: Set(available.keys)),
              !wanted.contains(retainedReference.path) else { return nil }
        let entries = normalized.compactMap { available[$0] }
        guard entries.count == normalized.count else { return nil }
        return DuplicateDeletionVerificationRequest(
            targetEntries: entries,
            retainedReference: retainedReference,
            fingerprint: fingerprint
        )
    }

    func matchesExactTargets(_ paths: [String]) -> Bool {
        paths.map(TrashPipeline.normalizePath)
            == targetPaths.map(TrashPipeline.normalizePath)
    }

    /// Cheap post-hash fence used immediately beside every actual recycle claim. The complete
    /// digest was already verified once for all targets and this survivor; this comparison only
    /// detects later ordinary replacement or writes through inode/size/mtime/ctime drift.
    func retainedReferenceStillMatchesIdentity() -> Bool {
        DuplicateScanner.matchesCurrentPathIdentity(
            path: retainedReference.path,
            expectedIdentity: retainedReference.identity
        )
    }

    private init(
        targetEntries: [Entry],
        retainedReference: Entry,
        fingerprint: DuplicateContentFingerprint
    ) {
        self.targetEntries = targetEntries
        self.retainedReference = retainedReference
        self.fingerprint = fingerprint
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

/// Source-specific proof carried by the otherwise shared deletion state machine.
public enum DeletionExecutionVerification: Sendable, Equatable {
    case duplicate(DuplicateDeletionVerificationRequest)
    case uninstall(UninstallCandidateVerificationRequest)
}

/// Claim-adjacent, cheap fence retained after the initial complete hash pass. It is reused for
/// every batch and every single-item diagnostic retry, so the explicitly retained survivor
/// cannot drift while later targets are being submitted.
struct DuplicateDeletionClaimFence: Sendable {
    let request: DuplicateDeletionVerificationRequest
    let cancellationToken: DuplicateDeletionVerificationCancellationToken
    private let targetIdentityByPath: [String: DuplicateFileIdentity]

    init(
        request: DuplicateDeletionVerificationRequest,
        cancellationToken: DuplicateDeletionVerificationCancellationToken
    ) {
        self.request = request
        self.cancellationToken = cancellationToken
        self.targetIdentityByPath = Dictionary(uniqueKeysWithValues: request.targetEntries.map {
            (TrashPipeline.normalizePath($0.path), $0.identity)
        })
    }

    func cancel() {
        cancellationToken.cancel()
    }

    func rejection(blocking paths: [String]) -> TrashPendingOperationRejection? {
        if cancellationToken.isCancelled {
            return TrashPendingOperationRejection(
                reasonsByPath: Dictionary(uniqueKeysWithValues: paths.map {
                    ($0, TrashPendingOperationRejection.Reason.duplicateVerificationCancelled)
                })
            )
        }
        guard request.retainedReferenceStillMatchesIdentity() else {
            return TrashPendingOperationRejection(
                reasonsByPath: Dictionary(uniqueKeysWithValues: paths.map {
                    ($0, TrashPendingOperationRejection.Reason.duplicateRetainedReferenceChanged)
                })
            )
        }

        var changedTargets: [String: TrashPendingOperationRejection.Reason] = [:]
        changedTargets.reserveCapacity(paths.count)
        for path in paths {
            guard let expectedIdentity = targetIdentityByPath[path],
                  DuplicateScanner.matchesCurrentPathIdentity(
                    path: path,
                    expectedIdentity: expectedIdentity
                  ) else {
                changedTargets[path] = .duplicateTargetIdentityChanged
                continue
            }
        }
        return changedTargets.isEmpty
            ? nil
            : TrashPendingOperationRejection(reasonsByPath: changedTargets)
    }
}

/// Final, read-only verifier. Synchronous POSIX reads run on a utility dispatch queue, never on
/// MainActor or a Swift cooperative executor. The caller remains responsible for placing this
/// immediately before the shared AppKit submission boundary.
enum DuplicateDeletionFinalVerifier {
    static func verify(
        request: DuplicateDeletionVerificationRequest,
        authorizedPaths: [String],
        cancellationToken: DuplicateDeletionVerificationCancellationToken = .init(),
        progress: (@Sendable (DuplicateDeletionVerificationProgress) -> Void)? = nil
    ) async -> [DeletionPreflight.Rejection] {
        guard request.matchesExactTargets(authorizedPaths) else {
            return authorizedPaths.map {
                .init(
                    path: $0,
                    reason: DuplicateDeletionVerificationRejectionReason.invalidEvidence.rawValue
                )
            }
        }

        let cancelledRejections = authorizedPaths.map {
            DeletionPreflight.Rejection(
                path: $0,
                reason: DuplicateDeletionVerificationRejectionReason.verificationCancelled.rawValue
            )
        }
        let totalItems = request.verificationItemCount

        return await withTaskCancellationHandler {
            let result = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard !cancellationToken.isCancelled else {
                        progress?(.init(
                            phase: .cancelled,
                            completedItems: 0,
                            totalItems: totalItems,
                            currentPath: nil
                        ))
                        continuation.resume(returning: cancelledRejections)
                        return
                    }

                    var rejections: [DeletionPreflight.Rejection] = []
                    rejections.reserveCapacity(request.targetEntries.count + 1)
                    var completedItems = 0
                    progress?(.init(
                        phase: .verifyingTargets,
                        completedItems: completedItems,
                        totalItems: totalItems,
                        currentPath: nil
                    ))

                    for entry in request.targetEntries {
                        let result = Self.verificationResult(
                            for: entry,
                            fingerprint: request.fingerprint,
                            cancellationToken: cancellationToken
                        )
                        guard result != .cancelled, !cancellationToken.isCancelled else {
                            progress?(.init(
                                phase: .cancelled,
                                completedItems: completedItems,
                                totalItems: totalItems,
                                currentPath: entry.path
                            ))
                            continuation.resume(returning: cancelledRejections)
                            return
                        }
                        if let rejection = Self.rejection(
                            result: result,
                            entry: entry,
                            retainedReference: false
                        ) {
                            rejections.append(rejection)
                        }
                        completedItems += 1
                        progress?(.init(
                            phase: .verifyingTargets,
                            completedItems: completedItems,
                            totalItems: totalItems,
                            currentPath: entry.path
                        ))
                    }

                    progress?(.init(
                        phase: .verifyingRetainedReference,
                        completedItems: completedItems,
                        totalItems: totalItems,
                        currentPath: request.retainedReference.path
                    ))
                    let retainedResult = Self.verificationResult(
                        for: request.retainedReference,
                        fingerprint: request.fingerprint,
                        cancellationToken: cancellationToken
                    )
                    guard retainedResult != .cancelled, !cancellationToken.isCancelled else {
                        progress?(.init(
                            phase: .cancelled,
                            completedItems: completedItems,
                            totalItems: totalItems,
                            currentPath: request.retainedReference.path
                        ))
                        continuation.resume(returning: cancelledRejections)
                        return
                    }
                    if let rejection = Self.rejection(
                        result: retainedResult,
                        entry: request.retainedReference,
                        retainedReference: true
                    ) {
                        rejections.append(rejection)
                    }
                    completedItems += 1
                    progress?(.init(
                        phase: .completed,
                        completedItems: completedItems,
                        totalItems: totalItems,
                        currentPath: nil
                    ))
                    continuation.resume(returning: rejections)
                }
            }
            return cancellationToken.isCancelled ? cancelledRejections : result
        } onCancel: {
            cancellationToken.cancel()
        }
    }

    private static func verificationResult(
        for entry: DuplicateDeletionVerificationRequest.Entry,
        fingerprint: DuplicateContentFingerprint,
        cancellationToken: DuplicateDeletionVerificationCancellationToken
    ) -> DuplicateContentVerificationResult {
        DuplicateScanner.verifyFullContent(
            path: entry.path,
            expectedIdentity: entry.identity,
            expectedFingerprint: fingerprint,
            isCancelled: { cancellationToken.isCancelled }
        )
    }

    private static func rejection(
        result: DuplicateContentVerificationResult,
        entry: DuplicateDeletionVerificationRequest.Entry,
        retainedReference: Bool
    ) -> DeletionPreflight.Rejection? {
        let reason: DuplicateDeletionVerificationRejectionReason
        switch result {
        case .verified:
            return nil
        case .cancelled:
            reason = .verificationCancelled
        case .contentChanged:
            reason = retainedReference ? .retainedReferenceChanged : .targetContentChanged
        case .identityChangedOrUnavailable:
            reason = retainedReference ? .retainedReferenceChanged : .targetIdentityChanged
        }
        return .init(path: entry.path, reason: reason.rawValue)
    }
}
