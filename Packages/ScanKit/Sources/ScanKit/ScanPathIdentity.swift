import Foundation

/// v2026.10.09: scan policy is attached to the selected namespace. Foundation URL
/// standardization may alias `/private/var` to `/var`, changing TCC policy before I/O.
/// Root planning may fold lexical components, but filesystem aliasing belongs only to
/// an explicit ScanPathNamespace projection. This operation performs no filesystem I/O.
public enum ScanPathIdentity {
    public static func lexicallyNormalizedURL(_ url: URL) -> URL {
        URL(fileURLWithPath: lexicallyNormalizedPath(url.path), isDirectory: url.hasDirectoryPath)
    }

    /// Hot-path consumers already own a path string. Avoid constructing URLs (including
    /// Foundation's directory inference) for every row or evidence lookup. Already
    /// normalized paths retain their storage; only actual lexical changes rebuild it.
    public static func lexicallyNormalizedPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        if !path.contains("//"), !path.contains("/./"), !path.contains("/../"),
           !path.hasSuffix("/"), !path.hasSuffix("/."), !path.hasSuffix("/.."),
           !path.hasPrefix("./"), !path.hasPrefix("../"), path != ".", path != ".." {
            return path
        }
        let absolute = path.hasPrefix("/")
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..":
                if let last = components.last, last != ".." { components.removeLast() }
                else if !absolute { components.append(component) }
            default: components.append(component)
            }
        }
        let joined = components.joined(separator: "/")
        return absolute ? "/" + joined : (joined.isEmpty ? "." : joined)
    }
}
