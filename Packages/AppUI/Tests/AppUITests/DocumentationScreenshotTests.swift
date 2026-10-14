import AppKit
import ScanKit
import SafetyKit
import SwiftUI
import XCTest

@testable import AppUI

/// v2026.10.14: the old script guessed sidebar positions and captured the entire
/// desktop on failure. Render production views with isolated example data instead.
/// These images document layout; they are never C4/C5 acceptance evidence.
@MainActor
final class DocumentationScreenshotTests: XCTestCase {
    private struct ReadOnlyPipeline: DeletionPipeline {
        func preflight(paths: [String], accessDeniedPaths: Set<String>) async -> DeletionPreflight {
            XCTFail("Documentation rendering must not initiate deletion")
            return DeletionPreflight(allowedPaths: [], rejections: [])
        }
        func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?, [(String, String)]) {
            XCTFail("Documentation rendering must never move files")
            return (0, 0, nil, [])
        }
        func setAccessDeniedPaths(_ paths: Set<String>) {}
    }

    func testRenderCurrentDocumentationScenesInBothLanguages() async throws {
        let output = ProcessInfo.processInfo.environment["AMUXCLEAN_DOCUMENTATION_RENDER_DIR"]
        try XCTSkipIf(output == nil, "Opt in through Scripts/screenshots.sh; no App is launched.")
        let destination = URL(fileURLWithPath: try XCTUnwrap(output), isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmuxAICleanDocumentation-\(UUID())", isDirectory: true)
        let dataRoot = root.appendingPathComponent("ExampleSpace", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // Best-effort fixture cleanup only.
        // Only this small, real temp scan backs the space-analysis image. Other
        // scenes use explicitly illustrative metrics, not claimed disk use.
        for (name, megabytes) in [("Projects", 8), ("Media", 5), ("Downloads", 3), ("Documents", 2)] {
            let folder = dataRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 0xA1, count: megabytes * 1_048_576)
                .write(to: folder.appendingPathComponent("example.bin"))
        }
        let suite = "DocumentationScreenshotTests-\(UUID())"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = AppSettings(testSuite: suite)
        settings.minFileSizeMB = 100
        settings.updateCheckEnabled = false
        let whitelist = WhitelistStore(storageURL: nil)
        let scanner = ScanCoordinator(home: root.path, whitelistStore: whitelist)
        let analysis = StorageAnalysisStore(scanner: scanner)
        let undo = UndoHistoryStore(storeURL: root.appendingPathComponent("undo.json"),
                                    allowedRestoreRoots: [root.path])
        let items = [
            SmartCareItem(id: "logs", bucketID: .systemJunk,
                          path: root.appendingPathComponent("Library/Logs/Example").path,
                          title: "Example.log", bytes: 192 * 1_048_576, fileCount: 84, verdict: .safe),
            SmartCareItem(id: "cache", bucketID: .appCache,
                          path: root.appendingPathComponent("Library/Caches/ExampleBrowser").path,
                          title: "ExampleBrowser", bytes: 768 * 1_048_576, fileCount: 312, verdict: .safe),
            SmartCareItem(id: "build", bucketID: .developerCache,
                          path: root.appendingPathComponent("Library/Developer/Xcode/DerivedData").path,
                          title: "DerivedData", bytes: 2_560 * 1_048_576, fileCount: 12_480, verdict: .confirm),
        ]
        let summary = SmartCareSummary(buckets: SmartCareBucketID.allCases.map { bucket in
            SmartCareBucketSummary(id: bucket, items: items.filter { $0.bucketID == bucket })
        })
        let care = SmartCareCoordinator(summary: summary)
        let session = SmartCareSession(care: care, scanCoordinator: scanner)
        for language in ["zh-Hans", "en"] {
            let locale = Locale(identifier: language)
            analysis.activate(locale: locale)
            analysis.scan(.makeCustom(url: dataRoot))
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while analysis.projection == nil || analysis.phase != .ready,
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(analysis.projection?.totalCount, 4)
            for (section, name) in [(NormalWorkspaceSection.analyze, "01-analyze"),
                                    (.clean, "02-clean"), (.status, "03-status")] {
                let view = NormalWorkspaceView(
                    section: .constant(section), analysis: analysis, probe: scanner.systemProbe,
                    pipeline: ReadOnlyPipeline(), undoHistoryStore: undo, isBusy: false,
                    onToolBusyChange: { _ in }, onClean: { XCTFail("Read-only capture") },
                    cleanContent: { SmartCareHomeView(coordinator: care, session: session) }
                )
                try await capture(view, name: name, language: language,
                                  size: CGSize(width: 1360, height: 760), destination: destination)
            }
            analysis.deactivate()
            let tree = ScanCoordinator(home: root.path, whitelistStore: whitelist)
            let names = ["DerivedData", "node_modules", "Downloads", "Archives", "Media", "Documents"]
            let sizes: [Int64] = [2_560, 1_024, 768, 512, 384, 128]
            let rows = zip(names, sizes).map { name, megabytes in
                let url = dataRoot.appendingPathComponent(name)
                return RowItem(id: url.path, url: url, title: name, isDirectory: true,
                               bytes: megabytes * 1_048_576, logicalBytes: megabytes * 1_048_576,
                               fileCount: Int(megabytes), verdict: .confirm, rejection: .ok,
                               hasChildren: true, modificationDate: Date(timeIntervalSince1970: 1_790_467_200))
            }
            tree._seedForTesting(
                snapshot: ScanSnapshot(categoryID: "documentation", rows: rows,
                    totalBytes: rows.reduce(0) { $0 + $1.bytes },
                    scannedFileCount: rows.reduce(0) { $0 + $1.fileCount },
                    isFinished: true, elapsed: 1),
                currentRootPath: dataRoot.path, isScanning: false
            )
            try await capture(
                TreeBrowserView(coordinator: tree, rootPath: dataRoot.path,
                                onTrash: { _ in XCTFail("Read-only capture") },
                                onStash: { _ in XCTFail("Read-only capture") },
                                isStashed: { _ in false },
                                onAskAI: { _ in XCTFail("Read-only capture") }),
                name: "04-tree", language: language,
                size: CGSize(width: 1200, height: 260), destination: destination
            )
            // Pure presentation paths are synthetic, so no machine-specific temp
            // identifiers or real user filenames enter a public documentation image.
            let exampleHome = "/Users/example"
            let exampleDownloads = URL(fileURLWithPath: exampleHome).appendingPathComponent("Downloads")
            let large = ScanCoordinator(home: exampleHome, whitelistStore: whitelist)
            let largeNames = ["Archive-2025.zip", "Project-demo.mov", "Installer.dmg",
                              "Dataset.tar.gz", "Presentation.pdf", "Photo-original.tiff"]
            large._seedForTesting(
                snapshot: ScanSnapshot(categoryID: "documentation-large", rows: [],
                    totalBytes: 5_376 * 1_048_576, scannedFileCount: largeNames.count,
                    isFinished: true, elapsed: 1),
                currentRootPath: exampleDownloads.path, isScanning: false
            )
            large._seedLargeFileLeavesForTesting(zip(largeNames, sizes).map {
                (path: exampleDownloads.appendingPathComponent($0.0).path, bytes: $0.1 * 1_048_576)
            })
            try await capture(
                LargeFilesView(coordinator: large, settings: settings, selection: .constant(nil),
                               batch: BatchSelection(), onTrash: { _ in XCTFail("Read-only capture") },
                               onStash: { _ in XCTFail("Read-only capture") },
                               isStashed: { _ in false }, aiSettings: nil,
                               onAskAI: { _ in XCTFail("Read-only capture") }),
                name: "05-large-files", language: language,
                size: CGSize(width: 1200, height: 410), destination: destination
            )
            try await capture(
                TreeRowActionsGuideExplanation().padding(24)
                    .background(Color(nsColor: .windowBackgroundColor)),
                name: "06-row-actions", language: language,
                size: CGSize(width: 640, height: 280), destination: destination
            )
        }
    }

    private func capture<Content: View>(
        _ content: Content, name: String, language: String, size: CGSize, destination: URL
    ) async throws {
        let view = content.environment(\.locale, Locale(identifier: language))
            .environment(\.colorScheme, .light).environment(\.scenePhase, .active)
            .transaction { $0.disablesAnimations = true }
            .frame(width: size.width, height: size.height)
            // Native result tables inherit the window's canvas in the App. Supply
            // that same light canvas for an offscreen view with no NSWindow.
            .background(Color.white)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // Production onAppear/table projections and the read-only status sampler
        // settle without showing a window or launching the application.
        try await Task.sleep(for: .milliseconds(2300))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(size.height))
        // Keep Retina text while avoiding multi-megabyte lossless gradient images
        // on the project landing pages. Encoding does not change UI or fixture data.
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92]))
        try jpeg.write(to: destination.appendingPathComponent("\(name)-\(language).jpg"))
    }
}
