import Darwin
import Foundation
import ScanKit

enum PermissionDenialClassifier {
    static func filesystemBlockedPaths(in paths: [String],
                                       fdaStatus: FDAProbe.Status) -> [String] {
        guard fdaStatus == .granted else { return [] }
        return paths.filter(isFilesystemBlocked)
    }

    static func isFilesystemBlocked(_ path: String) -> Bool {
        var sb = stat()
        guard lstat(path, &sb) == 0 else { return false }
        guard (sb.st_mode & S_IFMT) == S_IFDIR else { return false }

        let mode = sb.st_mode
        let uid = geteuid()
        let groups = currentGroupIDs()

        let canReadAndEnter: Bool
        if uid == sb.st_uid {
            canReadAndEnter = has(mode, S_IRUSR) && has(mode, S_IXUSR)
        } else if groups.contains(sb.st_gid) {
            canReadAndEnter = has(mode, S_IRGRP) && has(mode, S_IXGRP)
        } else {
            canReadAndEnter = has(mode, S_IROTH) && has(mode, S_IXOTH)
        }
        return !canReadAndEnter
    }

    private static func has(_ mode: mode_t, _ bit: mode_t) -> Bool {
        (mode & bit) != 0
    }

    private static func currentGroupIDs() -> Set<gid_t> {
        var result: Set<gid_t> = [getegid()]
        let count = getgroups(0, nil)
        guard count > 0 else { return result }
        var groups = [gid_t](repeating: 0, count: Int(count))
        let actual = getgroups(count, &groups)
        guard actual > 0 else { return result }
        result.formUnion(groups.prefix(Int(actual)))
        return result
    }
}
