import Foundation

/// 主扫描界面唯一的“扫描问题”投影。
///
/// 扫描引擎可能同时保留 permission / TCC / incomplete 兼容数组；UI 不能分别画三块，
/// 更不能再追加 raw `lastError`。本模型先按路径去重、按语义分区，再只产生一个互斥状态。
struct ScanIssuePresentation: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case none
        case limitations
        case fatal
    }

    let kind: Kind
    let permissionDeniedPaths: [String]
    let tccSkippedPaths: [String]
    let otherIncompletePaths: [String]

    var allLimitedPaths: [String] {
        Array(Set(permissionDeniedPaths + tccSkippedPaths + otherIncompletePaths)).sorted()
    }

    var limitationCount: Int { allLimitedPaths.count }
    var hasLimitations: Bool { limitationCount > 0 }

    static func make(
        hasTerminalFailure: Bool,
        permissionDeniedPaths: [String],
        tccSkippedPaths: [String],
        incompletePaths: [String]
    ) -> Self {
        let permission = normalized(permissionDeniedPaths)
        let tcc = normalized(tccSkippedPaths)
        let alreadyClassified = Set(permission).union(tcc)
        let incomplete = normalized(incompletePaths).filter { !alreadyClassified.contains($0) }
        let hasLimitations = !permission.isEmpty || !tcc.isEmpty || !incomplete.isEmpty

        return Self(
            kind: hasTerminalFailure ? .fatal : (hasLimitations ? .limitations : .none),
            permissionDeniedPaths: permission,
            tccSkippedPaths: tcc,
            otherIncompletePaths: incomplete
        )
    }

    private static func normalized(_ paths: [String]) -> [String] {
        Array(Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })).sorted()
    }
}
