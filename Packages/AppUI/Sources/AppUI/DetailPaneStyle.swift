import SwiftUI

/// v2 详情面板样式统一。
///
/// 把所有 inline detail panel（清单 / 树形 / 应用占用 / 重复文件等）的
/// padding / lineLimit / truncationMode / maxWidth 集中在一处，避免每个
/// screen 自己写一套又互不一致。
///
/// 用法：detail 内容容器的最外层加 `.detailPaneStyle()`。
struct DetailPaneStyleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    func detailPaneStyle() -> some View {
        modifier(DetailPaneStyleModifier())
    }

    /// 单行长路径文本统一处理：限制 3 行、中间省略号、不允许 ideal width 反推父。
    /// 详情区里所有显示文件路径 / URL 的 Text 都应该叠这一层。
    func longPathStyle() -> some View {
        self.lineLimit(3)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
