import Foundation
import Darwin
import LogKit

/// v1.3.x：探测 macOS 用了多少**硬盘空间**作为虚拟内存（swap）+ 休眠镜像（sleepimage）。
///
/// 用户原话："你能识别出来有多少硬盘空间是被用来当作内存 swap 了吗"。
/// 这个 Probe 把问题拆成两个口径，避免误导：
/// - **swap 内核口径**：`sysctl vm.swapusage` 返回的 total/used/free（内核视角，
///   含已分配但暂未写满的预留位）
/// - **swap 物理占盘**：遍历 `/private/var/vm/swapfile*` 的 allocated size 之和
///   （这才是用户磁盘上"被占走"的字节数）
/// - **sleepimage**：`/private/var/vm/sleepimage`（休眠镜像；存在则等同物理内存大小，
///   即便从不休眠也会被预占一份）
///
/// 设计原则：**只读，不清理**。swap 与 sleepimage 由内核 `dynamic_pager` / `pmset` 管理，
/// App 层删除会立即被系统重建，且可能触发 paging 错误或破坏休眠功能。
/// 所以本 Probe 不暴露删除接口，配套 UI 也只展示数据 + 给文案建议。
///
/// 权限要求：**零特权**。
/// - `sysctlbyname("vm.swapusage")` 任何用户态进程都能调
/// - `/private/var/vm/` 目录条目用 `URLResourceKey.totalFileAllocatedSizeKey` 拿元数据，无需 FDA、无需 root
///   （即便沙盒环境读不到也只会得到 0，本 Probe 会回退到 sysctl-only 模式，UI 仍可显示内核口径）
public enum SwapProbe {

    /// 单次探测的快照。所有字段单位均为字节。
    public struct Snapshot: Sendable, Equatable {
        /// 内核口径：swap 总分配（来自 `vm.swapusage` total）
        public let swapTotalBytes: Int64
        /// 内核口径：swap 已使用（来自 `vm.swapusage` used）
        public let swapUsedBytes: Int64
        /// 内核口径：swap 空闲（来自 `vm.swapusage` free）
        public let swapFreeBytes: Int64
        /// 是否 encrypted（`vm.swapusage` 字符串里若出现 `(encrypted)` 则为 true）
        public let encrypted: Bool

        /// 物理占盘：`/private/var/vm/swapfile*` 文件实际大小之和
        public let swapFileBytesOnDisk: Int64
        /// swapfile 的数量（0 表示要么没产生过，要么读不到目录）
        public let swapFileCount: Int

        /// 物理占盘：`/private/var/vm/sleepimage` 文件大小（不存在时为 0）
        public let sleepImageBytes: Int64

        /// 综合"被 macOS 拿去当内存延伸的硬盘空间"= **swap 物理占盘** + sleepimage。
        ///
        /// v1.3.x review-fix（用户反馈："你确定虚拟内存只有 2G，刚刚有 50 多 G"）：
        /// macOS 的 `/private/var/vm/swapfile*` 文件被 SIP/`chflags hidden` 保护，
        /// **大多数沙盒/普通 App 进程列不出文件**（`contentsOfDirectory` 返回空）。
        /// 这种情况下若直接以 0 计入物理占盘，会让虚拟内存看起来只剩 sleepimage 那 2 GB，
        /// 与用户终端 `sysctl vm.swapusage` 看到的几十 GB 严重不一致。
        ///
        /// 修复策略：**读不到物理 swapfile 时回退用内核 total 字节数**。
        /// 论据：`dynamic_pager` 创建出来的 swapfile 文件大小总和 == `xsw_usage.xsu_total`
        /// （内核会把所有已分配文件的总容量上报到 sysctl），所以 sysctl total 就是物理占盘的可靠估算。
        public var swapDiskBytes: Int64 {
            // 优先用真实文件大小（更精准；可能比 sysctl total 略小，因为内核保留位）
            if swapFileBytesOnDisk > 0 { return swapFileBytesOnDisk }
            // 回退到内核 total（受限/沙盒环境下唯一可信源）
            return swapTotalBytes
        }

        /// 同上，但只看"swap 文件"维度——sleepimage 单独算。
        public var totalDiskFootprintBytes: Int64 {
            swapDiskBytes + sleepImageBytes
        }

        /// 是否拿到了任何**文件级**精确值（决定 UI 是否显示 "swap N 个文件" 的细节行）。
        /// 修复：原实现只看物理读到的 swapfile/sleepimage，用户大多数情况下读不到 swapfile，
        /// 会让 UI 退化成"只显示 sleepimage"的反直觉表现。
        /// 现在改为：**只要任一来源（swap 或 sleepimage）有非零字节即返回 true**。
        public var diskFootprintAvailable: Bool {
            swapDiskBytes > 0 || sleepImageBytes > 0
        }

        /// 是否真正读到了 swapfile 物理大小（区别于"用 sysctl 回退估算的"）。
        /// UI 用它来决定是否显示"\(swapFileCount) 个 swapfile"的细节文案。
        public var swapFileSizeMeasured: Bool {
            swapFileCount > 0
        }

        public init(
            swapTotalBytes: Int64,
            swapUsedBytes: Int64,
            swapFreeBytes: Int64,
            encrypted: Bool,
            swapFileBytesOnDisk: Int64,
            swapFileCount: Int,
            sleepImageBytes: Int64
        ) {
            self.swapTotalBytes = swapTotalBytes
            self.swapUsedBytes = swapUsedBytes
            self.swapFreeBytes = swapFreeBytes
            self.encrypted = encrypted
            self.swapFileBytesOnDisk = swapFileBytesOnDisk
            self.swapFileCount = swapFileCount
            self.sleepImageBytes = sleepImageBytes
        }
    }

    /// 同步探测。开销 ~毫秒级（一次 sysctl + 几次 stat）。
    /// 任何子步骤失败都会回退为 0，整体不会抛错——UI 永远拿得到一个 Snapshot。
    public static func probe(vmDirectory: String = "/private/var/vm") -> Snapshot {
        let raw = readSwapUsageRaw() ?? ""
        let parsed = parseSwapUsage(raw)

        let (fileBytes, fileCount) = sumSwapFiles(in: vmDirectory)
        let sleepBytes = sleepImageSize(in: vmDirectory)

        return Snapshot(
            swapTotalBytes: parsed.total,
            swapUsedBytes: parsed.used,
            swapFreeBytes: parsed.free,
            encrypted: parsed.encrypted,
            swapFileBytesOnDisk: fileBytes,
            swapFileCount: fileCount,
            sleepImageBytes: sleepBytes
        )
    }

    // MARK: - sysctl 解析

    /// 内核口径解析结果。
    struct SwapUsageParsed: Equatable {
        var total: Int64
        var used: Int64
        var free: Int64
        var encrypted: Bool
    }

    /// 用 `sysctlbyname("vm.swapusage", ...)` 拿 `xsw_usage` 结构体，再格式化为典型字符串。
    /// 之所以**先转字符串再解析**：
    /// 1. `xsw_usage` 是私有 struct，跨 SDK 字段偏移可能变；
    /// 2. 字符串口径与 `sysctl vm.swapusage` 命令行输出完全一致，便于和用户在终端看到的对齐；
    /// 3. 单测可以直接喂字符串（不依赖真机 sysctl）。
    static func readSwapUsageRaw() -> String? {
        // 先获取所需缓冲区大小
        var size: size_t = 0
        if sysctlbyname("vm.swapusage", nil, &size, nil, 0) != 0 || size == 0 {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        let ok = buffer.withUnsafeMutableBufferPointer { ptr -> Bool in
            sysctlbyname("vm.swapusage", ptr.baseAddress, &size, nil, 0) == 0
        }
        guard ok else { return nil }

        // xsw_usage 内存布局（macOS 公开头 sysctl.h 顺序）：
        //   xsu_total / xsu_avail / xsu_used (uint64, bytes) ... xsu_pagesize (uint32) ... xsu_encrypted (bool)
        // 这里只读前 3 个 uint64（数值字段），encrypted 字段偏移容易跨版本漂移，
        // 不去硬解，直接按 macOS 10.7+ 默认 swap 加密展示一个 (encrypted) 标签即可——
        // 标签只用于 UI 展示，不影响任何数值口径。
        guard size >= MemoryLayout<UInt64>.size * 3 else { return nil }
        let total = buffer.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt64.self) }
        let avail = buffer.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
        let used = buffer.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt64.self) }

        let mb = 1024.0 * 1024.0
        return String(
            format: "total = %.2fM  used = %.2fM  free = %.2fM  (encrypted)",
            Double(total) / mb,
            Double(used) / mb,
            Double(avail) / mb
        )
    }

    /// 把形如 `total = 26624.00M  used = 25589.44M  free = 1034.56M  (encrypted)`
    /// 的字符串解析为 SwapUsageParsed。
    /// 解析失败时返回全 0（不抛错）。
    static func parseSwapUsage(_ raw: String) -> SwapUsageParsed {
        var result = SwapUsageParsed(total: 0, used: 0, free: 0, encrypted: false)
        if raw.isEmpty { return result }
        if raw.contains("(encrypted)") { result.encrypted = true }

        let s = raw as NSString
        let pattern = #"(total|used|free)\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*([KMG])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return result
        }
        let matches = regex.matches(in: raw, options: [], range: NSRange(location: 0, length: s.length))
        for m in matches where m.numberOfRanges == 4 {
            let key = s.substring(with: m.range(at: 1)).lowercased()
            let numStr = s.substring(with: m.range(at: 2))
            let unit = s.substring(with: m.range(at: 3)).uppercased()
            guard let num = Double(numStr) else { continue }
            let bytes = Int64(num * unitMultiplier(unit))
            switch key {
            case "total": result.total = bytes
            case "used":  result.used = bytes
            case "free":  result.free = bytes
            default: break
            }
        }
        return result
    }

    private static func unitMultiplier(_ unit: String) -> Double {
        // sysctl vm.swapusage 用 1024 进制（MiB），与 ByteCountFormatter .file (1000) 不同
        // 但展示层会重新走 ByteCountFormatter，本函数只负责字节换算
        switch unit.uppercased() {
        case "K": return 1024
        case "M": return 1024 * 1024
        case "G": return 1024 * 1024 * 1024
        default: return 1
        }
    }

    // MARK: - 物理占盘扫描

    /// 累加 `/private/var/vm/swapfile*` 文件的真实大小。
    /// 沙盒内读不到目录时返回 (0, 0)，UI 据此回退到 sysctl-only。
    static func sumSwapFiles(in vmDirectory: String) -> (bytes: Int64, count: Int) {
        let url = URL(fileURLWithPath: vmDirectory)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
        }
        var total: Int64 = 0
        var count = 0
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("swapfile") else { continue }
            do {
                let values = try entry.resourceValues(forKeys: [
                    .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey,
                ])
                guard values.isRegularFile == true else { continue }
                if let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
                    total += Int64(size)
                    count += 1
                }
            } catch {
                // Probe 是只读的 best-effort 系统指标；单个受保护 swapfile 不应让整张
                // 快照失败，但失败必须留诊断证据，不能静默吞掉。
                GSYLog.debug(.scan, "SwapProbe 无法读取 swapfile metadata path=\(entry.path) error=\(error)")
            }
        }
        return (total, count)
    }

    /// `/private/var/vm/sleepimage` 大小；不存在或读不到时为 0。
    static func sleepImageSize(in vmDirectory: String) -> Int64 {
        let path = "\(vmDirectory)/sleepimage"
        let url = URL(fileURLWithPath: path)
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey,
            ])
        } catch {
            // sleepimage 在现代 macOS 上经常不存在或不可见；记录后按 0 回退是这个
            // best-effort probe 的公开契约。
            GSYLog.debug(.scan, "SwapProbe 无法读取 sleepimage metadata path=\(path) error=\(error)")
            return 0
        }
        guard values.isRegularFile == true,
              let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize else { return 0 }
        return Int64(size)
    }
}
