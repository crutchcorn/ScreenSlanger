# Contributing to ScreenSlanger

Build with Xcode 27 and Swift 6 language mode. Run `scripts/setup-dependencies.sh` once to install the pinned native runtimes, then open `ScreenSlanger.xcodeproj`. Use the ScreenSlanger scheme and My Mac destination. Run tests with Product → Test (⌘U), or:

```sh
xcodebuild test -project ScreenSlanger.xcodeproj -scheme ScreenSlanger -destination 'platform=macOS'
```

The tests require Metal GPU access. They run without launching the app or changing saved settings. Keep compatibility fixtures small and deterministic, and exercise the production render path when adding a shader regression test.

## Vendored CLibrashader provenance

`Vendor/CLibrashader` is the C interface for [SnowflakePowered/librashader](https://github.com/SnowflakePowered/librashader), a RetroArch shader preset parser, compiler, and rendering runtime. It is not a new shader implementation written for ScreenSlanger.

The version is pinned to **0.12.0**, upstream tag [`librashader-v0.12.0`](https://github.com/SnowflakePowered/librashader/tree/librashader-v0.12.0). The original files were fetched from upstream during the ScreenSlanger Metal backend integration:

| Local file | Origin |
| --- | --- |
| `Vendor/CLibrashader/librashader.h` | Unmodified `librashader.h` extracted from the official [`librashader-aarch64-macos-v0.12.0-optimized.zip`](https://github.com/SnowflakePowered/librashader/releases/download/librashader-v0.12.0/librashader-aarch64-macos-v0.12.0-optimized.zip) release asset. The MIT copyright and permission notice remain in the header. |
| `Vendor/CLibrashader/LICENSE-MPL-2.0.md` | Unmodified [`LICENSE.md`](https://github.com/SnowflakePowered/librashader/blob/librashader-v0.12.0/LICENSE.md) from the pinned upstream tag. It covers the runtime implementation, not the MIT C header. |
| `Vendor/CLibrashader/shim.h` | Written for ScreenSlanger. Enables `LIBRA_RUNTIME_METAL` before importing the official header. |
| `Vendor/CLibrashader/module.modulemap` | Written for ScreenSlanger. Exposes the header as the `CLibrashader` Clang module for Swift. |
| `Vendor/CLibrashader/NOTICE.md` | Written for ScreenSlanger. Records licensing, corresponding-source links, and integration constraints. |

The dynamic library is **not committed to the repository**. The setup script downloads the official macOS release archive, verifies its SHA-256 digest, and installs its unmodified `librashader.dylib` into `~/Library/Application Support/ScreenSlanger/Tools/librashader/0.12.0/`. The script installs the license and source notice alongside it. The app build copies the library into `Contents/Frameworks/`, gives it a relocatable install name, and signs it with the app's build identity. `LIBRASHADER_PATH` can override the runtime for unhosted tests and probes; applications always load the embedded runtime.

The pinned archive checksums are from the upstream [GitHub release asset metadata](https://api.github.com/repos/SnowflakePowered/librashader/releases/tags/librashader-v0.12.0):

| Architecture | SHA-256 |
| --- | --- |
| Apple Silicon (`aarch64`) | `49808004a4904f6a99e0231092dcfdfe52b7b61f68430a4c9f1e165749c4c90e` |
| Intel (`x86_64`) | `8b2a50cefacf4073e8fa4757bec30242a788068c4096a580d94430688c184767` |

The extracted, unmodified `librashader.h` has SHA-256 `5d478897c391af3f60015810b67785ae1a286d262a845485276e36ded9f21e62`.

The corresponding runtime source is available as the [pinned source archive](https://github.com/SnowflakePowered/librashader/archive/refs/tags/librashader-v0.12.0.tar.gz). If shipping the binary inside an app, include its MPL-2.0 license and source notice. The vendored C header keeps its own MIT notice.

## Updating librashader

1. Select an official stable release with both supported macOS assets. Record the tag, asset URLs, and published SHA-256 digests in the setup script and this document.
2. Download and verify the archive before extracting its C header. Replace the header without editing upstream declarations; retain its copyright and license. Refresh the upstream license and source notice if needed.
3. Update the pinned runtime path in `ScreenSlanger/librashader.swift`, the installer, the bundling script and input/output file lists, and the README together. The output list must enumerate every packaged file and directory. Compare C ABI/API versions, struct layouts, ownership rules, and the Metal runtime's thread-safety requirements. Do not guess Swift declarations for C structs or function pointers.
4. Install the new runtime and run the full native test suite, including known-pixel output, multipass presets, reflected parameter layouts, texture filtering, custom vertices, includes, failures, and reloads. Verify app activation, animated effects on a static desktop, parameter editing, display changes, and deactivation on a Metal-capable Mac.
5. Commit the header, adapter changes, checksums, documentation, and regression fixtures together. Do not add downloaded native binaries or generated caches to Git.

`ScreenSlanger/librashader.swift` keeps each filter chain on a dedicated OS thread, including creation and destruction. This respects upstream's non-thread-safe Metal runtime. Its shared GPU uniform storage also requires only one outstanding frame per chain. A busy chain drops a render attempt rather than overwriting in-use buffers. Each display owns a separate chain so feedback and history textures remain independent.

The native shader-slang compiler is a separate backend and dependency. Its pinned release and checksums are also in `scripts/setup-dependencies.sh`; updating librashader does not update shader-slang.

## Self-contained application builds

The application target's **Bundle Shader Runtimes** phase runs `scripts/bundle-shader-runtimes.sh` as part of normal Debug, Release, and Archive builds. Input/output `.xcfilelist` files declare its dependency paths and every packaged file and directory. User-script sandboxing stays enabled: modifications and signing use the build's temporary directory, followed by copies directly to the declared outputs. The build never downloads tools: run setup first, and a missing runtime fails the build with instructions. Clean the build products when changing dependency versions so files removed by an upstream release cannot remain in an old bundle.

The app layout is:

```text
ScreenSlanger.app/Contents/
  Helpers/Slang.app/Contents/MacOS/slangc
  Helpers/Slang.app/Contents/lib/                 # Compiler libraries, plugins, and standard modules
  Frameworks/librashader.dylib
  Resources/ThirdParty/Slang/        # Upstream LICENSE, LICENSES, and source notice
  Resources/ThirdParty/librashader/  # MPL-2.0 license and corresponding-source notice
```

Slang is wrapped in a helper `.app` so code signing distinguishes its standard-library data from nested executables. Its executable/`../lib` relationship is preserved so its relative rpaths and runtime plugin lookup remain valid after moving the app. Packaging removes upstream CI-machine absolute rpaths, verifies architecture slices, and signs each nested binary and the helper bundle before Xcode signs the app. Both runtimes use the build's signing identity; local unsigned builds use ad-hoc nested signatures. Developer ID signing requests Apple's secure timestamp; development and ad-hoc signing do not require the timestamp service. Distributing through ordinary macOS download channels still requires your normal Developer ID signing and notarization workflow.

For a packaging regression check, move a built `.app` to a temporary directory outside DerivedData, verify it with `codesign --verify --deep --strict`, and load both a native Slang shader and a RetroArch preset from that copy. Confirm the compiler and loaded librashader paths stay inside the moved app even if `SLANG_PATH` and `LIBRASHADER_PATH` point to nonexistent files. Run the packaged compiler's `-version` and inspect its `otool -L`/`LC_RPATH` output. Recipients should never need the per-user setup installation.

Standalone shaders can be shared with the app. Shader folders containing includes, modules, LUT textures, or referenced presets must keep those files and relative paths together.
