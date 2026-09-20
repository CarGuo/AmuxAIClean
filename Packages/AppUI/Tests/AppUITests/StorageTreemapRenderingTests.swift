import AppKit
import SwiftUI
import XCTest

@testable import AppUI

/// Opt-in rendered layout evidence only, never an App launch or filesystem action.
@MainActor
final class StorageTreemapRenderingTests: XCTestCase {
    func testSkewedAndTinyGroupsRemainReadableInBothLanguages() throws {
        let output = ProcessInfo.processInfo.environment["GSYCLEAN_WORKSPACE_RENDER_DIR"]
        try XCTSkipIf(output == nil, "Set GSYCLEAN_WORKSPACE_RENDER_DIR for offscreen layout evidence.")
        let directory = URL(fileURLWithPath: try XCTUnwrap(output), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values: [(String, Int64)] = [
            ("Users", 304_390), ("Applications", 33_100), ("System", 25_310),
            ("Library", 7_490), ("private", 5_900), ("opt", 2_900), ("Volumes", 1_130),
        ]
        let rows = values.map { name, bytes in
            TreeRow(path: "/fixture/\(name)", title: name, bytes: bytes * 1_000_000,
                    fileCount: 1, isDirectory: true, hasChildren: true)
        }
        let cases: [(String, ColorScheme, CGSize)] = [
            ("zh-Hans", .light, CGSize(width: 1150, height: 400)),
            ("en", .dark, CGSize(width: 750, height: 280)),
        ]
        for (language, scheme, size) in cases {
            let projection = try StorageDirectoryProjection.make(
                rows: rows, query: "", limit: 100, locale: Locale(identifier: language), viewportSize: size)
            XCTAssertNotNil(projection.mapPresentation.smallerItems)
            let view = StorageTreemapCanvas(
                presentation: projection.mapPresentation, isBusy: false,
                onViewportChange: { _ in }, onActivate: { _ in }, onShowSmallerItems: {},
                fileActions: { _ in EmptyView() })
                .frame(width: size.width, height: size.height)
                .padding(16)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: size.width + 32, height: size.height + 32)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("treemap-\(language).png"))
        }
    }
}
