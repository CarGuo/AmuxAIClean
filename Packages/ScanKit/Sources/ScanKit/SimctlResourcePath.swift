/// A lexically unambiguous absolute resource path reported by CoreSimulator.
///
/// v2026.09.20: `standardizedFileURL.path == raw` rejected valid Cryptex paths because
/// Foundation can remove `/private` when the directory exists. Discovery and frozen-plan
/// validation must preserve the reported spelling without consulting mutable mount state.
/// This type deliberately proves only syntax, not filesystem identity or uninstall authority;
/// the managed UUID, deletable flag and execution-time authority checks remain mandatory.
public struct SimctlResourcePath: RawRepresentable, Sendable, Hashable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.hasPrefix("/"), rawValue != "/", !rawValue.utf8.contains(0) else {
            return nil
        }
        let components = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        self.rawValue = rawValue
    }

    /// Compare complete path components within the same reported path namespace.
    /// Different spellings are not guessed to be aliases and prefix siblings are rejected.
    public func isWithin(_ root: Self) -> Bool {
        rawValue == root.rawValue || rawValue.hasPrefix(root.rawValue + "/")
    }
}
