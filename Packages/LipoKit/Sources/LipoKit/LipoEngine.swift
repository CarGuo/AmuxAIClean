import Foundation

/// LipoEngine：MVP 版瘦身引擎（Step 11B / 2026-06）。
///
/// 设计目标：
/// 1. 输入一个 .app bundle 或单个 Mach-O 文件路径
/// 2. 扫出所有 FAT 二进制 + 估算保留指定架构后能省多少字节（dryRun）
/// 3. 用户确认后真实写盘：仅保留目标 slice，atomic replace
///
/// 与 macOS `lipo -extract` 一致；自研而不是 fork 系统 lipo 是因为：
/// - SPM 测试不依赖外部 CLI，CI 能跑
/// - 错误处理可控（lipo 退出码 + stderr 解析很麻烦）
/// - 后续可以加签名校验、备份等
public struct LipoEngine: Sendable {

    /// 单个二进制的瘦身候选。
    public struct Candidate: Equatable, Sendable {
        public let path: String
        public let originalSize: UInt64
        /// 命中目标架构的切片；可能为 nil 表示该 FAT 不含目标架构
        public let targetSlice: FatArch?
        public let allArches: [FatArch]
        /// 节省字节数 = originalSize - targetSlice.size（不命中则为 0）
        public var savings: UInt64 {
            guard let s = targetSlice else { return 0 }
            // 防御：避免 size > originalSize 这种异常文件造成下溢
            return originalSize > s.size ? originalSize - s.size : 0
        }
    }

    public let targetCPUType: Int32

    public init(targetCPUType: Int32 = CPUType.arm64) {
        self.targetCPUType = targetCPUType
    }

    /// 内部统一用 FileManager.default，避免 Sendable 噪音；FileManager.default 是
    /// 线程安全的（per Apple docs，对 read-only 元数据查询）。
    private var fm: FileManager { .default }

    // MARK: - Audit (dryRun)

    /// 检查单个文件，返回瘦身候选；非 FAT / 不命中目标架构返回 nil。
    public func audit(at path: String) -> Candidate? {
        // 仅读前 4096 字节做头解析；fat_arch[] 通常 << 1KB（最多 50 * 32 = 1600 byte）
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096) else { return nil }

        let shape = FatHeader.parse(head)
        guard !shape.arches.isEmpty else { return nil }

        // 文件总大小
        let attrs = try? fm.attributesOfItem(atPath: path)
        let originalSize = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        guard originalSize > 0 else { return nil }

        // 命中目标 cputype 的第一个切片（cpusubtype 不严格区分，arm64/arm64e 都接受）
        let target = shape.arches.first { $0.cputype == targetCPUType }
        // 若仅含目标架构（n=1）则瘦身无意义，跳过
        if shape.arches.count == 1 { return nil }

        return Candidate(
            path: path,
            originalSize: originalSize,
            targetSlice: target,
            allArches: shape.arches
        )
    }

    /// 递归扫描 bundle 或目录，所有 FAT 候选汇总。
    /// - Parameter rootPath: .app bundle 路径（如 `/Applications/Foo.app`）或任意目录
    public func auditBundle(at rootPath: String) -> [Candidate] {
        var out: [Candidate] = []
        let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: rootPath),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let next = enumerator?.nextObject() as? URL {
            // 仅看普通文件，忽略 symlink / dir
            if let isFile = (try? next.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile,
               isFile,
               let cand = audit(at: next.path) {
                out.append(cand)
            }
        }
        return out
    }

    // MARK: - DryRun aggregate

    /// 估算节省总量，不写盘。
    public func dryRunSavings(for candidates: [Candidate]) -> UInt64 {
        candidates.reduce(0) { $0 + $1.savings }
    }

    // MARK: - Real extract（暂未启用，留给 11B 真实场景验证）

    public enum ExtractError: Error, Equatable {
        case targetSliceMissing
        case readFailed
        case writeFailed
        case replaceFailed
    }

    /// 真实瘦身：从 candidate 提取目标 slice raw bytes，atomic 替换原文件。
    /// 调用者负责备份 / 用户确认。
    public func extract(_ candidate: Candidate) throws {
        guard let target = candidate.targetSlice else { throw ExtractError.targetSliceMissing }
        let url = URL(fileURLWithPath: candidate.path)

        // 读出 slice raw bytes
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ExtractError.readFailed }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: target.offset)
        } catch {
            throw ExtractError.readFailed
        }
        guard let body = try? handle.read(upToCount: Int(target.size)),
              UInt64(body.count) == target.size else {
            throw ExtractError.readFailed
        }

        // 临时文件在同目录写入；保留原属性（mtime/perm/owner 通过 replaceItemAt 处理）
        let tmpURL = url.deletingLastPathComponent()
            .appendingPathComponent(".lipo-\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            try body.write(to: tmpURL, options: .atomic)
        } catch {
            throw ExtractError.writeFailed
        }
        // 拷贝原文件可执行权限到临时文件
        if let perm = (try? fm.attributesOfItem(atPath: candidate.path))?[.posixPermissions] as? NSNumber {
            try? fm.setAttributes([.posixPermissions: perm], ofItemAtPath: tmpURL.path)
        }
        do {
            _ = try fm.replaceItemAt(url, withItemAt: tmpURL)
        } catch {
            try? fm.removeItem(at: tmpURL)
            throw ExtractError.replaceFailed
        }
    }
}
