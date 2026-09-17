import Foundation

private struct SelectionFailure: Error, LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw SelectionFailure(message: message) }
}

@main
struct ConfigSelection {
  static func main() {
    do {
      try run()
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }

  private static func legacyConfig(displayIDs: [UInt32]) throws -> Config {
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

  private static func roundTrip(_ config: Config) throws -> Config {
    try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
  }

  private static func run() throws {
    let defaults = Config()
    try require(defaults.isDisplayEnabled(1) && defaults.isDisplayEnabled(2),
                "A new configuration should enable every display")

    let legacyAll = try legacyConfig(displayIDs: [])
    try require(legacyAll.isDisplayEnabled(1) && legacyAll.isDisplayEnabled(2),
                "A legacy empty selection should still enable every display")
    let legacyAllReloaded = try roundTrip(legacyAll)
    try require(legacyAllReloaded.isDisplayEnabled(3),
                "Saving an untouched legacy default should still enable future displays")
    try require(legacyAllReloaded.shaderPath == "/tmp/example.slangp"
                && legacyAllReloaded.active && legacyAllReloaded.targetFPS == 120
                && legacyAllReloaded.getParameterValue(name: "GAIN") == 0.75,
                "Reading and writing a legacy configuration changed unrelated preferences")
    print("PASS: new and legacy default selections enable all displays without changing preferences")

    let legacySelected = try legacyConfig(displayIDs: [1])
    try require(legacySelected.isDisplayEnabled(1) && !legacySelected.isDisplayEnabled(2),
                "A legacy nonempty selection should remain restricted to its saved displays")
    let legacySelectedReloaded = try roundTrip(legacySelected)
    try require(legacySelectedReloaded.isDisplayEnabled(1) && !legacySelectedReloaded.isDisplayEnabled(2),
                "Saving a legacy explicit selection changed its enabled displays")
    print("PASS: legacy nonempty selections retain their saved displays")

    defaults.toggleDisplay(1, availableDisplayIDs: [1])
    try require(!defaults.isDisplayEnabled(1) && !defaults.isDisplayEnabled(2),
                "Disabling the only display should leave every display disabled")
    let disabledReloaded = try roundTrip(defaults)
    try require(!disabledReloaded.isDisplayEnabled(1) && !disabledReloaded.isDisplayEnabled(2),
                "An explicit empty selection should survive saving and reloading")
    disabledReloaded.toggleDisplay(1, availableDisplayIDs: [1])
    try require(disabledReloaded.isDisplayEnabled(1) && !disabledReloaded.isDisplayEnabled(2),
                "Re-enabling one display should not enable every display")
    print("PASS: the only display can be disabled, persisted, and re-enabled")

    legacySelected.toggleDisplay(1, availableDisplayIDs: [1, 2])
    try require(!legacySelected.isDisplayEnabled(1) && !legacySelected.isDisplayEnabled(2),
                "Removing the last legacy-selected display should not restore all displays")
    let legacyDisabledReloaded = try roundTrip(legacySelected)
    try require(!legacyDisabledReloaded.isDisplayEnabled(1) && !legacyDisabledReloaded.isDisplayEnabled(2),
                "A legacy selection explicitly cleared by the user should remain empty on reload")
    print("PASS: clearing the last legacy-selected display persists an empty selection")

    legacyAll.toggleDisplay(1, availableDisplayIDs: [1, 2])
    try require(!legacyAll.isDisplayEnabled(1) && legacyAll.isDisplayEnabled(2),
                "Disabling one of two default displays should leave the other enabled")
    legacyAll.toggleDisplay(2, availableDisplayIDs: [1, 2])
    try require(!legacyAll.isDisplayEnabled(1) && !legacyAll.isDisplayEnabled(2),
                "Disabling the second display should leave both disabled")
    legacyAll.toggleDisplay(1, availableDisplayIDs: [1, 2])
    try require(legacyAll.isDisplayEnabled(1) && !legacyAll.isDisplayEnabled(2),
                "Re-enabling one of two displays should leave the other disabled")
    print("PASS: multiple displays toggle independently through an empty selection")
    print("All configuration selection checks passed.")
  }
}
