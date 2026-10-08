import Foundation
import Darwin

/// CACHEDIR.TAG 探测器（cache-directory-tagging.com 标准）。
///
/// 标准约定：目录里若存在名为 `CACHEDIR.TAG` 的文件，且其前 43 字节正好是
///   `Signature: 8a477f597d28d172789f06886806bc55`
/// 则该目录及全部子目录可被备份/扫描工具视为「纯缓存」整体跳过/标记。
///
/// 业界采用情况（截至 2026）：
/// - rustc / cargo target / build 目录默认写入；
/// - bazel-out、deno cache、pnpm store、Gradle build；
/// - macOS Time Machine、TimeShift、restic、duplicity、borgbackup 等备份工具默认尊重；
/// - Pearcleaner / OmniDS 等扫描器在 v5+ 加入识别。
///
/// 我们的策略：
/// 1. 命中后整棵目录视为 safe 候选（命中点本身仍 yield .node，但子目录不下钻）；
/// 2. 检测代价 = 一次 stat + 最多 43 字节读；命中后省下整棵子树的 enumerator 成本；
/// 3. 检测**不阻塞 enumerator 主路径**：失败/不存在静默 false，永不抛错。
///
/// 参考：
/// - https://bford.info/cachedir/  （规范作者 Brad Fitzpatrick / Bryan Ford 主页）
/// - https://www.cache-directory-tagging.com/  （已废弃域名，但 Wayback 可查）
/// - GNU tar `--exclude-caches-under` 文档
public enum CacheDirTag {

    /// 标准要求的前 43 字节签名（不含换行）。
    public static let signature: String = "Signature: 8a477f597d28d172789f06886806bc55"

    /// 标记文件名（区分大小写，由规范明确规定）。
    public static let fileName: String = "CACHEDIR.TAG"

    /// 检测目录是否包含合法 CACHEDIR.TAG 标记。
    ///
    /// - Parameter directoryPath: 待检测的目录绝对路径。
    /// - Returns: 命中合法 tag 时 `true`；其它情况（文件不存在、签名不匹配、读失败）`false`。
    ///
    /// 实现说明：
    /// - 用 POSIX `open + read` 而非 FileHandle，避开 NSFileHandle 在并发上下文里偶发的
    ///   ObjC 异常包装；
    /// - 仅读前 43 字节，即便文件后续内容是 GB 级也不会拖累；
    /// - 仅做精确字节比对（不做 UTF-8 normalize）—— 标准要求 byte-exact。
    public static func isCacheDirectory(at directoryPath: String) -> Bool {
        let tagPath = directoryPath + "/" + fileName
        let fd = Darwin.open(tagPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            return false
        }

        let expected = Array(signature.utf8)
        let need = expected.count
        var buf = [UInt8](repeating: 0, count: need)
        var totalRead = 0
        while totalRead < need {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: totalRead), need - totalRead)
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }   // EOF 不足 43 字节 / 读错
            totalRead += n
        }
        return buf == expected
    }
}
