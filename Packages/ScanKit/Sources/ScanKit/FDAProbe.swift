import Foundation

/// v1.3：探测当前进程是否已被授予 **完全磁盘访问 (Full Disk Access, FDA)** 权限。
///
/// 背景：[TCCSkipList](TCCSkipList.swift) 是"硬编码 skip 列表"——无论用户授没授权，
/// 扫描器都不下钻 Mail/Messages/Photos 等敏感目录，源头杜绝系统弹窗。这在用户**没**
/// 授权时是必要的（避免一次扫描弹十次 prompt），但在用户**已经手动授予 FDA** 之后，
/// 这套硬 skip 反而会让 banner 永远显示"权限受阻 N 项"——明明用户已经授权了。
///
/// 业界做法：CleanMyMac / DaisyDisk 启动时 silently 试读一个**只有 FDA 才能开**的
/// 探针文件，成功 = 已授权，失败 = 未授权。我们采用同样思路。
///
/// **探针选择**：`~/Library/Mail`、`~/Library/Safari`、`~/Library/Messages`
/// 都是常见 TCC 守卫目录。不要只看第一个存在的目录：某个目录可能因为账户状态、
/// 数据迁移或更细粒度 TCC 状态返回权限错误，但另一个探针能读通；此时把整个 FDA
/// 判成 denied 会制造"我明明授权了，App 仍提示未授权"的误报。
///
/// **修复（v1.5.3）**：改用 `FileManager.contentsOfDirectory(atPath:)`——这是
/// CleanMyMac / DaisyDisk / OmniDS 都在用的"真探针"，会真正进 readdir 系统调用，
/// TCC 守护必须在此时给出一个明确答复（granted 时返回条目数组；denied 时抛
/// `NSCocoaErrorDomain 257 / fileReadNoPermissionError`）。v1.7 起改为多探针：
/// 任一探针读通即判 granted；只有没有任何探针读通且至少一个探针明确 denied 时，
/// 才判 denied。
///
/// **不要**用 `/Library/Application Support/com.apple.TCC/TCC.db` 当探针——
/// 那个文件**任何 App 都读不动**（只有特殊 entitlement，不是 FDA），永远返回 false。
public enum FDAProbe {

    /// 探测结果。`unknown` 表示没有可用探针或探针只返回非权限类 IO 错误，
    /// 此时交给扫描期真实 errno/skip 事件决定是否展示 banner。
    public enum Status: String, Sendable, Equatable {
        case granted
        case denied
        case unknown
    }

    /// 同步探测当前进程的 FDA 状态。可在任意线程调用，开销 ~毫秒级（一次 readdir）。
    public static func probe(home: String = NSHomeDirectory()) -> Status {
        let probePaths = [
            "\(home)/Library/Mail",
            "\(home)/Library/Safari",
            "\(home)/Library/Messages"
        ]

        var sawDenied = false

        for path in probePaths where FileManager.default.fileExists(atPath: path) {
            switch tryRead(path) {
            case .granted:
                // One real TCC-protected directory was readable by this process. Treat FDA as
                // usable and let later scan errors surface as path-specific denials.
                return .granted
            case .denied:
                sawDenied = true
            case .unknown:
                continue
            }
        }

        if sawDenied {
            return .denied
        }
        return .unknown
    }

    /// **v1.5.3**：用 `contentsOfDirectory` 实际读一次目录。这是 TCC 真正会校验
    /// 的系统调用——`open(O_RDONLY)` 拿 fd 在不少 macOS 版本下不触发 TCC，
    /// 导致老逻辑稳定误判（用户表现：开关打开 + 重启依旧 denied）。
    ///
    /// 错误归类：
    /// - `NSCocoaErrorDomain 257`（fileReadNoPermissionError） → 明确 denied（FDA 没开）
    /// - 其他 IO error / POSIX EPERM(1) / EACCES(13) → denied（保守）
    /// - 抛 ENOENT 等 → unknown（路径异常，按"不强行 skip"处理交给上层兜底）
    /// - 成功返回任意数组（含空数组）→ granted（空目录也算可见）
    private static func tryRead(_ path: String) -> Status {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: path)
            return .granted
        } catch let err as NSError {
            // Cocoa 层 257 = fileReadNoPermissionError，FDA 缺失最典型的报错码。
            if err.domain == NSCocoaErrorDomain && err.code == 257 {
                return .denied
            }
            // POSIX 层 EPERM/EACCES 也按 denied
            if err.domain == NSPOSIXErrorDomain {
                if err.code == 1 /* EPERM */ || err.code == 13 /* EACCES */ {
                    return .denied
                }
            }
            // 其他 IO 错误（ENOENT/ENOTDIR 等）：路径异常，归 unknown。
            return .unknown
        }
    }
}
