import SwiftUI
import ScanKit

/// v2026.07.18：维护命令的用户可见投影边界。ScanKit 保留 raw stdout/stderr 作为
/// 结构化诊断，主界面只消费稳定终态，避免中文界面暴露英文 CLI、errno 或内部 owner 状态。
enum MaintenanceOutcomePresentation {
    static func message(
        for status: MaintenanceTasks.Outcome.Status,
        locale: Locale
    ) -> String {
        switch status {
        case .succeeded:
            return AppLocalization.string("maintenance.outcome.succeeded", locale: locale)
        case .exited(let code):
            return AppLocalization.format(
                "maintenance.outcome.failed_exit %lld",
                locale: locale,
                arguments: [Int64(code)]
            )
        case .timedOut:
            return AppLocalization.string("maintenance.outcome.timed_out", locale: locale)
        case .cancelled:
            return AppLocalization.string("maintenance.outcome.cancelled", locale: locale)
        case .ownershipLost:
            return AppLocalization.string("maintenance.outcome.ownership_lost", locale: locale)
        case .launchFailed:
            return AppLocalization.string("maintenance.outcome.launch_failed", locale: locale)
        }
    }
}

/// v2026.07.18：维护命令和扫描一样需要“取消信号 + revision ownership”双保险。
/// 同步子进程返回后只有当前身份可以发布，离页先 invalidate 再等待 worker settlement。
struct MaintenanceRunIdentity: Sendable, Equatable {
    let operationID: UUID
    let revision: UInt64
    let tasks: [MaintenanceTasks.Task]
}

struct MaintenanceRunGate: Sendable, Equatable {
    private(set) var current: MaintenanceRunIdentity?

    mutating func begin(_ identity: MaintenanceRunIdentity) { current = identity }
    mutating func invalidate() { current = nil }

    mutating func finishIfCurrent(
        _ identity: MaintenanceRunIdentity,
        taskWasCancelled: Bool
    ) -> Bool? {
        guard current == identity else { return nil }
        current = nil
        return !taskWasCancelled
    }
}

/// M4-T4：维护任务屏（user-space，无 sudo）。
///
/// 包 [MaintenanceTasks](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/MaintenanceTasks.swift)
/// 的两个内置任务（flushQuickLookCache / flushDNSCache），
/// 提供按钮、批量执行入口、按时间倒序的执行结果列表。
///
/// 设计契约：
/// - **不阻塞 UI**：`runTask(_:)` 在 detached Task 里调 `tasks.run(_:)`，主线程仅追加 outcome。
/// - **不依赖 ScanCoordinator**：完全独立屏幕，本身是只读 + 用户主动触发。
/// - **可注入** `tasks: MaintenanceTasks`：测试用注入 fake runner 即可绕开 Process.run。
public struct MaintenanceScreen: View {
    /// Shared across SwiftUI page instances. A newly constructed page must still wait until an
    /// old page's cancelled owned child has reaped; local `@State` alone cannot enforce that.
    @MainActor private static let executionSettlement = ScanProducerSettlementChain()
    /// v2026.07.15：任务本身与 outcome 只保存语义/命令原始日志；所有标题、说明和
    /// 按钮在当前 View locale 下投影，避免运行结果留在页面时语言无法同步切换。
    @Environment(\.locale) private var locale

    private let tasks: MaintenanceTasks

    @State private var outcomes: [MaintenanceTasks.Outcome] = []
    @State private var runningTasks: Set<MaintenanceTasks.Task> = []
    @State private var operationTask: Task<Void, Never>?
    @State private var operationRevision: UInt64 = 0
    @State private var operationGate = MaintenanceRunGate()

    public init(tasks: MaintenanceTasks = MaintenanceTasks()) {
        self.tasks = tasks
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            taskGrid
            Divider()
            outcomeSection
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear { cancelOperationForDeparture() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLocalization.string("maintenance.title", locale: locale))
                .font(.title2.bold())
            Text(AppLocalization.string("maintenance.subtitle", locale: locale))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var taskGrid: some View {
        VStack(spacing: 10) {
            ForEach(MaintenanceTasks.Task.allCases, id: \.self) { task in
                taskRow(task)
            }
            HStack {
                Spacer()
                Button {
                    runAll()
                } label: {
                    Label(AppLocalization.string("maintenance.button.run_all", locale: locale),
                          systemImage: "play.rectangle.fill")
                }
                .disabled(!runningTasks.isEmpty)
                .controlSize(.large)
            }
        }
    }

    @ViewBuilder
    private func taskRow(_ task: MaintenanceTasks.Task) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(for: task))
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(localizedTitle(for: task)).font(.headline)
                Text(localizedSubtitle(for: task))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if runningTasks.contains(task) {
                ProgressView().controlSize(.small)
            }
            Button {
                runTask(task)
            } label: {
                Text(AppLocalization.string("maintenance.button.run", locale: locale))
            }
            .disabled(!runningTasks.isEmpty)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder
    private var outcomeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalization.string("maintenance.outcome.title", locale: locale))
                .font(.headline)
            if outcomes.isEmpty {
                Text(AppLocalization.string("maintenance.outcome.empty", locale: locale))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(outcomes.enumerated()), id: \.offset) { _, outcome in
                            outcomeRow(outcome)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    @ViewBuilder
    private func outcomeRow(_ outcome: MaintenanceTasks.Outcome) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(outcome.succeeded ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(localizedTitle(for: outcome.task)).font(.subheadline.bold())
                Text(MaintenanceOutcomePresentation.message(
                    for: outcome.status,
                    locale: locale
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: - actions

    private func runTask(_ task: MaintenanceTasks.Task) {
        startOperation([task])
    }

    private func runAll() {
        startOperation(MaintenanceTasks.Task.allCases)
    }

    private func startOperation(_ requestedTasks: [MaintenanceTasks.Task]) {
        guard operationTask == nil, runningTasks.isEmpty, !requestedTasks.isEmpty else { return }
        operationRevision &+= 1
        let identity = MaintenanceRunIdentity(
            operationID: UUID(),
            revision: operationRevision,
            tasks: requestedTasks
        )
        operationGate.begin(identity)
        runningTasks = Set(requestedTasks)

        let tasksRef = tasks
        let predecessor = Self.executionSettlement.barrier()
        operationTask = Task.detached {
            guard await ScanProducerSettlementChain.waitForSettlement(predecessor) else { return }
            let batch = tasksRef.runAll(requestedTasks)
            let taskWasCancelled = Task.isCancelled
            await MainActor.run {
                guard let shouldPublish = operationGate.finishIfCurrent(
                    identity,
                    taskWasCancelled: taskWasCancelled
                ) else { return }
                operationTask = nil
                runningTasks.removeAll()
                guard shouldPublish else { return }
                for o in batch { outcomes.insert(o, at: 0) }
            }
        }
    }

    private func cancelOperationForDeparture() {
        operationGate.invalidate()
        if let operationTask {
            Self.executionSettlement.retire([operationTask])
        }
        operationTask = nil
        runningTasks.removeAll()
    }

    // MARK: - presentation helpers

    private func icon(for task: MaintenanceTasks.Task) -> String {
        switch task {
        case .flushQuickLookCache:   return "eye.trianglebadge.exclamationmark"
        case .flushDNSCache:         return "network"
        }
    }

    private func localizedTitle(for task: MaintenanceTasks.Task) -> String {
        switch task {
        case .flushQuickLookCache:
            return AppLocalization.string("maintenance.task.quicklook.title", locale: locale)
        case .flushDNSCache:
            return AppLocalization.string("maintenance.task.dns.title", locale: locale)
        }
    }

    private func localizedSubtitle(for task: MaintenanceTasks.Task) -> String {
        switch task {
        case .flushQuickLookCache:
            return AppLocalization.string("maintenance.task.quicklook.subtitle", locale: locale)
        case .flushDNSCache:
            return AppLocalization.string("maintenance.task.dns.subtitle", locale: locale)
        }
    }
}
