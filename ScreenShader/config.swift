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
  var configVersion: Int = 2
  var shaderPath: String? = nil
  var active: Bool = false
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
        print("Failed to load config, creating new: \(error)")
        config = Config()
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
}
