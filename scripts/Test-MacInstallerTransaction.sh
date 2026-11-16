#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_APP="$ROOT/dist/macos/TopFade.app"
INSTALLER="$ROOT/scripts/Install-Mac.sh"
SKIP_BUILD=0

for argument in "$@"; do
    case "$argument" in
        --skip-build) SKIP_BUILD=1 ;;
        *)
            echo "Unknown argument: $argument" >&2
            echo "Usage: Test-MacInstallerTransaction.sh [--skip-build]" >&2
            exit 2
            ;;
    esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Test-MacInstallerTransaction.sh must run on macOS." >&2
    exit 3
fi
if [[ "$SKIP_BUILD" -eq 0 ]]; then
    bash "$ROOT/scripts/Build-Mac.sh"
fi
if [[ ! -x "$SOURCE_APP/Contents/MacOS/TopFade" ]]; then
    echo "Build TopFade before testing its installer transaction." >&2
    exit 4
fi

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/topfade-installer.XXXXXX")"
TEST_HOME="$TEST_ROOT/home"
INSTALL_ROOT="$TEST_ROOT/install"
SUPPORT_ROOT="$TEST_HOME/Library/Application Support/TopFade"
DESTINATION="$INSTALL_ROOT/TopFade.app"
PREVIOUS="$INSTALL_ROOT/TopFade.previous.app"
RECEIPT="$SUPPORT_ROOT/install-receipt.json"
EXPECTED_CURRENT="$TEST_ROOT/expected-current.app"
EXPECTED_PREVIOUS="$TEST_ROOT/expected-previous.app"
EXPECTED_RECEIPT="$TEST_ROOT/expected-receipt.json"

cleanup() {
    if [[ "$TEST_ROOT" == "${TMPDIR:-/tmp}"/topfade-installer.* ]]; then
        rm -rf "$TEST_ROOT"
    fi
}
trap cleanup EXIT

seed_populated_fixture() {
    rm -rf "$INSTALL_ROOT" "$SUPPORT_ROOT" "$EXPECTED_CURRENT" "$EXPECTED_PREVIOUS"
    rm -f "$EXPECTED_RECEIPT"
    mkdir -p "$DESTINATION/Contents" "$PREVIOUS/Contents" "$SUPPORT_ROOT"
    printf 'installed-before-test\n' >"$DESTINATION/Contents/fixture-marker.txt"
    printf 'rollback-before-test\n' >"$PREVIOUS/Contents/fixture-marker.txt"
    printf '{"fixture":"receipt-before-test"}\n' >"$RECEIPT"
    ditto "$DESTINATION" "$EXPECTED_CURRENT"
    ditto "$PREVIOUS" "$EXPECTED_PREVIOUS"
    cp "$RECEIPT" "$EXPECTED_RECEIPT"
}

assert_no_transaction_debris() {
    if find "$INSTALL_ROOT" "$SUPPORT_ROOT" -maxdepth 1 \
        \( -name '.TopFade.*' -o -name '.install-receipt.*' \) \
        -print -quit | grep -q .; then
        find "$INSTALL_ROOT" "$SUPPORT_ROOT" -maxdepth 1 \
            \( -name '.TopFade.*' -o -name '.install-receipt.*' \) -print >&2
        echo "Installer transaction debris remained after rollback." >&2
        return 1
    fi
}

run_interrupted_checkpoint() {
    local checkpoint="$1"
    seed_populated_fixture
    local status=0
    HOME="$TEST_HOME" \
    TOPFADE_INSTALL_ROOT="$INSTALL_ROOT" \
    TOPFADE_INSTALL_TEST_MODE=1 \
    TOPFADE_INSTALL_TEST_INTERRUPT_AT="$checkpoint" \
        bash "$INSTALLER" --skip-build >/dev/null 2>&1 || status=$?
    if [[ "$status" -eq 0 ]]; then
        echo "Installer checkpoint '$checkpoint' unexpectedly completed." >&2
        return 1
    fi
    if ! diff -qr "$EXPECTED_CURRENT" "$DESTINATION" >/dev/null; then
        echo "Checkpoint '$checkpoint' did not restore the installed app exactly." >&2
        return 1
    fi
    if ! diff -qr "$EXPECTED_PREVIOUS" "$PREVIOUS" >/dev/null; then
        echo "Checkpoint '$checkpoint' did not restore the rollback app exactly." >&2
        return 1
    fi
    if ! cmp -s "$EXPECTED_RECEIPT" "$RECEIPT"; then
        echo "Checkpoint '$checkpoint' did not restore the install receipt exactly." >&2
        return 1
    fi
    assert_no_transaction_debris
}

for checkpoint in \
    after-snapshots \
    after-current-displaced \
    after-app-promoted \
    after-previous-updated \
    before-receipt-commit; do
    run_interrupted_checkpoint "$checkpoint"
done

# A clean install interrupted after promotion must return to a genuinely empty state.
rm -rf "$INSTALL_ROOT" "$SUPPORT_ROOT"
mkdir -p "$INSTALL_ROOT" "$SUPPORT_ROOT"
CLEAN_STATUS=0
HOME="$TEST_HOME" \
TOPFADE_INSTALL_ROOT="$INSTALL_ROOT" \
TOPFADE_INSTALL_TEST_MODE=1 \
TOPFADE_INSTALL_TEST_INTERRUPT_AT=after-app-promoted \
    bash "$INSTALLER" --skip-build >/dev/null 2>&1 || CLEAN_STATUS=$?
if [[ "$CLEAN_STATUS" -eq 0 || -e "$DESTINATION" || -e "$PREVIOUS" || -e "$RECEIPT" ]]; then
    echo "Interrupted clean installation did not restore an empty pre-install state." >&2
    exit 5
fi
assert_no_transaction_debris

# The successful transaction must promote the exact build and rotate current -> previous.
seed_populated_fixture
HOME="$TEST_HOME" TOPFADE_INSTALL_ROOT="$INSTALL_ROOT" \
    bash "$INSTALLER" --skip-build >/dev/null
if ! diff -qr "$EXPECTED_CURRENT" "$PREVIOUS" >/dev/null; then
    echo "Successful installation did not preserve the former current app as rollback." >&2
    exit 6
fi
SOURCE_SHA256="$(shasum -a 256 "$SOURCE_APP/Contents/MacOS/TopFade" | awk '{print $1}')"
INSTALLED_SHA256="$(shasum -a 256 "$DESTINATION/Contents/MacOS/TopFade" | awk '{print $1}')"
if [[ "$SOURCE_SHA256" != "$INSTALLED_SHA256" ]]; then
    echo "Successful installation did not promote the exact built executable." >&2
    exit 7
fi
if ! grep -Eiq "\"executable_sha256\"[[:space:]]*:[[:space:]]*\"$SOURCE_SHA256\"" "$RECEIPT"; then
    echo "Successful installation receipt is not bound to the promoted executable." >&2
    exit 8
fi
assert_no_transaction_debris

printf '{\n'
printf '  "passed": true,\n'
printf '  "interruption_checkpoints": 5,\n'
printf '  "clean_install_rollback": true,\n'
printf '  "successful_rotation": true,\n'
printf '  "executable_sha256": "%s",\n' "$SOURCE_SHA256"
printf '  "real_home_untouched": true\n'
printf '}\n'
