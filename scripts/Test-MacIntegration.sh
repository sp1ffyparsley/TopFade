#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/macos/TopFade.app"
VALIDATION_ROOT="$ROOT/dist/macos/integration-profile"
RECEIPT="$VALIDATION_ROOT/integration-receipt.json"
INSTALLER_RECEIPT="$VALIDATION_ROOT/installer-transaction.json"
BUILD_RECEIPT="$ROOT/dist/macos/build-receipt.json"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Test-MacIntegration.sh must run on macOS." >&2
    exit 2
fi
if pgrep -x TopFade >/dev/null 2>&1; then
    echo "Close the running TopFade process before integration testing." >&2
    exit 3
fi
if pgrep -x TextEdit >/dev/null 2>&1; then
    echo "Close TextEdit before integration testing; the verifier will not touch an existing session." >&2
    exit 4
fi

if [[ "$VALIDATION_ROOT" != "$ROOT/dist/macos/integration-profile" ]]; then
    echo "Refusing to reset an unexpected validation path." >&2
    exit 6
fi
rm -rf "$VALIDATION_ROOT"
mkdir -p "$VALIDATION_ROOT"

bash "$ROOT/scripts/Build-Mac.sh"
EXECUTABLE="$APP/Contents/MacOS/TopFade"
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "TopFade app executable was not produced." >&2
    exit 5
fi
if [[ ! -f "$BUILD_RECEIPT" ]]; then
    echo "TopFade build receipt was not produced." >&2
    exit 5
fi

EXPECTED_BYTES="$(stat -f '%z' "$EXECUTABLE")"
EXPECTED_SHA256="$(shasum -a 256 "$EXECUTABLE" | awk '{print $1}')"
receipt_matches_identity() {
    local receipt="$1"
    grep -Eq "\"executable_bytes\"[[:space:]]*:[[:space:]]*$EXPECTED_BYTES([[:space:]]*,|[[:space:]]*$)" "$receipt" \
        && grep -Eiq "\"executable_sha256\"[[:space:]]*:[[:space:]]*\"$EXPECTED_SHA256\"" "$receipt"
}
if ! receipt_matches_identity "$BUILD_RECEIPT"; then
    cat "$BUILD_RECEIPT"
    echo "The built app does not match its build receipt." >&2
    exit 5
fi

SELF_TEST_EXIT=0
TOPFADE_SELF_TEST_ROOT="$VALIDATION_ROOT" \
TOPFADE_SELF_TEST_RECEIPT="$RECEIPT" \
    "$EXECUTABLE" --self-test || SELF_TEST_EXIT=$?

INSTALLER_TEST_EXIT=0
bash "$ROOT/scripts/Test-MacInstallerTransaction.sh" --skip-build \
    >"$INSTALLER_RECEIPT" || INSTALLER_TEST_EXIT=$?

FAILURES=()
if [[ "$SELF_TEST_EXIT" -ne 0 ]]; then
    FAILURES+=("TopFade self-test exited with status $SELF_TEST_EXIT.")
fi
if [[ "$INSTALLER_TEST_EXIT" -ne 0 ]]; then
    FAILURES+=("TopFade installer transaction test exited with status $INSTALLER_TEST_EXIT.")
elif ! grep -q '"passed"[[:space:]]*:[[:space:]]*true' "$INSTALLER_RECEIPT"; then
    FAILURES+=("TopFade installer transaction test did not produce a passing receipt.")
fi
if [[ ! -f "$RECEIPT" ]]; then
    FAILURES+=("TopFade did not write its macOS integration receipt.")
else
    if ! grep -q '"passed"[[:space:]]*:[[:space:]]*true' "$RECEIPT"; then
        FAILURES+=("TopFade macOS integration reported failure.")
    fi
    if ! grep -q '"textedit_cleanup_completed"[[:space:]]*:[[:space:]]*true' "$RECEIPT" \
        || ! grep -q '"fixture_cleanup_completed"[[:space:]]*:[[:space:]]*true' "$RECEIPT" \
        || ! grep -q '"production_preferences_unchanged"[[:space:]]*:[[:space:]]*true' "$RECEIPT" \
        || ! grep -q '"isolated_preferences_removed"[[:space:]]*:[[:space:]]*true' "$RECEIPT" \
        || ! grep -q '"remembered_state_legacy_migrated"[[:space:]]*:[[:space:]]*true' "$RECEIPT" \
        || ! grep -q '"remembered_same_title_records_preserved"[[:space:]]*:[[:space:]]*true' "$RECEIPT" \
        || ! grep -q '"scroll_outside_replica_ignored"[[:space:]]*:[[:space:]]*true' "$RECEIPT"; then
        FAILURES+=("Integration isolation, cleanup, or outside-scroll checks did not all pass.")
    fi
    if ! receipt_matches_identity "$RECEIPT"; then
        FAILURES+=("The self-test receipt is not bound to the executable that was built and run.")
    fi
fi

FINAL_BYTES="$(stat -f '%z' "$EXECUTABLE")"
FINAL_SHA256="$(shasum -a 256 "$EXECUTABLE" | awk '{print $1}')"
if [[ "$FINAL_BYTES" != "$EXPECTED_BYTES" || "$FINAL_SHA256" != "$EXPECTED_SHA256" ]]; then
    FAILURES+=("The TopFade executable changed while integration qualification was running.")
fi
if [[ ! -d "$VALIDATION_ROOT/Logs" ]]; then
    FAILURES+=("TopFade did not keep integration logs inside the isolated validation profile.")
fi
if pgrep -x TextEdit >/dev/null 2>&1; then
    FAILURES+=("TopFade macOS integration left its TextEdit process running.")
fi
if pgrep -x TopFade >/dev/null 2>&1; then
    FAILURES+=("TopFade macOS integration left its own process running.")
fi

if [[ "${#FAILURES[@]}" -ne 0 ]]; then
    if [[ -f "$RECEIPT" ]]; then
        cat "$RECEIPT"
    fi
    printf '%s\n' "${FAILURES[@]}" >&2
    exit 8
fi
cat "$RECEIPT"
