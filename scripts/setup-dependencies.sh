#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ScreenSlanger's dependencies must be installed on macOS." >&2
    exit 1
fi

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
slang_version="2026.18"
librashader_version="0.12.0-screenslanger.1"
librashader_upstream_version="0.12.0"
librashader_source_sha256="4bf8cf2489d00848dcabbf2163204093776082da4217d5a5db45e4cbf335cedf"
librashader_rust_version="1.93.0"
librashader_patches=(0001-skip-unused-final-target.patch 0002-compact-grayscale-luts.patch)
# Reviewed patches against the checksum-pinned source archive, not upstream binaries.
librashader_patch_sha256=(f5a9c09c0f7a72059eb536fbd63eacbc513bea5fe964e70f3a122ae61bfd90fb 2fd5bd08afabf7f0ee6c8329fcfda778b6460001d7de50145c32af329138fe5e)
# Checksums published with the official v2026.18 GitHub release assets.
# https://github.com/shader-slang/slang/releases/tag/v2026.18
case "$(uname -m)" in
    arm64)
        slang_arch="aarch64"
        slang_sha256="59833c5cfa12aad72c6fbad9cfcc06be8781ecd58c5983e6c79425e819e16bb2"
        librashader_arch="arm64"
        ;;
    x86_64)
        slang_arch="x86_64"
        slang_sha256="8d27b7020b102beecaa769c1ff7342dd2534c14cfae505a36e1b71d595208739"
        librashader_arch="x86_64"
        ;;
    *)
        echo "Unsupported Mac architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

slang_root="$HOME/Library/Application Support/ScreenSlanger/Tools/slang"
slang_directory="$slang_root/$slang_version"
mkdir -p "$slang_root"

if [[ -e "$slang_root/current" && ! -L "$slang_root/current" ]]; then
    echo "$slang_root/current exists and is not a symlink; leaving it unchanged." >&2
    exit 1
fi

if [[ ! -e "$slang_directory" ]]; then
    staging_directory="$(mktemp -d "$slang_root/.install.XXXXXX")"
    trap 'rm -rf "$staging_directory"' EXIT
    archive_url="https://github.com/shader-slang/slang/releases/download/v$slang_version/slang-$slang_version-macos-$slang_arch.tar.gz"
    curl --fail --location --retry 3 "$archive_url" --output "$staging_directory/slang.tar.gz"
    (
        cd "$staging_directory"
        printf '%s  slang.tar.gz\n' "$slang_sha256" | shasum -a 256 --check -
    )
    mkdir "$staging_directory/unpacked"
    tar -xzf "$staging_directory/slang.tar.gz" -C "$staging_directory/unpacked"
    installed_version="$("$staging_directory/unpacked/bin/slangc" -version 2>&1)"
    if [[ "$installed_version" != "$slang_version" ]]; then
        echo "Expected Slang $slang_version, got $installed_version; installation stopped." >&2
        exit 1
    fi
    mv "$staging_directory/unpacked" "$slang_directory"
    rm -rf "$staging_directory"
    trap - EXIT
fi

installed_version="$("$slang_directory/bin/slangc" -version 2>&1)"
if [[ "$installed_version" != "$slang_version" ]]; then
    echo "Unexpected Slang version in $slang_directory: $installed_version" >&2
    exit 1
fi
ln -sfn "$slang_version" "$slang_root/current"

# Compile our Metal-only runtime during setup. Normal Xcode builds only copy it.
# A distinct version preserves the official 0.12.0 installation for comparisons.
librashader_root="$HOME/Library/Application Support/ScreenSlanger/Tools/librashader"
librashader_directory="$librashader_root/$librashader_version"
patch_directory="$project_dir/Vendor/CLibrashader/patches"
for index in "${!librashader_patches[@]}"; do
    (
        cd "$patch_directory"
        printf '%s  %s\n' "${librashader_patch_sha256[$index]}" "${librashader_patches[$index]}" | shasum -a 256 --check -
    )
done
expected_build_info="$(cat <<BUILD_INFO
ScreenSlanger librashader runtime: $librashader_version
Upstream tag: librashader-v$librashader_upstream_version
Upstream archive SHA-256: $librashader_source_sha256
Patch 1 SHA-256: ${librashader_patch_sha256[0]}
Patch 2 SHA-256: ${librashader_patch_sha256[1]}
Rust toolchain: $librashader_rust_version
Architecture: $librashader_arch
MACOSX_DEPLOYMENT_TARGET: 27.0
CARGO_PROFILE_OPTIMIZED_STRIP: none
Build: cargo +$librashader_rust_version build --locked --profile optimized --package librashader-capi --no-default-features --features runtime-metal
BUILD_INFO
)"
mkdir -p "$librashader_root"
if [[ ! -e "$librashader_directory" ]]; then
    if ! command -v rustup >/dev/null || ! rustup run "$librashader_rust_version" rustc --version >/dev/null 2>&1; then
        echo "Install Rust with rustup (https://rustup.rs/), then run: rustup toolchain install $librashader_rust_version --profile minimal" >&2
        exit 1
    fi
    if ! xcrun --sdk macosx --find clang++ >/dev/null 2>&1; then
        echo "Select Xcode 27 with xcode-select before building librashader." >&2
        exit 1
    fi
    staging_directory="$(mktemp -d "$librashader_root/.install.XXXXXX")"
    trap 'rm -rf "$staging_directory"' EXIT
    source_archive="librashader-v$librashader_upstream_version-source.tar.gz"
    archive_url="https://github.com/SnowflakePowered/librashader/archive/refs/tags/librashader-v$librashader_upstream_version.tar.gz"
    mkdir "$staging_directory/install" "$staging_directory/source"
    curl --fail --location --retry 3 "$archive_url" --output "$staging_directory/install/$source_archive"
    (
        cd "$staging_directory/install"
        printf '%s  %s\n' "$librashader_source_sha256" "$source_archive" | shasum -a 256 --check -
    )
    tar -xzf "$staging_directory/install/$source_archive" --strip-components 1 -C "$staging_directory/source"
    for patch_file in "${librashader_patches[@]}"; do
        cp "$patch_directory/$patch_file" "$staging_directory/install/$patch_file"
        (cd "$staging_directory/source" && /usr/bin/patch --batch --forward --fuzz=0 -p1 < "$staging_directory/install/$patch_file")
    done
    (
        cd "$staging_directory/source"
        # Cargo.lock pins Rust and embedded C/C++ dependencies. Downloading crates
        # and compiling them happens here, never in the app's Xcode build phase.
        # Rust 1.93's stripping can misalign LINKEDIT string pools rejected by
        # macOS 27 dyld, including build-time proc macros. Keep optimization/LTO,
        # but disable stripping for the complete profile, including build tools.
        MACOSX_DEPLOYMENT_TARGET=27.0 SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
            CARGO_PROFILE_OPTIMIZED_STRIP=none \
            CARGO_TARGET_DIR="$staging_directory/target" \
            cargo +"$librashader_rust_version" build --locked --profile optimized \
            --package librashader-capi --no-default-features --features runtime-metal
    )
    cp "$staging_directory/target/optimized/liblibrashader_capi.dylib" "$staging_directory/install/librashader.dylib"
    /usr/bin/lipo "$staging_directory/install/librashader.dylib" -verify_arch "$librashader_arch"
    printf '%s\n' "$expected_build_info" > "$staging_directory/install/BUILD-INFO.txt"
    (
        cd "$staging_directory/install"
        shasum -a 256 "$source_archive" "${librashader_patches[@]}" > SHA256SUMS
        shasum -a 256 librashader.dylib > RUNTIME.sha256
    )
    mv "$staging_directory/install" "$librashader_directory"
    rm -rf "$staging_directory"
    trap - EXIT
fi
if [[ ! -f "$librashader_directory/BUILD-INFO.txt" || "$(cat "$librashader_directory/BUILD-INFO.txt")" != "$expected_build_info" ]]; then
    echo "Unexpected build provenance in $librashader_directory; installation stopped. Use a new runtime version when changing its source, patches, or build settings." >&2
    exit 1
fi
(
    cd "$librashader_directory"
    shasum -a 256 --check SHA256SUMS
    shasum -a 256 --check RUNTIME.sha256
)
cp "$project_dir/Vendor/CLibrashader/LICENSE-MPL-2.0.md" "$librashader_directory/LICENSE-MPL-2.0.md"
cp "$project_dir/Vendor/CLibrashader/NOTICE.md" "$librashader_directory/NOTICE.md"
cp "$project_dir/Vendor/CLibrashader/BUILDING.md" "$librashader_directory/BUILDING.md"

printf '\nInstalled ScreenSlanger dependencies:\n'
printf 'slang %s (%s)\n' "$installed_version" "$slang_root/current/bin/slangc"
printf 'librashader %s (%s)\n' "$librashader_version" "$librashader_directory/librashader.dylib"
