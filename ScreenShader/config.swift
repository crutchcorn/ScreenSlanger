import AppKit

let defaultShaderSource: String = """
  /**************************************************************

  These are the inputs provided to the shader (Slang version):

  struct ShaderInput {
    // The texture coordinates for indexing into the input at the current
    // position. The origin is at the top left of the screen.
    float2 texCoord;
    // The current position in pixels, with (0,0) at the bottom left of the
    // screen.
    float2 screenPosition;
    // The screen size in pixels.
    float2 screenSize;
    // The current position of the mouse cursor in pixels, with (0,0) at
    // the bottom left of the screen.
    float2 mousePosition;
    // The elapsed time since the system started in seconds.
    float time;
  };

  Available functions:
    float4 sampleInput(float2 texCoord) - Sample the input screen texture
    float2 texToScreen(float2 texCoord, float2 screenSize)
    float2 screenToTex(float2 screenPosition, float2 screenSize)

  **************************************************************/

  // Don't change the name or signature of this function:
  float4 shaderFunction(ShaderInput input) {
    float4 inputColor = sampleInput(input.texCoord);

    float4 resultColor = float4(
      inputColor.r,
      inputColor.g,
      inputColor.b,
      inputColor.a
    );

    return resultColor;
  }
  """

let predefinedShaders: [(String, String)] = [
  (
    "Swap red-blue channels",
    """
    float4 shaderFunction(ShaderInput input) {
      float4 inputColor = sampleInput(input.texCoord);
      return float4(inputColor.b, inputColor.g, inputColor.r, inputColor.a);
    }
    """
  ),
  (
    "Grey scale",
    """
    float4 shaderFunction(ShaderInput input) {
      float4 inputColor = sampleInput(input.texCoord);
      float grey = dot(inputColor.rgb, float3(0.299, 0.587, 0.114));
      return float4(grey, grey, grey, inputColor.a);
    }
    """
  ),
  (
    "Color Invert",
    """
    float4 shaderFunction(ShaderInput input) {
      float4 inputColor = sampleInput(input.texCoord);
      return float4(1.0 - inputColor.rgb, inputColor.a);
    }
    """
  ),
  (
    "Sepia Tone",
    """
    float4 shaderFunction(ShaderInput input) {
      float4 inputColor = sampleInput(input.texCoord);
      
      float3 sepia;
      sepia.r = dot(inputColor.rgb, float3(0.393, 0.769, 0.189));
      sepia.g = dot(inputColor.rgb, float3(0.349, 0.686, 0.168));
      sepia.b = dot(inputColor.rgb, float3(0.272, 0.534, 0.131));
      
      return float4(sepia, inputColor.a);
    }
    """
  ),
  (
    "Vignette",
    """
    float4 shaderFunction(ShaderInput input) {
      float4 inputColor = sampleInput(input.texCoord);
      
      // Calculate distance from center
      float2 center = float2(0.5, 0.5);
      float dist = distance(input.texCoord, center);
      
      // Create vignette effect
      float vignette = 1.0 - smoothstep(0.3, 0.8, dist);
      
      return float4(inputColor.rgb * vignette, inputColor.a);
    }
    """
  ),
]

class Config: Codable {
  var configVersion: Int = 1
  var effects: Effects = Effects()
  var targetFPS: Int = 60

  static func getFileURL() -> URL {
    let fileManager = FileManager.default
    let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
    let directory = appSupportDir.appendingPathComponent("ScreenShader", isDirectory: true)

    if !fileManager.fileExists(atPath: directory.path) {
      try? fileManager.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: nil)
    }

    return directory.appendingPathComponent("config.json")
  }

  func save() {
    do {
      let fileURL = Config.getFileURL()
      let encoder = JSONEncoder()
      encoder.outputFormatting = .prettyPrinted
      let data = try encoder.encode(self)
      try data.write(to: fileURL)
      print("Saved config to \(fileURL)")
    } catch {
      print("Failed to save config: \(error)")
    }
  }

  static func load() -> Config {
    let fileURL = getFileURL()
    var config: Config
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      print("No config file found at \(fileURL)")
      config = Config()
    } else {
      do {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        config = try decoder.decode(Config.self, from: data)
        print("Loaded config from \(fileURL)")
      } catch {
        fatalError("Failed to load config: \(error)")
      }
    }

    if config.effects.effectList().isEmpty {
      // Create a default empty effect for the user to configure with a shader file
      let _ = config.effects.new()
    }

    return config
  }
}

class Effects: Codable {
  private var nextEffectNumber: Int = 1
  private var effects: [UUID] = []
  private var deletedEffects: [UUID] = []
  private var effectToName: [UUID: String] = [:]
  private var effectToShader: [UUID: String] = [:]
  private var effectToShaderPath: [UUID: String] = [:]
  private var effectToActive: [UUID: Bool] = [:]
  private var mostRecentActiveEffect: UUID? = nil
  
  // Custom CodingKeys to handle optional effectToShaderPath
  private enum CodingKeys: String, CodingKey {
    case nextEffectNumber
    case effects
    case deletedEffects
    case effectToName
    case effectToShader
    case effectToShaderPath
    case effectToActive
    case mostRecentActiveEffect
  }
  
  // Default initializer
  init() {}
  
  // Custom decoder to handle missing effectToLanguage in old config files
  required init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    nextEffectNumber = try container.decode(Int.self, forKey: .nextEffectNumber)
    effects = try container.decode([UUID].self, forKey: .effects)
    deletedEffects = try container.decode([UUID].self, forKey: .deletedEffects)
    effectToName = try container.decode([UUID: String].self, forKey: .effectToName)
    effectToShader = try container.decode([UUID: String].self, forKey: .effectToShader)
    effectToShaderPath = try container.decodeIfPresent([UUID: String].self, forKey: .effectToShaderPath) ?? [:]
    effectToActive = try container.decode([UUID: Bool].self, forKey: .effectToActive)
    mostRecentActiveEffect = try container.decodeIfPresent(UUID.self, forKey: .mostRecentActiveEffect)
  }

  func effectList() -> [UUID] {
    return self.effects
  }

  func new() -> UUID {
    let newEffectID = UUID()
    let newEffectName = "Effect \(self.nextEffectNumber)"
    self.nextEffectNumber += 1

    self.effects.append(newEffectID)
    self.effectToName[newEffectID] = newEffectName
    self.effectToShader[newEffectID] = ""  // Empty - will be loaded from file
    self.effectToActive[newEffectID] = false

    return newEffectID
  }

  func delete(effect: UUID) {
    if let index = self.effects.firstIndex(of: effect) {
      self.effects.remove(at: index)
      self.deletedEffects.append(effect)
      if self.mostRecentActiveEffect == effect {
        self.mostRecentActiveEffect = nil
      }
    }
  }

  func getName(effect: UUID) -> String {
    return self.effectToName[effect]!
  }

  func setName(effect: UUID, newName: String) {
    self.effectToName[effect] = newName
  }

  func isActive(effect: UUID) -> Bool {
    return self.effectToActive[effect]!
  }

  func setActive(effect: UUID, active: Bool) {
    if active {
      for otherEffect in self.effects {
        self.effectToActive[otherEffect] = false
      }
      self.mostRecentActiveEffect = effect
    }
    self.effectToActive[effect] = active
  }

  func toggleActive(effect: UUID) {
    let active = self.isActive(effect: effect)
    self.setActive(effect: effect, active: !active)
  }

  func getShader(effect: UUID) -> String {
    // If a shader path is set, read from file
    if let path = effectToShaderPath[effect], !path.isEmpty {
      do {
        let shaderSource = try String(contentsOfFile: path, encoding: .utf8)
        return shaderSource
      } catch {
        print("Failed to read shader from file: \(error)")
        // Fall back to cached shader if file read fails
        return self.effectToShader[effect] ?? ""
      }
    }
    return self.effectToShader[effect] ?? ""
  }

  func setShader(effect: UUID, shader: String) {
    self.effectToShader[effect] = shader
  }

  func getShaderPath(effect: UUID) -> String? {
    return self.effectToShaderPath[effect]
  }

  func setShaderPath(effect: UUID, path: String?) {
    if let path = path, !path.isEmpty {
      self.effectToShaderPath[effect] = path
    } else {
      self.effectToShaderPath.removeValue(forKey: effect)
    }
  }

  func hasShaderPath(effect: UUID) -> Bool {
    if let path = effectToShaderPath[effect] {
      return !path.isEmpty
    }
    return false
  }

  func getActiveEffect() -> UUID? {
    for effect in self.effects {
      if self.isActive(effect: effect) {
        return effect
      }
    }
    return nil
  }

  func getMostRecentActiveEffect() -> UUID? {
    return self.mostRecentActiveEffect
  }

  func anyEffectActive() -> Bool {
    return self.getActiveEffect() != nil
  }

  func deactivateAll() {
    for effect in self.effects {
      self.setActive(effect: effect, active: false)
    }
  }

  func activateDefault() {
    if let mostRecentActiveEffect = self.mostRecentActiveEffect {
      self.setActive(effect: mostRecentActiveEffect, active: true)
    } else if self.effects.count > 0 {
      self.setActive(effect: self.effects.first!, active: true)
    }
  }
}
