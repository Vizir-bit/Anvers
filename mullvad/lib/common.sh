# shellcheck shell=bash
# shellcheck disable=SC2034  # constants used by the scripts that source this file
# Shared helpers for the Mullvad hardening kit. Sourced by the scripts, never run directly.
# Written for the /bin/bash 3.2 that ships with macOS: no associative arrays, no ${var,,}.
#
# Nothing here reads, prints or stores the Mullvad account number, and nothing prints a
# location or an IP address: status output is filtered down to state and feature names.

# Mullvad's Apple team identifier and code-signing key fingerprint, as recorded in
# Mullvad's own source tree (ios/ExportOptions.plist and desktop/scripts/release/release-config.sh
# at release tag 2026.5).
MULLVAD_TEAM_ID="CKG9MXH72F"
MULLVAD_GPG_FPR="A1198702FC3E0A09A9AE5B75D5A1D4F266DE8DDF"

# Oldest app version this kit was checked against.
MIN_YEAR=2026
MIN_MINOR=5

MULLVAD_APP="${MULLVAD_APP:-/Applications/Mullvad VPN.app}"
MULLVAD_CLI="$MULLVAD_APP/Contents/Resources/mullvad"
RELAY_CACHE="/Library/Caches/mullvad-vpn/relays.json"
RELAY_BUNDLED="$MULLVAD_APP/Contents/Resources/relays.json"

# Absolute paths, so that a doctored PATH cannot substitute these tools.
CODESIGN=/usr/bin/codesign
SPCTL=/usr/sbin/spctl
PKGUTIL=/usr/sbin/pkgutil
OSASCRIPT=/usr/bin/osascript
CURL=/usr/bin/curl

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'STOPPED: %s\n' "$*" >&2; exit 1; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

is_country_code() {
    case $1 in
        [a-z][a-z]) return 0 ;;
        *) return 1 ;;
    esac
}

require_macos() {
    [ "$(uname -s)" = "Darwin" ] || die "this kit configures the Mullvad app on macOS only."
}

require_cli() {
    [ -d "$MULLVAD_APP" ] || die "Mullvad VPN is not installed at '$MULLVAD_APP'. Install it first, or set MULLVAD_APP to where it is."
    [ -x "$MULLVAD_CLI" ] || die "the app's command-line tool is missing at '$MULLVAD_CLI'."
}

# Succeeds when $1 carries a valid signature from Mullvad's Apple team.
# $2 is "deep" for an app bundle, so that everything nested inside it is verified too.
signed_by_mullvad() {
    local target=$1 team
    if [ "${2:-}" = "deep" ]; then
        "$CODESIGN" --verify --deep --strict "$target" >/dev/null 2>&1 || return 1
    else
        "$CODESIGN" --verify --strict "$target" >/dev/null 2>&1 || return 1
    fi
    team=$("$CODESIGN" -dv --verbose=2 "$target" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    [ "$team" = "$MULLVAD_TEAM_ID" ]
}

require_authentic_app() {
    signed_by_mullvad "$MULLVAD_APP" deep ||
        die "the app at '$MULLVAD_APP' does not carry a valid signature from Mullvad's team ($MULLVAD_TEAM_ID). Do not use it; reinstall from Mullvad's site and run verify-download.sh on the installer first."
    signed_by_mullvad "$MULLVAD_CLI" ||
        die "the command-line tool inside the app is not validly signed by Mullvad's team ($MULLVAD_TEAM_ID)."
}

cli_version() {
    "$MULLVAD_CLI" --version 2>/dev/null | awk 'NR == 1 { print $NF }'
}

# Succeeds when the version string in $1 (for instance 2026.5 or 2026.6-beta1) is at least
# MIN_YEAR.MIN_MINOR.
version_supported() {
    local v=$1 year rest minor
    year=${v%%.*}
    rest=${v#*.}
    minor=${rest%%[!0-9]*}
    case $year in ''|*[!0-9]*) return 1 ;; esac
    case $minor in ''|*[!0-9]*) return 1 ;; esac
    [ "$year" -gt "$MIN_YEAR" ] && return 0
    [ "$year" -eq "$MIN_YEAR" ] && [ "$minor" -ge "$MIN_MINOR" ]
}

require_supported_version() {
    CLI_VERSION=$(cli_version)
    [ -n "$CLI_VERSION" ] || die "could not read the app's version."
    version_supported "$CLI_VERSION" ||
        die "the installed app is version $CLI_VERSION; this kit needs $MIN_YEAR.$MIN_MINOR or later. Update the app first: older releases lack security fixes listed in Mullvad's changelog."
}

# The multihop controls changed after release 2026.5. Generation A (2026.5) has a DAITA
# "direct only" switch and an on/off multihop switch; generation B has a single
# multihop setting that takes always, auto or never.
cli_generation() {
    if "$MULLVAD_CLI" tunnel set --help 2>/dev/null | grep -q 'daita-direct-only'; then
        echo A
    elif "$MULLVAD_CLI" relay set multihop --help 2>/dev/null | grep -q 'always'; then
        echo B
    else
        echo unknown
    fi
}

require_known_generation() {
    CLI_GENERATION=$(cli_generation)
    [ "$CLI_GENERATION" != unknown ] ||
        die "version $CLI_VERSION of the app has multihop controls this kit does not recognise. Nothing was changed; the kit needs updating for this release."
}

require_daemon() {
    "$MULLVAD_CLI" lockdown-mode get >/dev/null 2>&1 ||
        die "the Mullvad system service is not answering. Open the Mullvad VPN app once, then try again."
}

# Filters `mullvad status` down to what is safe to show: the state line and the feature
# names. The relay names, the visible location and the IP addresses are dropped.
status_raw() { "$MULLVAD_CLI" status 2>&1; }

state_of() {
    printf '%s\n' "$1" | grep -E '^(Connected|Connecting|Disconnected|Disconnecting|Blocked:)' | head -n 1
}

features_of() {
    printf '%s\n' "$1" | sed -n 's/^[[:space:]]*Features:[[:space:]]*//p' | head -n 1
}

# Two-letter country prefixes of the exit and entry relays, in that order, taken from the
# relay hostnames in the status output (for instance se-got-wg-001). Never printed.
relay_countries_of() {
    printf '%s\n' "$1" | grep -E '^[[:space:]]*Relay:' | head -n 1 |
        grep -oE '[a-z]{2}-[a-z]{3}-[a-z0-9]+-[0-9]+' | cut -c1-2 | tr '\n' ' '
}

# Polls until the tunnel is connected or blocked, for at most $1 seconds, and prints the
# last status output.
wait_for_tunnel() {
    local limit=$1 waited=0 out
    out=$(status_raw)
    while [ "$waited" -lt "$limit" ]; do
        case $(state_of "$out") in
            Connected|Blocked:*) break ;;
        esac
        sleep 1
        waited=$((waited + 1))
        out=$(status_raw)
    done
    printf '%s\n' "$out"
}

# Runs lib/relay-check.js against the newer of the daemon's cached relay list and the one
# bundled with the app. Prints "entry=<n> exit=<n>", or "unavailable".
relay_feasibility() {
    local file=""
    if [ -r "$RELAY_CACHE" ] && [ -r "$RELAY_BUNDLED" ]; then
        if [ "$RELAY_CACHE" -nt "$RELAY_BUNDLED" ]; then file=$RELAY_CACHE; else file=$RELAY_BUNDLED; fi
    elif [ -r "$RELAY_CACHE" ]; then
        file=$RELAY_CACHE
    elif [ -r "$RELAY_BUNDLED" ]; then
        file=$RELAY_BUNDLED
    fi
    if [ -z "$file" ]; then
        echo unavailable
        return 0
    fi
    "$OSASCRIPT" -l JavaScript "$KIT_DIR/lib/relay-check.js" "$file" "$@" 2>/dev/null || echo unavailable
}
