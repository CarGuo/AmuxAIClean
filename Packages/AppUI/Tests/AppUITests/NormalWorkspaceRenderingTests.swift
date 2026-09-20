import AppKit
import ScanKit
import SwiftUI
import XCTest

@testable import AppUI

/// Opt-in offscreen layout evidence, not C4 and never a launch of the application.
/// All scan data and persistence owners belong to an NSTemporaryDirectory fixture.
@MainActor
final class NormalWorkspaceRenderingTests: XCTestCase {
    private struct ReadOnlyPipeline: DeletionPipeline {
        func preflight(paths: [String], accessDeniedPaths: Set<String>) async -> DeletionPreflight {
            DeletionPreflight(allowedPaths: [], rejections: paths.map { .init(path: $0, reason: "preview") })
        }
        func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?, [(String, String)]) {
            XCTFail("Offscreen layout verification must never move files")
            return (0, 0, nil, [])
        }
        func setAccessDeniedPaths(_ paths: Set<String>) {}
    }

    func testRenderWorkspaceAtMinimumSizeInBothLanguagesAndAppearances() async throws {
        let output = ProcessInfo.processInfo.environment["GSYCLEAN_WORKSPACE_RENDER_DIR"]
        try XCTSkipIf(output == nil, "Set GSYCLEAN_WORKSPACE_RENDER_DIR for offscreen layout evidence.")
        let outputURL = URL(fileURLWithPath: try XCTUnwrap(output), isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceRender-\(UUID())")
        let dataRoot = root.appendingPathComponent("Storage")
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        // Only generated fixture payloads; no HOME files are scanned or moved by this test.
        for (name, megabytes) in [("Projects", 5), ("Library", 3), ("Downloads", 2), ("Documents", 1)] {
            let directory = dataRoot.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 0xAB, count: megabytes * 1_048_576).write(
                to: directory.appendingPathComponent("fixture.bin"))
        }
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let scanner = ScanCoordinator(home: root.path)
        let store = StorageAnalysisStore(scanner: scanner)
        store.activate(locale: Locale(identifier: "en"))
        store.scan(.makeCustom(url: dataRoot))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while store.projection == nil || store.phase != .ready, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.projection?.totalCount, 4)
        let undo = UndoHistoryStore(
            storeURL: root.appendingPathComponent("undo.json"), allowedRestoreRoots: [root.path])
        let care = SmartCareSession(
            scanCoordinator: ScanCoordinator(home: root.path, systemProbeStore: scanner.systemProbe))
        let cases: [(NormalWorkspaceSection, String, ColorScheme)] = [
            (.analyze, "en", .dark), (.analyze, "zh-Hans", .light),
            (.clean, "zh-Hans", .light), (.status, "en", .dark),
        ]
        for (section, language, scheme) in cases {
            let view = NormalWorkspaceView(
                section: .constant(section), analysis: store, probe: scanner.systemProbe,
                pipeline: ReadOnlyPipeline(), undoHistoryStore: undo,
                isBusy: false, onToolBusyChange: { _ in }, onClean: {},
                cleanContent: { SmartCareHomeView(coordinator: care.care, session: care) }
            )
            .environment(\.locale, Locale(identifier: language))
            .environment(\.colorScheme, scheme)
            .environment(\.scenePhase, .active)
            .transaction { $0.disablesAnimations = true }
            .frame(width: 1280, height: 700)
            // NSHostingView includes native fields, menus and scroll views; ImageRenderer
            // cannot render these AppKit-backed controls and paints unsupported markers.
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 1280, height: 700)
            host.layoutSubtreeIfNeeded()
            // Let onAppear publish presentation state (the existing scope cards
            // reveal on appearance) before reading the offscreen view's pixels.
            // The same read-only sampler gets two real readings, so status cards
            // also exercise their populated layout without synthetic percentages.
            try await Task.sleep(for: .milliseconds(2200))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 1280)
            XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 700)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(
                to: outputURL.appendingPathComponent(
                    "workspace-\(section.rawValue)-\(language)-\(scheme == .dark ? "dark" : "light").png"))
        }
        store.deactivate()
    }
}
