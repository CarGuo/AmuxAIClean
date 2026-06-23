import AppKit
import Foundation

/// 删除前的运行中 App 保护。
///
/// 常见软件缓存经常由对应 App 持续写入。真删前如果 App 仍在运行，
/// 先阻断并提示用户退出后重试，避免出现半删半写、App 立即重建、或同步客户端重新下载风暴。
public enum RunningAppGuard {
    public struct Conflict: Sendable, Equatable {
        public let path: String
        public let title: String
        public let bundleIDPrefix: String
        public let runningBundleID: String

        public init(path: String, title: String, bundleIDPrefix: String, runningBundleID: String) {
            self.path = path
            self.title = title
            self.bundleIDPrefix = bundleIDPrefix
            self.runningBundleID = runningBundleID
        }
    }

    public static func currentRunningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    public static func conflicts(rows: [RowItem],
                                 runningBundleIDs: Set<String>) -> [Conflict] {
        var out: [Conflict] = []
        var seen = Set<String>()
        for row in rows {
            guard let prefix = row.runningBundleIDPrefix?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !prefix.isEmpty else { continue }
            guard let running = runningBundleIDs.first(where: { $0 == prefix || $0.hasPrefix(prefix + ".") }) else {
                continue
            }
            let key = "\(prefix)|\(row.id)"
            guard seen.insert(key).inserted else { continue }
            out.append(Conflict(path: row.url.path,
                                title: row.title,
                                bundleIDPrefix: prefix,
                                runningBundleID: running))
        }
        return out
    }
}
