# Rebuilding ScreenSlanger's librashader runtime

ScreenSlanger uses **0.12.0-screenslanger.3**, built from upstream tag
[`librashader-v0.12.0`](https://github.com/SnowflakePowered/librashader/tree/librashader-v0.12.0)
with the four patches shipped beside this file. The upstream C header remains
unmodified; the fourth patch adds a ScreenSlanger-specific C entry point and
a separate `librashader-compiler` executable. This build enables only the Metal
runtime. The third patch adds the
already-pinned `image` crate as a direct Metal dependency; dependency versions
are unchanged.

The application includes the complete upstream source archive, its original
`Cargo.lock`, all four applied patches, and the MPL-2.0 license in
`Contents/Resources/ThirdParty/librashader/`. This directory is sufficient to
recover the modified librashader source without the ScreenSlanger checkout.
Cargo downloads the dependencies identified by the upstream lockfile when
rebuilding. Recipients who only run ScreenSlanger need none of these build tools.

## Prerequisites

- macOS 27 or later and Xcode 27 selected with `xcode-select`.
- [rustup](https://rustup.rs/) and the pinned Rust toolchain:

```sh
rustup toolchain install 1.93.0 --profile minimal
```

## From a ScreenSlanger checkout

Run `./scripts/setup-dependencies.sh`. It verifies the upstream archive and
reviewed patch checksums, applies the patches, builds with the locked dependency
graph and optimized profile, then installs the runtime and compiler helper into
`~/Library/Application Support/ScreenSlanger/Tools/librashader/0.12.0-screenslanger.3/`.
The official `0.12.0` and previous local runtime installations are
preserved. Normal Xcode builds only verify,
copy, and sign the installed runtime; they do not download or compile Rust code.

## From an application bundle

Copy this entire `librashader` directory to a writable folder, then run the
following commands in that copy. `SHA256SUMS` checks the source archive
and all four patches against the recorded distribution; `BUILD-INFO.txt` records
the version, toolchain, architecture, and build command.

```sh
shasum -a 256 --check SHA256SUMS
mkdir source
tar -xzf librashader-v0.12.0-source.tar.gz --strip-components 1 -C source
(cd source && patch --batch --forward --fuzz=0 -p1 < ../0001-skip-unused-final-target.patch)
(cd source && patch --batch --forward --fuzz=0 -p1 < ../0002-compact-grayscale-luts.patch)
(cd source && patch --batch --forward --fuzz=0 -p1 < ../0003-stream-metal-lut-loading.patch)
(cd source && patch --batch --forward --fuzz=0 -p1 < ../0004-isolate-retroarch-compiler.patch)
cd source
MACOSX_DEPLOYMENT_TARGET=27.0 SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
    CARGO_PROFILE_OPTIMIZED_STRIP=none \
    cargo +1.93.0 build --locked --profile optimized \
    --package librashader-capi --package librashader-reflect \
    --bin librashader-compiler --lib --no-default-features \
    --features librashader-capi/runtime-metal,librashader-reflect/glslang-in
```

`CARGO_PROFILE_OPTIMIZED_STRIP=none` avoids a Rust 1.93.0 stripping issue that
produces misaligned Mach-O LINKEDIT string pools rejected by macOS 27's loader.
It applies to both build-time procedural macros and the final library; limiting
it to build dependencies leaves the final library affected. Optimization, LTO,
and the pinned dependency versions remain unchanged.

The outputs are `target/optimized/liblibrashader_capi.dylib` and
`target/optimized/librashader-compiler`. ScreenSlanger installs the library
as `librashader.dylib`, changes its Mach-O identity to
`@rpath/librashader.dylib`, removes absolute build-machine rpaths, and signs the
app copy. The helper is copied to `Contents/Helpers/librashader-compiler` and
signed with the same identity. Those packaging steps do not change the source implementation.
The installation's `RUNTIME.sha256` verifies both binaries before packaging; it is
not copied into the application because code signing changes the binary bytes.

The upstream source archive is
[`librashader-v0.12.0.tar.gz`](https://github.com/SnowflakePowered/librashader/archive/refs/tags/librashader-v0.12.0.tar.gz),
SHA-256 `4bf8cf2489d00848dcabbf2163204093776082da4217d5a5db45e4cbf335cedf`.
Rebuilds use the pinned source, patches, and dependencies; binary hashes can
differ with the selected Xcode SDK and signing identity.
