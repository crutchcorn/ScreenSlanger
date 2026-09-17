import CryptoKit
import Darwin
import Foundation
import Synchronization

/// Errors that can occur during Slang shader compilation
enum SlangCompilerError: Error, LocalizedError {
    case slangcNotFound
    case compilationFailed(String)
    case invalidOutput
    case processError(String)
    case timedOut(TimeInterval)
    
    var errorDescription: String? {
        switch self {
        case .slangcNotFound:
            return "slangc compiler not found. Run scripts/setup-dependencies.sh or set SLANG_PATH to the compiler executable."
        case .compilationFailed(let message):
            return "Slang compilation failed: \(message)"
        case .invalidOutput:
            return "Slang compiler produced invalid output"
        case .processError(let message):
            return "Process error: \(message)"
        case .timedOut(let seconds):
            return "Shader compilation exceeded \(seconds) seconds"
        }
    }
}

/// Represents a shader parameter parsed from #pragma parameter directives
/// Format: #pragma parameter NAME "Description" default min max step
struct ShaderParameter: Sendable {
    let name: String
    let description: String
    let defaultValue: Float
    let minValue: Float
    let maxValue: Float
    let stepValue: Float
    
    /// Parse a #pragma parameter line
    /// Example: #pragma parameter DARKEN_COLOUR "Darken Colours" 0.0 0.0 2.0 0.05
    static func parse(from line: String) -> ShaderParameter? {
        // Remove the #pragma parameter prefix
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#pragma parameter") else { return nil }
        
        let content = String(trimmed.dropFirst("#pragma parameter".count))
            .trimmingCharacters(in: .whitespaces)
        
        // Parse: NAME "Description" default min max [step]
        let scanner = Scanner(string: content)
        scanner.charactersToBeSkipped = CharacterSet.whitespaces
        
        // Parse name
        guard let name = scanner.scanUpToCharacters(from: .whitespaces) else { return nil }
        
        // Parse quoted description
        guard scanner.scanString("\"") != nil else { return nil }
        guard let description = scanner.scanUpToString("\"") else { return nil }
        guard scanner.scanString("\"") != nil else { return nil }
        
        // Parse numeric values
        guard let defaultValue = scanner.scanFloat() else { return nil }
        guard let minValue = scanner.scanFloat() else { return nil }
        guard let maxValue = scanner.scanFloat() else { return nil }
        
        // Step is optional
        let stepValue = scanner.scanFloat() ?? 0.01
        
        return ShaderParameter(
            name: name,
            description: description,
            defaultValue: defaultValue,
            minValue: minValue,
            maxValue: maxValue,
            stepValue: stepValue
        )
    }
}

/// Result of preprocessing a RetroArch-style shader
struct PreprocessedShader: Sendable {
    let source: String
    let parameters: [ShaderParameter]
    let isRetroArchStyle: Bool
}

/// Shared between a UI task and its synchronous compiler worker. The compiler owns
/// its Process, so cancellation never touches Foundation process state across threads.
final class ShaderCompilationCancellation: Sendable {
    private let cancelled = Mutex(false)

    func cancel() {
        cancelled.withLock { $0 = true }
    }

    func checkCancellation() throws {
        if cancelled.withLock({ $0 }) { throw CancellationError() }
    }
}

/// Capture both output streams on disk so verbose diagnostics cannot fill a pipe.
/// Call from a worker: a bounded poll makes cancellation independent of compiler output.
func runShaderCompilerProcess(
    _ process: Process,
    outputFile: URL,
    cancellation: ShaderCompilationCancellation? = nil,
    timeout: TimeInterval = 30
) throws -> String {
    try cancellation?.checkCancellation()
    guard timeout.isFinite, timeout >= 0 else {
        throw SlangCompilerError.processError("Compiler timeout must be a finite, nonnegative duration")
    }
    try Data().write(to: outputFile)
    let outputHandle = try FileHandle(forWritingTo: outputFile)
    defer { try? outputHandle.close() }
    process.standardOutput = outputHandle
    process.standardError = outputHandle
    try process.run()

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(max(0, timeout)))
    do {
        while process.isRunning {
            try cancellation?.checkCancellation()
            if clock.now >= deadline { throw SlangCompilerError.timedOut(timeout) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        try cancellation?.checkCancellation()
    } catch {
        if process.isRunning {
            process.terminate()
            let grace = clock.now.advanced(by: .milliseconds(100))
            while process.isRunning && clock.now < grace {
                Thread.sleep(forTimeInterval: 0.005)
            }
            // A compiler can ignore SIGTERM. Always reap it before removing its files.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        throw error
    }
    return String(decoding: try Data(contentsOf: outputFile), as: UTF8.self)
}

/// Wrapper for the Slang shader compiler
class SlangCompiler {
    
    /// Read the override on each request, and resolve managed installation symlinks
    /// in the cache identity so an upgraded compiler never reuses an old artifact.
    static func findSlangc() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            ProcessInfo.processInfo.environment["SLANG_PATH"],
            home.appendingPathComponent("Library/Application Support/ScreenSlanger/Tools/slang/current/bin/slangc").path,
            "/opt/homebrew/bin/slangc",
            "/usr/local/bin/slangc",
            Bundle.main.path(forResource: "slangc", ofType: nil),
            "/usr/local/slang/bin/slangc",
            home.appendingPathComponent(".slang/bin/slangc").path,
            home.appendingPathComponent("slang/bin/slangc").path
        ].compactMap { $0 }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private struct CachedCompilation: Sendable {
        let metalSource: String
        let dependencies: [URL: Data]
        let searchDirectories: [URL: Date]
    }

    private static let cache = Mutex<[String: CachedCompilation]>([:])

    static func invalidateCache() {
        cache.withLock { $0.removeAll() }
    }

    private static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// Search directory timestamps catch newly added files that can shadow a previous
    /// include/import. Dependency contents (not timestamps) catch edits to existing files.
    private static func directorySnapshot(_ roots: [URL]) -> [URL: Date] {
        var snapshot: [URL: Date] = [:]
        for root in roots {
            if let date = try? root.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                snapshot[root] = date
            }
            guard let directories = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: []) else { continue }
            for case let directory as URL in directories {
                if directory.lastPathComponent == ".git" { directories.skipDescendants(); continue }
                if let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                   values.isDirectory == true, let date = values.contentModificationDate {
                    snapshot[directory] = date
                }
            }
        }
        return snapshot
    }

    /// Parse the compiler's Make-style dependency file, including escaped paths.
    /// Asking slangc is essential: regex scanning misses conditional includes and imports.
    static func dependencyPaths(from depfile: String, relativeTo directory: URL) -> [URL] {
        var escaped = false
        var foundTarget = false
        var token = ""
        var paths: [String] = []
        for character in depfile {
            if escaped {
                if character != "\n" && character != "\r" { token.append(character) }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if !foundTarget && character == ":" {
                foundTarget = true
                token = ""
            } else if character.isWhitespace {
                if foundTarget && !token.isEmpty { paths.append(token) }
                token = ""
            } else {
                token.append(character)
            }
        }
        if foundTarget && !token.isEmpty { paths.append(token) }
        return paths.map { path in
            URL(fileURLWithPath: path.replacingOccurrences(of: "$$", with: "$"), relativeTo: directory)
                .standardizedFileURL.resolvingSymlinksInPath()
        }
    }

    private static func escapedLinePath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Check if Slang compiler is available
    static var isAvailable: Bool {
        return findSlangc() != nil
    }
    
    /// Compile Slang shader source code to Metal Shading Language (MSL)
    /// - Parameters:
    ///   - slangSource: The complete Slang shader source code
    ///   - entryPoint: The name of the entry point function (default: "fragmentMain")
    ///   - stage: The shader stage (default: "fragment")
    /// - Returns: The generated Metal shader source code
    static func compileToMetal(
        slangSource: String,
        entryPoint: String = "fragmentMain",
        stage: String = "fragment",
        sourceURL: URL? = nil,
        includeDirectories: [URL] = [],
        cancellation: ShaderCompilationCancellation? = nil,
        timeout: TimeInterval = 30
    ) throws -> String {
        try cancellation?.checkCancellation()
        guard let slangcPath = findSlangc() else { throw SlangCompilerError.slangcNotFound }
        let compilerURL = URL(fileURLWithPath: slangcPath).resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: compilerURL.path)
        // Native distributions keep their compiler libraries adjacent to bin/. Including
        // that directory's identity also invalidates updates that only replace a dylib.
        let libraryDirectory = compilerURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib")
        let libraryFiles = (try? FileManager.default.contentsOfDirectory(at: libraryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        let libraryIdentity = libraryFiles.sorted { $0.path < $1.path }.map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "\(url.path):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values?.fileSize ?? 0)"
        }.joined(separator: "|")
        var roots = ([sourceURL?.deletingLastPathComponent()].compactMap { $0 } + includeDirectories)
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        var seen = Set<URL>()
        roots = roots.filter { seen.insert($0).inserted }
        let keyParts = [slangSource, entryPoint, stage, sourceURL?.path ?? "", compilerURL.path,
                        String(describing: attributes[.modificationDate]), String(describing: attributes[.size]),
                        libraryIdentity] + roots.map(\.path)
        let key = digest(try JSONEncoder().encode(keyParts)).base64EncodedString()
        let directories = directorySnapshot(roots)
        if let cached = cache.withLock({ $0[key] }), cached.searchDirectories == directories,
           cached.dependencies.allSatisfy({ url, fingerprint in
               (try? Data(contentsOf: url)).map(digest) == fingerprint
           }) {
            try cancellation?.checkCancellation()
            return cached.metalSource
        }
        // Evict stale successes before starting a replacement, including failed retries.
        _ = cache.withLock { $0.removeValue(forKey: key) }
        let startedAt = Date()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let inputFile = tempDir.appendingPathComponent("shader.slang")
        let outputFile = tempDir.appendingPathComponent("shader.metal")
        let depfile = tempDir.appendingPathComponent("shader.d")
        let source = sourceURL.map { "#line 1 \"\(escapedLinePath($0))\"\n" + slangSource } ?? slangSource
        try source.write(to: inputFile, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = compilerURL
        process.currentDirectoryURL = sourceURL?.deletingLastPathComponent() ?? tempDir
        process.arguments = [inputFile.path, "-target", "metal", "-entry", entryPoint,
                             "-stage", stage, "-o", outputFile.path, "-depfile", depfile.path]
            + roots.flatMap { ["-I", $0.path] }
        let diagnostics: String
        do {
            diagnostics = try runShaderCompilerProcess(process,
                outputFile: tempDir.appendingPathComponent("slangc.log"),
                cancellation: cancellation, timeout: timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SlangCompilerError {
            throw error
        } catch {
            throw SlangCompilerError.processError(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            throw SlangCompilerError.compilationFailed(
                diagnostics.isEmpty ? "slangc exited with code \(process.terminationStatus)" : diagnostics)
        }
        guard let metalSource = try? String(contentsOf: outputFile, encoding: .utf8), !metalSource.isEmpty else {
            throw SlangCompilerError.invalidOutput
        }
        try cancellation?.checkCancellation()
        if let dependencies = try? String(contentsOf: depfile, encoding: .utf8) {
            let paths = dependencyPaths(from: dependencies, relativeTo: process.currentDirectoryURL ?? tempDir)
                .filter { $0 != inputFile.resolvingSymlinksInPath() }
            var fingerprints: [URL: Data] = [:]
            var stable = true
            for url in paths {
                guard let data = try? Data(contentsOf: url),
                      let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      date <= startedAt else { stable = false; break }
                fingerprints[url] = digest(data)
            }
            // Do not cache a compile raced by filesystem changes or an incomplete depfile.
            if stable && !dependencies.isEmpty && directorySnapshot(roots) == directories {
                let entry = CachedCompilation(metalSource: metalSource, dependencies: fingerprints,
                                              searchDirectories: directories)
                cache.withLock {
                    if $0.count >= 32 { $0.removeAll(keepingCapacity: true) }
                    $0[key] = entry
                }
            }
        }
        return metalSource
    }

    /// Wrap user-provided Slang effect code with the ScreenSlanger framework code
    /// This creates a complete Slang shader that matches ScreenSlanger's expectations
    static func wrapEffectSource(_ effectSource: String, sourceURL: URL? = nil) -> String {
        let origin = sourceURL.map { "#line 1 \"\(escapedLinePath($0))\"" } ?? "#line 1 \"effect.slang\""
        return """
        #line 1 "ScreenSlanger-wrapper.slang"
        // ScreenSlanger Slang wrapper
        // This shader is compiled from Slang to Metal
        
        // Input texture and sampler
        Texture2D<float4> inputTexture : register(t0);
        SamplerState textureSampler : register(s0);
        
        // Uniform parameters passed from the application
        struct Uniforms {
            float2 screenSize;
            float2 mousePosition;
            float time;
        };
        
        ConstantBuffer<Uniforms> uniforms : register(b0);
        
        // Shader input structure matching ScreenSlanger's ShaderInput
        struct ShaderInput {
            Texture2D<float4> inputTexture;
            SamplerState sampler;
            float2 texCoord;
            float2 screenPosition;
            float2 screenSize;
            float2 mousePosition;
            float time;
            
            // Method to sample the input texture
            float4 sample(float2 uv) {
                return inputTexture.Sample(sampler, uv);
            }
        };
        
        // Utility functions
        float2 texToScreen(float2 texCoord, float2 screenSize) {
            return float2(texCoord.x * screenSize.x, (1.0 - texCoord.y) * screenSize.y);
        }
        
        float2 screenToTex(float2 screenPosition, float2 screenSize) {
            return float2(screenPosition.x / screenSize.x, 1.0 - screenPosition.y / screenSize.y);
        }
        
        // Sample the input texture at the given texture coordinates
        float4 sampleInput(float2 texCoord) {
            return inputTexture.Sample(textureSampler, texCoord);
        }
        
        // ========== USER EFFECT CODE BEGIN ==========
        \(origin)
        \(effectSource)
        #line 1 "ScreenSlanger-wrapper.slang"
        // ========== USER EFFECT CODE END ==========
        
        // Fragment shader output
        struct FragmentOutput {
            float4 color : SV_Target0;
        };
        
        // Fragment shader input from vertex shader
        struct FragmentInput {
            float4 position : SV_Position;
            float2 texCoord : TEXCOORD0;
        };
        
        // Main fragment shader entry point
        [shader("fragment")]
        FragmentOutput fragmentMain(FragmentInput input) {
            ShaderInput shaderInput;
            shaderInput.inputTexture = inputTexture;
            shaderInput.sampler = textureSampler;
            shaderInput.texCoord = input.texCoord;
            shaderInput.screenSize = uniforms.screenSize;
            shaderInput.screenPosition = texToScreen(input.texCoord, uniforms.screenSize);
            shaderInput.mousePosition = uniforms.mousePosition;
            shaderInput.time = uniforms.time;
            
            FragmentOutput output;
            output.color = shaderFunction(shaderInput);
            return output;
        }
        """
    }
}
