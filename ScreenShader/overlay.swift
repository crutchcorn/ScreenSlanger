import AppKit
import Metal
import MetalKit

class OverlayController: NSObject, MTKViewDelegate {
  private var config: Config
  private var metrics: Metrics
  private var errorMessage: ErrorMessage
  private var window: NSWindow!
  private var screen: NSScreen
  private var screenCapture: ScreenCapture!
  private var renderer: MetalRenderer!
  private var contentBuffer: CVPixelBuffer?
  private var frameID: Int?
  private let dispatchQueue = DispatchQueue(label: "overlayController.queue")

  init(config: Config, metrics: Metrics, errorMessage: ErrorMessage, screen: NSScreen) {
    self.config = config
    self.metrics = metrics
    self.errorMessage = errorMessage
    self.screen = screen
    super.init()

    let contentRect = screen.frame

    self.window = NSWindow(
      contentRect: contentRect,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    self.window.isOpaque = false
    self.window.backgroundColor = .clear
    self.window.level = .screenSaver
    self.window.ignoresMouseEvents = true
    self.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    let metalView = MetalView(frame: NSRect(origin: .zero, size: contentRect.size))
    metalView.delegate = self
    metalView.wantsLayer = true
    self.window.contentView = metalView
    self.window.makeKeyAndOrderFront(nil)

    self.renderer = MetalRenderer(metalLayer: metalView.metalLayer, screen: screen)

    self.screenCapture = ScreenCapture(screen: screen)
    self.screenCapture.config = self.config
    self.screenCapture.excludedWindowIDs = [CGWindowID(self.window.windowNumber)]
    self.screenCapture.onFrameReceived = { [weak self] contentBuffer in
      self?.receiveFrame(contentBuffer: contentBuffer)
    }
  }

  func receiveFrame(contentBuffer: CVPixelBuffer) {
    let frameID = self.metrics.newFrameID()
    self.metrics.recordScreenCapture(frameID: frameID)

    self.dispatchQueue.async {
      self.frameID = frameID
      self.contentBuffer = contentBuffer
    }

    // self.render()
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    self.render()
  }

  func render() {
    var contentBuffer: CVPixelBuffer?
    var frameID: Int?

    self.dispatchQueue.sync {
        contentBuffer = self.contentBuffer
        frameID = self.frameID
        self.frameID = nil
        self.contentBuffer = nil
    }
    
    if let contentBuffer = contentBuffer, let frameID = frameID {
      self.renderer.renderContentBuffer(window: self.window, contentBuffer: contentBuffer)
      self.metrics.recordRender(frameID: frameID)
    }
  }

  func refreshConfig() {
    let activeShader = self.config.active ? self.config.getShader() : nil

    do {
      try self.renderer.setEffectSource(activeShader, shaderPath: self.config.shaderPath)
      self.errorMessage.clear()
      
      // Apply stored parameter values from config
      self.config.applyStoredParameters(to: self.renderer.parameterState)
    } catch {
      print("Effect shader error: \(error.localizedDescription)")
      self.errorMessage.set(error.localizedDescription)
    }

    // TODO: The window is briefly visible with the previous effect applied.
    // self.window.setIsVisible(active)
    // self.screenCapture.setCapturing(active)

    self.window.setIsVisible(true)
    self.screenCapture.setCapturing(true)
  }
  
  /// Get the current parameter state from the renderer
  func getParameterState() -> ShaderParameterState? {
    return self.renderer.parameterState
  }
  
  /// Set a parameter value on the renderer
  func setParameterValue(name: String, value: Float) {
    self.renderer.parameterState.setValue(value, for: name)
  }
  
  /// Get the display ID for this overlay's screen
  func getDisplayID() -> CGDirectDisplayID {
    let screenNumber = self.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber
    return CGDirectDisplayID(screenNumber.uint32Value)
  }
  
  /// Get the screen this overlay is on
  func getScreen() -> NSScreen {
    return self.screen
  }
}
