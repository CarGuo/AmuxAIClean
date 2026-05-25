import AppKit

/// v1.3.x：App 激活策略控制器（决定是否显示 Dock 图标 / 顶部主菜单）。
///
/// 设计来源：用户原话「我们都有顶部托盘托管了，关闭后是不是可以不显示在底部托管」。
/// 既然菜单栏托盘已经能承担"打开主窗口 / 推荐扫描 / toggle HUD"三件事，
/// 关掉主窗口后再保留 Dock 图标就重复了。Bartender / iStat Menus / Rectangle 等
/// 菜单栏 App 的标准玩法是：关窗 = `.accessory`（隐 Dock + 隐主菜单），开窗 = `.regular`。
///
/// **三种 NSApp.ActivationPolicy 的实际差异**：
///
/// | 策略         | Dock 图标 | 顶部主菜单 (File/Edit/...) | ⌘Tab | 能激活窗口 |
/// |--------------|----------|---------------------------|------|-----------|
/// | `.regular`   | YES      | YES                       | YES  | YES       |
/// | `.accessory` | NO       | NO                        | NO   | YES（窗口仍可显示）|
/// | `.prohibited`| NO       | NO                        | NO   | NO（纯后台进程）|
///
/// 我们用 `.regular ⇄ .accessory` 切换：
/// - 主窗口可见（哪怕被遮挡）→ `.regular`：用户处在"工作态"，Dock 图标提供归属感与 ⌘Tab 切换
/// - 主窗口被关 / 隐藏 → `.accessory`：进入"驻留态"，App 隐入菜单栏托盘
///
/// **为什么不用 `.prohibited`**：那等于禁止 App 激活前台，主窗口连 makeKeyAndOrderFront 都失效，
/// 用户从托盘点"打开主窗口"会毫无反应。
///
/// **副作用与告知用户的内容**：
/// 1. 切到 `.accessory` 时，**整条 macOS 顶部主菜单（File / Edit / View / Window / Help）也会消失**——
///    这意味着我们 commands 里挂在 .toolbar 区的"显示扫描悬浮窗 ⌘⇧H"和挂在 .appInfo 区的
///    "检查更新…" 在主窗口关闭期间不可访问。要靠托盘菜单 / 主窗口重开来代偿。
/// 2. 切到 `.accessory` 后，App 会从 ⌘Tab 应用切换器消失。这是设计如此，不是 bug。
/// 3. 切回 `.regular` 时，需要紧接着调 `NSApp.activate()` 才能让 App 真正抢到前台焦点；
///    AppKit 老 bug：accessory→regular 后焦点不会自动转移。
///
/// **MainActor 隔离**：`NSApplication.setActivationPolicy(_:)` 必须在主线程调用。
@MainActor
public final class ActivationPolicyController {

    /// 当前内部记录的策略，避免重复调 setActivationPolicy 触发 Dock 闪烁。
    private var current: NSApplication.ActivationPolicy = .regular

    public init() {}

    /// 切到 `.regular`：显示 Dock 图标 + 顶部主菜单 + 可被 ⌘Tab 命中。
    /// 主窗口出现时调用。
    public func enterRegular() {
        applyIfChanged(.regular)
        // accessory→regular 后 AppKit 不会自动给 App 抢焦点，必须显式 activate，
        // 否则用户点托盘"打开主窗口"会看到窗口但焦点仍在前一个 App。
        NSApp.activate()
    }

    /// 切到 `.accessory`：隐 Dock 图标 + 隐顶部主菜单 + ⌘Tab 不再命中。
    /// 主窗口被关闭/全部隐藏时调用。
    public func enterAccessory() {
        applyIfChanged(.accessory)
    }

    /// 根据"是否启用关窗藏 Dock"+"主窗口是否可见"决定目标策略并应用。
    /// - Parameters:
    ///   - hideEnabled: settings.hideFromDockWhenClosed
    ///   - hasVisibleMainWindow: 当前是否至少有一个主窗口处于可见态（非 isMiniaturized 算可见也算）
    ///
    /// 取舍说明：
    /// - 关掉开关时永远 regular，保持现行行为不打扰存量用户。
    /// - 开开关时仅在"主窗口完全不在场"才切 accessory；最小化状态保留 regular，
    ///   因为最小化的窗口仍在 Dock 上有缩略图，用户预期点 Dock 能恢复，
    ///   切 accessory 会让 Dock 缩略图消失，体验割裂。
    public func reconcile(hideEnabled: Bool, hasVisibleMainWindow: Bool) {
        if !hideEnabled {
            // 开关关闭：永远保持 regular，不动用户当前焦点。
            applyIfChanged(.regular)
            return
        }
        if hasVisibleMainWindow {
            enterRegular()
        } else {
            enterAccessory()
        }
    }

    private func applyIfChanged(_ policy: NSApplication.ActivationPolicy) {
        guard policy != current else { return }
        NSApp.setActivationPolicy(policy)
        current = policy
    }
}
