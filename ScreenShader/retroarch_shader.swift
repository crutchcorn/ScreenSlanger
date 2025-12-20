import Foundation

/// Errors specific to RetroArch shader compilation
enum RetroArchShaderError: Error, LocalizedError {
    case glslangNotFound
    case spirvCrossNotFound
    case preprocessingFailed(String)
    case glslCompilationFailed(String)
    case spirvConversionFailed(String)
    case invalidShaderFormat(String)
    case missingTexture(String)
    case processError(String)
    
    var errorDescription: String? {
        switch self {
        case .glslangNotFound:
            return "glslangValidator not found. Install via: brew install glslang"
        case .spirvCrossNotFound:
            return "spirv-cross not found. Install via: brew install spirv-cross"
        case .preprocessingFailed(let message):
            return "Shader preprocessing failed: \(message)"
        case .glslCompilationFailed(let message):
            return "GLSL compilation failed: \(message)"
        case .spirvConversionFailed(let message):
            return "SPIRV to Metal conversion failed: \(message)"
        case .invalidShaderFormat(let message):
            return "Invalid shader format: \(message)"
        case .missingTexture(let name):
            return "Missing texture: \(name)"
        case .processError(let message):
            return "Process error: \(message)"
        }
    }
}

/// Represents a sampler/texture declaration in a RetroArch shader
struct ShaderSampler {
    let name: String
    let binding: Int
    let set: Int
}

/// Preprocessed RetroArch shader with separated vertex/fragment stages
struct RetroArchShaderStages {
    let vertexSource: String
    let fragmentSource: String
    let parameters: [ShaderParameter]
    let samplers: [ShaderSampler]
    let format: String?
}

/// Compiled RetroArch shader ready for Metal
struct CompiledRetroArchShader {
    let metalSource: String
    let vertexFunctionName: String
    let fragmentFunctionName: String
    let parameters: [ShaderParameter]
    let samplers: [ShaderSampler]
}

/// Texture definition from a slangp preset file
struct PresetTexture {
    let name: String
    let path: String
    let linear: Bool
    let wrapMode: String?
    let mipmap: Bool
}

/// Parsed slangp shader preset
struct ShaderPreset {
    let shaderPath: String
    let textures: [PresetTexture]
    let parameterValues: [String: Float]
    let filterLinear: Bool
    let wrapMode: String?
    let presetDirectory: URL
    
    /// Parse a .slangp preset file
    static func parse(from url: URL) throws -> ShaderPreset {
        let content = try String(contentsOf: url, encoding: .utf8)
        let presetDir = url.deletingLastPathComponent()
        
        var shaderPath: String? = nil
        var textures: [PresetTexture] = []
        var parameterValues: [String: Float] = [:]
        var filterLinear = true
        var wrapMode: String? = nil
        var textureNames: [String] = []
        var textureProps: [String: (path: String?, linear: Bool, wrapMode: String?, mipmap: Bool)] = [:]
        
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty && !trimmed.hasPrefix("#") else { continue }
            
            // Parse key = "value" or key = value
            guard let equalsIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: equalsIndex)...])
                .trimmingCharacters(in: .whitespaces)
            // Remove quotes
            if value.hasPrefix("\"") && value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            
            // Parse known keys
            if key == "shader0" {
                shaderPath = value
            } else if key == "filter_linear0" {
                filterLinear = value.lowercased() == "true"
            } else if key == "wrap_mode0" {
                wrapMode = value
            } else if key == "textures" {
                // Semicolon-separated list of texture names
                textureNames = value.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if textureNames.contains(key) {
                // This is a texture path
                var props = textureProps[key] ?? (path: nil, linear: false, wrapMode: nil, mipmap: false)
                props.path = value
                textureProps[key] = props
            } else if key.hasSuffix("_linear") {
                let texName = String(key.dropLast("_linear".count))
                if textureNames.contains(texName) {
                    var props = textureProps[texName] ?? (path: nil, linear: false, wrapMode: nil, mipmap: false)
                    props.linear = value.lowercased() == "true"
                    textureProps[texName] = props
                }
            } else if key.hasSuffix("_wrap_mode") {
                let texName = String(key.dropLast("_wrap_mode".count))
                if textureNames.contains(texName) {
                    var props = textureProps[texName] ?? (path: nil, linear: false, wrapMode: nil, mipmap: false)
                    props.wrapMode = value
                    textureProps[texName] = props
                }
            } else if key.hasSuffix("_mipmap") {
                let texName = String(key.dropLast("_mipmap".count))
                if textureNames.contains(texName) {
                    var props = textureProps[texName] ?? (path: nil, linear: false, wrapMode: nil, mipmap: false)
                    props.mipmap = value.lowercased() == "true"
                    textureProps[texName] = props
                }
            } else if let floatVal = Float(value) {
                // Assume it's a parameter value
                parameterValues[key] = floatVal
            }
        }
        
        // Build texture list
        for name in textureNames {
            if let props = textureProps[name], let path = props.path {
                textures.append(PresetTexture(
                    name: name,
                    path: path,
                    linear: props.linear,
                    wrapMode: props.wrapMode,
                    mipmap: props.mipmap
                ))
            }
        }
        
        guard let shader = shaderPath else {
            throw RetroArchShaderError.invalidShaderFormat("No shader0 defined in preset")
        }
        
        return ShaderPreset(
            shaderPath: shader,
            textures: textures,
            parameterValues: parameterValues,
            filterLinear: filterLinear,
            wrapMode: wrapMode,
            presetDirectory: presetDir
        )
    }
    
    /// Resolve a relative path from the preset
    func resolvePath(_ relativePath: String) -> URL {
        return presetDirectory.appendingPathComponent(relativePath)
    }
}

/// Compiler for RetroArch-style .slang shaders (GLSL with extensions)
class RetroArchShaderCompiler {
    
    // MARK: - Tool Discovery
    
    private static let glslangSearchPaths = [
        ProcessInfo.processInfo.environment["GLSLANG_PATH"],
        "/opt/homebrew/bin/glslangValidator",
        "/usr/local/bin/glslangValidator",
        "/usr/bin/glslangValidator",
        Bundle.main.path(forResource: "glslangValidator", ofType: nil)
    ].compactMap { $0 }
    
    private static let spirvCrossSearchPaths = [
        ProcessInfo.processInfo.environment["SPIRV_CROSS_PATH"],
        "/opt/homebrew/bin/spirv-cross",
        "/usr/local/bin/spirv-cross",
        "/usr/bin/spirv-cross",
        Bundle.main.path(forResource: "spirv-cross", ofType: nil)
    ].compactMap { $0 }
    
    static func findGlslang() -> String? {
        for path in glslangSearchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
    
    static func findSpirvCross() -> String? {
        for path in spirvCrossSearchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
    
    static var isAvailable: Bool {
        return findGlslang() != nil && findSpirvCross() != nil
    }
    
    static var missingTools: [String] {
        var missing: [String] = []
        if findGlslang() == nil {
            missing.append("glslangValidator (install via: brew install glslang)")
        }
        if findSpirvCross() == nil {
            missing.append("spirv-cross (install via: brew install spirv-cross)")
        }
        return missing
    }
    
    // MARK: - Shader Detection
    
    /// Detect if a shader source is RetroArch-style (GLSL with pragmas)
    static func isRetroArchShader(_ source: String) -> Bool {
        let indicators = [
            "#version 450",
            "#pragma stage",
            "layout(push_constant)",
            "layout(std140, set = 0, binding = 0) uniform UBO"
        ]
        return indicators.contains { source.contains($0) }
    }
    
    // MARK: - Preprocessing
    
    /// Preprocess a RetroArch shader, extracting parameters and separating stages
    static func preprocess(_ source: String) throws -> RetroArchShaderStages {
        var parameters: [ShaderParameter] = []
        var samplers: [ShaderSampler] = []
        var format: String? = nil
        
        var vertexLines: [String] = []
        var fragmentLines: [String] = []
        var sharedLines: [String] = []  // Lines that go in both (uniforms, etc.)
        
        var currentStage: String? = nil // nil = common/shared, "vertex", "fragment"
        
        let lines = source.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Parse #pragma parameter
            if trimmed.hasPrefix("#pragma parameter") {
                if let param = ShaderParameter.parse(from: line) {
                    // Deduplicate parameters
                    if !parameters.contains(where: { $0.name == param.name }) {
                        parameters.append(param)
                    }
                }
                continue // Don't include pragma in output
            }
            
            // Parse #pragma stage
            if trimmed.hasPrefix("#pragma stage vertex") {
                currentStage = "vertex"
                continue
            }
            if trimmed.hasPrefix("#pragma stage fragment") {
                currentStage = "fragment"
                continue
            }
            
            // Parse #pragma format
            if trimmed.hasPrefix("#pragma format") {
                format = String(trimmed.dropFirst("#pragma format".count))
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            
            // Skip #pragma name (we handle naming differently)
            if trimmed.hasPrefix("#pragma name") {
                continue
            }
            
            // Parse sampler declarations
            if trimmed.contains("uniform sampler2D") {
                if let sampler = parseSamplerDeclaration(line) {
                    samplers.append(sampler)
                }
            }
            
            // Add line to appropriate stage
            switch currentStage {
            case "vertex":
                vertexLines.append(line)
            case "fragment":
                fragmentLines.append(line)
            default:
                // Common/shared section - need to filter what goes where
                // Uniforms, push_constants go to both shaders
                // Vertex inputs (in vec4 Position) should only go to vertex
                sharedLines.append(line)
            }
        }
        
        // Filter shared lines for each stage
        let vertexSharedLines = sharedLines.filter { line in
            // Include everything in vertex shader
            return true
        }
        
        let fragmentSharedLines = sharedLines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Exclude vertex input declarations from fragment shader
            // These look like: layout(location = X) in vec4 Position;
            if trimmed.contains("layout(location") && trimmed.contains(") in ") {
                // Check if it's NOT an "out" that becomes fragment input
                if !trimmed.contains(" out ") {
                    // This is a vertex attribute input, skip in fragment
                    return false
                }
            }
            return true
        }
        
        // Build complete vertex and fragment sources
        let vertexSource = vertexSharedLines.joined(separator: "\n") + "\n" + vertexLines.joined(separator: "\n")
        let fragmentSource = fragmentSharedLines.joined(separator: "\n") + "\n" + fragmentLines.joined(separator: "\n")
        
        return RetroArchShaderStages(
            vertexSource: vertexSource,
            fragmentSource: fragmentSource,
            parameters: parameters,
            samplers: samplers,
            format: format
        )
    }
    
    /// Parse a sampler declaration like: layout(set = 0, binding = 2) uniform sampler2D Source;
    private static func parseSamplerDeclaration(_ line: String) -> ShaderSampler? {
        // Extract set and binding from layout
        var set = 0
        var binding = 0
        
        if let setMatch = line.range(of: "set\\s*=\\s*(\\d+)", options: .regularExpression) {
            let setStr = line[setMatch]
            if let numMatch = setStr.range(of: "\\d+", options: .regularExpression) {
                set = Int(setStr[numMatch]) ?? 0
            }
        }
        
        if let bindingMatch = line.range(of: "binding\\s*=\\s*(\\d+)", options: .regularExpression) {
            let bindingStr = line[bindingMatch]
            if let numMatch = bindingStr.range(of: "\\d+", options: .regularExpression) {
                binding = Int(bindingStr[numMatch]) ?? 0
            }
        }
        
        // Extract sampler name (last word before semicolon)
        if let nameMatch = line.range(of: "sampler2D\\s+(\\w+)", options: .regularExpression) {
            let matchStr = String(line[nameMatch])
            let parts = matchStr.components(separatedBy: .whitespaces)
            if parts.count >= 2 {
                let name = parts[1].replacingOccurrences(of: ";", with: "")
                return ShaderSampler(name: name, binding: binding, set: set)
            }
        }
        
        return nil
    }
    
    // MARK: - Compilation Pipeline
    
    /// Compile a RetroArch shader source to Metal
    static func compileToMetal(source: String, shaderDirectory: URL? = nil) throws -> CompiledRetroArchShader {
        guard let glslangPath = findGlslang() else {
            throw RetroArchShaderError.glslangNotFound
        }
        
        guard let spirvCrossPath = findSpirvCross() else {
            throw RetroArchShaderError.spirvCrossNotFound
        }
        
        // Preprocess the shader
        let stages = try preprocess(source)
        
        // Create temp directory
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            // Clean up temp files
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // Compile vertex shader: GLSL -> SPIRV -> Metal
        let vertexMetal = try compileStage(
            source: stages.vertexSource,
            stage: "vert",
            glslangPath: glslangPath,
            spirvCrossPath: spirvCrossPath,
            tempDir: tempDir,
            shaderDirectory: shaderDirectory
        )
        
        // Compile fragment shader: GLSL -> SPIRV -> Metal
        let fragmentMetal = try compileStage(
            source: stages.fragmentSource,
            stage: "frag",
            glslangPath: glslangPath,
            spirvCrossPath: spirvCrossPath,
            tempDir: tempDir,
            shaderDirectory: shaderDirectory
        )
        
        // Combine Metal sources
        let combinedMetal = combineMetalShaders(
            vertexMetal: vertexMetal,
            fragmentMetal: fragmentMetal,
            parameters: stages.parameters
        )
        
        // Parse actual Metal texture bindings from generated code
        // spirv-cross remaps bindings sequentially, so we need to extract the actual indices
        let metalSamplers = parseMetalTextureBindings(from: fragmentMetal)
        
        return CompiledRetroArchShader(
            metalSource: combinedMetal,
            vertexFunctionName: "vertex_main",
            fragmentFunctionName: "fragment_main",
            parameters: stages.parameters,
            samplers: metalSamplers
        )
    }
    
    /// Parse texture bindings from generated Metal source
    /// Looks for patterns like: texture2d<float> BACKGROUND [[texture(1)]]
    private static func parseMetalTextureBindings(from metalSource: String) -> [ShaderSampler] {
        var samplers: [ShaderSampler] = []
        
        // Match patterns like: texture2d<float> TextureName [[texture(N)]]
        let pattern = #"texture2d<\w+>\s+(\w+)\s+\[\[texture\((\d+)\)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            print("DEBUG: Failed to create regex for texture binding parsing")
            return samplers
        }
        
        let range = NSRange(metalSource.startIndex..., in: metalSource)
        let matches = regex.matches(in: metalSource, range: range)
        
        print("DEBUG: parseMetalTextureBindings found \(matches.count) texture matches in \(metalSource.count) chars")
        
        for match in matches {
            guard match.numberOfRanges >= 3,
                  let nameRange = Range(match.range(at: 1), in: metalSource),
                  let bindingRange = Range(match.range(at: 2), in: metalSource),
                  let binding = Int(metalSource[bindingRange]) else {
                continue
            }
            
            let name = String(metalSource[nameRange])
            print("DEBUG: Found texture '\(name)' at binding \(binding)")
            samplers.append(ShaderSampler(name: name, binding: binding, set: 0))
        }
        
        return samplers
    }
    
    /// Compile a single shader stage
    private static func compileStage(
        source: String,
        stage: String,  // "vert" or "frag"
        glslangPath: String,
        spirvCrossPath: String,
        tempDir: URL,
        shaderDirectory: URL?
    ) throws -> String {
        let inputFile = tempDir.appendingPathComponent("shader.\(stage).glsl")
        let spirvFile = tempDir.appendingPathComponent("shader.\(stage).spv")
        let metalFile = tempDir.appendingPathComponent("shader.\(stage).metal")
        
        // Write GLSL source
        try source.write(to: inputFile, atomically: true, encoding: .utf8)
        
        // Step 1: GLSL -> SPIRV using glslangValidator
        let glslangProcess = Process()
        glslangProcess.executableURL = URL(fileURLWithPath: glslangPath)
        glslangProcess.arguments = [
            "-V",  // Vulkan GLSL
            "-S", stage,  // Shader stage
            "-o", spirvFile.path,
            inputFile.path
        ]
        
        // Add include path if shader directory is specified
        // Note: -I must be directly followed by path with no space (e.g., -I/path/to/dir)
        if let dir = shaderDirectory {
            glslangProcess.arguments?.insert("-I\(dir.path)", at: 1)
        }
        
        // Use file-based output capture for more reliable error capture
        let glslangStdoutFile = tempDir.appendingPathComponent("glslang_stdout.txt")
        let glslangStderrFile = tempDir.appendingPathComponent("glslang_stderr.txt")
        
        FileManager.default.createFile(atPath: glslangStdoutFile.path, contents: nil)
        FileManager.default.createFile(atPath: glslangStderrFile.path, contents: nil)
        
        let stdoutHandle = try FileHandle(forWritingTo: glslangStdoutFile)
        let stderrHandle = try FileHandle(forWritingTo: glslangStderrFile)
        
        glslangProcess.standardOutput = stdoutHandle
        glslangProcess.standardError = stderrHandle
        
        do {
            try glslangProcess.run()
            glslangProcess.waitUntilExit()
        } catch {
            throw RetroArchShaderError.processError("Failed to run glslangValidator: \(error)")
        }
        
        try? stdoutHandle.close()
        try? stderrHandle.close()
        
        let stdoutMessage = (try? String(contentsOf: glslangStdoutFile, encoding: .utf8)) ?? ""
        let stderrMessage = (try? String(contentsOf: glslangStderrFile, encoding: .utf8)) ?? ""
        
        if glslangProcess.terminationStatus != 0 {
            let combinedError = [stdoutMessage, stderrMessage]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw RetroArchShaderError.glslCompilationFailed(
                combinedError.isEmpty ? "glslang failed with exit code \(glslangProcess.terminationStatus). Check temp files at: \(tempDir.path)" : combinedError
            )
        }
        
        // Step 2: SPIRV -> Metal using spirv-cross
        // Rename entry point based on stage to avoid conflicts when combining
        let entryPointName = stage == "vert" ? "vertex_main" : "fragment_main"
        
        let spirvCrossProcess = Process()
        spirvCrossProcess.executableURL = URL(fileURLWithPath: spirvCrossPath)
        spirvCrossProcess.arguments = [
            spirvFile.path,
            "--msl",  // Metal Shading Language output
            "--msl-version", "20100",  // Metal 2.1
            "--rename-entry-point", "main", entryPointName, stage,  // Rename main to vertex_main/fragment_main
            "--output", metalFile.path
        ]
        
        let spirvCrossError = Pipe()
        spirvCrossProcess.standardError = spirvCrossError
        spirvCrossProcess.standardOutput = Pipe()
        
        do {
            try spirvCrossProcess.run()
            spirvCrossProcess.waitUntilExit()
        } catch {
            throw RetroArchShaderError.processError("Failed to run spirv-cross: \(error)")
        }
        
        if spirvCrossProcess.terminationStatus != 0 {
            let errorData = spirvCrossError.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw RetroArchShaderError.spirvConversionFailed(errorMessage)
        }
        
        // Read Metal source
        guard let metalSource = try? String(contentsOf: metalFile, encoding: .utf8) else {
            throw RetroArchShaderError.spirvConversionFailed("Failed to read generated Metal source")
        }
        
        return metalSource
    }
    
    /// Combine vertex and fragment Metal shaders into a single source file
    private static func combineMetalShaders(
        vertexMetal: String,
        fragmentMetal: String,
        parameters: [ShaderParameter]
    ) -> String {
        // ScreenShader renders fullscreen quads procedurally without vertex buffers.
        // The RetroArch vertex shader expects vertex inputs, so we need to:
        // 1. Use a custom vertex shader that generates fullscreen quad vertices
        // 2. Extract shared structs (Push, UBO) from the generated Metal code
        // 3. Use the RetroArch fragment shader as-is
        
        // Extract structs from vertex shader (Push is shared, UBO is not needed for our vertex shader)
        var sharedStructs = ""
        var inStruct = false
        var braceCount = 0
        var currentStruct = ""
        
        for line in vertexMetal.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Capture struct definitions (Push only - we generate our own vertex shader)
            if trimmed.hasPrefix("struct Push") {
                inStruct = true
                braceCount = 0
                currentStruct = ""
            }
            
            if inStruct {
                currentStruct += line + "\n"
                braceCount += line.filter { $0 == "{" }.count
                braceCount -= line.filter { $0 == "}" }.count
                if braceCount == 0 && currentStruct.contains("{") {
                    sharedStructs += currentStruct + "\n"
                    inStruct = false
                    currentStruct = ""
                }
            }
        }
        
        // Extract fragment function and its output struct from fragment shader
        // First, rename fragment_main_in references since we'll provide our own vertex output
        var fragmentProcessed = fragmentMetal
        
        // Extract fragment_main_out struct
        var fragmentOutStruct = ""
        inStruct = false
        braceCount = 0
        currentStruct = ""
        
        for line in fragmentMetal.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("struct fragment_main_out") {
                inStruct = true
                braceCount = 0
                currentStruct = ""
            }
            
            if inStruct {
                currentStruct += line + "\n"
                braceCount += line.filter { $0 == "{" }.count
                braceCount -= line.filter { $0 == "}" }.count
                if braceCount == 0 && currentStruct.contains("{") {
                    fragmentOutStruct = currentStruct
                    inStruct = false
                    break
                }
            }
        }
        
        // Extract fragment function
        var fragmentFunction = ""
        var inFunction = false
        braceCount = 0
        
        for line in fragmentMetal.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("fragment fragment_main_out fragment_main") {
                inFunction = true
                braceCount = 0
            }
            
            if inFunction {
                fragmentFunction += line + "\n"
                braceCount += line.filter { $0 == "{" }.count
                braceCount -= line.filter { $0 == "}" }.count
                if braceCount == 0 && fragmentFunction.contains("{") {
                    break
                }
            }
        }
        
        // Replace fragment_main_in with VertexOut in the fragment function
        fragmentFunction = fragmentFunction.replacingOccurrences(
            of: "fragment_main_in",
            with: "VertexOut"
        )
        
        // Fix grayscale texture sampling: BACKGROUND textures may be grayscale (R8)
        // When sampling a grayscale texture, only .r has the value, .gb are 0
        // Replace BACKGROUND.sample(...).xyz with BACKGROUND.sample(...).rrr
        // This uses regex to handle any sampler name like BACKGROUNDSmplr
        fragmentFunction = fragmentFunction.replacingOccurrences(
            of: "BACKGROUND.sample(BACKGROUNDSmplr,",
            with: "float4(BACKGROUND.sample(BACKGROUNDSmplr,"
        )
        // Find the pattern: BACKGROUND.sample(...).xyz and change to use .rrr
        // Since the sample returns float4, we need to extract just the red channel repeated
        if let range = fragmentFunction.range(of: "float4(BACKGROUND.sample(BACKGROUNDSmplr, (bgPixelCoord * 0.000244140625))).xyz") {
            fragmentFunction = fragmentFunction.replacingCharacters(
                in: range, 
                with: "BACKGROUND.sample(BACKGROUNDSmplr, (bgPixelCoord * 0.000244140625)).rrr"
            )
        } else {
            // More generic approach - fix any BACKGROUND sampling that ends in .xyz
            fragmentFunction = fragmentFunction.replacingOccurrences(
                of: "float4(BACKGROUND.sample(BACKGROUNDSmplr,",
                with: "BACKGROUND.sample(BACKGROUNDSmplr,"
            )
            // Replace .xyz with .rrr for BACKGROUND texture samples
            // This is a heuristic - look for the pattern in the generated code
            var lines = fragmentFunction.components(separatedBy: .newlines)
            for i in 0..<lines.count {
                if lines[i].contains("BACKGROUND.sample") && lines[i].contains(".xyz") {
                    lines[i] = lines[i].replacingOccurrences(of: ".xyz", with: ".rrr")
                }
            }
            fragmentFunction = lines.joined(separator: "\n")
        }
        
        // Build combined shader with custom vertex shader
        let combined = """
        // Combined RetroArch shader compiled for Metal
        // Auto-generated by ScreenShader
        
        #include <metal_stdlib>
        #include <simd/simd.h>
        
        using namespace metal;
        
        // === Shared Structs from RetroArch Shader ===
        \(sharedStructs)
        
        // === Vertex Shader Output / Fragment Shader Input ===
        // Note: [[user(locn0)]] matches spirv-cross's layout(location = 0)
        struct VertexOut {
            float4 position [[position]];
            float2 vTexCoord [[user(locn0)]];
        };
        
        // === Custom Vertex Shader (Fullscreen Quad) ===
        vertex VertexOut vertex_main(uint vertexId [[vertex_id]]) {
            // Generate fullscreen quad vertices procedurally
            float2 quadVertices[6] = {
                float2(-1.0, -1.0),
                float2( 1.0, -1.0),
                float2(-1.0,  1.0),
                float2(-1.0,  1.0),
                float2( 1.0, -1.0),
                float2( 1.0,  1.0)
            };
            
            VertexOut out;
            out.position = float4(quadVertices[vertexId], 0.0, 1.0);
            // Texture coordinates: (0,0) at top-left, (1,1) at bottom-right
            out.vTexCoord = float2(
                (quadVertices[vertexId].x + 1.0) * 0.5,
                (1.0 - quadVertices[vertexId].y) * 0.5
            );
            return out;
        }
        
        // === Fragment Shader Output ===
        \(fragmentOutStruct)
        
        // === Fragment Shader ===
        \(fragmentFunction)
        """
        
        return combined
    }
}

// MARK: - Integration with SlangCompiler

extension SlangCompiler {
    
    /// Detect shader type and compile appropriately
    static func compileShader(source: String, shaderDirectory: URL? = nil) throws -> (metalSource: String, parameters: [ShaderParameter], isRetroArch: Bool) {
        if RetroArchShaderCompiler.isRetroArchShader(source) {
            // Use RetroArch compiler
            if !RetroArchShaderCompiler.isAvailable {
                let missing = RetroArchShaderCompiler.missingTools.joined(separator: ", ")
                throw SlangCompilerError.compilationFailed(
                    "RetroArch shader detected but required tools are missing: \(missing)"
                )
            }
            
            let compiled = try RetroArchShaderCompiler.compileToMetal(
                source: source,
                shaderDirectory: shaderDirectory
            )
            return (compiled.metalSource, compiled.parameters, true)
        } else {
            // Use standard Slang compiler
            let wrappedSource = wrapEffectSource(source)
            let metalSource = try compileToMetal(slangSource: wrappedSource)
            return (metalSource, [], false)
        }
    }
}
