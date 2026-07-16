import SwiftUI
import AppKit

public struct TCCGuideView: View {
    public let onDismiss: (_ openedSettings: Bool) -> Void
    /// v2026.07.15：Button 的 String 标签显式读取当前界面语言，无需重启向导。
    @Environment(\.locale) private var locale

    public init(onDismiss: @escaping (_ openedSettings: Bool) -> Void) {
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("tcc.guide.title", bundle: .module)
                    .font(.title2.bold())
                Text("tcc.guide.subtitle", bundle: .module)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                section(
                    titleKey: "tcc.guide.why.title",
                    bodyKey: "tcc.guide.why.body"
                )
                section(
                    titleKey: "tcc.guide.how.title",
                    bodyKey: "tcc.guide.how.body"
                )
                section(
                    titleKey: "tcc.guide.skip.title",
                    bodyKey: "tcc.guide.skip.body"
                )
            }
            .padding(20)

            Divider()

            HStack {
                Button(AppLocalization.string("tcc.guide.button.later", locale: locale)) {
                    onDismiss(false)
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(AppLocalization.string("tcc.guide.button.open_settings", locale: locale)) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                    onDismiss(true)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 640)
    }

    @ViewBuilder
    private func section(titleKey: LocalizedStringKey, bodyKey: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titleKey, bundle: .module)
                .font(.headline)
            Text(bodyKey, bundle: .module)
                .foregroundStyle(.secondary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
