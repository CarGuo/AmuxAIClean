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
/// **探针选择**：`~/Library/Mail` 的 mode 是 `0o700`，即便没有 FDA 也能 stat 元数据，
/// 但 `open(path, O_RDONLY)` 在没有 FDA 时会返回 EPERM/EACCES（macOS Sequoia 起进一步
/// 严格化）。我们试 open 它的目录 fd，成功立即 close 不读内容；失败按未授权处理。
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

    /// 同步探测当前进程的 FDA 状态。可在任意线程调用，开销 ~微秒级（一次 open + close）。
    public static func probe(home: String = NSHomeDirectory()) -> Status {
        // 探针 1：`~/Library/Mail`（绝大多数 Mac 用户都用过 Mail.app 至少一次，存在）
        let mailPath = "\(home)/Library/Mail"
        if FileManager.default.fileExists(atPath: mailPath) {
            return tryOpen(mailPath)
        }

        // 探针 2：`~/Library/Safari`（fallback，几乎所有 Mac 都有）
        let safariPath = "\(home)/Library/Safari"
        if FileManager.default.fileExists(atPath: safariPath) {
            return tryOpen(safariPath)
        }

        // 探针 3：`~/Library/Messages`（再 fallback）
        let messagesPath = "\(home)/Library/Messages"
        if FileManager.default.fileExists(atPath: messagesPath) {
            return tryOpen(messagesPath)
        }

        // 三个探针都不存在：用户从没用过 Mail/Safari/Messages，只能算未知。
        return .unknown
    }

    private static func tryOpen(_ path: String) -> Status {
        let fd = open(path, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return .granted
        }
        // EPERM = 1 / EACCES = 13 都是 FDA 缺失的典型 errno
        // 其他 errno（ENOENT 等）也按未授权处理，反正进入硬 skip 是安全的
        return .denied
    }
}
