import XCTest
@testable import LogKit

/// IOErrorClassifier —— Step 14 错误分类器单元测试。
///
/// 验证三大不变量：
/// 1. CocoaError fileReadNoPermission / fileWriteNoPermission → `.permissionDenied`
/// 2. CocoaError fileReadNoSuchFile / fileNoSuchFile → `.notFound`
/// 3. POSIX EACCES / EPERM / ENOENT 直接命中相应 kind
/// 4. NSUnderlyingErrorKey 嵌套时递归剥离
final class IOErrorClassifierTests: XCTestCase {

    // MARK: - Cocoa 域

    func test_classify_CocoaFileReadNoPermission归类为permissionDenied() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        XCTAssertEqual(IOErrorClassifier.classify(err), .permissionDenied)
    }

    func test_classify_CocoaFileWriteNoPermission归类为permissionDenied() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        XCTAssertEqual(IOErrorClassifier.classify(err), .permissionDenied)
    }

    func test_classify_CocoaFileReadNoSuchFile归类为notFound() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        XCTAssertEqual(IOErrorClassifier.classify(err), .notFound)
    }

    func test_classify_CocoaFileNoSuchFile归类为notFound() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        XCTAssertEqual(IOErrorClassifier.classify(err), .notFound)
    }

    func test_classify_其他Cocoa错误归类为other() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)
        XCTAssertEqual(IOErrorClassifier.classify(err), .other)
    }

    // MARK: - POSIX 域

    func test_classify_POSIX_EACCES归类为permissionDenied() {
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        XCTAssertEqual(IOErrorClassifier.classify(err), .permissionDenied)
    }

    func test_classify_POSIX_EPERM归类为permissionDenied() {
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        XCTAssertEqual(IOErrorClassifier.classify(err), .permissionDenied)
    }

    func test_classify_POSIX_ENOENT归类为notFound() {
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        XCTAssertEqual(IOErrorClassifier.classify(err), .notFound)
    }

    func test_classify_POSIX_EIO归类为other() {
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        XCTAssertEqual(IOErrorClassifier.classify(err), .other)
    }

    // MARK: - 嵌套 underlying error 递归剥离

    func test_classify_Cocoa外层包装POSIX_EACCES应递归命中permissionDenied() {
        let inner = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        // 用 NSCocoaErrorDomain 但 code 不是 file 类，把真正错误塞 underlying
        let outer = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadUnknownError,
            userInfo: [NSUnderlyingErrorKey: inner]
        )
        XCTAssertEqual(IOErrorClassifier.classify(outer), .permissionDenied)
    }

    // MARK: - 默认兜底

    func test_classify_完全未知域归类为other() {
        let err = NSError(domain: "com.example.weird", code: 9999)
        XCTAssertEqual(IOErrorClassifier.classify(err), .other)
    }
}
