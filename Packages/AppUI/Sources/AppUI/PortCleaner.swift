import Darwin
import Foundation

public enum PortCleanerProtocol: String, CaseIterable, Hashable, Sendable {
    case tcp = "TCP"
    case udp = "UDP"
    case tcp6 = "TCP6"
    case udp6 = "UDP6"
}

public struct PortCleanerEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let proto: PortCleanerProtocol
    public let localAddress: String
    public let localPort: Int
    public let remoteAddress: String?
    public let remotePort: Int?
    public let state: String?
    public let pid: Int32
    public let processName: String
    public let processPath: String?
    public let user: String?

    public init(
        proto: PortCleanerProtocol,
        localAddress: String,
        localPort: Int,
        remoteAddress: String? = nil,
        remotePort: Int? = nil,
        state: String? = nil,
        pid: Int32,
        processName: String,
        processPath: String? = nil,
        user: String? = nil
    ) {
        self.proto = proto
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.state = state
        self.pid = pid
        self.processName = processName
        self.processPath = processPath
        self.user = user
        self.id = [
            proto.rawValue,
            localAddress,
            String(localPort),
            remoteAddress ?? "",
            remotePort.map(String.init) ?? "",
            String(pid)
        ].joined(separator: "|")
    }

    public var localEndpoint: String {
        "\(localAddress):\(localPort)"
    }

    public var remoteEndpoint: String {
        guard let remoteAddress, let remotePort else { return "-" }
        return "\(remoteAddress):\(remotePort)"
    }

    public var terminationProtection: PortCleanerTerminationProtection? {
        if pid <= 1 { return .invalidPID }
        if user == "root" { return .privilegedUser }
        if processName.hasPrefix("com.apple.") { return .systemProcess }
        guard let processPath, !processPath.isEmpty else { return nil }
        if processPath.hasPrefix("/System/")
            || processPath.hasPrefix("/usr/libexec/")
            || processPath.hasPrefix("/sbin/")
            || processPath.hasPrefix("/bin/")
            || processPath.hasPrefix("/usr/sbin/") {
            return .systemProcess
        }
        return nil
    }

    public var canRequestTermination: Bool {
        terminationProtection == nil
    }
}

public enum PortCleanerTerminationProtection: Hashable, Sendable {
    case invalidPID
    case privilegedUser
    case systemProcess
}

public struct PortCleanerGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let path: String?
    public let user: String?
    public let entries: [PortCleanerEntry]

    public var pids: [Int32] {
        Array(Set(entries.map(\.pid))).sorted()
    }

    public var portCount: Int { entries.count }

    public var terminableEntries: [PortCleanerEntry] {
        entries.filter(\.canRequestTermination)
    }

    public var terminablePids: [Int32] {
        Array(Set(terminableEntries.map(\.pid))).sorted()
    }

    public static func groups(from entries: [PortCleanerEntry]) -> [PortCleanerGroup] {
        let grouped = Dictionary(grouping: entries) { entry in
            "\(entry.processName)|\(entry.processPath ?? "")|\(entry.user ?? "")"
        }
        return grouped.map { key, items in
            let sorted = items.sorted(by: PortCleanerParser.entrySort)
            let first = sorted[0]
            return PortCleanerGroup(
                id: key,
                title: first.processName,
                path: first.processPath,
                user: first.user,
                entries: sorted
            )
        }
        .sorted { lhs, rhs in
            if lhs.portCount != rhs.portCount { return lhs.portCount > rhs.portCount }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}

/// v2026.07.15：终止请求结果只保存事实，不在后台 actor 内提前固化 App 语言。
/// 若 UI 需要展示逐项原因，应在渲染边界调用 `message(locale:)`；系统 errno 文本保持
/// verbatim，产品自身的原因则由显式传入的 App locale 投影。
public enum PortCleanerKillDisposition: Hashable, Sendable {
    case terminationRequested
    case invalidPID
    case currentApplicationProtected
    case systemFailure(code: Int32, description: String)

    public var succeeded: Bool {
        if case .terminationRequested = self { return true }
        return false
    }

    public func message(locale: Locale) -> String {
        switch self {
        case .terminationRequested:
            return AppLocalization.string("port_cleaner.kill.success", locale: locale)
        case .invalidPID:
            return AppLocalization.string("port_cleaner.kill.invalid_pid", locale: locale)
        case .currentApplicationProtected:
            return AppLocalization.string("port_cleaner.kill.refuse_self", locale: locale)
        case .systemFailure(_, let description):
            return description
        }
    }
}

public struct PortCleanerKillResult: Hashable, Sendable {
    public let pid: Int32
    public let disposition: PortCleanerKillDisposition

    public var success: Bool { disposition.succeeded }

    public func message(locale: Locale) -> String {
        disposition.message(locale: locale)
    }
}

public actor PortCleanerScanner {
    public init() {}

    public func listPorts() async -> [PortCleanerEntry] {
        let output = Self.runExecutable(
            "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-iUDP", "-FpcLnPT"],
            timeout: 8
        )
        let parsed = PortCleanerParser.parseLsof(output.stdout).filter { $0.localPort > 0 }
        guard !parsed.isEmpty else { return [] }

        let processInfo = Self.processInfo(for: Set(parsed.map(\.pid)))
        return parsed.map { entry in
            guard let info = processInfo[entry.pid] else { return entry }
            return PortCleanerEntry(
                proto: entry.proto,
                localAddress: entry.localAddress,
                localPort: entry.localPort,
                remoteAddress: entry.remoteAddress,
                remotePort: entry.remotePort,
                state: entry.state,
                pid: entry.pid,
                processName: entry.processName,
                processPath: info.path,
                user: entry.user ?? info.user
            )
        }
        .sorted(by: PortCleanerParser.entrySort)
    }

    public func kill(pid: Int32) async -> PortCleanerKillResult {
        await kill(pids: [pid]).first ?? PortCleanerKillResult(
            pid: pid,
            disposition: .invalidPID
        )
    }

    public func kill(pids: [Int32]) async -> [PortCleanerKillResult] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        return Array(Set(pids)).sorted().prefix(128).map { pid in
            guard pid > 1 else {
                return PortCleanerKillResult(
                    pid: pid,
                    disposition: .invalidPID
                )
            }
            guard pid != currentPID else {
                return PortCleanerKillResult(
                    pid: pid,
                    disposition: .currentApplicationProtected
                )
            }
            let rc = Darwin.kill(pid_t(pid), SIGTERM)
            if rc == 0 {
                return PortCleanerKillResult(
                    pid: pid,
                    disposition: .terminationRequested
                )
            }
            let errorCode = errno
            return PortCleanerKillResult(
                pid: pid,
                disposition: .systemFailure(
                    code: errorCode,
                    description: String(cString: strerror(errorCode))
                )
            )
        }
    }

    private struct ProcessSnapshot: Sendable {
        let user: String?
        let path: String?
    }

    private static func processInfo(for pids: Set<Int32>) -> [Int32: ProcessSnapshot] {
        guard !pids.isEmpty else { return [:] }
        let output = runExecutable("/bin/ps", arguments: ["-axo", "pid=,user=,comm="], timeout: 5)
        var map: [Int32: ProcessSnapshot] = [:]
        for raw in output.stdout.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let columns = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard columns.count >= 2, let pid = Int32(columns[0]), pids.contains(pid) else { continue }
            let user = String(columns[1])
            let path = columns.count >= 3 ? String(columns[2]) : nil
            map[pid] = ProcessSnapshot(user: user, path: path)
        }
        return map
    }

    private static func runExecutable(
        _ path: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> (stdout: String, stderr: String, status: Int32, timedOut: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return ("", error.localizedDescription, -1, false)
        }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            semaphore.signal()
        }

        let timedOut = semaphore.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
        }

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (out, err, timedOut ? -1 : process.terminationStatus, timedOut)
    }
}

enum PortCleanerParser {
    static func parseLsof(_ text: String) -> [PortCleanerEntry] {
        var entries: [PortCleanerEntry] = []
        var pid: Int32 = 0
        var command = ""
        var user: String?
        var fileProto: PortCleanerProtocol?
        var fileState: String?
        var fileAddress: String?

        func flushFile() {
            guard
                pid > 0,
                let proto = fileProto,
                let address = fileAddress,
                let endpoint = parseAddress(address)
            else {
                fileProto = nil
                fileState = nil
                fileAddress = nil
                return
            }
            entries.append(PortCleanerEntry(
                proto: proto,
                localAddress: endpoint.local.host,
                localPort: endpoint.local.port,
                remoteAddress: endpoint.remote?.host,
                remotePort: endpoint.remote?.port,
                state: fileState,
                pid: pid,
                processName: command.isEmpty ? String(format: "PID %d", pid) : command,
                user: user
            ))
            fileProto = nil
            fileState = nil
            fileAddress = nil
        }

        for raw in text.split(whereSeparator: \.isNewline) {
            guard let tag = raw.first else { continue }
            let value = String(raw.dropFirst())
            switch tag {
            case "p":
                flushFile()
                pid = Int32(value) ?? 0
                command = ""
                user = nil
            case "f":
                flushFile()
            case "c":
                command = value
            case "L":
                user = value
            case "P":
                if fileProto != nil || fileAddress != nil {
                    flushFile()
                }
                fileProto = PortCleanerProtocol(rawValue: value.uppercased())
            case "T":
                if value.hasPrefix("ST=") {
                    fileState = String(value.dropFirst(3))
                }
            case "n":
                fileAddress = value
            default:
                continue
            }
        }
        flushFile()

        var seen: Set<String> = []
        let unique = entries.filter { entry in
            if seen.contains(entry.id) { return false }
            seen.insert(entry.id)
            return true
        }
        return unique.sorted(by: entrySort)
    }

    static func entrySort(_ lhs: PortCleanerEntry, _ rhs: PortCleanerEntry) -> Bool {
        if lhs.processName != rhs.processName {
            return lhs.processName.localizedStandardCompare(rhs.processName) == .orderedAscending
        }
        if lhs.localPort != rhs.localPort { return lhs.localPort < rhs.localPort }
        if lhs.proto != rhs.proto { return lhs.proto.rawValue < rhs.proto.rawValue }
        return lhs.pid < rhs.pid
    }

    private static func parseAddress(_ value: String) -> (
        local: (host: String, port: Int),
        remote: (host: String, port: Int)?
    )? {
        let parts = value.split(separator: "->", maxSplits: 1, omittingEmptySubsequences: false)
        guard let local = parseHostPort(String(parts[0])) else { return nil }
        let remote = parts.count > 1 ? parseHostPort(String(parts[1])) : nil
        return (local, remote)
    }

    static func parseHostPort(_ raw: String) -> (host: String, port: Int)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let host = String(text[text.index(after: text.startIndex)..<close])
            let suffix = text[text.index(after: close)...]
            guard suffix.first == ":" else { return nil }
            return parsePort(String(suffix.dropFirst())).map { (host.isEmpty ? "*" : host, $0) }
        }
        guard let colon = text.lastIndex(of: ":") else { return nil }
        let host = String(text[..<colon])
        let port = String(text[text.index(after: colon)...])
        return parsePort(port).map { (host.isEmpty ? "*" : host, $0) }
    }

    private static func parsePort(_ text: String) -> Int? {
        if text == "*" { return 0 }
        guard let port = Int(text), port >= 0 else { return nil }
        return port
    }
}
