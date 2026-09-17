import AppKit
import Metal
import MetalKit

@MainActor
class OverlayController: NSObject, @MainActor MTKViewDelegate {
  var onCaptureStopped: @MainActor () -> Void = {}
  private var config: Config
  private var metrics: Metrics
  private var errorMessage: ErrorMessage
  private var window: NSWindow!
  private var screen: NSScreen
  private var screenCapture: ScreenCapture!
  private var renderer: MetalRenderer!
  private let pendingFrame = PendingCaptureFrame()
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
    metalView.isPaused = true
    metalView.wantsLayer = true
    self.window.contentView = metalView

    self.renderer = MetalRenderer(metalLayer: metalView.metalLayer, screen: screen)

    self.screenCapture = ScreenCapture(screen: screen)
    self.screenCapture.config = self.config
    self.screenCapture.excludedWindowIDs = [CGWindowID(self.window.windowNumber)]
    self.screenCapture.onFrameReceived = { [pendingFrame, metrics] contentBuffer in
      let frameID = metrics.newFrameID()
      metrics.recordScreenCapture(frameID: frameID)
      pendingFrame.store(buffer: contentBuffer, frameID: frameID)
    }
    self.screenCapture.onCaptureStopped = { [weak self] in
      guard let self = self, !self.isCleanedUp else { return }
      self.setActive(false)
      self.onCaptureStopped()
    }
    self.screenCapture.onError = { [weak self] error in
      guard let self = self, !self.isCleanedUp else { return }
      self.errorMessage.set("Screen capture failed: \(error.localizedDescription)")
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
    
    // stopCapture drains its callback before we discard the final pending frame.
    self.pendingFrame.clear()
    
    // Close and release the window
    self.window?.orderOut(nil)
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    guard !isCleanedUp else { return }
    self.render()
  }

  func render() {
    guard !isCleanedUp else { return }
    
    if let frame = self.pendingFrame.take() {
      self.renderer.renderContentBuffer(window: self.window, contentBuffer: frame.buffer)
      self.metrics.recordRender(frameID: frame.frameID)
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
      self.setActive(false)
      return
    }

    self.setActive(self.config.active && activeShader != nil)
  }

  private func setActive(_ active: Bool) {
    self.screenCapture.setCapturing(active)
    (self.window.contentView as? MTKView)?.isPaused = !active
    if active {
      self.window.orderFrontRegardless()
    } else {
      self.window.orderOut(nil)
      self.pendingFrame.clear()
    }
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

/// Transfers the latest read-only capture surface from ScreenCaptureKit to the UI.
/// The lock protects the slot; retaining a pixel buffer keeps its IOSurface alive.
/// Neither the capture callback nor renderer modifies the buffer's pixels.
private final class PendingCaptureFrame: @unchecked Sendable {
  private let lock = NSLock()
  private var frame: (buffer: CVPixelBuffer, frameID: Int)?

  func store(buffer: CVPixelBuffer, frameID: Int) {
    lock.withLock {
      frame = (buffer, frameID)
    }
  }

  func take() -> (buffer: CVPixelBuffer, frameID: Int)? {
    lock.withLock {
      defer { frame = nil }
      return frame
    }
  }

  func clear() {
    lock.withLock {
      frame = nil
    }
  }
}
