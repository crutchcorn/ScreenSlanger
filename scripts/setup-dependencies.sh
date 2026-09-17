#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ScreenSlanger's dependencies must be installed on macOS." >&2
    exit 1
fi

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
slang_version="2026.18"
# Checksums published with the official v2026.18 GitHub release assets.
# https://github.com/shader-slang/slang/releases/tag/v2026.18
case "$(uname -m)" in
    arm64)
        slang_arch="aarch64"
        slang_sha256="59833c5cfa12aad72c6fbad9cfcc06be8781ecd58c5983e6c79425e819e16bb2"
        ;;
    x86_64)
        slang_arch="x86_64"
        slang_sha256="8d27b7020b102beecaa769c1ff7342dd2534c14cfae505a36e1b71d595208739"
        ;;
    *)
        echo "Unsupported Mac architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

brew_command="$(command -v brew || true)"
if [[ -z "$brew_command" ]]; then
    echo "Install Homebrew from https://brew.sh, then run this script again." >&2
    exit 1
fi

# Upgrade only this project's formulae and their required dependencies.
# Do not clean up other installed packages.
HOMEBREW_NO_INSTALL_CLEANUP=1 "$brew_command" bundle install --upgrade --file="$project_dir/Brewfile"

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
fi

installed_version="$("$slang_directory/bin/slangc" -version 2>&1)"
if [[ "$installed_version" != "$slang_version" ]]; then
    echo "Unexpected Slang version in $slang_directory: $installed_version" >&2
    exit 1
fi
ln -sfn "$slang_version" "$slang_root/current"

printf '\nInstalled ScreenSlanger dependencies:\n'
"$brew_command" list --versions glslang spirv-cross
printf 'slang %s (%s)\n' "$installed_version" "$slang_root/current/bin/slangc"
