import Foundation

/// Step 11A / 2026-06：Spotlight 残留补刀。
///
/// 背景：[AppUninstaller.candidatesAsync](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppUninstaller.swift)
/// 走 11 个用户级 + 1 个系统级 search root 第一层目录扫描；
/// 但有些 app 的残留落在**非典型位置**（比如某厂商把数据写在
/// `~/Library/Mobile Documents/iCloud~xxx`、`~/Documents/<AppName>` 等），
/// 第一层 root 列表无法穷举。
///
/// 解决：扫完主路径后，用 macOS Spotlight（NSMetadataQuery）做一次
/// 严格谓词补刀，查 `kMDItemCFBundleIdentifier == bundleID` 与
/// `kMDItemDisplayName ==[c] appName` 命中的路径，与主路径去重后追加。
///
/// 设计要点：
/// 1. **协议抽象**：`SpotlightProbing` 让单测可以用 fake 注入固定路径，
///    避免依赖系统 mds 索引（CI 环境通常索引不全）。
/// 2. **严格谓词**：bundleID 用 `==` 严格相等（不前缀匹配，避免 `com.foo`
///    误带出 `com.foobar`）；appName 用 `==[c]`（case-insensitive 严格相等）
///    且要求长度 >= 4。
/// 3. **路径去重**：与已有 `seenPaths` 合并；新路径若不存在 / 0B / 无 entries 跳过。
/// 4. **Fail-soft**：Spotlight 不可用 / 超时 / 返空一律不报错，主路径结果原样返回。
///
/// 决策来源：[docs/AUDIT_2026_06.md L416-L417](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/AUDIT_2026_06.md#L416-L417)。

/// Spotlight 查询抽象层。生产实现走 NSMetadataQuery，测试实现走内存 fixture。
public protocol SpotlightProbing: Sendable {
    /// 按 bundleID 严格相等查路径。返回的路径**未必存在**或**未必属于该 app 残留**，
    /// 调用方负责后续过滤。
    /// - timeout: 查询超时（秒）。NSMetadataQuery 真实实现需要这个上限避免 UI 卡死；
    ///   fake 实现可忽略。
    func probeByBundleID(_ bundleID: String, timeout: TimeInterval) async -> [String]

    /// 按 appName 严格相等（忽略大小写）查路径。
    func probeByAppName(_ appName: String, timeout: TimeInterval) async -> [String]
}

/// 默认实现：NSMetadataQuery（全用户域 + 本地索引）。
///
/// 仅在 macOS sandbox=false 时能查到 user-domain 完整结果；sandbox=true 时
/// 受限于 entitlements。本 App 当前 sandbox=false（详见 GSYCleanMac.entitlements）。
public final class DefaultSpotlightProbe: SpotlightProbing, @unchecked Sendable {
    public init() {}

    public func probeByBundleID(_ bundleID: String, timeout: TimeInterval) async -> [String] {
        // 谓词：kMDItemCFBundleIdentifier == "<bundleID>"
        await runQuery(
            predicateFormat: "kMDItemCFBundleIdentifier == %@",
            argument: bundleID,
            timeout: timeout
        )
    }

    public func probeByAppName(_ appName: String, timeout: TimeInterval) async -> [String] {
        // 严格相等（忽略大小写）：kMDItemDisplayName ==[c] "<appName>"
        await runQuery(
            predicateFormat: "kMDItemDisplayName ==[c] %@",
            argument: appName,
            timeout: timeout
        )
    }

    private func runQuery(predicateFormat: String, argument: String, timeout: TimeInterval) async -> [String] {
        // NSMetadataQuery 必须在主线程启动并由 RunLoop 驱动；这里包装成 continuation。
        // 跨 actor 只传 String（Sendable），NSPredicate 在 main actor 内组装。
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            Task { @MainActor in
                let state = SpotlightQueryState()
                state.query.predicate = NSPredicate(format: predicateFormat, argument)
                state.query.searchScopes = [NSMetadataQueryUserHomeScope]

                state.observer = NotificationCenter.default.addObserver(
                    forName: .NSMetadataQueryDidFinishGathering,
                    object: state.query, queue: .main
                ) { [weak state] _ in
                    MainActor.assumeIsolated {
                        guard let state else { return }
                        var paths: [String] = []
                        for i in 0..<state.query.resultCount {
                            if let item = state.query.result(at: i) as? NSMetadataItem,
                               let p = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                                paths.append(p)
                            }
                        }
                        state.finish(with: paths, cont: cont)
                    }
                }

                let deadline = DispatchTime.now() + timeout
                DispatchQueue.main.asyncAfter(deadline: deadline) { [weak state] in
                    guard let state else { return }
                    state.finish(with: [], cont: cont)
                }

                if !state.query.start() {
                    state.finish(with: [], cont: cont)
                }
            }
        }
    }
}

/// NSMetadataQuery + observer + resumed 标志的 main-actor isolated holder。
/// 单一职责：把分散的 capture 收拢成一个对象引用，绕开 @Sendable 闭包对值类型的捕获限制。
@MainActor
private final class SpotlightQueryState {
    let query = NSMetadataQuery()
    var observer: NSObjectProtocol?
    var resumed = false

    func finish(with paths: [String], cont: CheckedContinuation<[String], Never>) {
        guard !resumed else { return }
        resumed = true
        query.stop()
        if let o = observer {
            NotificationCenter.default.removeObserver(o)
            observer = nil
        }
        cont.resume(returning: paths)
    }
}

/// Noop 实现：所有查询返空。给单元测试当默认 stub，避免触发系统 mds。
public struct NoopSpotlightProbe: SpotlightProbing {
    public init() {}
    public func probeByBundleID(_ bundleID: String, timeout: TimeInterval) async -> [String] { [] }
    public func probeByAppName(_ appName: String, timeout: TimeInterval) async -> [String] { [] }
}
