import Foundation
import Synchronization

/// Capture callbacks and Metal completion callbacks can update these counters
/// directly. The lock protects only fixed-size state; no per-frame work is queued.
final class Metrics: Sendable {
  struct Snapshot: Sendable {
    let duration: TimeInterval
    let capturedFrames: Int
    let droppedCaptures: Int
    let skippedRenders: Int
    let submittedFrames: Int
    /// Includes failed completions, which are also counted in failedRenders.
    let completedFrames: Int
    let failedRenders: Int
    let presentedFrames: Int
    /// Successful GPU completion minus the capture timestamp. This is not
    /// display latency: presentation may happen later and images can be reused.
    let averageCaptureToGPUCompletionSeconds: TimeInterval?
    let averageGPUDurationSeconds: TimeInterval?

    var captureFPS: Double { rate(capturedFrames) }
    var droppedCaptureFPS: Double { rate(droppedCaptures) }
    var skippedRenderFPS: Double { rate(skippedRenders) }
    var submissionFPS: Double { rate(submittedFrames) }
    var completionFPS: Double { rate(completedFrames) }
    var failureFPS: Double { rate(failedRenders) }
    var presentationFPS: Double { rate(presentedFrames) }

    private func rate(_ count: Int) -> Double {
      duration > 0 ? Double(count) / duration : 0
    }
  }

  private struct State: Sendable {
    var startTime: TimeInterval
    var capturedFrames = 0
    var droppedCaptures = 0
    var skippedRenders = 0
    var submittedFrames = 0
    var completedFrames = 0
    var failedRenders = 0
    var presentedFrames = 0
    var totalCaptureToCompletion: TimeInterval = 0
    var captureTimingSamples = 0
    var totalGPUDuration: TimeInterval = 0
    var gpuTimingSamples = 0
    var lastReport: Snapshot?

    func snapshot(at now: TimeInterval) -> Snapshot {
      let elapsed = now - startTime
      return Snapshot(
        duration: elapsed.isFinite ? max(elapsed, 0) : 0,
        capturedFrames: capturedFrames, droppedCaptures: droppedCaptures,
        skippedRenders: skippedRenders, submittedFrames: submittedFrames,
        completedFrames: completedFrames, failedRenders: failedRenders,
        presentedFrames: presentedFrames,
        averageCaptureToGPUCompletionSeconds: captureTimingSamples > 0
          ? totalCaptureToCompletion / Double(captureTimingSamples) : nil,
        averageGPUDurationSeconds: gpuTimingSamples > 0
          ? totalGPUDuration / Double(gpuTimingSamples) : nil)
    }
  }

  private let state: Mutex<State>

  init(startTime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    state = Mutex(State(startTime: startTime))
  }

  func recordCapture() {
    state.withLock { $0.capturedFrames += 1 }
  }

  func recordDroppedCapture(count: Int = 1) {
    guard count > 0 else { return }
    state.withLock { $0.droppedCaptures += count }
  }

  func recordSkippedRender() {
    state.withLock { $0.skippedRenders += 1 }
  }

  func recordSubmitted() {
    state.withLock { $0.submittedFrames += 1 }
  }

  func recordCompleted(
    captureTime: TimeInterval,
    completionTime: TimeInterval = ProcessInfo.processInfo.systemUptime,
    gpuDuration: TimeInterval?,
    succeeded: Bool
  ) {
    state.withLock { state in
      state.completedFrames += 1
      guard succeeded else {
        state.failedRenders += 1
        return
      }

      let captureToCompletion = completionTime - captureTime
      if captureToCompletion.isFinite, captureToCompletion >= 0 {
        state.totalCaptureToCompletion += captureToCompletion
        state.captureTimingSamples += 1
      }
      if let gpuDuration, gpuDuration.isFinite, gpuDuration >= 0 {
        state.totalGPUDuration += gpuDuration
        state.gpuTimingSamples += 1
      }
    }
  }

  func recordPresented() {
    state.withLock { $0.presentedFrames += 1 }
  }

  /// Reads the current window without consuming its counters.
  func snapshot(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Snapshot {
    state.withLock { $0.snapshot(at: now) }
  }

  /// Finishes the current window and starts the next one atomically. Events
  /// belong to the window when their callbacks arrive, including GPU completions.
  @discardableResult
  func reset(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Snapshot {
    state.withLock { state in
      let report = state.snapshot(at: now)
      state = State(startTime: now, lastReport: report)
      return report
    }
  }

  func updateStats() {
    reset()
  }

  func printStats() {
    let now = ProcessInfo.processInfo.systemUptime
    let report = state.withLock { $0.lastReport ?? $0.snapshot(at: now) }
    print("Capture FPS: \(format(report.captureFPS)); submitted GPU FPS: \(format(report.submissionFPS)); completed GPU FPS: \(format(report.completionFPS)); presented FPS: \(format(report.presentationFPS))")
    print("Dropped captures: \(report.droppedCaptures); skipped renders: \(report.skippedRenders); failed GPU commands: \(report.failedRenders)")
    print("Capture to GPU completion (ms): \(milliseconds(report.averageCaptureToGPUCompletionSeconds)); GPU duration (ms): \(milliseconds(report.averageGPUDurationSeconds))")
  }

  private func format(_ value: Double) -> String {
    String(format: "%.2f", value)
  }

  private func milliseconds(_ value: TimeInterval?) -> String {
    value.map { format($0 * 1000) } ?? "n/a"
  }
}
