import Foundation
import Testing

@Suite("Capture and GPU metrics")
struct MetricsTests {
  @Test("GPU completion, failures, and presentation stay distinct")
  func reportsPipelineStagesAndTimings() throws {
    let metrics = Metrics(startTime: 100)
    metrics.recordCapture()
    metrics.recordCapture()
    metrics.recordDroppedCapture(count: 2)
    metrics.recordSkippedRender()
    for _ in 0..<3 { metrics.recordSubmitted() }
    metrics.recordCompleted(captureTime: 100, completionTime: 100.25, gpuDuration: 0.01, succeeded: true)
    metrics.recordCompleted(captureTime: 101, completionTime: 101.75, gpuDuration: 0.03, succeeded: true)
    metrics.recordCompleted(captureTime: 100, completionTime: 101, gpuDuration: 1, succeeded: false)
    metrics.recordPresented()

    let snapshot = metrics.snapshot(at: 102)
    #expect(snapshot.duration == 2)
    #expect(snapshot.captureFPS == 1)
    #expect(snapshot.droppedCaptureFPS == 1)
    #expect(snapshot.skippedRenderFPS == 0.5)
    #expect(snapshot.submissionFPS == 1.5)
    #expect(snapshot.completionFPS == 1.5)
    #expect(snapshot.failureFPS == 0.5)
    #expect(snapshot.presentationFPS == 0.5)
    #expect(snapshot.failedRenders == 1)
    #expect(snapshot.averageCaptureToGPUCompletionSeconds == 0.5)
    let gpuDuration = try #require(snapshot.averageGPUDurationSeconds)
    #expect(abs(gpuDuration - 0.02) < 0.000_001)
  }

  @Test("Reset starts an empty interval and late completions belong to the new interval")
  func resetSeparatesIntervals() {
    let metrics = Metrics(startTime: 10)
    metrics.recordCapture()
    metrics.recordSubmitted()
    #expect(metrics.snapshot(at: 11).capturedFrames == 1)
    let first = metrics.reset(at: 12)
    #expect(first.capturedFrames == 1)
    #expect(first.submittedFrames == 1)

    let empty = metrics.snapshot(at: 13)
    #expect(empty.duration == 1)
    #expect(empty.captureFPS == 0)
    #expect(empty.submissionFPS == 0)
    #expect(empty.averageCaptureToGPUCompletionSeconds == nil)
    #expect(empty.averageGPUDurationSeconds == nil)

    metrics.recordCompleted(captureTime: 11, completionTime: 13, gpuDuration: nil, succeeded: true)
    let next = metrics.snapshot(at: 14)
    #expect(next.capturedFrames == 0)
    #expect(next.completedFrames == 1)
    #expect(next.completionFPS == 0.5)
    #expect(next.averageCaptureToGPUCompletionSeconds == 2)
  }

  @Test("Unavailable timing values do not masquerade as zero latency")
  func ignoresInvalidTimingSamples() {
    let metrics = Metrics(startTime: 10)
    metrics.recordDroppedCapture(count: -1)
    metrics.recordCompleted(captureTime: 11, completionTime: 10, gpuDuration: .nan, succeeded: true)
    metrics.recordCompleted(captureTime: .nan, completionTime: 12, gpuDuration: -1, succeeded: true)
    let snapshot = metrics.snapshot(at: 10)

    #expect(snapshot.completedFrames == 2)
    #expect(snapshot.failedRenders == 0)
    #expect(snapshot.droppedCaptures == 0)
    #expect(snapshot.completionFPS == 0)
    #expect(snapshot.averageCaptureToGPUCompletionSeconds == nil)
    #expect(snapshot.averageGPUDurationSeconds == nil)
  }

  @Test("Concurrent callbacks retain every event")
  func concurrentCallbacksAreCounted() {
    let metrics = Metrics(startTime: 10)
    DispatchQueue.concurrentPerform(iterations: 200) { _ in
      metrics.recordCapture()
      metrics.recordSubmitted()
      metrics.recordCompleted(captureTime: 10, completionTime: 11, gpuDuration: 0.01, succeeded: true)
      metrics.recordPresented()
    }
    let snapshot = metrics.snapshot(at: 12)
    #expect(snapshot.capturedFrames == 200)
    #expect(snapshot.submittedFrames == 200)
    #expect(snapshot.completedFrames == 200)
    #expect(snapshot.presentedFrames == 200)
    #expect(snapshot.averageCaptureToGPUCompletionSeconds == 1)
  }
}
