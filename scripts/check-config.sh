#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_directory="$(mktemp -d "${TMPDIR:-/tmp}/screenslanger-config.XXXXXX")"
trap 'rm -rf "$build_directory"' EXIT

# Compile the real configuration and its shader-state dependencies. The checks
# only use in-memory JSON and supplied display IDs; saved user settings are untouched.
xcrun --sdk macosx swiftc \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -module-cache-path "$build_directory/ModuleCache" \
    -parse-as-library \
    "$project_dir/ScreenSlanger/config.swift" \
    "$project_dir/ScreenSlanger/slang_compiler.swift" \
    "$project_dir/ScreenSlanger/retroarch_shader.swift" \
    "$project_dir/ScreenSlanger/renderer.swift" \
    "$project_dir/Tests/ConfigSelection.swift" \
    -o "$build_directory/check-config"

"$build_directory/check-config"
