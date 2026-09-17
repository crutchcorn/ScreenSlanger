#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_directory="$(mktemp -d "${TMPDIR:-/tmp}/screenslanger-shaders.XXXXXX")"
trap 'rm -rf "$build_directory"' EXIT

# Compile the application's actual shader adapters and pipeline builders.
# A temporary module cache keeps this check independent of Xcode build products.
xcrun --sdk macosx swiftc \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -module-cache-path "$build_directory/ModuleCache" \
    -parse-as-library \
    "$project_dir/ScreenSlanger/slang_compiler.swift" \
    "$project_dir/ScreenSlanger/retroarch_shader.swift" \
    "$project_dir/ScreenSlanger/renderer.swift" \
    "$project_dir/Tests/ShaderSmoke.swift" \
    -o "$build_directory/check-shaders"

"$build_directory/check-shaders" "$project_dir"
