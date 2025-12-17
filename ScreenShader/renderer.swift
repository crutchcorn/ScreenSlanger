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

class MetalRenderer {
  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private var textureCache: CVMetalTextureCache!
  private var activeEffectSource: String? = nil
  private var renderPipeline: MTLRenderPipelineState? = nil
  private var samplerState: MTLSamplerState!
  private let baseTime = ProcessInfo.processInfo.systemUptime

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
    
    // Create a sampler state for Slang shaders
    let samplerDescriptor = MTLSamplerDescriptor()
    samplerDescriptor.minFilter = .linear
    samplerDescriptor.magFilter = .linear
    samplerDescriptor.sAddressMode = .clampToEdge
    samplerDescriptor.tAddressMode = .clampToEdge
    self.samplerState = self.device.makeSamplerState(descriptor: samplerDescriptor)
  }

  /// Build a render pipeline from Slang shader effect source
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

  func setEffectSource(_ effectSource: String?) throws {
    guard let effectSource = effectSource else {
      self.activeEffectSource = nil
      self.renderPipeline = nil
      return
    }
    self.activeEffectSource = effectSource
    do {
      self.renderPipeline = try Self.buildRenderPipeline(
        device: self.device, effectSource: effectSource)
    } catch {
      self.renderPipeline = nil
      throw error
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
        var screenSize = vector_float2(Float(screen.frame.width), Float(screen.frame.height))
        var mousePosition = vector_float2(
          Float(NSEvent.mouseLocation.x), Float(NSEvent.mouseLocation.y))
        var time = Float(ProcessInfo.processInfo.systemUptime - self.baseTime)

        encoder.setRenderPipelineState(renderPipeline)
        encoder.setFragmentTexture(texture, index: 0)
        
        // Slang shaders expect a Uniforms struct at buffer(0) and a sampler
        var uniforms = SlangUniforms(
          screenSize: screenSize,
          mousePosition: mousePosition,
          time: time
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SlangUniforms>.stride, index: 0)
        encoder.setFragmentSamplerState(self.samplerState, index: 0)

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
      }
    }

    encoder.endEncoding()

    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}
