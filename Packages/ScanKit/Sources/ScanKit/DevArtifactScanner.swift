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
        /// v1.3 P0-D：命中硬上限。超过即截断 + didTimeout=true，给 UI banner 用。
        /// 200 是基于实测：30+ dev project 家目录平均 ~80 命中；200 足够覆盖重度开发者，
        /// 同时把"误命中 + 异常仓库（如 mirror clone）"导致的命中风暴卡在可控范围。
        public var maxHits: Int

        public init(enabledRuleIDs: Set<String> = DevArtifactRules.allIDs,
                    timeoutSeconds: TimeInterval = 60,
                    skipLibrary: Bool = true,
                    staySingleVolume: Bool = true,
                    maxHits: Int = 200) {
            self.enabledRuleIDs = enabledRuleIDs
            self.timeoutSeconds = timeoutSeconds
            self.skipLibrary = skipLibrary
            self.staySingleVolume = staySingleVolume
            self.maxHits = maxHits
        }

        public static let `default` = Options()
    }

    /// v1.3 P0-D：勘察结果带元数据。UI 用此结构判断是否需要展示"已截断 / 已超时"banner。
    public struct DiscoverResult: Sendable {
        public let hits: [Hit]
        /// true 表示命中数达 `Options.maxHits` 上限被截断 或 走 walk 时命中了 timeout。
        /// UI 应展示"开发者产物命中过多 / 勘察超时，仅展示前 N 项"提示。
        public let didTimeout: Bool
        /// 命中是否触达硬上限被截断（与 didTimeout 解耦，便于 UI 显示更精准文案）。
        public let didTruncate: Bool

        public init(hits: [Hit], didTimeout: Bool, didTruncate: Bool) {
            self.hits = hits
            self.didTimeout = didTimeout
            self.didTruncate = didTruncate
        }
    }

    private let options: Options
    public init(options: Options = .default) {
        self.options = options
    }

    /// 在 `home` 下勘察所有命中规则的目录。
    /// 返回一个 [Hit] 列表（可能为空）。命中后**整棵剪枝**——不再下钻该子树。
    /// 旧 API：丢失 timeout/truncate 元数据；新调用方应改用 `discoverWithMetadata`。
    public func discover(home: URL = URL(fileURLWithPath: NSHomeDirectory())) async -> [Hit] {
        await discoverWithMetadata(home: home).hits
    }

    /// v1.3 P0-D：带元数据的勘察入口。
    public func discoverWithMetadata(home: URL = URL(fileURLWithPath: NSHomeDirectory())) async -> DiscoverResult {
        let opts = options
        let homePath = home.standardizedFileURL.path
        GSYLog.info(.scan, "DevArtifact 勘察启动 home=\(homePath) rules=\(opts.enabledRuleIDs.count) timeout=\(opts.timeoutSeconds)s maxHits=\(opts.maxHits)")

        // 跨 actor 边界跑一个 detached：FileManager.enumerator 是同步阻塞的，不能占 actor。
        return await Task.detached(priority: .userInitiated) { () -> DiscoverResult in
            Self.runWalk(home: home, options: opts)
        }.value
    }

    /// 同步 walk 主体。放静态以便 detached 内部直调，避免 actor 隔离。
    private static func runWalk(home: URL, options: Options) -> DiscoverResult {
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
            return DiscoverResult(hits: [], didTimeout: false, didTruncate: false)
        }

        let rootDevice = (try? homeStd.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        guard let enumerator = fm.enumerator(
            at: homeStd,
            includingPropertiesForKeys: [.isDirectoryKey, .volumeIdentifierKey],
            options: [],
            errorHandler: { _, _ in true } // 任何 IO 错误吞掉，继续扫
        ) else {
            GSYLog.error(.scan, "DevArtifact 勘察 enumerator 构造失败 home=\(homeStd.path)")
            return DiscoverResult(hits: [], didTimeout: false, didTruncate: false)
        }

        var hits: [Hit] = []
        var iterations = 0
        var timedOut = false
        var truncated = false
        // v1.3 P0-D：父目录 siblings cache —— 之前每命中一次就 contentsOfDirectory(parent) 一次，
        // dev 家目录下命中数百次时这是 N×O(parent.count) 的 IO 风暴；改为按 parent.path 缓存。
        var siblingsCache: [String: Set<String>] = [:]
        // 上限保护：100 个 parent 已足够，更多说明扫到太深；超过即整体丢弃旧 entry。
        let siblingsCacheCap = 256
        while let item = enumerator.nextObject() as? URL {
            iterations += 1
            // v1.3 P0-D：响应取消（旧实现完全不检 Task.isCancelled，dev 扫描 cancel 不掉就是这里）。
            if Task.isCancelled {
                GSYLog.info(.scan, "DevArtifact 勘察响应取消 已扫描 \(iterations) 个 entry")
                break
            }
            // 每 256 个条目检查一次超时
            if iterations & 0xFF == 0, Date() >= deadline {
                timedOut = true
                break
            }
            // 命中达到硬上限：截断 + 标记 didTruncate
            if hits.count >= options.maxHits {
                truncated = true
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
            // v1.3 P0-D：父目录 siblings 进 cache，避免相邻命中重复 IO。
            let parent = stdURL.deletingLastPathComponent()
            let parentPath = parent.path
            let parentPathLower = parentPath.lowercased()
            let siblings: Set<String>
            if let cached = siblingsCache[parentPath] {
                siblings = cached
            } else {
                siblings = (try? fm.contentsOfDirectory(atPath: parentPath)).map { Set($0) } ?? []
                if siblingsCache.count >= siblingsCacheCap {
                    siblingsCache.removeAll(keepingCapacity: true)
                }
                siblingsCache[parentPath] = siblings
            }
            // 扩展名兜底所需的 siblings 小写视图（按需懒构造）
            var siblingsLowerExtCache: Set<String>? = nil

            for rule in candidates {
                let pass: Bool
                if rule.siblingMarkers.isEmpty
                    && rule.siblingExtensionMarkers.isEmpty
                    && rule.parentSuffixMarkers.isEmpty {
                    // 无任何 marker：保持旧语义"无条件通过"。
                    pass = true
                } else {
                    var matched = false
                    // 1. 精确文件名命中（与历史兼容路径，最常用）
                    if !rule.siblingMarkers.isEmpty,
                       rule.siblingMarkers.contains(where: { siblings.contains($0) }) {
                        matched = true
                    }
                    // 2. 兄弟扩展名命中（如 __pycache__ 同级有 *.py 即视为真 Python 项目）
                    if !matched, !rule.siblingExtensionMarkers.isEmpty {
                        if siblingsLowerExtCache == nil {
                            // 用扩展名集合反查（小写比较），避免 N×M 字符串扫描
                            var exts: Set<String> = []
                            for name in siblings {
                                // 用 NSString.pathExtension 获取最后一个 "." 后的部分（不含点）
                                let ext = (name as NSString).pathExtension.lowercased()
                                if !ext.isEmpty { exts.insert("." + ext) }
                            }
                            siblingsLowerExtCache = exts
                        }
                        if rule.siblingExtensionMarkers.contains(where: { siblingsLowerExtCache!.contains($0) }) {
                            matched = true
                        }
                    }
                    // 3. 父目录路径后缀命中（如 xcuserdata 必然在 .xcodeproj/.xcworkspace 内）
                    if !matched, !rule.parentSuffixMarkers.isEmpty,
                       rule.parentSuffixMarkers.contains(where: { parentPathLower.hasSuffix($0) }) {
                        matched = true
                    }
                    pass = matched
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
                // v1.3 P0-D：原 GSYLog.debug release 下看不到，命中风暴时丢失关键诊断信息。
                // 改 info：保留路径但不刷屏（release 默认开 info）。命中数本就有 200 上限。
                GSYLog.info(.scan, "DevArtifact 命中 rule=\(rule.id) path=\(stdPath)")
                // 命中即整棵剪枝（一棵子树只属于一条规则；多规则同名时第一条命中后退出）
                enumerator.skipDescendants()
                break
            }
        }

        if timedOut {
            GSYLog.warning(.scan, "DevArtifact 勘察超时 已扫描 \(iterations) 个 entry，命中 \(hits.count) 项")
        } else if truncated {
            GSYLog.warning(.scan, "DevArtifact 勘察命中达上限 \(options.maxHits) entries=\(iterations) → 截断")
        } else {
            GSYLog.info(.scan, "DevArtifact 勘察完成 entries=\(iterations) hits=\(hits.count)")
        }
        return DiscoverResult(hits: hits, didTimeout: timedOut, didTruncate: truncated)
    }

    private static func areVolumeIdentifiersEqual(_ a: Any, _ b: Any) -> Bool {
        guard let aObj = a as AnyObject as? NSObject,
              let bObj = b as AnyObject as? NSObject else { return false }
        return aObj.isEqual(bObj)
    }
}
