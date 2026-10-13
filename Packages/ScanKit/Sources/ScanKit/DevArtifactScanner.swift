import Foundation
import Darwin
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
/// 1. **descriptor 批量枚举**：每个父目录只用 `getattrlistbulk(2)` 枚举一次；同一批
///    entry 同时承担 sibling marker 匹配和子目录入队，命中后整棵剪枝；
/// 2. **跨卷停**：碰到不同 volumeIdentifier 的子目录直接跳过，避免外接盘 / 网络盘吃爆；
/// 3. **跳过 ~/Library 高敏区**：~/Library 内部叫 `Caches`、`Logs`、`build` 的目录大量
///    存在，这些**不是开发者产物**而是系统/App 缓存，下钻还会触发 TCC 弹窗；
/// 4. **显式预算而非默认截断**：生产默认不按任意秒数截断；调用方只有在能把 partial
///    终态原样呈现时才可显式配置预算，用户取消则通过统一 cancellation relay 停止遍历；
/// 5. **关键链路有 AmuxLog 埋点**：开始 / 命中 / 完成 summary / 超时；用户拿日志即可还原。
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
        /// 勘察超时。`nil` 表示不做任意截断，由调用方取消任务来停止扫描。
        ///
        /// 开发者目录规模无法用固定秒数推断完整性；默认 60 秒会把大型 home 的
        /// partial 结果伪装成完整结果。需要预算的诊断/测试调用方仍可显式传值。
        public var timeoutSeconds: TimeInterval?
        public var skipLibrary: Bool
        public var staySingleVolume: Bool
        /// v2026.06.21：命中硬上限。
        ///
        /// 历史上 200/500/2000 都试过——任何"小数字 + 截断 banner"路线都会让用户在
        /// 大开发机看到「结果已截断」，体验上等价于"扫描失败"。
        /// 新策略：**默认 = Int.max（实际永远不截断）**。命中风暴属于业务异常，
        /// 应该用真实数据治理（添加更严格的 marker 检查 / 调用方传更小的 enabledRuleIDs），
        /// 而不是让用户在 UI 看到内部限流状态。
        public var maxHits: Int
        /// v2026.07.17：发现阶段与 BulkScanner 共用介质探测和并发预算。
        ///
        /// DevArtifactScanner 只消费其中的 concurrency/maxConcurrency/mediaAware 与
        /// respectTCCSkipList；是否跨卷仍由上面的兼容字段 `staySingleVolume` 决定，
        /// 避免旧调用方在迁移期间出现两个来源互相覆盖。
        public var scanOptions: ScanOptions

        public init(enabledRuleIDs: Set<String> = DevArtifactRules.allIDs,
                    timeoutSeconds: TimeInterval? = nil,
                    skipLibrary: Bool = true,
                    staySingleVolume: Bool = true,
                    maxHits: Int = .max,
                    scanOptions: ScanOptions = .default) {
            self.enabledRuleIDs = enabledRuleIDs
            self.timeoutSeconds = timeoutSeconds
            self.skipLibrary = skipLibrary
            self.staySingleVolume = staySingleVolume
            self.maxHits = maxHits
            self.scanOptions = scanOptions
        }

        public static let `default` = Options()
    }

    /// v1.3 P0-D：勘察结果带元数据。UI 用此结构判断是否需要展示"已截断 / 已超时"banner。
    public struct DiscoverResult: Sendable {
        public let hits: [Hit]
        /// true 只表示 walk 命中了 timeout；命中上限由 `didTruncate` 单独表达。
        public let didTimeout: Bool
        /// 命中是否触达硬上限被截断（与 didTimeout 解耦，便于 UI 显示更精准文案）。
        public let didTruncate: Bool
        /// 发现阶段没有完整覆盖的路径。目录枚举、节点 metadata 和 marker 读取错误都必须
        /// 保留下来，调用方不能把“发生 I/O 错误后的空结果”解释为完整扫描。
        public let incompleteIssues: [ScanIncompleteIssue]
        /// descriptor 枚举实际交付给发现器的 entry 数；不含根目录自身，也不把未进入的
        /// 剪枝子树估算进去。该值可用于真实链路性能回归，而不是拿命中数冒充工作量。
        public let scannedEntryCount: Int
        /// 发现阶段端到端耗时（含根身份冻结、介质探测、并发枚举和最终归并）。
        public let elapsed: TimeInterval

        public var isComplete: Bool {
            !didTimeout && !didTruncate && incompleteIssues.isEmpty
        }

        public init(
            hits: [Hit],
            didTimeout: Bool,
            didTruncate: Bool,
            incompleteIssues: [ScanIncompleteIssue] = [],
            scannedEntryCount: Int = 0,
            elapsed: TimeInterval = 0
        ) {
            self.hits = hits
            self.didTimeout = didTimeout
            self.didTruncate = didTruncate
            self.incompleteIssues = incompleteIssues
            self.scannedEntryCount = scannedEntryCount
            self.elapsed = elapsed
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
        let timeoutDescription = opts.timeoutSeconds.map { "\($0)s" } ?? "disabled"
        AmuxLog.info(.scan, "DevArtifact 勘察启动 home=\(homePath) rules=\(opts.enabledRuleIDs.count) timeout=\(timeoutDescription) maxHits=\(opts.maxHits)")

        // 跨 actor 边界跑一个 detached：descriptor syscall 是同步阻塞的，不能占 actor。
        return await Self.runCancellableDetached { () -> DiscoverResult in
            await Self.runWalk(home: home, options: opts, onPartial: nil)
        }
    }

    /// v2026.06.21：带"边走边喂"回调的勘察入口。
    ///
    /// **解决用户反馈**：「为什么不是一批一批显示出来？」
    /// 旧 [discoverWithMetadata](#) 是 all-or-nothing —— 必须等整棵 walk 跑完才返回。
    /// 在大型 home 上即使没有配置超时，期间 UI 也完全没反馈，让用户感觉"卡死"。
    ///
    /// 新 API 让调用方传 `onPartial`：每命中 `flushEvery` 条 hit 就回一次（拷贝一份当前 hits 数组）。
    /// 调用方可以拿这些 partial hits 立刻预填 sidebar 进度行，UI 视觉上始终在长。
    /// 注意：`onPartial` 在 detached task 里被调用（IO 线程），调用方需要自己跳回主 actor。
    ///
    /// - Parameters:
    ///   - home: 勘察根；默认 ~
    ///   - flushEvery: 每命中多少个 hit 回调一次；默认 20。设小了回调过频，设大了用户感知慢。
    ///   - onPartial: 增量回调；参数是"自上次回调以来新增的 hits"（保序）。可能为 nil。
    public func discoverWithMetadataStreamed(
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        flushEvery: Int = 20,
        onPartial: (@Sendable ([Hit]) -> Void)? = nil
    ) async -> DiscoverResult {
        let opts = options
        let homePath = home.standardizedFileURL.path
        let timeoutDescription = opts.timeoutSeconds.map { "\($0)s" } ?? "disabled"
        AmuxLog.info(.scan, "DevArtifact 勘察(stream) home=\(homePath) rules=\(opts.enabledRuleIDs.count) timeout=\(timeoutDescription) maxHits=\(opts.maxHits) flushEvery=\(flushEvery)")

        return await Self.runCancellableDetached { () -> DiscoverResult in
            await Self.runWalk(
                home: home,
                options: opts,
                onPartial: onPartial.map {
                    PartialDelivery(every: max(1, flushEvery), callback: $0)
                }
            )
        }
    }

    /// detached 同步遍历必须显式继承调用方的取消。
    ///
    /// `await worker.value` 本身不会在父任务取消时自动取消 unstructured task；统一在
    /// 这里建立 ownership relay，避免每个入口各自遗漏。标为 internal 便于用一个
    /// 阻塞型 fake worker 精确测试取消传播，不需要在真实文件系统里制造超大目录。
    static func runCancellableDetached<Result: Sendable>(
        _ operation: @escaping @Sendable () async -> Result
    ) async -> Result {
        let worker = Task.detached(priority: .userInitiated) {
            await operation()
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// v2026.07.17 根因修复：旧实现用 `FileManager.enumerator` 后又对每个 URL 单独
    /// `resourceValues`，三百万 entry 的 home 会产生三百万次 Foundation metadata
    /// 往返；命中候选还会再次列举父目录。这里改成与 BulkScanner 相同的 descriptor
    /// identity fence + `getattrlistbulk`，同一父目录的一批 entry 同时完成 marker 匹配
    /// 和下钻决策，不再为每个 entry 构造 URL 或追加 syscall。
    private static func runWalk(
        home: URL,
        options: Options,
        onPartial: PartialDelivery?
    ) async -> DiscoverResult {
        let startedAt = Date()
        let homePath = home.standardizedFileURL.path
        let libraryPath = BulkScanner.entryPath(directoryPath: homePath, name: "Library")
        let deadline = options.timeoutSeconds.map { ScanDeadline.make(timeout: $0) }
        let stopState = DevArtifactStopState(deadline: deadline)
        let accumulator = DevArtifactAccumulator(partialDelivery: onPartial)

        let activeRules = DevArtifactRules.all.filter {
            options.enabledRuleIDs.contains($0.id)
        }
        // Freeze the lookup before spawning Swift 6 @Sendable task-group children. Capturing a
        // locally-mutated `var` here is both unnecessary and rejected as a concurrently-executing
        // capture even though construction has logically finished.
        let ruleIndex = Dictionary(grouping: activeRules) { $0.directoryName }
        let markerRequirements = DevArtifactMarkerRequirements(rules: activeRules)
        guard !ruleIndex.isEmpty else {
            AmuxLog.warning(.scan, "DevArtifact 勘察 0 规则启用 直接返回")
            return DiscoverResult(
                hits: [],
                didTimeout: false,
                didTruncate: false,
                scannedEntryCount: 0,
                elapsed: Date().timeIntervalSince(startedAt)
            )
        }
        // Public timeout normalization applies before any filesystem I/O. A zero/negative/NaN
        // budget is an immediate typed timeout, not permission/metadata evidence from a root
        // lstat that should never have started.
        if stopState.shouldStop() {
            return await accumulator.finish(
                stopOutcome: stopState.outcome,
                elapsed: Date().timeIntervalSince(startedAt)
            )
        }

        let rootWork: BulkDirectoryWork
        switch BulkDirectoryWorkResolver.resolveRoot(
            path: homePath,
            followSymlinks: false,
            shouldCancel: { Task.isCancelled }
        ) {
        case .resolved(let work):
            rootWork = work
        case .cancelled:
            return DiscoverResult(
                hits: [],
                didTimeout: false,
                didTruncate: false,
                elapsed: Date().timeIntervalSince(startedAt)
            )
        case .notDirectory:
            await accumulator.addIssue(ScanFailureClassifier.issue(
                path: homePath,
                stage: .open,
                posixErrorCode: ENOTDIR
            ))
            return await accumulator.finish(
                stopOutcome: stopState.outcome,
                elapsed: Date().timeIntervalSince(startedAt)
            )
        case .failed(let errorCode):
            await accumulator.addIssue(ScanFailureClassifier.issue(
                path: homePath,
                stage: .open,
                posixErrorCode: errorCode
            ))
            return await accumulator.finish(
                stopOutcome: stopState.outcome,
                elapsed: Date().timeIntervalSince(startedAt)
            )
        }

        let queue = DirQueue()
        let directoryIdentities = DirInodeSet()
        _ = directoryIdentities.insertIfFirstSeen(
            device: rootWork.identity.device,
            inode: rootWork.identity.inode
        )
        await queue.push(rootWork)

        let scanOptions = options.scanOptions
        let workerCount: Int
        if scanOptions.mediaAware {
            let media = MediaProbe.probe(path: homePath)
            workerCount = MediaProbe.recommendedWorkerCount(
                for: media,
                fallback: scanOptions.actualConcurrency,
                maxCap: scanOptions.maxConcurrency
            )
        } else {
            workerCount = scanOptions.actualConcurrency
        }
        AmuxLog.info(
            .scan,
            "DevArtifact descriptor walk root=\(homePath) workers=\(workerCount) staySingleVolume=\(options.staySingleVolume)"
        )

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    await Self.workerLoop(
                        queue: queue,
                        accumulator: accumulator,
                        stopState: stopState,
                        directoryIdentities: directoryIdentities,
                        ruleIndex: ruleIndex,
                        markerRequirements: markerRequirements,
                        options: options,
                        rootDevice: rootWork.identity.device,
                        libraryPath: libraryPath
                    )
                }
            }
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        let result = await accumulator.finish(
            stopOutcome: stopState.outcome,
            elapsed: elapsed
        )
        if Task.isCancelled {
            AmuxLog.info(.scan, "DevArtifact 勘察响应取消 entries=\(result.scannedEntryCount) hits=\(result.hits.count)")
        } else if result.didTimeout {
            AmuxLog.warning(.scan, "DevArtifact 勘察超时 entries=\(result.scannedEntryCount) hits=\(result.hits.count) elapsed=\(String(format: "%.3f", elapsed))s")
        } else if result.didTruncate {
            AmuxLog.warning(.scan, "DevArtifact 勘察命中达上限 \(options.maxHits) entries=\(result.scannedEntryCount) elapsed=\(String(format: "%.3f", elapsed))s")
        } else {
            AmuxLog.info(.scan, "DevArtifact 勘察完成 entries=\(result.scannedEntryCount) hits=\(result.hits.count) incomplete=\(result.incompleteIssues.count) elapsed=\(String(format: "%.3f", elapsed))s")
        }
        return result
    }

    /// 多 worker 共享一个 `DirQueue`；每份 work 都携带父枚举时冻结的 dev/inode，
    /// `BulkDirectoryOpener` 会在真正枚举前对 descriptor 做 fstat 重验。
    private static func workerLoop(
        queue: DirQueue,
        accumulator: DevArtifactAccumulator,
        stopState: DevArtifactStopState,
        directoryIdentities: DirInodeSet,
        ruleIndex: [String: [DevArtifactRule]],
        markerRequirements: DevArtifactMarkerRequirements,
        options: Options,
        rootDevice: UInt64,
        libraryPath: String
    ) async {
        while !Task.isCancelled, !stopState.shouldStop() {
            switch await queue.popOrFinish() {
            case .done, .cancelled:
                return
            case .work(let work):
                await processDirectory(
                    work: work,
                    queue: queue,
                    accumulator: accumulator,
                    stopState: stopState,
                    directoryIdentities: directoryIdentities,
                    ruleIndex: ruleIndex,
                    markerRequirements: markerRequirements,
                    options: options,
                    rootDevice: rootDevice,
                    libraryPath: libraryPath
                )
                await queue.markCompleted()
            }
        }
    }

    private static func processDirectory(
        work: BulkDirectoryWork,
        queue: DirQueue,
        accumulator: DevArtifactAccumulator,
        stopState: DevArtifactStopState,
        directoryIdentities: DirInodeSet,
        ruleIndex: [String: [DevArtifactRule]],
        markerRequirements: DevArtifactMarkerRequirements,
        options: Options,
        rootDevice: UInt64,
        libraryPath: String
    ) async {
        // v2026.07.17 final static-review correction: the batched stop poll below is only for
        // the per-entry hot loop. A worker may already have popped this directory when another
        // worker proves timeout/truncation; recheck the shared state once, unbatched, before
        // issuing any new open so terminal state cannot start another potentially blocking I/O.
        guard shouldBeginDirectoryIO(stopState: stopState) else { return }
        var stopPollClock = 0
        let shouldStop: () -> Bool = {
            if Task.isCancelled { return true }
            stopPollClock &+= 1
            // v2026.07.17 performance boundary: cancellation stays per-entry, while the locked
            // cross-worker truncate/deadline state is sampled in batches instead of serializing
            // every entry behind one NSLock.
            guard stopPollClock & 0xFF == 0 else { return false }
            return stopState.shouldStop()
        }

        let fd: Int32
        switch BulkDirectoryOpener.open(work: work, shouldCancel: shouldStop) {
        case .opened(let openedFD):
            fd = openedFD
        case .cancelled:
            return
        case .failed(let errorCode):
            await accumulator.addIssue(ScanFailureClassifier.issue(
                path: work.path,
                stage: .open,
                posixErrorCode: errorCode
            ))
            return
        case .identityChanged(let errorCode):
            await accumulator.addIssue(ScanFailureClassifier.issue(
                path: work.path,
                stage: .metadata,
                posixErrorCode: errorCode ?? ESTALE
            ))
            return
        }
        defer { Darwin.close(fd) }

        // v2026.07.17 root cause closure: a very wide directory may contain millions of regular
        // files. Retaining every BulkEntry before marker evaluation would trade the old syscall
        // regression for unbounded memory. Keep only child-directory metadata; exact/extension
        // marker observations are bounded by the active rule vocabulary, while every delivered
        // entry still contributes to the authoritative scanned counter.
        var scannedEntries = 0
        var directoryEntries: [BulkEntry] = []
        var observedExactMarkers: Set<String> = []
        var observedExtensionMarkers: Set<String> = []
        let enumerationOutcome = BulkEnumerate.enumerate(
            fd: fd,
            dirPath: work.path,
            shouldCancel: shouldStop,
            fallbackPolicy: .boundedMemory
        ) { entry in
            scannedEntries += 1
            if entry.isDirectory {
                directoryEntries.append(entry)
            }
            markerRequirements.observe(
                name: entry.name,
                exact: &observedExactMarkers,
                extensions: &observedExtensionMarkers
            )
            return true
        }
        await accumulator.addScannedEntries(scannedEntries)

        switch enumerationOutcome {
        case .complete:
            break
        case .completeWithIssues(let issues):
            await accumulator.addIssues(issues)
        case .failed(let issue):
            await accumulator.addIssue(issue)
            return
        case .stoppedByConsumer:
            return
        }
        guard !Task.isCancelled, !stopState.shouldStop() else { return }

        let parentPathLower = work.path.lowercased()
        var childWork: [BulkDirectoryWork] = []
        childWork.reserveCapacity(min(directoryEntries.count, 64))

        for (offset, entry) in directoryEntries.enumerated() {
            if offset & 0xFF == 0,
               (Task.isCancelled || stopState.shouldStop()) {
                return
            }
            guard entry.isDirectory else { continue }
            let path = BulkScanner.entryPath(directoryPath: work.path, name: entry.name)

            if options.staySingleVolume,
               rootDevice != 0,
               entry.device != rootDevice {
                continue
            }
            if options.skipLibrary,
               (path == libraryPath || path.hasPrefix(libraryPath + "/")) {
                continue
            }
            // v2026.07.17 prompt regression guard: media-library packages are pruned before
            // descriptor open. Reusing the shared list keeps classification aligned with
            // BulkScanner while the comment below documents why this discovery scope stays complete.
            if options.scanOptions.respectTCCSkipList,
               TCCSkipList.shouldSkip(path) {
                // Like the explicit ~/Library exclusion above, media-library packages are
                // outside developer-artifact discovery's business scope. This is a proved
                // classification prune, not an I/O hole, so it must not make the whole developer
                // result partial. Full-capacity scanners retain their own typed TCC evidence.
                continue
            }

            let candidates = ruleIndex[entry.name.lowercased()] ?? []
            if let rule = matchingRule(
                in: candidates,
                observedExactMarkers: observedExactMarkers,
                observedExtensionMarkers: observedExtensionMarkers,
                parentPathLower: parentPathLower
            ) {
                let hit = Hit(
                    url: URL(fileURLWithPath: path, isDirectory: true),
                    ruleID: rule.id,
                    displayName: rule.displayName,
                    ecosystem: rule.ecosystem,
                    verdict: rule.verdict,
                    subtitle: rule.subtitle
                )
                let accepted = await accumulator.accept(
                    hit: hit,
                    maxHits: options.maxHits,
                    stopState: stopState
                )
                if accepted {
                    AmuxLog.info(.scan, "DevArtifact 命中 rule=\(rule.id) path=\(path)")
                }
                guard accepted, !stopState.shouldStop() else { return }
                continue
            }

            switch BulkDirectoryWorkResolver.resolveDescendant(
                path: path,
                entry: entry,
                followSymlinks: false,
                shouldCancel: { Task.isCancelled || stopState.shouldStop() }
            ) {
            case .resolved(let child):
                if directoryIdentities.insertIfFirstSeen(
                    device: child.identity.device,
                    inode: child.identity.inode
                ) {
                    childWork.append(child)
                }
            case .notDirectory, .cancelled:
                break
            case .failed(let errorCode):
                await accumulator.addIssue(ScanFailureClassifier.issue(
                    path: path,
                    stage: .metadata,
                    posixErrorCode: errorCode
                ))
            }
        }

        guard !Task.isCancelled, !stopState.shouldStop() else { return }
        await queue.pushMany(childWork)
    }

    static func shouldBeginDirectoryIO(stopState: DevArtifactStopState) -> Bool {
        !Task.isCancelled && !stopState.shouldStop()
    }

    private static func matchingRule(
        in candidates: [DevArtifactRule],
        observedExactMarkers: Set<String>,
        observedExtensionMarkers: Set<String>,
        parentPathLower: String
    ) -> DevArtifactRule? {
        for rule in candidates {
            if rule.siblingMarkers.isEmpty,
               rule.siblingExtensionMarkers.isEmpty,
               rule.parentSuffixMarkers.isEmpty {
                return rule
            }
            if rule.siblingMarkers.contains(where: observedExactMarkers.contains) {
                return rule
            }
            if rule.siblingExtensionMarkers.contains(where: observedExtensionMarkers.contains) {
                return rule
            }
            if rule.parentSuffixMarkers.contains(where: parentPathLower.hasSuffix) {
                return rule
            }
        }
        return nil
    }

    /// Foundation 与 POSIX 的权限错误统一映射到删除链路认识的结构化原因；其它 I/O
    /// 错误由调用位置决定是枚举失败还是 metadata 缺失。
    nonisolated static func incompleteReason(
        for error: Error,
        fallback: ScanIncompleteReason
    ) -> ScanIncompleteReason {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileReadNoPermission.rawValue {
            return .permissionDenied
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
            return .permissionDenied
        }
        return fallback
    }

}

/// 流式 API 的不可变交付合同；真正的 buffer 由 `DevArtifactAccumulator` actor 独占。
private struct PartialDelivery: Sendable {
    let every: Int
    let callback: @Sendable ([DevArtifactScanner.Hit]) -> Void

    init(every: Int, callback: @escaping @Sendable ([DevArtifactScanner.Hit]) -> Void) {
        self.every = every
        self.callback = callback
    }
}

/// Active rules compressed into bounded marker vocabularies. A parent with ten million ordinary
/// files therefore stores at most O(active marker count) strings rather than O(parent entries).
private struct DevArtifactMarkerRequirements: Sendable {
    let exactNames: Set<String>
    let extensions: Set<String>

    init(rules: [DevArtifactRule]) {
        exactNames = Set(rules.flatMap(\.siblingMarkers))
        extensions = Set(rules.flatMap(\.siblingExtensionMarkers))
    }

    func observe(
        name: String,
        exact observedExact: inout Set<String>,
        extensions observedExtensions: inout Set<String>
    ) {
        if exactNames.contains(name) {
            observedExact.insert(name)
        }
        guard !extensions.isEmpty,
              let dot = name.lastIndex(of: "."),
              dot != name.startIndex else {
            return
        }
        let afterDot = name.index(after: dot)
        guard afterDot != name.endIndex else { return }
        let normalized = "." + name[afterDot...].lowercased()
        if extensions.contains(normalized) {
            observedExtensions.insert(normalized)
        }
    }
}

/// v2026.07.17：deadline/truncation 会被多个 descriptor worker 同步观察。锁只在目录
/// 边界和每 256 个 entry 采样，不进入逐 entry 热路径。
final class DevArtifactStopState: @unchecked Sendable {
    struct Outcome: Sendable {
        let didTimeout: Bool
        let didTruncate: Bool
    }

    private let lock = NSLock()
    private let deadline: Date?
    private var timedOut = false
    private var truncated = false

    init(deadline: Date?) {
        self.deadline = deadline
    }

    func shouldStop(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if truncated || timedOut { return true }
        if let deadline, now >= deadline {
            timedOut = true
            return true
        }
        return false
    }

    func markTruncated() {
        lock.lock()
        truncated = true
        lock.unlock()
    }

    var outcome: Outcome {
        lock.lock()
        defer { lock.unlock() }
        return Outcome(didTimeout: timedOut, didTruncate: truncated)
    }
}

/// 命中、完整性证据、计数与 partial buffer 的唯一并发所有者。
///
/// v2026.07.17 根因注释：旧 `PartialFlush` 依赖单线程 enumerator；descriptor worker
/// 并发后若继续直接调用会数据竞争并让 UI 收到重叠批次。actor 在同一临界区内完成
/// maxHits 认领、append 和 flush，保证所有回调串行且每条 hit 恰好交付一次。
private actor DevArtifactAccumulator {
    private var hits: [DevArtifactScanner.Hit] = []
    private var issues: Set<ScanIncompleteIssue> = []
    private var scannedEntryCount = 0
    private let partialDelivery: PartialDelivery?
    private var partialBuffer: [DevArtifactScanner.Hit] = []

    init(partialDelivery: PartialDelivery?) {
        self.partialDelivery = partialDelivery
        if let partialDelivery {
            partialBuffer.reserveCapacity(partialDelivery.every)
        }
    }

    func addScannedEntries(_ count: Int) {
        scannedEntryCount += count
    }

    func addIssue(_ issue: ScanIncompleteIssue) {
        issues.insert(issue)
    }

    func addIssues(_ newIssues: [ScanIncompleteIssue]) {
        issues.formUnion(newIssues)
    }

    func accept(
        hit: DevArtifactScanner.Hit,
        maxHits: Int,
        stopState: DevArtifactStopState
    ) -> Bool {
        guard maxHits > 0, hits.count < maxHits else {
            stopState.markTruncated()
            return false
        }
        hits.append(hit)
        if let partialDelivery {
            partialBuffer.append(hit)
            if partialBuffer.count >= partialDelivery.every {
                flushPartial(using: partialDelivery)
            }
        }
        // v2026.07.17 exact-cap semantics: reaching N is not proof that item N+1 exists. Keep
        // discovering until an additional matching hit is observed; only that rejected hit
        // proves truncation and may turn the result partial. Int.max therefore never self-marks.
        return true
    }

    func finish(
        stopOutcome: DevArtifactStopState.Outcome,
        elapsed: TimeInterval
    ) -> DevArtifactScanner.DiscoverResult {
        if let partialDelivery {
            flushPartial(using: partialDelivery)
        }
        let sortedIssues = issues.sorted {
            if $0.path != $1.path { return $0.path < $1.path }
            if $0.reason.rawValue != $1.reason.rawValue {
                return $0.reason.rawValue < $1.reason.rawValue
            }
            return ($0.stage?.rawValue ?? "") < ($1.stage?.rawValue ?? "")
        }
        return DevArtifactScanner.DiscoverResult(
            // Partial callbacks and final output share the actor's single acceptance order.
            // Sorting only the final array would make the streamed prefix contract untrue.
            hits: hits,
            didTimeout: stopOutcome.didTimeout,
            didTruncate: stopOutcome.didTruncate,
            incompleteIssues: sortedIssues,
            scannedEntryCount: scannedEntryCount,
            elapsed: elapsed
        )
    }

    private func flushPartial(using delivery: PartialDelivery) {
        guard !partialBuffer.isEmpty else { return }
        let snapshot = partialBuffer
        partialBuffer.removeAll(keepingCapacity: true)
        delivery.callback(snapshot)
    }
}
