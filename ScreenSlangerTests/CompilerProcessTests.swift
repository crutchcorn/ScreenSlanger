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


extension CompilerProcessTests {
    private func withHangingCompiler(
        _ body: (Process, URL) throws -> Void
    ) throws {
        let products = Bundle(for: CompilerProbeBundle.self).bundleURL.deletingLastPathComponent()
        let executable = products.appendingPathComponent("ShaderCompilerProbe")
        try #require(FileManager.default.isExecutableFile(atPath: executable.path))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--hang"]
        try body(process, temporary.appendingPathComponent("compiler.log"))
    }

    @Test("A hung compiler is killed and reaped within its deadline")
    func compilerTimeout() throws {
        try withHangingCompiler { process, log in
            let start = ContinuousClock.now
            do {
                _ = try runShaderCompilerProcess(process, outputFile: log, timeout: 0.3)
                Issue.record("Hung compiler unexpectedly completed")
            } catch SlangCompilerError.timedOut {
                #expect(!process.isRunning)
                #expect(process.terminationReason == .uncaughtSignal)
                #expect(ContinuousClock.now - start < .seconds(3))
            }
        }
    }

    @Test("Cancellation stops an already running compiler")
    func compilerCancellation() throws {
        let cancellation = ShaderCompilationCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { cancellation.cancel() }
        try withHangingCompiler { process, log in
            let start = ContinuousClock.now
            do {
                _ = try runShaderCompilerProcess(process, outputFile: log,
                                                  cancellation: cancellation, timeout: 5)
                Issue.record("Cancelled compiler unexpectedly completed")
            } catch is CancellationError {
                #expect(!process.isRunning)
                #expect(ContinuousClock.now - start < .seconds(3))
            }
        }
    }

    @Test("An already cancelled request does not launch a compiler")
    func cancelledBeforeLaunch() throws {
        let cancellation = ShaderCompilationCancellation()
        cancellation.cancel()
        try withHangingCompiler { process, log in
            #expect(throws: CancellationError.self) {
                try runShaderCompilerProcess(process, outputFile: log, cancellation: cancellation)
            }
            #expect(process.processIdentifier == 0)
            #expect(!FileManager.default.fileExists(atPath: log.path))
        }
    }
}

@Suite(.serialized)
struct NativeCompilerTests {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Slang fixture \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test("Native imports track transitive includes and invalidate cached output")
    func importAndTransitiveIncludeChanges() throws {
        try #require(SlangCompiler.isAvailable, "Install the compiler with scripts/setup-dependencies.sh")
        try withDirectory { directory in
            let effect = directory.appendingPathComponent("effect.slang")
            let module = directory.appendingPathComponent("gain.slang")
            let include = directory.appendingPathComponent("nested header.slangh")
            try "float gain() { return 0.25; }".write(to: include, atomically: true, encoding: .utf8)
            try "module gain;\n#include \"nested header.slangh\"\npublic float moduleGain() { return gain(); }"
                .write(to: module, atomically: true, encoding: .utf8)
            let source = "import gain;\nfloat4 shaderFunction(ShaderInput input) { return float4(moduleGain(),0,0,1); }"
            try source.write(to: effect, atomically: true, encoding: .utf8)
            let wrapped = SlangCompiler.wrapEffectSource(source, sourceURL: effect)
            func compile() throws -> String {
                try SlangCompiler.compileToMetal(slangSource: wrapped, sourceURL: effect)
            }
            let first = try compile()
            #expect(first.contains("0.25f"))
            #expect(try compile() == first)
            // An atomic save replaces the included file without changing the root source.
            try "float gain() { return 0.75; }".write(to: include, atomically: true, encoding: .utf8)
            let changed = try compile()
            #expect(changed.contains("0.75f"))
            #expect(changed != first)
            // Failed replacements cannot fall back to an older successful artifact.
            try "float gain() { return missingIncludedSymbol; }".write(to: include, atomically: true, encoding: .utf8)
            for _ in 0..<2 {
                do {
                    _ = try compile()
                    Issue.record("Invalid included shader returned a stale cached result")
                } catch SlangCompilerError.compilationFailed(let diagnostic) {
                    #expect(diagnostic.contains("missingIncludedSymbol"))
                    #expect(diagnostic.contains("nested header.slangh"))
                }
            }
            try "float gain() { return 0.5; }".write(to: include, atomically: true, encoding: .utf8)
            #expect(try compile().contains("0.5f"))
        }
    }

    @Test("Native include search roots and original diagnostic line numbers are preserved")
    func includeRootsAndDiagnostics() throws {
        try #require(SlangCompiler.isAvailable)
        try withDirectory { directory in
            let sourceDirectory = directory.appendingPathComponent("shaders")
            let includes = directory.appendingPathComponent("includes")
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: includes, withIntermediateDirectories: true)
            try "float4 effectColor() { return float4(0,1,0,1); }"
                .write(to: includes.appendingPathComponent("color.slangh"), atomically: true, encoding: .utf8)
            let effect = sourceDirectory.appendingPathComponent("original effect.slang")
            let source = "#include \"color.slangh\"\nfloat4 shaderFunction(ShaderInput input) { return effectColor(); }"
            let output = try SlangCompiler.compileToMetal(
                slangSource: SlangCompiler.wrapEffectSource(source, sourceURL: effect),
                sourceURL: effect, includeDirectories: [includes])
            #expect(output.contains("effectColor"))
            do {
                _ = try SlangCompiler.compileToMetal(slangSource: SlangCompiler.wrapEffectSource(
                    "// original line one\nfloat4 shaderFunction(ShaderInput input) { return missingOriginalSymbol; }",
                    sourceURL: effect), sourceURL: effect)
                Issue.record("Invalid shader compiled")
            } catch SlangCompilerError.compilationFailed(let diagnostic) {
                #expect(diagnostic.contains(effect.path + ":2:") || diagnostic.contains(effect.path + "(2)"))
                #expect(diagnostic.contains("missingOriginalSymbol"))
            }
        }
    }

    @Test("Compiler dependency paths preserve escaped spaces, hashes, dollars and continuations")
    func makeDependencyPaths() {
        let directory = URL(fileURLWithPath: "/tmp/dependencies")
        let paths = SlangCompiler.dependencyPaths(
            from: "shader.metal: nested\\ header.slangh escaped\\#name.slang dollar$$name.slang \\\n module.slang\n",
            relativeTo: directory)
        #expect(paths.map(\.lastPathComponent) == ["nested header.slangh", "escaped#name.slang", "dollar$name.slang", "module.slang"])
    }
}
