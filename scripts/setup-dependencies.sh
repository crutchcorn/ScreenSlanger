#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ScreenSlanger's dependencies must be installed on macOS." >&2
    exit 1
fi

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
slang_version="2026.18"
librashader_version="0.12.0"
# Checksums published with the official v2026.18 GitHub release assets.
# https://github.com/shader-slang/slang/releases/tag/v2026.18
case "$(uname -m)" in
    arm64)
        slang_arch="aarch64"
        slang_sha256="59833c5cfa12aad72c6fbad9cfcc06be8781ecd58c5983e6c79425e819e16bb2"
        librashader_arch="aarch64"
        librashader_sha256="49808004a4904f6a99e0231092dcfdfe52b7b61f68430a4c9f1e165749c4c90e"
        ;;
    x86_64)
        slang_arch="x86_64"
        slang_sha256="8d27b7020b102beecaa769c1ff7342dd2534c14cfae505a36e1b71d595208739"
        librashader_arch="x86_64"
        librashader_sha256="8b2a50cefacf4073e8fa4757bec30242a788068c4096a580d94430688c184767"
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

# The Metal runtime contains its own RetroArch preset parser, compiler, reflection,
# and multipass renderer. Digests are from the official GitHub release asset metadata.
librashader_root="$HOME/Library/Application Support/ScreenSlanger/Tools/librashader"
librashader_directory="$librashader_root/$librashader_version"
mkdir -p "$librashader_root"
if [[ ! -e "$librashader_directory" ]]; then
    staging_directory="$(mktemp -d "$librashader_root/.install.XXXXXX")"
    trap 'rm -rf "$staging_directory"' EXIT
    archive_url="https://github.com/SnowflakePowered/librashader/releases/download/librashader-v$librashader_version/librashader-$librashader_arch-macos-v$librashader_version-optimized.zip"
    curl --fail --location --retry 3 "$archive_url" --output "$staging_directory/librashader.zip"
    (
        cd "$staging_directory"
        printf '%s  librashader.zip\n' "$librashader_sha256" | shasum -a 256 --check -
    )
    mkdir "$staging_directory/unpacked"
    unzip -q "$staging_directory/librashader.zip" librashader.dylib -d "$staging_directory/unpacked"
    cp "$project_dir/Vendor/CLibrashader/LICENSE-MPL-2.0.md" "$staging_directory/unpacked/LICENSE-MPL-2.0.md"
    cp "$project_dir/Vendor/CLibrashader/NOTICE.md" "$staging_directory/unpacked/NOTICE.md"
    mv "$staging_directory/unpacked" "$librashader_directory"
    rm -rf "$staging_directory"
    trap - EXIT
fi
if [[ ! -f "$librashader_directory/librashader.dylib" ]]; then
    echo "Missing runtime in $librashader_directory; installation stopped." >&2
    exit 1
fi
cp "$project_dir/Vendor/CLibrashader/LICENSE-MPL-2.0.md" "$librashader_directory/LICENSE-MPL-2.0.md"
cp "$project_dir/Vendor/CLibrashader/NOTICE.md" "$librashader_directory/NOTICE.md"

printf '\nInstalled ScreenSlanger dependencies:\n'
printf 'slang %s (%s)\n' "$installed_version" "$slang_root/current/bin/slangc"
printf 'librashader %s (%s)\n' "$librashader_version" "$librashader_directory/librashader.dylib"
