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

class Config: Codable {
  static let currentVersion = 4
  static let supportedFrameRates = 1...240

  var configVersion: Int = Config.currentVersion
  var shaderPath: String? = nil
  var active: Bool = false
  private var storedTargetFPS: Int = 60
  var targetFPS: Int {
    get { storedTargetFPS }
    set { storedTargetFPS = min(max(newValue, Self.supportedFrameRates.lowerBound), Self.supportedFrameRates.upperBound) }
  }

  private var fileURL: URL?
  private var fileRequiringRecovery: URL?
  private(set) var recoveryBackupURL: URL?

  private enum CodingKeys: String, CodingKey {
    case configVersion, shaderPath, active, targetFPS, shaderParameters
    case enabledDisplayIDs, displaySelectionIsExplicit
  }

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL
  }

  required init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let savedVersion = try values.decodeIfPresent(Int.self, forKey: .configVersion) ?? 1
    guard savedVersion <= Self.currentVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .configVersion, in: values,
        debugDescription: "Configuration was saved by a newer version of ScreenSlanger")
    }

    // New fields must use defaults when loading older configurations. Property
    // initializers alone are not used by synthesized Codable decoding.
    configVersion = Self.currentVersion
    shaderPath = try values.decodeIfPresent(String.self, forKey: .shaderPath)
    active = try values.decodeIfPresent(Bool.self, forKey: .active) ?? false
    targetFPS = try values.decodeIfPresent(Int.self, forKey: .targetFPS) ?? 60
    shaderParameters = try values.decodeIfPresent([String: [String: Float]].self, forKey: .shaderParameters) ?? [:]
    enabledDisplayIDs = try values.decodeIfPresent(Set<UInt32>.self, forKey: .enabledDisplayIDs) ?? []
    displaySelectionIsExplicit = try values.decodeIfPresent(Bool.self, forKey: .displaySelectionIsExplicit)
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(configVersion, forKey: .configVersion)
    try values.encodeIfPresent(shaderPath, forKey: .shaderPath)
    try values.encode(active, forKey: .active)
    try values.encode(targetFPS, forKey: .targetFPS)
    try values.encode(shaderParameters, forKey: .shaderParameters)
    try values.encode(enabledDisplayIDs, forKey: .enabledDisplayIDs)
    try values.encodeIfPresent(displaySelectionIsExplicit, forKey: .displaySelectionIsExplicit)
  }
  
  /// Stored parameter values for RetroArch shaders, keyed by shader path then parameter name
  var shaderParameters: [String: [String: Float]] = [:]
  
  /// Set of display IDs that should have the shader applied (CGDirectDisplayID as UInt32)
  /// Legacy configurations use an empty set to enable all displays by default.
  var enabledDisplayIDs: Set<UInt32> = []
  /// Optional so existing saved configurations retain their original selection behavior.
  /// Once the user selects displays, an empty set means no displays are enabled.
  var displaySelectionIsExplicit: Bool? = nil
  
  /// Returns whether the given display should have the shader applied
  func isDisplayEnabled(_ displayID: CGDirectDisplayID) -> Bool {
    if enabledDisplayIDs.isEmpty && displaySelectionIsExplicit != true {
      return true  // All enabled by default
    }
    return enabledDisplayIDs.contains(UInt32(displayID))
  }
  
  /// Toggle whether a display is enabled
  @MainActor
  func toggleDisplay(_ displayID: CGDirectDisplayID) {
    let availableDisplayIDs = NSScreen.screens.compactMap { screen -> CGDirectDisplayID? in
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
        return nil
      }
      return CGDirectDisplayID(number.uint32Value)
    }
    toggleDisplay(displayID, availableDisplayIDs: availableDisplayIDs)
  }

  func toggleDisplay(_ displayID: CGDirectDisplayID, availableDisplayIDs: [CGDirectDisplayID]) {
    let id = UInt32(displayID)
    if enabledDisplayIDs.isEmpty && displaySelectionIsExplicit != true {
      // Convert the default "all" selection into the current explicit selection.
      enabledDisplayIDs = Set(availableDisplayIDs.map { UInt32($0) })
      enabledDisplayIDs.remove(id)
    } else if enabledDisplayIDs.contains(id) {
      enabledDisplayIDs.remove(id)
    } else {
      enabledDisplayIDs.insert(id)
    }
    displaySelectionIsExplicit = true
  }

  static func getFileURL() -> URL {
    let fileManager = FileManager.default
    let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
    let directory = appSupportDir.appendingPathComponent("ScreenSlanger", isDirectory: true)

    return directory.appendingPathComponent("config.json")
  }

  /// Returns false if the existing configuration could not be preserved or the
  /// replacement could not be written. Callers should keep unsaved changes dirty.
  @discardableResult
  func save(fileURL: URL? = nil) -> Bool {
    do {
      let destination = fileURL ?? self.fileURL ?? Config.getFileURL()
      let encoder = JSONEncoder()
      encoder.outputFormatting = .prettyPrinted
      let data = try encoder.encode(self)
      let fileManager = FileManager.default
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

      if let original = fileRequiringRecovery,
        original.standardizedFileURL == destination.standardizedFileURL {
        // A defaults-based session must not destroy an unreadable or future
        // configuration. Refuse the save if its original bytes cannot be kept.
        let backup = original.deletingPathExtension()
          .appendingPathExtension("recovery-\(UUID().uuidString).json")
        try fileManager.copyItem(at: original, to: backup)
        recoveryBackupURL = backup
        fileRequiringRecovery = nil
        print("Preserved unreadable config at \(backup)")
      }

      // Foundation writes a sibling temporary file and replaces the destination,
      // so interrupted writes cannot leave a partially encoded configuration.
      try data.write(to: destination, options: .atomic)
      print("Saved config to \(destination)")
      return true
    } catch {
      print("Failed to save config: \(error)")
      return false
    }
  }

  static func load(fileURL: URL? = nil) -> Config {
    let fileURL = fileURL ?? getFileURL()
    var config: Config
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      print("No config file found at \(fileURL)")
      config = Config(fileURL: fileURL)
    } else {
      do {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        config = try decoder.decode(Config.self, from: data)
        config.fileURL = fileURL
        print("Loaded config from \(fileURL)")
      } catch {
        print("Failed to load config; the original will be preserved before saving: \(error)")
        config = Config(fileURL: fileURL)
        config.fileRequiringRecovery = fileURL
      }
    }

    return config
  }
  
  func hasShaderPath() -> Bool {
    if let path = shaderPath {
      return !path.isEmpty
    }
    return false
  }
  
  func getShader() -> String? {
    guard let path = shaderPath, !path.isEmpty else {
      return nil
    }
    do {
      return try String(contentsOfFile: path, encoding: .utf8)
    } catch {
      print("Failed to read shader from file: \(error)")
      return nil
    }
  }
  
  func toggleActive() {
    if hasShaderPath() {
      active = !active
    } else {
      active = false
    }
  }
  
  // MARK: - Shader Parameter Management
  
  /// Get stored parameter value for current shader
  func getParameterValue(name: String) -> Float? {
    guard let path = shaderPath else { return nil }
    return shaderParameters[path]?[name]
  }
  
  /// Set parameter value for current shader
  func setParameterValue(name: String, value: Float) {
    guard let path = shaderPath else { return }
    if shaderParameters[path] == nil {
      shaderParameters[path] = [:]
    }
    shaderParameters[path]?[name] = value
  }
  
  /// Get all stored parameter values for current shader
  func getParameterValues() -> [String: Float] {
    guard let path = shaderPath else { return [:] }
    return shaderParameters[path] ?? [:]
  }
  
  /// Apply stored values to a parameter state
  @MainActor
  func applyStoredParameters(to state: ShaderParameterState) {
    let stored = getParameterValues()
    for (name, value) in stored {
      state.setValue(value, for: name)
    }
  }
  
  /// Save current parameter state to config
  @MainActor
  func saveParameters(from state: ShaderParameterState) {
    for param in state.parameters {
      setParameterValue(name: param.name, value: state.getValue(for: param.name))
    }
  }
}
