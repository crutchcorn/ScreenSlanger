import ScreenCaptureKit

class ScreenCapture {
  var config: Config! = nil
  var excludedWindowIDs: [CGWindowID] = []
  var onFrameReceived: (CVPixelBuffer) -> Void = { _ in }
  private var capturing: Bool = false
  private var stream: SCStream?
  private var streamOutput: StreamOutput?
  private let streamQueue = DispatchQueue(label: "ScreenCaptureKitStreamQueue")
  private let screen: NSScreen
  
  init(screen: NSScreen) {
    self.screen = screen
  }
  
  /// Get the CGDirectDisplayID for the screen
  private func getDisplayID() -> CGDirectDisplayID {
    let screenNumber = self.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber
    return CGDirectDisplayID(screenNumber.uint32Value)
  }

  func startCapture() {
    if self.capturing {
      return
    }
    self.capturing = true
    
    let targetDisplayID = getDisplayID()

    Task {
      do {
        let content = try await SCShareableContent.current
        
        // Find the display matching our screen
        guard let display = content.displays.first(where: { $0.displayID == targetDisplayID }) else {
          print("Could not find display with ID \(targetDisplayID)")
          return
        }

        let excludedWindows = content.windows.filter { window in
          self.excludedWindowIDs.contains(window.windowID)
        }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        let scaleFactor = self.screen.backingScaleFactor

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = Int(CGFloat(display.width) * scaleFactor)
        streamConfig.height = Int(CGFloat(display.height) * scaleFactor)
        streamConfig.minimumFrameInterval = CMTime(
          value: 1, timescale: CMTimeScale(self.config.targetFPS))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.capturesAudio = false
        streamConfig.showsCursor = false

        self.stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
        self.streamOutput = StreamOutput(onFrameReceived: self.onFrameReceived)

        try self.stream!.addStreamOutput(
          self.streamOutput!, type: .screen, sampleHandlerQueue: self.streamQueue)

        try await self.stream!.startCapture()
        print("Started screen capture for display \(targetDisplayID)")
      } catch {
        print("Failed to start screen capture: \(error.localizedDescription)")
      }
    }
  }

  func stopCapture() {
    if !self.capturing {
      return
    }
    self.capturing = false
    
    // Clear callback immediately to prevent race conditions
    self.onFrameReceived = { _ in }
    
    // Capture references before the Task
    let stream = self.stream
    let streamOutput = self.streamOutput
    self.stream = nil
    self.streamOutput = nil

    Task {
      do {
        try await stream?.stopCapture()
        print("Stopped screen capture.")
      } catch {
        print("Failed to stop screen capture: \(error.localizedDescription)")
      }
    }
  }

  func setCapturing(_ capturing: Bool) {
    if capturing {
      self.startCapture()
    } else {
      self.stopCapture()
    }
  }
}

private class StreamOutput: NSObject, SCStreamOutput {
  private let onFrameReceived: (CVPixelBuffer) -> Void

  init(onFrameReceived: @escaping (CVPixelBuffer) -> Void) {
    self.onFrameReceived = onFrameReceived
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    guard outputType == .screen else { return }
    if let buffer = sampleBuffer.imageBuffer {
      self.onFrameReceived(buffer)
    }
  }
}
