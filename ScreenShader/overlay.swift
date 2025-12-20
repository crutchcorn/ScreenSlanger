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
  private var isCleanedUp = false

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
  
  deinit {
    // cleanup() should have already been called
  }
  
  /// Stop all capture and close the window
  func cleanup() {
    // Prevent double cleanup
    guard !isCleanedUp else { return }
    isCleanedUp = true
    
    // Clear the MTKView delegate first to stop render callbacks
    if let metalView = self.window?.contentView as? MTKView {
      metalView.delegate = nil
      metalView.isPaused = true
    }
    
    // Stop screen capture
    self.screenCapture?.stopCapture()
    
    // Drain any pending operations on our queue
    self.dispatchQueue.sync {
      self.contentBuffer = nil
      self.frameID = nil
    }
    
    // Close and release the window
    self.window?.orderOut(nil)
  }

  func receiveFrame(contentBuffer: CVPixelBuffer) {
    guard !isCleanedUp else { return }
    
    let frameID = self.metrics.newFrameID()
    self.metrics.recordScreenCapture(frameID: frameID)

    self.dispatchQueue.async { [weak self] in
      guard let self = self, !self.isCleanedUp else { return }
      self.frameID = frameID
      self.contentBuffer = contentBuffer
    }
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    guard !isCleanedUp else { return }
    self.render()
  }

  func render() {
    guard !isCleanedUp else { return }
    
    var contentBuffer: CVPixelBuffer?
    var frameID: Int?

    self.dispatchQueue.sync {
        contentBuffer = self.contentBuffer
        frameID = self.frameID
        self.frameID = nil
        self.contentBuffer = nil
    }
    
    // Double-check after sync in case cleanup happened while waiting
    guard !isCleanedUp else { return }
    
    if let contentBuffer = contentBuffer, let frameID = frameID {
      self.renderer.renderContentBuffer(window: self.window, contentBuffer: contentBuffer)
      self.metrics.recordRender(frameID: frameID)
    }
  }

  func refreshConfig() {
    guard !isCleanedUp else { return }
    
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
    guard !isCleanedUp else { return nil }
    return self.renderer.parameterState
  }
  
  /// Set a parameter value on the renderer
  func setParameterValue(name: String, value: Float) {
    guard !isCleanedUp else { return }
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
