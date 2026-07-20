import Darwin
import Foundation
import XCTest
@testable import ScanKit

final class BoundedLocalFileReaderTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func test_regularFileWithinLimitReturnsExactBytes() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("metadata.plist")
        let expected = Data("bounded metadata".utf8)
        try expected.write(to: file)

        XCTAssertEqual(
            try BoundedLocalFileReader.read(at: file, maximumBytes: expected.count),
            expected
        )
    }

    func test_intMaxLimitDoesNotOverflowLimitProbeArithmetic() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("metadata.plist")
        let expected = Data("small metadata".utf8)
        try expected.write(to: file)

        XCTAssertEqual(
            try BoundedLocalFileReader.read(at: file, maximumBytes: .max),
            expected
        )
    }

    func test_oversizeFileFailsBeforeMaterializingContents() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("oversize.json")
        try Data(repeating: 0x61, count: 9).write(to: file)

        XCTAssertThrowsError(try BoundedLocalFileReader.read(at: file, maximumBytes: 8)) {
            XCTAssertEqual(
                $0 as? BoundedLocalFileReadError,
                .tooLarge(limit: 8, observedSize: 9)
            )
        }
    }

    func test_finalComponentSymlinkIsRejectedWithoutFollowingTarget() throws {
        let directory = try makeTemporaryDirectory()
        let target = directory.appendingPathComponent("target")
        let link = directory.appendingPathComponent("metadata")
        try Data("secret".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try BoundedLocalFileReader.read(at: link)) {
            XCTAssertEqual(
                $0 as? BoundedLocalFileReadError,
                .unsafeType(.symbolicLink)
            )
        }
    }

    func test_stableParentSymlinkUsesNormalPOSIXResolution() throws {
        let directory = try makeTemporaryDirectory()
        let actualParent = directory.appendingPathComponent("actual", isDirectory: true)
        let linkedParent = directory.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(
            at: actualParent,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: linkedParent,
            withDestinationURL: actualParent
        )
        let expected = Data("bounded".utf8)
        try expected.write(to: actualParent.appendingPathComponent("metadata"))

        XCTAssertEqual(
            try BoundedLocalFileReader.read(at: linkedParent.appendingPathComponent("metadata")),
            expected
        )
    }

    func test_nonRegularFileIsRejected() throws {
        let directory = try makeTemporaryDirectory()

        XCTAssertThrowsError(try BoundedLocalFileReader.read(at: directory)) {
            XCTAssertEqual(
                $0 as? BoundedLocalFileReadError,
                .unsafeType(.directory)
            )
        }
    }

    func test_pathReplacementBeforeTerminalValidationFailsChanged() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("metadata")
        let displaced = directory.appendingPathComponent("metadata.original")
        try Data("first".utf8).write(to: file)

        XCTAssertThrowsError(try BoundedLocalFileReader.read(
            at: file,
            maximumBytes: 64,
            shouldCancel: { false },
            testHook: { phase in
                guard phase == .beforeFinalValidation else { return }
                try FileManager.default.moveItem(at: file, to: displaced)
                try Data("other".utf8).write(to: file)
            }
        )) {
            XCTAssertEqual($0 as? BoundedLocalFileReadError, .changed)
        }
    }

    func test_regularFileReplacedByFIFOIsRejectedWithoutBlockingInOpen() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("metadata")
        try Data("first".utf8).write(to: file)

        XCTAssertThrowsError(try BoundedLocalFileReader.read(
            at: file,
            maximumBytes: 64,
            shouldCancel: { false },
            testHook: { phase in
                guard phase == .afterInitialMetadata else { return }
                try FileManager.default.removeItem(at: file)
                let result = file.withUnsafeFileSystemRepresentation { path -> Int32 in
                    guard let path else { return -1 }
                    return Darwin.mkfifo(path, S_IRUSR | S_IWUSR)
                }
                guard result == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        )) {
            XCTAssertEqual($0 as? BoundedLocalFileReadError, .unsafeType(.other))
        }
    }

    func test_cancellationIsCheckedBetweenReadChunks() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("metadata")
        try Data(repeating: 0x61, count: 512 * 1_024).write(to: file)
        let probe = CancellationProbe(cancelOnCheck: 4)

        XCTAssertThrowsError(try BoundedLocalFileReader.read(
            at: file,
            maximumBytes: 512 * 1_024,
            shouldCancel: { probe.shouldCancel() }
        )) {
            XCTAssertEqual($0 as? BoundedLocalFileReadError, .cancelled)
        }
        XCTAssertGreaterThanOrEqual(probe.checkCount, 4)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoundedLocalFileReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelOnCheck: Int
    private var checks = 0

    init(cancelOnCheck: Int) {
        self.cancelOnCheck = cancelOnCheck
    }

    var checkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return checks
    }

    func shouldCancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        checks += 1
        return checks >= cancelOnCheck
    }
}
