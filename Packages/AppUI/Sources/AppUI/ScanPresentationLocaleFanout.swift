import Foundation

/// App 生命周期内两个扫描协调器的统一语言同步边界。
///
/// v2026.07.16：Professional 与 Smart Care 的 `ScanCoordinator` 都由 App 持有，
/// 主窗口关闭后仍然存活。语言同步不能依赖 `MainView.onChange`，否则用户只打开
/// Settings 切换语言时，后续由托盘/HUD 发起的扫描仍会生成旧语言的 String 文案。
/// 这里只更新协调器的展示 locale；不会启动扫描、替换协调器或重建扫描快照。
@MainActor
public enum ScanPresentationLocaleFanout {
    public static func apply(
        _ locale: Locale,
        professionalCoordinator: ScanCoordinator,
        smartCareCoordinator: ScanCoordinator
    ) {
        professionalCoordinator.updatePresentationLocale(locale)
        smartCareCoordinator.updatePresentationLocale(locale)
    }
}
