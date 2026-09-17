import ScreenCaptureKit

@MainActor
class ScreenCapture {
  var excludedWindowIDs: [CGWindowID] = []
  var onFrameReceived: @Sendable (CVPixelBuffer) -> Void = { _ in }
  var onError: @MainActor (Error) -> Void = { _ in }
  var onCaptureStopped: @MainActor () -> Void = {}

  private var session: CaptureSession?
  private var latestSessionID: UUID?
  private let streamQueue = DispatchQueue(label: "ScreenCaptureKitStreamQueue")
  private let screen: NSScreen

  init(screen: NSScreen) {
    self.screen = screen
  }

  /// Get the CGDirectDisplayID for the screen.
  private func getDisplayID() -> CGDirectDisplayID {
    let screenNumber = self.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber
    return CGDirectDisplayID(screenNumber.uint32Value)
  }

  private func startCapture(framesPerSecond: Int) {
    // Snapshot AppKit values on the UI thread before the task starts.
    let targetDisplayID = getDisplayID()
    let scaleFactor = self.screen.backingScaleFactor
    let targetFPS = max(1, min(framesPerSecond, Int(Int32.max)))
    let excludedWindowIDs = self.excludedWindowIDs
    let sessionID = UUID()
    let output = StreamOutput(onFrameReceived: self.onFrameReceived) { [weak self] error in
      Task { @MainActor [weak self] in
        self?.captureStopped(sessionID: sessionID, error: error)
      }
    }
    let newSession = CaptureSession(
      id: sessionID, output: output, framesPerSecond: targetFPS,
      onError: self.onError, onCaptureStopped: self.onCaptureStopped)

    guard session == nil else { return }
    session = newSession
    latestSessionID = sessionID

    newSession.startTask = Task { [weak self] in
      guard let self = self else { return }
      var newStream: SCStream?
      do {
        let content = try await SCShareableContent.current
        guard self.isCurrentSession(newSession), !Task.isCancelled else { return }

        guard let display = content.displays.first(where: { $0.displayID == targetDisplayID }) else {
          throw NSError(
            domain: "ScreenCapture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not find display with ID \(targetDisplayID)"])
        }

        let excludedWindows = content.windows.filter { excludedWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = Int(CGFloat(display.width) * scaleFactor)
        streamConfig.height = Int(CGFloat(display.height) * scaleFactor)
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.capturesAudio = false
        streamConfig.showsCursor = false

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: output)
        newStream = stream
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: self.streamQueue)
        guard self.isCurrentSession(newSession), !Task.isCancelled else { return }
        try await stream.startCapture()

        // stopCapture may have run while either asynchronous operation was suspended.
        // A stale start owns its stream until it has stopped it; it cannot replace a newer session.
        guard self.finishStarting(newSession, stream: stream) else {
          self.stopStream(stream, output: output)
          return
        }
        print("Started screen capture for display \(targetDisplayID)")
      } catch {
        output.invalidate()
        self.captureStopped(sessionID: sessionID, error: error)
        // Keep the stream and output alive until any partial start is cleaned up.
        if let stream = newStream {
          self.stopStream(stream, output: output)
        }
      }
    }
  }

  func stopCapture() {
    let stoppedSession = session
    session = nil
    // Also suppress a pending error/stopped callback from an earlier session.
    latestSessionID = nil
    let startTask = stoppedSession?.startTask
    stoppedSession?.startTask = nil
    let stream = stoppedSession?.stream

    guard let stoppedSession = stoppedSession else { return }
    stoppedSession.output.invalidate()
    startTask?.cancel()

    // A pending start cleans up its own stream after startCapture returns.
    // Only stop streams whose start has already completed here.
    if let stream = stream {
      stopStream(stream, output: stoppedSession.output)
    }
  }

  func setCapturing(_ capturing: Bool, framesPerSecond: Int) {
    guard capturing else {
      stopCapture()
      return
    }
    let framesPerSecond = max(1, min(framesPerSecond, Int(Int32.max)))
    guard session?.framesPerSecond != framesPerSecond else { return }
    // Capture configuration is immutable for a session. Changing FPS replaces
    // that session without reloading the shader or its per-display filter chain.
    stopCapture()
    startCapture(framesPerSecond: framesPerSecond)
  }

  private func isCurrentSession(_ candidate: CaptureSession) -> Bool {
    return session === candidate
  }

  private func stopStream(_ stream: SCStream, output: StreamOutput) {
    // An independent task can finish cleanup even when the task that started capture was cancelled.
    Task {
      do {
        try await stream.stopCapture()
        print("Stopped screen capture.")
      } catch {
        print("Failed to stop screen capture: \(error.localizedDescription)")
      }
      withExtendedLifetime(output) {}
    }
  }

  private func finishStarting(_ candidate: CaptureSession, stream: SCStream) -> Bool {
    guard session === candidate else { return false }
    candidate.stream = stream
    candidate.startTask = nil
    return true
  }

  private func captureStopped(sessionID: UUID, error: Error) {
    guard let stoppedSession = session, stoppedSession.id == sessionID else { return }
    session = nil
    let startTask = stoppedSession.startTask
    stoppedSession.startTask = nil

    stoppedSession.output.invalidate()
    startTask?.cancel()

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      let shouldNotify = self.latestSessionID == sessionID
      guard shouldNotify else { return }

      stoppedSession.onCaptureStopped()
      let streamError = error as NSError
      if streamError.domain != SCStreamError.errorDomain
        || streamError.code != SCStreamError.Code.userStopped.rawValue {
        print("Screen capture stopped: \(error.localizedDescription)")
        stoppedSession.onError(error)
      }
    }
  }
}

@MainActor
private final class CaptureSession {
  let id: UUID
  let output: StreamOutput
  let framesPerSecond: Int
  let onError: @MainActor (Error) -> Void
  let onCaptureStopped: @MainActor () -> Void
  // Session transitions are confined to the main actor, including after awaits.
  var stream: SCStream?
  var startTask: Task<Void, Never>?

  init(
    id: UUID, output: StreamOutput, framesPerSecond: Int,
    onError: @escaping @MainActor (Error) -> Void,
    onCaptureStopped: @escaping @MainActor () -> Void
  ) {
    self.id = id
    self.output = output
    self.framesPerSecond = framesPerSecond
    self.onError = onError
    self.onCaptureStopped = onCaptureStopped
  }
}

// The callbacks are immutable and Sendable. callbackLock guards active and drains
// any frame callback before invalidation returns, so stopped captures cannot refill the UI slot.
private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  private let onFrameReceived: @Sendable (CVPixelBuffer) -> Void
  private let onStopped: @Sendable (Error) -> Void
  private let callbackLock = NSRecursiveLock()
  private var active = true

  init(
    onFrameReceived: @escaping @Sendable (CVPixelBuffer) -> Void,
    onStopped: @escaping @Sendable (Error) -> Void
  ) {
    self.onFrameReceived = onFrameReceived
    self.onStopped = onStopped
  }

  func invalidate() {
    callbackLock.lock()
    active = false
    callbackLock.unlock()
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    invalidate()
    onStopped(error)
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    guard outputType == .screen, sampleBuffer.isValid,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        as? [[SCStreamFrameInfo: Any]],
      let status = attachments.first?[.status] as? Int,
      SCFrameStatus(rawValue: status) == .complete,
      let buffer = sampleBuffer.imageBuffer
    else { return }

    callbackLock.lock()
    defer { callbackLock.unlock() }
    guard active else { return }
    onFrameReceived(buffer)
  }
}
