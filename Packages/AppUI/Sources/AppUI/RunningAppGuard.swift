import AppKit
import Foundation

/// 删除前的运行中 App 风险提示。
///
/// 常见软件缓存经常由对应 App 持续写入。运行状态只用于让用户选择“跳过”或
/// “仍尝试移到废纸篓”，不属于 SafetyEngine 的安全等级，也不会绕过底层安全规则。
public enum RunningAppGuard {
    /// 运行冲突检测所需的最小输入。它刻意不携带 SafetyVerdict：
    /// 运行状态只决定“跳过还是仍尝试”，最终能否删除仍由 TrashPipeline 重新预检。
    public struct Candidate: Sendable, Equatable, Identifiable {
        public var id: String { path }
        public let path: String
        public let title: String
        public let titlePresentation: LocalizedTextDescriptor
        public let bundleIDPrefix: String?

        public init(path: String, title: String, bundleIDPrefix: String? = nil,
                    titlePresentation: LocalizedTextDescriptor? = nil) {
            self.path = path
            self.title = title
            self.titlePresentation = titlePresentation ?? .verbatim(title)
            self.bundleIDPrefix = bundleIDPrefix
        }

        public func displayTitle(locale: Locale) -> String {
            titlePresentation.localized(locale: locale)
        }
    }

    public struct RunningApplication: Sendable, Equatable {
        public let bundleID: String
        public let localizedName: String

        public init(bundleID: String, localizedName: String) {
            self.bundleID = bundleID
            self.localizedName = localizedName
        }
    }

    public struct Conflict: Sendable, Equatable {
        public let path: String
        public let title: String
        public let titlePresentation: LocalizedTextDescriptor
        public let bundleIDPrefix: String
        public let runningBundleID: String
        public let runningAppName: String

        public init(path: String,
                    title: String,
                    bundleIDPrefix: String,
                    runningBundleID: String,
                    runningAppName: String? = nil,
                    titlePresentation: LocalizedTextDescriptor? = nil) {
            self.path = path
            self.title = title
            self.titlePresentation = titlePresentation ?? .verbatim(title)
            self.bundleIDPrefix = bundleIDPrefix
            self.runningBundleID = runningBundleID
            self.runningAppName = runningAppName ?? runningBundleID
        }

        public func displayTitle(locale: Locale) -> String {
            titlePresentation.localized(locale: locale)
        }
    }

    public enum Resolution: Sendable, Equatable {
        case skipConflictingItems
        case moveAllToTrash
    }

    public struct Plan: Sendable, Equatable {
        public let rows: [RowItem]
        public let skippedConflicts: [Conflict]

        public init(rows: [RowItem], skippedConflicts: [Conflict]) {
            self.rows = rows
            self.skippedConflicts = skippedConflicts
        }
    }

    public struct CandidatePlan: Sendable, Equatable {
        public let candidates: [Candidate]
        public let skippedConflicts: [Conflict]

        public init(candidates: [Candidate], skippedConflicts: [Conflict]) {
            self.candidates = candidates
            self.skippedConflicts = skippedConflicts
        }
    }

    public static func currentRunningApplications() -> [RunningApplication] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard let bundleID = application.bundleIdentifier else { return nil }
            return RunningApplication(
                bundleID: bundleID,
                localizedName: application.localizedName ?? bundleID
            )
        }
    }

    public static func currentRunningBundleIDs() -> Set<String> {
        Set(currentRunningApplications().map(\.bundleID))
    }

    public static func conflicts(rows: [RowItem],
                                 runningBundleIDs: Set<String>) -> [Conflict] {
        conflicts(
            rows: rows,
            runningApplications: runningBundleIDs.map {
                RunningApplication(bundleID: $0, localizedName: $0)
            }
        )
    }

    public static func conflicts(rows: [RowItem],
                                 runningApplications: [RunningApplication]) -> [Conflict] {
        conflicts(
            candidates: rows.map {
                Candidate(
                    path: $0.url.path,
                    title: $0.title,
                    bundleIDPrefix: $0.runningBundleIDPrefix,
                    titlePresentation: $0.titlePresentation
                )
            },
            runningApplications: runningApplications
        )
    }

    public static func conflicts(candidates: [Candidate],
                                 runningApplications: [RunningApplication]) -> [Conflict] {
        var out: [Conflict] = []
        var seen = Set<String>()
        for candidate in candidates {
            guard let prefix = candidate.bundleIDPrefix?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !prefix.isEmpty else { continue }
            // 同一 App 常伴随多个 helper 进程。优先展示 bundle ID 精确匹配的主 App，
            // 只有主进程不可见时才退到点边界子进程，避免把 Chrome Helper 当成 Chrome 本体。
            let running = runningApplications.first(where: { $0.bundleID == prefix })
                ?? runningApplications.first(where: { $0.bundleID.hasPrefix(prefix + ".") })
            guard let running else {
                continue
            }
            let key = "\(prefix)|\(candidate.path)"
            guard seen.insert(key).inserted else { continue }
            out.append(Conflict(path: candidate.path,
                                title: candidate.title,
                                bundleIDPrefix: prefix,
                                runningBundleID: running.bundleID,
                                runningAppName: running.localizedName,
                                titlePresentation: candidate.titlePresentation))
        }
        return out
    }

    public static func makePlan(rows: [RowItem],
                                runningApplications: [RunningApplication],
                                resolution: Resolution,
                                confirmedConflicts: [Conflict] = []) -> Plan {
        let candidatePlan = makePlan(
            candidates: rows.map {
                Candidate(
                    path: $0.url.path,
                    title: $0.title,
                    bundleIDPrefix: $0.runningBundleIDPrefix,
                    titlePresentation: $0.titlePresentation
                )
            },
            runningApplications: runningApplications,
            resolution: resolution,
            confirmedConflicts: confirmedConflicts
        )
        let includedPaths = Set(candidatePlan.candidates.map(\.path))
        return Plan(
            rows: rows.filter { includedPaths.contains($0.url.path) },
            skippedConflicts: candidatePlan.skippedConflicts
        )
    }

    public static func makePlan(candidates: [Candidate],
                                runningApplications: [RunningApplication],
                                resolution: Resolution,
                                confirmedConflicts: [Conflict] = []) -> CandidatePlan {
        guard resolution == .skipConflictingItems else {
            return CandidatePlan(candidates: candidates, skippedConflicts: [])
        }
        let currentConflicts = conflicts(
            candidates: candidates,
            runningApplications: runningApplications
        )
        // 用户在对话框中已经看见并明确选择跳过的项，即使 App 随后退出也必须继续跳过；
        // 同时合并最终点击时新出现的运行冲突，避免把新冲突静默纳入。
        var conflictByPath: [String: Conflict] = [:]
        for conflict in confirmedConflicts {
            conflictByPath[conflict.path] = conflict
        }
        for conflict in currentConflicts {
            conflictByPath[conflict.path] = conflict
        }

        var includedCandidates: [Candidate] = []
        var skippedConflicts: [Conflict] = []
        var recordedSkippedPaths = Set<String>()
        includedCandidates.reserveCapacity(candidates.count)
        for candidate in candidates {
            if let conflict = conflictByPath[candidate.path] {
                if recordedSkippedPaths.insert(candidate.path).inserted {
                    skippedConflicts.append(conflict)
                }
            } else {
                includedCandidates.append(candidate)
            }
        }
        return CandidatePlan(
            candidates: includedCandidates,
            skippedConflicts: skippedConflicts
        )
    }
}
