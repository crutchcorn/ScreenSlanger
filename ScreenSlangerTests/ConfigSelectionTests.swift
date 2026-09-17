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
