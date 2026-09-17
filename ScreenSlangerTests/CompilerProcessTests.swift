import Darwin
import Foundation
import Testing

private final class CompilerProbeBundle: NSObject {}

struct CompilerProcessTests {
    @Test("Large compiler output returns without a pipe deadlock")
    func largeCompilerDiagnostic() throws {
        let products = Bundle(for: CompilerProbeBundle.self).bundleURL.deletingLastPathComponent()
        let executable = products.appendingPathComponent("ShaderCompilerProbe")
        try #require(FileManager.default.isExecutableFile(atPath: executable.path),
                     "Missing ShaderCompilerProbe test helper")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outputURL = temporary.appendingPathComponent("probe.log")
        try Data().write(to: outputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--verify"]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let timedOut = process.isRunning
        if timedOut {
            // The verifier creates this process group before starting its child.
            // Also kill the verifier directly in case it stalled before setup.
            kill(-process.processIdentifier, SIGKILL)
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        try #require(!timedOut, "Compiler output handling blocked for more than five seconds")
        let diagnostic = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(process.terminationStatus == 0, "Large-output compiler probe failed: \(diagnostic)")
    }
}
