import Foundation

/// simctl 动态发现的类型化失败边界。
///
/// **v2026.07.15 根因修复**：过去 launch / timeout / nonzero / JSON schema 变化都被
/// 折叠为 `[]`，上层只能把真实失败展示成“暂未发现”。现在完整成功且 payload 为空才
/// 返回空数组；任何无法证明完整性的情况都抛出本类型，由 WorkflowRegistry 转为
/// `DiscoveryEvidence.incompleteIssues`。命令原始输出只写结构化日志，不进入用户文案。
public enum SimctlDiscoveryError: Error, Sendable, Equatable {
    public enum Query: String, Sendable, Equatable {
        case devices
        case managedRuntimes
        case legacyRuntimes
    }

    case commandRejected(query: Query)
    case launchFailed(query: Query)
    case timedOut(query: Query)
    case commandFailed(query: Query, exitCode: Int32)
    case invalidPayload(query: Query)

    static func commandFailure(
        for result: SubprocessExecutor.Result,
        query: Query
    ) -> SimctlDiscoveryError? {
        switch result.exitCode {
        case 0:
            return nil
        case -1:
            return .launchFailed(query: query)
        case -2:
            return .timedOut(query: query)
        default:
            return .commandFailed(query: query, exitCode: result.exitCode)
        }
    }
}

extension SimctlDiscoveryError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .commandRejected(let query):
            return "simctl command rejected query=\(query.rawValue)"
        case .launchFailed(let query):
            return "simctl launch failed query=\(query.rawValue)"
        case .timedOut(let query):
            return "simctl timed out query=\(query.rawValue)"
        case .commandFailed(let query, let exitCode):
            return "simctl command failed query=\(query.rawValue) exit=\(exitCode)"
        case .invalidPayload(let query):
            return "simctl invalid payload query=\(query.rawValue)"
        }
    }
}
