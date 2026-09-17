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
  private let initialFrame: NSRect
  private let initialScale: CGFloat
  private let initialMaximumFPS: Int
  private let initialVisibleFrame: NSRect
  private var screenCapture: ScreenCapture!
  private var renderer: MetalRenderer!
  private let pendingFrame = PendingCaptureFrame()
  private var latestFrame: CapturedFrame?
  private var latestFrameWasSubmitted = false
  private var needsRender = false
  private var isActive = false
  private var framesPerSecond = 60
  private var redrawRetryTask: Task<Void, Never>?
  private var redrawRetries = 0
  private var isCleanedUp = false

  init(config: Config, metrics: Metrics, errorMessage: ErrorMessage, screen: NSScreen) {
    self.initialFrame = screen.frame
    self.initialScale = screen.backingScaleFactor
    self.initialMaximumFPS = screen.maximumFramesPerSecond
    self.initialVisibleFrame = screen.visibleFrame
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
    metalView.device = SharedMetalResources.shared.device
    metalView.delegate = self
    metalView.isPaused = true
    metalView.wantsLayer = true
    self.window.contentView = metalView

    self.renderer = MetalRenderer(metalLayer: metalView.metalLayer, screen: screen, metrics: metrics)
    self.renderer.onError = { [weak self] message in
      guard let self, !self.isCleanedUp else { return }
      self.errorMessage.set(message)
      self.setActive(false)
      self.onCaptureStopped()
    }

    self.screenCapture = ScreenCapture(screen: screen)
    self.screenCapture.excludedWindowIDs = [CGWindowID(self.window.windowNumber)]
    self.screenCapture.onFrameReceived = { [weak self, pendingFrame, metrics] contentBuffer in
      metrics.recordCapture()
      let result = pendingFrame.store(
        buffer: contentBuffer, captureTime: ProcessInfo.processInfo.systemUptime)
      if result.replaced { metrics.recordDroppedCapture() }
      // Animated drawing consumes the mailbox on its existing Metal cadence.
      // Static drawing coalesces many captures into one main-actor notification.
      if result.shouldNotify {
        Task { @MainActor [weak self] in
          pendingFrame.acknowledgeNotification()
          self?.markNeedsRender()
        }
      }
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
  
  /// Stop all capture and close the window
  func cleanup() {
    // Prevent double cleanup
    guard !isCleanedUp else { return }
    isCleanedUp = true
    isActive = false
    redrawRetryTask?.cancel()
    redrawRetryTask = nil
    
    // Clear the MTKView delegate first to stop render callbacks
    if let metalView = self.window?.contentView as? MTKView {
      metalView.delegate = nil
      metalView.isPaused = true
    }
    
    // Stop screen capture
    self.screenCapture?.stopCapture()
    
    // stopCapture drains its callback before we discard the final pending frame.
    clearFrames()
    
    // Close and release the window
    self.window?.orderOut(nil)
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    guard !isCleanedUp else { return }
    self.render()
  }

  func render() {
    guard !isCleanedUp, isActive else { return }
    if let frame = self.pendingFrame.take() {
      if latestFrame != nil, !latestFrameWasSubmitted { metrics.recordDroppedCapture() }
      latestFrame = frame
      latestFrameWasSubmitted = false
      needsRender = true
      redrawRetries = 0
    }
    guard let frame = latestFrame, config.animateWhenIdle || needsRender else { return }
    let submitted = renderer.renderContentBuffer(
      window: window, contentBuffer: frame.buffer, captureTime: frame.captureTime,
      framesPerSecond: framesPerSecond
    ) { [weak self] in
      guard let self, !self.isCleanedUp, self.isActive else { return }
      // A static update rejected while the GPU was busy remains dirty. Retry it
      // after completion, without creating an idle animation loop.
      if self.needsRender { self.requestStaticRedraw() }
    }
    if submitted {
      latestFrameWasSubmitted = true
      needsRender = false
      redrawRetryTask?.cancel()
      redrawRetryTask = nil
      redrawRetries = 0
    } else {
      retryUnavailableDrawable()
    }
  }

  func refreshConfig(ready: Bool) {
    guard !isCleanedUp else { return }
    framesPerSecond = max(1, min(config.targetFPS, screen.maximumFramesPerSecond))
    (window.contentView as? MTKView)?.preferredFramesPerSecond = framesPerSecond
    setActive(config.active && ready)
    if isActive { markNeedsRender() }
  }

  private func setActive(_ active: Bool) {
    let wasActive = isActive
    isActive = active
    pendingFrame.setNotificationsEnabled(active && !config.animateWhenIdle)
    self.screenCapture.setCapturing(active, framesPerSecond: framesPerSecond)
    if let view = self.window.contentView as? MTKView {
      view.enableSetNeedsDisplay = !config.animateWhenIdle
      view.isPaused = !active || !config.animateWhenIdle
    }
    if active {
      if !wasActive { self.window.orderFrontRegardless() }
    } else {
      self.window.orderOut(nil)
      redrawRetryTask?.cancel()
      redrawRetryTask = nil
      clearFrames()
    }
  }

  private func clearFrames() {
    if pendingFrame.clear() { metrics.recordDroppedCapture() }
    if latestFrame != nil, !latestFrameWasSubmitted { metrics.recordDroppedCapture() }
    latestFrame = nil
    latestFrameWasSubmitted = false
    needsRender = false
  }

  private func markNeedsRender() {
    guard !isCleanedUp, isActive else { return }
    needsRender = true
    redrawRetries = 0
    requestStaticRedraw()
  }

  private func requestStaticRedraw() {
    guard !config.animateWhenIdle, isActive, !isCleanedUp else { return }
    (window.contentView as? MTKView)?.needsDisplay = true
  }

  private func retryUnavailableDrawable() {
    guard !config.animateWhenIdle, redrawRetryTask == nil, redrawRetries < 3,
      isActive, needsRender else { return }
    redrawRetries += 1
    // A transient drawable allocation failure has no GPU completion callback.
    // Bound retries so an occluded static window cannot start continuous drawing.
    redrawRetryTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
      guard let self, !self.isCleanedUp, self.isActive else { return }
      self.redrawRetryTask = nil
      if self.needsRender { self.requestStaticRedraw() }
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
    markNeedsRender()
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

  func matchesDisplay(_ screen: NSScreen) -> Bool {
    initialFrame == screen.frame && initialScale == screen.backingScaleFactor
      && initialMaximumFPS == screen.maximumFramesPerSecond && initialVisibleFrame == screen.visibleFrame
  }
}

private struct CapturedFrame {
  let buffer: CVPixelBuffer
  /// Monotonic time when ScreenCaptureKit delivered the complete frame.
  let captureTime: TimeInterval
}

/// Transfers the latest read-only capture surface from ScreenCaptureKit to the UI.
/// The lock protects the slot; retaining a pixel buffer keeps its IOSurface alive.
/// Neither the capture callback nor renderer modifies the buffer's pixels.
private final class PendingCaptureFrame: @unchecked Sendable {
  private let lock = NSLock()
  private var frame: CapturedFrame?
  private var notificationsEnabled = false
  private var notificationPending = false

  func store(buffer: CVPixelBuffer, captureTime: TimeInterval) -> (replaced: Bool, shouldNotify: Bool) {
    lock.withLock {
      let replaced = frame != nil
      frame = CapturedFrame(buffer: buffer, captureTime: captureTime)
      let shouldNotify = notificationsEnabled && !notificationPending
      if shouldNotify { notificationPending = true }
      return (replaced, shouldNotify)
    }
  }

  func take() -> CapturedFrame? {
    lock.withLock {
      defer { frame = nil }
      return frame
    }
  }

  func clear() -> Bool {
    lock.withLock {
      let discarded = frame != nil
      frame = nil
      notificationPending = false
      return discarded
    }
  }

  func setNotificationsEnabled(_ enabled: Bool) {
    lock.withLock { notificationsEnabled = enabled }
  }

  func acknowledgeNotification() {
    lock.withLock { notificationPending = false }
  }
}
