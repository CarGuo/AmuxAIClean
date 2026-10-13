import Foundation
import Darwin
import LogKit

/// 浏览器旧版 Framework 扫描器（Step 12C / AUDIT §4.2 P1 / line 117 + 435）。
///
/// macOS Chrome / Edge / Brave / Chromium 系浏览器在 Framework bundle 里使用
/// **多版本并存 + Current 软链** 的标准布局：
///
/// ```
/// /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/
/// └── Versions/
///     ├── 124.0.6367.207/      ← 旧版本（safe 候选）
///     ├── 125.0.6422.142/      ← 旧版本（safe 候选）
///     ├── 126.0.6478.127/      ← 当前版本（**不动**）
///     └── Current -> 126.0.6478.127  ← 软链与版本子目录**同级**
/// ```
///
/// 注意 `Current` 软链位于 `Versions/` **内部**，与版本子目录同级，这与
/// `VersionsScanner` 的 `current` / `versions` 同级布局不同，因此独立实现。
/// `MicrosoftEdgeUpdater.framework`、`Brave Browser Framework.framework` 等同款。
///
/// 安全护栏（与 VersionsScanner 一致的反向选择思路）：
///   - Current 软链落点必须解析为 `Versions/<X>` 中的某个目录 → 否则整个 framework 不识别；
///   - Current 所指版本 → **永远跳过**（不会出现在 hits）；
///   - readlink 失败 → 整个 framework 不识别；
///   - 只识别**目录**版本（不动文件 / 软链 / "."、".." / 隐藏项）。
public actor BrowserOldFrameworkScanner {

    public struct Hit: Sendable, Hashable, Identifiable {
        /// 旧版本目录绝对路径，如 `.../Versions/124.0.6367.207`。
        public let url: URL
        /// 该版本所属的 framework bundle 根，如 `.../Google Chrome Framework.framework`。
        public let frameworkRoot: URL
        /// 当前激活版本目录名（Current 软链所指）。
        public let activeVersion: String
        /// 该旧版本目录名（如 `124.0.6367.207`）。
        public let versionName: String

        public var id: String { url.path }

        public init(url: URL, frameworkRoot: URL, activeVersion: String, versionName: String) {
            self.url = url
            self.frameworkRoot = frameworkRoot
            self.activeVersion = activeVersion
            self.versionName = versionName
        }
    }

    public struct Options: Sendable {
        /// 待扫描的 framework bundle 根列表（每条形如
        /// `<...>.app/Contents/Frameworks/<X>.framework`）。
        public var frameworkRoots: [URL]
        /// 版本子目录名（Chromium 系标准为大写 `Versions`）。
        public var versionsDirectoryNames: Set<String>
        /// 当前激活指针名（Chromium 系标准为大写 `Current`）。
        public var currentSymlinkNames: Set<String>

        public init(
            frameworkRoots: [URL],
            versionsDirectoryNames: Set<String> = ["Versions"],
            currentSymlinkNames: Set<String> = ["Current"]
        ) {
            self.frameworkRoots = frameworkRoots
            self.versionsDirectoryNames = versionsDirectoryNames
            self.currentSymlinkNames = currentSymlinkNames
        }
    }

    private let options: Options
    public init(options: Options) { self.options = options }

    public func discover() async -> [Hit] {
        let opts = options
        return await Task.detached(priority: .userInitiated) {
            BrowserOldFrameworkScanner.detect(options: opts)
        }.value
    }

    public nonisolated static func detect(options: Options) -> [Hit] {
        var hits: [Hit] = []
        for fw in options.frameworkRoots {
            hits.append(contentsOf: detectOne(frameworkRoot: fw, options: options))
        }
        return hits
    }

    private nonisolated static func detectOne(
        frameworkRoot: URL,
        options: Options
    ) -> [Hit] {
        let fm = FileManager.default

        // 1) framework 根必须是目录
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: frameworkRoot.path, isDirectory: &isDir),
              isDir.boolValue else {
            return []
        }

        // 2) 在 framework 直接子目录里找 Versions
        guard let topEntries = try? fm.contentsOfDirectory(atPath: frameworkRoot.path) else {
            return []
        }
        let topSet = Set(topEntries)
        guard let versionsName = options.versionsDirectoryNames
            .first(where: { topSet.contains($0) })
        else { return [] }
        let versionsDir = frameworkRoot.appendingPathComponent(versionsName)

        // 3) 在 Versions/ 里找 Current 软链与所有版本子目录
        guard let versionsEntries = try? fm.contentsOfDirectory(atPath: versionsDir.path) else {
            return []
        }
        let versionsSet = Set(versionsEntries)
        guard let currentName = options.currentSymlinkNames
            .first(where: { versionsSet.contains($0) })
        else { return [] }
        let currentLink = versionsDir.appendingPathComponent(currentName)

        // 4) Current 必须是软链
        guard let attrs = try? fm.attributesOfItem(atPath: currentLink.path),
              let type = attrs[.type] as? FileAttributeType,
              type == .typeSymbolicLink
        else { return [] }

        // 5) readlink（支持多级软链）→ 解析相对路径 → 必须落在 Versions/ 内且目标目录真实存在
        let versionsDirResolved = versionsDir.resolvingSymlinksInPath().standardizedFileURL
        var cursorURL = currentLink
        var resolvedTarget: URL?
        for _ in 0..<16 {
            guard let itemAttrs = try? fm.attributesOfItem(atPath: cursorURL.path),
                  let itemType = itemAttrs[.type] as? FileAttributeType else {
                return []
            }
            if itemType == .typeSymbolicLink {
                guard let dest = try? fm.destinationOfSymbolicLink(atPath: cursorURL.path) else {
                    return []
                }
                if (dest as NSString).isAbsolutePath {
                    cursorURL = URL(fileURLWithPath: dest).standardizedFileURL
                } else {
                    cursorURL = URL(
                        fileURLWithPath: dest,
                        relativeTo: cursorURL.deletingLastPathComponent()
                    ).standardizedFileURL
                }
            } else {
                resolvedTarget = cursorURL.standardizedFileURL
                break
            }
        }
        guard let activeTargetURL = resolvedTarget else {
            return []
        }
        guard let activeIdentity = directoryIdentity(activeTargetURL),
              let versionsIdentity = directoryIdentity(versionsDirResolved) else {
            return []
        }

        let activeVersionParentResolved = activeTargetURL
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard directoryIdentity(activeVersionParentResolved) == versionsIdentity else {
            AmuxLog.notice(.scan,
                          "BrowserOldFramework Current 落点不在 Versions/ 内 fw=\(frameworkRoot.path) target=\(activeTargetURL.path)")
            return []
        }

        // 6) 列举 Versions/* 子目录，按 (st_dev, st_ino) 识别 active，排除 Current / 隐藏项 / 软链 / 跨卷
        var activeVersion: String?
        var oldVersions: [(name: String, url: URL)] = []
        for name in versionsEntries {
            if options.currentSymlinkNames.contains(name) { continue }
            if name.hasPrefix(".") { continue }
            let child = versionsDir.appendingPathComponent(name)
            guard let identity = directoryIdentity(child),
                  identity.device == versionsIdentity.device else { continue }
            if identity == activeIdentity {
                activeVersion = name
                continue
            }
            oldVersions.append((name, child))
        }
        guard let activeVersion,
              directoryIdentity(currentLink.resolvingSymlinksInPath()) == activeIdentity,
              directoryIdentity(activeTargetURL) == activeIdentity else {
            return []
        }
        let hits = oldVersions.map { version in
            Hit(
                url: version.url,
                frameworkRoot: frameworkRoot,
                activeVersion: activeVersion,
                versionName: version.name
            )
        }

        if !hits.isEmpty {
            AmuxLog.info(.scan,
                        "BrowserOldFramework 识别到旧版本 fw=\(frameworkRoot.path) active=\(activeVersion) old=\(hits.count)")
        }
        return hits
    }

    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    /// lstat deliberately excludes a symbolic-link child even if its target is a directory.
    private nonisolated static func directoryIdentity(_ url: URL) -> DirectoryIdentity? {
        var metadata = stat()
        guard url.withUnsafeFileSystemRepresentation({ path in
            guard let path else { return false }
            return lstat(path, &metadata) == 0
        }), metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return nil }
        return DirectoryIdentity(device: metadata.st_dev, inode: metadata.st_ino)
    }
}
