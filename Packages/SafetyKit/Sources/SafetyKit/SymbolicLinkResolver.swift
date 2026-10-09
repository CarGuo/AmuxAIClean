import Foundation
import Darwin

/// v2026.10.09: one filesystem boundary for SafetyEngine and WhitelistStore.
/// Unlike Foundation's best-effort URL projection, a missing target does not discard
/// the links already traversed. Every component is resolved before processing `..`.
/// The platform's POSIX link budget bounds both cycles and acyclic chains.
/// Returns a policy-canonical path; consumers must not standardize a missing leaf again.
enum SymbolicLinkResolver {
    enum Failure: Error, Sendable, Equatable {
        case relativePath
        case linkLimitUnavailable
        case fileSystem(path: String, code: Int32)
    }

    private static let linkLimit = sysconf(_SC_SYMLOOP_MAX)

    static func resolve(_ path: String) -> Result<String, Failure> {
        guard path.hasPrefix("/") else { return .failure(.relativePath) }
        guard !path.utf8.contains(0) else {
            return .failure(.fileSystem(path: path, code: EINVAL))
        }
        // libc is the fast path for existing targets, preserving POSIX/APFS semantics.
        if let canonical = path.withCString({ realpath($0, nil) }) {
            defer { free(canonical) }
            return .success(URL(fileURLWithPath: String(cString: canonical)).standardizedFileURL.path)
        }
        let realpathError = errno
        guard realpathError == ENOENT else {
            return .failure(.fileSystem(path: path, code: realpathError))
        }
        guard linkLimit > 0 else { return .failure(.linkLimitUnavailable) }

        var pending = Array(path.split(separator: "/").map(String.init).reversed())
        var components: [String] = []
        var firstMissingDepth: Int?
        var linksFollowed = 0
        while let component = pending.popLast() {
            if component == "." { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
                if let depth = firstMissingDepth, components.count < depth {
                    firstMissingDepth = nil
                }
                continue
            }
            let candidate = "/" + (components + [component]).joined(separator: "/")
            if firstMissingDepth != nil {
                components.append(component)
                continue
            }
            var metadata = stat()
            guard lstat(candidate, &metadata) == 0 else {
                let code = errno
                guard code == ENOENT else {
                    return .failure(.fileSystem(path: candidate, code: code))
                }
                components.append(component)
                firstMissingDepth = components.count
                continue
            }
            if (metadata.st_mode & S_IFMT) == S_IFLNK {
                linksFollowed += 1
                guard linksFollowed <= linkLimit else {
                    return .failure(.fileSystem(path: candidate, code: ELOOP))
                }
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let length = readlink(candidate, &buffer, buffer.count - 1)
                guard length >= 0 else {
                    return .failure(.fileSystem(path: candidate, code: errno))
                }
                guard length < buffer.count - 1 else {
                    return .failure(.fileSystem(path: candidate, code: ENAMETOOLONG))
                }
                let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
                guard let target = String(bytes: bytes, encoding: .utf8) else {
                    return .failure(.fileSystem(path: candidate, code: EILSEQ))
                }
                if target.hasPrefix("/") { components.removeAll(keepingCapacity: true) }
                pending.append(contentsOf: target.split(separator: "/").map(String.init).reversed())
            } else {
                guard pending.isEmpty || (metadata.st_mode & S_IFMT) == S_IFDIR else {
                    return .failure(.fileSystem(path: candidate, code: ENOTDIR))
                }
                components.append(component)
            }
        }
        // Canonicalize the proven existing ancestor before attaching a missing suffix.
        // Foundation leaves physical aliases unchanged when the whole path is missing;
        // doing this after append would make policy identity depend on leaf existence.
        let ancestorDepth = firstMissingDepth.map { $0 - 1 } ?? components.count
        let ancestor = URL(fileURLWithPath: "/" + components.prefix(ancestorDepth).joined(separator: "/"))
            .standardizedFileURL.path
        let suffix = components.dropFirst(ancestorDepth).joined(separator: "/")
        return .success(suffix.isEmpty ? ancestor : (ancestor == "/" ? "/" : ancestor + "/") + suffix)
    }
}
