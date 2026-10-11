import SwiftUI
import XCTest
@testable import AppUI

final class MainWindowActionsAccessoryTests: XCTestCase {
    @MainActor
    func test_unrelatedRootUpdatesDoNotMeasureButChangedContentGeometryDoes() throws {
        // v2026.10.11: keep only the fittingSize regression in default tests. The actual
        // titlebar/resize experiment is archived with C4 evidence, not a permanent window fixture.
        let actions = MainWindowActionsAccessory<AnyView, Int>.Controller()
        let controls = content(count: 3)
        actions.configure(content: controls, layoutIdentity: 0)
        let width = try XCTUnwrap(actions.hosting).frame.width
        actions.configure(content: AnyView(controls.opacity(0.5)), layoutIdentity: 0)
        XCTAssertEqual(actions.measurementCount, 1)
        actions.configure(content: content(count: 1), layoutIdentity: 1)
        XCTAssertEqual(actions.measurementCount, 2)
        XCTAssertLessThan(try XCTUnwrap(actions.hosting).frame.width, width)
    }

    @MainActor
    private func content(count: Int) -> AnyView {
        AnyView(HStack(spacing: 12) {
            ForEach(0..<count, id: \.self) { _ in Button {} label: { Image(systemName: "circle") } }
        }.font(.system(size: 17)).padding(12).fixedSize())
    }
}
