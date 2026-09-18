import CLibrashader
import CryptoKit
import Darwin
import Foundation
import Metal
import Testing

private final class RuntimeBundleMarker: NSObject {}

@Suite("Bundled shader runtimes", .serialized)
struct RuntimeBundleTests {
    private func builtApplication() throws -> URL {
        let application = Bundle(for: RuntimeBundleMarker.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("ScreenSlanger.app")
        try #require(FileManager.default.fileExists(atPath: application.path),
                     "The ScreenSlanger scheme must build the app before running packaging tests")
        return application
    }

    private func withRelocatedApplication(_ body: (URL, Bundle) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("Runtime relocation \(UUID().uuidString)")
        let application = temporary.appendingPathComponent("Moved ScreenSlanger.app")
        let contents = application.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let info: [String: String] = [
            "CFBundlePackageType": "APPL",
            "CFBundleIdentifier": "io.github.crutchcorn.relocation-\(UUID().uuidString)",
            "CFBundleName": "Moved ScreenSlanger",
            "CFBundleExecutable": "ScreenSlanger"
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: application))
        try body(temporary, bundle)
    }

    @Test("The bundled compiler and GLSL plugin work after moving the app")
    func relocatedSlangCompilation() throws {
        let original = try builtApplication()
        try withRelocatedApplication { temporary, bundle in
            let relativeDirectory = "Contents/Helpers/Slang.app"
            let bundledRuntime = original.appendingPathComponent(relativeDirectory)
            let relocatedRuntime = bundle.bundleURL.appendingPathComponent(relativeDirectory)
            try FileManager.default.createDirectory(at: relocatedRuntime.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // Copy the actual build products, preserving executable permissions and dylib links.
            try FileManager.default.copyItem(at: bundledRuntime, to: relocatedRuntime)
            let libraries = relocatedRuntime.appendingPathComponent("Contents/lib")
            try #require(FileManager.default.fileExists(atPath: libraries.appendingPathComponent("libslang-compiler.dylib").path))
            let libraryNames = try FileManager.default.contentsOfDirectory(atPath: libraries.path)
            #expect(libraryNames.contains { $0.hasPrefix("libslang-glsl-module-") && $0.hasSuffix(".dylib") })
            #expect(libraryNames.contains { $0.hasPrefix("slang-standard-module-") })

            let workingDirectory = temporary.appendingPathComponent("empty working directory")
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            let environment = [
                "PATH": "/usr/bin:/bin",
                "SLANG_PATH": "/missing/developer/slangc",
                "LIBRASHADER_PATH": "/missing/developer/librashader.dylib"
            ]
            let compiler = try #require(SlangCompiler.findSlangc(
                bundle: bundle, environment: environment, homeDirectory: workingDirectory))
            #expect(compiler == relocatedRuntime.appendingPathComponent("Contents/MacOS/slangc").path)

            let fixtures: [(name: String, source: String, entry: String, options: [String])] = [
                ("native.slang", """
                [shader("fragment")]
                float4 fragmentMain() : SV_Target0 { return float4(0.25, 0.5, 0.75, 1.0); }
                """, "fragmentMain", []),
                ("glsl.frag", """
                #version 450
                layout(location = 0) out vec4 color;
                void main() { color = vec4(0.25, 0.5, 0.75, 1.0); }
                """, "main", ["-allow-glsl"])
            ]
            for fixture in fixtures {
                let source = temporary.appendingPathComponent(fixture.name)
                let output = source.appendingPathExtension("metal")
                try fixture.source.write(to: source, atomically: true, encoding: .utf8)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: compiler)
                process.currentDirectoryURL = workingDirectory
                // Clear inherited DYLD and developer search paths as well as compiler overrides.
                process.environment = environment
                process.arguments = [source.path, "-target", "metal", "-entry", fixture.entry,
                                     "-stage", "fragment", "-o", output.path] + fixture.options
                let diagnostic = try runShaderCompilerProcess(process,
                    outputFile: source.appendingPathExtension("log"), timeout: 20)
                try #require(process.terminationStatus == 0,
                             "Relocated \(fixture.name) compilation failed: \(diagnostic)")
                let metal = try String(contentsOf: output, encoding: .utf8)
                #expect(metal.contains("[[fragment]]"))
                #expect(metal.contains("0.25f"))
            }
        }
    }

    @Test("The relocated RetroArch runtime compiles with its bundled frontend")
    func relocatedRetroArchLibrary() throws {
        let original = try builtApplication()
        try withRelocatedApplication { temporary, bundle in
            let relativeLibrary = "Contents/Frameworks/librashader.dylib"
            let library = bundle.bundleURL.appendingPathComponent(relativeLibrary)
            try FileManager.default.createDirectory(at: library.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: original.appendingPathComponent(relativeLibrary), to: library)
            let loaded = dlopen(library.path, RTLD_NOW | RTLD_LOCAL | RTLD_NODELETE)
            let diagnostic = loaded == nil ? dlerror().map { String(cString: $0) } : nil
            let handle = try #require(loaded, "Relocated runtime failed to load: \(diagnostic ?? "unknown error")")
            defer { dlclose(handle) }
            let abiSymbol = try #require(dlsym(handle, "libra_instance_abi_version"))
            let apiSymbol = try #require(dlsym(handle, "libra_instance_api_version"))
            let abi = unsafeBitCast(abiSymbol, to: PFN_libra_instance_abi_version.self)
            let api = unsafeBitCast(apiSymbol, to: PFN_libra_instance_api_version.self)
            #expect(abi() == 2)
            #expect(api() >= 5)

            // Do not accidentally pass by reusing the development library already loaded
            // by other GPU tests: this function must belong to the copied binary.
            var image = Dl_info()
            try #require(dladdr(abiSymbol, &image) != 0)
            let path = String(cString: try #require(image.dli_fname))
            #expect(URL(fileURLWithPath: path).resolvingSymlinksInPath() == library.resolvingSymlinksInPath())

            let relativeHelper = "Contents/Helpers/librashader-compiler"
            let helper = bundle.bundleURL.appendingPathComponent(relativeHelper)
            try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: original.appendingPathComponent(relativeHelper), to: helper)
            let compiler = try #require(RetroArchCompilerLocation.findCompiler(runtimeURL: library, bundle: bundle,
                environment: ["LIBRASHADER_COMPILER_PATH": "/missing/developer/compiler"]))
            #expect(compiler == helper.path)

            func symbol<T>(_ name: String, as: T.Type) throws -> T {
                unsafeBitCast(try #require(dlsym(handle, name)), to: T.self)
            }
            let presetCreate = try symbol("libra_preset_create_with_options", as: PFN_libra_preset_create_with_options.self)
            let presetFree = try symbol("libra_preset_free", as: PFN_libra_preset_free.self)
            let create = try symbol("screenslanger_mtl_filter_chain_create_with_compiler",
                                    as: PFN_screenslanger_mtl_filter_chain_create_with_compiler.self)
            let free = try symbol("libra_mtl_filter_chain_free", as: PFN_libra_mtl_filter_chain_free.self)
            let errorWrite = try symbol("libra_error_write", as: PFN_libra_error_write.self)
            let errorFree = try symbol("libra_error_free", as: PFN_libra_error_free.self)
            let stringFree = try symbol("libra_error_free_string", as: PFN_libra_error_free_string.self)
            func check(_ result: libra_error_t?) throws {
                guard result != nil else { return }
                var error = result
                var message: UnsafeMutablePointer<CChar>?
                _ = errorWrite(error, &message)
                let description = message.map { String(cString: $0) } ?? "Unknown runtime error"
                _ = stringFree(&message)
                _ = errorFree(&error)
                throw NSError(domain: "RuntimeBundleTests", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: description])
            }
            let source = temporary.appendingPathComponent("portable.slang")
            try """
            #version 450
            #pragma stage vertex
            layout(location = 0) in vec4 Position;
            layout(location = 1) in vec2 TexCoord;
            layout(location = 0) out vec2 vTexCoord;
            void main() { gl_Position = Position; vTexCoord = TexCoord; }
            #pragma stage fragment
            layout(location = 0) in vec2 vTexCoord;
            layout(location = 0) out vec4 FragColor;
            void main() { FragColor = vec4(vTexCoord, 0.6, 1.0); }
            """.write(to: source, atomically: true, encoding: .utf8)
            let presetURL = temporary.appendingPathComponent("portable.slangp")
            try "shaders = 1\nshader0 = \"portable.slang\"\n"
                .write(to: presetURL, atomically: true, encoding: .utf8)
            var preset: libra_shader_preset_t?
            var options = libra_preset_opt_t()
            options.version = 5
            try check(presetURL.path.withCString { presetCreate($0, nil, &options, &preset) })
            defer { if preset != nil { try? check(presetFree(&preset)) } }
            let device = try #require(MTLCreateSystemDefaultDevice())
            let queue = try #require(device.makeCommandQueue())
            var chain: libra_mtl_filter_chain_t?
            var chainOptions = filter_chain_mtl_opt_t()
            chainOptions.version = 5
            try check(compiler.withCString { create(&preset, queue, &chainOptions, $0, &chain) })
            try #require(chain != nil)
            try check(free(&chain))
        }
    }

    @Test("The patched runtime bundles its corresponding source and verified patches")
    func patchedRuntimeSourceProvenance() throws {
        let directory = try builtApplication().appendingPathComponent("Contents/Resources/ThirdParty/librashader")
        let manifest = try String(contentsOf: directory.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
        let files = ["librashader-v0.12.0-source.tar.gz", "0001-skip-unused-final-target.patch",
                     "0002-compact-grayscale-luts.patch", "0003-stream-metal-lut-loading.patch",
                     "0004-isolate-retroarch-compiler.patch"]
        for file in files {
            let line = try #require(manifest.split(separator: "\n").first { $0.hasSuffix("  " + file) })
            let bytes = try Data(contentsOf: directory.appendingPathComponent(file), options: .mappedIfSafe)
            let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            #expect(actual == String(line.prefix(64)), "Bundled source differs from its build manifest: \(file)")
        }
        let provenance = try String(contentsOf: directory.appendingPathComponent("BUILD-INFO.txt"), encoding: .utf8)
        #expect(provenance.contains("0.12.0-screenslanger.3"))
        #expect(provenance.contains("--bin librashader-compiler"))
        for file in ["LICENSE-MPL-2.0.md", "NOTICE.md", "BUILDING.md"] {
            #expect(!(try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)).isEmpty)
        }
    }
}
