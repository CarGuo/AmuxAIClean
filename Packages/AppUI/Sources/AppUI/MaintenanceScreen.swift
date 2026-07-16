import SwiftUI
import ScanKit

/// M4-T4：维护任务屏（user-space，无 sudo）。
///
/// 包 [MaintenanceTasks](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/MaintenanceTasks.swift)
/// 的两个内置任务（flushQuickLookCache / flushDNSCache），
/// 提供按钮、批量执行入口、按时间倒序的执行结果列表。
///
/// 设计契约：
/// - **不阻塞 UI**：`runTask(_:)` 在 detached Task 里调 `tasks.run(_:)`，主线程仅追加 outcome。
/// - **不依赖 ScanCoordinator**：完全独立屏幕，本身是只读 + 用户主动触发。
/// - **可注入** `tasks: MaintenanceTasks`：测试用注入 fake runner 即可绕开 Process.run。
public struct MaintenanceScreen: View {
    /// v2026.07.15：任务本身与 outcome 只保存语义/命令原始日志；所有标题、说明和
    /// 按钮在当前 View locale 下投影，避免运行结果留在页面时语言无法同步切换。
    @Environment(\.locale) private var locale

    private let tasks: MaintenanceTasks

    @State private var outcomes: [MaintenanceTasks.Outcome] = []
    @State private var runningTasks: Set<MaintenanceTasks.Task> = []

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
            .disabled(runningTasks.contains(task))
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
                if !outcome.log.isEmpty {
                    Text(outcome.log)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: - actions

    private func runTask(_ task: MaintenanceTasks.Task) {
        runningTasks.insert(task)
        let tasksRef = tasks
        Task.detached { [task] in
            let outcome = tasksRef.run(task)
            await MainActor.run {
                outcomes.insert(outcome, at: 0)
                runningTasks.remove(task)
            }
        }
    }

    private func runAll() {
        let all = MaintenanceTasks.Task.allCases
        runningTasks.formUnion(all)
        let tasksRef = tasks
        Task.detached {
            let batch = tasksRef.runAll(all)
            await MainActor.run {
                for o in batch { outcomes.insert(o, at: 0) }
                runningTasks.removeAll()
            }
        }
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
