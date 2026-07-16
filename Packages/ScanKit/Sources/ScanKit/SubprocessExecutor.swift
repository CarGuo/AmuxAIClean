import Foundation
import Darwin

/// 受限子进程执行器（v1.7 M1 PR-2）。
///
/// 与既有 [DefaultMaintenanceRunner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/MaintenanceTasks.swift#L137-L171) 的区别：
/// - MaintenanceRunner：管理任务（lsregister/qlmanage/dscacheutil），全是系统维护命令，硬编码 launchPath 已隔离风险
/// - SubprocessExecutor：**面向 simctl / xcrun 等开发者命令**，要执行的子命令是「数据驱动」的，
///   必须用 **allowlist** 强约束才能避免被未来 PR 误用为"任意命令执行通道"。
///
/// 设计原则：
/// 1. **白名单优先**：调用方传入 `(executable, args)`，如不在 allowlist 中直接 throw `notAllowed`；
///    任何"开后门让 caller 跳过白名单"的修改都是回归红线。
/// 2. **按命令生命周期等待**：只读查询默认 5s 超时并可终止；系统托管的破坏性操作必须
///    显式使用 `.waitUntilExit`，避免 App 在 CoreSimulator 正提交卸载时发送 TERM/KILL。
/// 3. **stdout/stderr 合并**：返回单一字符串，调用方自己解析；
///    这与 MaintenanceCommandResult 模式一致，避免 Pipe 多通道复杂度。
/// 4. **dryRun 闸门**：构造时可指定 `dryRun=true`，此时**不真起 Process**，
///    仅返回 `(exitCode: 0, output: "<dryRun> /xxx args...")` 用于测试 + 用户预览。
/// 5. **不抛异常的错误返回**：`SubprocessResult.exitCode = -1` 表 launch 失败，`-2` 表超时，
///    与 MaintenanceCommandResult 完全同构，方便调用方统一处理。
public struct SubprocessExecutor: Sendable {

    /// 子进程终态等待策略。
    ///
    /// **v2026.07.15 根因修复**：查询命令需要有界超时，防止扫描永久挂起；但
    /// `simctl delete` / `simctl runtime delete` 是 CoreSimulator 管理的事务，任意固定
    /// 秒数后强杀既无法证明回滚，也与 UI“当前项安全完成后停止”的承诺冲突。因此 managed
    /// operation 使用 `.waitUntilExit`，停止按钮只阻止提交下一项，不中断当前系统事务。
    public enum TerminalWaitPolicy: Sendable, Equatable {
        case timeout(TimeInterval)
        case waitUntilExit
    }

    /// 允许执行的命令模板。
    ///
    /// `(executable, argsPrefix)` 两元组：
    /// - `executable`：必须精确匹配，例如 `/usr/bin/xcrun`；
    /// - `argsPrefix`：实际调用的 args 必须以此为前缀，例如 `["simctl", "delete"]` 允许
    ///   `xcrun simctl delete <UUID>` 但拒绝 `xcrun simctl install`。
    ///
    /// 维护原则：**新增条目必须经过 V12 级集成测试同步加 case**，
    /// 详见 [SubprocessExecutorTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Tests/ScanKitTests/SubprocessExecutorTests.swift)。
    public struct AllowEntry: Sendable, Hashable {
        public let executable: String
        public let argsPrefix: [String]

        public init(executable: String, argsPrefix: [String]) {
            self.executable = executable
            self.argsPrefix = argsPrefix
        }
    }

    /// 默认 allowlist —— v1.7 M1 PR-2 范围。
    ///
    /// 该 list 必须**只读**——任何运行时修改都是回归红线。
    public static let defaultAllowlist: [AllowEntry] = [
        // simctl 只读查询
        AllowEntry(executable: "/usr/bin/xcrun", argsPrefix: ["simctl", "list", "devices", "--json"]),
        AllowEntry(executable: "/usr/bin/xcrun", argsPrefix: ["simctl", "list", "runtimes", "--json"]),
        // 2026-07-15：新 Xcode 托管 runtime 元数据，直接提供 UUID/deletable/sizeBytes。
        AllowEntry(executable: "/usr/bin/xcrun", argsPrefix: ["simctl", "runtime", "list", "-j"]),
        // CoreSimulator 托管卸载。固定前缀之外还会在 argumentsPassDestructiveTailPolicy
        // 严格要求单个 UUID 尾参，不允许 semantic identifier 或附加 flag。
        AllowEntry(executable: "/usr/bin/xcrun", argsPrefix: ["simctl", "delete"]),
        AllowEntry(executable: "/usr/bin/xcrun", argsPrefix: ["simctl", "runtime", "delete"]),
    ]

    public enum SubprocessError: Error, Sendable, Equatable {
        /// 不在 allowlist 中。`reason` 给出 (executable, args) 便于日志追踪。
        case notAllowed(executable: String, args: [String])
    }

    public struct Result: Sendable, Hashable {
        public let exitCode: Int32
        public let output: String

        public init(exitCode: Int32, output: String) {
            self.exitCode = exitCode
            self.output = output
        }

        /// 仅当 exitCode == 0 视为成功。
        public var isSuccess: Bool { exitCode == 0 }
    }

    public let allowlist: [AllowEntry]
    public let terminalWaitPolicy: TerminalWaitPolicy
    public let dryRun: Bool

    public init(allowlist: [AllowEntry] = SubprocessExecutor.defaultAllowlist,
                timeout: TimeInterval = 5,
                dryRun: Bool = false) {
        self.allowlist = allowlist
        self.terminalWaitPolicy = .timeout(timeout)
        self.dryRun = dryRun
    }

    /// 系统托管事务专用构造入口。调用点必须显式选择等待策略，不能靠扩大 magic timeout
    /// 猜测 Runtime 卸载需要多久。
    public init(allowlist: [AllowEntry] = SubprocessExecutor.defaultAllowlist,
                terminalWaitPolicy: TerminalWaitPolicy,
                dryRun: Bool = false) {
        self.allowlist = allowlist
        self.terminalWaitPolicy = terminalWaitPolicy
        self.dryRun = dryRun
    }

    /// 执行子进程。
    ///
    /// - Parameters:
    ///   - executable: 绝对可执行路径，如 `/usr/bin/xcrun`
    ///   - args: 完整参数列表，如 `["simctl", "delete", "<UUID>"]`
    /// - Throws: `SubprocessError.notAllowed` 若不在 allowlist
    /// - Returns: `Result(exitCode, output)`；`exitCode = -1` 表 launch 失败，`-2` 表超时
    ///
    /// **Threading 警告**：本函数是**同步阻塞**的——会在当前线程一直阻塞到
    /// 子进程结束或有界查询的 `timeout` 触发。caller 若在 actor / @MainActor 上下文里调用，
    /// 会持锁阻塞整个 actor。已知 actor 调用方：
    /// [SimctlDevicesScanner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/SimctlDevicesScanner.swift)
    /// 与 [SimctlRuntimeScanner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/SimctlRuntimeScanner.swift)
    /// ——这两个 actor 串行使用 executor，外部不会并发等同一 actor，可接受。
    /// `.waitUntilExit` 必须在 nonisolated / detached 上下文调用，避免阻塞主线程或核心 actor。
    public func run(executable: String, args: [String]) throws -> Result {
        // 1. allowlist 检查（必须先于任何执行动作）
        let isAllowed = allowlist.contains { entry in
            entry.executable == executable
            && args.count >= entry.argsPrefix.count
            && Array(args.prefix(entry.argsPrefix.count)) == entry.argsPrefix
        }
        guard isAllowed else {
            throw SubprocessError.notAllowed(executable: executable, args: args)
        }
        guard Self.argumentsPassDestructiveTailPolicy(executable: executable, args: args) else {
            throw SubprocessError.notAllowed(executable: executable, args: args)
        }

        // 2. dryRun 闸门：不真起进程
        if dryRun {
            let argsJoined = args.joined(separator: " ")
            return Result(exitCode: 0, output: "<dryRun> \(executable) \(argsJoined)")
        }

        // 3. 实际执行（事件驱动 + timeout 闸门 + 双 Pipe 边读边累积）
        //
        // **Review fix #1，2026-06-15**：原实现是
        //   while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        // 这是 busy-loop polling——平均 50ms 醒一次，CPU 浪费 + 唤醒抖动；且在 timeout
        // 路径上 sleep 颗粒度直接决定"超时判定误差"。改为 DispatchSemaphore + Process
        // 的 terminationHandler 事件驱动：子进程结束的瞬间 signal 唤醒等待，毫秒级精确；
        // timeout 用 semaphore.wait(timeout:) 由 GCD 内核计时，零 CPU 占用。
        //
        // **Review fix #2，2026-06-22（P0-2）**：原实现把 stdout/stderr 复用同一根 Pipe，
        // 且采用「wait-then-read」（task 结束后再 readDataToEndOfFile）。macOS Pipe
        // 内核缓冲约 64KB——一旦子命令输出超过 64KB（如 simctl list 在巨多设备上、或
        // runtime delete 失败时的长 stderr），子进程会在写入 pipe 时阻塞，永远不退出，
        // 进而把 terminationHandler 卡死，触发 timeout 但仍残留泄漏的 fd。
        // 同时 terminationHandler 闭包没显式断开 task.terminationHandler，存在 ARC
        // 循环引用（Process → closure → semaphore 持有；Process 不被 release）。
        // 修复：
        //   - 拆 stdout / stderr 为独立 Pipe；
        //   - 用 readabilityHandler 在后台线程边读边累积到 NSLock 保护的 Data 中；
        //   - defer 关闭 read/write FD，timeout/正常路径统一回收；
        //   - wait 完成后立即把 task.terminationHandler = nil 解循环。
        let task = Process()
        task.launchPath = executable
        task.arguments = args
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        // 后台累积缓冲（NSLock 保护，跨线程安全）
        //
        // **Sendable 闭包约束**：readabilityHandler 是 `@Sendable` 闭包，不能 capture
        // 一个可变 `var Data`（会触发 `mutation of captured var in concurrently-executing
        // code` 报错）。改用 final class box 让 capture 的是引用，引用内字段的写入
        // 由 NSLock 保护——既满足 Sendable，又保留"边读边累积"语义。
        final class ByteBuffer: @unchecked Sendable {
            var data = Data()
        }
        let bufferLock = NSLock()
        let stdoutBuffer = ByteBuffer()
        let stderrBuffer = ByteBuffer()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            bufferLock.lock()
            stdoutBuffer.data.append(chunk)
            bufferLock.unlock()
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            bufferLock.lock()
            stderrBuffer.data.append(chunk)
            bufferLock.unlock()
        }

        let semaphore = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in
            // 子进程退出由独立线程回调；signal 唤醒下面 wait()。
            // 多次 signal 是安全的（即便 wait 已经返回，下次 wait 会立即通过）。
            semaphore.signal()
        }

        // 统一回收 readabilityHandler / FD / 循环引用。
        // 注意：terminate() 之后内核才会关闭子进程那侧的 write end，readabilityHandler
        // 会再被回调一次 chunk.isEmpty 表示 EOF，然后我们置 nil 让闭包释放。
        func cleanup() {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            task.terminationHandler = nil
        }

        do {
            try task.run()
        } catch {
            cleanup()
            return Result(exitCode: -1, output: "launch failed: \(error)")
        }

        // 查询使用有界 timeout；managed operation 等待系统命令自然收敛到终态。
        // `.waitUntilExit` 不响应 Task cancellation：上层停止语义是“不再提交下一项”，
        // 当前 CoreSimulator 事务必须继续等待真实 exit status。
        switch terminalWaitPolicy {
        case .waitUntilExit:
            semaphore.wait()

        case .timeout(let timeout):
            let waitResult = semaphore.wait(timeout: .now() + timeout)
            if waitResult == .timedOut {
                task.terminate()
                var killed = false
                if semaphore.wait(timeout: .now() + 1.0) == .timedOut {
                    kill(task.processIdentifier, SIGKILL)
                    killed = true
                    _ = semaphore.wait(timeout: .now() + 1.0)
                }
                bufferLock.lock()
                let pre = String(data: stdoutBuffer.data + stderrBuffer.data, encoding: .utf8) ?? ""
                bufferLock.unlock()
                cleanup()
                let suffix = killed ? " SIGKILL sent" : " terminated"
                return Result(exitCode: -2, output: "timeout after \(timeout)s;\(suffix); partial=\(pre)")
            }
        }

        // 正常退出：readabilityHandler 已把所有数据累积到 buffer 中。
        bufferLock.lock()
        let combined = stdoutBuffer.data + stderrBuffer.data
        bufferLock.unlock()
        let output = String(data: combined, encoding: .utf8) ?? ""
        let status = task.terminationStatus
        cleanup()
        return Result(exitCode: status, output: output)
    }

    static func argumentsPassDestructiveTailPolicy(executable: String, args: [String]) -> Bool {
        guard executable == "/usr/bin/xcrun" else { return true }
        if Array(args.prefix(2)) == ["simctl", "delete"] {
            return args.count == 3 && isUUID(args[2])
        }
        if Array(args.prefix(3)) == ["simctl", "runtime", "delete"] {
            return args.count == 4 && isUUID(args[3])
        }
        return true
    }

    private static func isUUID(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        let lengths = [8, 4, 4, 4, 12]
        guard parts.count == lengths.count else { return false }
        for (part, length) in zip(parts, lengths) {
            guard part.count == length,
                  part.allSatisfy({ $0.isHexDigit }) else { return false }
        }
        return true
    }

}
