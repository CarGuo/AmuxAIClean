import AppKit
import Foundation

/// v0 主链路：把文件移到废纸篓，不需要 root，不需要 Helper，不需要 Apple Developer Program。
///
/// **设计原则**（PITFALLS §5.9）：
/// - 走 [NSWorkspace.recycle](https://developer.apple.com/documentation/appkit/nsworkspace/1524800-recycle)：
///   - 用户可在 Finder 撤销
///   - 不调 unlink，可 100% 恢复
/// - dryRun=true 时只打印，不真动文件
/// - 任意一项失败都会被记入 skipped（不抛异常中断整批）
public final class TrashPipeline: DeletionPipeline, @unchecked Sendable {

    public init() {}

    public func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?) {
        guard !paths.isEmpty else { return (0, 0, nil) }

        if dryRun {
            var present = 0
            var missing = 0
            let fm = FileManager.default
            for p in paths {
                if fm.fileExists(atPath: p) { present += 1 } else { missing += 1 }
            }
            return (present, missing, missing > 0 ? "dryRun: \(missing) 路径不存在或无权限" : nil)
        }

        let urls = paths.map { URL(fileURLWithPath: $0) }

        return await withCheckedContinuation { (cc: CheckedContinuation<(Int, Int, String?), Never>) in
            let gate = TrashGate(cc: cc)
            // recycle 是 async 回调，且最后只回调一次（成功 trashedURLs 列出，失败给 error）
            NSWorkspace.shared.recycle(urls) { trashed, error in
                let movedCount = trashed.count
                let skipped = urls.count - movedCount
                if let error {
                    gate.fire((movedCount, skipped, "recycle-failed: \(error.localizedDescription)"))
                } else {
                    gate.fire((movedCount, skipped, nil))
                }
            }
        }
    }
}

/// recycle 回调可能在任意线程；用 OneShot 保证 cc 只 resume 一次。
private final class TrashGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let cc: CheckedContinuation<(Int, Int, String?), Never>

    init(cc: CheckedContinuation<(Int, Int, String?), Never>) {
        self.cc = cc
    }

    @discardableResult
    func fire(_ value: (Int, Int, String?)) -> Bool {
        lock.lock()
        if fired {
            lock.unlock()
            return false
        }
        fired = true
        lock.unlock()
        cc.resume(returning: value)
        return true
    }
}
