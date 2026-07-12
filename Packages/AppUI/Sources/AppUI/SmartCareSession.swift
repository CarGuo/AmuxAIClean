import Combine
import Foundation
import Observation
import ScanKit

/// 普通模式的一键扫描会话。
///
/// 会话按顺序复用现有三个扫描入口，避免多个 `ScanCoordinator` 并发写同一份状态：
/// 推荐清理 -> 常见应用缓存 -> 开发缓存。每一段完成后只复制最终 rows，
/// 聚合与去重放到 detached task，主线程仅发布轻量进度和最终摘要。
@MainActor
@Observable
public final class SmartCareSession {
    public static let defaultSources: [SmartCareCandidateSource] = [
        .recommended,
        .commonAppCache,
        .developer
    ]
    public static let defaultStages = SmartCareScanStage.allCases

    public let care: SmartCareCoordinator
    @ObservationIgnored public let scanCoordinator: ScanCoordinator
    public private(set) var selectedStages: Set<SmartCareScanStage>
    public private(set) var startedAt: Date?
    public private(set) var finishedAt: Date?

    public var isBusy: Bool {
        switch care.phase {
        case .scanning, .cleaning:
            return true
        case .idle, .reviewing, .confirming, .completed, .failed, .cancelled:
            return false
        }
    }

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = UUID()

    public init(care: SmartCareCoordinator = SmartCareCoordinator(),
                scanCoordinator: ScanCoordinator = ScanCoordinator()) {
        self.care = care
        self.scanCoordinator = scanCoordinator
        self.selectedStages = Set(Self.defaultStages)
    }

    public var orderedSelectedStages: [SmartCareScanStage] {
        Self.defaultStages.filter(selectedStages.contains)
    }

    public func setStage(_ stage: SmartCareScanStage, selected: Bool) {
        guard !isBusy else { return }
        if selected {
            selectedStages.insert(stage)
        } else {
            selectedStages.remove(stage)
        }
    }

    public func prepareForRescan() {
        guard !isBusy else { return }
        startedAt = nil
        finishedAt = nil
        care.reset()
    }

    public func elapsedForDisplay(referenceDate: Date = Date()) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, (finishedAt ?? referenceDate).timeIntervalSince(startedAt))
    }

    public func startScan(includeHidden: Bool,
                          enabledDeveloperRuleIDs: Set<String>,
                          home: String = NSHomeDirectory()) {
        if case .cleaning = care.phase { return }
        let plannedStages = orderedSelectedStages
        guard !plannedStages.isEmpty else { return }
        scanTask?.cancel()
        scanCoordinator.cancel()

        let generation = UUID()
        scanGeneration = generation
        startedAt = Date()
        finishedAt = nil
        care.beginScan()

        scanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let summary = try await self.runScan(
                    using: self.scanCoordinator,
                    plannedStages: plannedStages,
                    includeHidden: includeHidden,
                    enabledDeveloperRuleIDs: enabledDeveloperRuleIDs,
                    home: home
                )
                try Task.checkCancellation()
                guard self.scanGeneration == generation else { return }
                self.finishedAt = Date()
                self.care.finishScan(summary)
            } catch is CancellationError {
                guard self.scanGeneration == generation else { return }
                self.finishedAt = Date()
                self.care.cancel()
            } catch {
                guard self.scanGeneration == generation else { return }
                self.finishedAt = Date()
                self.care.fail(.scanFailed(error.localizedDescription))
            }

            if self.scanGeneration == generation {
                self.scanTask = nil
            }
        }
    }

    public func cancelScan() {
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        scanCoordinator.cancel()
        finishedAt = Date()
        care.cancel()
    }

    private func runScan(using scanCoordinator: ScanCoordinator,
                         plannedStages: [SmartCareScanStage],
                         includeHidden: Bool,
                         enabledDeveloperRuleIDs: Set<String>,
                         home: String) async throws -> SmartCareSummary {
        var candidates: [SmartCareCandidate] = []
        var completedBytes: Int64 = 0
        var completedFileCount = 0
        var completedSummary = SmartCareSummary.empty
        var completedStages: Set<SmartCareScanStage> = []

        for stage in plannedStages {
            try Task.checkCancellation()
            let result = try await collectStage(
                using: scanCoordinator,
                source: source(for: stage),
                expectedCategoryID: expectedCategoryID(for: stage),
                stage: stage,
                plannedStages: plannedStages,
                completedBytes: completedBytes,
                completedFileCount: completedFileCount,
                completedSummary: completedSummary,
                completedStages: completedStages,
                home: home
            ) {
                startStage(
                    stage,
                    using: scanCoordinator,
                    includeHidden: includeHidden,
                    enabledDeveloperRuleIDs: enabledDeveloperRuleIDs
                )
            }
            candidates.append(contentsOf: result.candidates)
            completedBytes &+= result.snapshot.totalBytes
            completedFileCount &+= result.snapshot.scannedFileCount
            completedStages.insert(stage)
            completedSummary = await buildSummary(candidates)
        }

        try Task.checkCancellation()
        care.updateProgress(
            SmartCareProgress(
                scannedBytes: completedBytes,
                safeBytes: completedSummary.safeBytes,
                scannedItemCount: candidates.count,
                activity: .finalizing,
                completedStages: completedStages,
                plannedStages: plannedStages,
                bucketSafeBytes: Self.bucketSafeBytes(from: completedSummary)
            )
        )
        return completedSummary
    }

    private func collectStage(using scanCoordinator: ScanCoordinator,
                              source: SmartCareCandidateSource,
                              expectedCategoryID: String,
                              stage: SmartCareScanStage,
                              plannedStages: [SmartCareScanStage],
                              completedBytes: Int64,
                              completedFileCount: Int,
                              completedSummary: SmartCareSummary,
                              completedStages: Set<SmartCareScanStage>,
                              home: String,
                              start: () -> Void) async throws -> (snapshot: ScanSnapshot, candidates: [SmartCareCandidate]) {
        care.updateProgress(
            SmartCareProgress(
                scannedBytes: completedBytes,
                safeBytes: completedSummary.safeBytes,
                scannedItemCount: completedFileCount,
                activity: .scanning(stage),
                completedStages: completedStages,
                plannedStages: plannedStages,
                bucketSafeBytes: Self.bucketSafeBytes(from: completedSummary)
            )
        )
        start()

        let snapshot = try await waitForFinishedSnapshot(
            using: scanCoordinator,
            expectedCategoryID: expectedCategoryID,
            stage: stage,
            plannedStages: plannedStages,
            completedBytes: completedBytes,
            completedFileCount: completedFileCount,
            completedSummary: completedSummary,
            completedStages: completedStages
        )
        let finalRows = snapshot.rows
        care.updateProgress(
            SmartCareProgress(
                scannedBytes: completedBytes + snapshot.totalBytes,
                safeBytes: completedSummary.safeBytes + snapshot.safeBytes,
                scannedItemCount: completedFileCount + snapshot.scannedFileCount,
                activity: .organizing(stage),
                completedStages: completedStages,
                plannedStages: plannedStages,
                bucketSafeBytes: Self.bucketSafeBytes(from: completedSummary)
            )
        )
        let stageCandidates = await Task.detached(priority: .userInitiated) {
            SmartCareSummaryBuilder.candidates(from: finalRows, source: source, home: home)
        }.value
        return (snapshot, stageCandidates)
    }

    private func waitForFinishedSnapshot(using scanCoordinator: ScanCoordinator,
                                         expectedCategoryID: String,
                                         stage: SmartCareScanStage,
                                         plannedStages: [SmartCareScanStage],
                                         completedBytes: Int64,
                                         completedFileCount: Int,
                                         completedSummary: SmartCareSummary,
                                         completedStages: Set<SmartCareScanStage>) async throws -> ScanSnapshot {
        for await snapshot in scanCoordinator.$snapshot.values {
            try Task.checkCancellation()
            guard snapshot.categoryID == expectedCategoryID else { continue }

            care.updateProgress(
                SmartCareProgress(
                    scannedBytes: completedBytes + snapshot.totalBytes,
                    safeBytes: completedSummary.safeBytes + snapshot.safeBytes,
                    scannedItemCount: completedFileCount + snapshot.scannedFileCount,
                    activity: .scanning(stage),
                    completedStages: completedStages,
                    plannedStages: plannedStages,
                    bucketSafeBytes: Self.bucketSafeBytes(from: completedSummary)
                )
            )

            guard snapshot.isFinished else { continue }
            if snapshot.rows.isEmpty, let error = scanCoordinator.lastError {
                throw SmartCareScanFailure.message(error)
            }
            return snapshot
        }
        throw CancellationError()
    }

    private func buildSummary(_ candidates: [SmartCareCandidate]) async -> SmartCareSummary {
        await Task.detached(priority: .userInitiated) {
            SmartCareSummaryBuilder.build(candidates: candidates)
        }.value
    }

    private func source(for stage: SmartCareScanStage) -> SmartCareCandidateSource {
        switch stage {
        case .core: return .recommended
        case .appCaches: return .commonAppCache
        case .developerCaches: return .developer
        }
    }

    private func expectedCategoryID(for stage: SmartCareScanStage) -> String {
        switch stage {
        case .core: return ScanCoordinator.multiRootCategoryID
        case .appCaches: return ScanCoordinator.commonAppCacheCategoryID
        case .developerCaches: return ScanCoordinator.developerCategoryID
        }
    }

    private func startStage(_ stage: SmartCareScanStage,
                            using scanCoordinator: ScanCoordinator,
                            includeHidden: Bool,
                            enabledDeveloperRuleIDs: Set<String>) {
        switch stage {
        case .core:
            scanCoordinator.scanRecommended(includeHidden: includeHidden)
        case .appCaches:
            scanCoordinator.scanCommonAppCaches(includeConfirm: true)
        case .developerCaches:
            scanCoordinator.scanDeveloper(
                includeHidden: includeHidden,
                enabledRuleIDs: enabledDeveloperRuleIDs
            )
        }
    }

    private static func bucketSafeBytes(from summary: SmartCareSummary) -> [SmartCareBucketID: Int64] {
        Dictionary(uniqueKeysWithValues: summary.buckets.map { ($0.id, $0.safeBytes) })
    }
}

private enum SmartCareScanFailure: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}
