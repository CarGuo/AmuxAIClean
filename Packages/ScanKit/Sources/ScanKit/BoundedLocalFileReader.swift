import Darwin
import Foundation

/// A bounded reader that refuses a symbolic link at the final path component.
///
/// v2026.07.18: `Data(contentsOf:)` made small plist/JSON inputs an unbounded and effectively
/// uncancellable filesystem producer. This boundary admits only one regular file, freezes its
/// identity and size before reading, checks cancellation between chunks, and proves the same
/// pathname/object/size again before returning bytes to a parser. Parent path components retain
/// normal POSIX symlink resolution; callers that require a root-confined/all-component no-follow
/// contract must use descriptor-relative traversal instead.
public enum BoundedLocalFileReadError: Error, Sendable, Equatable {
    public enum FileKind: String, Sendable, Equatable {
        case directory
        case symbolicLink = "symbolic-link"
        case other
    }

    public enum MetadataStage: String, Sendable, Equatable {
        case initialPath = "initial-path"
        case openedFile = "opened-file"
        case finalFile = "final-file"
        case finalPath = "final-path"
    }

    case invalidFileURL
    case metadataUnavailable(stage: MetadataStage, posixErrorCode: Int32)
    case openFailed(posixErrorCode: Int32)
    case readFailed(posixErrorCode: Int32)
    case tooLarge(limit: Int, observedSize: Int64)
    case unsafeType(FileKind)
    case changed
    case cancelled

    public var posixErrorCode: Int32? {
        switch self {
        case .metadataUnavailable(_, let code), .openFailed(let code), .readFailed(let code):
            return code
        case .invalidFileURL, .tooLarge, .unsafeType, .changed, .cancelled:
            return nil
        }
    }
}

public enum BoundedLocalFileReader {
    /// Structured metadata in this project is expected to be measured in KiB. Sixteen MiB leaves
    /// generous room for real-world plists/JWS envelopes while providing a hard memory boundary.
    public static let defaultMaximumBytes = 16 * 1_024 * 1_024
    private static let chunkBytes = 64 * 1_024

    enum TestPhase: Sendable, Equatable {
        case afterInitialMetadata
        case afterOpen
        case beforeFinalValidation
    }

    public static func read(
        at url: URL,
        maximumBytes: Int = defaultMaximumBytes,
        shouldCancel: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> Data {
        try read(
            at: url,
            maximumBytes: maximumBytes,
            shouldCancel: shouldCancel,
            testHook: nil
        )
    }

    static func read(
        at url: URL,
        maximumBytes: Int,
        shouldCancel: @Sendable () -> Bool,
        testHook: ((TestPhase) throws -> Void)?
    ) throws -> Data {
        guard url.isFileURL, maximumBytes >= 0 else {
            throw BoundedLocalFileReadError.invalidFileURL
        }
        try checkCancellation(shouldCancel)

        let initial = try pathSnapshot(
            at: url,
            stage: .initialPath
        )
        guard initial.fileType == UInt16(S_IFREG) else {
            throw BoundedLocalFileReadError.unsafeType(fileKind(initial.fileType))
        }
        try validateSize(initial.size, maximumBytes: maximumBytes)
        try testHook?(.afterInitialMetadata)
        try checkCancellation(shouldCancel)

        var openError = Int32(EINVAL)
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            // v2026.07.18: O_NONBLOCK closes the lstat/open race where a regular file could be
            // replaced by a FIFO and otherwise block forever before fstat rejects its type.
            let result = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if result < 0 { openError = errno }
            return result
        }
        guard descriptor >= 0 else {
            throw BoundedLocalFileReadError.openFailed(posixErrorCode: openError)
        }
        defer { close(descriptor) }

        let opened = try descriptorSnapshot(
            descriptor,
            stage: .openedFile
        )
        guard opened.fileType == UInt16(S_IFREG) else {
            throw BoundedLocalFileReadError.unsafeType(fileKind(opened.fileType))
        }
        guard opened.sameIdentity(as: initial), opened.sameVersion(as: initial) else {
            throw BoundedLocalFileReadError.changed
        }
        try validateSize(opened.size, maximumBytes: maximumBytes)
        try testHook?(.afterOpen)

        var data = Data()
        data.reserveCapacity(Int(opened.size))
        // Read one byte beyond small limits so growth cannot masquerade as EOF, without ever
        // evaluating `Int.max + 1` for this public API.
        let bufferCapacity = maximumBytes < chunkBytes ? maximumBytes + 1 : chunkBytes
        var buffer = [UInt8](repeating: 0, count: bufferCapacity)
        while true {
            try checkCancellation(shouldCancel)
            let remaining = maximumBytes - data.count
            let requested = remaining < buffer.count ? remaining + 1 : buffer.count
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requested)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw BoundedLocalFileReadError.readFailed(posixErrorCode: errno)
            }
            let nextCount = data.count.addingReportingOverflow(count)
            guard !nextCount.overflow, nextCount.partialValue <= maximumBytes else {
                throw BoundedLocalFileReadError.tooLarge(
                    limit: maximumBytes,
                    observedSize: firstObservedSizeBeyond(maximumBytes)
                )
            }
            data.append(buffer, count: count)
        }

        try testHook?(.beforeFinalValidation)
        try checkCancellation(shouldCancel)
        let finalFile = try descriptorSnapshot(
            descriptor,
            stage: .finalFile
        )
        guard finalFile.sameIdentity(as: opened), finalFile.sameVersion(as: opened) else {
            throw BoundedLocalFileReadError.changed
        }
        try validateSize(finalFile.size, maximumBytes: maximumBytes)
        guard finalFile.size == Int64(data.count) else {
            throw BoundedLocalFileReadError.changed
        }

        let finalPath = try pathSnapshot(
            at: url,
            stage: .finalPath
        )
        guard finalPath.fileType == UInt16(S_IFREG),
              finalPath.sameIdentity(as: finalFile),
              finalPath.sameVersion(as: finalFile) else {
            throw BoundedLocalFileReadError.changed
        }
        return data
    }

    private struct Snapshot {
        let device: UInt64
        let inode: UInt64
        let fileType: UInt16
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64

        init(_ metadata: stat) {
            device = UInt64(bitPattern: Int64(metadata.st_dev))
            inode = UInt64(metadata.st_ino)
            fileType = UInt16(metadata.st_mode & S_IFMT)
            size = Int64(metadata.st_size)
            modificationSeconds = Int64(metadata.st_mtimespec.tv_sec)
            modificationNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
            changeSeconds = Int64(metadata.st_ctimespec.tv_sec)
            changeNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
        }

        func sameIdentity(as other: Snapshot) -> Bool {
            device == other.device && inode == other.inode && fileType == other.fileType
        }

        func sameVersion(as other: Snapshot) -> Bool {
            size == other.size
                && modificationSeconds == other.modificationSeconds
                && modificationNanoseconds == other.modificationNanoseconds
                && changeSeconds == other.changeSeconds
                && changeNanoseconds == other.changeNanoseconds
        }
    }

    private static func pathSnapshot(
        at url: URL,
        stage: BoundedLocalFileReadError.MetadataStage
    ) throws -> Snapshot {
        var metadata = stat()
        var failureCode = Int32(EINVAL)
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            let status = lstat(path, &metadata)
            if status != 0 { failureCode = errno }
            return status
        }
        guard result == 0 else {
            throw BoundedLocalFileReadError.metadataUnavailable(
                stage: stage,
                posixErrorCode: failureCode
            )
        }
        return Snapshot(metadata)
    }

    private static func descriptorSnapshot(
        _ descriptor: Int32,
        stage: BoundedLocalFileReadError.MetadataStage
    ) throws -> Snapshot {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw BoundedLocalFileReadError.metadataUnavailable(
                stage: stage,
                posixErrorCode: errno
            )
        }
        return Snapshot(metadata)
    }

    private static func validateSize(_ size: Int64, maximumBytes: Int) throws {
        guard size >= 0 else {
            throw BoundedLocalFileReadError.changed
        }
        guard size <= Int64(maximumBytes) else {
            throw BoundedLocalFileReadError.tooLarge(
                limit: maximumBytes,
                observedSize: size
            )
        }
    }

    private static func firstObservedSizeBeyond(_ maximumBytes: Int) -> Int64 {
        let limit = Int64(maximumBytes)
        return limit == Int64.max ? Int64.max : limit + 1
    }

    private static func fileKind(_ fileType: UInt16) -> BoundedLocalFileReadError.FileKind {
        switch fileType {
        case UInt16(S_IFDIR): return .directory
        case UInt16(S_IFLNK): return .symbolicLink
        default: return .other
        }
    }

    private static func checkCancellation(_ shouldCancel: @Sendable () -> Bool) throws {
        if shouldCancel() {
            throw BoundedLocalFileReadError.cancelled
        }
    }
}
