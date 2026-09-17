import Foundation
import Testing

@Suite("Display selection")
@MainActor
struct ConfigSelectionTests {
  @Test("New configurations enable every display")
  func defaultsEnableEveryDisplay() {
    let config = Config()

    #expect(config.isDisplayEnabled(1))
    #expect(config.isDisplayEnabled(2))
    #expect(config.animateWhenIdle)
  }

  @Test("Legacy default selections preserve all displays and unrelated preferences")
  func legacyDefaultsSurviveRoundTrip() throws {
    let config = try legacyConfig(displayIDs: [])

    #expect(config.isDisplayEnabled(1))
    #expect(config.isDisplayEnabled(2))

    let reloaded = try roundTrip(config)
    #expect(reloaded.isDisplayEnabled(3))
    #expect(reloaded.shaderPath == "/tmp/example.slangp")
    #expect(reloaded.active)
    #expect(reloaded.targetFPS == 120)
    let gain = try #require(reloaded.getParameterValue(name: "GAIN"))
    #expect(gain == 0.75)
  }

  @Test("Legacy nonempty selections retain their saved displays")
  func legacySelectionsSurviveRoundTrip() throws {
    let config = try legacyConfig(displayIDs: [1])

    #expect(config.isDisplayEnabled(1))
    #expect(!config.isDisplayEnabled(2))

    let reloaded = try roundTrip(config)
    #expect(reloaded.isDisplayEnabled(1))
    #expect(!reloaded.isDisplayEnabled(2))
  }

  @Test("The only display can be disabled, persisted, and re-enabled")
  func onlyDisplayCanBeDisabledAndReEnabled() throws {
    let config = Config()
    config.toggleDisplay(1, availableDisplayIDs: [1])

    #expect(!config.isDisplayEnabled(1))
    #expect(!config.isDisplayEnabled(2))

    let reloaded = try roundTrip(config)
    #expect(!reloaded.isDisplayEnabled(1))
    #expect(!reloaded.isDisplayEnabled(2))

    reloaded.toggleDisplay(1, availableDisplayIDs: [1])
    #expect(reloaded.isDisplayEnabled(1))
    #expect(!reloaded.isDisplayEnabled(2))
  }

  @Test("Clearing the last legacy-selected display persists an empty selection")
  func lastLegacyDisplayCanBeDisabled() throws {
    let config = try legacyConfig(displayIDs: [1])
    config.toggleDisplay(1, availableDisplayIDs: [1, 2])

    #expect(!config.isDisplayEnabled(1))
    #expect(!config.isDisplayEnabled(2))

    let reloaded = try roundTrip(config)
    #expect(!reloaded.isDisplayEnabled(1))
    #expect(!reloaded.isDisplayEnabled(2))
  }

  @Test("Multiple displays toggle independently through an empty selection")
  func multipleDisplaysToggleIndependently() throws {
    let config = try legacyConfig(displayIDs: [])
    config.toggleDisplay(1, availableDisplayIDs: [1, 2])

    #expect(!config.isDisplayEnabled(1))
    #expect(config.isDisplayEnabled(2))

    config.toggleDisplay(2, availableDisplayIDs: [1, 2])
    #expect(!config.isDisplayEnabled(1))
    #expect(!config.isDisplayEnabled(2))

    config.toggleDisplay(1, availableDisplayIDs: [1, 2])
    #expect(config.isDisplayEnabled(1))
    #expect(!config.isDisplayEnabled(2))
  }

  @Test("Older configurations fill missing preferences with defaults")
  func missingLegacyKeysReceiveDefaults() throws {
    let data = Data(#"{"shaderPath":"/tmp/legacy.slang","active":true}"#.utf8)
    let config = try JSONDecoder().decode(Config.self, from: data)

    #expect(config.configVersion == Config.currentVersion)
    #expect(config.shaderPath == "/tmp/legacy.slang")
    #expect(config.active)
    #expect(config.targetFPS == 60)
    #expect(config.animateWhenIdle)
    #expect(config.shaderParameters.isEmpty)
    #expect(config.isDisplayEnabled(1))
    #expect(config.displaySelectionIsExplicit == nil)
  }

  @Test("Frame rates are bounded on decoding and assignment", arguments: [Int.min, -1, 0, 1, 60, 240, 241, Int.max])
  func frameRatesAreValidated(requested: Int) throws {
    let data = try JSONSerialization.data(withJSONObject: ["targetFPS": requested])
    let decoded = try JSONDecoder().decode(Config.self, from: data)
    let expected = min(max(requested, 1), 240)
    #expect(decoded.targetFPS == expected)

    let assigned = Config()
    assigned.targetFPS = requested
    #expect(assigned.targetFPS == expected)
  }

  @Test("Saving and reloading uses the injected URL and persists preferences")
  func filePersistenceRoundTrip() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("nested/config.json")
    let config = Config(fileURL: fileURL)
    config.shaderPath = "/tmp/example.slangp"
    config.active = true
    config.targetFPS = 120
    config.animateWhenIdle = false
    config.setParameterValue(name: "GAIN", value: 0.75)
    config.toggleDisplay(1, availableDisplayIDs: [1])

    #expect(config.save())
    let loaded = Config.load(fileURL: fileURL)
    #expect(loaded.shaderPath == config.shaderPath)
    #expect(loaded.active)
    #expect(loaded.targetFPS == 120)
    #expect(!loaded.animateWhenIdle)
    #expect(loaded.getParameterValue(name: "GAIN") == 0.75)
    #expect(!loaded.isDisplayEnabled(1))

    loaded.active = false
    loaded.animateWhenIdle = true
    #expect(loaded.save())
    let reloaded = Config.load(fileURL: fileURL)
    #expect(!reloaded.active)
    #expect(reloaded.animateWhenIdle)
  }

  @Test("A missing file loads defaults without creating directories")
  func loadingMissingFileDoesNotWrite() {
    let directory = temporaryDirectory()
    let loaded = Config.load(fileURL: directory.appendingPathComponent("config.json"))

    #expect(loaded.targetFPS == 60)
    #expect(loaded.animateWhenIdle)
    #expect(!loaded.active)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
  }

  @Test("An encoding failure preserves the last saved configuration")
  func failedSavePreservesPreviousBytes() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("config.json")
    let config = Config(fileURL: fileURL)
    config.shaderPath = "/tmp/example.slangp"
    #expect(config.save())
    let original = try Data(contentsOf: fileURL)

    config.setParameterValue(name: "GAIN", value: .nan)
    #expect(!config.save())
    #expect(try Data(contentsOf: fileURL) == original)
  }

  @Test("An unreadable configuration is preserved before defaults replace it")
  func malformedFileReceivesRecoveryCopy() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("config.json")
    let original = Data(#"{"shaderPath": "incomplete""#.utf8)
    try original.write(to: fileURL)

    let loaded = Config.load(fileURL: fileURL)
    #expect(!loaded.active)
    #expect(try Data(contentsOf: fileURL) == original)
    #expect(loaded.save())
    let backup = try #require(loaded.recoveryBackupURL)
    #expect(try Data(contentsOf: backup) == original)
    #expect(try JSONDecoder().decode(Config.self, from: Data(contentsOf: fileURL)).targetFPS == 60)

    #expect(loaded.save())
    #expect(loaded.recoveryBackupURL == backup)
  }

  @Test("Saving reports filesystem failures")
  func savingToInvalidDirectoryFails() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let parentFile = directory.appendingPathComponent("regular-file")
    try Data("keep me".utf8).write(to: parentFile)
    let config = Config(fileURL: parentFile.appendingPathComponent("config.json"))

    #expect(!config.save())
    #expect(try String(contentsOf: parentFile, encoding: .utf8) == "keep me")
  }

  @Test("A newer configuration is not interpreted with older defaults")
  func futureConfigurationIsRejected() throws {
    let data = try JSONSerialization.data(withJSONObject: ["configVersion": Config.currentVersion + 1])
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(Config.self, from: data)
    }
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ScreenSlangerConfigTests-\(UUID().uuidString)", isDirectory: true)
  }

  private func legacyConfig(displayIDs: [UInt32]) throws -> Config {
    // Match the version 4 format, before displaySelectionIsExplicit existed.
    let data = try JSONSerialization.data(withJSONObject: [
      "configVersion": 4,
      "shaderPath": "/tmp/example.slangp",
      "active": true,
      "targetFPS": 120,
      "shaderParameters": ["/tmp/example.slangp": ["GAIN": 0.75]],
      "enabledDisplayIDs": displayIDs
    ])
    return try JSONDecoder().decode(Config.self, from: data)
  }

  private func roundTrip(_ config: Config) throws -> Config {
    // Exercise persistence entirely in memory, without touching saved user settings.
    try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
  }
}
