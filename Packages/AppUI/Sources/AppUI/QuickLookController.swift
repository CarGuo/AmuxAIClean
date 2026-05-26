import Foundation
import AppKit
import Quartz

/// v1.2 P2-4：Spacebar 触发 macOS 原生 Quick Look 预览。
///
/// 设计要点：
/// 1. **复用系统单例 `QLPreviewPanel.shared()`** —— Apple 官方支持的方式；不要自己造预览窗口。
/// 2. **单例 DataSource + Delegate** —— Panel 是全应用共用的，单例 controller 负责
///    维持当前要预览的 url 列表与索引；任何视图都能调 `.preview(urls:initialIndex:)`。
/// 3. **不持久化**——关掉 panel 后 controller 就丢清单（避免拿到旧 url 的悬空预览）。
/// 4. **目录与不存在路径直接拒绝**——QLPreviewPanel 对不存在 url 会闪退到错误占位，
///    这里先做一道前置过滤，体验更稳。
@MainActor
public final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    public static let shared = QuickLookController()

    private var urls: [URL] = []
    private var initialIndex: Int = 0

    private override init() { super.init() }

    /// 触发预览。`urls` 为空 / 全部不存在则不弹 panel。
    public func preview(urls: [URL], initialIndex: Int = 0) {
        let valid = Self.filterPreviewable(urls: urls)
        guard !valid.isEmpty else { return }
        self.urls = valid
        self.initialIndex = max(0, min(initialIndex, valid.count - 1))

        // 只有 panel 已经就绪时调 reloadData；首次 makeKeyAndOrderFront 会自动取数据。
        let panel = QLPreviewPanel.shared()
        panel?.dataSource = self
        panel?.delegate = self
        if let p = panel, p.isVisible {
            p.reloadData()
            p.currentPreviewItemIndex = self.initialIndex
        } else {
            panel?.makeKeyAndOrderFront(nil)
            panel?.currentPreviewItemIndex = self.initialIndex
        }
    }

    /// 过滤"可预览"路径：跳过不存在 / 是目录的项。
    /// 单独抽出便于单测；纯函数无副作用，所以 `nonisolated` 让单测线程随便调。
    public nonisolated static func filterPreviewable(urls: [URL]) -> [URL] {
        urls.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
        }
    }

    /// 单测探测：当前内部状态（urls / initialIndex），用于断言 preview 是否正确接受参数。
    /// 不影响生产路径；仅 #if DEBUG 下暴露。
    #if DEBUG
    public var _testCurrentURLs: [URL] { urls }
    public var _testInitialIndex: Int { initialIndex }
    public func _testReset() { urls = []; initialIndex = 0 }
    #endif

    /// 关闭当前预览（用户按 Esc / 主动关闭走系统逻辑，这里用于程序触发，比如选中变没了）。
    public func close() {
        guard let p = QLPreviewPanel.shared(), p.isVisible else { return }
        p.orderOut(nil)
    }

    // MARK: - QLPreviewPanelDataSource
    //
    // QLPreviewPanel 协议方法在 Xcode 16.4 (Swift 6.0) 下要求 `nonisolated` 才能
    // 满足 `QLPreviewPanelDataSource` / `QLPreviewPanelDelegate` 这两个 NSObject
    // 协议（它们不是 @MainActor）。AppKit 的实际调用都发生在主线程，所以方法体内
    // 用 `MainActor.assumeIsolated` 安全访问 self.urls；这是 Apple 推荐的桥接模式。

    public nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    public nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let url: URL? = MainActor.assumeIsolated {
            guard index >= 0 && index < urls.count else { return nil }
            return urls[index]
        }
        guard let u = url else { return nil }
        return u as NSURL
    }

    // MARK: - QLPreviewPanelDelegate

    /// 把 ←/→ 与 Esc 留给 panel 自己处理；其他按键不拦截。
    public nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        false
    }
}
