#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: scripts/test.sh [--allow-no-metal]"
    echo "Run the full test suite, or allow CPU/compiler tests when Metal is unavailable."
}

allow_no_metal=false
for argument in "$@"; do
    case "$argument" in
        --allow-no-metal) allow_no_metal=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $argument" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ScreenSlanger's tests must run on macOS." >&2
    exit 1
fi

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
results_directory="$(mktemp -d "${TMPDIR:-/tmp}/screenslanger-tests.XXXXXX")"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'results-directory=%s\n' "$results_directory" >> "$GITHUB_OUTPUT"
fi

test_mode="Full suite"
coverage_note="Includes Metal rendering and runtime relocation tests."
finish() {
    local exit_status=$?
    printf '\nTest logs and build results: %s\n' "$results_directory"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        {
            printf '### ScreenSlanger tests\n\n'
            printf 'Selected scope: **%s**.\n\n' "$test_mode"
            printf '%s\n\n' "$coverage_note"
            if [[ "$exit_status" -eq 0 ]]; then
                printf 'Result: passed.\n'
            else
                printf 'Result: failed (exit status %s). See the retained logs.\n' "$exit_status"
            fi
        } >> "$GITHUB_STEP_SUMMARY"
    fi
    return "$exit_status"
}
trap finish EXIT

# Only this probe's explicit no-device status permits the reduced suite.
# Compiler errors and other failures must still fail the check.
cat > "$results_directory/metal-probe.swift" <<'SWIFT'
import Darwin
import Metal

guard let device = MTLCreateSystemDefaultDevice() else {
    print("No Metal device is available.")
    exit(42)
}
print("Metal device: \(device.name)")
SWIFT

probe_status=0
xcrun swift "$results_directory/metal-probe.swift" > "$results_directory/metal-probe.log" 2>&1 || probe_status=$?
cat "$results_directory/metal-probe.log"

test_arguments=(
    test
    -project "$project_dir/ScreenSlanger.xcodeproj"
    -scheme ScreenSlanger
    -destination 'platform=macOS'
    -parallel-testing-enabled NO
    -disableAutomaticPackageResolution
    -derivedDataPath "$results_directory/DerivedData"
    -resultBundlePath "$results_directory/TestResults.xcresult"
    CODE_SIGN_IDENTITY=-
    CODE_SIGN_STYLE=Manual
    DEVELOPMENT_TEAM=
)

if [[ "$probe_status" -eq 42 ]]; then
    if [[ "$allow_no_metal" != true ]]; then
        coverage_note="No tests ran because Metal is unavailable. The full suite requires a Metal-capable Mac."
        echo "The full suite requires Metal. Use --allow-no-metal to run the CPU/compiler and non-GPU packaging checks." >&2
        exit 1
    fi
    test_mode="CPU/compiler and non-GPU packaging tests"
    coverage_note="Metal is unavailable: shader rendering and GPU runtime relocation tests were excluded. This run does not validate rendered output."
    test_arguments+=(
        '-skip-testing:ScreenSlangerTests/ShaderTests'
        '-skip-testing:ScreenSlangerTests/RuntimeBundleTests/relocatedRetroArchLibrary()'
    )
    if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
        printf '::warning title=Metal tests skipped::%s\n' "$coverage_note"
    else
        printf 'Warning: %s\n' "$coverage_note" >&2
    fi
elif [[ "$probe_status" -ne 0 ]]; then
    coverage_note="No tests ran because the Metal capability probe failed."
    echo "Metal capability probe failed with exit status $probe_status." >&2
    exit "$probe_status"
fi

printf '\nRunning %s.\n' "$test_mode"
xcodebuild "${test_arguments[@]}" 2>&1 | tee "$results_directory/xcodebuild.log"
