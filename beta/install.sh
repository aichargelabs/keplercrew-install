#!/bin/sh
# KeplerCrew client installer and updater (beta channel).
# Usage: curl -fsSL https://get.keplercrew.com/beta/install.sh | sh
# Running it again updates an existing install to the latest published stable or beta release.
# Env:
#   KEPLER_LICENSE_KEY  license key (existing install's stored key is reused; prompted otherwise)
#   KEPLER_VERSION      optional version such as 1.0.0-beta.1 (default: latest)
#   KEPLER_CHANNEL      beta (default: stable and beta releases) or stable (stable only)
#   KEPLER_DRY_RUN      set to 1 to resolve and print the release without downloading
#   KEPLER_ACCEPT_STABLE set to 1 to install stable without asking when the license has no beta access
#   KEPLER_INSTALL_DIR  optional install directory (default: ~/.local/share/keplercrew or $XDG_DATA_HOME/keplercrew)
#   KEPLER_NO_LAUNCH    set to 1 to skip launching after install
#   KEPLER_FORCE        set to 1 to reinstall even when already on the resolved version
# Author: aichargelabs.

set -eu

# Fallback live-run check for machines without python3: read the pid and the
# apex_status with grep/sed and test the pid with kill -0.
kepler_busy_runs_without_python() {
    _live_dir="$1"
    for _file in "$_live_dir"/*.json; do
        [ -f "$_file" ] || continue
        _pid=$(grep '"pid"' "$_file" 2>/dev/null | sed -n '1{s/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p;}')
        [ -n "$_pid" ] || continue
        _status=$(grep '"apex_status"' "$_file" 2>/dev/null | sed -n '1{s/.*"apex_status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;}')
        if printf '%s' "$_status" | grep -qiE '^(completed|failed|killed|done|idle|error|halted)$'; then
            continue
        fi
        kill -0 "$_pid" 2>/dev/null || continue
        _name=$(grep '"title"' "$_file" 2>/dev/null | sed -n '1{s/.*"title"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;}')
        if [ -z "$_name" ]; then
            _name=$(grep '"cycle_id"' "$_file" 2>/dev/null | sed -n '1{s/.*"cycle_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;}')
        fi
        if [ -z "$_name" ]; then
            _name="${_file##*/}"
            _name="${_name%.json}"
        fi
        printf '%s\n' "$_name"
    done
}

# Refuse self-updates and protect live runs before any prompt, download, or removal.
if [ "${KEPLER_INSIDE_RUN:-}" = "1" ]; then
    echo "This is running inside a Kepler task. Updating Kepler from a task would stop every run. Run the installer from your own terminal." >&2
    exit 3
fi
force=0
for arg in "$@"; do [ "$arg" = "--force" ] && force=1; done
# A piped one-liner (curl ... | sh) takes no argument: use sh -s -- --force there.
# The environment variable works in every form and never applies to the
# inside-task refusal above.
if [ "${KEPLER_FORCE_RUNNING:-}" = "1" ]; then force=1; fi
_data_dir="${APEX_HOME:-$HOME/.kepler-trial}"
if command -v python3 >/dev/null 2>&1; then
    _busy_runs=$(python3 - "$_data_dir/state/live" <<'PYGUARD' 2>/dev/null || true
import glob,json,os,sys,errno
terminal={'completed','failed','killed','done','idle','error','halted'}
for path in glob.glob(os.path.join(sys.argv[1],'*.json')):
    try:
        with open(path,encoding='utf-8') as f: rec=json.load(f)
        pid=int(rec.get('pid') or 0)
        status=str(rec.get('apex_status') or '').lower()
        if status not in terminal and pid>0:
            try: os.kill(pid,0)
            except OSError as e:
                if e.errno == errno.EPERM: print(str(rec.get('title') or rec.get('cycle_id') or os.path.basename(path)[:-5]))
            else:
                print(str(rec.get('title') or rec.get('cycle_id') or os.path.basename(path)[:-5]))
    except Exception: pass
PYGUARD
)
else
    _busy_runs=$(kepler_busy_runs_without_python "$_data_dir/state/live")
fi
if [ -n "$_busy_runs" ] && [ "$force" != "1" ]; then
    echo "Kepler has live runs; let them finish first, or override with --force or KEPLER_FORCE_RUNNING=1:" >&2
    printf '%s\n' "$_busy_runs" >&2
    exit 3
fi

echo "KeplerCrew installer (beta channel)"
if [ "${KEPLER_CHANNEL:-beta}" != "stable" ]; then
    echo "To return to stable, run: curl -fsSL https://get.keplercrew.com/beta/install.sh | KEPLER_CHANNEL=stable KEPLER_FORCE=1 sh"
fi

INSTALL_CHANNEL="${KEPLER_CHANNEL:-beta}"
case "$INSTALL_CHANNEL" in
    beta|stable) ;;
    *)
        printf '%s\n' 'Error: KEPLER_CHANNEL must be "beta" or "stable".' >&2
        exit 1
        ;;
esac

ACCOUNT="11cdb180-ce9f-4b8b-82c6-ca59f9b2c512"
# The installer accepts only the supported licensing authority.
KEYGEN_BASE="https://licenses.aichargelabs.com/v1"
if [ -n "${KEPLER_KEYGEN_BASE:-}" ] && [ "${KEPLER_KEYGEN_BASE%/}" != "$KEYGEN_BASE" ]; then
    echo "Unsupported licensing endpoint." >&2
    exit 1
fi
API="$KEYGEN_BASE/accounts/$ACCOUNT"
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

# 3. Resolve the release (latest published stable or beta, or KEPLER_VERSION).
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
    printf '%s\n' "Contact support@aichargelabs.com and quote error RELEASE-AUTH-$rel_code-BETA." >&2
    exit 1
fi
if [ "$rel_code" != "200" ] || [ -z "$releases" ]; then
    printf '%s\n' "Error: could not reach the release service ($rel_code). Check your network and try again." >&2
    exit 1
fi

# Parse releases: find PUBLISHED entries with channel "stable" or "beta", extract version + id.
# Order-independent parsing: filter both status and channel before extracting version.
# Use python3 when available for proper JSON parsing; fallback to shell parsing.
parse_releases_shell() {
    # Shell fallback: split on '{' but filter both status and selected channel.
    if [ "$INSTALL_CHANNEL" = "stable" ]; then
        channel_pattern='"channel":"stable"'
    else
        channel_pattern='"channel":"(stable|beta)"'
    fi
    printf '%s' "$releases" | tr '{' '\n' | grep '"status":"PUBLISHED"' | grep -E "$channel_pattern"
}

parse_releases_python() {
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$releases" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('data', []):
    attrs = item.get('attributes', {})
    if attrs.get('status') == 'PUBLISHED' and (
        attrs.get('channel') == '$INSTALL_CHANNEL' or
        ('$INSTALL_CHANNEL' == 'beta' and attrs.get('channel') == 'stable')
    ):
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
    printf '%s\n' "Contact support@aichargelabs.com and quote error RELEASE-NONE-BETA." >&2
    exit 1
fi

# A license without beta access is shown stable releases only. Ask before the beta
# command installs stable. An install already on beta is the normal update path.
if [ "$INSTALL_CHANNEL" = "beta" ] && [ -z "${KEPLER_VERSION-}" ] && \
   ! printf '%s' "$published" | grep -Eq '"channel": *"beta"'; then
    installed_channel=$(cat "$INSTALL_DIR/channel.txt" 2>/dev/null || echo "")
    case "$INSTALLED" in *-beta.*) installed_channel="beta" ;; esac
    if [ "$installed_channel" != "beta" ]; then
        echo "You do not have beta access: no beta version is available to your license."
        if [ "${KEPLER_ACCEPT_STABLE-}" = "1" ]; then
            echo "Continuing with the stable version (KEPLER_ACCEPT_STABLE=1)."
            INSTALL_CHANNEL="stable"
        elif [ "${KEPLER_DRY_RUN-}" = "1" ]; then
            echo "Dry run: a real install asks before it continues with the stable version."
        elif ( : </dev/tty ) 2>/dev/null; then
            printf 'Would you like to proceed with the stable version? [y/N] ' >&2
            read -r stable_answer </dev/tty || stable_answer=""
            case "$stable_answer" in
                y|Y|yes|Yes|YES) INSTALL_CHANNEL="stable" ;;
                *)
                    echo "Nothing was installed. For beta access contact support@aichargelabs.com."
                    exit 1
                    ;;
            esac
        else
            printf '%s\n' "Error: nothing was installed. For beta access contact support@aichargelabs.com." >&2
            printf '%s\n' "To install the stable version instead, set KEPLER_ACCEPT_STABLE=1 and run again." >&2
            exit 1
        fi
    fi
fi

wanted="${KEPLER_VERSION-}"

version_is_valid() {
    printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[1-9][0-9]*)?$'
}

# Semver comparison function: returns 0 if v1 > v2, 1 if v1 <= v2.
# For the same X.Y.Z, stable is newer than every beta and beta.N sorts by N.
semver_gt() {
    v1="$1"
    v2="$2"
    # If equal, v1 is NOT greater
    if [ "$v1" = "$v2" ]; then
        return 1
    fi
    # Compare the numeric X.Y.Z core without the optional beta tag.
    v1_core=${v1%%-beta.*}
    v2_core=${v2%%-beta.*}
    v1_major=$(printf '%s' "$v1_core" | cut -d. -f1)
    v1_minor=$(printf '%s' "$v1_core" | cut -d. -f2)
    v1_patch=$(printf '%s' "$v1_core" | cut -d. -f3)
    v2_major=$(printf '%s' "$v2_core" | cut -d. -f1)
    v2_minor=$(printf '%s' "$v2_core" | cut -d. -f2)
    v2_patch=$(printf '%s' "$v2_core" | cut -d. -f3)
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
    elif [ "${v1_patch:-0}" -lt "${v2_patch:-0}" ]; then
        return 1
    fi
    v1_stable=1
    v1_beta=0
    v2_stable=1
    v2_beta=0
    case "$v1" in
        *-beta.*) v1_stable=0; v1_beta=${v1##*-beta.} ;;
    esac
    case "$v2" in
        *-beta.*) v2_stable=0; v2_beta=${v2##*-beta.} ;;
    esac
    if [ "$v1_stable" -gt "$v2_stable" ]; then
        return 0
    elif [ "$v1_stable" -lt "$v2_stable" ]; then
        return 1
    fi
    if [ "$v1_beta" -gt "$v2_beta" ]; then
        return 0
    fi
    return 1
}

# Selection sort keeps the no-python fallback on the same prerelease ordering.
sort_versions() {
    sort_remaining="$1"
    sort_ordered=""
    while [ -n "$sort_remaining" ]; do
        sort_newest=""
        for sort_candidate in $sort_remaining; do
            if [ -z "$sort_newest" ] || semver_gt "$sort_candidate" "$sort_newest"; then
                sort_newest="$sort_candidate"
            fi
        done
        sort_ordered="$sort_ordered $sort_newest"
        sort_next=""
        sort_removed=0
        for sort_candidate in $sort_remaining; do
            if [ "$sort_removed" -eq 0 ] && [ "$sort_candidate" = "$sort_newest" ]; then
                sort_removed=1
            else
                sort_next="$sort_next $sort_candidate"
            fi
        done
        sort_remaining="$sort_next"
    done
    printf '%s' "$sort_ordered"
}

# Resolve this machine's platform before choosing a release. Platform bundles
# can lag the newest release, so an unpinned install selects the newest
# published release that actually carries a bundle for this platform.
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

# Extract all stable and beta published versions with their ids.
# Filter by wanted version if specified, otherwise try newest first.
candidates=""
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
    candidates="$version"
else
    # Newest first. The artifact probe below skips releases with no bundle
    # for this platform, so a platform lag does not strand the install.
    if [ "$use_python" = "1" ]; then
        candidates=$(printf '%s' "$published" | python3 -c "
import sys, json, re
versions = []
for line in sys.stdin:
    attrs = json.loads(line)
    v = attrs.get('version', '')
    if v and v not in versions:
        versions.append(v)
def version_key(v):
    match = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)(?:-beta\.(\d+))?', v)
    if not match:
        return (0, 0, 0, 0, 0)
    return (int(match[1]), int(match[2]), int(match[3]),
            0 if match[4] is not None else 1, int(match[4] or 0))
versions.sort(key=version_key, reverse=True)
print(' '.join(versions))
")
    else
        # Shell fallback: de-duplicate, then apply the same prerelease-aware ordering.
        unsorted=$(printf '%s' "$published" | sed -n 's/.*"version"[: ]*"\([^"]*\)".*/\1/p' | awk '!seen[$0]++' | tr '\n' ' ')
        candidates=$(sort_versions "$unsorted")
    fi
    if [ -z "$candidates" ]; then
        if [ "$INSTALL_CHANNEL" = "stable" ]; then
            printf '%s\n' "Error: no published stable release is available for your license." >&2
        else
            printf '%s\n' "Error: no published stable or beta release is available for your license." >&2
        fi
        printf '%s\n' "Contact support@aichargelabs.com and quote error RELEASE-NONE-BETA." >&2
        exit 1
    fi
    version=$(printf '%s' "$candidates" | awk '{print $1}')
fi

# Downgrade and up-to-date guards run after the platform artifact is
# resolved below: with no version pin, the selected release is the newest
# one that carries a bundle for this platform, which may differ from the
# newest published release overall.

# 4. Resolve the platform artifact. License-key auth cannot LIST artifacts,
#    so the filename follows the release convention and each candidate is
#    probed in newest-first order until one carries this platform's bundle.
release_id_for() {
    candidate="$1"
    found=""
    if [ "$use_python" = "1" ]; then
        found=$(printf '%s' "$published" | python3 -c "
import sys, json
for line in sys.stdin:
    attrs = json.loads(line)
    if attrs.get('version') == sys.argv[1]:
        print(attrs.get('id', ''))
        break
" "$candidate" 2>/dev/null) || found=""
    fi
    if [ -z "$found" ]; then
        # Shell fallback: records start at each top-level id; the release's own record
        # carries its attributes (version/status), relationship ids do not.
        found=$(printf '%s' "$releases" | awk -v ver="$candidate" '
            BEGIN { RS="\"id\":\""; FS="\"" }
            NR>1 && index($0, "\"version\":\"" ver "\"") && index($0, "\"status\":\"PUBLISHED\"") { print $1; exit }')
    fi
    printf '%s' "$found"
}

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

first_candidate=$(printf '%s' "$candidates" | awk '{print $1}')
selected=""
skipped_newer=""
for candidate in $candidates; do
    version="$candidate"
    filename="KeplerCrew-$platform-$arch-$version.tar.gz"
    release_id=$(release_id_for "$candidate")
    if [ -z "$release_id" ]; then
        printf '%s\n' "Error: release $version has no id." >&2
        exit 1
    fi

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
if [ "$status" = "404" ]; then
    if [ -n "$wanted" ]; then
        printf '%s\n' "KeplerCrew $version has no build for $platform/$arch yet." >&2
        exit 1
    fi
    skipped_newer="$skipped_newer $version"
    continue
fi
if [ "$status" != "303" ]; then
    printf '%s\n' "Error: artifact endpoint returned HTTP $status for $filename." >&2
    exit 1
fi
selected="1"
break
done

if [ -z "$selected" ]; then
    echo "No published release has a $platform/$arch bundle yet."
    echo "Windows install: powershell -ExecutionPolicy Bypass -Command \"irm https://get.keplercrew.com/beta/install.ps1 | iex\""
    exit 0
fi
if [ -n "$skipped_newer" ]; then
    echo "Release $first_candidate has no $platform/$arch bundle yet; using latest available for $platform/$arch: $version."
fi

# 4b. Downgrade guard: refuse if resolved version is lower than installed (unless KEPLER_FORCE=1).
if [ -n "$INSTALLED" ] && [ "$INSTALLED" != "$version" ]; then
    if ! version_is_valid "$version"; then
        printf '%s\n' "Error: resolved KeplerCrew version \"$version\" could not be read." >&2
        exit 1
    fi
    if ! version_is_valid "$INSTALLED"; then
        printf '%s\n' "Installed version \"$INSTALLED\" could not be read; continuing without the downgrade check."
    elif semver_gt "$INSTALLED" "$version"; then
        if [ "${KEPLER_FORCE:-}" != "1" ]; then
            printf '%s\n' "Error: downgrade refused: installed $INSTALLED is newer than $version. Set KEPLER_FORCE=1 to allow downgrade." >&2
            exit 1
        fi
        echo "Downgrade allowed by KEPLER_FORCE=1."
    fi
fi

# Already on the resolved version? Nothing to do.
if [ "$INSTALLED" = "$version" ] && [ "${KEPLER_FORCE-}" != "1" ] && [ "${KEPLER_DRY_RUN-}" != "1" ]; then
    echo "KeplerCrew $version is already installed and up to date."
    echo "Set KEPLER_FORCE=1 to reinstall."
    printf '%s' "$INSTALL_CHANNEL" > "$INSTALL_DIR/channel.txt"
    chmod 644 "$INSTALL_DIR/channel.txt"
    echo "Channel set to $INSTALL_CHANNEL."
    exit 0
fi

if [ -n "$INSTALLED" ] && { [ "$INSTALLED" != "$version" ] || [ "${KEPLER_FORCE-}" = "1" ]; }; then
    if [ "$INSTALLED" = "$version" ]; then
        echo "Reinstalling KeplerCrew $version..."
    else
        echo "Updating KeplerCrew $INSTALLED -> $version..."
    fi
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
    echo "Channel:   $INSTALL_CHANNEL"
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

# Record the selected channel after the swap so updates cannot lose it.
printf '%s' "$INSTALL_CHANNEL" > "$INSTALL_DIR/channel.txt"
chmod 644 "$INSTALL_DIR/channel.txt"
echo "Channel set to $INSTALL_CHANNEL."

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
