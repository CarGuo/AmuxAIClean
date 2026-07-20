import Foundation
import XCTest
@testable import ScanKit

final class ScanFailureDiagnosticTests: XCTestCase {
    /// 自定义 provider 可以控制 Error 的三条文字通道以及 NSError domain；测试故意把
    /// 路径和正文放进每条通道，锁定共享诊断边界不会因未来重新插值 Error 而回归。
    private struct MaliciousProviderError: Error, CustomNSError, LocalizedError, CustomStringConvertible {
        static let errorDomain = "/Users/private/SecretProject/provider-response-body"

        var errorCode: Int { 73_319 }

        var errorUserInfo: [String: Any] {
            [NSLocalizedDescriptionKey: "userInfo secret token=alpha /Users/private/Secret.plist"]
        }

        var errorDescription: String? {
            "localized secret token=beta /Users/private/Secret.plist"
        }

        var description: String {
            "description secret token=gamma /Users/private/Secret.plist"
        }
    }

    func test_customError_只保留闭集事实_不透传description路径或自定义domain() {
        let diagnostic = ScanFailureDiagnostic(
            source: .workflow,
            stage: .dynamicDiscovery,
            reason: .unexpectedFailure,
            error: MaliciousProviderError()
        )

        XCTAssertEqual(diagnostic.source, .workflow)
        XCTAssertEqual(diagnostic.stage, .dynamicDiscovery)
        XCTAssertEqual(diagnostic.reason, .unexpectedFailure)
        XCTAssertEqual(diagnostic.domain, .unknown)
        XCTAssertEqual(diagnostic.code, 73_319)
        XCTAssertEqual(
            diagnostic.logFields,
            "source=workflow stage=dynamic-discovery reason=unexpected-failure "
                + "domain=UnknownErrorDomain code=73319"
        )

        let forbiddenFragments = [
            "/Users/private",
            "Secret.plist",
            "provider-response-body",
            "userInfo secret",
            "localized secret",
            "description secret",
            "token=alpha",
            "token=beta",
            "token=gamma",
        ]
        for fragment in forbiddenFragments {
            XCTAssertFalse(
                diagnostic.logFields.contains(fragment),
                "诊断字段不得透传 Error 控制的内容：\(fragment)"
            )
        }
    }

    func test_knownDomain_保留domain与数值code_丢弃userInfo正文() {
        let error = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EACCES),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "permission payload /Users/private/ShouldNeverReachDiagnostic",
            ]
        )
        let diagnostic = ScanFailureDiagnostic(
            source: .derivedData,
            stage: .snapshot,
            reason: .permissionDenied,
            error: error
        )

        XCTAssertEqual(diagnostic.domain, .posix)
        XCTAssertEqual(diagnostic.code, Int(EACCES))
        XCTAssertEqual(
            diagnostic.logFields,
            "source=derived-data stage=snapshot reason=permission-denied "
                + "domain=NSPOSIXErrorDomain code=13"
        )
        XCTAssertFalse(diagnostic.logFields.contains("permission payload"))
        XCTAssertFalse(diagnostic.logFields.contains("/Users/private"))
    }

    func test_typedScanFailure_无errno时仍形成稳定none字段() {
        let diagnostic = ScanFailureDiagnostic(
            source: .workflow,
            stage: .bulkScan,
            reason: .enumerationFailed,
            posixErrorCode: nil
        )

        XCTAssertEqual(diagnostic.domain, .unknown)
        XCTAssertNil(diagnostic.code)
        XCTAssertEqual(
            diagnostic.logFields,
            "source=workflow stage=bulk-scan reason=enumeration-failed "
                + "domain=UnknownErrorDomain code=none"
        )
    }

    func test_incompleteReason_完整映射到诊断reason闭集() {
        XCTAssertEqual(ScanFailureDiagnostic.Reason(.permissionDenied), .permissionDenied)
        XCTAssertEqual(ScanFailureDiagnostic.Reason(.tccProtectedSkipped), .tccProtectedSkipped)
        XCTAssertEqual(ScanFailureDiagnostic.Reason(.enumerationFailed), .enumerationFailed)
        XCTAssertEqual(ScanFailureDiagnostic.Reason(.metadataUnavailable), .metadataUnavailable)
    }
}
