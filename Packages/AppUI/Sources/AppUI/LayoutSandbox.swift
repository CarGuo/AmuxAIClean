import SwiftUI

/// v2 布局沙箱（width sandbox）。
///
/// # 为什么需要这个
///
/// SwiftUI 的布局协议是双向的尺寸协商：父给子 proposed size，子返回 ideal size，
/// 父再决定最终 frame。**铁律是：子的 ideal size 会反向影响父的 ideal size。**
///
/// 这就导致一条嵌套链：
///
///   NavigationSplitView (detail 列) → results VStack → HStack(横向分栏)
///   → List → ForEach Row → RowView (HStack: 路径 + 大小)
///
/// 任何一行 RowView 路径 ideal width 异常大（10 GB+ 文件 / 长路径），它会顺着
/// 这条链一路往外推，最终把 NavigationSplitView 的 detail 列 ideal width 抬高，
/// 反挤 sidebar —— 用户截图里"sidebar 被挤成竖线"就是这么来的。
///
/// # 怎么解决
///
/// 在 detail 入口处用 `GeometryReader` 把父 proposed width **物理钉死**：
///
///   GeometryReader { geo in
///       content.frame(width: geo.size.width, height: geo.size.height)
///   }
///
/// `GeometryReader` 自身会 fill 父给它的 proposed size，并把这个 size 暴露成 `geo`；
/// 我们再把 child 的 frame `.frame(width:...)` 钉死——子无论 ideal width 多大，
/// 渲染时都被截断在沙箱宽度内。**沙箱的 ideal size 只取决于父 proposed**，
/// 反推链被切断。
///
/// # 注意
///
/// - GeometryReader 默认占满 proposed width 与 height；外层只要给到合理的
///   `.frame(maxWidth: .infinity, maxHeight: .infinity)` 即可。
/// - 沙箱是单向阀：内向 fixed，外向不再反推。
/// - 不要在 sandbox 里再嵌 sandbox（嵌套 GeometryReader 在某些 SwiftUI 版本会
///   引发 multi-pass layout warning），单层就够。
struct WidthSandbox<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geo in
            content()
                .frame(width: geo.size.width,
                       height: geo.size.height,
                       alignment: .topLeading)
        }
    }
}

extension View {
    /// 把当前视图包进 [WidthSandbox](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/LayoutSandbox.swift)，
    /// 切断子的 ideal size 对外层的反推。
    ///
    /// 用法：detail 入口或 split detail panel 的最外层调用一次。
    /// 不要在 List 行内调用——行内长路径用 lineLimit + truncationMode 解决，
    /// 不需要沙箱。
    func layoutSandbox() -> some View {
        WidthSandbox { self }
    }
}
