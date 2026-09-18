import Metal
import MetalKit

class MetalView: MTKView {
  var metalLayer: CAMetalLayer {
    return self.layer as! CAMetalLayer
  }

  override func makeBackingLayer() -> CALayer {
    return CAMetalLayer()
  }
}

/// A compiled native pipeline is immutable. RetroArch owns one isolated chain per display.
struct CompiledEffect: Sendable {
  enum Backend: Sendable {
    case slang(any MTLRenderPipelineState)
    case retroArch([UInt32: RetroArchFilterChain])
  }
  let id = UUID()
  let backend: Backend
  let parameters: [ShaderParameter]
  var desktopMaskPipeline: (any MTLRenderPipelineState)? = nil
}

struct ShaderLoadRequest: Sendable {
  var source: String?
  var url: URL?
  var displayIDs: [UInt32] = [0]
}

/// Shares immutable native pipelines and UI parameters; mutable RetroArch history stays per display.
@MainActor
final class SharedMetalResources {
  static let shared = SharedMetalResources()
  let device: MTLDevice
  let commandQueue: MTLCommandQueue
  let samplerState: MTLSamplerState
  let baseTime = ProcessInfo.processInfo.systemUptime
  private(set) var effect: CompiledEffect?
  private(set) var parameterState = ShaderParameterState()
  private var loadGeneration: UInt64 = 0
  private var cancellation: ShaderCompilationCancellation?

  var renderPipeline: MTLRenderPipelineState? {
    guard case .slang(let pipeline) = effect?.backend else { return nil }
    return pipeline
  }

  init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
    guard let device, let queue = device.makeCommandQueue() else {
      fatalError("Unable to create Metal resources.")
    }
    self.device = device
    self.commandQueue = queue
    let descriptor = MTLSamplerDescriptor()
    descriptor.minFilter = .linear
    descriptor.magFilter = .linear
    descriptor.sAddressMode = .clampToEdge
    descriptor.tAddressMode = .clampToEdge
    self.samplerState = device.makeSamplerState(descriptor: descriptor)!
  }

  func clear() {
    cancellation?.cancel()
    cancellation = nil
    loadGeneration &+= 1
    effect = nil
    parameterState = ShaderParameterState()
  }

  /// Compilation and texture loading never run on the main actor. A cancelled or
  /// superseded request can finish cleanup, but cannot publish its result.
  func loadEffect(
    _ request: ShaderLoadRequest,
    build: @escaping @Sendable (
      ShaderLoadRequest, any MTLDevice, any MTLCommandQueue, ShaderCompilationCancellation
    ) throws -> CompiledEffect = SharedMetalResources.compile
  ) async throws {
    clear()
    let generation = loadGeneration
    let token = ShaderCompilationCancellation()
    cancellation = token
    let device = self.device
    let queue = self.commandQueue
    let loaded = try await withTaskCancellationHandler {
      try await Task.detached(priority: .userInitiated) {
        try build(request, device, queue, token)
      }.value
    } onCancel: {
      token.cancel()
    }
    try Task.checkCancellation()
    try token.checkCancellation()
    guard generation == loadGeneration else { throw CancellationError() }
    effect = loaded
    parameterState.parameters = loaded.parameters
    parameterState.reset()
    cancellation = nil
  }

  nonisolated static func compile(
    _ request: ShaderLoadRequest, device: any MTLDevice, queue: any MTLCommandQueue,
    cancellation: ShaderCompilationCancellation
  ) throws -> CompiledEffect {
    try cancellation.checkCancellation()
    let source: String
    if let supplied = request.source {
      source = supplied
    } else if let url = request.url {
      source = try String(contentsOf: url, encoding: .utf8)
    } else {
      throw ShaderRenderError.noSource
    }
    let isPreset = request.url?.pathExtension.lowercased() == "slangp"
    if isPreset || ShaderFormat.isRetroArch(source) {
      guard let url = request.url else { throw ShaderRenderError.retroArchNeedsFile }
      var chains: [UInt32: RetroArchFilterChain] = [:]
      for displayID in request.displayIDs {
        try cancellation.checkCancellation()
        chains[displayID] = try RetroArchFilterChain(shaderURL: url, commandQueue: queue)
      }
      try cancellation.checkCancellation()
      return CompiledEffect(backend: .retroArch(chains),
                            parameters: chains.values.first?.parameters ?? [],
                            desktopMaskPipeline: try makeDesktopMaskPipeline(device: device))
    }
    let pipeline = try MetalRenderer.buildRenderPipeline(
      device: device, effectSource: source, sourceURL: request.url, cancellation: cancellation)
    try cancellation.checkCancellation()
    return CompiledEffect(backend: .slang(pipeline), parameters: [])
  }
  nonisolated private static func makeDesktopMaskPipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
    let library = try device.makeLibrary(source: """
      #include <metal_stdlib>
      using namespace metal;
      vertex float4 screenVertex(uint id [[vertex_id]]) {
        float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
        return float4(p[id],0,1);
      }
      fragment float4 transparentPixel() {
        return float4(0);
      }
      """, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "screenVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "transparentPixel")
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    return try device.makeRenderPipelineState(descriptor: descriptor)
  }

}

// Uniforms struct that matches Slang's expected layout
struct SlangUniforms {
  var screenSize: vector_float2
  var mousePosition: vector_float2
  var time: Float
  var _padding: Float = 0  // Alignment padding
}

/// Holds the current state of shader parameters
@MainActor
class ShaderParameterState {
  var parameters: [ShaderParameter] = []
  var values: [String: Float] = [:]
  
  func getValue(for name: String) -> Float {
    if let value = values[name] {
      return value
    }
    if let param = parameters.first(where: { $0.name == name }) {
      return param.defaultValue
    }
    return 0.0
  }
  
  func setValue(_ value: Float, for name: String) {
    values[name] = value
  }
  
  func reset() {
    values.removeAll()
    for param in parameters {
      values[param.name] = param.defaultValue
    }
  }
}

@MainActor
class MetalRenderer {
  private let shared = SharedMetalResources.shared
  private var textureCache: CVMetalTextureCache!
  private let screen: NSScreen
  private let metrics: Metrics
  private let core: ShaderRenderCore
  private let frameSlot = DispatchSemaphore(value: 1)
  private var frameCount: UInt32 = 0
  private var effectID: UUID?
  private var previousFrameTime: TimeInterval?
  var onError: @MainActor (String) -> Void = { _ in }
  
  // Expose parameter state from shared resources
  var parameterState: ShaderParameterState {
    return shared.parameterState
  }

  init(metalLayer: CAMetalLayer, screen: NSScreen, metrics: Metrics) {
    self.screen = screen
    self.metrics = metrics
    let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
    self.core = ShaderRenderCore(displayID: displayID)

    metalLayer.device = shared.device
    metalLayer.pixelFormat = .bgra8Unorm
    metalLayer.framebufferOnly = true
    metalLayer.contentsScale = screen.backingScaleFactor
    metalLayer.isOpaque = false
    metalLayer.backgroundColor = NSColor.clear.cgColor

    var cache: CVMetalTextureCache?
    CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, shared.device, nil, &cache)
    if let createdCache = cache {
      self.textureCache = createdCache
    } else {
      fatalError("Could not create CVMetalTextureCache.")
    }
  }
  
  // MARK: - Standard Slang Pipeline Builder
  nonisolated static func buildRenderPipeline(
    device: MTLDevice, effectSource: String, sourceURL: URL? = nil,
    cancellation: ShaderCompilationCancellation? = nil
  ) throws -> MTLRenderPipelineState {
    // Wrap the user's effect code in the Slang framework
    let wrappedSource = SlangCompiler.wrapEffectSource(effectSource, sourceURL: sourceURL)
    
    // Compile Slang to Metal shader source
    let metalFragmentSource: String
    do {
      metalFragmentSource = try SlangCompiler.compileToMetal(
        slangSource: wrappedSource, sourceURL: sourceURL, cancellation: cancellation)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw NSError(
        domain: "MetalRenderer", code: 3,
        userInfo: [
          NSLocalizedDescriptionKey: "Slang compilation failed: \(error.localizedDescription)"
        ])
    }
    
    // Append the fullscreen vertex stage to the compiler's complete Metal source.
    let librarySource = """
      \(metalFragmentSource)
      
      // ========== ScreenSlanger Vertex Shader ==========
      struct VertexOut {
        float4 position [[position]];
        float2 texCoord [[user(TEXCOORD)]];
      };
      
      vertex VertexOut vertex_main(uint vertexId [[vertex_id]]) {
        float2 quadVertices[6] = {
          float2(-1.0, -1.0),
          float2( 1.0, -1.0),
          float2(-1.0,  1.0),
          float2(-1.0,  1.0),
          float2( 1.0, -1.0),
          float2( 1.0,  1.0)
        };

        VertexOut out;
        out.position = float4(quadVertices[vertexId], 0.0, 1.0);
        out.texCoord = float2(
          (quadVertices[vertexId].x + 1.0) * 0.5,
          (-quadVertices[vertexId].y + 1.0) * 0.5);
        return out;
      }
      """
    
    let library: MTLLibrary
    do {
      library = try device.makeLibrary(source: librarySource, options: nil)
    } catch {
      throw NSError(
        domain: "MetalRenderer", code: 4,
        userInfo: [
          NSLocalizedDescriptionKey: "Metal compilation failed: \(error.localizedDescription)"
        ])
    }
    
    let vertexFunction = library.makeFunction(name: "vertex_main")
    let fragmentFunction = library.makeFunction(name: "fragmentMain")
    
    guard vertexFunction != nil && fragmentFunction != nil else {
      throw NSError(
        domain: "MetalRenderer", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "Could not find vertex_main or fragmentMain in compiled Slang shader."
        ])
    }
    
    let pipelineDescriptor = MTLRenderPipelineDescriptor()
    pipelineDescriptor.vertexFunction = vertexFunction
    pipelineDescriptor.fragmentFunction = fragmentFunction
    pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    
    return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
  }

  /// Nonblocking submission: keep one frame per display in flight, with its
  /// capture surface retained until the GPU has finished reading it.
  @discardableResult
  func renderContentBuffer(
    window: NSWindow, contentBuffer: CVPixelBuffer, captureTime: TimeInterval,
    framesPerSecond: Int, onCompletion: @escaping @MainActor @Sendable () -> Void
  ) -> Bool {
    guard shared.effect != nil, frameSlot.wait(timeout: .now()) == .success else {
      metrics.recordSkippedRender()
      return false
    }
    var submitted = false
    defer {
      if !submitted {
        frameSlot.signal()
        metrics.recordSkippedRender()
      }
    }

    var textureRef: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, textureCache, contentBuffer, nil, .bgra8Unorm,
      CVPixelBufferGetWidth(contentBuffer), CVPixelBufferGetHeight(contentBuffer), 0, &textureRef)
    guard status == kCVReturnSuccess, let textureRef,
          let texture = CVMetalTextureGetTexture(textureRef),
          let commandBuffer = shared.commandQueue.makeCommandBuffer() else { return false }

    // Acquire scarce drawable storage only after the capture and frame slot are ready.
    guard let drawable = (window.contentView as? MetalView)?.metalLayer.nextDrawable() else {
      return false
    }
    if effectID != shared.effect?.id {
      effectID = shared.effect?.id
      frameCount = 0
      previousFrameTime = nil
    }
    let now = ProcessInfo.processInfo.systemUptime
    let elapsed = previousFrameTime.map { now - $0 } ?? (1 / Double(max(framesPerSecond, 1)))
    let scale = screen.backingScaleFactor
    let frame = screen.frame
    let visible = screen.visibleFrame
    let width = drawable.texture.width
    let height = drawable.texture.height
    let x = max(0, min(Int((visible.minX - frame.minX) * scale), width))
    let y = max(0, min(Int((frame.maxY - visible.maxY) * scale), height))
    let scissor = MTLScissorRect(
      x: x, y: y, width: max(0, min(Int(visible.width * scale), width - x)),
      height: max(0, min(Int(visible.height * scale), height - y)))
    let context = ShaderFrameContext(
      outputSize: SIMD2(Float(width), Float(height)),
      mousePosition: SIMD2(
        Float((NSEvent.mouseLocation.x - frame.minX) * scale),
        Float((NSEvent.mouseLocation.y - frame.minY) * scale)),
      time: Float(now - shared.baseTime), frameCount: frameCount,
      framesPerSecond: Float(framesPerSecond),
      frameTimeMilliseconds: UInt32(clamping: Int(max(0, min(elapsed * 1000, Double(UInt32.max))))))
    do {
      try core.encode(commandBuffer: commandBuffer, source: texture,
                      destination: drawable.texture, context: context, scissor: scissor)
    } catch RetroArchRuntimeError.frameInFlight {
      return false
    } catch {
      onError("Shader rendering failed: \(error.localizedDescription)")
      return false
    }

    let retainedSurface = RetainedCaptureSurface(texture: textureRef, buffer: contentBuffer)
    let metrics = self.metrics
    let frameSlot = self.frameSlot
    let submittedEffectID = effectID
    commandBuffer.addCompletedHandler { [weak self] buffer in
      withExtendedLifetime(retainedSurface) {}
      let duration = buffer.gpuEndTime > buffer.gpuStartTime
        ? buffer.gpuEndTime - buffer.gpuStartTime : nil
      metrics.recordCompleted(captureTime: captureTime, gpuDuration: duration,
                              succeeded: buffer.status == .completed)
      frameSlot.signal()
      let failure = buffer.status == .error
        ? (buffer.error?.localizedDescription ?? "Metal could not finish rendering the shader.") : nil
      Task { @MainActor [weak self] in
        if let self, let failure, self.shared.effect?.id == submittedEffectID {
          self.onError(failure)
        }
        onCompletion()
      }
    }
    drawable.addPresentedHandler { _ in metrics.recordPresented() }
    commandBuffer.present(drawable)
    metrics.recordSubmitted()
    submitted = true
    frameCount &+= 1
    previousFrameTime = now
    commandBuffer.commit()
    return true
  }
}

/// Inputs shared by onscreen drawing and offscreen regression tests, in pixels.
struct ShaderFrameContext {
  var outputSize: SIMD2<Float>
  var mousePosition: SIMD2<Float> = .zero
  var time: Float = 0
  var frameCount: UInt32 = 0
  var framesPerSecond: Float = 60
  var frameTimeMilliseconds: UInt32 = 17
}

enum ShaderRenderError: Error, LocalizedError {
  case noPipeline, encoderUnavailable, noSource, retroArchNeedsFile, missingDisplayChain

  var errorDescription: String? {
    switch self {
    case .noPipeline: return "No shader is loaded."
    case .encoderUnavailable: return "Metal could not create a render encoder."
    case .noSource: return "Select a shader file."
    case .retroArchNeedsFile: return "RetroArch shaders require a source file for includes and preset resources."
    case .missingDisplayChain: return "The shader has not been prepared for this display."
    }
  }
}

/// The production texture binding and draw path, used by both the app and pixel tests.
@MainActor
final class ShaderRenderCore {
  let resources: SharedMetalResources
  let displayID: UInt32

  init(resources: SharedMetalResources = .shared, displayID: UInt32 = 0) {
    self.resources = resources
    self.displayID = displayID
  }

  func encode(
    commandBuffer: MTLCommandBuffer, source: MTLTexture, destination: MTLTexture,
    context: ShaderFrameContext, scissor: MTLScissorRect? = nil
  ) throws {
    guard let effect = resources.effect else { throw ShaderRenderError.noPipeline }
    switch effect.backend {
    case .retroArch(let chains):
      guard let chain = chains[displayID] else { throw ShaderRenderError.missingDisplayChain }
      // Preserve full-size shader coordinates and history. A librashader viewport
      // would resize the image instead of just excluding the menu bar and Dock.
      try chain.encode(commandBuffer: commandBuffer, input: source, output: destination,
                       frameCount: UInt(context.frameCount), framesPerSecond: context.framesPerSecond,
                       frameTimeMilliseconds: context.frameTimeMilliseconds,
                       parameterValues: resources.parameterState.values)
      commandBuffer.addCompletedHandler { _ in withExtendedLifetime(chain) {} }
      if let scissor, let pipeline = effect.desktopMaskPipeline {
        do {
          try maskDesktopEdges(commandBuffer: commandBuffer, destination: destination,
                               visible: scissor, pipeline: pipeline)
        } catch {
          chain.discardUnsubmittedFrame(commandBuffer: commandBuffer)
          throw error
        }
      }
    case .slang(let pipeline):
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = destination
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].storeAction = .store
      pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
      guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
        throw ShaderRenderError.encoderUnavailable
      }
      encoder.setRenderPipelineState(pipeline)
      if let scissor { encoder.setScissorRect(scissor) }
      encoder.setFragmentTexture(source, index: 0)
      encoder.setFragmentSamplerState(resources.samplerState, index: 0)
      var uniforms = SlangUniforms(
        screenSize: context.outputSize, mousePosition: context.mousePosition, time: context.time)
      encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SlangUniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
      encoder.endEncoding()
    }
  }

  /// Mask only excluded desktop edges after the chain has saved its feedback.
  /// Drawing directly to the destination avoids an output-sized texture and a
  /// full-screen sampling pass; an entirely visible desktop needs no extra pass.
  private func maskDesktopEdges(
    commandBuffer: MTLCommandBuffer, destination: MTLTexture,
    visible: MTLScissorRect, pipeline: MTLRenderPipelineState
  ) throws {
    let width = destination.width, height = destination.height
    if visible.x == 0, visible.y == 0, visible.width == width, visible.height == height { return }
    let empty = visible.width == 0 || visible.height == 0
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = destination
    pass.colorAttachments[0].loadAction = empty ? .clear : .load
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
      throw ShaderRenderError.encoderUnavailable
    }
    defer { encoder.endEncoding() }
    guard !empty else { return }
    encoder.setRenderPipelineState(pipeline)
    let right = visible.x + visible.width, bottom = visible.y + visible.height
    let excluded = [
      MTLScissorRect(x: 0, y: 0, width: width, height: visible.y),
      MTLScissorRect(x: 0, y: bottom, width: width, height: height - bottom),
      MTLScissorRect(x: 0, y: visible.y, width: visible.x, height: visible.height),
      MTLScissorRect(x: right, y: visible.y, width: width - right, height: visible.height),
    ]
    for rectangle in excluded where rectangle.width > 0 && rectangle.height > 0 {
      encoder.setScissorRect(rectangle)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
  }

}

/// A lifetime token for immutable capture surfaces read by the GPU. The completion
/// handler only releases these references; it never accesses or modifies their pixels.
private struct RetainedCaptureSurface: @unchecked Sendable {
  let texture: CVMetalTexture
  let buffer: CVPixelBuffer
}
