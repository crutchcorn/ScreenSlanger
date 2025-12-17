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
  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private var textureCache: CVMetalTextureCache!
  private var activeEffectSource: String? = nil
  private var renderPipeline: MTLRenderPipelineState? = nil
  private var samplerState: MTLSamplerState!
  private let baseTime = ProcessInfo.processInfo.systemUptime
  
  // RetroArch shader support
  private var activeShaderType: ActiveShaderType = .none
  private(set) var parameterState: ShaderParameterState = ShaderParameterState()
  private var shaderDirectory: URL? = nil
  
  // Background texture for RetroArch shaders that need it
  private var backgroundTexture: MTLTexture? = nil

  init(metalLayer: CAMetalLayer) {
    guard let device = MTLCreateSystemDefaultDevice() else {
      fatalError("Unable to access a Metal device on this system.")
    }
    self.device = device

    guard let queue = self.device.makeCommandQueue() else {
      fatalError("Could not create command queue.")
    }
    self.commandQueue = queue

    metalLayer.device = self.device
    metalLayer.pixelFormat = .bgra8Unorm
    metalLayer.framebufferOnly = true
    metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 1.0
    metalLayer.isOpaque = false
    metalLayer.backgroundColor = NSColor.clear.cgColor

    var cache: CVMetalTextureCache?
    CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, self.device, nil, &cache)
    if let createdCache = cache {
      self.textureCache = createdCache
    } else {
      fatalError("Could not create CVMetalTextureCache.")
    }
    
    // Create a sampler state for shaders
    let samplerDescriptor = MTLSamplerDescriptor()
    samplerDescriptor.minFilter = .linear
    samplerDescriptor.magFilter = .linear
    samplerDescriptor.sAddressMode = .clampToEdge
    samplerDescriptor.tAddressMode = .clampToEdge
    self.samplerState = self.device.makeSamplerState(descriptor: samplerDescriptor)
  }
  
  // MARK: - RetroArch Shader Pipeline Builder
  
  /// Build a render pipeline from a RetroArch shader
  static func buildRetroArchPipeline(
    device: MTLDevice,
    effectSource: String,
    shaderDirectory: URL?
  ) throws -> (MTLRenderPipelineState, [ShaderParameter]) {
    let compiled = try RetroArchShaderCompiler.compileToMetal(
      source: effectSource,
      shaderDirectory: shaderDirectory
    )
    
    print("=== RetroArch-generated Metal code ===")
    print(compiled.metalSource)
    print("=== End RetroArch-generated Metal code ===")
    
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
    return (pipeline, compiled.parameters)
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
    
    // Debug: print the generated Metal code
    print("=== Slang-generated Metal code ===")
    print(metalFragmentSource)
    print("=== End Slang-generated Metal code ===")
    
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
    guard let effectSource = effectSource else {
      self.activeEffectSource = nil
      self.renderPipeline = nil
      self.activeShaderType = .none
      self.parameterState = ShaderParameterState()
      return
    }
    
    self.activeEffectSource = effectSource
    
    // Determine shader directory for includes
    if let path = shaderPath {
      self.shaderDirectory = URL(fileURLWithPath: path).deletingLastPathComponent()
    } else {
      self.shaderDirectory = nil
    }
    
    // Detect shader type and compile accordingly
    if RetroArchShaderCompiler.isRetroArchShader(effectSource) {
      // RetroArch-style shader
      do {
        let (pipeline, parameters) = try Self.buildRetroArchPipeline(
          device: self.device,
          effectSource: effectSource,
          shaderDirectory: self.shaderDirectory
        )
        self.renderPipeline = pipeline
        self.activeShaderType = .retroArch
        self.parameterState = ShaderParameterState()
        self.parameterState.parameters = parameters
        self.parameterState.reset()
        
        // Load background texture if the shader uses one
        loadBackgroundTextureIfNeeded(effectSource: effectSource)
        
        print("Loaded RetroArch shader with \(parameters.count) parameters")
        for param in parameters {
          print("  - \(param.name): \(param.description) [\(param.minValue) - \(param.maxValue), default: \(param.defaultValue)]")
        }
      } catch {
        self.renderPipeline = nil
        self.activeShaderType = .none
        throw error
      }
    } else {
      // Standard Slang shader
      do {
        self.renderPipeline = try Self.buildRenderPipeline(
          device: self.device, effectSource: effectSource)
        self.activeShaderType = .slang
        self.parameterState = ShaderParameterState()
      } catch {
        self.renderPipeline = nil
        self.activeShaderType = .none
        throw error
      }
    }
  }
  
  /// Load background texture if the shader references BACKGROUND sampler
  private func loadBackgroundTextureIfNeeded(effectSource: String) {
    // Check if shader uses BACKGROUND texture
    guard effectSource.contains("BACKGROUND") else {
      self.backgroundTexture = nil
      return
    }
    
    // Look for background texture in shader directory
    guard let shaderDir = self.shaderDirectory else {
      print("Warning: Shader uses BACKGROUND texture but no shader directory specified")
      return
    }
    
    // Common background texture paths for RetroArch shaders
    let possiblePaths = [
      shaderDir.appendingPathComponent("png/4k/background.png"),
      shaderDir.appendingPathComponent("png/2k/background.png"),
      shaderDir.appendingPathComponent("background.png"),
      shaderDir.appendingPathComponent("../background.png")
    ]
    
    for path in possiblePaths {
      if FileManager.default.fileExists(atPath: path.path) {
        loadTexture(from: path)
        return
      }
    }
    
    print("Warning: Could not find BACKGROUND texture for shader")
  }
  
  /// Load a texture from a file
  private func loadTexture(from url: URL) {
    let textureLoader = MTKTextureLoader(device: device)
    do {
      self.backgroundTexture = try textureLoader.newTexture(
        URL: url,
        options: [
          .textureUsage: MTLTextureUsage.shaderRead.rawValue,
          .textureStorageMode: MTLStorageMode.private.rawValue
        ]
      )
      print("Loaded background texture: \(url.lastPathComponent)")
    } catch {
      print("Failed to load background texture: \(error)")
    }
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

    guard let commandBuffer = self.commandQueue.makeCommandBuffer(),
      let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
    else {
      return
    }

    // Set scissor rect to exclude the menu bar.
    if let screen = NSScreen.main {
      let scaleFactor = NSScreen.main?.backingScaleFactor ?? 1.0
      let visibleFrame = screen.visibleFrame
      let screenHeight = screen.frame.height
      let scissorRect = MTLScissorRect(
        x: Int(visibleFrame.origin.x * scaleFactor),
        y: Int((screenHeight - visibleFrame.origin.y - visibleFrame.height) * scaleFactor),
        width: Int(visibleFrame.width * scaleFactor),
        height: Int(visibleFrame.height * scaleFactor)
      )
      encoder.setScissorRect(scissorRect)

      if let renderPipeline = self.renderPipeline {
        encoder.setRenderPipelineState(renderPipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(self.samplerState, index: 0)
        
        switch self.activeShaderType {
        case .retroArch:
          // Set up RetroArch-style uniforms
          encodeRetroArchUniforms(
            encoder: encoder,
            screen: screen,
            textureWidth: width,
            textureHeight: height
          )
          
          // Set background texture if available (typically at binding 3)
          if let bgTexture = self.backgroundTexture {
            encoder.setFragmentTexture(bgTexture, index: 1)
          }
          
        case .slang:
          // Slang shaders expect a Uniforms struct at buffer(0)
          var screenSize = vector_float2(Float(screen.frame.width), Float(screen.frame.height))
          var mousePosition = vector_float2(
            Float(NSEvent.mouseLocation.x), Float(NSEvent.mouseLocation.y))
          var time = Float(ProcessInfo.processInfo.systemUptime - self.baseTime)
          
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
    }

    encoder.endEncoding()

    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
  
  /// Encode RetroArch-style uniforms for the shader
  private func encodeRetroArchUniforms(
    encoder: MTLRenderCommandEncoder,
    screen: NSScreen,
    textureWidth: Int,
    textureHeight: Int
  ) {
    let scaleFactor = screen.backingScaleFactor
    let outputWidth = Float(screen.frame.width * scaleFactor)
    let outputHeight = Float(screen.frame.height * scaleFactor)
    let sourceWidth = Float(textureWidth)
    let sourceHeight = Float(textureHeight)
    
    // Build the push constants buffer matching the shader's Push struct
    // The order must match the shader's push_constant layout
    var pushBuffer: [Float] = []
    
    // Add user-defined parameters from #pragma parameter
    for param in parameterState.parameters {
      pushBuffer.append(parameterState.getValue(for: param.name))
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
    
    // Set vertex uniforms (UBO with MVP matrix)
    var mvp = matrix_identity_float4x4
    encoder.setVertexBytes(&mvp, length: MemoryLayout<matrix_float4x4>.stride, index: 0)
  }
}
