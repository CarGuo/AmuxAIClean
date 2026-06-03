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
/// **探针选择**：`~/Library/Mail` 的 mode 是 `0o700`。仅 `open(path, O_RDONLY)`
/// 拿一个目录 fd 在很多 macOS 版本下并不会真正触发 TCC 校验——这是 1.5.x 系列被
/// 用户反馈"已授权 + 重启仍报 denied"的根因：进程拿到了 fd 但从未"实质性读取"，
/// 系统也就没机会返回正确状态，老逻辑根据 fd 是否 >= 0 误判，反而在很多机器上稳定
/// 返回 granted 或 denied 取决于内核版本。
///
/// **修复（v1.5.3）**：改用 `FileManager.contentsOfDirectory(atPath:)`——这是
/// CleanMyMac / DaisyDisk / OmniDS 都在用的"真探针"，会真正进 readdir 系统调用，
/// TCC 守护必须在此时给出一个明确答复（granted 时返回条目数组；denied 时抛
/// `NSCocoaErrorDomain 257 / fileReadNoPermissionError`）。
///
/// **不要**用 `/Library/Application Support/com.apple.TCC/TCC.db` 当探针——
/// 那个文件**任何 App 都读不动**（只有特殊 entitlement，不是 FDA），永远返回 false。
public enum FDAProbe {

    /// 探测结果。`unknown` 表示探针文件不存在（用户从没用过 Mail.app），
    /// 此时**保持保守 skip 行为**最安全，banner 仍会显示。
    public enum Status: String, Sendable, Equatable {
        case granted
        case denied
        case unknown
    }

    /// 同步探测当前进程的 FDA 状态。可在任意线程调用，开销 ~毫秒级（一次 readdir）。
    public static func probe(home: String = NSHomeDirectory()) -> Status {
        // 探针 1：`~/Library/Mail`（绝大多数 Mac 用户都用过 Mail.app 至少一次，存在）
        let mailPath = "\(home)/Library/Mail"
        if FileManager.default.fileExists(atPath: mailPath) {
            return tryRead(mailPath)
        }

        // 探针 2：`~/Library/Safari`（fallback，几乎所有 Mac 都有）
        let safariPath = "\(home)/Library/Safari"
        if FileManager.default.fileExists(atPath: safariPath) {
            return tryRead(safariPath)
        }

        // 探针 3：`~/Library/Messages`（再 fallback）
        let messagesPath = "\(home)/Library/Messages"
        if FileManager.default.fileExists(atPath: messagesPath) {
            return tryRead(messagesPath)
        }

        // 三个探针都不存在：用户从没用过 Mail/Safari/Messages，只能算未知。
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
