import Foundation

/// FatHeader：Mach-O Universal (FAT) 二进制头部解析。
///
/// 参考 `<mach-o/fat.h>`：
/// - `FAT_MAGIC = 0xCAFEBABE`（big-endian on disk; 当前架构相同字节序时直接读到这个）
/// - `FAT_CIGAM = 0xBEBAFECA`（与上字节序反转：磁盘是 big-endian，机器是 little-endian 时读到这个）
/// - `FAT_MAGIC_64 = 0xCAFEBABF` / `FAT_CIGAM_64 = 0xBFBAFECA`：64-bit 版本，offset/size 是 64-bit
///
/// 文件布局：
/// ```
/// fat_header  { magic: u32, nfat_arch: u32 }
/// fat_arch[]  { cputype: i32, cpusubtype: i32, offset: u32, size: u32, align: u32 } * nfat_arch
/// // (FAT_MAGIC_64 时 fat_arch_64 各字段类型见 <mach-o/fat.h>)
/// <slice 0 raw bytes>...
/// <slice 1 raw bytes>...
/// ```
///
/// 我们的瘦身策略（Step 11B MVP）：
/// 1. 读前 8 字节判 magic + nfat_arch
/// 2. 解析每个 fat_arch（仅支持 32-bit FAT_MAGIC，足以覆盖 macOS 当前 universal app 主流场景）
/// 3. 选目标 cputype（默认 arm64=0x0100000C）
/// 4. dryRun 计算节省 = 文件总大小 - 目标 slice size
/// 5. real 写：仅保留目标 slice 的 raw bytes，atomic replace 原文件
public enum FatMagic {
    public static let magic32: UInt32 = 0xCAFEBABE
    public static let cigam32: UInt32 = 0xBEBAFECA // 反序
    public static let magic64: UInt32 = 0xCAFEBABF
    public static let cigam64: UInt32 = 0xBFBAFECA
}

/// CPU 类型常量，与 `<mach/machine.h>` 对齐。
public enum CPUType {
    /// arm64 = CPU_ARCH_ABI64 (0x01000000) | CPU_TYPE_ARM (12) = 0x0100000C
    public static let arm64: Int32 = 0x0100000C
    /// arm64e（Apple Silicon 内部签名指针，cputype 同 arm64，subtype 区分；目前不区分）
    /// x86_64 = CPU_ARCH_ABI64 (0x01000000) | CPU_TYPE_X86 (7) = 0x01000007
    public static let x86_64: Int32 = 0x01000007
}

/// 单个 FAT 切片描述（解析后）。
public struct FatArch: Equatable, Sendable {
    public let cputype: Int32
    public let cpusubtype: Int32
    public let offset: UInt64    // 32-bit FAT 时直接放进 64-bit
    public let size: UInt64
    public let align: UInt32
    public init(cputype: Int32, cpusubtype: Int32, offset: UInt64, size: UInt64, align: UInt32) {
        self.cputype = cputype
        self.cpusubtype = cpusubtype
        self.offset = offset
        self.size = size
        self.align = align
    }
}

/// 文件分类：is FAT or thin or 不是 Mach-O。
public enum BinaryShape: Equatable, Sendable {
    case thin                           // 单架构 Mach-O 或非 FAT；瘦身无意义
    case fat32(arches: [FatArch])       // FAT_MAGIC（32-bit fat_arch）
    case fat64(arches: [FatArch])       // FAT_MAGIC_64
    case notMachO                       // 完全不是 Mach-O / 文件太短

    public var arches: [FatArch] {
        switch self {
        case .fat32(let a), .fat64(let a): return a
        case .thin, .notMachO: return []
        }
    }
}

/// FatHeader 解析器。无副作用、纯计算。
public enum FatHeader {

    /// 把 4 字节 big-endian 序列解释成 UInt32。
    /// 不能用 `data[i]` 拿单字节然后位移 —— 那样依赖 CPU endianness；这里强制 big-endian。
    @inline(__always)
    static func readBE32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    @inline(__always)
    static func readBE64(_ data: Data, at offset: Int) -> UInt64? {
        guard offset + 8 <= data.count else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 {
            v = (v << 8) | UInt64(data[data.startIndex + offset + i])
        }
        return v
    }

    /// 解析文件前 N 字节（足够覆盖头 + 所有 fat_arch）得到 BinaryShape。
    /// - Parameter data: 文件起始至少 4096 字节足以容纳常见 fat_arch 数组
    public static func parse(_ data: Data) -> BinaryShape {
        guard let magic = readBE32(data, at: 0) else { return .notMachO }
        switch magic {
        case FatMagic.magic32:
            return parseFat32(data)
        case FatMagic.magic64:
            return parseFat64(data)
        case FatMagic.cigam32, FatMagic.cigam64:
            // 极少见：磁盘上是 little-endian fat 头。当前实现不支持，按 thin 处理（不瘦身），保守。
            return .thin
        default:
            // 可能是 thin Mach-O（0xFEEDFACE / 0xFEEDFACF）或别的；不区分，统一 thin。
            return .thin
        }
    }

    private static func parseFat32(_ data: Data) -> BinaryShape {
        guard let nfat = readBE32(data, at: 4) else { return .notMachO }
        // 防御：nfat 异常（>50）的视为坏文件
        guard nfat > 0, nfat <= 50 else { return .notMachO }
        var arches: [FatArch] = []
        var p = 8
        for _ in 0..<Int(nfat) {
            guard let cputype = readBE32(data, at: p),
                  let cpusubtype = readBE32(data, at: p + 4),
                  let offset = readBE32(data, at: p + 8),
                  let size = readBE32(data, at: p + 12),
                  let align = readBE32(data, at: p + 16) else { return .notMachO }
            arches.append(.init(
                cputype: Int32(bitPattern: cputype),
                cpusubtype: Int32(bitPattern: cpusubtype),
                offset: UInt64(offset),
                size: UInt64(size),
                align: align
            ))
            p += 20
        }
        return .fat32(arches: arches)
    }

    private static func parseFat64(_ data: Data) -> BinaryShape {
        guard let nfat = readBE32(data, at: 4) else { return .notMachO }
        guard nfat > 0, nfat <= 50 else { return .notMachO }
        var arches: [FatArch] = []
        var p = 8
        for _ in 0..<Int(nfat) {
            guard let cputype = readBE32(data, at: p),
                  let cpusubtype = readBE32(data, at: p + 4),
                  let offset = readBE64(data, at: p + 8),
                  let size = readBE64(data, at: p + 16),
                  let align = readBE32(data, at: p + 24) else { return .notMachO }
            // p + 28 是 reserved (UInt32)，跳过
            arches.append(.init(
                cputype: Int32(bitPattern: cputype),
                cpusubtype: Int32(bitPattern: cpusubtype),
                offset: offset,
                size: size,
                align: align
            ))
            p += 32
        }
        return .fat64(arches: arches)
    }
}
