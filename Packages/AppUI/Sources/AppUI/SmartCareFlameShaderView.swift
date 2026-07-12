import AppKit
import Metal
import QuartzCore
import SwiftUI

enum SmartCareBackgroundMode: Equatable {
    case hidden
    case idleKoi
    case scanningFlame

    static func mode(for phase: SmartCarePhase) -> SmartCareBackgroundMode {
        switch phase {
        case .idle:
            return .idleKoi
        case .scanning:
            return .scanningFlame
        case .reviewing, .confirming, .cleaning, .completed, .failed, .cancelled:
            return .hidden
        }
    }
}

struct SmartCareBackgroundShaderView: NSViewRepresentable {
    let mode: SmartCareBackgroundMode
    let reduceMotion: Bool

    func makeNSView(context: Context) -> SmartCareBackgroundShaderHostView {
        let view = SmartCareBackgroundShaderHostView()
        view.configure(mode: mode, reduceMotion: reduceMotion)
        return view
    }

    func updateNSView(_ nsView: SmartCareBackgroundShaderHostView, context: Context) {
        nsView.configure(mode: mode, reduceMotion: reduceMotion)
    }
}

enum SmartCareFlameShaderSource {
    static func load() throws -> String {
        guard let url = Bundle.module.url(
            forResource: "SmartCareFlameShader.metal",
            withExtension: "txt"
        ) else {
            throw SmartCareBackgroundShaderError.resourceMissing
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

enum SmartCareBackgroundShaderError: Error {
    case resourceMissing
    case metalUnavailable
    case functionMissing(String)
}

enum SmartCareBackgroundRenderPolicy {
    static let preferredFramesPerSecond = 60
    static let flameRenderScale: CGFloat = 0.18
    static let maximumFlameDrawableEdge: CGFloat = 640
    static let koiRenderScale: CGFloat = 0.46
    static let maximumKoiDrawableEdge: CGFloat = 1_200
    static let maximumInFlightFrames = 2
    static let maximumSimulationStep: CFTimeInterval = 1.0 / 30.0
    static let sceneTransitionDuration: Float = 0.42
    static let flameOpacity: Float = 0.24
    static let koiOpacity: Float = 0.28
    static let koiPointCount = 10_000

    static var frameInterval: TimeInterval {
        1.0 / Double(preferredFramesPerSecond)
    }

    static func isVisible(mode: SmartCareBackgroundMode) -> Bool {
        mode != .hidden
    }

    static func shouldAnimate(mode: SmartCareBackgroundMode, reduceMotion: Bool) -> Bool {
        isVisible(mode: mode) && !reduceMotion
    }

    static func targetOpacity(mode: SmartCareBackgroundMode) -> Float {
        isVisible(mode: mode) ? 1 : 0
    }

    static func targetFlameMix(mode: SmartCareBackgroundMode) -> Float {
        mode == .scanningFlame ? 1 : 0
    }

    static func drawableSize(bounds: CGSize,
                             backingScale: CGFloat,
                             mode: SmartCareBackgroundMode) -> CGSize {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let renderScale = mode == .idleKoi ? koiRenderScale : flameRenderScale
        let maximumEdge = mode == .idleKoi
            ? maximumKoiDrawableEdge
            : maximumFlameDrawableEdge
        var size = CGSize(
            width: bounds.width * backingScale * renderScale,
            height: bounds.height * backingScale * renderScale
        )
        let longestEdge = max(size.width, size.height)
        if longestEdge > maximumEdge {
            let scale = maximumEdge / longestEdge
            size.width *= scale
            size.height *= scale
        }
        return CGSize(
            width: max(1, size.width.rounded()),
            height: max(1, size.height.rounded())
        )
    }
}

struct SmartCareBackgroundTimeline {
    private(set) var simulationTime: Float = 0
    private(set) var lastStep: Float = 0
    private var previousWallTime: CFTimeInterval?

    mutating func restart(at wallTime: CFTimeInterval) {
        simulationTime = 0
        lastStep = 0
        previousWallTime = wallTime
    }

    mutating func advance(to wallTime: CFTimeInterval) -> Float {
        guard let previousWallTime else {
            restart(at: wallTime)
            return simulationTime
        }
        let elapsed = max(0, wallTime - previousWallTime)
        let boundedElapsed = min(
            elapsed,
            SmartCareBackgroundRenderPolicy.maximumSimulationStep
        )
        lastStep = Float(boundedElapsed)
        simulationTime += lastStep
        self.previousWallTime = wallTime
        return simulationTime
    }
}

@MainActor
final class SmartCareBackgroundMetalSurfaceView: NSView {
    private var mode: SmartCareBackgroundMode = .hidden

    override func makeBackingLayer() -> CALayer {
        CAMetalLayer()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var metalLayer: CAMetalLayer {
        guard let metalLayer = layer as? CAMetalLayer else {
            preconditionFailure("Smart Care background surface must use CAMetalLayer")
        }
        return metalLayer
    }

    func configure(device: any MTLDevice) {
        let metalLayer = metalLayer
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        metalLayer.presentsWithTransaction = false
        metalLayer.displaySyncEnabled = true
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.maximumDrawableCount = SmartCareBackgroundRenderPolicy.maximumInFlightFrames
        updateDrawableSize()
    }

    func configure(mode: SmartCareBackgroundMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        updateDrawableSize()
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = backingScale
        let targetSize = SmartCareBackgroundRenderPolicy.drawableSize(
            bounds: bounds.size,
            backingScale: backingScale,
            mode: mode
        )
        guard targetSize != .zero, metalLayer.drawableSize != targetSize else { return }
        metalLayer.drawableSize = targetSize
    }
}

@MainActor
final class SmartCareBackgroundShaderHostView: NSView {
    private let surfaceView = SmartCareBackgroundMetalSurfaceView()
    private var renderer: SmartCareBackgroundRenderThread?
    private var mode: SmartCareBackgroundMode = .hidden
    private var reduceMotion = false
    private var isConfigured = false
    private var compilationTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.masksToBounds = true
        layer?.opacity = 0
        addSubview(surfaceView)
        NSLayoutConstraint.activate([
            surfaceView.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: trailingAnchor),
            surfaceView.topAnchor.constraint(equalTo: topAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        guard let device = MTLCreateSystemDefaultDevice() else {
            NSLog("[SmartCareBackground] Metal device unavailable")
            return
        }
        surfaceView.configure(device: device)
        compilePipelines(using: device)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        compilationTask?.cancel()
        renderer?.shutdown()
    }

    func configure(mode: SmartCareBackgroundMode, reduceMotion: Bool) {
        let previousMode = self.mode
        let changed = !isConfigured || previousMode != mode || self.reduceMotion != reduceMotion
        guard changed else { return }

        let shouldRestart = !isConfigured
            || (previousMode == .hidden && mode != .hidden)
        isConfigured = true
        self.mode = mode
        self.reduceMotion = reduceMotion
        surfaceView.configure(mode: mode)
        applyRenderingState(
            restartTime: shouldRestart,
            jumpToScene: shouldRestart || reduceMotion
        )
    }

    private func compilePipelines(using device: any MTLDevice) {
        compilationTask = Task { [weak self] in
            do {
                let source = try await Task.detached(priority: .utility) {
                    try SmartCareFlameShaderSource.load()
                }.value
                guard !Task.isCancelled else { return }
                let library = try await device.makeLibrary(source: source, options: nil)
                let flamePipeline = try await Self.makePipeline(
                    device: device,
                    library: library,
                    vertexName: "smartCareFlameVertex",
                    fragmentName: "smartCareFlameFragment"
                )
                let koiPipeline = try await Self.makePipeline(
                    device: device,
                    library: library,
                    vertexName: "smartCareKoiVertex",
                    fragmentName: "smartCareKoiFragment"
                )
                guard let commandQueue = device.makeCommandQueue() else {
                    throw SmartCareBackgroundShaderError.metalUnavailable
                }
                guard let self else { return }
                installRenderer(
                    SmartCareBackgroundRenderThread(
                        metalLayer: surfaceView.metalLayer,
                        flamePipeline: flamePipeline,
                        koiPipeline: koiPipeline,
                        commandQueue: commandQueue
                    )
                )
            } catch is CancellationError {
                return
            } catch {
                NSLog("[SmartCareBackground] shader setup failed: %@", error.localizedDescription)
            }
        }
    }

    private static func makePipeline(device: any MTLDevice,
                                     library: any MTLLibrary,
                                     vertexName: String,
                                     fragmentName: String) async throws -> any MTLRenderPipelineState {
        guard let vertexFunction = library.makeFunction(name: vertexName) else {
            throw SmartCareBackgroundShaderError.functionMissing(vertexName)
        }
        guard let fragmentFunction = library.makeFunction(name: fragmentName) else {
            throw SmartCareBackgroundShaderError.functionMissing(fragmentName)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try await device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func installRenderer(_ renderer: SmartCareBackgroundRenderThread?) {
        guard let renderer else { return }
        self.renderer?.shutdown()
        self.renderer = renderer
        renderer.qualityOfService = .userInteractive
        renderer.name = "com.amux.clean.smart-care-background"
        renderer.start()
        applyRenderingState(restartTime: mode != .hidden, jumpToScene: true)
    }

    private func applyRenderingState(restartTime: Bool, jumpToScene: Bool) {
        let targetOpacity = SmartCareBackgroundRenderPolicy.targetOpacity(mode: mode)
        let currentOpacity = layer?.presentation()?.opacity ?? layer?.opacity ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = targetOpacity
        CATransaction.commit()

        if currentOpacity != targetOpacity {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = currentOpacity
            fade.toValue = targetOpacity
            fade.duration = mode == .hidden ? 0.24 : 0.44
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(fade, forKey: "smart-care-background-fade")
        }

        renderer?.configure(
            mode: mode,
            reduceMotion: reduceMotion,
            restartTime: restartTime,
            jumpToScene: jumpToScene
        )
    }
}

final class SmartCareBackgroundRenderThread: Thread {
    private struct Uniforms {
        var resolution: SIMD2<Float>
        var time: Float
        var flameOpacity: Float
        var koiOpacity: Float
        var sceneMix: Float
        var padding: SIMD2<Float> = .zero
        var paletteBlue: SIMD4<Float>
        var paletteTeal: SIMD4<Float>
        var paletteAmber: SIMD4<Float>
    }

    private let metalLayer: CAMetalLayer
    private let flamePipeline: any MTLRenderPipelineState
    private let koiPipeline: any MTLRenderPipelineState
    private let commandQueue: any MTLCommandQueue
    private let renderPassDescriptor = MTLRenderPassDescriptor()
    private let stateCondition = NSCondition()
    private let inFlightFrames = DispatchSemaphore(
        value: SmartCareBackgroundRenderPolicy.maximumInFlightFrames
    )

    private var mode: SmartCareBackgroundMode = .hidden
    private var active = false
    private var animate = false
    private var frameRequested = false
    private var restartRequested = false
    private var jumpToSceneRequested = false
    private var stopRequested = false
    private var sceneMix: Float = 0
    private var timeline = SmartCareBackgroundTimeline()

    init?(metalLayer: CAMetalLayer?,
          flamePipeline: any MTLRenderPipelineState,
          koiPipeline: any MTLRenderPipelineState,
          commandQueue: any MTLCommandQueue) {
        guard let metalLayer else { return nil }
        self.metalLayer = metalLayer
        self.flamePipeline = flamePipeline
        self.koiPipeline = koiPipeline
        self.commandQueue = commandQueue
        super.init()

        let attachment = renderPassDescriptor.colorAttachments[0]
        attachment?.loadAction = .clear
        attachment?.storeAction = .store
        attachment?.clearColor = MTLClearColorMake(0, 0, 0, 0)
    }

    func configure(mode: SmartCareBackgroundMode,
                   reduceMotion: Bool,
                   restartTime: Bool,
                   jumpToScene: Bool) {
        stateCondition.lock()
        self.mode = mode
        active = SmartCareBackgroundRenderPolicy.isVisible(mode: mode)
        animate = SmartCareBackgroundRenderPolicy.shouldAnimate(
            mode: mode,
            reduceMotion: reduceMotion
        )
        if active {
            frameRequested = true
            restartRequested = restartRequested || restartTime
            jumpToSceneRequested = jumpToSceneRequested || jumpToScene
        }
        stateCondition.signal()
        stateCondition.unlock()
    }

    func shutdown() {
        stateCondition.lock()
        stopRequested = true
        stateCondition.signal()
        stateCondition.unlock()
    }

    override func main() {
        while true {
            stateCondition.lock()
            while !stopRequested && (!active || (!animate && !frameRequested)) {
                stateCondition.wait()
            }
            if stopRequested {
                stateCondition.unlock()
                return
            }
            let shouldAnimate = animate
            let shouldRestart = restartRequested
            let shouldJumpToScene = jumpToSceneRequested
            let frameMode = mode
            frameRequested = false
            restartRequested = false
            jumpToSceneRequested = false
            stateCondition.unlock()

            let frameStartedAt = CACurrentMediaTime()
            autoreleasepool {
                if shouldRestart {
                    timeline.restart(at: frameStartedAt)
                }
                let simulationTime = timeline.advance(to: frameStartedAt)
                updateSceneMix(
                    target: SmartCareBackgroundRenderPolicy.targetFlameMix(mode: frameMode),
                    step: timeline.lastStep,
                    jumpToTarget: shouldJumpToScene
                )
                renderFrame(simulationTime: simulationTime)
            }

            guard shouldAnimate else { continue }
            let elapsed = CACurrentMediaTime() - frameStartedAt
            let remaining = max(0, SmartCareBackgroundRenderPolicy.frameInterval - elapsed)
            guard remaining > 0 else { continue }

            stateCondition.lock()
            if !stopRequested && active && animate {
                _ = stateCondition.wait(until: Date(timeIntervalSinceNow: remaining))
            }
            stateCondition.unlock()
        }
    }

    private func updateSceneMix(target: Float, step: Float, jumpToTarget: Bool) {
        guard !jumpToTarget else {
            sceneMix = target
            return
        }
        let maximumChange = step / SmartCareBackgroundRenderPolicy.sceneTransitionDuration
        if sceneMix < target {
            sceneMix = min(target, sceneMix + maximumChange)
        } else {
            sceneMix = max(target, sceneMix - maximumChange)
        }
    }

    private func renderFrame(simulationTime: Float) {
        guard inFlightFrames.wait(timeout: .now()) == .success else { return }
        guard metalLayer.drawableSize.width > 0,
              metalLayer.drawableSize.height > 0,
              let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightFrames.signal()
            return
        }

        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor
        ) else {
            inFlightFrames.signal()
            return
        }

        var uniforms = Uniforms(
            resolution: SIMD2(
                Float(drawable.texture.width),
                Float(drawable.texture.height)
            ),
            time: simulationTime,
            flameOpacity: SmartCareBackgroundRenderPolicy.flameOpacity * sceneMix,
            koiOpacity: SmartCareBackgroundRenderPolicy.koiOpacity * (1 - sceneMix),
            sceneMix: sceneMix,
            paletteBlue: SmartCareMotionPalette.blueVector,
            paletteTeal: SmartCareMotionPalette.tealVector,
            paletteAmber: SmartCareMotionPalette.amberVector
        )

        if uniforms.koiOpacity > 0.001 {
            encoder.setRenderPipelineState(koiPipeline)
            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<Uniforms>.stride,
                index: 0
            )
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<Uniforms>.stride,
                index: 0
            )
            encoder.drawPrimitives(
                type: .point,
                vertexStart: 0,
                vertexCount: SmartCareBackgroundRenderPolicy.koiPointCount
            )
        }

        if uniforms.flameOpacity > 0.001 {
            encoder.setRenderPipelineState(flamePipeline)
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<Uniforms>.stride,
                index: 0
            )
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        let semaphore = inFlightFrames
        commandBuffer.addCompletedHandler { _ in
            semaphore.signal()
        }
        commandBuffer.commit()
    }
}
