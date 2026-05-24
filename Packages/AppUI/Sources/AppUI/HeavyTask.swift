import Foundation

/// v2 重操作启动模板。
///
/// # 为什么需要这个
///
/// SwiftUI 视图侧的 `.onChange` 闭包默认在主线程同步执行；如果直接调用
/// 重操作（如 [startScan](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift)）：
///
///   .onChange(of: selection) { _, new in
///       startScan(...)        // ❌ 主线程同步占用，UI 来不及 commit
///   }
///
/// 用户体感：点完 sidebar 选项后，**当前一帧 UI 不会更新**（高亮没换，旧详情
/// 没清），鼠标转彩虹球，等扫描进程入队 / 元数据初始化完之后才动。
///
/// 哪怕改成 `Task { @MainActor in startScan(...) }`，本质仍然是把 startScan
/// 推到下一帧主线程同步跑—— SwiftUI 一般要 2-3 帧才能完成 layout commit，
/// 所以彩虹球仍然出现。
///
/// # 解决方案
///
/// 走 detached task → sleep 16ms（一帧）→ MainActor.run 模板：
///
/// ```swift
/// runHeavyAfterCommit {
///     startScan(category: cat)
/// }
/// ```
///
/// detached 切到 background priority queue，sleep 16ms 让出至少一个 vsync
/// 周期让 SwiftUI 把 sidebar 高亮 / 旧详情清空 / loading 状态 commit 出去，
/// 然后再切回 MainActor 跑 startScan。
///
/// # Sendable 保证
///
/// 闭包必须 `@Sendable + @MainActor`。MainView 是 struct value type，
/// 闭包内 `self.startScan(...)` 会复制一份 self；但因为 self 内的 @State
/// / @StateObject 是引用语义存储，复制是廉价的、且最终调用仍发生在主线程。
@MainActor
func runHeavyAfterCommit(_ work: @escaping @MainActor @Sendable () -> Void) {
    Task.detached(priority: .userInitiated) {
        try? await Task.sleep(nanoseconds: 16_000_000)
        await MainActor.run {
            work()
        }
    }
}
