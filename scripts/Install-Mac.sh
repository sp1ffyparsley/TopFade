#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_APP="$ROOT/dist/macos/TopFade.app"
BUILD_RECEIPT="$ROOT/dist/macos/build-receipt.json"
INSTALL_ROOT="${TOPFADE_INSTALL_ROOT:-$HOME/Applications}"
DESTINATION="$INSTALL_ROOT/TopFade.app"
PREVIOUS="$INSTALL_ROOT/TopFade.previous.app"
SUPPORT_ROOT="$HOME/Library/Application Support/TopFade"
LOG_ROOT="$HOME/Library/Logs/TopFade"
PREFERENCES_FILE="$HOME/Library/Preferences/com.tavito.topfade.plist"
SAVED_STATE_ROOT="$HOME/Library/Saved Application State/com.tavito.topfade.savedState"

SKIP_BUILD=0
LAUNCH=0
UNINSTALL=0
REMOVE_DATA=0
for argument in "$@"; do
    case "$argument" in
        --skip-build) SKIP_BUILD=1 ;;
        --launch) LAUNCH=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --remove-data) REMOVE_DATA=1 ;;
        *)
            echo "Unknown argument: $argument" >&2
            echo "Usage: Install-Mac.sh [--skip-build] [--launch] [--uninstall] [--remove-data]" >&2
            exit 2
            ;;
    esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Install-Mac.sh must run on macOS." >&2
    exit 3
fi
if [[ "$DESTINATION" != "$INSTALL_ROOT/TopFade.app" || "$PREVIOUS" != "$INSTALL_ROOT/TopFade.previous.app" ]]; then
    echo "Refusing to modify an unexpected installation path." >&2
    exit 4
fi
if [[ "$SUPPORT_ROOT" != "$HOME/Library/Application Support/TopFade" \
    || "$LOG_ROOT" != "$HOME/Library/Logs/TopFade" \
    || "$PREFERENCES_FILE" != "$HOME/Library/Preferences/com.tavito.topfade.plist" \
    || "$SAVED_STATE_ROOT" != "$HOME/Library/Saved Application State/com.tavito.topfade.savedState" ]]; then
    echo "Refusing to modify an unexpected TopFade data path." >&2
    exit 5
fi

stop_installed_topfade() {
    local installed_binary="$DESTINATION/Contents/MacOS/TopFade"
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        local command
        command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        if [[ "$command" == "$installed_binary"* ]]; then
            kill -TERM "$pid" 2>/dev/null || true
            for _ in {1..25}; do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.2
            done
            if kill -0 "$pid" 2>/dev/null; then
                echo "Installed TopFade did not exit within five seconds (PID $pid)." >&2
                return 1
            fi
        fi
    done < <(pgrep -x TopFade 2>/dev/null || true)
}

if [[ "$UNINSTALL" -eq 1 ]]; then
    stop_installed_topfade
    if [[ -x "$DESTINATION/Contents/MacOS/TopFade" ]]; then
        if ! "$DESTINATION/Contents/MacOS/TopFade" --unregister-login; then
            echo "TopFade was not removed because launch-at-login cleanup failed." >&2
            exit 8
        fi
    fi
    rm -rf "$DESTINATION" "$PREVIOUS"
    if [[ "$REMOVE_DATA" -eq 1 ]]; then
        defaults delete com.tavito.topfade >/dev/null 2>&1 || true
        rm -rf "$SUPPORT_ROOT" "$LOG_ROOT" "$SAVED_STATE_ROOT"
        rm -f "$PREFERENCES_FILE"
    fi
    printf '{\n  "action": "uninstall",\n  "application_removed": true,\n  "data_preserved": %s,\n  "windowtop_untouched": true\n}\n' \
        "$([[ "$REMOVE_DATA" -eq 1 ]] && echo false || echo true)"
    exit 0
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    bash "$ROOT/scripts/Build-Mac.sh"
fi
if [[ ! -d "$SOURCE_APP" || ! -x "$SOURCE_APP/Contents/MacOS/TopFade" ]]; then
    echo "Built app bundle was not found: $SOURCE_APP" >&2
    exit 6
fi
codesign --verify --deep --strict "$SOURCE_APP"

stop_installed_topfade
mkdir -p "$INSTALL_ROOT" "$SUPPORT_ROOT"
STAGED="$INSTALL_ROOT/.TopFade.app.stage.$$"
FAILED="$INSTALL_ROOT/.TopFade.app.failed.$$"
CURRENT_BACKUP="$INSTALL_ROOT/.TopFade.app.backup.$$"
PREVIOUS_BACKUP="$INSTALL_ROOT/.TopFade.previous.app.backup.$$"
RECEIPT="$SUPPORT_ROOT/install-receipt.json"
RECEIPT_BACKUP="$SUPPORT_ROOT/.install-receipt.backup.$$"
RECEIPT_STAGE="$SUPPORT_ROOT/.install-receipt.stage.$$"

HAD_DESTINATION=0
HAD_PREVIOUS=0
HAD_RECEIPT=0
TRANSACTION_ACTIVE=0
INSTALL_COMMITTED=0

maybe_interrupt_for_test() {
    local checkpoint="$1"
    if [[ "${TOPFADE_INSTALL_TEST_MODE:-0}" == "1" \
        && "${TOPFADE_INSTALL_TEST_INTERRUPT_AT:-}" == "$checkpoint" ]]; then
        kill -TERM "$$"
        sleep 1
    fi
}

rollback_install() {
    local failed=0
    if ! rm -rf "$DESTINATION" "$PREVIOUS" "$FAILED"; then
        failed=1
    fi
    if [[ "$HAD_DESTINATION" -eq 1 ]] \
        && ! ditto "$CURRENT_BACKUP" "$DESTINATION"; then
        failed=1
    fi
    if [[ "$HAD_PREVIOUS" -eq 1 ]] \
        && ! ditto "$PREVIOUS_BACKUP" "$PREVIOUS"; then
        failed=1
    fi
    if [[ "$HAD_RECEIPT" -eq 1 ]]; then
        if ! cp "$RECEIPT_BACKUP" "$RECEIPT"; then
            failed=1
        fi
    elif ! rm -f "$RECEIPT"; then
        failed=1
    fi
    if [[ "$failed" -eq 0 ]]; then
        if [[ -d "$DESTINATION" ]]; then
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
                -f "$DESTINATION" >/dev/null 2>&1 || true
        fi
        TRANSACTION_ACTIVE=0
    fi
    return "$failed"
}

on_exit() {
    local status=$?
    trap - EXIT
    trap '' HUP INT TERM
    set +e
    if [[ "$TRANSACTION_ACTIVE" -eq 1 && "$INSTALL_COMMITTED" -eq 0 ]]; then
        if rollback_install; then
            echo "TopFade installation did not complete; the prior app, rollback slot, and receipt were restored." >&2
        else
            echo "TopFade installation rollback failed; preserved backups remain under $INSTALL_ROOT and $SUPPORT_ROOT." >&2
        fi
        if [[ "$status" -eq 0 ]]; then
            status=1
        fi
    fi
    rm -rf "$STAGED"
    rm -f "$RECEIPT_STAGE"
    if [[ "$TRANSACTION_ACTIVE" -eq 0 || "$INSTALL_COMMITTED" -eq 1 ]]; then
        rm -rf "$FAILED" "$CURRENT_BACKUP" "$PREVIOUS_BACKUP"
        rm -f "$RECEIPT_BACKUP"
    fi
    exit "$status"
}

trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

rm -rf "$STAGED" "$FAILED" "$CURRENT_BACKUP" "$PREVIOUS_BACKUP"
rm -f "$RECEIPT_BACKUP" "$RECEIPT_STAGE"
ditto "$SOURCE_APP" "$STAGED"
codesign --verify --deep --strict "$STAGED"

SOURCE_EXECUTABLE="$SOURCE_APP/Contents/MacOS/TopFade"
STAGED_EXECUTABLE="$STAGED/Contents/MacOS/TopFade"
SOURCE_BYTES="$(stat -f '%z' "$SOURCE_EXECUTABLE")"
STAGED_BYTES="$(stat -f '%z' "$STAGED_EXECUTABLE")"
SOURCE_SHA256="$(shasum -a 256 "$SOURCE_EXECUTABLE" | awk '{print $1}')"
STAGED_SHA256="$(shasum -a 256 "$STAGED_EXECUTABLE" | awk '{print $1}')"
if [[ "$SOURCE_BYTES" != "$STAGED_BYTES" || "$SOURCE_SHA256" != "$STAGED_SHA256" ]]; then
    echo "Staged TopFade executable does not match the built source artifact." >&2
    exit 7
fi
if [[ ! -f "$BUILD_RECEIPT" ]] \
    || ! grep -Eq "\"executable_bytes\"[[:space:]]*:[[:space:]]*$SOURCE_BYTES([[:space:]]*,|[[:space:]]*$)" "$BUILD_RECEIPT" \
    || ! grep -Eiq "\"executable_sha256\"[[:space:]]*:[[:space:]]*\"$SOURCE_SHA256\"" "$BUILD_RECEIPT"; then
    echo "The source app does not match its build receipt; rebuild before installing." >&2
    exit 7
fi

if [[ -f "$RECEIPT" ]]; then
    cp "$RECEIPT" "$RECEIPT_BACKUP"
    HAD_RECEIPT=1
fi
if [[ -d "$PREVIOUS" ]]; then
    ditto "$PREVIOUS" "$PREVIOUS_BACKUP"
    HAD_PREVIOUS=1
fi
if [[ -d "$DESTINATION" ]]; then
    ditto "$DESTINATION" "$CURRENT_BACKUP"
    HAD_DESTINATION=1
fi
TRANSACTION_ACTIVE=1
maybe_interrupt_for_test "after-snapshots"

if [[ "$HAD_DESTINATION" -eq 1 ]]; then
    mv "$DESTINATION" "$FAILED"
    maybe_interrupt_for_test "after-current-displaced"
fi
mv "$STAGED" "$DESTINATION"
maybe_interrupt_for_test "after-app-promoted"
if [[ "$HAD_DESTINATION" -eq 1 ]]; then
    rm -rf "$PREVIOUS"
    mv "$FAILED" "$PREVIOUS"
fi
maybe_interrupt_for_test "after-previous-updated"

finalize_install() {
    codesign --verify --deep --strict "$DESTINATION" || return 1
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$DESTINATION" >/dev/null || return 1

    local executable="$DESTINATION/Contents/MacOS/TopFade"
    local bytes sha256 installed_utc
    bytes="$(stat -f '%z' "$executable")" || return 1
    sha256="$(shasum -a 256 "$executable" | awk '{print $1}')" || return 1
    if [[ "$bytes" != "$SOURCE_BYTES" || "$sha256" != "$SOURCE_SHA256" ]]; then
        echo "Installed TopFade executable does not match the built source artifact." >&2
        return 1
    fi
    installed_utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || return 1
    cat >"$RECEIPT_STAGE" <<EOF || return 1
{
  "action": "install",
  "installed_utc": "$installed_utc",
  "source": "$SOURCE_APP",
  "destination": "$DESTINATION",
  "executable_bytes": $bytes,
  "source_executable_sha256": "$SOURCE_SHA256",
  "staged_executable_sha256": "$STAGED_SHA256",
  "executable_sha256": "$sha256",
  "previous_app_preserved": $([[ -d "$PREVIOUS" ]] && echo true || echo false),
  "data_preserved": true,
  "windowtop_untouched": true
}
EOF
    maybe_interrupt_for_test "before-receipt-commit"
    mv "$RECEIPT_STAGE" "$RECEIPT" || return 1
}

if ! finalize_install; then
    echo "TopFade post-install verification failed." >&2
    exit 8
fi

INSTALL_COMMITTED=1
TRANSACTION_ACTIVE=0
rm -rf "$CURRENT_BACKUP" "$PREVIOUS_BACKUP" "$FAILED"
rm -f "$RECEIPT_BACKUP"

if [[ "$LAUNCH" -eq 1 ]]; then
    if ! open "$DESTINATION"; then
        echo "TopFade installed successfully but could not be launched automatically." >&2
        exit 10
    fi
fi
cat "$RECEIPT"
