import Foundation
import Darwin

/// v2026.10.08: permissive rules must match the target filesystem's name semantics.
/// Protective rules can remain conservatively case-folded; a positive match cannot assume
/// that APFS is insensitive. Exact spelling avoids filesystem queries on the normal hot path.
struct FileSystemPathSemantics: Sendable {
    let isCaseSensitive: @Sendable (String) -> Bool?

    init(isCaseSensitive: @escaping @Sendable (String) -> Bool? = Self.queryCaseSensitivity) {
        self.isCaseSensitive = isCaseSensitive
    }

    func matchesSafeRule(pattern: String, path: String) -> Bool {
        if !PathGlob.isGlob(pattern) {
            func matches(_ value: String, _ prefix: String) -> Bool {
                value.hasPrefix(prefix) && (prefix.hasSuffix("/") || value == prefix
                    || value.dropFirst(prefix.count).first == "/")
            }
            if matches(path, pattern) { return true }
            return matches(path.lowercased(), pattern.lowercased()) && isCaseSensitive(path) == false
        }
        if PathGlob.matchPrefix(pattern: pattern, path: path, caseSensitive: true) { return true }
        guard PathGlob.matchPrefix(pattern: pattern, path: path),
              isCaseSensitive(path) == false else { return false }
        return true
    }

    /// Query the nearest existing ancestor, never infer a mounted volume's behavior from
    /// the HOME/default disk. An unavailable capability cannot authorize a folded match.
    static func queryCaseSensitivity(_ path: String) -> Bool? {
        var cursor = path
        while !cursor.isEmpty {
            errno = 0
            let value = cursor.withCString { pathconf($0, _PC_CASE_SENSITIVE) }
            if value == 0 { return false }
            if value == 1 { return true }
            guard errno == ENOENT || errno == ENOTDIR, cursor != "/" else { return nil }
            cursor = (cursor as NSString).deletingLastPathComponent
        }
        return nil
    }
}
