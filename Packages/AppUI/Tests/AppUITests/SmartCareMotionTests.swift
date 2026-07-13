import Metal
import XCTest
@testable import AppUI

@MainActor
final class SmartCareMotionTests: XCTestCase {
    func testScanningMotionRunsOnCoreAnimationLayers() {
        let view = SmartCareCoreHostView(frame: CGRect(x: 0, y: 0, width: 280, height: 280))
        view.layoutSubtreeIfNeeded()
        view.configure(mode: .scanning, reduceMotion: false)

        let animationCount = view.layer?.sublayers?.reduce(into: 0) { count, layer in
            count += layer.animationKeys()?.count ?? 0
        } ?? 0
        XCTAssertGreaterThan(animationCount, 0)
    }

    func testReduceMotionStopsContinuousLayerAnimations() {
        let view = SmartCareCoreHostView(frame: CGRect(x: 0, y: 0, width: 280, height: 280))
        view.layoutSubtreeIfNeeded()
        view.configure(mode: .scanning, reduceMotion: true)

        let animationCount = view.layer?.sublayers?.reduce(into: 0) { count, layer in
            count += layer.animationKeys()?.count ?? 0
        } ?? 0
        XCTAssertEqual(animationCount, 0)
    }

    func testSignalBeamRunsOnCoreAnimationLayers() {
        let view = SmartCareSignalBeamHostView(frame: CGRect(x: 0, y: 0, width: 180, height: 3))
        view.configure(isActive: true, reduceMotion: false)
        view.layoutSubtreeIfNeeded()

        let animationCount = view.layer?.sublayers?.reduce(into: 0) { count, layer in
            count += layer.animationKeys()?.count ?? 0
        } ?? 0
        XCTAssertGreaterThan(animationCount, 0)
    }

    func testReduceMotionStopsSignalBeamAnimation() {
        let view = SmartCareSignalBeamHostView(frame: CGRect(x: 0, y: 0, width: 180, height: 3))
        view.configure(isActive: true, reduceMotion: true)
        view.layoutSubtreeIfNeeded()

        let animationCount = view.layer?.sublayers?.reduce(into: 0) { count, layer in
            count += layer.animationKeys()?.count ?? 0
        } ?? 0
        XCTAssertEqual(animationCount, 0)
    }

    func testActivityTextItselfBouncesAndGlowsOnCoreAnimationLayers() {
        let view = SmartCareAnimatedActivityTextHostView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 36)
        )
        view.configure(
            text: "Scanning developer caches",
            activity: .scanning(.developerCaches),
            reduceMotion: false
        )
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.displayedTextForTesting, "Scanning developer caches")
        XCTAssertTrue(view.animationKeysForTesting.contains("smart-care-activity-bounce"))
        XCTAssertTrue(view.animationKeysForTesting.contains("smart-care-activity-glow"))
    }

    func testReduceMotionStopsActivityTextContinuousAnimation() {
        let view = SmartCareAnimatedActivityTextHostView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 36)
        )
        view.configure(
            text: "Scanning developer caches",
            activity: .scanning(.developerCaches),
            reduceMotion: true
        )
        view.layoutSubtreeIfNeeded()

        XCTAssertTrue(view.animationKeysForTesting.isEmpty)
    }

    func testActiveStageCirclePulsesAndOrbitsOnCoreAnimationLayers() {
        let view = SmartCareStagePulseHostView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.configure(isActive: true, reduceMotion: false)
        view.layoutSubtreeIfNeeded()

        XCTAssertTrue(view.animationKeysForTesting.contains("smart-care-stage-pulse-scale"))
        XCTAssertTrue(view.animationKeysForTesting.contains("smart-care-stage-pulse-fade"))
        XCTAssertTrue(view.animationKeysForTesting.contains("smart-care-stage-orbit"))
    }

    func testReduceMotionStopsActiveStageCircleContinuousAnimation() {
        let view = SmartCareStagePulseHostView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.configure(isActive: true, reduceMotion: true)
        view.layoutSubtreeIfNeeded()

        XCTAssertTrue(view.animationKeysForTesting.isEmpty)
    }

    func testIdleKoiOwnsBackgroundMotionWithoutAmbientSweep() {
        let view = SmartCareAmbientHostView(frame: CGRect(x: 0, y: 0, width: 1_000, height: 700))
        view.layoutSubtreeIfNeeded()
        view.configure(mode: .idle, reduceMotion: false)

        let animationCount = view.layer?.sublayers?.reduce(into: 0) { count, layer in
            count += layer.animationKeys()?.count ?? 0
        } ?? 0
        XCTAssertEqual(animationCount, 0)
    }

    func testBackgroundModeKeepsKoiIdleAndFlameScanningOnly() {
        XCTAssertEqual(SmartCareBackgroundMode.mode(for: .idle), .idleKoi)
        XCTAssertEqual(
            SmartCareBackgroundMode.mode(for: .scanning(progress: SmartCareProgress())),
            .scanningFlame
        )

        let hiddenPhases: [SmartCarePhase] = [
            .reviewing(summary: .empty),
            .confirming(selection: SmartCareSelection()),
            .cleaning(progress: SmartCareCleanProgress(completedCount: 0, totalCount: 1)),
            .completed(result: SmartCareResult(movedCount: 0, skippedCount: 0, releasedBytes: 0)),
            .failed(.scanFailed("test")),
            .cancelled(partial: nil)
        ]
        for phase in hiddenPhases {
            XCTAssertEqual(SmartCareBackgroundMode.mode(for: phase), .hidden)
        }
    }

    func testFlameShaderUsesReferenceRaymarchingAndTransparentNegativeSpace() throws {
        let source = try SmartCareFlameShaderSource.load()

        XCTAssertTrue(source.contains("step < 70"))
        XCTAssertTrue(source.contains("octave < 6"))
        XCTAssertTrue(source.contains("point.yzx * frequency"))
        XCTAssertTrue(source.contains("tanh(accumulatedColor.rgb / 15.0)"))
        XCTAssertTrue(source.contains("float flameEnergy"))
        XCTAssertTrue(source.contains("float edgeFade"))
        XCTAssertTrue(source.contains("float sourceMean"))
        XCTAssertTrue(source.contains("float sourceMedian"))
        XCTAssertTrue(source.contains("float brightnessEnergy"))
        XCTAssertTrue(source.contains("float multiChannelEnergy"))
        XCTAssertTrue(source.contains("float palettePhase"))
        XCTAssertFalse(source.contains("float fieldMask"))
        XCTAssertFalse(source.contains("atmosphereAlpha"))
        XCTAssertTrue(source.contains("uniforms.paletteBlue.rgb"))
        XCTAssertTrue(source.contains("uniforms.paletteTeal.rgb"))
        XCTAssertTrue(source.contains("uniforms.paletteAmber.rgb"))
    }

    func testKoiShaderPortsReferencePointAndParityContract() throws {
        let source = try SmartCareFlameShaderSource.load()

        XCTAssertTrue(source.contains("int i = 10000 - int(vertexID)"))
        XCTAssertTrue(source.contains("float y = float(i) / 790.0"))
        XCTAssertTrue(source.contains("int(y) ^ 9"))
        XCTAssertTrue(source.contains("float parity = float(i & 1)"))
        XCTAssertTrue(source.contains("float koiTime = uniforms.time * 2.0943951"))
        XCTAssertTrue(source.contains("travelTime * 0.22"))
        XCTAssertTrue(source.contains("0.43 + 0.18 * sin(travelTime * 0.17)"))
    }

    func testBackgroundShadersCompileOnMetal() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let source = try SmartCareFlameShaderSource.load()

        let library = try await device.makeLibrary(source: source, options: nil)

        XCTAssertNotNil(library.makeFunction(name: "smartCareFlameVertex"))
        XCTAssertNotNil(library.makeFunction(name: "smartCareFlameFragment"))
        XCTAssertNotNil(library.makeFunction(name: "smartCareKoiVertex"))
        XCTAssertNotNil(library.makeFunction(name: "smartCareKoiFragment"))
    }

    func testBackgroundAnimationHonorsSceneAndReduceMotion() {
        XCTAssertFalse(
            SmartCareBackgroundRenderPolicy.shouldAnimate(mode: .hidden, reduceMotion: false)
        )
        XCTAssertTrue(
            SmartCareBackgroundRenderPolicy.shouldAnimate(mode: .idleKoi, reduceMotion: false)
        )
        XCTAssertTrue(
            SmartCareBackgroundRenderPolicy.shouldAnimate(mode: .scanningFlame, reduceMotion: false)
        )
        XCTAssertFalse(
            SmartCareBackgroundRenderPolicy.shouldAnimate(mode: .idleKoi, reduceMotion: true)
        )
        XCTAssertEqual(SmartCareBackgroundRenderPolicy.targetOpacity(mode: .hidden), 0)
        XCTAssertEqual(SmartCareBackgroundRenderPolicy.targetOpacity(mode: .idleKoi), 1)
        XCTAssertEqual(SmartCareBackgroundRenderPolicy.targetFlameMix(mode: .idleKoi), 0)
        XCTAssertEqual(SmartCareBackgroundRenderPolicy.targetFlameMix(mode: .scanningFlame), 1)
    }

    func testBackgroundUsesTheProgressRingPalette() {
        XCTAssertEqual(
            SmartCareMotionPalette.blueVector,
            SIMD4<Float>(0.14, 0.48, 0.98, 1)
        )
        XCTAssertEqual(
            SmartCareMotionPalette.tealVector,
            SIMD4<Float>(0.09, 0.69, 0.56, 1)
        )
        XCTAssertEqual(
            SmartCareMotionPalette.amberVector,
            SIMD4<Float>(0.95, 0.58, 0.16, 1)
        )
    }

    func testBackgroundRendererHasStableIndependentBudgets() throws {
        XCTAssertEqual(SmartCareBackgroundRenderPolicy.preferredFramesPerSecond, 60)
        XCTAssertEqual(SmartCareBackgroundRenderPolicy.maximumInFlightFrames, 2)
        XCTAssertLessThanOrEqual(SmartCareBackgroundRenderPolicy.flameOpacity, 0.24)
        XCTAssertLessThanOrEqual(SmartCareBackgroundRenderPolicy.flameRenderScale, 0.18)
        XCTAssertLessThanOrEqual(
            SmartCareBackgroundRenderPolicy.maximumFlameDrawableEdge,
            640
        )
        XCTAssertGreaterThanOrEqual(SmartCareBackgroundRenderPolicy.koiRenderScale, 0.4)
        XCTAssertLessThanOrEqual(
            SmartCareBackgroundRenderPolicy.maximumKoiDrawableEdge,
            1_200
        )
        XCTAssertEqual(SmartCareBackgroundRenderPolicy.koiPointCount, 10_000)

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AppUI/SmartCareFlameShaderView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(source.contains("MTKView"))
        XCTAssertTrue(source.contains("SmartCareBackgroundRenderThread: Thread"))
        XCTAssertTrue(source.contains("qualityOfService = .userInteractive"))
        XCTAssertTrue(source.contains("type: .point"))
    }

    func testBackgroundTimelineClampsAStalledFrameInsteadOfJumping() {
        var timeline = SmartCareBackgroundTimeline()
        timeline.restart(at: 10)
        let regularFrame = timeline.advance(to: 10 + (1.0 / 60.0))
        let afterStall = timeline.advance(to: 11)

        XCTAssertEqual(regularFrame, Float(1.0 / 60.0), accuracy: 0.0001)
        XCTAssertEqual(
            afterStall - regularFrame,
            Float(SmartCareBackgroundRenderPolicy.maximumSimulationStep),
            accuracy: 0.0001
        )
    }

    func testBackgroundDrawableUsesSceneSpecificResolution() {
        let bounds = CGSize(width: 2_000, height: 1_200)
        let flameSize = SmartCareBackgroundRenderPolicy.drawableSize(
            bounds: bounds,
            backingScale: 2,
            mode: .scanningFlame
        )
        let koiSize = SmartCareBackgroundRenderPolicy.drawableSize(
            bounds: bounds,
            backingScale: 2,
            mode: .idleKoi
        )

        XCTAssertEqual(max(flameSize.width, flameSize.height), 640)
        XCTAssertEqual(max(koiSize.width, koiSize.height), 1_200)
        XCTAssertEqual(flameSize.width / flameSize.height, 2_000.0 / 1_200.0, accuracy: 0.01)
        XCTAssertEqual(koiSize.width / koiSize.height, 2_000.0 / 1_200.0, accuracy: 0.01)
    }

    func testSmartCareViewsDoNotDriveFramesWithTimelineView() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AppUI")
        let files = [
            "SmartCareDashboardView.swift",
            "SmartCareFlameShaderView.swift",
            "SmartCareMotionView.swift"
        ]

        for file in files {
            let source = try String(
                contentsOf: sourceRoot.appendingPathComponent(file),
                encoding: .utf8
            )
            XCTAssertFalse(
                source.contains("TimelineView"),
                "\(file) must not schedule frame-by-frame SwiftUI updates"
            )
            XCTAssertFalse(
                source.contains("repeatForever"),
                "\(file) must keep repeating motion on Core Animation or Metal"
            )
        }
    }
}
