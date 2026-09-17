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
    func slangTextureSampling() async throws {
        let shared = SharedMetalResources.shared
        defer { shared.clear() }
        try await shared.loadEffect(ShaderLoadRequest(source: fixtureSource("passthrough")))
        let output = try render()
        try expectPixels(output, expected: inputPixels)
    }

    @Test("RetroArch helper, texture binding, and push parameter render correctly")
    func retroArchParametersAndSampling() async throws {
        let shared = SharedMetalResources.shared
        defer { shared.clear() }
        let fixture = try fixtureURL("retroarch-helper")
        try await shared.loadEffect(ShaderLoadRequest(url: fixture))
        let parameters = shared.parameterState.parameters
        try #require(parameters.count == 1)
        #expect(parameters[0].name == "GAIN")
        #expect(parameters[0].defaultValue == 0.5)
        let output = try render()
        let expected: [UInt8] = [
            0, 0, 128, 255, 0, 128, 0, 255,
            128, 0, 0, 255, 128, 128, 128, 255,
        ]
        try expectPixels(output, expected: expected)
    }

    @Test("Preset grayscale textures sample as opaque grayscale")
    func grayscalePresetTexture() async throws {
        try await expectPresetTexture(grayscale: true)
    }

    @Test("Preset RGB textures preserve their color channels")
    func colorPresetTexture() async throws {
        try await expectPresetTexture(grayscale: false)
    }

    @Test("Preset reload recompiles an edited shader at the same path")
    func presetReload() async throws {
        try await expectPresetTexture(grayscale: true, reload: true)
    }

    @Test("Failed shader replacement clears the pipeline and retries still fail")
    func failedShaderReplacementAndRecovery() async throws {
        let shared = SharedMetalResources.shared
        defer { shared.clear() }
        let fixture = try fixtureURL("passthrough")
        let source = try String(contentsOf: fixture, encoding: .utf8)
        try await shared.loadEffect(ShaderLoadRequest(source: source, url: fixture))
        try #require(shared.renderPipeline != nil, "Valid shader did not create a pipeline")
        for attempt in 1...2 {
            do {
                try await shared.loadEffect(ShaderLoadRequest(
                    source: "float4 shaderFunction(ShaderInput input) { return missingSmokeSymbol; }",
                    url: fixture))
                Issue.record("Invalid shader attempt \(attempt) reused a cached pipeline")
            } catch {
                #expect(error.localizedDescription.contains("missingSmokeSymbol"))
            }
            #expect(shared.renderPipeline == nil, "Failed shader left a stale render pipeline active")
        }
        try await shared.loadEffect(ShaderLoadRequest(source: source, url: fixture))
        #expect(shared.renderPipeline != nil, "Valid shader could not recover after compilation failed")
    }

    @Test("Changed shader content at the same path produces a new pipeline")
    func changedShaderContent() async throws {
        let shared = SharedMetalResources.shared
        defer { shared.clear() }
        let fixture = try fixtureURL("passthrough")
        let source = try String(contentsOf: fixture, encoding: .utf8)
        try await shared.loadEffect(ShaderLoadRequest(source: source, url: fixture))
        let previous = try #require(shared.renderPipeline)
        try await shared.loadEffect(ShaderLoadRequest(
            source: "float4 shaderFunction(ShaderInput input) { return float4(0.0, 1.0, 0.0, 1.0); }",
            url: fixture))
        let pipeline = try #require(shared.renderPipeline, "Edited shader did not create a pipeline")
        #expect(pipeline !== previous, "Edited shader reused the previous pipeline")
        let output = try render()
        let green: [UInt8] = [0, 255, 0, 255]
        try expectPixels(output, expected: Array(repeating: green, count: 4).flatMap { $0 })
    }

    @Test("Frame context drives production Slang uniforms without a new input image")
    func nativeFrameContext() async throws {
        let shared = SharedMetalResources.shared
        defer { shared.clear() }
        try await shared.loadEffect(ShaderLoadRequest(source: """
        float4 shaderFunction(ShaderInput input) {
            return float4(input.time, input.mousePosition.x / input.screenSize.x,
                          input.mousePosition.y / input.screenSize.y, 1.0);
        }
        """))
        let first = try render(context: ShaderFrameContext(
            outputSize: SIMD2(2, 2), mousePosition: SIMD2(1, 2), time: 0))
        try expectPixels(first, expected: Array(repeating: [255, 128, 0, 255], count: 4).flatMap { $0 })
        let second = try render(context: ShaderFrameContext(
            outputSize: SIMD2(2, 2), mousePosition: SIMD2(1, 2), time: 1))
        try expectPixels(second, expected: Array(repeating: [255, 128, 255, 255], count: 4).flatMap { $0 })
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
    func invalidRetroArchDiagnostic() async throws {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = try fixtureSource("retroarch-helper")
        let shader = temporary.appendingPathComponent("invalid.slang")
        try source.replacingOccurrences(of: "color * gain", with: "missingSmokeSymbol")
            .write(to: shader, atomically: true, encoding: .utf8)
        let shared = SharedMetalResources.shared
        defer { shared.clear() }
        do {
            try await shared.loadEffect(ShaderLoadRequest(url: shader))
            Issue.record("Invalid GLSL unexpectedly compiled")
        } catch {
            #expect(error.localizedDescription.contains("missingSmokeSymbol"), "Diagnostic did not identify the invalid symbol: \(error)")
        }
        #expect(shared.effect == nil)
    }

    @Test("RetroArch binds reordered parameters at their reflected uniform offsets")
    func reorderedUniformParameters() async throws {
        let source = retroArchSource(
            fragment: "vec4(global.FIRST, global.SECOND, global.OutputSize.x * 0.25, 1.0)",
            uniforms: """
            #pragma parameter FIRST "First" 0.25 0.0 1.0 0.05
            #pragma parameter SECOND "Second" 0.75 0.0 1.0 0.05
            layout(set = 0, binding = 0) uniform Global {
                mat4 MVP;
                vec4 OutputSize;
                float SECOND;
                float FIRST;
            } global;
            """)
        try await withRetroArchShader(source) { shared in
            try expectPixels(render(), expected: solidPixel([128, 191, 64, 255]))
            shared.parameterState.setValue(1, for: "FIRST")
            shared.parameterState.setValue(0, for: "SECOND")
            try expectPixels(render(), expected: solidPixel([128, 0, 255, 255]))
        }
    }

    @Test("RetroArch binds separate uniform and push buffers with FrameCount")
    func separateUniformAndPushBuffers() async throws {
        let source = retroArchSource(
            fragment: "vec4(params.GAIN, global.FIRST, float(params.FrameCount) * 0.25, 1.0)",
            uniforms: """
            #pragma parameter GAIN "Gain" 0.75 0.0 1.0 0.05
            #pragma parameter FIRST "First" 0.25 0.0 1.0 0.05
            layout(set = 0, binding = 0) uniform Global {
                mat4 MVP;
                float FIRST;
            } global;
            layout(push_constant) uniform Push {
                vec4 SourceSize;
                uint FrameCount;
                float GAIN;
            } params;
            """)
        try await withRetroArchShader(source) { _ in
            let output = try render(context: ShaderFrameContext(outputSize: SIMD2(2, 2), frameCount: 2))
            try expectPixels(output, expected: solidPixel([128, 64, 191, 255]))
        }
    }

    @Test("RetroArch executes the shader's custom vertex varying")
    func customVertexStage() async throws {
        let source = retroArchSource(
            fragment: "texture(Source, vTexCoord)",
            vertex: "gl_Position = global.MVP * Position; vTexCoord = vec2(1.0) - TexCoord;")
        try await withRetroArchShader(source) { _ in
            try expectPixels(render(), expected: [
                255, 255, 255, 255, 255, 0, 0, 255,
                0, 255, 0, 255, 0, 0, 255, 255,
            ])
        }
    }

    @Test("Every preset pass runs, including differently sized intermediate targets")
    func multiPassPreset() async throws {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try retroArchSource(fragment: "vec4(texture(Source, vTexCoord).rgb * 0.5, 1.0)")
            .write(to: temporary.appendingPathComponent("first.slang"), atomically: true, encoding: .utf8)
        try retroArchSource(fragment: "vec4(texture(Source, vTexCoord).bgr, 1.0)")
            .write(to: temporary.appendingPathComponent("second.slang"), atomically: true, encoding: .utf8)
        let preset = temporary.appendingPathComponent("two-pass.slangp")
        try """
        shaders = 2
        shader0 = "first.slang"
        filter_linear0 = false
        scale_type0 = "source"
        scale0 = 2.0
        shader1 = "second.slang"
        filter_linear1 = false
        """.write(to: preset, atomically: true, encoding: .utf8)
        let shared = SharedMetalResources.shared
        defer { shared.clear() }
        try await shared.loadEffect(ShaderLoadRequest(url: preset))
        try expectPixels(render(), expected: [
            128, 0, 0, 255, 0, 128, 0, 255,
            0, 0, 128, 255, 128, 128, 128, 255,
        ])
    }

    @Test("Referenced presets resolve relative includes and reload their edits")
    func referencedPresetAndIncludes() async throws {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let base = temporary.appendingPathComponent("base")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let include = base.appendingPathComponent("color.inc")
        try "vec4 fixtureColor() { return vec4(1.0, 0.0, 0.0, 1.0); }"
            .write(to: include, atomically: true, encoding: .utf8)
        try retroArchSource(
            fragment: "vec4(fixtureColor().rgb * global.GAIN, 1.0)",
            uniforms: """
            #pragma parameter GAIN "Gain" 0.5 0.0 1.0 0.05
            layout(set = 0, binding = 0) uniform Global { mat4 MVP; float GAIN; } global;
            """,
            fragmentDeclarations: "#include \"color.inc\"")
            .write(to: base.appendingPathComponent("color.slang"), atomically: true, encoding: .utf8)
        try "shaders = 1\nshader0 = \"color.slang\"\n"
            .write(to: base.appendingPathComponent("base.slangp"), atomically: true, encoding: .utf8)
        let preset = temporary.appendingPathComponent("reference.slangp")
        try "#reference \"base/base.slangp\"\nGAIN = \"0.25\"\n"
            .write(to: preset, atomically: true, encoding: .utf8)
        let shared = SharedMetalResources.shared
        defer { shared.clear() }
        try await shared.loadEffect(ShaderLoadRequest(url: preset))
        #expect(shared.parameterState.getValue(for: "GAIN") == 0.25)
        try expectPixels(render(), expected: solidPixel([0, 0, 64, 255]))

        try "vec4 fixtureColor() { return vec4(0.0, 1.0, 0.0, 1.0); }"
            .write(to: include, atomically: true, encoding: .utf8)
        try await shared.loadEffect(ShaderLoadRequest(url: preset))
        try expectPixels(render(), expected: solidPixel([0, 64, 0, 255]))
    }

    @Test("Preset lookup textures honor nearest filtering and repeat wrapping")
    func lookupTextureSamplerSettings() async throws {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try retroArchSource(
            fragment: "texture(BACKGROUND, vec2(1.1, 0.1))",
            fragmentDeclarations: "layout(set = 0, binding = 3) uniform sampler2D BACKGROUND;")
            .write(to: temporary.appendingPathComponent("sample.slang"), atomically: true, encoding: .utf8)
        try writeTexture(
            rgba: [255, 0, 0, 255, 0, 255, 0, 255, 255, 0, 0, 255, 0, 255, 0, 255],
            to: temporary.appendingPathComponent("lookup.png"))
        let preset = temporary.appendingPathComponent("sampler.slangp")
        try """
        shaders = 1
        shader0 = "sample.slang"
        textures = "BACKGROUND"
        BACKGROUND = "lookup.png"
        BACKGROUND_linear = false
        BACKGROUND_wrap_mode = "repeat"
        """.write(to: preset, atomically: true, encoding: .utf8)
        let shared = SharedMetalResources.shared
        defer { shared.clear() }
        try await shared.loadEffect(ShaderLoadRequest(url: preset))
        try expectPixels(render(), expected: solidPixel([0, 0, 255, 255]))
    }

    @Test("Missing preset textures fail without retaining the previous effect")
    func missingPresetTexture() async throws {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try fixtureSource("retroarch-background")
            .write(to: temporary.appendingPathComponent("background.slang"), atomically: true, encoding: .utf8)
        let preset = temporary.appendingPathComponent("missing.slangp")
        try """
        shaders = 1
        shader0 = "background.slang"
        textures = "BACKGROUND"
        BACKGROUND = "missing.png"
        """.write(to: preset, atomically: true, encoding: .utf8)
        let shared = SharedMetalResources.shared
        defer { shared.clear() }
        try await shared.loadEffect(ShaderLoadRequest(source: fixtureSource("passthrough")))
        do {
            try await shared.loadEffect(ShaderLoadRequest(url: preset))
            Issue.record("Preset with a missing lookup texture unexpectedly loaded")
        } catch {
            #expect(shared.effect == nil)
        }
    }

    @Test("Native and RetroArch rendering leave excluded desktop areas transparent")
    func desktopScissorComposition() async throws {
        let shared = SharedMetalResources.shared
        defer { shared.clear() }
        let scissor = MTLScissorRect(x: 1, y: 0, width: 1, height: 2)
        try await shared.loadEffect(ShaderLoadRequest(source: fixtureSource("passthrough")))
        let expected: [UInt8] = [
            0, 0, 0, 0, 0, 255, 0, 255,
            0, 0, 0, 0, 255, 255, 255, 255,
        ]
        try expectPixels(render(scissor: scissor), expected: expected)
        try await withRetroArchShader(retroArchSource(fragment: "texture(Source, vTexCoord)")) { _ in
            try expectPixels(render(scissor: scissor), expected: expected)
        }
    }

    @Test("Each display retains its own previous input across repeated frames")
    func displayHistoryIsIsolated() async throws {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let shader = temporary.appendingPathComponent("history.slang")
        try retroArchSource(
            fragment: "texture(OriginalHistory1, vTexCoord)",
            fragmentDeclarations: "layout(set = 0, binding = 3) uniform sampler2D OriginalHistory1;")
            .write(to: shader, atomically: true, encoding: .utf8)
        let shared = SharedMetalResources.shared
        defer { shared.clear() }
        try await shared.loadEffect(ShaderLoadRequest(url: shader, displayIDs: [101, 202]))
        let red = solidPixel([0, 0, 255, 255])
        let green = solidPixel([0, 255, 0, 255])
        let blue = solidPixel([255, 0, 0, 255])
        let white = solidPixel([255, 255, 255, 255])

        // The first frame seeds each chain's history. Interleave subsequent
        // frames so a shared history would immediately expose the other display.
        _ = try render(displayID: 101, pixels: red)
        _ = try render(displayID: 202, pixels: green)
        try expectPixels(render(
            context: ShaderFrameContext(outputSize: SIMD2(2, 2), frameCount: 1),
            displayID: 101, pixels: blue), expected: red)
        try expectPixels(render(
            context: ShaderFrameContext(outputSize: SIMD2(2, 2), frameCount: 1),
            displayID: 202, pixels: white), expected: green)
        try expectPixels(render(
            context: ShaderFrameContext(outputSize: SIMD2(2, 2), frameCount: 2),
            displayID: 101, pixels: white), expected: blue)
    }

    @Test("Busy chains reject another frame before changing in-flight uniforms")
    func unsubmittedFrameKeepsItsUniforms() async throws {
        let shared = SharedMetalResources.shared
        defer { shared.clear() }
        try await shared.loadEffect(ShaderLoadRequest(url: fixtureURL("retroarch-helper")))
        let source = try makeTexture(pixels: inputPixels)
        let firstDestination = try makeTexture()
        let nextDestination = try makeTexture()
        let first = try #require(shared.commandQueue.makeCommandBuffer())
        let next = try #require(shared.commandQueue.makeCommandBuffer())
        let core = ShaderRenderCore(resources: shared)
        let context = ShaderFrameContext(outputSize: SIMD2(2, 2))
        defer {
            // Ensure even a failed assertion cannot abandon a successfully
            // encoded buffer that owns the chain's busy gate.
            if first.status == .notEnqueued {
                _ = try? finishRendering(first, to: firstDestination)
            }
        }
        try core.encode(commandBuffer: first, source: source, destination: firstDestination, context: context)
        shared.parameterState.setValue(1, for: "GAIN")
        do {
            try core.encode(commandBuffer: next, source: source, destination: nextDestination, context: context)
            Issue.record("An unsubmitted frame did not hold the filter chain's busy gate")
        } catch RetroArchRuntimeError.frameInFlight {
            // Rejection must precede parameter writes to the first frame's buffers.
        }
        try expectPixels(finishRendering(first, to: firstDestination), expected: [
            0, 0, 128, 255, 0, 128, 0, 255,
            128, 0, 0, 255, 128, 128, 128, 255,
        ])
        try core.encode(commandBuffer: next, source: source, destination: nextDestination, context: context)
        try expectPixels(finishRendering(next, to: nextDestination), expected: inputPixels)
    }

    @Test("Discarding an unsubmitted frame releases its chain for the next render")
    func discardedFrameReleasesBusyGate() async throws {
        let shared = SharedMetalResources.shared
        defer { shared.clear() }
        try await shared.loadEffect(ShaderLoadRequest(url: fixtureURL("retroarch-helper")))
        let effect = try #require(shared.effect)
        guard case .retroArch(let chains) = effect.backend else {
            Issue.record("Expected a RetroArch filter chain")
            return
        }
        let chain = try #require(chains[0])
        let abandoned = try #require(shared.commandQueue.makeCommandBuffer())
        defer { chain.discardUnsubmittedFrame(commandBuffer: abandoned) }
        try ShaderRenderCore(resources: shared).encode(
            commandBuffer: abandoned, source: makeTexture(pixels: inputPixels),
            destination: makeTexture(), context: ShaderFrameContext(outputSize: SIMD2(2, 2)))
        chain.discardUnsubmittedFrame(commandBuffer: abandoned)

        // Simulate abandoning a partially encoded frame after a later encoder
        // fails. The next real frame must not remain permanently "busy".
        shared.parameterState.setValue(1, for: "GAIN")
        try expectPixels(render(), expected: inputPixels)
        #expect(abandoned.status == .notEnqueued)
    }

    @Test("An obsolete background compilation cannot replace a newer effect")
    func supersededLoadCannotPublish() async throws {
        let resources = SharedMetalResources()
        let request = ShaderLoadRequest(source: try fixtureSource("passthrough"))
        try await resources.loadEffect(request)
        let pipeline = try #require(resources.renderPipeline)
        let stale = CompiledEffect(backend: .slang(pipeline), parameters: [])
        let current = CompiledEffect(backend: .slang(pipeline), parameters: [])
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); resources.clear() }
        let previous = Task {
            try await resources.loadEffect(request) { _, _, _, _ in
                entered.continuation.yield(())
                entered.continuation.finish()
                release.wait()
                return stale
            }
        }
        for await _ in entered.stream { break }
        try await resources.loadEffect(request) { _, _, _, _ in current }
        release.signal()
        do {
            try await previous.value
            Issue.record("Superseded load unexpectedly succeeded")
        } catch is CancellationError {
            // Some native library compilation cannot stop mid-call. Even if it
            // returns a result afterward, the generation check must discard it.
        }
        #expect(resources.effect?.id == current.id)
    }

    private func solidPixel(_ pixel: [UInt8]) -> [UInt8] {
        Array(repeating: pixel, count: 4).flatMap { $0 }
    }

    private func retroArchSource(
        fragment: String,
        uniforms: String = "layout(set = 0, binding = 0) uniform Global { mat4 MVP; vec4 OutputSize; } global;",
        vertex: String = "gl_Position = global.MVP * Position; vTexCoord = TexCoord;",
        fragmentDeclarations: String = ""
    ) -> String {
        """
        #version 450
        \(uniforms)
        #pragma stage vertex
        layout(location = 0) in vec4 Position;
        layout(location = 1) in vec2 TexCoord;
        layout(location = 0) out vec2 vTexCoord;
        void main() { \(vertex) }
        #pragma stage fragment
        layout(location = 0) in vec2 vTexCoord;
        layout(location = 0) out vec4 FragColor;
        layout(set = 0, binding = 2) uniform sampler2D Source;
        \(fragmentDeclarations)
        void main() { FragColor = \(fragment); }
        """
    }

    private func withRetroArchShader(
        _ source: String, check: (SharedMetalResources) throws -> Void
    ) async throws {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let shader = temporary.appendingPathComponent("fixture.slang")
        try source.write(to: shader, atomically: true, encoding: .utf8)
        let shared = SharedMetalResources.shared
        defer { shared.clear() }
        try await shared.loadEffect(ShaderLoadRequest(url: shader))
        try check(shared)
    }

    private func writeTexture(rgba: [UInt8], to url: URL) throws {
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let image = try #require(CGImage(
            width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shader fixtures \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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

    private func expectPresetTexture(grayscale: Bool, reload: Bool = false) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(
            at: fixtureURL("retroarch-background"), to: temporary.appendingPathComponent("background.slang"))

        // Exercise the runtime's image decoder and GPU lookup-texture bindings
        // with both single-channel PNGs and full-color PNGs.
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
        defer { shared.clear() }
        try await shared.loadEffect(ShaderLoadRequest(url: presetURL))
        let previousID = try #require(shared.effect).id
        let output = try render()
        let pixel: [UInt8] = grayscale ? [128, 128, 128, 255] : [0, 0, 255, 255]
        try expectPixels(output, expected: Array(repeating: pixel, count: 4).flatMap { $0 })

        if reload {
            let shaderURL = temporary.appendingPathComponent("background.slang")
            let originalSource = try String(contentsOf: shaderURL, encoding: .utf8)
            try originalSource.replacingOccurrences(
                of: "texture(BACKGROUND, vTexCoord)", with: "vec4(0.0, 1.0, 0.0, 1.0)"
            ).write(to: shaderURL, atomically: true, encoding: .utf8)
            try await shared.loadEffect(ShaderLoadRequest(url: presetURL))
            #expect(try #require(shared.effect).id != previousID)
            let reloadedOutput = try render()
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
        context: ShaderFrameContext = ShaderFrameContext(outputSize: SIMD2(2, 2)),
        scissor: MTLScissorRect? = nil,
        displayID: UInt32 = 0,
        pixels: [UInt8]? = nil
    ) throws -> [UInt8] {
        let shared = SharedMetalResources.shared
        let source = try makeTexture(pixels: pixels ?? inputPixels)
        let destination = try makeTexture()
        let commands = try #require(shared.commandQueue.makeCommandBuffer())
        try ShaderRenderCore(resources: shared, displayID: displayID).encode(
            commandBuffer: commands, source: source, destination: destination, context: context, scissor: scissor)
        return try finishRendering(commands, to: destination)
    }

    private func makeTexture(pixels: [UInt8]? = nil) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 2, height: 2, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        let texture = try #require(SharedMetalResources.shared.device.makeTexture(descriptor: descriptor))
        if let pixels {
            try #require(pixels.count == 16)
            pixels.withUnsafeBytes { bytes in
                texture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
                                withBytes: bytes.baseAddress!, bytesPerRow: 8)
            }
        }
        return texture
    }

    private func finishRendering(_ commands: MTLCommandBuffer, to destination: MTLTexture) throws -> [UInt8] {
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
        var output = [UInt8](repeating: 0, count: 16)
        output.withUnsafeMutableBytes { bytes in
            destination.getBytes(bytes.baseAddress!, bytesPerRow: 8,
                                 from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0)
        }
        return output
    }
}
