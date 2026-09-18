import CLibrashader
import Darwin
import Foundation
import Metal

enum RetroArchRuntimeError: Error, LocalizedError {
    case unavailable(String)
    case incompleteBundle(String)
    case compilerUnavailable
    case incompatibleVersion(abi: Int, api: Int)
    case runtime(String)
    case frameInFlight
    case wrongCommandQueue

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return "librashader could not be loaded. Run scripts/setup-dependencies.sh or set LIBRASHADER_PATH to librashader.dylib. \(detail)"
        case .incompleteBundle(let detail):
            return "The app's bundled RetroArch runtime or compiler helper is missing or could not load. Reinstall a complete ScreenSlanger.app. \(detail)"
        case .compilerUnavailable:
            return "The RetroArch compiler helper is missing. Run scripts/setup-dependencies.sh or set LIBRASHADER_COMPILER_PATH to librashader-compiler."
        case .incompatibleVersion(let abi, let api):
            return "Incompatible librashader (ABI \(abi), API \(api)); ScreenSlanger requires ABI 2 and API 5 or later."
        case .runtime(let message): return "RetroArch shader: \(message)"
        case .frameInFlight: return "The previous RetroArch shader frame is still using its GPU resources."
        case .wrongCommandQueue: return "The RetroArch shader command buffer belongs to a different Metal command queue."
        }
    }
}

/// App bundles always use their own short-lived frontend. Development probes can
/// override it, or keep it next to the selected runtime installation.
enum RetroArchCompilerLocation {
    static func findCompiler(
        runtimeURL: URL,
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let paths: [String]
        if bundle.bundleURL.pathExtension.lowercased() == "app" {
            paths = [bundle.bundleURL.appendingPathComponent("Contents/Helpers/librashader-compiler").path]
        } else {
            paths = [environment["LIBRASHADER_COMPILER_PATH"],
                     runtimeURL.deletingLastPathComponent().appendingPathComponent("librashader-compiler").path]
                .compactMap { $0 }
        }
        return paths.first { path in
            FileManager.default.isExecutableFile(atPath: path)
                && (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }
}

/// One chain per display: feedback and history must never be shared across displays.
/// The Metal runtime is not thread safe. All C calls, including creation and destruction,
/// run on one dedicated OS thread. The wrapper transfers only immutable metadata and
/// Metal objects whose encoding ownership is handed to that thread for the call.
final class RetroArchFilterChain: Sendable {
    let parameters: [ShaderParameter]
    private let worker: LibraWorker

    /// Compilation is synchronous; invoke this from the shader-loading task, not the UI actor.
    init(shaderURL: URL, commandQueue: any MTLCommandQueue) throws {
        let worker = LibraWorker()
        self.worker = worker
        parameters = try worker.perform { state in
            let newState = try LibraState(shaderURL: shaderURL, commandQueue: commandQueue)
            state = newState
            return newState.parameters
        }
    }

    /// Encode into a fresh command buffer, then commit it before calling again. The caller
    /// must retain this chain through completion. Busy chains return frameInFlight instead
    /// of blocking the UI or overwriting uniforms while the GPU reads them.
    func encode(
        commandBuffer: any MTLCommandBuffer,
        input: any MTLTexture,
        output: any MTLTexture,
        frameCount: UInt,
        framesPerSecond: Float,
        frameTimeMilliseconds: UInt32,
        parameterValues: [String: Float]
    ) throws {
        let frame = LibraFrame(commandBuffer: commandBuffer, input: input, output: output)
        try worker.perform { state in
            guard let state else { throw RetroArchRuntimeError.runtime("Filter chain has been released.") }
            try state.encode(commandBuffer: frame.commandBuffer, input: frame.input, output: frame.output,
                             frameCount: frameCount, framesPerSecond: framesPerSecond,
                             frameTimeMilliseconds: frameTimeMilliseconds, parameterValues: parameterValues)
        }
        let commandID = ObjectIdentifier(commandBuffer)
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.releaseCompletedFrame(id: commandID)
        }
    }

    /// Release completed command storage even when a static desktop produces no
    /// next frame. Never block a Metal callback on the worker: teardown on that
    /// thread may itself be waiting for command completion.
    func releaseCompletedFrame(id: ObjectIdentifier) {
        // Metal can invoke completion while destroying an abandoned command.
        // Carry its identity, never retain the callback's potentially dying buffer.
        worker.schedule { state in state?.releaseCompletedFrame(id: id) }
    }

    /// If later encoding fails and the caller drops the unsubmitted command buffer,
    /// release the busy gate. Call only after deciding that buffer will never be committed.
    func discardUnsubmittedFrame(commandBuffer: any MTLCommandBuffer) {
        let command = LibraCommand(buffer: commandBuffer)
        try? worker.perform { state in state?.discardUnsubmittedFrame(command.buffer) }
    }
}

private struct LibraCommand: @unchecked Sendable {
    // The worker only inspects identity/status here; it never encodes commands.
    let buffer: any MTLCommandBuffer
}

/// The caller lends encoding ownership for the synchronous worker request: it cannot
/// encode or modify these resources until encode returns, and must not mutate textures
/// until GPU completion. Metal permits this handoff but does not annotate these protocols.
private struct LibraFrame: @unchecked Sendable {
    let commandBuffer: any MTLCommandBuffer
    let input: any MTLTexture
    let output: any MTLTexture
}

/// A blocking request/reply queue keeps opaque Rust objects on their creation thread.
/// Locking protects jobs and results; the backend itself never leaves the thread closure.
private final class LibraWorker: Sendable {
    private final class Queue: @unchecked Sendable {
        typealias Job = @Sendable (inout LibraState?) -> Void
        private let condition = NSCondition()
        private var jobs: [Job] = []
        private var finished = false

        func append(_ job: @escaping Job) {
            condition.lock()
            jobs.append(job)
            condition.signal()
            condition.unlock()
        }

        func next() -> Job? {
            condition.lock()
            defer { condition.unlock() }
            while jobs.isEmpty && !finished { condition.wait() }
            return jobs.isEmpty ? nil : jobs.removeFirst()
        }

        func finish() {
            condition.lock()
            finished = true
            condition.signal()
            condition.unlock()
        }
    }

    private final class Reply<Value: Sendable>: @unchecked Sendable {
        private let condition = NSCondition()
        private var result: Result<Value, Error>?

        func complete(_ result: Result<Value, Error>) {
            condition.lock()
            self.result = result
            condition.signal()
            condition.unlock()
        }

        func wait() throws -> Value {
            condition.lock()
            defer { condition.unlock() }
            while result == nil { condition.wait() }
            return try result!.get()
        }
    }

    private let queue: Queue

    init() {
        let queue = Queue()
        self.queue = queue
        let thread = Thread {
            var state: LibraState?
            while let job = queue.next() {
                autoreleasepool { job(&state) }
            }
            // Destruction happens on the same OS thread as every other C call.
            autoreleasepool { state = nil }
        }
        thread.name = "ScreenSlanger RetroArch rendering"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    deinit { queue.finish() }

    func schedule(_ body: @escaping @Sendable (inout LibraState?) -> Void) {
        queue.append(body)
    }

    func perform<Value: Sendable>(_ body: @escaping @Sendable (inout LibraState?) throws -> Value) throws -> Value {
        let reply = Reply<Value>()
        queue.append { state in reply.complete(Result { try body(&state) }) }
        return try reply.wait()
    }
}

/// Confined to LibraWorker's thread. Never mark the raw C handles Sendable.
private final class LibraState {
    let parameters: [ShaderParameter]
    private let api: LibraAPI
    private let commandQueue: any MTLCommandQueue
    private var chain: libra_mtl_filter_chain_t?
    private var lastCommandBuffer: (any MTLCommandBuffer)?
    private var parameterValues: [String: Float] = [:]

    init(shaderURL: URL, commandQueue: any MTLCommandQueue) throws {
        let api = try LibraAPI()
        self.api = api
        self.commandQueue = commandQueue
        var temporaryDirectory: URL?
        defer {
            if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        }

        let presetURL: URL
        if shaderURL.pathExtension.lowercased() == "slangp" {
            presetURL = shaderURL
        } else {
            // Keep the actual source at its original path so relative includes work.
            let sourcePath = shaderURL.standardizedFileURL.path
            guard !sourcePath.contains("\""), !sourcePath.contains("\n"), !sourcePath.contains("\r") else {
                throw RetroArchRuntimeError.runtime("Shader paths containing quotes or newlines cannot be represented in a preset.")
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenSlanger-preset-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            temporaryDirectory = directory
            presetURL = directory.appendingPathComponent("single-pass.slangp")
            try "shaders = 1\nshader0 = \"\(sourcePath)\"\n".write(to: presetURL, atomically: true, encoding: .utf8)
        }

        var preset: libra_shader_preset_t?
        var options = libra_preset_opt_t()
        options.version = 5
        options.original_aspect_uniforms = true
        options.frametime_uniforms = true
        try api.check(presetURL.path.withCString { api.presetCreate($0, nil, &options, &preset) })
        // create consumes and nulls the preset. v0.12.0's preset_free panics on a
        // null handle despite the header documenting it as a no-op.
        defer { if preset != nil { api.discard(api.presetFree(&preset)) } }

        var metadata = libra_preset_param_list_t()
        try api.check(api.presetParameters(&preset, &metadata))
        defer { api.discard(api.presetParametersFree(metadata)) }
        parameters = (0..<Int(metadata.length)).map { index in
            let parameter = metadata.parameters![index]
            return ShaderParameter(name: String(cString: parameter.name), description: String(cString: parameter.description),
                                   defaultValue: parameter.initial, minValue: parameter.minimum,
                                   maxValue: parameter.maximum, stepValue: parameter.step)
        }
        var chainOptions = filter_chain_mtl_opt_t()
        chainOptions.version = 5
        try api.check(api.compilerPath.withCString {
            api.chainCreate(&preset, commandQueue, &chainOptions, $0, &chain)
        })
        guard chain != nil else { throw RetroArchRuntimeError.runtime("Runtime returned no filter chain.") }
    }

    deinit {
        // Shared uniforms and intermediate textures remain live until the GPU is done.
        if let lastCommandBuffer, lastCommandBuffer.status == .committed || lastCommandBuffer.status == .scheduled {
            lastCommandBuffer.waitUntilCompleted()
        }
        if chain != nil { api.discard(api.chainFree(&chain)) }
    }

    func encode(commandBuffer: any MTLCommandBuffer, input: any MTLTexture, output: any MTLTexture,
                frameCount: UInt, framesPerSecond: Float, frameTimeMilliseconds: UInt32,
                parameterValues: [String: Float]) throws {
        guard commandBuffer.commandQueue === commandQueue else { throw RetroArchRuntimeError.wrongCommandQueue }
        if let previous = lastCommandBuffer, previous.status != .completed && previous.status != .error {
            throw RetroArchRuntimeError.frameInFlight
        }
        for parameter in parameters {
            let value = parameterValues[parameter.name] ?? parameter.defaultValue
            if self.parameterValues[parameter.name] != value {
                try api.check(parameter.name.withCString { api.chainSetParameter(&chain, $0, value) })
                self.parameterValues[parameter.name] = value
            }
        }
        var options = frame_mtl_opt_t()
        options.version = 5
        options.frame_direction = 1
        options.total_subframes = 1
        options.current_subframe = 1
        options.aspect_ratio = Float(input.width) / Float(input.height)
        options.frames_per_second = framesPerSecond
        options.frametime_delta = frameTimeMilliseconds
        options.brightness_nits = 200
        try api.check(api.chainFrame(&chain, commandBuffer, Int(truncatingIfNeeded: frameCount), input, output, nil, nil, &options))
        lastCommandBuffer = commandBuffer
    }

    func releaseCompletedFrame(id: ObjectIdentifier) {
        // A new frame can be encoded before an older completion reaches this
        // queue. Its busy gate and retained resources belong to that new frame.
        if let commandBuffer = lastCommandBuffer, ObjectIdentifier(commandBuffer) == id,
           commandBuffer.status == .completed || commandBuffer.status == .error {
            lastCommandBuffer = nil
        }
    }

    func discardUnsubmittedFrame(_ commandBuffer: any MTLCommandBuffer) {
        if lastCommandBuffer === commandBuffer, commandBuffer.status == .notEnqueued {
            lastCommandBuffer = nil
        }
    }
}

/// Function pointers use the vendored official C declarations, preserving ABI layout.
/// Every instance owns its dlopen reference until the filter chain has been destroyed.
private final class LibraAPI {
    private let handle: UnsafeMutableRawPointer
    let compilerPath: String
    let presetCreate: PFN_libra_preset_create_with_options
    let presetFree: PFN_libra_preset_free
    let presetParameters: PFN_libra_preset_get_runtime_params
    let presetParametersFree: PFN_libra_preset_free_runtime_params
    let chainCreate: PFN_screenslanger_mtl_filter_chain_create_with_compiler
    let chainFrame: PFN_libra_mtl_filter_chain_frame
    let chainSetParameter: PFN_libra_mtl_filter_chain_set_param
    let chainFree: PFN_libra_mtl_filter_chain_free
    private let errorWrite: PFN_libra_error_write
    private let errorFree: PFN_libra_error_free
    private let errorStringFree: PFN_libra_error_free_string

    init() throws {
        let isAppBundle = Bundle.main.bundleURL.pathExtension.lowercased() == "app"
        let paths: [String]
        if isAppBundle {
            // Distributed applications must be self-contained. Do not conceal a broken
            // bundle by borrowing a developer's per-user installation or environment.
            paths = [Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/librashader.dylib").path]
        } else {
            // Unhosted tests and compiler probes use the pinned development installation.
            paths = [
                ProcessInfo.processInfo.environment["LIBRASHADER_PATH"],
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ScreenSlanger/Tools/librashader/0.12.0-screenslanger.3/librashader.dylib").path
            ].compactMap { $0 }
        }
        var loaded: UnsafeMutableRawPointer?
        var loadedPath: String?
        var failures: [String] = []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            // The Rust runtime may retain global worker threads. Keep its executable
            // mapping alive even after the last chain releases its dlopen reference.
            if let candidate = dlopen(path, RTLD_NOW | RTLD_LOCAL | RTLD_NODELETE) {
                loaded = candidate
                loadedPath = path
                break
            }
            if let error = dlerror() { failures.append(String(cString: error)) }
        }
        guard let loaded, let loadedPath else {
            let detail = failures.joined(separator: "\n")
            if isAppBundle { throw RetroArchRuntimeError.incompleteBundle(detail) }
            throw RetroArchRuntimeError.unavailable(detail)
        }
        handle = loaded
        func symbol<T>(_ name: String, as: T.Type = T.self) throws -> T {
            guard let pointer = dlsym(loaded, name) else { throw RetroArchRuntimeError.unavailable("Missing function \(name).") }
            return unsafeBitCast(pointer, to: T.self)
        }
        do {
            guard let compiler = RetroArchCompilerLocation.findCompiler(runtimeURL: URL(fileURLWithPath: loadedPath)) else {
                if isAppBundle { throw RetroArchRuntimeError.incompleteBundle("Missing librashader-compiler.") }
                throw RetroArchRuntimeError.compilerUnavailable
            }
            compilerPath = compiler
            let abi: PFN_libra_instance_abi_version = try symbol("libra_instance_abi_version")
            let api: PFN_libra_instance_api_version = try symbol("libra_instance_api_version")
            guard abi() == 2, api() >= 5 else { throw RetroArchRuntimeError.incompatibleVersion(abi: abi(), api: api()) }
            presetCreate = try symbol("libra_preset_create_with_options")
            presetFree = try symbol("libra_preset_free")
            presetParameters = try symbol("libra_preset_get_runtime_params")
            presetParametersFree = try symbol("libra_preset_free_runtime_params")
            chainCreate = try symbol("screenslanger_mtl_filter_chain_create_with_compiler")
            chainFrame = try symbol("libra_mtl_filter_chain_frame")
            chainSetParameter = try symbol("libra_mtl_filter_chain_set_param")
            chainFree = try symbol("libra_mtl_filter_chain_free")
            errorWrite = try symbol("libra_error_write")
            errorFree = try symbol("libra_error_free")
            errorStringFree = try symbol("libra_error_free_string")
        } catch {
            dlclose(loaded)
            throw error
        }
    }

    deinit { dlclose(handle) }

    func check(_ error: libra_error_t?) throws {
        guard let error else { return }
        var message: UnsafeMutablePointer<CChar>?
        _ = errorWrite(error, &message)
        let text = message.map { String(cString: $0) } ?? "Unknown librashader error."
        _ = errorStringFree(&message)
        discard(error)
        throw RetroArchRuntimeError.runtime(text)
    }

    func discard(_ error: libra_error_t?) {
        var error = error
        _ = errorFree(&error)
    }
}
