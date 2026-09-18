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
        try #require(SlangCompiler.isAvailable, "Build the bundled shader dependencies before running unhosted compiler tests")
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
            // In-place edits with preserved timestamps still invalidate by content.
            let date = try FileManager.default.attributesOfItem(atPath: include.path)[.modificationDate]
            try "float gain() { return 0.75; }".write(to: include, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: try #require(date)], ofItemAtPath: include.path)
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
            // A new local header takes precedence over the previously resolved include root.
            try "float4 effectColor() { return float4(0.5,0,0,1); }"
                .write(to: sourceDirectory.appendingPathComponent("color.slangh"), atomically: true, encoding: .utf8)
            let shadowed = try SlangCompiler.compileToMetal(
                slangSource: SlangCompiler.wrapEffectSource(source, sourceURL: effect),
                sourceURL: effect, includeDirectories: [includes])
            #expect(shadowed.contains("0.5f"))
            #expect(shadowed != output)
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


struct CompilerLocationTests {
    private func withFixture(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Compiler bundle fixture \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func fixtureBundle(at url: URL) throws -> Bundle {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: String] = [
            "CFBundlePackageType": url.pathExtension == "app" ? "APPL" : "BNDL", "CFBundleIdentifier": "io.github.crutchcorn.compiler-fixture",
            "CFBundleName": "Compiler Fixture", "CFBundleExecutable": "CompilerFixture"
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        return try #require(Bundle(url: url))
    }

    private func executable(at url: URL, executable: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("compiler fixture".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    }

    @Test("The app's bundled compiler takes precedence over development overrides")
    func bundledCompilerWins() throws {
        try withFixture { directory in
            let bundle = try fixtureBundle(at: directory.appendingPathComponent("ScreenSlanger.app"))
            let embedded = bundle.bundleURL.appendingPathComponent("Contents/Helpers/Slang.app/Contents/MacOS/slangc")
            let override = directory.appendingPathComponent("other-slangc")
            try executable(at: embedded)
            try executable(at: override)
            let found = SlangCompiler.findSlangc(bundle: bundle,
                environment: ["SLANG_PATH": override.path], homeDirectory: directory)
            #expect(found == embedded.path)
        }
    }

    @Test("Moving the app retains compiler discovery without an installation or environment override")
    func relocatedBundleIsSelfContained() throws {
        try withFixture { directory in
            let original = directory.appendingPathComponent("Original.app")
            let bundle = try fixtureBundle(at: original)
            let relativeCompiler = "Contents/Helpers/Slang.app/Contents/MacOS/slangc"
            try executable(at: bundle.bundleURL.appendingPathComponent(relativeCompiler))
            let relocated = directory.appendingPathComponent("Moved app.app")
            try FileManager.default.moveItem(at: original, to: relocated)
            let movedBundle = try #require(Bundle(url: relocated))
            let found = SlangCompiler.findSlangc(bundle: movedBundle, environment: [:],
                                               homeDirectory: directory.appendingPathComponent("empty-home"))
            #expect(found == relocated.appendingPathComponent(relativeCompiler).path)
            #expect(!FileManager.default.fileExists(atPath: original.path))
        }
    }

    @Test("An incomplete app never borrows a developer's compiler")
    func incompleteAppCannotUseDeveloperFallback() throws {
        try withFixture { directory in
            let bundle = try fixtureBundle(at: directory.appendingPathComponent("Incomplete.app"))
            let embedded = bundle.bundleURL.appendingPathComponent("Contents/Helpers/Slang.app/Contents/MacOS/slangc")
            let override = directory.appendingPathComponent("developer-slangc")
            let managed = directory.appendingPathComponent("Library/Application Support/ScreenSlanger/Tools/slang/current/bin/slangc")
            try executable(at: override)
            try executable(at: managed)
            #expect(SlangCompiler.findSlangc(bundle: bundle,
                environment: ["SLANG_PATH": override.path], homeDirectory: directory) == nil)
            try executable(at: embedded, executable: false)
            #expect(SlangCompiler.findSlangc(bundle: bundle,
                environment: ["SLANG_PATH": override.path], homeDirectory: directory) == nil)
        }
    }

    @Test("Unhosted tools use an explicit compiler when no executable is bundled")
    func developerOverrideFallback() throws {
        try withFixture { directory in
            let bundle = try fixtureBundle(at: directory.appendingPathComponent("Unhosted.bundle"))
            let embedded = bundle.bundleURL.appendingPathComponent("Contents/Helpers/Slang.app/Contents/MacOS/slangc")
            let override = directory.appendingPathComponent("developer-slangc")
            try executable(at: embedded, executable: false)
            try executable(at: override)
            #expect(SlangCompiler.findSlangc(bundle: bundle,
                environment: ["SLANG_PATH": override.path], homeDirectory: directory) == override.path)
            // An executable directory is not a compiler, even when its permissions allow traversal.
            try FileManager.default.removeItem(at: embedded)
            try FileManager.default.createDirectory(at: embedded, withIntermediateDirectories: true)
            #expect(SlangCompiler.findSlangc(bundle: bundle,
                environment: ["SLANG_PATH": override.path], homeDirectory: directory) == override.path)
        }
    }

    @Test("RetroArch helper discovery follows the moved app and ignores developer overrides")
    func relocatedRetroArchCompiler() throws {
        try withFixture { directory in
            let original = directory.appendingPathComponent("Original.app")
            _ = try fixtureBundle(at: original)
            let relative = "Contents/Helpers/librashader-compiler"
            try executable(at: original.appendingPathComponent(relative))
            let other = directory.appendingPathComponent("developer/librashader-compiler")
            try executable(at: other)
            let moved = directory.appendingPathComponent("Moved app.app")
            try FileManager.default.moveItem(at: original, to: moved)
            let bundle = try #require(Bundle(url: moved))
            #expect(RetroArchCompilerLocation.findCompiler(
                runtimeURL: other.deletingLastPathComponent().appendingPathComponent("librashader.dylib"),
                bundle: bundle, environment: ["LIBRASHADER_COMPILER_PATH": other.path])
                    == moved.appendingPathComponent(relative).path)
            try FileManager.default.removeItem(at: moved.appendingPathComponent(relative))
            #expect(RetroArchCompilerLocation.findCompiler(
                runtimeURL: other.deletingLastPathComponent().appendingPathComponent("librashader.dylib"),
                bundle: bundle, environment: ["LIBRASHADER_COMPILER_PATH": other.path]) == nil)
        }
    }

    @Test("Unhosted RetroArch tools use the selected runtime's adjacent helper or an explicit override")
    func developmentRetroArchCompiler() throws {
        try withFixture { directory in
            let bundle = try fixtureBundle(at: directory.appendingPathComponent("Unhosted.bundle"))
            let runtime = directory.appendingPathComponent("selected-runtime/librashader.dylib")
            let adjacent = runtime.deletingLastPathComponent().appendingPathComponent("librashader-compiler")
            let other = directory.appendingPathComponent("different compiler")
            try executable(at: adjacent)
            try executable(at: other)
            #expect(RetroArchCompilerLocation.findCompiler(runtimeURL: runtime, bundle: bundle,
                environment: [:]) == adjacent.path)
            #expect(RetroArchCompilerLocation.findCompiler(runtimeURL: runtime, bundle: bundle,
                environment: ["LIBRASHADER_COMPILER_PATH": other.path]) == other.path)
            try FileManager.default.removeItem(at: adjacent)
            try FileManager.default.createDirectory(at: adjacent, withIntermediateDirectories: true)
            #expect(RetroArchCompilerLocation.findCompiler(runtimeURL: runtime, bundle: bundle,
                environment: [:]) == nil)
            try executable(at: other, executable: false)
            #expect(RetroArchCompilerLocation.findCompiler(runtimeURL: runtime, bundle: bundle,
                environment: ["LIBRASHADER_COMPILER_PATH": other.path]) == nil)
        }
    }
}
