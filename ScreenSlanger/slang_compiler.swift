import Foundation

/// Errors that can occur during Slang shader compilation
enum SlangCompilerError: Error, LocalizedError {
    case slangcNotFound
    case compilationFailed(String)
    case invalidOutput
    case processError(String)
    
    var errorDescription: String? {
        switch self {
        case .slangcNotFound:
            return "slangc compiler not found. Please install Slang or set SLANG_PATH environment variable."
        case .compilationFailed(let message):
            return "Slang compilation failed: \(message)"
        case .invalidOutput:
            return "Slang compiler produced invalid output"
        case .processError(let message):
            return "Process error: \(message)"
        }
    }
}

/// Represents a shader parameter parsed from #pragma parameter directives
/// Format: #pragma parameter NAME "Description" default min max step
struct ShaderParameter {
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
        var scanner = Scanner(string: content)
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
struct PreprocessedShader {
    let source: String
    let parameters: [ShaderParameter]
    let isRetroArchStyle: Bool
}

/// Wrapper for the Slang shader compiler
class SlangCompiler {
    
    /// Possible locations to search for slangc
    private static let slangcSearchPaths = [
        // Environment variable override
        ProcessInfo.processInfo.environment["SLANG_PATH"],
        // Homebrew installation
        "/opt/homebrew/bin/slangc",
        "/usr/local/bin/slangc",
        // App bundle resources
        Bundle.main.path(forResource: "slangc", ofType: nil),
        // Development paths
        "/usr/local/slang/bin/slangc",
        // User home directory
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".slang/bin/slangc").path,
        // Common Slang download locations
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("slang/bin/slangc").path
    ].compactMap { $0 }
    
    /// Find the slangc executable
    static func findSlangc() -> String? {
        for path in slangcSearchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
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
        stage: String = "fragment"
    ) throws -> String {
        guard let slangcPath = findSlangc() else {
            throw SlangCompilerError.slangcNotFound
        }
        
        // Create a temporary directory for compilation
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // Write the Slang source to a temporary file
        let inputFile = tempDir.appendingPathComponent("shader.slang")
        let outputFile = tempDir.appendingPathComponent("shader.metal")
        
        try slangSource.write(to: inputFile, atomically: true, encoding: .utf8)
        
        // Build the slangc command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: slangcPath)
        process.arguments = [
            inputFile.path,
            "-target", "metal",
            "-entry", entryPoint,
            "-stage", stage,
            "-o", outputFile.path
        ]
        
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe() // Capture stdout too
        
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw SlangCompilerError.processError(error.localizedDescription)
        }
        
        // Check for compilation errors
        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw SlangCompilerError.compilationFailed(errorMessage)
        }
        
        // Read the generated Metal source
        guard let metalSource = try? String(contentsOf: outputFile, encoding: .utf8) else {
            throw SlangCompilerError.invalidOutput
        }
        
        return metalSource
    }
    
    /// Wrap user-provided Slang effect code with the ScreenSlanger framework code
    /// This creates a complete Slang shader that matches ScreenSlanger's expectations
    static func wrapEffectSource(_ effectSource: String) -> String {
        return """
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
        \(effectSource)
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
