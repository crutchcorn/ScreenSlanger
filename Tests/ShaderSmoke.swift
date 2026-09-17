import Foundation
import CoreGraphics
import ImageIO
import Metal

private struct SmokeFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SmokeFailure(message: message) }
}

@main
struct ShaderSmoke {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        if CommandLine.arguments.dropFirst().first == "--large-diagnostic-child" {
            do {
                _ = try SlangCompiler.compileToMetal(slangSource: "deliberately invalid shader")
                throw SmokeFailure(message: "Mock compiler unexpectedly succeeded")
            } catch SlangCompilerError.compilationFailed(let diagnostic) {
                try require(diagnostic.count > 262_144 && diagnostic.contains("largeDiagnosticSentinel"),
                            "Compiler output was truncated or lost")
            }
            return
        }
        guard CommandLine.arguments.count == 2 else {
            throw SmokeFailure(message: "Usage: check-shaders <repository directory>")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SmokeFailure(message: "A Metal device is required for the shader checks.")
        }
        print("Metal device: \(device.name)")
        print("Slang compiler: \(SlangCompiler.findSlangc() ?? "missing")")
        print("glslang: \(RetroArchShaderCompiler.findGlslang() ?? "missing")")
        print("SPIRV-Cross: \(RetroArchShaderCompiler.findSpirvCross() ?? "missing")")

        func read(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }

        var failures: [String] = []
        func check(_ name: String, _ body: () throws -> Void) {
            do {
                try body()
                print("PASS: \(name)")
            } catch {
                failures.append(name)
                print("FAIL: \(name): \(error.localizedDescription)")
            }
        }

        check("waves.slang compiles to a Metal render pipeline") {
            _ = try MetalRenderer.buildRenderPipeline(device: device, effectSource: read("assets/waves.slang"))
        }

        // BGRA bytes: red, green, blue, white. The four different texels detect
        // incorrect texture coordinates as well as missing texture bindings.
        let input: [UInt8] = [0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255]
        check("Slang texture sampling preserves all four texels") {
            let pipeline = try MetalRenderer.buildRenderPipeline(
                device: device, effectSource: read("Tests/Fixtures/passthrough.slang"))
            let output = try render(device: device, pipeline: pipeline, pixels: input) { encoder in
                var uniforms = SlangUniforms(screenSize: SIMD2<Float>(2, 2), mousePosition: .zero, time: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SlangUniforms>.stride, index: 0)
            }
            try checkPixels(output, expected: input)
        }

        let retroSource = try read("Tests/Fixtures/retroarch-helper.slang")
        check("RetroArch helper, texture binding, and push parameter render correctly") {
            let (pipeline, parameters, samplers) = try MetalRenderer.buildRetroArchPipeline(
                device: device, effectSource: retroSource, shaderDirectory: root.appendingPathComponent("Tests/Fixtures"))
            try require(parameters.count == 1 && parameters[0].name == "GAIN", "Missing GAIN parameter")
            try require(parameters[0].defaultValue == 0.5, "Wrong GAIN default")
            guard let sourceSampler = samplers.first(where: { $0.name == "Source" }) else {
                throw SmokeFailure(message: "Generated Metal lost the Source sampler binding")
            }
            let output = try render(device: device, pipeline: pipeline, pixels: input, textureIndex: sourceSampler.binding) { encoder in
                // Match the fixture's std430 layout: a float, padding, then three vec4s.
                let push: [Float] = [parameters[0].defaultValue, 0, 0, 0,
                                     2, 2, 0.5, 0.5, 2, 2, 0.5, 0.5, 2, 2, 0.5, 0.5]
                push.withUnsafeBytes { bytes in
                    encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
                }
            }
            let expected: [UInt8] = [0, 0, 128, 255, 0, 128, 0, 255, 128, 0, 0, 255, 128, 128, 128, 255]
            try checkPixels(output, expected: expected)
        }

        check("preset grayscale textures sample as opaque grayscale") {
            try checkPresetTexture(root: root, grayscale: true)
        }

        check("preset RGB textures preserve their color channels") {
            try checkPresetTexture(root: root, grayscale: false)
        }

        check("preset reload recompiles an edited shader at the same path") {
            try checkPresetTexture(root: root, grayscale: true, reload: true)
        }

        check("failed shader replacement clears the pipeline and retries still fail") {
            let shared = SharedMetalResources.shared
            defer { try? shared.setEffectSource(nil) }
            let path = root.appendingPathComponent("Tests/Fixtures/passthrough.slang").path
            try shared.setEffectSource(read("Tests/Fixtures/passthrough.slang"), shaderPath: path)
            try require(shared.renderPipeline != nil, "Valid shader did not create a pipeline")
            for attempt in 1...2 {
                var rejected = false
                do {
                    try shared.setEffectSource("float4 shaderFunction(ShaderInput input) { return missingSmokeSymbol; }", shaderPath: path)
                } catch {
                    rejected = true
                }
                try require(rejected, "Invalid shader attempt \(attempt) reused a cached pipeline")
                try require(shared.renderPipeline == nil, "Failed shader left a stale render pipeline active")
            }
            try shared.setEffectSource(read("Tests/Fixtures/passthrough.slang"), shaderPath: path)
            try require(shared.renderPipeline != nil, "Valid shader could not recover after compilation failed")
        }

        check("changed shader content at the same path produces a new pipeline") {
            let shared = SharedMetalResources.shared
            defer { try? shared.setEffectSource(nil) }
            let path = root.appendingPathComponent("Tests/Fixtures/passthrough.slang").path
            try shared.setEffectSource(read("Tests/Fixtures/passthrough.slang"), shaderPath: path)
            let previous = shared.renderPipeline
            try shared.setEffectSource(
                "float4 shaderFunction(ShaderInput input) { return float4(0.0, 1.0, 0.0, 1.0); }", shaderPath: path)
            guard let pipeline = shared.renderPipeline else {
                throw SmokeFailure(message: "Edited shader did not create a pipeline")
            }
            try require(pipeline !== previous, "Edited shader reused the previous pipeline")
            let output = try render(device: shared.device, pipeline: pipeline, pixels: input) { _ in }
            let green: [UInt8] = [0, 255, 0, 255]
            try checkPixels(output, expected: Array(repeating: green, count: 4).flatMap { $0 })
        }

        check("invalid Slang returns a compiler diagnostic") {
            do {
                _ = try SlangCompiler.compileToMetal(slangSource: SlangCompiler.wrapEffectSource(
                    "float4 shaderFunction(ShaderInput input) { return missingSmokeSymbol; }"))
                throw SmokeFailure(message: "Invalid Slang unexpectedly compiled")
            } catch SlangCompilerError.compilationFailed(let diagnostic) {
                try require(diagnostic.contains("missingSmokeSymbol"), "Diagnostic did not identify the invalid symbol: \(diagnostic)")
            }
        }

        check("invalid RetroArch GLSL returns a compiler diagnostic") {
            do {
                _ = try RetroArchShaderCompiler.compileToMetal(
                    source: retroSource.replacingOccurrences(of: "color * gain", with: "missingSmokeSymbol"), shaderDirectory: nil)
                throw SmokeFailure(message: "Invalid GLSL unexpectedly compiled")
            } catch RetroArchShaderError.glslCompilationFailed(let diagnostic) {
                try require(diagnostic.contains("missingSmokeSymbol"), "Diagnostic did not identify the invalid symbol: \(diagnostic)")
            }
        }

        check("large compiler output returns without a pipe deadlock") {
            try checkLargeDiagnostic()
        }

        if !failures.isEmpty {
            throw SmokeFailure(message: "\(failures.count) shader smoke check(s) failed: \(failures.joined(separator: ", "))")
        }
        print("All shader smoke checks passed.")
    }

    private static func checkPresetTexture(root: URL, grayscale: Bool, reload: Bool = false) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("Tests/Fixtures/retroarch-background.slang"),
            to: temporary.appendingPathComponent("background.slang"))

        // Create tiny PNGs so this test exercises MTKTextureLoader and the app's
        // preset texture handling, including its single-channel texture view.
        let data = grayscale ? Data(repeating: 128, count: 4) : Data([255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255])
        let colorSpace = grayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = grayscale ? CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
            : CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: 2, height: 2, bitsPerComponent: 8,
                                  bitsPerPixel: grayscale ? 8 : 32, bytesPerRow: grayscale ? 2 : 8,
                                  space: colorSpace, bitmapInfo: bitmapInfo, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(
                temporary.appendingPathComponent("background.png") as CFURL, "public.png" as CFString, 1, nil) else {
            throw SmokeFailure(message: "Could not create PNG texture fixture")
        }
        CGImageDestinationAddImage(destination, image, nil)
        try require(CGImageDestinationFinalize(destination), "Could not write PNG texture fixture")

        let preset = """
        shaders = 1
        shader0 = "background.slang"
        textures = "BACKGROUND"
        BACKGROUND = "background.png"
        """
        let presetURL = temporary.appendingPathComponent("background.slangp")
        try preset.write(to: presetURL, atomically: true, encoding: .utf8)
        let shared = SharedMetalResources.shared
        defer { try? shared.setEffectSource(nil) }
        try shared.setEffectSource(preset, shaderPath: presetURL.path)
        guard let texture = shared.getTexture(named: "BACKGROUND"), let pipeline = shared.renderPipeline,
              let binding = shared.getTextureSamplers().first(where: { $0.name == "BACKGROUND" })?.binding else {
            throw SmokeFailure(message: "Preset failed to load its background texture and pipeline")
        }
        print("Preset texture format: \(texture.pixelFormat.rawValue), grayscale: \(grayscale)")
        let output = try render(device: shared.device, pipeline: pipeline, pixels: [],
                                textureIndex: binding, sourceTexture: texture) { _ in }
        let pixel: [UInt8] = grayscale ? [128, 128, 128, 255] : [0, 0, 255, 255]
        try checkPixels(output, expected: Array(repeating: pixel, count: 4).flatMap { $0 })

        if reload {
            let shaderURL = temporary.appendingPathComponent("background.slang")
            let originalSource = try String(contentsOf: shaderURL, encoding: .utf8)
            try originalSource.replacingOccurrences(of: "texture(BACKGROUND, vTexCoord)", with: "vec4(0.0, 1.0, 0.0, 1.0)")
                .write(to: shaderURL, atomically: true, encoding: .utf8)
            shared.invalidateEffect()
            try shared.setEffectSource(preset, shaderPath: presetURL.path)
            guard let reloadedPipeline = shared.renderPipeline else {
                throw SmokeFailure(message: "Preset reload did not create a pipeline")
            }
            try require(reloadedPipeline !== pipeline, "Preset reload reused the previous shader pipeline")
            let reloadedOutput = try render(device: shared.device, pipeline: reloadedPipeline,
                                            pixels: [], sourceTexture: texture) { _ in }
            let green: [UInt8] = [0, 255, 0, 255]
            try checkPixels(reloadedOutput, expected: Array(repeating: green, count: 4).flatMap { $0 })
        }
    }

    private static func checkLargeDiagnostic() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let compiler = temporary.appendingPathComponent("mock-slangc")
        let script = #"""
        #!/bin/sh
        /usr/bin/head -c 262144 /dev/zero | /usr/bin/tr '\000' 'o'
        /usr/bin/head -c 262144 /dev/zero | /usr/bin/tr '\000' 'e' >&2
        printf '\nlargeDiagnosticSentinel\n' >&2
        exit 1
        """#
        try script.write(to: compiler, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: compiler.path)
        let outputFile = temporary.appendingPathComponent("output.txt")
        FileManager.default.createFile(atPath: outputFile.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputFile)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--large-diagnostic-child"]
        var environment = ProcessInfo.processInfo.environment
        environment["SLANG_PATH"] = compiler.path
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw SmokeFailure(message: "Compiler handling blocked after 5 seconds with output larger than a pipe buffer")
        }
        process.waitUntilExit()
        let diagnostic = try String(contentsOf: outputFile, encoding: .utf8)
        try require(process.terminationStatus == 0, "Large-output subprocess failed: \(diagnostic)")
    }

    private static func checkPixels(_ actual: [UInt8], expected: [UInt8]) throws {
        try require(actual.count == expected.count, "Pixel output length mismatch")
        for index in actual.indices {
            try require(abs(Int(actual[index]) - Int(expected[index])) <= 1,
                        "Pixel bytes differ at channel \(index): got \(actual), expected \(expected)")
        }
    }

    private static func render(
        device: MTLDevice,
        pipeline: MTLRenderPipelineState,
        pixels: [UInt8],
        textureIndex: Int = 0,
        sourceTexture: MTLTexture? = nil,
        uniforms: (MTLRenderCommandEncoder) -> Void
    ) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2, height: 2, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        guard let source = sourceTexture ?? device.makeTexture(descriptor: descriptor),
              let destination = device.makeTexture(descriptor: descriptor),
              let queue = device.makeCommandQueue(),
              let commands = queue.makeCommandBuffer() else {
            throw SmokeFailure(message: "Could not allocate offscreen rendering resources")
        }
        let region = MTLRegionMake2D(0, 0, 2, 2)
        if sourceTexture == nil {
            pixels.withUnsafeBytes { bytes in
                source.replace(region: region, mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: 8)
            }
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw SmokeFailure(message: "Could not create sampler")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            throw SmokeFailure(message: "Could not create render encoder")
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: textureIndex)
        encoder.setFragmentSamplerState(sampler, index: textureIndex)
        uniforms(encoder)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
        var output = [UInt8](repeating: 0, count: 16)
        output.withUnsafeMutableBytes { bytes in
            destination.getBytes(bytes.baseAddress!, bytesPerRow: 8, from: region, mipmapLevel: 0)
        }
        return output
    }
}
