#!/bin/sh
# KeplerCrew client uninstaller.
# Usage: curl -fsSL https://get.keplercrew.com/uninstall.sh | sh
# Removes the application and frees the license seat.
# Env:
#   KEPLER_INSTALL_DIR   install directory to remove (default: ~/.local/share/keplercrew or $XDG_DATA_HOME/keplercrew)
#   KEPLER_PURGE         set to 1 to ALSO delete your local data (projects, cycles, logs)
#   KEPLER_KEEP_LICENSE  set to 1 to keep the seat activated (reinstalling on this same machine)
#   KEPLER_YES           set to 1 to skip the confirmation prompt (unattended)
# Author: aichargelabs.

set -eu

# 0. Resolve the install directory (same precedence as install.sh) and the data
#    directory. The data dir is APEX_HOME as set by the bundled run.sh - it is
#    NOT inside the install dir, so removing one never removes the other.
if [ -n "${KEPLER_INSTALL_DIR:-}" ]; then
    INSTALL_DIR="$KEPLER_INSTALL_DIR"
elif [ -n "${XDG_DATA_HOME:-}" ]; then
    INSTALL_DIR="$XDG_DATA_HOME/keplercrew"
else
    INSTALL_DIR="$HOME/.local/share/keplercrew"
fi
DATA_DIR="${APEX_HOME:-$HOME/.kepler-trial}"
LICENSE_FILE="$INSTALL_DIR/licenses/customer.key"
ENGINE="$INSTALL_DIR/engine/kepler-engine"

if [ ! -d "$INSTALL_DIR" ]; then
    echo "No KeplerCrew install found at $INSTALL_DIR - nothing to uninstall."
    if [ -d "$DATA_DIR" ]; then
        echo "Your data is still at $DATA_DIR. Remove it with:"
        echo "  rm -rf \"$DATA_DIR\""
    fi
    exit 0
fi

# 1. Confirm. This deletes software and (optionally) work, so an accidental paste
#    must not be enough. Piped through sh, stdin is the script - prompt on the tty.
if [ "${KEPLER_YES:-}" != "1" ]; then
    echo ""
    echo "This will uninstall KeplerCrew:"
    echo "  - stop the app and remove $INSTALL_DIR"
    echo "  - free your license seat so the key can be used on another machine"
    if [ "${KEPLER_PURGE:-}" = "1" ]; then
        echo "  - DELETE your data: $DATA_DIR (projects, cycles, logs)"
    else
        echo "  - KEEP your data: $DATA_DIR"
        echo "  - remove the downloaded local model (it is fetched again on reinstall)"
    fi
    echo ""
    if [ -r /dev/tty ]; then
        printf 'Type yes to continue: '
        read -r answer </dev/tty
    else
        echo "No terminal available. Re-run with KEPLER_YES=1 to confirm:"
        echo "  curl -fsSL https://get.keplercrew.com/uninstall.sh | KEPLER_YES=1 sh"
        exit 0
    fi
    if [ "$answer" != "yes" ]; then
        echo "Cancelled - nothing was changed."
        exit 0
    fi
fi

# 2. Stop anything running FROM THIS INSTALL DIR. Matching on the full binary path
#    means a second install (or an unrelated process) is never touched.
for binary in "$INSTALL_DIR/backend/kepler-backend" "$INSTALL_DIR/engine/kepler-engine"     "$INSTALL_DIR/assistant/llama/llama-server"; do
    if pgrep -f "^$binary" >/dev/null 2>&1; then
        echo "Stopping KeplerCrew..."
        pkill -f "^$binary" >/dev/null 2>&1 || true
    fi
done
sleep 1

# 3. Free the license seat BEFORE deleting anything - the key lives in the install
#    dir and the activated machine id in the data dir, so once either is gone the
#    seat can only be released by support.
if [ "${KEPLER_KEEP_LICENSE:-}" = "1" ]; then
    echo "Keeping the license seat activated (KEPLER_KEEP_LICENSE=1)."
elif [ -x "$ENGINE" ] && [ -f "$LICENSE_FILE" ]; then
    echo "Freeing the license seat..."
    # Never fatal: an offline or air-gapped machine must still be able to uninstall.
    if ! APEX_HOME="$DATA_DIR" KEPLER_LICENSE_KEY="$(cat "$LICENSE_FILE")" "$ENGINE" license deactivate; then
        echo ""
        echo "Could not free the license seat."
        echo "Your key is still activated on this machine. Email support@aichargelabs.com"
        echo "to release it, or the next install with this key may be refused."
        echo ""
    fi
else
    echo "No license key stored here - skipping seat release."
fi

# 4. Remove the application.
if rm -rf "$INSTALL_DIR"; then
    echo "Removed $INSTALL_DIR"
else
    echo ""
    echo "Could not remove $INSTALL_DIR - a file is still in use."
    echo "Close any running KeplerCrew and run:"
    echo "  rm -rf \"$INSTALL_DIR\""
    echo ""
fi

# Clean up the staging leftovers the installer may have left next door
# (install.sh stages at "$INSTALL_DIR.new-<pid>" and swaps via "$INSTALL_DIR.old").
rm -rf "$INSTALL_DIR.old" 2>/dev/null || true
for leftover in "$INSTALL_DIR".new-*; do
    if [ -d "$leftover" ]; then rm -rf "$leftover"; fi
done

# 4b. The local model is a re-downloadable cache (~2.5 GB), not user data.
if [ "${KEPLER_PURGE:-}" != "1" ] && [ -d "$DATA_DIR/models" ]; then
    rm -rf "$DATA_DIR/models" && echo "Removed the downloaded local model: $DATA_DIR/models"
fi

# 5. Data: deleted only on an explicit opt-in.
if [ -d "$DATA_DIR" ]; then
    if [ "${KEPLER_PURGE:-}" = "1" ]; then
        rm -rf "$DATA_DIR" && echo "Removed your data: $DATA_DIR"
    else
        echo ""
        echo "Your projects and history were kept at $DATA_DIR"
        echo "Reinstalling picks them up again. To delete them:"
        echo "  rm -rf \"$DATA_DIR\""
    fi
fi

echo ""
echo "KeplerCrew uninstalled."
echo "Reinstall any time: curl -fsSL https://get.keplercrew.com/install.sh | sh"

exit 0
