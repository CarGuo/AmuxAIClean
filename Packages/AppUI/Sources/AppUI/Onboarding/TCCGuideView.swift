import SwiftUI
import AppKit

public struct TCCGuideView: View {
    public let onDismiss: (_ openedSettings: Bool) -> Void

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
                    title: "为什么需要",
                    body: "macOS 把 ~/Library/Mail、~/Library/Safari、~/Library/Calendars 等目录列为高敏区，普通进程读取会被系统拦截（errno=1，Operation not permitted），导致这部分缓存与残留无法被识别和清理。"
                )
                section(
                    title: "如何授予",
                    body: "点击下方「打开系统设置」，在「隐私与安全性 → 完全磁盘访问」中找到 GSY 清理管家并打开开关，随后回到本应用即可生效。"
                )
                section(
                    title: "不授予会怎样",
                    body: "应用仍可使用，但隐私目录扫描会被跳过；扫描结果可能漏报，部分缓存残留无法清理。你可以稍后再说，并随时在设置中开启。"
                )
            }
            .padding(20)

            Divider()

            HStack {
                Button(String(localized: "tcc.guide.button.later", bundle: .module)) {
                    onDismiss(false)
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(String(localized: "tcc.guide.button.open_settings", bundle: .module)) {
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
    private func section(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(body)
                .foregroundStyle(.secondary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
