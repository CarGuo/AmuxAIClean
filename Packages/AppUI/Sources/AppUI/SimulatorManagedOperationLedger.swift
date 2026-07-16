import Foundation
import Darwin
import ScanKit
import LogKit

/// 跨 App 重启保留的 CoreSimulator managed-operation tombstone 合同。
///
/// **v2026.07.16 根因修复**：持久记录必须区分“仅保留、已跨提交屏障、已确认终态”。
/// 旧的单一 intent 会把 reserve 后崩溃和真实 in-flight 混在一起，既可能永久锁死重试，
/// 也无法证明普通非零退出已经没有活跃进程。阶段转换必须同步、原子落盘；submitted/未知
/// 永远 fail closed，只有死亡 owner 留下的 reserved、已确认非零 terminal 或权威 absent
/// 才能由对应的类型化方法清除。
public protocol SimulatorManagedOperationLedger: Sendable {
    func observation(
        identifier: String,
        kind: ManagedUninstallRecipe
    ) -> SimulatorManagedLedgerObservation
    func reserve(
        identifier: String,
        kind: ManagedUninstallRecipe,
        reviewIdentity: SimulatorManagedReviewIdentity
    ) -> SimulatorManagedLedgerReservation
    /// 在 `Process.run()` 前的同步持久屏障中把本进程的 reserved 提升为 submitted。
    @discardableResult
    func markSubmitted(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID
    ) -> Bool
    /// 只有 executor 已拿到真实 terminationStatus 后才能调用。
    @discardableResult
    func recordConfirmedTerminal(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID,
        exitCode: Int32
    ) -> Bool
    /// 仅当 executor 的持久屏障拒绝或 `Process.run()` 抛错、明确没有产生 PID 时允许
    /// 回滚本进程的 reserved/submitted。
    @discardableResult
    func clearAfterProvenNoLaunch(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID
    ) -> Bool
    /// 仅清理由已死亡进程 owner 留下的 reserved；活跃 owner 或查询失败均 fail closed。
    @discardableResult
    func clearStaleReservationForFreshReview(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID,
        candidateReviewIdentity: SimulatorManagedReviewIdentity
    ) -> Bool
    /// 只有持久阶段已是 confirmed terminal 且 exitCode != 0 才允许清理并重新复核。
    @discardableResult
    func clearAfterConfirmedTerminalFailure(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID
    ) -> Bool
    @discardableResult
    func clearAfterAuthoritativeAbsence(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID
    ) -> Bool
}

/// Stable identity of the Workflow evidence that the user reviewed before a managed uninstall.
///
/// **v2026.07.16 根因修复**：点击 sheet 生成的随机 operation UUID 不能证明用户看过了
/// 一轮更新后的 CoreSimulator 清单。只有扫描 session 与 revision 都来自冻结的 Workflow
/// intent，ledger 才能在跨进程恢复时判断这是“同一次复核”还是更新后的复核。
public struct SimulatorManagedReviewIdentity: Codable, Sendable, Equatable, Hashable {
    public let sessionID: UUID
    public let revision: UInt64

    public init(sessionID: UUID, revision: UInt64) {
        self.sessionID = sessionID
        self.revision = revision
    }
}

public extension SimulatorManagedOperationLedger {
    /// Compatibility projection for diagnostics/tests. Mutations must use the full observation's
    /// attempt ID; a state value by itself is intentionally insufficient for compare-and-swap.
    func state(identifier: String, kind: ManagedUninstallRecipe) -> SimulatorManagedLedgerState {
        observation(identifier: identifier, kind: kind).state
    }
}

/// One immutable ledger read. The attempt ID is the generation token for the exact record that
/// produced `state`; callers must pass it back to every mutation after an external authority probe.
public struct SimulatorManagedLedgerObservation: Sendable, Equatable {
    public let state: SimulatorManagedLedgerState
    public let attemptID: UUID?

    public init(state: SimulatorManagedLedgerState, attemptID: UUID?) {
        self.state = state
        self.attemptID = attemptID
    }
}

public enum SimulatorManagedLedgerState: Sendable, Equatable {
    case absent
    case reservedByActiveProcess
    case staleReservation
    case submitted
    case terminal(exitCode: Int32)
    /// 文件损坏、读失败、UUID/kind 冲突或 owner 身份不可验证；调用方必须 fail closed。
    case unavailable
}

public enum SimulatorManagedLedgerReservation: Sendable, Equatable {
    case reserved(attemptID: UUID)
    case alreadyPending
    case persistenceFailed
}

struct SimulatorLedgerProcessIdentity: Codable, Sendable, Equatable {
    let pid: Int32
    let startTimeSeconds: UInt64
    let startTimeMicroseconds: UInt64
}

enum SimulatorLedgerProcessLiveness: Sendable, Equatable {
    case active
    case inactive
    case unavailable
}

/// Application Support JSON ledger。每次操作都重新读取磁盘，再用 `.atomic` replace 写回；
/// NSLock 让同进程多个 Coordinator/ViewModel 的 read-modify-write 保持单一临界区。
public final class PersistentSimulatorManagedOperationLedger: SimulatorManagedOperationLedger,
                                                              @unchecked Sendable {
    private enum Phase: String, Codable, Sendable {
        case reserved
        case submitted
        case terminal
    }

    private struct Record: Codable, Sendable, Equatable {
        let identifier: String
        let kind: String
        let attemptID: UUID
        let owner: SimulatorLedgerProcessIdentity?
        let reviewIdentity: SimulatorManagedReviewIdentity
        var phase: Phase
        let reservedAt: Date
        var submittedAt: Date?
        var terminalAt: Date?
        var terminalExitCode: Int32?
    }

    private struct Envelope: Codable, Sendable, Equatable {
        let schemaVersion: Int
        var records: [String: Record]
    }

    /// schema 3 introduced attempt CAS but did not persist the scan/review generation.
    private struct Schema3Record: Codable {
        let identifier: String
        let kind: String
        let attemptID: UUID
        let owner: SimulatorLedgerProcessIdentity?
        let phase: Phase
        let reservedAt: Date
        let submittedAt: Date?
        let terminalAt: Date?
        let terminalExitCode: Int32?
    }

    private struct Schema3Envelope: Codable {
        let schemaVersion: Int
        let records: [String: Schema3Record]
    }

    /// schema 2 already separated lifecycle phases, but did not carry an attempt generation.
    /// It is migrated to one stable, reserved migration token per identifier and remains
    /// conservative until authoritative absence or a recorded terminal permits an exact clear.
    private struct Schema2Record: Codable {
        let identifier: String
        let kind: String
        let owner: SimulatorLedgerProcessIdentity?
        let phase: Phase
        let reservedAt: Date
        let submittedAt: Date?
        let terminalAt: Date?
        let terminalExitCode: Int32?
    }

    private struct Schema2Envelope: Codable {
        let schemaVersion: Int
        let records: [String: Schema2Record]
    }

    /// schema 1 的单一 intent 可能已经跨过 `Process.run()`，升级时必须保守映射为 submitted，
    /// 不能把旧记录猜成可清理的 reserved。
    private struct LegacyRecord: Codable {
        let identifier: String
        let kind: String
        let submittedIntentAt: Date
    }

    private struct LegacyEnvelope: Codable {
        let schemaVersion: Int
        let records: [String: LegacyRecord]
    }

    private struct SchemaHeader: Codable {
        let schemaVersion: Int
    }

    /// v1/v2 records did not have a generation. The sentinel is stable across independent reads
    /// and processes, while new reservations explicitly avoid it, so a migrated clear can never
    /// match a replacement attempt (v2026.07.16 ABA root-cause fix).
    private static let migratedAttemptID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// v1-v3 had no review identity. A reserved record can only reach stale after its owner
    /// process is proven dead, so any production review in the replacement process is necessarily
    /// a new scan session. The private sentinel preserves that fact without guessing a revision;
    /// callers are forbidden from reserving with the sentinel itself. Submitted records remain
    /// fail-closed exactly as before. (v2026.07.16 schema-4 migration contract)
    private static let migratedReviewIdentity = SimulatorManagedReviewIdentity(
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        revision: 0
    )

    typealias ProcessIdentityProvider = @Sendable () -> SimulatorLedgerProcessIdentity?
    typealias ProcessLivenessProbe = @Sendable (
        SimulatorLedgerProcessIdentity
    ) -> SimulatorLedgerProcessLiveness

    private let fileURL: URL
    private let lockFileURL: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let processIdentityProvider: ProcessIdentityProvider
    private let processLivenessProbe: ProcessLivenessProbe

    public convenience init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.init(fileURL: base
            .appendingPathComponent("AmuxAIClean", isDirectory: true)
            .appendingPathComponent("simulator-managed-operations.json", isDirectory: false))
    }

    /// 可注入路径仅用于隔离测试；生产使用 Application Support 默认位置。
    public convenience init(fileURL: URL) {
        self.init(
            fileURL: fileURL,
            processIdentityProvider: {
                Self.lookupProcessIdentity(pid: Int32(Darwin.getpid())).identity
            },
            processLivenessProbe: { expected in
                switch Self.lookupProcessIdentity(pid: expected.pid) {
                case .found(let actual):
                    return actual == expected ? .active : .inactive
                case .notRunning:
                    return .inactive
                case .unavailable:
                    return .unavailable
                }
            }
        )
    }

    /// 进程身份注入仅供确定性测试模拟“前一 App 实例已退出”；生产不公开替换系统探针。
    init(
        fileURL: URL,
        processIdentityProvider: @escaping ProcessIdentityProvider,
        processLivenessProbe: @escaping ProcessLivenessProbe
    ) {
        self.fileURL = fileURL
        self.lockFileURL = fileURL.appendingPathExtension("lock")
        self.processIdentityProvider = processIdentityProvider
        self.processLivenessProbe = processLivenessProbe
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        decoder.dateDecodingStrategy = .iso8601
    }

    public func observation(
        identifier: String,
        kind: ManagedUninstallRecipe
    ) -> SimulatorManagedLedgerObservation {
        lock.lock()
        defer { lock.unlock() }
        return withCrossProcessLock {
            guard let canonical = Self.canonical(identifier),
                  let envelope = loadEnvelope() else {
                return SimulatorManagedLedgerObservation(state: .unavailable, attemptID: nil)
            }
            guard let record = envelope.records[canonical] else {
                return SimulatorManagedLedgerObservation(state: .absent, attemptID: nil)
            }
            guard record.identifier == canonical,
                  record.kind == kind.rawValue,
                  Self.hasValidShape(record) else {
                return SimulatorManagedLedgerObservation(state: .unavailable, attemptID: nil)
            }
            let state: SimulatorManagedLedgerState
            switch record.phase {
            case .reserved:
                guard let owner = record.owner else {
                    return SimulatorManagedLedgerObservation(state: .unavailable, attemptID: nil)
                }
                switch processLivenessProbe(owner) {
                case .active: state = .reservedByActiveProcess
                case .inactive: state = .staleReservation
                case .unavailable: state = .unavailable
                }
            case .submitted:
                state = .submitted
            case .terminal:
                guard let exitCode = record.terminalExitCode else {
                    return SimulatorManagedLedgerObservation(state: .unavailable, attemptID: nil)
                }
                state = .terminal(exitCode: exitCode)
            }
            return SimulatorManagedLedgerObservation(
                state: state,
                attemptID: state == .unavailable ? nil : record.attemptID
            )
        } ?? SimulatorManagedLedgerObservation(state: .unavailable, attemptID: nil)
    }

    public func reserve(
        identifier: String,
        kind: ManagedUninstallRecipe,
        reviewIdentity: SimulatorManagedReviewIdentity
    ) -> SimulatorManagedLedgerReservation {
        lock.lock()
        defer { lock.unlock() }
        return withCrossProcessLock {
            guard let canonical = Self.canonical(identifier),
                  let owner = processIdentityProvider(),
                  Self.hasValidOwnerShape(owner),
                  Self.hasValidCandidateReviewIdentity(reviewIdentity),
                  var envelope = loadEnvelope() else { return .persistenceFailed }
            if envelope.records[canonical] != nil { return .alreadyPending }
            var attemptID = UUID()
            while attemptID == Self.migratedAttemptID {
                attemptID = UUID()
            }
            envelope.records[canonical] = Record(
                identifier: canonical,
                kind: kind.rawValue,
                attemptID: attemptID,
                owner: owner,
                reviewIdentity: reviewIdentity,
                phase: .reserved,
                reservedAt: Date(),
                submittedAt: nil,
                terminalAt: nil,
                terminalExitCode: nil
            )
            return persist(envelope) ? .reserved(attemptID: attemptID) : .persistenceFailed
        } ?? .persistenceFailed
    }

    @discardableResult
    public func markSubmitted(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID
    ) -> Bool {
        mutateOwnedRecord(
            identifier: identifier,
            kind: kind,
            expectedAttemptID: expectedAttemptID
        ) { record in
            guard record.phase == .reserved else { return false }
            record.phase = .submitted
            record.submittedAt = Date()
            return true
        }
    }

    @discardableResult
    public func recordConfirmedTerminal(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID,
        exitCode: Int32
    ) -> Bool {
        mutateOwnedRecord(
            identifier: identifier,
            kind: kind,
            expectedAttemptID: expectedAttemptID
        ) { record in
            guard record.phase == .submitted else { return false }
            record.phase = .terminal
            record.terminalAt = Date()
            record.terminalExitCode = exitCode
            return true
        }
    }

    @discardableResult
    public func clearAfterProvenNoLaunch(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID
    ) -> Bool {
        removeRecord(
            identifier: identifier,
            kind: kind,
            expectedAttemptID: expectedAttemptID
        ) { record in
            guard (record.phase == .reserved || record.phase == .submitted),
                  let currentOwner = processIdentityProvider() else { return false }
            return record.owner == currentOwner
        }
    }

    @discardableResult
    public func clearStaleReservationForFreshReview(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID,
        candidateReviewIdentity: SimulatorManagedReviewIdentity
    ) -> Bool {
        removeRecord(
            identifier: identifier,
            kind: kind,
            expectedAttemptID: expectedAttemptID
        ) { record in
            guard record.phase == .reserved,
                  let owner = record.owner,
                  Self.hasValidCandidateReviewIdentity(candidateReviewIdentity),
                  Self.isFreshReview(candidateReviewIdentity, relativeTo: record.reviewIdentity)
            else { return false }
            // The liveness probe and review-generation comparison both execute while holding
            // the same cross-process flock as the attempt CAS/removal. A competing instance
            // therefore cannot replace the record between evidence validation and mutation.
            return processLivenessProbe(owner) == .inactive
        }
    }

    @discardableResult
    public func clearAfterConfirmedTerminalFailure(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID
    ) -> Bool {
        removeRecord(
            identifier: identifier,
            kind: kind,
            expectedAttemptID: expectedAttemptID
        ) { record in
            record.phase == .terminal && (record.terminalExitCode ?? 0) != 0
        }
    }

    @discardableResult
    public func clearAfterAuthoritativeAbsence(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID
    ) -> Bool {
        removeRecord(
            identifier: identifier,
            kind: kind,
            expectedAttemptID: expectedAttemptID
        ) { _ in true }
    }

    private func mutateOwnedRecord(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID,
        mutation: (inout Record) -> Bool
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return withCrossProcessLock {
            guard let canonical = Self.canonical(identifier),
                  let currentOwner = processIdentityProvider(),
                  var envelope = loadEnvelope(),
                  var record = envelope.records[canonical],
                  record.identifier == canonical,
                  record.kind == kind.rawValue,
                  record.attemptID == expectedAttemptID,
                  record.owner == currentOwner,
                  Self.hasValidShape(record),
                  mutation(&record) else { return false }
            envelope.records[canonical] = record
            return persist(envelope)
        } ?? false
    }

    private func removeRecord(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID,
        predicate: (Record) -> Bool
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return withCrossProcessLock {
            guard let canonical = Self.canonical(identifier),
                  var envelope = loadEnvelope(),
                  let record = envelope.records[canonical],
                  record.identifier == canonical,
                  record.kind == kind.rawValue,
                  record.attemptID == expectedAttemptID,
                  Self.hasValidShape(record),
                  predicate(record) else { return false }
            envelope.records.removeValue(forKey: canonical)
            return persist(envelope)
        } ?? false
    }

    private func loadEnvelope() -> Envelope? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Envelope(schemaVersion: 4, records: [:])
        }
        do {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            switch try decoder.decode(SchemaHeader.self, from: data).schemaVersion {
            case 4:
                let envelope = try decoder.decode(Envelope.self, from: data)
                return Self.isValidEnvelope(envelope) ? envelope : nil
            case 3:
                let legacy = try decoder.decode(Schema3Envelope.self, from: data)
                let envelope = Envelope(
                    schemaVersion: 4,
                    records: legacy.records.mapValues { record in
                        Record(
                            identifier: record.identifier,
                            kind: record.kind,
                            attemptID: record.attemptID,
                            owner: record.owner,
                            reviewIdentity: Self.migratedReviewIdentity,
                            phase: record.phase,
                            reservedAt: record.reservedAt,
                            submittedAt: record.submittedAt,
                            terminalAt: record.terminalAt,
                            terminalExitCode: record.terminalExitCode
                        )
                    }
                )
                return Self.isValidEnvelope(envelope) ? envelope : nil
            case 2:
                let legacy = try decoder.decode(Schema2Envelope.self, from: data)
                let envelope = Envelope(
                    schemaVersion: 4,
                    records: legacy.records.mapValues { record in
                        Record(
                            identifier: record.identifier,
                            kind: record.kind,
                            attemptID: Self.migratedAttemptID,
                            owner: record.owner,
                            reviewIdentity: Self.migratedReviewIdentity,
                            phase: record.phase,
                            reservedAt: record.reservedAt,
                            submittedAt: record.submittedAt,
                            terminalAt: record.terminalAt,
                            terminalExitCode: record.terminalExitCode
                        )
                    }
                )
                return Self.isValidEnvelope(envelope) ? envelope : nil
            case 1:
                let legacy = try decoder.decode(LegacyEnvelope.self, from: data)
                let envelope = Envelope(
                    schemaVersion: 4,
                    records: legacy.records.mapValues { record in
                        Record(
                            identifier: record.identifier,
                            kind: record.kind,
                            attemptID: Self.migratedAttemptID,
                            owner: nil,
                            reviewIdentity: Self.migratedReviewIdentity,
                            phase: .submitted,
                            reservedAt: record.submittedIntentAt,
                            submittedAt: record.submittedIntentAt,
                            terminalAt: nil,
                            terminalExitCode: nil
                        )
                    }
                )
                return Self.isValidEnvelope(envelope) ? envelope : nil
            case let unsupported:
                GSYLog.warning(.app, "Simulator ledger schema unsupported: \(unsupported)")
                return nil
            }
        } catch {
            GSYLog.warning(.app, "Simulator ledger read failed path=\(fileURL.path) error=\(error)")
            return nil
        }
    }

    private func persist(_ envelope: Envelope) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(envelope)
            try data.write(to: fileURL, options: [.atomic])
            return true
        } catch {
            GSYLog.warning(.app, "Simulator ledger atomic write failed path=\(fileURL.path) error=\(error)")
            return false
        }
    }

    private static func hasValidShape(_ record: Record) -> Bool {
        guard record.owner.map(hasValidOwnerShape) ?? true else { return false }
        switch record.phase {
        case .reserved:
            return record.owner != nil
                && record.submittedAt == nil
                && record.terminalAt == nil
                && record.terminalExitCode == nil
        case .submitted:
            return record.submittedAt != nil
                && record.terminalAt == nil
                && record.terminalExitCode == nil
        case .terminal:
            return record.submittedAt != nil
                && record.terminalAt != nil
                && record.terminalExitCode != nil
        }
    }

    /// The dictionary key is part of the duplicate-submission identity. A malformed or
    /// non-canonical key must invalidate the whole ledger rather than look "absent" for the
    /// canonical lookup and permit a second record for the same managed UUID.
    private static func isValidEnvelope(_ envelope: Envelope) -> Bool {
        guard envelope.schemaVersion == 4 else { return false }
        return envelope.records.allSatisfy { key, record in
            guard let canonicalIdentifier = canonical(record.identifier),
                  key == canonicalIdentifier,
                  record.identifier == canonicalIdentifier,
                  ManagedUninstallRecipe(rawValue: record.kind) != nil,
                  hasValidShape(record) else { return false }
            return true
        }
    }

    /// `.atomic` 只保证单次 replace 完整，不能防两个 `open -n` App 实例同时
    /// read-modify-write。独立 lock inode 配合 `flock(LOCK_EX)` 覆盖整个事务；ledger
    /// 文件自身可被 atomic replace 而不会使锁失效。
    private func withCrossProcessLock<T>(_ body: () -> T) -> T? {
        do {
            try FileManager.default.createDirectory(
                at: lockFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            GSYLog.warning(.app, "Simulator ledger lock directory failed: \(error)")
            return nil
        }
        let descriptor = lockFileURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            GSYLog.warning(.app, "Simulator ledger lock open failed errno=\(errno)")
            return nil
        }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            GSYLog.warning(.app, "Simulator ledger flock failed errno=\(errno)")
            return nil
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return body()
    }

    private enum ProcessIdentityLookup {
        case found(SimulatorLedgerProcessIdentity)
        case notRunning
        case unavailable

        var identity: SimulatorLedgerProcessIdentity? {
            guard case .found(let identity) = self else { return nil }
            return identity
        }
    }

    private static func lookupProcessIdentity(pid: Int32) -> ProcessIdentityLookup {
        guard pid > 0 else { return .notRunning }
        var info = proc_bsdinfo()
        errno = 0
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let byteCount = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, pointer, Int32(expectedSize))
        }
        guard byteCount == Int32(expectedSize) else {
            return errno == ESRCH ? .notRunning : .unavailable
        }
        let identity = SimulatorLedgerProcessIdentity(
            pid: pid,
            startTimeSeconds: info.pbi_start_tvsec,
            startTimeMicroseconds: info.pbi_start_tvusec
        )
        return hasValidOwnerShape(identity) ? .found(identity) : .unavailable
    }

    /// Kernel process identity is only meaningful with a positive PID, a non-zero epoch second,
    /// and a normalized timeval microsecond component. Any malformed owner invalidates the whole
    /// envelope so one corrupt record can never look absent and reopen duplicate submission.
    /// (v2026.07.16 root-cause hardening)
    private static func hasValidOwnerShape(_ owner: SimulatorLedgerProcessIdentity) -> Bool {
        owner.pid > 0
            && owner.startTimeSeconds > 0
            && owner.startTimeMicroseconds < 1_000_000
    }

    private static func hasValidCandidateReviewIdentity(
        _ identity: SimulatorManagedReviewIdentity
    ) -> Bool {
        identity != migratedReviewIdentity
    }

    private static func isFreshReview(
        _ candidate: SimulatorManagedReviewIdentity,
        relativeTo previous: SimulatorManagedReviewIdentity
    ) -> Bool {
        if candidate.sessionID != previous.sessionID { return true }
        return candidate.revision > previous.revision
    }

    private static func canonical(_ identifier: String) -> String? {
        UUID(uuidString: identifier)?.uuidString.lowercased()
    }
}

/// 无磁盘副作用的测试 ledger；真实非-dry-run 测试必须显式注入，避免污染用户数据。
final class InMemorySimulatorManagedOperationLedger: SimulatorManagedOperationLedger,
                                                     @unchecked Sendable {
    private struct Record {
        let kind: ManagedUninstallRecipe
        let attemptID: UUID
        let reviewIdentity: SimulatorManagedReviewIdentity
        var phase: SimulatorManagedLedgerState
    }

    private var records: [String: Record] = [:]
    private let lock = NSLock()

    func observation(
        identifier: String,
        kind: ManagedUninstallRecipe
    ) -> SimulatorManagedLedgerObservation {
        lock.lock()
        defer { lock.unlock() }
        guard let key = UUID(uuidString: identifier)?.uuidString.lowercased() else {
            return SimulatorManagedLedgerObservation(state: .unavailable, attemptID: nil)
        }
        guard let record = records[key] else {
            return SimulatorManagedLedgerObservation(state: .absent, attemptID: nil)
        }
        guard record.kind == kind else {
            return SimulatorManagedLedgerObservation(state: .unavailable, attemptID: nil)
        }
        return SimulatorManagedLedgerObservation(
            state: record.phase,
            attemptID: record.attemptID
        )
    }

    func reserve(
        identifier: String,
        kind: ManagedUninstallRecipe,
        reviewIdentity: SimulatorManagedReviewIdentity
    ) -> SimulatorManagedLedgerReservation {
        lock.lock()
        defer { lock.unlock() }
        guard let key = UUID(uuidString: identifier)?.uuidString.lowercased() else {
            return .persistenceFailed
        }
        guard records[key] == nil else { return .alreadyPending }
        let attemptID = UUID()
        records[key] = Record(
            kind: kind,
            attemptID: attemptID,
            reviewIdentity: reviewIdentity,
            phase: .reservedByActiveProcess
        )
        return .reserved(attemptID: attemptID)
    }

    func markSubmitted(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID
    ) -> Bool {
        mutate(
            identifier: identifier,
            kind: kind,
            expectedAttemptID: expectedAttemptID
        ) { phase in
            guard phase == .reservedByActiveProcess else { return false }
            phase = .submitted
            return true
        }
    }

    func recordConfirmedTerminal(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID,
        exitCode: Int32
    ) -> Bool {
        mutate(
            identifier: identifier,
            kind: kind,
            expectedAttemptID: expectedAttemptID
        ) { phase in
            guard phase == .submitted else { return false }
            phase = .terminal(exitCode: exitCode)
            return true
        }
    }

    func clearAfterProvenNoLaunch(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID
    ) -> Bool {
        remove(identifier: identifier, kind: kind, expectedAttemptID: expectedAttemptID) {
            $0 == .reservedByActiveProcess || $0 == .submitted
        }
    }

    func clearStaleReservationForFreshReview(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID,
        candidateReviewIdentity: SimulatorManagedReviewIdentity
    ) -> Bool {
        removeRecord(identifier: identifier, kind: kind, expectedAttemptID: expectedAttemptID) {
            record in
            guard record.phase == .staleReservation else { return false }
            if candidateReviewIdentity.sessionID != record.reviewIdentity.sessionID { return true }
            return candidateReviewIdentity.revision > record.reviewIdentity.revision
        }
    }

    func clearAfterConfirmedTerminalFailure(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID
    ) -> Bool {
        remove(identifier: identifier, kind: kind, expectedAttemptID: expectedAttemptID) { phase in
            guard case .terminal(let exitCode) = phase else { return false }
            return exitCode != 0
        }
    }

    @discardableResult
    func clearAfterAuthoritativeAbsence(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID
    ) -> Bool {
        remove(identifier: identifier, kind: kind, expectedAttemptID: expectedAttemptID) { _ in true }
    }

    private func mutate(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID,
        mutation: (inout SimulatorManagedLedgerState) -> Bool
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let key = UUID(uuidString: identifier)?.uuidString.lowercased(),
              var record = records[key], record.kind == kind,
              record.attemptID == expectedAttemptID,
              mutation(&record.phase) else { return false }
        records[key] = record
        return true
    }

    private func remove(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID,
        predicate: (SimulatorManagedLedgerState) -> Bool
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let key = UUID(uuidString: identifier)?.uuidString.lowercased(),
              let record = records[key], record.kind == kind,
              record.attemptID == expectedAttemptID,
              predicate(record.phase) else { return false }
        records.removeValue(forKey: key)
        return true
    }

    private func removeRecord(
        identifier: String,
        kind: ManagedUninstallRecipe,
        expectedAttemptID: UUID,
        predicate: (Record) -> Bool
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let key = UUID(uuidString: identifier)?.uuidString.lowercased(),
              let record = records[key], record.kind == kind,
              record.attemptID == expectedAttemptID,
              predicate(record) else { return false }
        records.removeValue(forKey: key)
        return true
    }
}
