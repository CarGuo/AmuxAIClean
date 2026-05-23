import Foundation
import Darwin

/// v1.3：根据扫描根所在卷的"介质类型"自适应 worker 数。
///
/// 业界共识（PITFALLS §4）：
/// - **SSD/NVMe**：随机 IO 几乎无 seek 成本，worker 数提到 8 仍线性扩展，IO 队列深度优先；
/// - **机械硬盘 (HDD)**：多 worker 同时下钻不同子目录会让磁头 seek 风暴，2 个 worker 通常已最优；
/// - **网络盘 (smbfs/nfs/afpfs/webdav/cifs)**：单连接吞吐稳，多 worker 易被 server 限速；
///   尤其 SMB 在 macOS 上是单 TCP 连接复用，多 worker = 单连接抢带宽，不如串行。
///
/// 实现方式：`statfs(2)` 拿 mount 的 `f_fstypename`（`apfs`/`hfs`/`smbfs`/`nfs`/...）
/// + `f_flags`（`MNT_LOCAL` 区分本地/远程）。控制流：先 fstype 黑名单识别已知远程类型，
/// 再检查 `MNT_LOCAL` flag 兜底，最后按 fstype 区分 SSD/HDD/闪存。
///
/// 已知边界：APFS over USB HDD / Fusion Drive / 外接 APFS 备份盘会被误判 SSD 跑 8 worker，
/// 后果是 IO 风暴拖慢机器（不损坏数据）。用户可通过 `ScanOptions.mediaAware = false` 兜底。
public enum MediaProbe {

    public enum Kind: String, Sendable {
        case ssd
        case hdd
        case network
        case unknown
    }

    /// 探测路径所在卷的介质类型。失败返回 `.unknown`，调用方应当回退到默认 worker 数。
    public static func probe(path: String) -> Kind {
        var sb = statfs()
        guard statfs(path, &sb) == 0 else { return .unknown }

        // f_fstypename: char[MFSTYPENAMELEN]（=16，含 \0）。
        // 直接 String(cString:) 假设 buffer 内必有 \0；为防止内核异常给出 16 字节无 null，
        // 显式按字节扫到 \0 截断，再用 String(decoding:as:UTF8.self) 自带替换字符容错。
        let fsType: String = withUnsafeBytes(of: sb.f_fstypename) { raw -> String in
            let bytes = raw.bindMemory(to: UInt8.self)
            var len = 0
            while len < bytes.count, bytes[len] != 0 { len += 1 }
            return String(decoding: bytes.prefix(len), as: UTF8.self)
        }

        // 第一步：fstype 黑名单优先识别远程文件系统。
        // 有些 FUSE 实现的 smbfs 会误带 MNT_LOCAL，所以名字优先级高于 flag。
        switch fsType {
        case "smbfs", "nfs", "afpfs", "webdav", "ftp", "cifs":
            return .network
        default:
            break
        }

        // 第二步：MNT_LOCAL 兜底。f_flags 是 UInt32、MNT_LOCAL 是 Int32（0x1000）；
        // 必须把 MNT_LOCAL 拓宽到 UInt32 再做位运算。
        // 错误写法 `Int32(sb.f_flags) & MNT_LOCAL` 在内核启用任何 ≥0x80000000 高位 flag
        // 时会触发 Swift runtime trap（Int32(UInt32) 是检查型转换）。
        let isLocal = (sb.f_flags & UInt32(MNT_LOCAL)) != 0
        if !isLocal { return .network }

        // 第三步：本地卷按 fstype 分档。
        switch fsType {
        case "apfs":
            // 2018+ Mac 内置盘几乎都是 SSD；APFS over HDD（Fusion Drive / 外接备份盘）
            // 极少见，统一按 SSD 看。最坏退化为 IO 风暴拖慢机器，可由用户关 mediaAware 兜底。
            return .ssd
        case "hfs", "hfsplus":
            // HFS+ 通常在老款 Mac 旋转盘 / 外接机械盘，保守按 HDD 处理。
            return .hdd
        case "exfat", "msdos":
            // exFAT/FAT32 在 USB 闪存 / SD 卡，访问特性接近 SSD。
            return .ssd
        default:
            return .unknown
        }
    }

    /// 把介质类型 + 用户配置 → 实际 worker 数。
    /// 仅在 `options.mediaAware == true` 时调用；返回值会再被 `min(maxConcurrency, ...)` 兜一道。
    public static func recommendedWorkerCount(for kind: Kind, fallback: Int, maxCap: Int) -> Int {
        let raw: Int
        switch kind {
        case .ssd:     raw = max(fallback, 8)
        case .hdd:     raw = 2
        case .network: raw = 1
        case .unknown: raw = fallback
        }
        return max(1, min(raw, maxCap))
    }
}
