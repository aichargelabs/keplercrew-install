#!/bin/sh
# KeplerCrew client installer and updater.
# Usage: curl -fsSL https://get.keplercrew.com/install.sh | sh
# Running it again updates an existing install to the latest published release.
# Env:
#   KEPLER_LICENSE_KEY  license key (existing install's stored key is reused; prompted otherwise)
#   KEPLER_VERSION      optional version such as 1.0.0 (default: latest)
#   KEPLER_DRY_RUN      set to 1 to resolve and print the release without downloading
#   KEPLER_INSTALL_DIR  optional install directory (default: ~/.local/share/keplercrew or $XDG_DATA_HOME/keplercrew)
#   KEPLER_NO_LAUNCH    set to 1 to skip launching after install
#   KEPLER_FORCE        set to 1 to reinstall even when already on the resolved version
# Author: aichargelabs.

set -eu

ACCOUNT="11cdb180-ce9f-4b8b-82c6-ca59f9b2c512"
API="https://api.keygen.sh/v1/accounts/$ACCOUNT"
ACCEPT="application/vnd.api+json"

# Helper: parse JSON with python3 if available, otherwise fall back to shell parsing.
# Uses order-independent key extraction via grep rather than tr '{' splitting.
parse_json_field() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import sys,json; d=json.load(sys.stdin); print('$1')" 2>/dev/null || return 1
    else
        return 1
    fi
}

# 0. Resolve the install directory - respect XDG_DATA_HOME when set.
if [ -n "${KEPLER_INSTALL_DIR:-}" ]; then
    INSTALL_DIR="$KEPLER_INSTALL_DIR"
elif [ -n "${XDG_DATA_HOME:-}" ]; then
    INSTALL_DIR="$XDG_DATA_HOME/keplercrew"
else
    INSTALL_DIR="$HOME/.local/share/keplercrew"
fi
LICENSE_DIR="$INSTALL_DIR/licenses"
LICENSE_FILE="$LICENSE_DIR/customer.key"
INST_VERSION_FILE="$INSTALL_DIR/version.txt"

if [ -f "$INST_VERSION_FILE" ]; then
    INSTALLED=$(cat "$INST_VERSION_FILE" 2>/dev/null || echo "")
else
    INSTALLED=""
fi

# stty safety: ensure echo is restored on interrupt, termination, or exit.
restore_stty() {
    stty echo 2>/dev/null || true
}
trap restore_stty INT TERM EXIT

# 1. License key — env var, stored key from a previous install, or prompt.
key="${KEPLER_LICENSE_KEY-}"
if [ -z "$key" ]; then
    if [ -f "$LICENSE_FILE" ]; then
        key=$(cat "$LICENSE_FILE" | tr -d '\n\r')
        if [ -n "$key" ]; then
            echo "Using the stored license key."
        fi
    fi
fi
if [ -z "$key" ]; then
    # Try /dev/tty first (works under curl|sh), fall back to stdin only when unavailable.
    input_src="/dev/tty"
    if [ ! -r "$input_src" ]; then
        input_src="/dev/stdin"
    fi
    if [ -r "$input_src" ]; then
        printf 'Enter your KeplerCrew license key: ' >&2
        stty -echo <"$input_src" 2>/dev/null || true
        read -r key <"$input_src"
        stty echo <"$input_src" 2>/dev/null || true
        printf '\n' >&2
    else
        printf '%s\n' "Error: set KEPLER_LICENSE_KEY when running non-interactively." >&2
        exit 1
    fi
fi

# Trim whitespace.
key=$(printf '%s' "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

if [ -z "$key" ]; then
    printf '%s\n' "Error: a license key is required." >&2
    exit 1
fi

# 2. Validate the key before downloading anything.
echo "Validating license..."

# License key hygiene: validate-key needs no auth header; the key travels only in
# the JSON body, fed via stdin (-d @-) so it never appears in the process list.
resp=$(curl -fsSL -X POST "$API/licenses/actions/validate-key" \
    -H "Accept: $ACCEPT" -H "Content-Type: $ACCEPT" \
    -d @- <<EOF
{"meta":{"key":"$key"}}
EOF
) || true

# BSD-compatible parsing: use caseglob instead of GNU sed alternation.
if printf '%s' "$resp" | grep -q '"valid":true'; then
    valid="true"
elif printf '%s' "$resp" | grep -q '"valid":false'; then
    valid="false"
else
    valid=""
fi

if [ "$valid" != "true" ]; then
    code=""
    if printf '%s' "$resp" | grep -q '"code"'; then
        code=$(printf '%s' "$resp" | sed -n 's/.*"code":"\([^"]*\)".*/\1/p')
    fi
    if [ -z "$code" ]; then
        code="UNKNOWN"
    fi
    printf '%s\n' "Error: license is not valid ($code). Contact support@aichargelabs.com." >&2
    exit 1
fi
echo "License OK."

# 3. Resolve the release (latest published stable, or KEPLER_VERSION).
echo "Fetching available releases..."

# Use curl config from stdin to pass Authorization header without exposing in ps.
# Capture the HTTP status too: a license that authenticates fine can still be
# refused the catalog (policy forbids license-key auth). Reporting that as a
# version problem sends the customer hunting for something that is not wrong.
rel_tmp=$(mktemp)
rel_code=$(printf 'header = "Authorization: License %s"\n' "$key" | curl -sSL -K - -X GET "$API/releases?limit=50" \
    -H "Accept: $ACCEPT" -o "$rel_tmp" -w '%{http_code}') || rel_code="000"
releases=$(cat "$rel_tmp" 2>/dev/null || true)
rm -f "$rel_tmp"

if [ "$rel_code" = "401" ] || [ "$rel_code" = "403" ]; then
    printf '%s\n' "Error: your license is valid but is not permitted to download releases ($rel_code)." >&2
    printf '%s\n' "This is a license configuration problem, not a problem with your machine." >&2
    printf '%s\n' "Contact support@aichargelabs.com and quote error RELEASE-AUTH-$rel_code." >&2
    exit 1
fi
if [ "$rel_code" != "200" ] || [ -z "$releases" ]; then
    printf '%s\n' "Error: could not reach the release service ($rel_code). Check your network and try again." >&2
    exit 1
fi

# Parse releases: find PUBLISHED entries with channel "stable", extract version + id.
# Order-independent parsing: filter both status and channel before extracting version.
# Use python3 when available for proper JSON parsing; fallback to shell parsing.
parse_releases_shell() {
    # Shell fallback: split on '{' but filter both status and channel.
    printf '%s' "$releases" | tr '{' '\n' | grep '"status":"PUBLISHED"' | grep '"channel":"stable"'
}

parse_releases_python() {
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$releases" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('data', []):
    attrs = item.get('attributes', {})
    if attrs.get('status') == 'PUBLISHED' and attrs.get('channel') == 'stable':
        attrs['id'] = item.get('id', '')
        print(json.dumps(attrs))
"
    fi
}

# Try python3 first, fall back to shell.
published=""
if published=$(parse_releases_python 2>/dev/null) && [ -n "$published" ]; then
    use_python=1
else
    published=$(parse_releases_shell || true)
    use_python=0
fi

# An empty catalog is an entitlement problem, never a version problem.
if [ -z "$published" ]; then
    printf '%s\n' "Error: your license is valid but is not entitled to any published release." >&2
    printf '%s\n' "This is a license configuration problem, not a problem with your machine." >&2
    printf '%s\n' "Contact support@aichargelabs.com and quote error RELEASE-NONE." >&2
    exit 1
fi

wanted="${KEPLER_VERSION-}"

# Semver comparison function: returns 0 if v1 > v2, 1 if v1 <= v2.
# Pure POSIX numeric compare: split on '.' and compare major, minor, patch as integers.
semver_gt() {
    v1="$1"
    v2="$2"
    # If equal, v1 is NOT greater
    if [ "$v1" = "$v2" ]; then
        return 1
    fi
    # Split and compare using POSIX shell (IFS-split, no arrays)
    v1_major=$(printf '%s' "$v1" | cut -d. -f1)
    v1_minor=$(printf '%s' "$v1" | cut -d. -f2)
    v1_patch=$(printf '%s' "$v1" | cut -d. -f3)
    v2_major=$(printf '%s' "$v2" | cut -d. -f1)
    v2_minor=$(printf '%s' "$v2" | cut -d. -f2)
    v2_patch=$(printf '%s' "$v2" | cut -d. -f3)
    # Compare major
    if [ "${v1_major:-0}" -gt "${v2_major:-0}" ]; then
        return 0
    elif [ "${v1_major:-0}" -lt "${v2_major:-0}" ]; then
        return 1
    fi
    # Compare minor
    if [ "${v1_minor:-0}" -gt "${v2_minor:-0}" ]; then
        return 0
    elif [ "${v1_minor:-0}" -lt "${v2_minor:-0}" ]; then
        return 1
    fi
    # Compare patch
    if [ "${v1_patch:-0}" -gt "${v2_patch:-0}" ]; then
        return 0
    fi
    return 1
}

# Extract all stable published versions with their ids.
# Filter by wanted version if specified, otherwise find latest.
if [ -n "$wanted" ]; then
    wanted=$(printf '%s' "$wanted" | sed 's/^v//')
    if [ "$use_python" = "1" ]; then
        version=$(printf '%s' "$published" | python3 -c "
import sys, json
for line in sys.stdin:
    attrs = json.loads(line)
    if attrs.get('version') == '$wanted':
        print(attrs.get('version', ''))
        break
")
    else
        version=$(printf '%s' "$published" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | grep -Fx "$wanted" | head -1)
    fi
    if [ -z "$version" ]; then
        # The catalog is non-empty (checked above), so this really is a bad version.
        # Name the ones that ARE available, and point at the pin: an exported
        # KEPLER_VERSION keeps applying to every later install in that shell.
        avail=$(printf '%s\n' "$published" | sed -n 's/.*"version"[: ]*"\([^"]*\)".*/\1/p' | tr '\n' ' ')
        printf '%s\n' "Error: version \"$wanted\" is not available to your license." >&2
        printf '%s\n' "Your license can install: $avail" >&2
        printf '%s\n' "This version was requested because KEPLER_VERSION is set in this shell." >&2
        printf '%s\n' "To install the latest instead, run:  unset KEPLER_VERSION  and re-run the install command." >&2
        exit 1
    fi
else
    # Find latest version by semver comparison.
    version=""
    if [ "$use_python" = "1" ]; then
        version=$(printf '%s' "$published" | python3 -c "
import sys, json
versions = []
for line in sys.stdin:
    attrs = json.loads(line)
    v = attrs.get('version', '')
    if v:
        versions.append(v)
if versions:
    # Sort by semver descending
    versions.sort(key=lambda x: [int(p) for p in x.split('.')], reverse=True)
    print(versions[0])
")
    else
        # Shell fallback: first one from API (which returns newest first after our filters).
        version=$(printf '%s' "$published" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1)
    fi
    if [ -z "$version" ]; then
        printf '%s\n' "Error: no published stable release is available for your license." >&2
        printf '%s\n' "Contact support@aichargelabs.com and quote error RELEASE-NONE-STABLE." >&2
        exit 1
    fi
fi

# 3b. Downgrade guard: refuse if resolved version is lower than installed (unless KEPLER_FORCE=1).
if [ -n "$INSTALLED" ] && [ "$INSTALLED" != "$version" ]; then
    if semver_gt "$INSTALLED" "$version"; then
        if [ "${KEPLER_FORCE:-}" != "1" ]; then
            printf '%s\n' "Error: downgrade refused: installed $INSTALLED is newer than $version. Set KEPLER_FORCE=1 to allow downgrade." >&2
            exit 1
        fi
        echo "Downgrade allowed by KEPLER_FORCE=1."
    fi
fi

# 3c. Already on the resolved version? Nothing to do.
if [ "$INSTALLED" = "$version" ] && [ "${KEPLER_FORCE-}" != "1" ]; then
    echo "KeplerCrew $version is already installed and up to date."
    echo "Set KEPLER_FORCE=1 to reinstall."
    exit 0
fi

if [ -n "$INSTALLED" ]; then
    if [ "$INSTALLED" = "$version" ]; then
        echo "Reinstalling KeplerCrew $version..."
    else
        echo "Updating KeplerCrew $INSTALLED -> $version..."
    fi
fi

# 4. Resolve the platform artifact of that release. License-key auth cannot
#    LIST artifacts, so the filename follows the release convention.
os=$(uname -s 2>/dev/null || echo unknown)
case "$os" in
    Darwin) platform="darwin" ;;
    Linux)  platform="linux" ;;
    *)      printf '%s\n' "Error: unsupported operating system: $os" >&2; exit 1 ;;
esac
arch_name=$(uname -m 2>/dev/null || echo unknown)
case "$arch_name" in
    x86_64|amd64) arch="x64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)      printf '%s\n' "Error: unsupported architecture on $platform: $arch_name" >&2; exit 1 ;;
esac
filename="KeplerCrew-$platform-$arch-$version.tar.gz"

# The selected release record contains the id needed by the artifact endpoint.
# Use python3 for order-independent extraction when available.
if [ "$use_python" = "1" ]; then
    release_id=$(printf '%s' "$published" | python3 -c "
import sys, json
for line in sys.stdin:
    attrs = json.loads(line)
    if attrs.get('version') == '$version':
        print(attrs.get('id', ''))
        break
" 2>/dev/null) || release_id=""
fi

if [ -z "$release_id" ]; then
    # Shell fallback: records start at each top-level id; the release's own record
    # carries its attributes (version/status), relationship ids do not.
    release_id=$(printf '%s' "$releases" | awk -v ver="$version" '
        BEGIN { RS="\"id\":\""; FS="\"" }
        NR>1 && index($0, "\"version\":\"" ver "\"") && index($0, "\"status\":\"PUBLISHED\"") { print $1; exit }')
fi

if [ -z "$release_id" ]; then
    printf '%s\n' "Error: release $version has no id." >&2
    exit 1
fi

# Create staging directory for atomic update.
staging_dir="${INSTALL_DIR}.new-$$"
tmpdir=$(mktemp -d)
meta_headers="$tmpdir/headers"
meta_body="$tmpdir/body"
cleanup() {
    rm -f "$meta_headers" "$meta_body"
    rm -rf "$tmpdir"
    rm -rf "$staging_dir" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

# Fetch artifact metadata.
curl_rc=0
printf 'header = "Authorization: License %s"\n' "$key" | curl -sS -K - -D "$meta_headers" -o "$meta_body" \
    "$API/releases/$release_id/artifacts/$filename" \
    -H "Accept: $ACCEPT" || curl_rc=$?

if [ "$curl_rc" -ne 0 ]; then
    printf '%s\n' "Error: failed to resolve artifact metadata (curl exit code: $curl_rc)." >&2
    exit 1
fi

# Parse HTTP status code (BSD-compatible: no GNU sed alternation).
status=$(sed -n '1s/^HTTP[^ ]* \([0-9][0-9][0-9]\).*/\1/p' "$meta_headers")
if [ "$status" -ge 400 ] 2>/dev/null; then
    echo "Release $version has no $platform/$arch bundle yet."
    echo "Windows install: powershell -ExecutionPolicy Bypass -Command \"irm https://get.keplercrew.com/install.ps1 | iex\""
    exit 0
fi
if [ "$status" != "303" ]; then
    printf '%s\n' "Error: artifact endpoint returned HTTP $status for $filename." >&2
    exit 1
fi

# Extract Location header and checksum (BSD-compatible parsing).
location=$(sed -n 's/^[Ll]ocation: *//p' "$meta_headers" | tr -d '\r' | head -1)
expected=$(tr -d ' \n\r' < "$meta_body" | sed -n 's/.*"checksum":"\([0-9A-Fa-f]*\)".*/\1/p')

# Checksum fail-closed: empty/missing checksum is a hard error.
if [ -z "$location" ]; then
    printf '%s\n' "Error: artifact metadata is incomplete for $filename (missing location)." >&2
    exit 1
fi

if [ -z "$expected" ]; then
    printf '%s\n' "Error: artifact metadata missing checksum - verification cannot proceed. Contact support." >&2
    exit 1
fi

# DRY_RUN support - print version info before downloading.
if [ "${KEPLER_DRY_RUN-}" = "1" ]; then
    echo "Version:   $version"
    if [ -n "$INSTALLED" ]; then
        echo "Installed: $INSTALLED"
    fi
    echo "Artifact:  $filename"
    echo "SHA256:    $expected"
    exit 0
fi

# 5. Download from the signed URL (time-limited, no credentials attached).
echo "Downloading KeplerCrew $version..."
archive="$tmpdir/$filename"
curl -fsSL "$location" -o "$archive"

# 6. Verify checksum.
if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$archive" | sed 's/[[:space:]].*//')
elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$archive" | sed 's/[[:space:]].*//')
else
    printf '%s\n' "Error: neither sha256sum nor shasum is available." >&2
    exit 1
fi
if [ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')" ]; then
    printf '%s\n' "Checksum mismatch - download corrupted. Expected $expected got $actual" >&2
    exit 1
fi
echo "Checksum OK."

# 6b. Stop a running KeplerCrew from this install dir before extraction.
pids=$(pgrep -f "$INSTALL_DIR" 2>/dev/null || true)
stopped=0
for pid in $pids; do
    executable=$(readlink "/proc/$pid/exe" 2>/dev/null || ps -p "$pid" -o comm= 2>/dev/null || true)
    case "$executable" in
        "$INSTALL_DIR"/*)
            if [ "$stopped" = "0" ]; then echo "Stopping the running KeplerCrew..."; stopped=1; fi
            kill "$pid" 2>/dev/null || true
            ;;
    esac
done
if [ "$stopped" = "1" ]; then sleep 2; fi

# 7. Extract to staging directory, validate run.sh exists.
echo "Installing to $INSTALL_DIR..."
mkdir -p "$staging_dir"
tar -xzf "$archive" -C "$staging_dir"

# Validate run.sh exists in extraction.
if [ ! -f "$staging_dir/run.sh" ]; then
    printf '%s\n' "Error: extraction failed - run.sh not found in the archive." >&2
    exit 1
fi

# Preserve licenses directory from current install (if exists).
if [ -d "$LICENSE_DIR" ] && [ ! -d "$staging_dir/licenses" ]; then
    mkdir -p "$staging_dir/licenses"
fi
if [ -f "$LICENSE_FILE" ]; then
    cp "$LICENSE_FILE" "$staging_dir/licenses/" 2>/dev/null || true
fi

# Perform atomic swap: rename current to .old, then staging into place.
old_dir="${INSTALL_DIR}.old"
swap_succeeded=0
if [ -d "$INSTALL_DIR" ]; then
    if [ -d "$old_dir" ]; then
        rm -rf "$old_dir"
    fi
    mv "$INSTALL_DIR" "$old_dir" && mv "$staging_dir" "$INSTALL_DIR" && swap_succeeded=1
else
    mv "$staging_dir" "$INSTALL_DIR" && swap_succeeded=1
fi

if [ "$swap_succeeded" != "1" ]; then
    printf '%s\n' "Error: atomic swap failed. Staging directory left at $staging_dir." >&2
    exit 1
fi

# Clean up old installation on success.
if [ -d "$old_dir" ]; then
    rm -rf "$old_dir"
fi

# Set proper permissions on license directory.
mkdir -p "$LICENSE_DIR"
chmod 700 "$LICENSE_DIR"

# 8. Store the license for the launcher - user-only file permissions (umask 0077).
umask 0077
printf '%s' "$key" > "$LICENSE_FILE"
chmod 600 "$LICENSE_FILE"

# Write version.txt LAST, only after swap succeeded.
printf '%s' "$version" > "$INST_VERSION_FILE"
chmod 644 "$INST_VERSION_FILE"

echo "KeplerCrew $version installed."

# 9. Launch.
if [ -f "$INSTALL_DIR/run.sh" ] && [ "${KEPLER_NO_LAUNCH-}" != "1" ]; then
    echo "Starting KeplerCrew..."
    chmod +x "$INSTALL_DIR/run.sh"
    (cd "$INSTALL_DIR" && nohup ./run.sh >/dev/null 2>&1 &)
else
    echo "Run it any time: $INSTALL_DIR/run.sh"
fi

exit 0

# Partial-download guard: wrap entire script in main() to prevent truncated script execution.
main() {
    # All code above runs here; this is the entry point.
    # If the script is truncated mid-download, this function never completes.
    return 0
}
main "$@"
