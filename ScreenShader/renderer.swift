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

/// Shared Metal resources to avoid duplicating expensive objects across multiple renderers
class SharedMetalResources {
  static let shared = SharedMetalResources()
  
  let device: MTLDevice
  let commandQueue: MTLCommandQueue
  let samplerState: MTLSamplerState
  let repeatSamplerState: MTLSamplerState
  let baseTime: TimeInterval
  
  // Cached shader resources
  private(set) var renderPipeline: MTLRenderPipelineState? = nil
  private(set) var activeShaderType: ActiveShaderType = .none
  private(set) var parameterState: ShaderParameterState = ShaderParameterState()
  private var shaderDirectory: URL? = nil
  private var shaderPreset: ShaderPreset? = nil
  private var loadedTextures: [String: MTLTexture] = [:]  // Texture name -> texture
  private var textureSamplers: [ShaderSampler] = []  // Parsed samplers from shader
  private var activeEffectSource: String? = nil
  
  private init() {
    guard let device = MTLCreateSystemDefaultDevice() else {
      fatalError("Unable to access a Metal device on this system.")
    }
    self.device = device
    self.baseTime = ProcessInfo.processInfo.systemUptime
    
    guard let queue = self.device.makeCommandQueue() else {
      fatalError("Could not create command queue.")
    }
    self.commandQueue = queue
    
    // Create a sampler state for shaders (clamp for source texture)
    let samplerDescriptor = MTLSamplerDescriptor()
    samplerDescriptor.minFilter = .linear
    samplerDescriptor.magFilter = .linear
    samplerDescriptor.sAddressMode = .clampToEdge
    samplerDescriptor.tAddressMode = .clampToEdge
    self.samplerState = self.device.makeSamplerState(descriptor: samplerDescriptor)!
    
    // Create a repeat sampler for tiling background textures
    let repeatSamplerDescriptor = MTLSamplerDescriptor()
    repeatSamplerDescriptor.minFilter = .linear
    repeatSamplerDescriptor.magFilter = .linear
    repeatSamplerDescriptor.sAddressMode = .repeat
    repeatSamplerDescriptor.tAddressMode = .repeat
    self.repeatSamplerState = self.device.makeSamplerState(descriptor: repeatSamplerDescriptor)!
  }
  
  func getTexture(named name: String) -> MTLTexture? {
    return loadedTextures[name]
  }
  
  func getBackgroundTexture() -> MTLTexture? {
    // For backwards compatibility, return first non-Source texture or BACKGROUND
    return loadedTextures["BACKGROUND"] ?? loadedTextures.values.first
  }
  
  func getTextureSamplers() -> [ShaderSampler] {
    return textureSamplers
  }
  
  private var currentShaderPath: String? = nil
  
  func setEffectSource(_ effectSource: String?, shaderPath: String? = nil) throws {
    // Skip if shader hasn't changed and we already have a valid pipeline
    // For preset files (.slangp), compare by path since the effectSource changes after loading
    // But never skip if effectSource is nil (deactivation) or was nil (activation)
    let isDeactivating = effectSource == nil
    let wasDeactivated = activeEffectSource == nil
    if !isDeactivating && !wasDeactivated && shaderPath == currentShaderPath && currentShaderPath != nil && renderPipeline != nil {
      return
    }
    if effectSource == activeEffectSource && shaderPath == currentShaderPath {
      return
    }
    
    // Reset state
    self.shaderPreset = nil
    self.currentShaderPath = shaderPath
    self.loadedTextures.removeAll()
    self.textureSamplers.removeAll()
    
    guard let effectSource = effectSource else {
      self.activeEffectSource = nil
      self.renderPipeline = nil
      self.activeShaderType = .none
      self.parameterState = ShaderParameterState()
      return
    }
    
    self.activeEffectSource = effectSource
    
    // Check if this is a .slangp preset file
    if let path = shaderPath, path.hasSuffix(".slangp") {
      try loadFromPreset(presetPath: path)
      return
    }
    
    // Determine shader directory for includes
    if let path = shaderPath {
      self.shaderDirectory = URL(fileURLWithPath: path).deletingLastPathComponent()
    } else {
      self.shaderDirectory = nil
    }
    
    // Detect shader type and compile accordingly
    if RetroArchShaderCompiler.isRetroArchShader(effectSource) {
      // RetroArch-style shader
      let (pipeline, parameters, samplers) = try MetalRenderer.buildRetroArchPipeline(
        device: self.device,
        effectSource: effectSource,
        shaderDirectory: self.shaderDirectory
      )
      self.renderPipeline = pipeline
      self.activeShaderType = .retroArch
      self.parameterState = ShaderParameterState()
      self.parameterState.parameters = parameters
      self.parameterState.reset()
      self.textureSamplers = samplers
      // Note: Standalone .slang files without a .slangp preset won't have textures loaded
      // Textures are only loaded when defined in a .slangp preset file
    } else {
      // Standard Slang shader
      self.renderPipeline = try MetalRenderer.buildRenderPipeline(
        device: self.device, effectSource: effectSource)
      self.activeShaderType = .slang
      self.parameterState = ShaderParameterState()
    }
  }
  
  /// Load shader from a .slangp preset file
  private func loadFromPreset(presetPath: String) throws {
    let presetURL = URL(fileURLWithPath: presetPath)
    let preset = try ShaderPreset.parse(from: presetURL)
    self.shaderPreset = preset
    
    // Resolve and load the actual shader
    let shaderURL = preset.resolvePath(preset.shaderPath)
    self.shaderDirectory = shaderURL.deletingLastPathComponent()
    
    let shaderSource = try String(contentsOf: shaderURL, encoding: .utf8)
    self.activeEffectSource = shaderSource
    
    // Compile the shader
    let (pipeline, parameters, samplers) = try MetalRenderer.buildRetroArchPipeline(
      device: self.device,
      effectSource: shaderSource,
      shaderDirectory: self.shaderDirectory
    )
    self.renderPipeline = pipeline
    self.activeShaderType = .retroArch
    self.parameterState = ShaderParameterState()
    self.parameterState.parameters = parameters
    self.textureSamplers = samplers
    
    // Apply parameter values from preset
    for (name, value) in preset.parameterValues {
      self.parameterState.setValue(value, for: name)
    }
    
    // For any parameters not in preset, use defaults
    for param in parameters {
      if preset.parameterValues[param.name] == nil {
        self.parameterState.setValue(param.defaultValue, for: param.name)
      }
    }
    
    // Load textures defined in the preset
    for texture in preset.textures {
      let textureURL = preset.resolvePath(texture.path)
      if let loadedTexture = loadTexture(from: textureURL, linear: texture.linear) {
        loadedTextures[texture.name] = loadedTexture
      }
    }
  }
  
  /// Load a texture from a file
  private func loadTexture(from url: URL, linear: Bool = false) -> MTLTexture? {
    let textureLoader = MTKTextureLoader(device: device)
    do {
      let texture = try textureLoader.newTexture(
        URL: url,
        options: [
          .textureUsage: MTLTextureUsage.shaderRead.rawValue,
          .textureStorageMode: MTLStorageMode.private.rawValue
        ]
      )
      return texture
    } catch {
      return nil
    }
  }
}

// Uniforms struct that matches Slang's expected layout
struct SlangUniforms {
  var screenSize: vector_float2
  var mousePosition: vector_float2
  var time: Float
  var _padding: Float = 0  // Alignment padding
}

// Uniforms struct for RetroArch shaders (matches push_constant layout)
struct RetroArchPushConstants {
  // Standard RetroArch push constants - matches typical Push struct
  var sourceSize: vector_float4      // xy = size, zw = 1/size
  var originalSize: vector_float4    // xy = size, zw = 1/size
  var outputSize: vector_float4      // xy = size, zw = 1/size
  var frameCount: UInt32
  var _padding1: UInt32 = 0
  var _padding2: UInt32 = 0
  var _padding3: UInt32 = 0
}

// Standard UBO for RetroArch shaders
struct RetroArchUBO {
  var mvp: matrix_float4x4
}

/// Enum to track which type of shader is currently active
enum ActiveShaderType {
  case none
  case slang
  case retroArch
}

/// Holds the current state of shader parameters
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

class MetalRenderer {
  private let shared = SharedMetalResources.shared
  private var textureCache: CVMetalTextureCache!
  private let screen: NSScreen  // The screen this renderer is associated with
  
  // Expose parameter state from shared resources
  var parameterState: ShaderParameterState {
    return shared.parameterState
  }

  init(metalLayer: CAMetalLayer, screen: NSScreen) {
    self.screen = screen

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
  
  // MARK: - RetroArch Shader Pipeline Builder
  
  /// Build a render pipeline from a RetroArch shader
  static func buildRetroArchPipeline(
    device: MTLDevice,
    effectSource: String,
    shaderDirectory: URL?
  ) throws -> (MTLRenderPipelineState, [ShaderParameter], [ShaderSampler]) {
    let compiled = try RetroArchShaderCompiler.compileToMetal(
      source: effectSource,
      shaderDirectory: shaderDirectory
    )
    
    let library: MTLLibrary
    do {
      library = try device.makeLibrary(source: compiled.metalSource, options: nil)
    } catch {
      throw NSError(
        domain: "MetalRenderer", code: 4,
        userInfo: [
          NSLocalizedDescriptionKey: "Metal compilation failed: \(error.localizedDescription)"
        ])
    }
    
    // RetroArch shaders use main0 for both vertex and fragment by default
    // but spirv-cross may generate different names
    let vertexFunction = library.makeFunction(name: compiled.vertexFunctionName)
      ?? library.makeFunction(name: "vertexMain")
      ?? library.makeFunction(name: "vertex_main")
    let fragmentFunction = library.makeFunction(name: compiled.fragmentFunctionName)
      ?? library.makeFunction(name: "fragmentMain") 
      ?? library.makeFunction(name: "fragment_main")
    
    guard vertexFunction != nil && fragmentFunction != nil else {
      // List available functions for debugging
      let functionNames = library.functionNames.joined(separator: ", ")
      throw NSError(
        domain: "MetalRenderer", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "Could not find shader entry points. Available functions: \(functionNames)"
        ])
    }
    
    let pipelineDescriptor = MTLRenderPipelineDescriptor()
    pipelineDescriptor.vertexFunction = vertexFunction
    pipelineDescriptor.fragmentFunction = fragmentFunction
    pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    
    let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    return (pipeline, compiled.parameters, compiled.samplers)
  }

  // MARK: - Standard Slang Pipeline Builder
  static func buildRenderPipeline(device: MTLDevice, effectSource: String) throws
    -> MTLRenderPipelineState
  {
    // Wrap the user's effect code in the Slang framework
    let wrappedSource = SlangCompiler.wrapEffectSource(effectSource)
    
    // Compile Slang to Metal shader source
    let metalFragmentSource: String
    do {
      metalFragmentSource = try SlangCompiler.compileToMetal(slangSource: wrappedSource)
    } catch {
      throw NSError(
        domain: "MetalRenderer", code: 3,
        userInfo: [
          NSLocalizedDescriptionKey: "Slang compilation failed: \(error.localizedDescription)"
        ])
    }
    
    // Slang generates a complete Metal file with its own includes.
    // We need to add our vertex shader to it, but avoid duplicate includes.
    // Strip the Slang includes and add our vertex shader after.
    
    // The Slang output already has the fragment shader, we just need to add vertex shader
    let librarySource = """
      \(metalFragmentSource)
      
      // ========== ScreenShader Vertex Shader ==========
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

  func setEffectSource(_ effectSource: String?, shaderPath: String? = nil) throws {
    // Delegate to shared resources - shader compilation happens only once
    try shared.setEffectSource(effectSource, shaderPath: shaderPath)
  }

  func renderContentBuffer(window: NSWindow, contentBuffer: CVPixelBuffer) {
    guard let drawable = (window.contentView as? MetalView)?.metalLayer.nextDrawable() else {
      return
    }

    let width = CVPixelBufferGetWidth(contentBuffer)
    let height = CVPixelBufferGetHeight(contentBuffer)

    var tempTextureRef: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault,
      self.textureCache,
      contentBuffer,
      nil,
      .bgra8Unorm,
      width,
      height,
      0,
      &tempTextureRef)

    guard status == kCVReturnSuccess, let textureRef = tempTextureRef,
      let texture = CVMetalTextureGetTexture(textureRef)
    else {
      return
    }

    let renderPassDescriptor = MTLRenderPassDescriptor()
    renderPassDescriptor.colorAttachments[0].texture = drawable.texture
    renderPassDescriptor.colorAttachments[0].loadAction = .clear
    renderPassDescriptor.colorAttachments[0].storeAction = .store
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

    guard let commandBuffer = shared.commandQueue.makeCommandBuffer(),
      let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
    else {
      return
    }

    // Set scissor rect to exclude the menu bar.
    // The scissor rect is relative to the drawable, not global screen coordinates.
    let scaleFactor = self.screen.backingScaleFactor
    let screenFrame = self.screen.frame
    let visibleFrame = self.screen.visibleFrame
    
    // Calculate the visible area relative to the screen's own frame (not global coordinates)
    // The visible frame excludes the menu bar and dock
    let relativeX = visibleFrame.origin.x - screenFrame.origin.x
    let relativeY = visibleFrame.origin.y - screenFrame.origin.y
    
    // Convert to Metal coordinates (origin at top-left, scaled by backing scale factor)
    // The scissor rect Y is from the top, but visibleFrame Y is from the bottom
    let scissorX = Int(relativeX * scaleFactor)
    let scissorY = Int((screenFrame.height - relativeY - visibleFrame.height) * scaleFactor)
    let scissorWidth = Int(visibleFrame.width * scaleFactor)
    let scissorHeight = Int(visibleFrame.height * scaleFactor)
    
    // Clamp to drawable bounds to avoid Metal validation errors
    let drawableWidth = drawable.texture.width
    let drawableHeight = drawable.texture.height
    
    let clampedX = max(0, min(scissorX, drawableWidth))
    let clampedY = max(0, min(scissorY, drawableHeight))
    let clampedWidth = max(0, min(scissorWidth, drawableWidth - clampedX))
    let clampedHeight = max(0, min(scissorHeight, drawableHeight - clampedY))
    
    let scissorRect = MTLScissorRect(
      x: clampedX,
      y: clampedY,
      width: clampedWidth,
      height: clampedHeight
    )
    encoder.setScissorRect(scissorRect)

    if let renderPipeline = shared.renderPipeline {
      encoder.setRenderPipelineState(renderPipeline)
      
      switch shared.activeShaderType {
      case .retroArch:
        // Set up RetroArch-style uniforms
        encodeRetroArchUniforms(
          encoder: encoder,
          textureWidth: width,
          textureHeight: height
        )
        
        // Bind all textures based on their Metal bindings (parsed from generated code)
        let samplers = shared.getTextureSamplers()
        
        // If no samplers were parsed, fallback to binding Source at index 0
        if samplers.isEmpty {
          encoder.setFragmentTexture(texture, index: 0)
          encoder.setFragmentSamplerState(shared.samplerState, index: 0)
        }
        
        for sampler in samplers {
          if sampler.name == "Source" {
            // Source is the screen capture texture
            encoder.setFragmentTexture(texture, index: sampler.binding)
            encoder.setFragmentSamplerState(shared.samplerState, index: sampler.binding)
          } else if let loadedTexture = shared.getTexture(named: sampler.name) {
            encoder.setFragmentTexture(loadedTexture, index: sampler.binding)
            encoder.setFragmentSamplerState(shared.repeatSamplerState, index: sampler.binding)
          } else {
            // Use source texture as fallback to avoid validation errors
            encoder.setFragmentTexture(texture, index: sampler.binding)
            encoder.setFragmentSamplerState(shared.repeatSamplerState, index: sampler.binding)
          }
        }
        
      case .slang:
        // Slang shaders use fixed texture binding at index 0
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(shared.samplerState, index: 0)
        
        // Slang shaders expect a Uniforms struct at buffer(0)
        let screenSize = vector_float2(Float(self.screen.frame.width), Float(self.screen.frame.height))
        let mousePosition = vector_float2(
          Float(NSEvent.mouseLocation.x), Float(NSEvent.mouseLocation.y))
        let time = Float(ProcessInfo.processInfo.systemUptime - shared.baseTime)
        
        var uniforms = SlangUniforms(
          screenSize: screenSize,
          mousePosition: mousePosition,
          time: time
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SlangUniforms>.stride, index: 0)
        
      case .none:
        break
      }

      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    encoder.endEncoding()

    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
  
  /// Encode RetroArch-style uniforms for the shader
  private func encodeRetroArchUniforms(
    encoder: MTLRenderCommandEncoder,
    textureWidth: Int,
    textureHeight: Int
  ) {
    let scaleFactor = self.screen.backingScaleFactor
    let outputWidth = Float(self.screen.frame.width * scaleFactor)
    let outputHeight = Float(self.screen.frame.height * scaleFactor)
    let sourceWidth = Float(textureWidth)
    let sourceHeight = Float(textureHeight)
    
    // Build the push constants buffer matching the shader's Push struct
    // The order must match the shader's push_constant layout
    var pushBuffer: [Float] = []
    
    // Add user-defined parameters from #pragma parameter
    for param in parameterState.parameters {
      pushBuffer.append(parameterState.getValue(for: param.name))
    }
    
    // IMPORTANT: float4 members require 16-byte alignment in Metal
    // After N floats, we need to pad to the next 16-byte boundary (4 floats)
    // 7 floats = 28 bytes, next 16-byte boundary is 32 bytes (8 floats)
    while pushBuffer.count % 4 != 0 {
      pushBuffer.append(0)  // Padding for alignment
    }
    
    // Add standard RetroArch parameters (OutputSize, OriginalSize, SourceSize)
    // These are vec4s: xy = size, zw = 1.0/size
    pushBuffer.append(contentsOf: [
      outputWidth, outputHeight, 1.0 / outputWidth, 1.0 / outputHeight,  // OutputSize
      sourceWidth, sourceHeight, 1.0 / sourceWidth, 1.0 / sourceHeight,  // OriginalSize
      sourceWidth, sourceHeight, 1.0 / sourceWidth, 1.0 / sourceHeight   // SourceSize
    ])
    
    // Pad to 16-byte alignment
    while pushBuffer.count % 4 != 0 {
      pushBuffer.append(0)
    }
    
    encoder.setFragmentBytes(pushBuffer, length: pushBuffer.count * MemoryLayout<Float>.stride, index: 0)
    
    // Note: We don't need vertex uniforms since our custom vertex shader generates the quad procedurally
  }
}
