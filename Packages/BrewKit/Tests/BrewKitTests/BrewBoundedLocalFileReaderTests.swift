import Darwin
import Foundation
import XCTest
@testable import BrewKit

final class BrewBoundedLocalFileReaderTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func test_oversizeIsTypedBeforeRead() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("registry.json")
        try Data(repeating: 0x61, count: 9).write(to: file)

        XCTAssertThrowsError(try BrewBoundedLocalFileReader.read(
            at: file,
            maximumBytes: 8
        )) {
            XCTAssertEqual(
                $0 as? BrewBoundedLocalFileReadError,
                .tooLarge(limit: 8, observedSize: 9)
            )
        }
    }

    func test_intMaxLimitDoesNotOverflowLimitProbeArithmetic() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("registry.json")
        let expected = Data("small registry".utf8)
        try expected.write(to: file)

        XCTAssertEqual(
            try BrewBoundedLocalFileReader.read(at: file, maximumBytes: .max),
            expected
        )
    }

    func test_symlinkAndNonRegularInputsAreRejected() throws {
        let directory = try makeTemporaryDirectory()
        let target = directory.appendingPathComponent("target")
        let link = directory.appendingPathComponent("link")
        try Data("payload".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try BrewBoundedLocalFileReader.read(
            at: link,
            maximumBytes: 64
        )) {
            XCTAssertEqual($0 as? BrewBoundedLocalFileReadError, .unsafeType(.symbolicLink))
        }
        XCTAssertThrowsError(try BrewBoundedLocalFileReader.read(
            at: directory,
            maximumBytes: 64
        )) {
            XCTAssertEqual($0 as? BrewBoundedLocalFileReadError, .unsafeType(.directory))
        }
    }

    func test_pathReplacementBeforeFinalValidationIsChanged() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("receipt.json")
        let displaced = directory.appendingPathComponent("receipt.old")
        try Data("first".utf8).write(to: file)

        XCTAssertThrowsError(try BrewBoundedLocalFileReader.read(
            at: file,
            maximumBytes: 64,
            shouldCancel: { false },
            testHook: { phase in
                guard phase == .beforeFinalValidation else { return }
                try FileManager.default.moveItem(at: file, to: displaced)
                try Data("other".utf8).write(to: file)
            }
        )) {
            XCTAssertEqual($0 as? BrewBoundedLocalFileReadError, .changed)
        }
    }

    func test_unlinkAfterInitialMetadataIsOpenFailureNotNormalMissing() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("receipt.json")
        try Data("first".utf8).write(to: file)

        XCTAssertThrowsError(try BrewBoundedLocalFileReader.read(
            at: file,
            maximumBytes: 64,
            shouldCancel: { false },
            testHook: { phase in
                guard phase == .afterInitialMetadata else { return }
                try FileManager.default.removeItem(at: file)
            }
        )) {
            XCTAssertEqual(
                $0 as? BrewBoundedLocalFileReadError,
                .openFailed(posixErrorCode: ENOENT)
            )
        }
    }

    func test_unlinkBeforeFinalValidationFailsChangedAndNeverMissing() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("receipt.json")
        try Data("first".utf8).write(to: file)

        XCTAssertThrowsError(try BrewBoundedLocalFileReader.read(
            at: file,
            maximumBytes: 64,
            shouldCancel: { false },
            testHook: { phase in
                guard phase == .beforeFinalValidation else { return }
                try FileManager.default.removeItem(at: file)
            }
        )) {
            // unlink updates the opened inode's ctime, so descriptor version proof rejects it
            // before the final pathname lookup. Either way it can never become normal missing.
            XCTAssertEqual($0 as? BrewBoundedLocalFileReadError, .changed)
        }
    }

    func test_parentPathRemovalBeforeFinalValidationCarriesFinalPathStage() throws {
        let directory = try makeTemporaryDirectory()
        let parent = directory.appendingPathComponent("current", isDirectory: true)
        let displaced = directory.appendingPathComponent("displaced", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let file = parent.appendingPathComponent("receipt.json")
        try Data("first".utf8).write(to: file)

        XCTAssertThrowsError(try BrewBoundedLocalFileReader.read(
            at: file,
            maximumBytes: 64,
            shouldCancel: { false },
            testHook: { phase in
                guard phase == .beforeFinalValidation else { return }
                try FileManager.default.moveItem(at: parent, to: displaced)
            }
        )) {
            XCTAssertEqual(
                $0 as? BrewBoundedLocalFileReadError,
                .metadataUnavailable(stage: .finalPath, posixErrorCode: ENOENT)
            )
        }
    }

    func test_onlyInitialPathENOENTIsNormalMissing() {
        let initialMissing = BrewFileReader(read: { _ in
            throw BrewBoundedLocalFileReadError.metadataUnavailable(
                stage: .initialPath,
                posixErrorCode: ENOENT
            )
        })
        let removedDuringOpen = BrewFileReader(read: { _ in
            throw BrewBoundedLocalFileReadError.openFailed(posixErrorCode: ENOENT)
        })
        let removedBeforeFinalPath = BrewFileReader(read: { _ in
            throw BrewBoundedLocalFileReadError.metadataUnavailable(
                stage: .finalPath,
                posixErrorCode: ENOENT
            )
        })
        let url = URL(fileURLWithPath: "/tmp/receipt.json")

        guard case .missing = readBrewLocalFile(
            at: url,
            source: .installReceipt,
            reader: initialMissing
        ) else {
            return XCTFail("initial ENOENT must remain normal optional-file absence")
        }
        for reader in [removedDuringOpen, removedBeforeFinalPath] {
            guard case .failure(let diagnostic) = readBrewLocalFile(
                at: url,
                source: .installReceipt,
                reader: reader
            ) else {
                XCTFail("post-initial ENOENT must not be collapsed into missing")
                continue
            }
            XCTAssertEqual(diagnostic.reason, .changed)
        }
    }

    func test_regularFileReplacedByFIFOIsRejectedWithoutBlockingInOpen() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("receipt.json")
        try Data("first".utf8).write(to: file)

        XCTAssertThrowsError(try BrewBoundedLocalFileReader.read(
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
            XCTAssertEqual($0 as? BrewBoundedLocalFileReadError, .unsafeType(.other))
        }
    }

    func test_cancellationIsObservedBetweenChunks() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("registry.json")
        try Data(repeating: 0x61, count: 512 * 1_024).write(to: file)
        let probe = BrewCancellationProbe(cancelOnCheck: 4)

        XCTAssertThrowsError(try BrewBoundedLocalFileReader.read(
            at: file,
            maximumBytes: 512 * 1_024,
            shouldCancel: { probe.shouldCancel() }
        )) {
            XCTAssertEqual($0 as? BrewBoundedLocalFileReadError, .cancelled)
        }
        XCTAssertGreaterThanOrEqual(probe.checkCount, 4)
    }

    func test_liveReaderMapsUnsafeAndOversizeToClosedDiagnostics() throws {
        let directory = try makeTemporaryDirectory()
        let receipt = directory.appendingPathComponent("INSTALL_RECEIPT.json")
        try Data().write(to: receipt)
        let handle = try FileHandle(forWritingTo: receipt)
        try handle.truncate(atOffset: UInt64(
            BrewLocalFileLimits.maximumBytes(for: .installReceipt) + 1
        ))
        try handle.close()

        guard case .failure(let diagnostic) = readBrewLocalFile(
            at: receipt,
            source: .installReceipt,
            reader: .live
        ) else {
            return XCTFail("oversize receipt must be a typed failure")
        }
        XCTAssertEqual(diagnostic.reason, .tooLarge)
        XCTAssertEqual(diagnostic.stage, .read)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrewBoundedLocalFileReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}

private final class BrewCancellationProbe: @unchecked Sendable {
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
