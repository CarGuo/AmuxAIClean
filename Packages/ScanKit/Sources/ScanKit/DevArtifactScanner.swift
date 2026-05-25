import Foundation
import LogKit

/// 开发者构建产物 / 依赖目录的「勘察器」。
///
/// 与 [BulkScanner] 的关系：
/// - BulkScanner 是「**给定根，全量扫**」，性能最高但不做内容判别；
/// - DevArtifactScanner 是「**给定根，找出符合规则的子目录列表**」——只做枚举 + 命中
///   过滤，不计字节、不发事件。命中点拿到后，调用方再决定怎么处理（最常见做法：把
///   命中点当成多根丢给 [MultiRootScanner] 做正式扫描，复用现有 UI 全套）。
///
/// 性能策略：
/// 1. **一遍 enumerator**：FileManager.enumerator(at:) 走全树，命中规则就 skipDescendants
///    剪枝，避免重复进入 `node_modules/.bin/...`、`build/intermediates/...`；
/// 2. **跨卷停**：碰到不同 volumeIdentifier 的子目录直接跳过，避免外接盘 / 网络盘吃爆；
/// 3. **跳过 ~/Library 高敏区**：~/Library 内部叫 `Caches`、`Logs`、`build` 的目录大量
///    存在，这些**不是开发者产物**而是系统/App 缓存，下钻还会触发 TCC 弹窗；
/// 4. **超时硬上限**：默认 60s，到点直接返回当前累计——不让用户在 IDE 工作目录里
///    卡很久；
/// 5. **关键链路有 GSYLog 埋点**：开始 / 命中 / 完成 summary / 超时；用户拿日志即可还原。
///
/// 安全：
/// - 命中点要求**目录**，文件忽略；
/// - 「兄弟脚手架兜底」开关在规则里——siblingMarkers 非空时必须兄弟里至少有一个。
public actor DevArtifactScanner {

    /// 一条命中。
    public struct Hit: Sendable, Hashable, Identifiable {
        public let url: URL
        public let ruleID: String
        public let displayName: String
        public let ecosystem: DevArtifactRule.Ecosystem
        public let verdict: DevArtifactRule.Verdict
        public let subtitle: String

        public var id: String { "\(ruleID)|\(url.path)" }

        public init(url: URL,
                    ruleID: String,
                    displayName: String,
                    ecosystem: DevArtifactRule.Ecosystem,
                    verdict: DevArtifactRule.Verdict,
                    subtitle: String) {
            self.url = url
            self.ruleID = ruleID
            self.displayName = displayName
            self.ecosystem = ecosystem
            self.verdict = verdict
            self.subtitle = subtitle
        }
    }

    /// 勘察配置。
    public struct Options: Sendable {
        public var enabledRuleIDs: Set<String>
        public var timeoutSeconds: TimeInterval
        public var skipLibrary: Bool
        public var staySingleVolume: Bool

        public init(enabledRuleIDs: Set<String> = DevArtifactRules.allIDs,
                    timeoutSeconds: TimeInterval = 60,
                    skipLibrary: Bool = true,
                    staySingleVolume: Bool = true) {
            self.enabledRuleIDs = enabledRuleIDs
            self.timeoutSeconds = timeoutSeconds
            self.skipLibrary = skipLibrary
            self.staySingleVolume = staySingleVolume
        }

        public static let `default` = Options()
    }

    private let options: Options
    public init(options: Options = .default) {
        self.options = options
    }

    /// 在 `home` 下勘察所有命中规则的目录。
    /// 返回一个 [Hit] 列表（可能为空）。命中后**整棵剪枝**——不再下钻该子树。
    public func discover(home: URL = URL(fileURLWithPath: NSHomeDirectory())) async -> [Hit] {
        let opts = options
        let homePath = home.standardizedFileURL.path
        GSYLog.info(.scan, "DevArtifact 勘察启动 home=\(homePath) rules=\(opts.enabledRuleIDs.count) timeout=\(opts.timeoutSeconds)s")

        // 跨 actor 边界跑一个 detached：FileManager.enumerator 是同步阻塞的，不能占 actor。
        return await Task.detached(priority: .userInitiated) { () -> [Hit] in
            Self.runWalk(home: home, options: opts)
        }.value
    }

    /// 同步 walk 主体。放静态以便 detached 内部直调，避免 actor 隔离。
    private static func runWalk(home: URL, options: Options) -> [Hit] {
        let deadline = Date().addingTimeInterval(options.timeoutSeconds)
        let fm = FileManager.default
        let homeStd = home.standardizedFileURL
        let libraryPath = homeStd.appendingPathComponent("Library").standardizedFileURL.path

        // 索引：directoryName.lowercased() -> [Rule]，扫描时 O(1) 查
        let activeRules = DevArtifactRules.all.filter { options.enabledRuleIDs.contains($0.id) }
        var index: [String: [DevArtifactRule]] = [:]
        for rule in activeRules {
            index[rule.directoryName, default: []].append(rule)
        }
        guard !index.isEmpty else {
            GSYLog.warning(.scan, "DevArtifact 勘察 0 规则启用 直接返回")
            return []
        }

        let rootDevice = (try? homeStd.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        guard let enumerator = fm.enumerator(
            at: homeStd,
            includingPropertiesForKeys: [.isDirectoryKey, .volumeIdentifierKey],
            options: [],
            errorHandler: { _, _ in true } // 任何 IO 错误吞掉，继续扫
        ) else {
            GSYLog.error(.scan, "DevArtifact 勘察 enumerator 构造失败 home=\(homeStd.path)")
            return []
        }

        var hits: [Hit] = []
        var iterations = 0
        var timedOut = false
        while let item = enumerator.nextObject() as? URL {
            iterations += 1
            // 每 256 个条目检查一次超时
            if iterations & 0xFF == 0, Date() >= deadline {
                timedOut = true
                break
            }

            // 仅处理目录
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .volumeIdentifierKey])
            guard values?.isDirectory == true else { continue }

            // 跨卷停：碰到挂载点（外接盘 / 网络盘）直接整棵剪枝
            if options.staySingleVolume,
               let dev = values?.volumeIdentifier, let rdev = rootDevice,
               !areVolumeIdentifiersEqual(dev, rdev) {
                enumerator.skipDescendants()
                continue
            }

            let stdURL = item.standardizedFileURL
            let stdPath = stdURL.path

            // 跳过 ~/Library（系统/App 的缓存堆，不是开发者产物，进去还可能触发 TCC）
            if options.skipLibrary,
               stdPath == libraryPath || stdPath.hasPrefix(libraryPath + "/") {
                enumerator.skipDescendants()
                continue
            }

            // 命中匹配（目录名小写比较）
            let dirName = stdURL.lastPathComponent.lowercased()
            guard let candidates = index[dirName] else { continue }

            // 兄弟兜底：拿到父目录的子项列表（一次 contentsOfDirectory），用集合查 marker
            let parent = stdURL.deletingLastPathComponent()
            let siblings: Set<String> = (try? fm.contentsOfDirectory(atPath: parent.path))
                .map { Set($0) } ?? []

            for rule in candidates {
                let pass: Bool
                if rule.siblingMarkers.isEmpty {
                    pass = true
                } else {
                    pass = rule.siblingMarkers.contains { siblings.contains($0) }
                }
                guard pass else { continue }
                hits.append(Hit(
                    url: stdURL,
                    ruleID: rule.id,
                    displayName: rule.displayName,
                    ecosystem: rule.ecosystem,
                    verdict: rule.verdict,
                    subtitle: rule.subtitle
                ))
                GSYLog.debug(.scan, "DevArtifact 命中 rule=\(rule.id) path=\(stdPath)")
                // 命中即整棵剪枝（一棵子树只属于一条规则；多规则同名时第一条命中后退出）
                enumerator.skipDescendants()
                break
            }
        }

        if timedOut {
            GSYLog.warning(.scan, "DevArtifact 勘察超时 已扫描 \(iterations) 个 entry，命中 \(hits.count) 项")
        } else {
            GSYLog.info(.scan, "DevArtifact 勘察完成 entries=\(iterations) hits=\(hits.count)")
        }
        return hits
    }

    private static func areVolumeIdentifiersEqual(_ a: Any, _ b: Any) -> Bool {
        guard let aObj = a as AnyObject as? NSObject,
              let bObj = b as AnyObject as? NSObject else { return false }
        return aObj.isEqual(bObj)
    }
}
