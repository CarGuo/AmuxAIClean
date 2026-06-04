import XCTest
@testable import LipoKit

/// LipoKit —— FAT 二进制识别 + 瘦身引擎测试（Step 11B / 2026-06）
///
/// 测试主题：
/// 1. FAT_MAGIC 识别正确（big-endian magic 0xCAFEBABE）
/// 2. FAT_MAGIC_64 识别 + 64-bit offset/size 解析
/// 3. thin / 非 Mach-O 直接 .thin / .notMachO 不引擎瘦身
/// 4. audit 命中目标架构 → savings 正确（ = total - target.size）
/// 5. dryRun 不写盘 + 总 savings 累加
/// 6. extract 真实写盘 + 内容仅含目标 slice raw bytes
/// 7. 仅含目标架构（n=1）的 thin 不进入候选（瘦身无意义）
final class LipoKitTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir(_ label: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LipoKitTests-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// big-endian UInt32 写入 Data
    private func appendBE32(_ v: UInt32, into d: inout Data) {
        d.append(UInt8((v >> 24) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8(v & 0xFF))
    }

    private func appendBE64(_ v: UInt64, into d: inout Data) {
        for i in (0..<8).reversed() {
            d.append(UInt8((v >> (UInt64(i) * 8)) & 0xFF))
        }
    }

    /// 构造一个最小 FAT_MAGIC（32-bit）二进制：
    ///   header: magic + nfat
    ///   fat_arch[0]: arm64,  offset=64, size=arm64Size
    ///   fat_arch[1]: x86_64, offset=64+arm64Size, size=x86Size
    ///   slice0: arm64 raw bytes（pattern 'A'）
    ///   slice1: x86_64 raw bytes（pattern 'X'）
    /// total bytes: 8 + 20*2 + arm64Size + x86Size
    private func makeFat32Fixture(arm64Size: Int, x86Size: Int) -> Data {
        var d = Data()
        appendBE32(FatMagic.magic32, into: &d)
        appendBE32(2, into: &d) // nfat = 2
        // fat_arch[0] arm64
        let off0: UInt32 = 64 // 头 8 + 2 个 fat_arch 共 40 = 48；用 64 对齐
        appendBE32(UInt32(bitPattern: CPUType.arm64), into: &d)
        appendBE32(0, into: &d) // subtype
        appendBE32(off0, into: &d)
        appendBE32(UInt32(arm64Size), into: &d)
        appendBE32(0, into: &d) // align
        // fat_arch[1] x86_64
        let off1 = off0 + UInt32(arm64Size)
        appendBE32(UInt32(bitPattern: CPUType.x86_64), into: &d)
        appendBE32(0, into: &d)
        appendBE32(off1, into: &d)
        appendBE32(UInt32(x86Size), into: &d)
        appendBE32(0, into: &d)
        // pad 到 off0
        while d.count < Int(off0) { d.append(0) }
        // slice 0: arm64 raw bytes
        d.append(Data(repeating: 0x41, count: arm64Size)) // 'A'
        // slice 1: x86 raw bytes
        d.append(Data(repeating: 0x58, count: x86Size))   // 'X'
        return d
    }

    // MARK: - 1. FAT_MAGIC 识别

    func test_FAT_magic识别正确_2架构() {
        let d = makeFat32Fixture(arm64Size: 100, x86Size: 80)
        let shape = FatHeader.parse(d)
        guard case .fat32(let arches) = shape else {
            return XCTFail("expected .fat32, got \(shape)")
        }
        XCTAssertEqual(arches.count, 2)
        XCTAssertEqual(arches[0].cputype, CPUType.arm64)
        XCTAssertEqual(arches[0].offset, 64)
        XCTAssertEqual(arches[0].size, 100)
        XCTAssertEqual(arches[1].cputype, CPUType.x86_64)
        XCTAssertEqual(arches[1].offset, 64 + 100)
        XCTAssertEqual(arches[1].size, 80)
    }

    // MARK: - 2. FAT_MAGIC_64

    func test_FAT_MAGIC_64识别_64bit_offset_size() {
        var d = Data()
        appendBE32(FatMagic.magic64, into: &d)
        appendBE32(1, into: &d) // 1 arch
        appendBE32(UInt32(bitPattern: CPUType.arm64), into: &d)
        appendBE32(0, into: &d) // subtype
        appendBE64(128, into: &d) // offset
        appendBE64(50000, into: &d) // size
        appendBE32(0, into: &d) // align
        appendBE32(0, into: &d) // reserved
        let shape = FatHeader.parse(d)
        guard case .fat64(let arches) = shape else {
            return XCTFail("expected .fat64, got \(shape)")
        }
        XCTAssertEqual(arches.count, 1)
        XCTAssertEqual(arches[0].cputype, CPUType.arm64)
        XCTAssertEqual(arches[0].offset, 128)
        XCTAssertEqual(arches[0].size, 50000)
    }

    // MARK: - 3. thin / 非 Mach-O

    func test_非fat_magic返回thin() {
        // thin Mach-O magic 0xFEEDFACE
        var d = Data()
        appendBE32(0xFEEDFACE, into: &d)
        appendBE32(0, into: &d)
        d.append(Data(repeating: 0, count: 32))
        let shape = FatHeader.parse(d)
        XCTAssertEqual(shape, .thin)
    }

    func test_文件太短返回notMachO() {
        let d = Data([0x01, 0x02])
        XCTAssertEqual(FatHeader.parse(d), .notMachO)
    }

    func test_坏nfat_arch_返回notMachO() {
        var d = Data()
        appendBE32(FatMagic.magic32, into: &d)
        appendBE32(9999, into: &d) // 异常 nfat
        XCTAssertEqual(FatHeader.parse(d), .notMachO)
    }

    // MARK: - 4. audit + savings

    func test_audit_2架构_savings等于x86切片大小() throws {
        let tmp = try makeTempDir("audit")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bin = tmp.appendingPathComponent("foo")
        let d = makeFat32Fixture(arm64Size: 1000, x86Size: 800)
        try d.write(to: bin)

        let engine = LipoEngine(targetCPUType: CPUType.arm64)
        let cand = engine.audit(at: bin.path)
        XCTAssertNotNil(cand)
        XCTAssertEqual(cand?.originalSize, UInt64(d.count))
        XCTAssertEqual(cand?.targetSlice?.size, 1000)
        // savings = total - arm64Size = (8 + 40 + 16 pad + 1000 + 800) - 1000 = 864
        XCTAssertEqual(cand?.savings, UInt64(d.count) - 1000)
    }

    func test_audit_目标架构不存在_savings为0() throws {
        let tmp = try makeTempDir("nomatch")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bin = tmp.appendingPathComponent("foo")
        // 构造仅 x86_64 的 FAT，但 fat 必须 nfat>=2 才有意义；这里造 1+1 异架构
        var d = Data()
        appendBE32(FatMagic.magic32, into: &d)
        appendBE32(2, into: &d)
        // arch0: 假装是某个未知 cputype（0x0BAD）
        appendBE32(0x0BAD, into: &d); appendBE32(0, into: &d)
        appendBE32(64, into: &d); appendBE32(100, into: &d); appendBE32(0, into: &d)
        // arch1: x86_64
        appendBE32(UInt32(bitPattern: CPUType.x86_64), into: &d); appendBE32(0, into: &d)
        appendBE32(64 + 100, into: &d); appendBE32(80, into: &d); appendBE32(0, into: &d)
        while d.count < 64 { d.append(0) }
        d.append(Data(repeating: 0x42, count: 100))
        d.append(Data(repeating: 0x58, count: 80))
        try d.write(to: bin)
        let engine = LipoEngine(targetCPUType: CPUType.arm64)
        let cand = engine.audit(at: bin.path)
        XCTAssertNotNil(cand, "FAT 文件应仍返候选项，savings 视具体计算")
        XCTAssertNil(cand?.targetSlice)
        XCTAssertEqual(cand?.savings, 0)
    }

    func test_audit_thin文件_返回nil_无瘦身() throws {
        let tmp = try makeTempDir("thin")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bin = tmp.appendingPathComponent("foo")
        var d = Data()
        appendBE32(0xFEEDFACE, into: &d)
        d.append(Data(repeating: 0, count: 200))
        try d.write(to: bin)
        let engine = LipoEngine()
        XCTAssertNil(engine.audit(at: bin.path))
    }

    // MARK: - 5. dryRun aggregate

    func test_dryRunSavings_累加多个候选() throws {
        let tmp = try makeTempDir("dryrun")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let b1 = tmp.appendingPathComponent("a")
        let b2 = tmp.appendingPathComponent("b")
        try makeFat32Fixture(arm64Size: 100, x86Size: 50).write(to: b1)
        try makeFat32Fixture(arm64Size: 200, x86Size: 70).write(to: b2)
        let engine = LipoEngine()
        let c1 = engine.audit(at: b1.path)!
        let c2 = engine.audit(at: b2.path)!
        let total = engine.dryRunSavings(for: [c1, c2])
        XCTAssertEqual(total, c1.savings + c2.savings)
        XCTAssertGreaterThan(total, 0)
    }

    func test_dryRun不写盘_文件大小不变() throws {
        let tmp = try makeTempDir("nopwrite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bin = tmp.appendingPathComponent("foo")
        let d = makeFat32Fixture(arm64Size: 500, x86Size: 300)
        try d.write(to: bin)
        let sizeBefore = (try FileManager.default.attributesOfItem(atPath: bin.path)[.size] as? NSNumber)?.uint64Value
        let engine = LipoEngine()
        _ = engine.audit(at: bin.path)
        _ = engine.dryRunSavings(for: [engine.audit(at: bin.path)!])
        let sizeAfter = (try FileManager.default.attributesOfItem(atPath: bin.path)[.size] as? NSNumber)?.uint64Value
        XCTAssertEqual(sizeBefore, sizeAfter, "dryRun 必须不写盘")
    }

    // MARK: - 6. extract 真实写盘

    func test_extract_仅保留arm64切片字节正确() throws {
        let tmp = try makeTempDir("extract")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bin = tmp.appendingPathComponent("foo")
        let arm64Size = 100
        let x86Size = 80
        let d = makeFat32Fixture(arm64Size: arm64Size, x86Size: x86Size)
        try d.write(to: bin)

        let engine = LipoEngine(targetCPUType: CPUType.arm64)
        let cand = engine.audit(at: bin.path)!
        XCTAssertEqual(cand.targetSlice?.size, UInt64(arm64Size))
        try engine.extract(cand)

        // 写盘后文件大小应等于 arm64 slice size
        let after = try Data(contentsOf: bin)
        XCTAssertEqual(after.count, arm64Size)
        // 字节内容：fixture 里 arm64 全是 0x41 'A'
        XCTAssertEqual(after, Data(repeating: 0x41, count: arm64Size))
    }

    func test_extract_目标架构缺失_抛错() throws {
        // 手工构造一个只含 x86_64 的 FAT，arm64 缺失场景
        let tmp = try makeTempDir("missing")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bin = tmp.appendingPathComponent("foo")
        var d = Data()
        appendBE32(FatMagic.magic32, into: &d)
        appendBE32(2, into: &d)
        appendBE32(0x0BAD, into: &d); appendBE32(0, into: &d)
        appendBE32(64, into: &d); appendBE32(100, into: &d); appendBE32(0, into: &d)
        appendBE32(UInt32(bitPattern: CPUType.x86_64), into: &d); appendBE32(0, into: &d)
        appendBE32(64 + 100, into: &d); appendBE32(80, into: &d); appendBE32(0, into: &d)
        while d.count < 64 { d.append(0) }
        d.append(Data(repeating: 0x42, count: 100))
        d.append(Data(repeating: 0x58, count: 80))
        try d.write(to: bin)
        let engine = LipoEngine(targetCPUType: CPUType.arm64)
        let cand = engine.audit(at: bin.path)!
        XCTAssertThrowsError(try engine.extract(cand)) { error in
            XCTAssertEqual(error as? LipoEngine.ExtractError, .targetSliceMissing)
        }
    }

    // MARK: - 7. auditBundle 递归

    func test_auditBundle_递归扫整个目录_汇总所有FAT() throws {
        let tmp = try makeTempDir("bundle")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // tmp/Contents/MacOS/foo + tmp/Contents/Frameworks/Bar.framework/Bar
        let macos = tmp.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try makeFat32Fixture(arm64Size: 100, x86Size: 50).write(to: macos.appendingPathComponent("foo"))
        let fw = tmp.appendingPathComponent("Contents/Frameworks/Bar.framework")
        try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
        try makeFat32Fixture(arm64Size: 200, x86Size: 70).write(to: fw.appendingPathComponent("Bar"))
        // 一个 thin 文件不进入候选
        var thin = Data()
        appendBE32(0xFEEDFACE, into: &thin); thin.append(Data(repeating: 0, count: 50))
        try thin.write(to: tmp.appendingPathComponent("ReadMe"))

        let engine = LipoEngine()
        let cands = engine.auditBundle(at: tmp.path)
        XCTAssertEqual(cands.count, 2, "应找到 2 个 FAT，thin 文件不算")
    }
}
