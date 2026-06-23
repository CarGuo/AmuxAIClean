import Darwin
import Foundation
import LogKit
import SafetyKit

/// Common app cache discovery built on top of the audited vendors.yaml path rules.
///
/// This scanner intentionally does not infer paths from app names. It only consumes
/// `VendorRule.category == "common_app_cache"` rules and expands their explicit paths.
/// That keeps consumer-app cleanup separate from uninstall leftovers and avoids
/// deleting neighboring databases, profile roots, sync folders, or chat media.
public actor CommonAppCacheScanner {

    public struct Options: Sendable {
        public var category: String
        public var includedVerdicts: Set<SafetyVerdict>
        public var timeoutSeconds: TimeInterval
        public var maxGlobExpansionsPerRule: Int
        public var maxEntriesPerPath: Int

        public init(
            category: String = "common_app_cache",
            includedVerdicts: Set<SafetyVerdict> = [.safe, .confirm],
            timeoutSeconds: TimeInterval = 12,
            maxGlobExpansionsPerRule: Int = 128,
            maxEntriesPerPath: Int = 200_000
        ) {
            self.category = category
            self.includedVerdicts = includedVerdicts
            self.timeoutSeconds = timeoutSeconds
            self.maxGlobExpansionsPerRule = max(1, maxGlobExpansionsPerRule)
            self.maxEntriesPerPath = max(1, maxEntriesPerPath)
        }

        public static let `default` = Options()
    }

    public struct Hit: Sendable, Hashable, Identifiable {
        public let ruleName: String
        public let bundleIDPrefix: String?
        public let source: String?
        public let url: URL
        public let isDirectory: Bool
        public let verdict: SafetyVerdict
        public let reason: String?
        public let sizeBytes: Int64
        public let entryCount: Int

        public var id: String { "\(ruleName)|\(url.path)" }

        public init(
            ruleName: String,
            bundleIDPrefix: String?,
            source: String?,
            url: URL,
            isDirectory: Bool,
            verdict: SafetyVerdict,
            reason: String?,
            sizeBytes: Int64,
            entryCount: Int
        ) {
            self.ruleName = ruleName
            self.bundleIDPrefix = bundleIDPrefix
            self.source = source
            self.url = url
            self.isDirectory = isDirectory
            self.verdict = verdict
            self.reason = reason
            self.sizeBytes = sizeBytes
            self.entryCount = entryCount
        }
    }

    private let options: Options

    public init(options: Options = .default) {
        self.options = options
    }

    public func discover(
        vendors: [VendorRule],
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) async -> [Hit] {
        let opts = options
        return await Task.detached(priority: .utility) {
            Self.detect(vendors: vendors, home: home, options: opts)
        }.value
    }

    public nonisolated static func detect(
        vendors: [VendorRule],
        home: URL,
        options: Options = .default
    ) -> [Hit] {
        let homePath = home.standardizedFileURL.path
        let deadline = Date().addingTimeInterval(options.timeoutSeconds)
        let fm = FileManager.default
        var hits: [Hit] = []

        let rules = vendors.filter { $0.category == options.category }
        GSYLog.info(.scan, "CommonAppCache scan start rules=\(rules.count) timeout=\(options.timeoutSeconds)s")

        ruleLoop: for rule in rules {
            if Date() >= deadline { break }
            for pathRule in rule.paths where options.includedVerdicts.contains(pathRule.verdict) {
                if Date() >= deadline { break ruleLoop }
                let expanded = expandPattern(
                    pathRule.path,
                    home: homePath,
                    fileManager: fm,
                    maxResults: options.maxGlobExpansionsPerRule
                )
                for path in expanded {
                    if Date() >= deadline { break ruleLoop }
                    var isDirectory = ObjCBool(false)
                    guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
                    let size = sizeOfPath(
                        path,
                        isDirectory: isDirectory.boolValue,
                        deadline: deadline,
                        maxEntries: options.maxEntriesPerPath
                    )
                    let bytes = size.bytes
                    guard bytes > 0 else { continue }
                    hits.append(Hit(
                        ruleName: rule.name,
                        bundleIDPrefix: rule.bundleIDPrefix,
                        source: rule.source,
                        url: URL(fileURLWithPath: path),
                        isDirectory: isDirectory.boolValue,
                        verdict: pathRule.verdict,
                        reason: pathRule.reason,
                        sizeBytes: bytes,
                        entryCount: size.entryCount
                    ))
                }
            }
        }

        GSYLog.info(.scan, "CommonAppCache scan finished hits=\(hits.count)")
        return hits.sorted {
            if $0.sizeBytes == $1.sizeBytes { return $0.url.path < $1.url.path }
            return $0.sizeBytes > $1.sizeBytes
        }
    }

    static func expandHome(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    static func expandPattern(
        _ rawPattern: String,
        home: String,
        fileManager: FileManager,
        maxResults: Int
    ) -> [String] {
        let pattern = URL(fileURLWithPath: expandHome(rawPattern, home: home)).standardizedFileURL.path
        guard PathGlob.isGlob(pattern) else { return [pattern] }

        var results: [String] = []
        expandGlobComponents(
            NSString(string: pattern).pathComponents,
            fileManager: fileManager,
            maxResults: maxResults,
            output: &results
        )
        return results
    }

    private static func expandGlobComponents(
        _ components: [String],
        fileManager: FileManager,
        maxResults: Int,
        output: inout [String]
    ) {
        if output.count >= maxResults { return }
        guard let globIndex = components.firstIndex(where: { PathGlob.isGlob($0) }) else {
            output.append(NSString.path(withComponents: components))
            return
        }

        let baseComponents = Array(components[..<globIndex])
        let glob = components[globIndex]
        let rest = Array(components[(globIndex + 1)...])
        let base = NSString.path(withComponents: baseComponents.isEmpty ? ["/"] : baseComponents)
        guard let names = try? fileManager.contentsOfDirectory(atPath: base) else { return }

        for name in names.sorted() {
            if output.count >= maxResults { return }
            guard PathGlob.match(pattern: glob, path: name) else { continue }
            expandGlobComponents(
                baseComponents + [name] + rest,
                fileManager: fileManager,
                maxResults: maxResults,
                output: &output
            )
        }
    }

    private struct SizeStat {
        let bytes: Int64
        let entryCount: Int
    }

    private static func sizeOfPath(
        _ path: String,
        isDirectory: Bool,
        deadline: Date,
        maxEntries: Int
    ) -> SizeStat {
        if !isDirectory {
            var st = stat()
            guard lstat(path, &st) == 0 else { return SizeStat(bytes: 0, entryCount: 0) }
            return SizeStat(bytes: Int64(st.st_size), entryCount: 1)
        }
        return sizeOfDirectory(path, deadline: deadline, maxEntries: maxEntries)
    }

    private static func sizeOfDirectory(_ rootPath: String, deadline: Date, maxEntries: Int) -> SizeStat {
        var rootStat = stat()
        guard stat(rootPath, &rootStat) == 0 else { return SizeStat(bytes: 0, entryCount: 0) }
        let rootDevice = UInt64(bitPattern: Int64(rootStat.st_dev))

        var stack = [rootPath]
        var total: Int64 = 0
        var entries = 0
        var shouldStop = false

        while let dir = stack.popLast() {
            if shouldStop || Date() >= deadline || entries >= maxEntries { break }
            let fd = open(dir, O_RDONLY, 0)
            if fd < 0 { continue }
            BulkEnumerate.enumerate(fd: fd, dirPath: dir) { entry in
                entries += 1
                if entries & 0xFF == 0, Date() >= deadline {
                    shouldStop = true
                    return false
                }
                if entries >= maxEntries {
                    shouldStop = true
                    return false
                }
                if entry.isSymlink || entry.device != rootDevice { return true }
                if entry.isDirectory {
                    stack.append("\(dir)/\(entry.name)")
                } else {
                    total += entry.logicalSize
                }
                return true
            }
            close(fd)
        }
        return SizeStat(bytes: total, entryCount: entries)
    }
}
