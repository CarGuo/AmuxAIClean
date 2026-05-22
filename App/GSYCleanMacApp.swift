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

    private let tccDismissedKey = "tcc.onboarding.dismissed"

    init() {
        self.vendors = Self.loadBundledVendors()
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
            }
            .sheet(isPresented: $showTCCGuide) {
                TCCGuideView { openedSettings in
                    if openedSettings {
                        UserDefaults.standard.set(true, forKey: tccDismissedKey)
                    }
                    showTCCGuide = false
                }
            }
        }

        // v1.0：标准 ⌘, 设置窗口（隐藏文件 toggle / 大文件阈值 / 自定义路径）。
        Settings {
            SettingsScene(settings: settings, pathStore: pathStore)
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
