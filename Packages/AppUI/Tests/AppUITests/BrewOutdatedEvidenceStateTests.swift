import XCTest
import Darwin
import BrewKit
@testable import AppUI

final class BrewOutdatedEvidenceStateTests: XCTestCase {
    private func package(kind: BrewPackageKind) -> BrewPackage {
        BrewPackage(
            name: "fixture",
            version: "1.0",
            kind: kind,
            installedAt: nil,
            installedOnRequest: true,
            tap: nil,
            path: URL(fileURLWithPath: "/tmp/fixture")
        )
    }

    /// v2026.07.18 regression：空 outdated 只有在相关 registry 完整时才能显示“全部最新”。
    func test_formulaRegistry完整_允许权威空结果() {
        let registry = BrewRegistry(
            formulaLatest: [:],
            caskLatest: [:],
            formulaStatus: .complete,
            caskStatus: .missing
        )

        XCTAssertEqual(
            BrewOutdatedEvidenceState.evaluate(
                installed: BrewPackageListResult(packages: [package(kind: .formula)]),
                registry: registry
            ),
            .complete
        )
    }

    func test_相关registry缺失或损坏_不能伪装为全部最新() {
        let missing = BrewRegistry(
            formulaLatest: [:],
            caskLatest: [:],
            formulaStatus: .missing,
            caskStatus: .complete
        )
        let malformed = BrewRegistry(
            formulaLatest: [:],
            caskLatest: [:],
            formulaStatus: .unavailable,
            caskStatus: .complete
        )
        let installed = BrewPackageListResult(packages: [package(kind: .formula)])

        XCTAssertEqual(
            BrewOutdatedEvidenceState.evaluate(installed: installed, registry: missing),
            .cacheMissing
        )
        XCTAssertEqual(
            BrewOutdatedEvidenceState.evaluate(installed: installed, registry: malformed),
            .incomplete
        )
    }

    func test_installed枚举不完整_即使registry完整也不能宣称全部最新() {
        let registry = BrewRegistry(
            formulaLatest: [:],
            caskLatest: [:],
            formulaStatus: .complete,
            caskStatus: .complete
        )
        let installed = BrewPackageListResult(
            packages: [],
            diagnostics: [BrewDiagnostic(
                source: .formulaInstallations,
                stage: .enumerateRoot,
                reason: .permissionDenied,
                path: "/opt/homebrew/Cellar",
                errorDomain: NSPOSIXErrorDomain,
                errorCode: Int(EACCES)
            )]
        )

        XCTAssertEqual(
            BrewOutdatedEvidenceState.evaluate(installed: installed, registry: registry),
            .incomplete
        )
    }

    // MARK: - v2026.07.18 regression: Installed/Cleanup share authoritative-empty rules

    func test_evidencePresentation_只有complete或missing的空结果才显示权威空态() {
        XCTAssertEqual(
            BrewEvidencePresentation.evaluate(itemCount: 0, status: .complete),
            .authoritativeEmpty
        )
        XCTAssertEqual(
            BrewEvidencePresentation.evaluate(itemCount: 0, status: .missing),
            .authoritativeEmpty
        )
        XCTAssertEqual(
            BrewEvidencePresentation.evaluate(itemCount: 0, status: .partial),
            .incompleteEmpty
        )
        XCTAssertEqual(
            BrewEvidencePresentation.evaluate(itemCount: 0, status: .unavailable),
            .incompleteEmpty
        )
    }

    func test_evidencePresentation_局部结果保留内容并显示不完整提示() {
        XCTAssertEqual(
            BrewEvidencePresentation.evaluate(itemCount: 2, status: .partial),
            .content(incomplete: true)
        )
        XCTAssertEqual(
            BrewEvidencePresentation.evaluate(itemCount: 2, status: .complete),
            .content(incomplete: false)
        )
    }

    func test_evidencePresentation_尚未扫描时不抢先显示空态() {
        XCTAssertEqual(
            BrewEvidencePresentation.evaluate(itemCount: 0, status: nil),
            .idle
        )
    }
}
