import Foundation
import Darwin
import LogKit

/// `versions/*` 旧版本识别器。
///
/// 经典工具链版本管理布局（rustup / pyenv / nvm / asdf / node / pnpm shim 等）：
/// ```
/// ~/.toolchain/
///   ├── current -> versions/1.78.0    ← 软链，指向当前激活版本
///   └── versions/
///       ├── 1.76.0/                    ← 旧版本（safe）
///       ├── 1.77.0/                    ← 旧版本（safe）
///       └── 1.78.0/                    ← 当前版本（**不动**）
/// ```
///
/// `DevArtifactScanner` 的「目录名 + sibling 兜底」模型不擅长这种场景——
/// 它没法表达「除 current 软链所指版本外、其它兄弟都标 safe」这种**反向选择**语义。
///
/// 所以这里独立成 module，调用方先用 [DevArtifactScanner] 找出工具链根（如 ~/.rustup），
/// 再用 `VersionsScanner` 在工具链根里识别 versions/* 子结构，把旧版本作为额外
/// safe-by-default 候选 push 到 UI。
///
/// 为什么不直接把"当前版本"标 forbid？因为：
/// 1. 用户可能手动删 current 软链；这种情况整个 versions/ 都不识别（防误删）；
/// 2. current 也可能指向 versions/ 之外的路径（asdf 链到 plugin 内部），这种也跳过；
/// 3. 真正命中的判定是「current 软链 readlink 后落点正好是 versions/<X>」，
///    才能放心把 versions/ 下其它子目录标 safe。
///
/// 安全护栏：
/// - 只识别**目录**版本（不动文件 / 软链本身）；
/// - 跨卷不下钻；
/// - readlink 失败 / 落点不在 versions/ 内 → 整个 versions/ 不识别（保守）；
/// - current 软链所指目录 → **永远跳过**（不会出现在 hits 里）。
public actor VersionsScanner {

    /// 一条命中：某个 versions/* 旧版本目录。
    public struct Hit: Sendable, Hashable, Identifiable {
        /// 旧版本目录绝对路径，如 `/Users/foo/.rustup/toolchains/1.76.0`。
        public let url: URL
        /// 工具链根，如 `/Users/foo/.rustup`。命中时 toolchainRoot 父目录里至少有
        /// `current` 软链 + `versions`/`toolchains` 目录。
        public let toolchainRoot: URL
        /// 当前激活版本目录名（current 软链所指版本子目录的 lastPathComponent）。
        public let activeVersion: String
        /// 该旧版本目录名（如 `1.76.0`）。
        public let versionName: String

        public var id: String { url.path }

        public init(url: URL, toolchainRoot: URL, activeVersion: String, versionName: String) {
            self.url = url
            self.toolchainRoot = toolchainRoot
            self.activeVersion = activeVersion
            self.versionName = versionName
        }
    }

    /// 勘察配置。
    public struct Options: Sendable {
        /// 工具链版本子目录的常见名字。rustup 用 `toolchains`，pyenv/nvm/asdf 用 `versions`。
        public var versionsDirectoryNames: Set<String>
        /// 当前激活版本指针的常见名字。
        public var currentSymlinkNames: Set<String>

        public init(
            versionsDirectoryNames: Set<String> = ["versions", "toolchains"],
            currentSymlinkNames: Set<String> = ["current", "default"]
        ) {
            self.versionsDirectoryNames = versionsDirectoryNames
            self.currentSymlinkNames = currentSymlinkNames
        }

        public static let `default` = Options()
    }

    private let options: Options

    public init(options: Options = .default) {
        self.options = options
    }

    /// 在 `toolchainRoot` 下识别 `versions/*` 旧版本（保留 current 软链所指版本）。
    ///
    /// - Parameter toolchainRoot: 工具链根目录绝对路径，例如 `/Users/foo/.rustup`。
    /// - Returns: 旧版本目录命中列表；如果 current 软链不存在 / 落点非法，返回空。
    public func discover(toolchainRoot: URL) async -> [Hit] {
        let opts = options
        return await Task.detached(priority: .userInitiated) {
            VersionsScanner.detect(toolchainRoot: toolchainRoot, options: opts)
        }.value
    }

    /// 单根识别的同步实现（便于测试与并行批处理调用）。
    public nonisolated static func detect(
        toolchainRoot: URL,
        options: Options = .default
    ) -> [Hit] {
        let fm = FileManager.default
        let rootPath = toolchainRoot.path
        // 1) 工具链根必须是目录
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: rootPath, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        // 2) 找出 versions 目录与 current 软链
        guard let entries = try? fm.contentsOfDirectory(atPath: rootPath) else { return [] }
        let entrySet = Set(entries)

        guard let versionsName = options.versionsDirectoryNames.first(where: { entrySet.contains($0) }) else {
            return []
        }
        guard let currentName = options.currentSymlinkNames.first(where: { entrySet.contains($0) }) else {
            return []
        }

        let versionsDir = toolchainRoot.appendingPathComponent(versionsName)
        let currentLink = toolchainRoot.appendingPathComponent(currentName)

        // 3) current 必须是软链
        guard let currentAttrs = try? fm.attributesOfItem(atPath: currentLink.path),
              let type = currentAttrs[.type] as? FileAttributeType,
              type == .typeSymbolicLink
        else {
            return []
        }

        // 4) readlink（支持多级软链）→ 解析相对路径 → 必须落在 versions/ 内且目标目录真实存在
        let versionsDirResolved = versionsDir.resolvingSymlinksInPath().standardizedFileURL
        var cursorURL = currentLink
        var resolvedTarget: URL?
        for _ in 0..<16 {
            guard let attrs = try? fm.attributesOfItem(atPath: cursorURL.path),
                  let itemType = attrs[.type] as? FileAttributeType else {
                return []
            }
            if itemType == .typeSymbolicLink {
                guard let dest = try? fm.destinationOfSymbolicLink(atPath: cursorURL.path) else {
                    return []
                }
                if (dest as NSString).isAbsolutePath {
                    cursorURL = URL(fileURLWithPath: dest).standardizedFileURL
                } else {
                    // 相对路径基准是当前软链所在的父目录
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
            // current 落点不在 versions/ 内（如 asdf 落到 plugin 内部）→ 保守不识别
            AmuxLog.notice(.scan, "VersionsScanner current 软链落点不在 versions/ 内 root=\(rootPath) target=\(activeTargetURL.path)")
            return []
        }
        var activeVersion: String?

        // 5) 枚举 versions/* 子目录，排除 active
        guard let versionEntries = try? fm.contentsOfDirectory(atPath: versionsDir.path) else {
            return []
        }
        var oldVersions: [(name: String, url: URL)] = []
        for name in versionEntries {
            if name.hasPrefix(".") { continue }
            let child = versionsDir.appendingPathComponent(name)
            guard let identity = directoryIdentity(child),
                  identity.device == versionsIdentity.device else { continue }
            // v2026.10.08: readlink spelling is not filesystem identity. On insensitive
            // APFS `VACTIVE` may be the enumerated `vActive` directory; Unicode aliases
            // have the same issue. Only device/inode proves which directory is active.
            if identity == activeIdentity {
                activeVersion = name
                continue
            }
            oldVersions.append((name, child))
        }
        guard let activeVersion,
              directoryIdentity(currentLink.resolvingSymlinksInPath()) == activeIdentity,
              directoryIdentity(activeTargetURL) == activeIdentity else { return [] }
        let hits = oldVersions.map { version in
            Hit(
                url: version.url,
                toolchainRoot: toolchainRoot,
                activeVersion: activeVersion,
                versionName: version.name
            )
        }

        if !hits.isEmpty {
            AmuxLog.info(.scan, "VersionsScanner 识别到旧版本 root=\(rootPath) active=\(activeVersion) old=\(hits.count)")
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
