import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing

private final class ShaderFixtureBundle: NSObject {}

@Suite("Shader rendering and reloads", .serialized)
@MainActor
struct ShaderTests {
    // BGRA bytes for red, green, blue, and white. Distinct texels catch both
    // incorrect texture coordinates and missing texture bindings.
    private let inputPixels: [UInt8] = [
        0, 0, 255, 255, 0, 255, 0, 255,
        255, 0, 0, 255, 255, 255, 255, 255,
    ]

    @Test("waves.slang compiles to a Metal render pipeline")
    func wavesCompiles() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "A Metal device is required")
        _ = try MetalRenderer.buildRenderPipeline(device: device, effectSource: fixtureSource("waves"))
    }

    @Test("Slang texture sampling preserves all four texels")
    func slangTextureSampling() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "A Metal device is required")
        let pipeline = try MetalRenderer.buildRenderPipeline(
            device: device, effectSource: fixtureSource("passthrough"))
        let output = try render(device: device, pipeline: pipeline, pixels: inputPixels) { encoder in
            var uniforms = SlangUniforms(screenSize: SIMD2<Float>(2, 2), mousePosition: .zero, time: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SlangUniforms>.stride, index: 0)
        }
        try expectPixels(output, expected: inputPixels)
    }

    @Test("RetroArch helper, texture binding, and push parameter render correctly")
    func retroArchParametersAndSampling() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "A Metal device is required")
        let fixture = try fixtureURL("retroarch-helper")
        let source = try String(contentsOf: fixture, encoding: .utf8)
        let (pipeline, parameters, samplers) = try MetalRenderer.buildRetroArchPipeline(
            device: device, effectSource: source, shaderDirectory: fixture.deletingLastPathComponent())
        try #require(parameters.count == 1, "Expected one GAIN parameter")
        #expect(parameters[0].name == "GAIN")
        #expect(parameters[0].defaultValue == 0.5)
        let sourceSampler = try #require(
            samplers.first(where: { $0.name == "Source" }), "Generated Metal lost the Source sampler binding")
        let output = try render(
            device: device, pipeline: pipeline, pixels: inputPixels, textureIndex: sourceSampler.binding
        ) { encoder in
            // Match the fixture's std430 layout: a float, padding, then three vec4s.
            let push: [Float] = [parameters[0].defaultValue, 0, 0, 0,
                                 2, 2, 0.5, 0.5, 2, 2, 0.5, 0.5, 2, 2, 0.5, 0.5]
            push.withUnsafeBytes { bytes in
                encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            }
        }
        let expected: [UInt8] = [
            0, 0, 128, 255, 0, 128, 0, 255,
            128, 0, 0, 255, 128, 128, 128, 255,
        ]
        try expectPixels(output, expected: expected)
    }

    @Test("Preset grayscale textures sample as opaque grayscale")
    func grayscalePresetTexture() throws {
        try expectPresetTexture(grayscale: true)
    }

    @Test("Preset RGB textures preserve their color channels")
    func colorPresetTexture() throws {
        try expectPresetTexture(grayscale: false)
    }

    @Test("Preset reload recompiles an edited shader at the same path")
    func presetReload() throws {
        try expectPresetTexture(grayscale: true, reload: true)
    }

    @Test("Failed shader replacement clears the pipeline and retries still fail")
    func failedShaderReplacementAndRecovery() throws {
        let shared = SharedMetalResources.shared
        defer { try? shared.setEffectSource(nil) }
        let fixture = try fixtureURL("passthrough")
        let source = try String(contentsOf: fixture, encoding: .utf8)
        try shared.setEffectSource(source, shaderPath: fixture.path)
        try #require(shared.renderPipeline != nil, "Valid shader did not create a pipeline")
        for attempt in 1...2 {
            #expect(throws: (any Error).self, "Invalid shader attempt \(attempt) must not reuse a cached pipeline") {
                try shared.setEffectSource(
                    "float4 shaderFunction(ShaderInput input) { return missingSmokeSymbol; }",
                    shaderPath: fixture.path)
            }
            #expect(shared.renderPipeline == nil, "Failed shader left a stale render pipeline active")
        }
        try shared.setEffectSource(source, shaderPath: fixture.path)
        #expect(shared.renderPipeline != nil, "Valid shader could not recover after compilation failed")
    }

    @Test("Changed shader content at the same path produces a new pipeline")
    func changedShaderContent() throws {
        let shared = SharedMetalResources.shared
        defer { try? shared.setEffectSource(nil) }
        let fixture = try fixtureURL("passthrough")
        let source = try String(contentsOf: fixture, encoding: .utf8)
        try shared.setEffectSource(source, shaderPath: fixture.path)
        let previous = try #require(shared.renderPipeline)
        try shared.setEffectSource(
            "float4 shaderFunction(ShaderInput input) { return float4(0.0, 1.0, 0.0, 1.0); }",
            shaderPath: fixture.path)
        let pipeline = try #require(shared.renderPipeline, "Edited shader did not create a pipeline")
        #expect(pipeline !== previous, "Edited shader reused the previous pipeline")
        let output = try render(device: shared.device, pipeline: pipeline, pixels: inputPixels) { _ in }
        let green: [UInt8] = [0, 255, 0, 255]
        try expectPixels(output, expected: Array(repeating: green, count: 4).flatMap { $0 })
    }

    @Test("Invalid Slang returns a compiler diagnostic")
    func invalidSlangDiagnostic() throws {
        do {
            _ = try SlangCompiler.compileToMetal(slangSource: SlangCompiler.wrapEffectSource(
                "float4 shaderFunction(ShaderInput input) { return missingSmokeSymbol; }"))
            Issue.record("Invalid Slang unexpectedly compiled")
        } catch SlangCompilerError.compilationFailed(let diagnostic) {
            #expect(diagnostic.contains("missingSmokeSymbol"), "Diagnostic did not identify the invalid symbol: \(diagnostic)")
        }
    }

    @Test("Invalid RetroArch GLSL returns a compiler diagnostic")
    func invalidRetroArchDiagnostic() throws {
        let source = try fixtureSource("retroarch-helper")
        do {
            _ = try RetroArchShaderCompiler.compileToMetal(
                source: source.replacingOccurrences(of: "color * gain", with: "missingSmokeSymbol"),
                shaderDirectory: nil)
            Issue.record("Invalid GLSL unexpectedly compiled")
        } catch RetroArchShaderError.glslCompilationFailed(let diagnostic) {
            #expect(diagnostic.contains("missingSmokeSymbol"), "Diagnostic did not identify the invalid symbol: \(diagnostic)")
        }
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let bundle = Bundle(for: ShaderFixtureBundle.self)
        return try #require(
            bundle.url(forResource: name, withExtension: "slang", subdirectory: "Fixtures")
                ?? bundle.url(forResource: name, withExtension: "slang"),
            "Missing bundled shader fixture: \(name).slang")
    }

    private func fixtureSource(_ name: String) throws -> String {
        try String(contentsOf: fixtureURL(name), encoding: .utf8)
    }

    private func expectPresetTexture(grayscale: Bool, reload: Bool = false) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(
            at: fixtureURL("retroarch-background"), to: temporary.appendingPathComponent("background.slang"))

        // Tiny PNGs exercise MTKTextureLoader and the app's preset texture handling,
        // including its single-channel texture view.
        let data = grayscale ? Data(repeating: 128, count: 4)
            : Data([255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255])
        let colorSpace = grayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = grayscale ? CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
            : CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(
            width: 2, height: 2, bitsPerComponent: 8,
            bitsPerPixel: grayscale ? 8 : 32, bytesPerRow: grayscale ? 2 : 8,
            space: colorSpace, bitmapInfo: bitmapInfo, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(
            temporary.appendingPathComponent("background.png") as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination), "Could not write PNG texture fixture")

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
        let texture = try #require(shared.getTexture(named: "BACKGROUND"), "Preset did not load its texture")
        let pipeline = try #require(shared.renderPipeline, "Preset did not create its pipeline")
        let binding = try #require(
            shared.getTextureSamplers().first(where: { $0.name == "BACKGROUND" })?.binding,
            "Preset did not create its texture sampler")
        let output = try render(
            device: shared.device, pipeline: pipeline, pixels: [], textureIndex: binding, sourceTexture: texture
        ) { _ in }
        let pixel: [UInt8] = grayscale ? [128, 128, 128, 255] : [0, 0, 255, 255]
        try expectPixels(output, expected: Array(repeating: pixel, count: 4).flatMap { $0 })

        if reload {
            let shaderURL = temporary.appendingPathComponent("background.slang")
            let originalSource = try String(contentsOf: shaderURL, encoding: .utf8)
            try originalSource.replacingOccurrences(
                of: "texture(BACKGROUND, vTexCoord)", with: "vec4(0.0, 1.0, 0.0, 1.0)"
            ).write(to: shaderURL, atomically: true, encoding: .utf8)
            shared.invalidateEffect()
            try shared.setEffectSource(preset, shaderPath: presetURL.path)
            let reloadedPipeline = try #require(shared.renderPipeline, "Preset reload did not create a pipeline")
            #expect(reloadedPipeline !== pipeline, "Preset reload reused the previous shader pipeline")
            let reloadedOutput = try render(
                device: shared.device, pipeline: reloadedPipeline, pixels: [], sourceTexture: texture
            ) { _ in }
            let green: [UInt8] = [0, 255, 0, 255]
            try expectPixels(reloadedOutput, expected: Array(repeating: green, count: 4).flatMap { $0 })
        }
    }

    private func expectPixels(_ actual: [UInt8], expected: [UInt8]) throws {
        try #require(actual.count == expected.count, "Pixel output length mismatch")
        for index in actual.indices {
            #expect(abs(Int(actual[index]) - Int(expected[index])) <= 1,
                    "Pixel bytes differ at channel \(index): got \(actual), expected \(expected)")
        }
    }

    private func render(
        device: MTLDevice,
        pipeline: MTLRenderPipelineState,
        pixels: [UInt8],
        textureIndex: Int = 0,
        sourceTexture: MTLTexture? = nil,
        uniforms: (MTLRenderCommandEncoder) -> Void
    ) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 2, height: 2, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        let source = try #require(sourceTexture ?? device.makeTexture(descriptor: descriptor))
        let destination = try #require(device.makeTexture(descriptor: descriptor))
        let queue = try #require(device.makeCommandQueue())
        let commands = try #require(queue.makeCommandBuffer())
        let region = MTLRegionMake2D(0, 0, 2, 2)
        if sourceTexture == nil {
            try #require(pixels.count == 16, "Rendering a 2×2 BGRA texture requires 16 bytes")
            pixels.withUnsafeBytes { bytes in
                source.replace(region: region, mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: 8)
            }
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        let sampler = try #require(device.makeSamplerState(descriptor: samplerDescriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let encoder = try #require(commands.makeRenderCommandEncoder(descriptor: pass))
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
