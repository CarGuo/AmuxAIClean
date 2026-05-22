import SwiftUI
import AppUI
import SafetyKit

@main
struct GSYCleanMacApp: App {
    private let vendors: [VendorRule]

    /// v1.0：跨场景共享的设置 / 自定义路径状态（@MainActor @Observable + actor）。
    /// MainView 与 SettingsScene 共用同一份引用，⌘, 改了立刻生效。
    @State private var settings = AppSettings()
    private let pathStore = UserPathStore()

    @State private var showTCCGuide: Bool = false

    /// v1.1 更新检查器，启动时静默 GET 一次 GitHub Releases。
    @State private var updateChecker: UpdateChecker

    private let tccDismissedKey = "tcc.onboarding.dismissed"

    init() {
        self.vendors = Self.loadBundledVendors()
        let s = AppSettings()
        self._settings = State(initialValue: s)
        self._updateChecker = State(initialValue: UpdateChecker(settings: s))
    }

    var body: some Scene {
        WindowGroup("GSY 清理管家") {
            TabView {
                MainView(vendors: vendors, settings: settings, pathStore: pathStore)
                    .tabItem { Label("清理", systemImage: "sparkles") }
                UninstallScreen(vendors: vendors)
                    .tabItem { Label("卸载残留", systemImage: "trash.slash") }
            }
            .frame(minWidth: 1080, minHeight: 640)
            .task {
                await evaluateTCCOnboarding()
                // v1.1：尊重 settings.updateCheckEnabled 决定是否联网；用户可在设置里关
                updateChecker.checkOnLaunch()
            }
            .sheet(isPresented: $showTCCGuide) {
                TCCGuideView { openedSettings in
                    if openedSettings {
                        UserDefaults.standard.set(true, forKey: tccDismissedKey)
                    }
                    showTCCGuide = false
                }
            }
            .sheet(item: Binding(
                get: { updateChecker.availableUpdate.map { IdentifiedRelease(release: $0) } },
                set: { _ in updateChecker.dismissUntilNextLaunch() }
            )) { wrapped in
                UpdatePromptView(checker: updateChecker, release: wrapped.release)
            }
        }
        .commands {
            // v1.1：Help 菜单加"检查更新"入口
            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    updateChecker.checkNow()
                }
            }
        }

        // v1.0：标准 ⌘, 设置窗口（隐藏文件 toggle / 大文件阈值 / 自定义路径）。
        Settings {
            SettingsScene(settings: settings, pathStore: pathStore, updateChecker: updateChecker)
        }
    }

    private func evaluateTCCOnboarding() async {
        if UserDefaults.standard.bool(forKey: tccDismissedKey) {
            return
        }
        let probe = TCCProbe()
        let status = await probe.probe()
        if case .deniedReadable = status {
            await MainActor.run {
                showTCCGuide = true
            }
        }
    }

    private static func loadBundledVendors() -> [VendorRule] {
        guard let url = Bundle.main.url(forResource: "vendors",
                                        withExtension: "yaml",
                                        subdirectory: "Rules")
            ?? Bundle.main.url(forResource: "vendors", withExtension: "yaml")
        else {
            NSLog("[GSYCleanMac] vendors.yaml 未找到，跳过 vendor 规则加载")
            return []
        }
        do {
            let rules = try RuleLoader.loadVendors(from: url)
            NSLog("[GSYCleanMac] 已加载 \(rules.count) 条 vendor 规则")
            return rules
        } catch {
            NSLog("[GSYCleanMac] vendor 规则加载失败：\(error)")
            return []
        }
    }
}
