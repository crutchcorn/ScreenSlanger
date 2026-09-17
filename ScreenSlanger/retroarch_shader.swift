import Foundation

/// Both shader languages use .slang; RetroArch marks GLSL stages explicitly.
/// Parsing, reflection, presets, and resource binding belong to librashader.
enum ShaderFormat {
  static func isRetroArch(_ source: String) -> Bool {
    source.range(of: #"(?m)^\s*#\s*(?:pragma\s+stage\b|version\s+\d+)"#,
                 options: .regularExpression) != nil
  }
}
