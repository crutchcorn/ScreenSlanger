# Contributing to ScreenSlanger

Build with Xcode 27 and Swift 6 language mode. Install [rustup](https://rustup.rs/) and the pinned build compiler with `rustup toolchain install 1.93.0 --profile minimal`. Run `scripts/setup-dependencies.sh` once to install the pinned native runtimes, then open `ScreenSlanger.xcodeproj`. Rust is used only during setup to compile librashader; normal Xcode builds and app recipients do not need it. Use the ScreenSlanger scheme and My Mac destination. Run tests with Product → Test (⌘U), or:

```sh
xcodebuild test -project ScreenSlanger.xcodeproj -scheme ScreenSlanger -destination 'platform=macOS'
```

The tests require Metal GPU access. They run without launching the app or changing saved settings. Keep compatibility fixtures small and deterministic, and exercise the production render path when adding a shader regression test.

## Vendored CLibrashader provenance

`Vendor/CLibrashader` is the C interface for [SnowflakePowered/librashader](https://github.com/SnowflakePowered/librashader), a RetroArch shader preset parser, compiler, and rendering runtime. It is not a new shader implementation written for ScreenSlanger.

The upstream version is pinned to **0.12.0**, tag [`librashader-v0.12.0`](https://github.com/SnowflakePowered/librashader/tree/librashader-v0.12.0). The runtime build is **0.12.0-screenslanger.3**, with the local source patches described below. The header remains the original upstream header fetched during the ScreenSlanger Metal backend integration:

| Local file | Origin |
| --- | --- |
| `Vendor/CLibrashader/librashader.h` | Unmodified `librashader.h` extracted from the official [`librashader-aarch64-macos-v0.12.0-optimized.zip`](https://github.com/SnowflakePowered/librashader/releases/download/librashader-v0.12.0/librashader-aarch64-macos-v0.12.0-optimized.zip) release asset. The MIT copyright and permission notice remain in the header. |
| `Vendor/CLibrashader/LICENSE-MPL-2.0.md` | Unmodified [`LICENSE.md`](https://github.com/SnowflakePowered/librashader/blob/librashader-v0.12.0/LICENSE.md) from the pinned upstream tag. It covers the runtime implementation, not the MIT C header. |
| `Vendor/CLibrashader/shim.h` | Written for ScreenSlanger. Enables `LIBRA_RUNTIME_METAL` before importing the official header and the separate local extension header. |
| `Vendor/CLibrashader/screenslanger.h` | Written for ScreenSlanger. Declares the local helper-aware C entry point implemented by patch 4 without modifying the vendored upstream header. |
| `Vendor/CLibrashader/module.modulemap` | Written for ScreenSlanger. Exposes the header as the `CLibrashader` Clang module for Swift. |
| `Vendor/CLibrashader/NOTICE.md` | Written for ScreenSlanger. Records licensing, corresponding-source links, and integration constraints. |
| `Vendor/CLibrashader/BUILDING.md` | Written for ScreenSlanger. Reproduces the runtime from a checkout or the source and patches included in the app. |
| `Vendor/CLibrashader/patches/0001-skip-unused-final-target.patch` | ScreenSlanger's MPL-2.0 modification to upstream framebuffer scaling and Metal rendering. Skips full-size allocation of the final target when the shader does not need final-pass feedback; preserves declared sizes and feedback behavior. |
| `Vendor/CLibrashader/patches/0002-compact-grayscale-luts.patch` | ScreenSlanger's MPL-2.0 modification to upstream Metal LUT loading. Packs exactly grayscale textures into `RG8Unorm` with a red/red/red/green component swizzle, preserving the original RGB and alpha values, including transparent border samples. Colored textures retain their original `BGRA8Unorm` representation. |
| `Vendor/CLibrashader/patches/0003-stream-metal-lut-loading.patch` | ScreenSlanger's MPL-2.0 modification to Metal preset loading. Decodes and uploads LUTs one at a time; 8-bit grayscale images retain their compact decoded form and upload in at most 64-row strips instead of expanding the whole image. Color and 16-bit images keep the existing conversion behavior, and the public packed-preset format and API are unchanged. Adds the already-pinned `image` crate as a direct Metal dependency without changing dependency versions. |
| `Vendor/CLibrashader/patches/0004-isolate-retroarch-compiler.patch` | ScreenSlanger's MPL-2.0 modification adding the `librashader-compiler` helper and a C entry point accepting its explicit path. Moves GLSL compilation into a short-lived process so compiler-global allocations are reclaimed without violating glslang's process-lifetime API. The helper-aware path preprocesses passes sequentially, avoids a permanent Rayon pool, and releases GLSL source strings after pipeline creation. A bounded SPIR-V response cache preserves warm reload performance. |

The dynamic library and helper executable are **not committed to the repository**. The setup script downloads the pinned upstream source archive, verifies its SHA-256 digest and all four reviewed patch digests, applies the patches, and builds both outputs together:

```sh
cargo +1.93.0 build --locked --profile optimized \
    --package librashader-capi --package librashader-reflect \
    --bin librashader-compiler --lib --no-default-features \
    --features librashader-capi/runtime-metal,librashader-reflect/glslang-in
```

The build uses `MACOSX_DEPLOYMENT_TARGET=27.0`, the selected macOS SDK, and `CARGO_PROFILE_OPTIMIZED_STRIP=none`. Disabling stripping avoids Rust 1.93.0 generating misaligned Mach-O LINKEDIT string pools that macOS 27 rejects when loading build-time procedural macros or the final binaries; optimization and LTO remain enabled. The source patches include the corresponding manifest and lockfile changes. Setup downloads any missing Cargo dependencies and compiles them with `--locked`; the normal Xcode build never invokes Cargo or accesses the network.

Setup installs `librashader.dylib` and `librashader-compiler` into `~/Library/Application Support/ScreenSlanger/Tools/librashader/0.12.0-screenslanger.3/`, alongside their source archive, applied patches, license, notice, and build instructions. Existing official and previous local runtime installations are preserved. `BUILD-INFO.txt` records the version, source and patch checksums, compiler version, architecture, and build command. Setup checks that metadata before reusing an installation, so a changed source or build recipe needs a new local runtime version. `RUNTIME.sha256` verifies both installed binaries; `SHA256SUMS` verifies their source archive and patches.

The pinned corresponding-source checksums are:

| File | SHA-256 |
| --- | --- |
| [Upstream source archive](https://github.com/SnowflakePowered/librashader/archive/refs/tags/librashader-v0.12.0.tar.gz) | `4bf8cf2489d00848dcabbf2163204093776082da4217d5a5db45e4cbf335cedf` |
| `0001-skip-unused-final-target.patch` | `f5a9c09c0f7a72059eb536fbd63eacbc513bea5fe964e70f3a122ae61bfd90fb` |
| `0002-compact-grayscale-luts.patch` | `2fd5bd08afabf7f0ee6c8329fcfda778b6460001d7de50145c32af329138fe5e` |
| `0003-stream-metal-lut-loading.patch` | `3e3c574a0b8940f04502bece08442ab297bc1b9a7de89dff412b51566de9acfe` |
| `0004-isolate-retroarch-compiler.patch` | `1956179bfa7f89e4318c1aa3982656d24ea63e6dffe9494d87ad64a3f27dac8f` |

The extracted, unmodified `librashader.h` has SHA-256 `5d478897c391af3f60015810b67785ae1a286d262a845485276e36ded9f21e62`.

The app build copies the library into `Contents/Frameworks/`, gives it a relocatable install name, and copies the helper into `Contents/Helpers/librashader-compiler`. Both binaries are signed with the app's build identity before the application is signed. It also bundles the exact upstream archive, all four patches, `SHA256SUMS`, `BUILD-INFO.txt`, `BUILDING.md`, the MPL-2.0 license, and source notice under `Contents/Resources/ThirdParty/librashader/`. These files let a recipient reconstruct the modified runtime and helper without this checkout. The installation's binary hashes are verified before packaging and are not bundled because signing changes their bytes. The vendored C header keeps its own MIT notice.

Unhosted tests and probes can override the runtime with `LIBRASHADER_PATH` and the helper with `LIBRASHADER_COMPILER_PATH`; otherwise the helper is located beside the selected runtime. Applications always use the embedded library and exact bundled helper path, ignoring those overrides. A missing helper is an error, with no in-process GLSL compiler fallback. The local `screenslanger_mtl_filter_chain_create_with_compiler` symbol adds this explicit helper path to creation while preserving the upstream header and existing entry points.

## Updating librashader

1. Select an official stable release, record the source tag and archive checksum, and review the locked dependencies and Rust compiler requirements. Check whether upstream has incorporated our patches before rebasing them. Any source, patch, or build recipe change requires a new distinct local runtime version; never overwrite an installed upstream or local version.
2. Download and verify the official release archive before extracting its C header. Replace the header without editing upstream declarations; retain its copyright and license. Refresh the upstream license and source notice if needed. Update each source patch's checksum in the setup script and this document after review.
3. Update the pinned runtime path in `ScreenSlanger/librashader.swift`, the installer, the bundling script and input/output file lists, the source rebuilding instructions, and the README together. The output list must enumerate every packaged file and directory, including the corresponding source. Compare C ABI/API versions, struct layouts, ownership rules, and the Metal runtime's thread-safety requirements. Do not guess Swift declarations for C structs or function pointers.
4. Install the new runtime and run the full native test suite, including known-pixel output, multipass presets, reflected parameter layouts, texture filtering, custom vertices, includes, failures, and reloads. Verify app activation, animated effects on a static desktop, parameter editing, display changes, and deactivation on a Metal-capable Mac.
5. Commit the header, adapter changes, checksums, documentation, and regression fixtures together. Do not add downloaded native binaries or generated caches to Git.

`ScreenSlanger/librashader.swift` keeps each filter chain on a dedicated OS thread, including creation and destruction. This respects upstream's non-thread-safe Metal runtime. Its shared GPU uniform storage also requires only one outstanding frame per chain. A busy chain drops a render attempt rather than overwriting in-use buffers. Each display owns a separate chain so feedback and history textures remain independent.

The native shader-slang compiler is a separate backend and dependency. Its pinned release and checksums are also in `scripts/setup-dependencies.sh`; updating librashader does not update shader-slang.

## Self-contained application builds

The application target's **Bundle Shader Runtimes** phase runs `scripts/bundle-shader-runtimes.sh` as part of normal Debug, Release, and Archive builds. Input/output `.xcfilelist` files declare its dependency paths and every packaged file and directory. User-script sandboxing stays enabled: modifications and signing use the build's temporary directory, followed by copies directly to the declared outputs. The build verifies the installed library and source checksums before copying them. It never downloads tools or compiles Rust: run setup first, and a missing runtime fails the build with instructions. Clean the build products when changing dependency versions so files removed by an upstream release cannot remain in an old bundle.

The app layout is:

```text
ScreenSlanger.app/Contents/
  Helpers/Slang.app/Contents/MacOS/slangc
  Helpers/Slang.app/Contents/lib/                 # Compiler libraries, plugins, and standard modules
  Helpers/librashader-compiler                   # Short-lived RetroArch GLSL frontend
  Frameworks/librashader.dylib
  Resources/ThirdParty/Slang/        # Upstream LICENSE, LICENSES, and source notice
  Resources/ThirdParty/librashader/  # MPL-2.0 license, source archive, patches, hashes, rebuild instructions
```

Slang is wrapped in a helper `.app` so code signing distinguishes its standard-library data from nested executables. Its executable/`../lib` relationship is preserved so its relative rpaths and runtime plugin lookup remain valid after moving the app. Packaging removes upstream CI-machine absolute rpaths, verifies architecture slices, and signs each nested binary and the helper bundle before Xcode signs the app. Both runtimes use the build's signing identity; local unsigned builds use ad-hoc nested signatures. Developer ID signing requests Apple's secure timestamp; development and ad-hoc signing do not require the timestamp service. Distributing through ordinary macOS download channels still requires your normal Developer ID signing and notarization workflow.

For a packaging regression check, move a built `.app` to a temporary directory outside DerivedData, verify it with `codesign --verify --deep --strict`, and load both a native Slang shader and a RetroArch preset from that copy. Confirm the compiler and loaded librashader paths stay inside the moved app even if `SLANG_PATH` and `LIBRASHADER_PATH` point to nonexistent files. Run the packaged compiler's `-version` and inspect its `otool -L`/`LC_RPATH` output. Recipients should never need the per-user setup installation.

Standalone shaders can be shared with the app. Shader folders containing includes, modules, LUT textures, or referenced presets must keep those files and relative paths together.
