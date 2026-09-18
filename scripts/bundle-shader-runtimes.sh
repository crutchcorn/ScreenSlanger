#!/bin/bash
set -euo pipefail

# Xcode runs this after resources are copied and before signing the application.
# Downloads and Rust compilation belong to setup-dependencies.sh; Xcode builds are offline.
: "${SRCROOT:?This script is an Xcode build phase.}"
: "${TARGET_BUILD_DIR:?This script is an Xcode build phase.}"
: "${CONTENTS_FOLDER_PATH:?This script is an Xcode build phase.}"
: "${FRAMEWORKS_FOLDER_PATH:?This script is an Xcode build phase.}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?This script is an Xcode build phase.}"
: "${TARGET_TEMP_DIR:?This script is an Xcode build phase.}"

slang_version="2026.18"
librashader_version="0.12.0-screenslanger.2"
tools_directory="$HOME/Library/Application Support/ScreenSlanger/Tools"
slang_source="$tools_directory/slang/$slang_version"
librashader_directory="$tools_directory/librashader/$librashader_version"
librashader_source="$librashader_directory/librashader.dylib"

if [[ ! -x "$slang_source/bin/slangc" || ! -f "$librashader_source" ]]; then
    echo "error: Shader dependencies are missing. Run scripts/setup-dependencies.sh from the checkout, then build again." >&2
    exit 1
fi

# Validate the installed library before changing its install name or signing it.
# Source hashes remain valid in the app; the installation's binary hash does not.
(
    cd "$librashader_directory"
    shasum -a 256 --check RUNTIME.sha256
    shasum -a 256 --check SHA256SUMS
)

package_staging="$TARGET_TEMP_DIR/ShaderRuntimes"
slang_bundle="$package_staging/Slang.app"
slang_destination="$slang_bundle/Contents"
frameworks_destination="$package_staging/Frameworks"
notices_destination="$package_staging/ThirdParty"
mkdir -p "$slang_destination/MacOS" "$slang_destination/lib" "$frameworks_destination" "$notices_destination/Slang" "$notices_destination/librashader"

# Keep Slang's executable/../lib relationship intact for dynamically loaded backends.
# A nested helper .app gives code signing a valid bundle boundary around its data modules.
# Headers, documentation, and compiler development metadata are not needed at runtime.
rsync -a --delete "$slang_source/bin/slangc" "$slang_destination/MacOS/"
cp "$SRCROOT/scripts/Slang-Info.plist" "$slang_destination/Info.plist"
rsync -a --delete --exclude cmake --exclude pkgconfig "$slang_source/lib/" "$slang_destination/lib/"
cp "$librashader_source" "$frameworks_destination/librashader.dylib"
cp "$slang_source/LICENSE" "$notices_destination/Slang/LICENSE"
rsync -a --delete "$slang_source/LICENSES/" "$notices_destination/Slang/LICENSES/"
cp "$SRCROOT/Vendor/CLibrashader/LICENSE-MPL-2.0.md" "$notices_destination/librashader/LICENSE-MPL-2.0.md"
cp "$SRCROOT/Vendor/CLibrashader/NOTICE.md" "$notices_destination/librashader/NOTICE.md"
cp "$SRCROOT/Vendor/CLibrashader/BUILDING.md" "$notices_destination/librashader/BUILDING.md"
for source_file in librashader-v0.12.0-source.tar.gz \
    0001-skip-unused-final-target.patch 0002-compact-grayscale-luts.patch \
    0003-stream-metal-lut-loading.patch \
    BUILD-INFO.txt SHA256SUMS; do
    cp "$librashader_directory/$source_file" "$notices_destination/librashader/$source_file"
done
cat > "$notices_destination/Slang/NOTICE.txt" <<NOTICE
Slang $slang_version, Copyright shader-slang contributors.
This app bundles the unmodified official macOS compiler and libraries, apart from
removing upstream build-machine rpaths and applying the app publisher's code signature.
Source: https://github.com/shader-slang/slang/tree/v$slang_version
Release: https://github.com/shader-slang/slang/releases/tag/v$slang_version
See LICENSE and LICENSES/ for the distribution's complete license texts.
NOTICE

sign_identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [[ -z "$sign_identity" ]]; then sign_identity="-"; fi
timestamp_option="--timestamp=none"
if [[ "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}" == "Developer ID"* ]]; then
    timestamp_option="--timestamp"
fi

prepare_binary() {
    local binary="$1"
    # A host-only runtime must never silently produce an app promising other architectures.
    for architecture in ${ARCHS:-$(uname -m)}; do
        if ! /usr/bin/lipo "$binary" -verify_arch "$architecture"; then
            echo "error: $binary has no $architecture slice. Build for the installed runtime architecture." >&2
            exit 1
        fi
    done

    # Official archives can contain CI-machine rpaths. Relative loader paths stay valid
    # after moving the .app, and no recipient needs the upstream build directory.
    while IFS= read -r rpath; do
        if [[ "$rpath" = /* ]]; then
            /usr/bin/install_name_tool -delete_rpath "$rpath" "$binary"
        fi
    done < <(/usr/bin/otool -l "$binary" | /usr/bin/awk '/LC_RPATH/{getline; getline; sub(/^ *path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print}')

    # Sign nested code before Xcode signs the app. Developer ID builds use the same
    # identity throughout; local builds use ad-hoc signatures. Do not use --deep.
    if [[ "$sign_identity" == "-" ]]; then
        /usr/bin/codesign --force --sign - --timestamp=none "$binary"
    else
        /usr/bin/codesign --force --sign "$sign_identity" --options runtime "$timestamp_option" "$binary"
    fi
}

for binary in "$slang_destination"/lib/*.dylib; do
    if [[ ! -L "$binary" ]]; then prepare_binary "$binary"; fi
done
prepare_binary "$slang_destination/MacOS/slangc"
if [[ "$sign_identity" == "-" ]]; then
    /usr/bin/codesign --force --sign - --timestamp=none "$slang_bundle"
else
    /usr/bin/codesign --force --sign "$sign_identity" --options runtime "$timestamp_option" "$slang_bundle"
fi
# This library is loaded by absolute bundle path, but give it a relocatable identity too.
/usr/bin/install_name_tool -id '@rpath/librashader.dylib' "$frameworks_destination/librashader.dylib"
prepare_binary "$frameworks_destination/librashader.dylib"

# Xcode permits only exact declared output paths, even for directories. Signing and
# rsync's temporary work happen in TARGET_TEMP_DIR; final copies write declared files
# in place so the build phase can keep user-script sandboxing enabled.
final_slang="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/Slang.app"
final_frameworks="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
final_notices="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ThirdParty"
mkdir -p "$final_slang" "$final_frameworks" "$final_notices"
rsync -a --inplace "$slang_bundle/" "$final_slang/"
cp "$frameworks_destination/librashader.dylib" "$final_frameworks/librashader.dylib"
rsync -a --inplace "$notices_destination/" "$final_notices/"

echo "Bundled Slang $slang_version and librashader $librashader_version into the application."
