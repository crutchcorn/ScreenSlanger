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
        var commonLines: [String] = []
        
        var currentStage: String? = nil // nil = common, "vertex", "fragment"
        var inPushConstant = false
        var pushConstantFields: [String] = []
        
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
                commonLines.append(line)
            }
        }
        
        // Build complete vertex and fragment sources with common prefix
        let commonSource = commonLines.joined(separator: "\n")
        let vertexSource = commonSource + "\n" + vertexLines.joined(separator: "\n")
        let fragmentSource = commonSource + "\n" + fragmentLines.joined(separator: "\n")
        
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
        
        return CompiledRetroArchShader(
            metalSource: combinedMetal,
            vertexFunctionName: "main0",
            fragmentFunctionName: "main0",
            parameters: stages.parameters,
            samplers: stages.samplers
        )
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
        if let dir = shaderDirectory {
            glslangProcess.arguments?.insert(contentsOf: ["-I", dir.path], at: 1)
        }
        
        let glslangError = Pipe()
        glslangProcess.standardError = glslangError
        glslangProcess.standardOutput = Pipe()
        
        do {
            try glslangProcess.run()
            glslangProcess.waitUntilExit()
        } catch {
            throw RetroArchShaderError.processError("Failed to run glslangValidator: \(error)")
        }
        
        if glslangProcess.terminationStatus != 0 {
            let errorData = glslangError.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw RetroArchShaderError.glslCompilationFailed(errorMessage)
        }
        
        // Step 2: SPIRV -> Metal using spirv-cross
        let spirvCrossProcess = Process()
        spirvCrossProcess.executableURL = URL(fileURLWithPath: spirvCrossPath)
        spirvCrossProcess.arguments = [
            spirvFile.path,
            "--msl",  // Metal Shading Language output
            "--msl-version", "20100",  // Metal 2.1
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
        // Extract unique includes and type definitions from both shaders
        var includes = Set<String>()
        var typeDefinitions: [String] = []
        var vertexMain = ""
        var fragmentMain = ""
        
        // Process vertex shader
        let vertexComponents = parseMetalShader(vertexMetal)
        includes.formUnion(vertexComponents.includes)
        typeDefinitions.append(contentsOf: vertexComponents.types)
        vertexMain = vertexComponents.mainFunction
        
        // Process fragment shader - rename main0 to fragment_main0
        let fragmentComponents = parseMetalShader(fragmentMetal)
        includes.formUnion(fragmentComponents.includes)
        // Add fragment types but avoid duplicates
        for ftype in fragmentComponents.types {
            if !typeDefinitions.contains(where: { $0.contains(ftype.components(separatedBy: " ")[1]) }) {
                typeDefinitions.append(ftype)
            }
        }
        fragmentMain = fragmentComponents.mainFunction
        
        // Build combined shader
        var combined = """
        // Combined RetroArch shader compiled for Metal
        // Auto-generated by ScreenShader
        
        #include <metal_stdlib>
        #include <simd/simd.h>
        
        using namespace metal;
        
        """
        
        // Add type definitions from vertex shader
        combined += "\n// === Vertex Shader Types and Code ===\n"
        combined += vertexMetal
        
        // Add fragment shader with renamed function
        combined += "\n// === Fragment Shader Types and Code ===\n"
        // Rename the fragment main function to avoid conflict
        let renamedFragmentMetal = fragmentMetal
            .replacingOccurrences(of: "vertex main0", with: "fragment fragment_main0")
            .replacingOccurrences(of: "fragment main0", with: "fragment fragment_main0")
        combined += renamedFragmentMetal
        
        return combined
    }
    
    /// Parse a Metal shader to extract includes, types, and main function
    private static func parseMetalShader(_ source: String) -> (includes: [String], types: [String], mainFunction: String) {
        var includes: [String] = []
        var types: [String] = []
        var mainFunction = ""
        
        let lines = source.components(separatedBy: .newlines)
        var inMain = false
        var braceCount = 0
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("#include") {
                includes.append(line)
            } else if trimmed.hasPrefix("struct ") || trimmed.hasPrefix("constant ") {
                types.append(line)
            }
            
            if trimmed.contains("main0(") {
                inMain = true
            }
            
            if inMain {
                mainFunction += line + "\n"
                braceCount += line.filter { $0 == "{" }.count
                braceCount -= line.filter { $0 == "}" }.count
                if braceCount == 0 && mainFunction.contains("{") {
                    inMain = false
                }
            }
        }
        
        return (includes, types, mainFunction)
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
