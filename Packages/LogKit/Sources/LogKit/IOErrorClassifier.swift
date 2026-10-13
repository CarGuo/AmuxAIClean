import Foundation

/// I/O 错误分类 —— Step 14 静默失败修复的核心枚举。
///
/// 用途：把 `try?` 吞掉的错误改成 do/catch 之后，调用方需要分情况上报：
/// - `.permissionDenied` → 暴露到 UI banner（"无法读取，请授予权限"）
/// - `.notFound` → 沉默到 AmuxLog.debug（路径不存在是常态，不打扰用户）
/// - `.other` → 走 AmuxLog.warning 不静默（编码错误 / IO 损坏 / 设备离线 等）
///
/// 这是一个**纯函数判定**，不持有状态，全平台可用。
public enum IOErrorKind: Sendable, Equatable {
    /// EACCES (POSIX 13) 或 NSCocoaErrorDomain.fileReadNoPermission (257)
    case permissionDenied
    /// ENOENT (POSIX 2) 或 NSCocoaErrorDomain.fileReadNoSuchFile (260)
    case notFound
    /// 其他错误（编码错误、IO 损坏、磁盘脱机等）
    case other
}

/// I/O 错误分类器 —— 把 NSError / POSIXError 归类成 IOErrorKind。
///
/// 设计原则：
/// 1. 只看 errno / NSCocoaErrorDomain 这两层最稳定的来源
/// 2. **永不 throw、永不 return nil** —— 任何 Error 都能映射到三类之一
/// 3. **纯静态、零依赖、Sendable**，可在任何 actor / 子进程边界内调用
public enum IOErrorClassifier {

    /// 把任意 Error 归类为 IOErrorKind。
    public static func classify(_ error: Error) -> IOErrorKind {
        let ns = error as NSError

        // 路径 1：CocoaError 域（FileManager / Data(contentsOf:) 抛出的常态）
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return .permissionDenied
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                return .notFound
            default:
                break
            }
            // CocoaError 内层 NSUnderlyingError 仍可能含 POSIX errno
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                return classify(underlying)
            }
        }

        // 路径 2：POSIX 域（POSIXErrorCode 直接 throw）
        if ns.domain == NSPOSIXErrorDomain {
            switch Int32(ns.code) {
            case EACCES, EPERM:
                return .permissionDenied
            case ENOENT:
                return .notFound
            default:
                return .other
            }
        }

        // 路径 3：Swift POSIXError 直接转 NSError（domain == NSPOSIXErrorDomain，
        // 已在路径 2 命中，这里兜底）
        if let posix = error as? POSIXError {
            switch posix.code {
            case .EACCES, .EPERM:
                return .permissionDenied
            case .ENOENT:
                return .notFound
            default:
                return .other
            }
        }

        return .other
    }
}
