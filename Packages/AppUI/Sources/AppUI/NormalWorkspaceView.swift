import AppKit
import SwiftUI

enum NormalWorkspaceSection: String, CaseIterable, Identifiable, Sendable {
    // v1.6.3: Normal mode exposes the four requested workspace sections. Remove
    // Uninstall from the route model as well as navigation, so no hidden route remains.
    case analyze, clean, optimize, status
    var id: String { rawValue }
    var titleKey: String {
        // v2026.09.06: explicit catalog references keep enum additions covered by
        // the project's localization integrity checks without a dynamic-key exemption.
        switch self {
        case .analyze: return "workspace.tab.analyze"
        case .clean: return "workspace.tab.clean"
        case .optimize: return "workspace.tab.optimize"
        case .status: return "workspace.tab.status"
        }
    }
    var icon: String {
        switch self {
        case .analyze: return "chart.pie"
        case .clean: return "sparkles"
        case .optimize: return "slider.horizontal.3"
        case .status: return "waveform.path.ecg"
        }
    }
}

/// v2026.09.06: Normal mode is a task-oriented workspace. Shared visual tokens and
/// existing business screens preserve the app's identity; navigation does not create
/// a second scanner, deletion engine, maintenance runner or AI authorization path.
struct NormalWorkspaceView<CleanContent: View>: View {
    @Binding var section: NormalWorkspaceSection
    let analysis: StorageAnalysisStore
    let probe: SystemProbeStore
    let pipeline: any DeletionPipeline
    let undoHistoryStore: UndoHistoryStore
    let isBusy: Bool
    let onToolBusyChange: (Bool) -> Void
    let onClean: () -> Void
    @ViewBuilder let cleanContent: () -> CleanContent
    @State private var status = SystemStatusStore()
    @State private var showHistory = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            navigation
            Divider().opacity(0.45)
            Group {
                switch section {
                case .analyze:
                    StorageAnalysisView(
                        store: analysis, probe: probe, pipeline: pipeline,
                        undoHistoryStore: undoHistoryStore,
                        onBusyChange: onToolBusyChange, onClean: onClean)
                case .clean:
                    cleanContent()
                case .optimize:
                    NormalMaintenanceView()
                case .status:
                    SystemStatusDashboard(store: status, probe: probe)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if section != .status {
                SystemStatusStrip(store: status, probe: probe) { section = .status }
                    .disabled(isBusy)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 16)
                    .padding(.top, 8)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: scenePhase) {
            if scenePhase == .active { await status.run() }
        }
        .onValueChange(of: showHistory) { _, visible in
            if visible { onToolBusyChange(true) }
        }
        .sheet(isPresented: $showHistory, onDismiss: { onToolBusyChange(false) }) {
            VStack(spacing: 0) {
                HStack {
                    Text("sidebar.section.undo_history", bundle: .module).font(.headline)
                    Spacer()
                    Button {
                        showHistory = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text("workspace.close", bundle: .module))
                }.padding(16)
                UndoHistoryScreen(store: undoHistoryStore)
            }
            .frame(width: 820, height: 540)
        }
    }

    private var navigation: some View {
        HStack(spacing: 16) {
            Label {
                Text("workspace.title", bundle: .module)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
            } icon: {
                Image(systemName: "sparkle").foregroundStyle(SmartCareMotionPalette.tealColor)
            }
            .frame(width: 195, alignment: .leading)

            Spacer(minLength: 0)
            HStack(spacing: 4) {
                ForEach(NormalWorkspaceSection.allCases) { item in
                    Button {
                        section = item
                    } label: {
                        Label {
                            Text(LocalizedStringKey(item.titleKey), bundle: .module)
                        } icon: {
                            Image(systemName: item.icon)
                        }
                        .font(
                            .system(.callout, design: .rounded).weight(section == item ? .semibold : .medium)
                        )
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                        .foregroundStyle(section == item ? Color.white : Color.secondary)
                        .background {
                            if section == item {
                                Capsule().fill(
                                    LinearGradient(
                                        colors: [
                                            SmartCareMotionPalette.blueColor,
                                            SmartCareMotionPalette.tealColor,
                                        ],
                                        startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                                .shadow(color: Color.accentColor.opacity(0.18), radius: 7, y: 3)
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                    .accessibilityIdentifier("normal.tab.\(item.rawValue)")
                }
            }
            .padding(5)
            .background(Color.primary.opacity(0.035), in: Capsule())
            Spacer(minLength: 0)

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button {
                    showHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 16))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(Text("sidebar.section.undo_history", bundle: .module))
                .accessibilityLabel(Text("sidebar.section.undo_history", bundle: .module))
                .disabled(isBusy)
            }
            .frame(width: 195, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

private struct NormalMaintenanceView: View {
    @State private var showsStartupItems = false
    var body: some View {
        VStack(spacing: 12) {
            Picker(selection: $showsStartupItems) {
                Text("maintenance.title", bundle: .module).tag(false)
                Text("sidebar.row.launch_agents", bundle: .module).tag(true)
            } label: {
                Text("workspace.optimize.tools", bundle: .module)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 340)
            .padding(.top, 20)
            if showsStartupItems { LaunchAgentScreen() } else { MaintenanceScreen() }
        }
        .padding(.horizontal, 16)
    }
}

enum NormalWorkspacePalette {
    static let colors: [Color] = [
        SmartCareMotionPalette.blueColor, SmartCareMotionPalette.tealColor,
        SmartCareMotionPalette.amberColor, .indigo, .purple, .cyan,
    ]
    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}
