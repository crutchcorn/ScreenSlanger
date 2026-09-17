import CLibrashader
import Darwin
import Foundation
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

    @Test("The bundled RetroArch runtime loads from its relocated path")
    func relocatedRetroArchLibrary() throws {
        let original = try builtApplication()
        try withRelocatedApplication { _, bundle in
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
        }
    }
}
