#!/bin/bash
# Read-only audit of the Mullvad VPN configuration against the profile harden.sh applies.
# It changes nothing, unless --test-lockdown is given, which disconnects the tunnel for a few
# seconds to prove that the Mac then has no network at all, and reconnects.
#
# Output says PASS, FAIL or WARN per check. It never prints an IP address, a location or a
# relay name, and never reads the account number. The exit status is 1 if any check failed.

set -eu

KIT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
. "$KIT_DIR/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: audit.sh [--profile daily|sensitive] [--test-lockdown] [--log FILE]

  --profile         which profile to check against (default: daily)
  --test-lockdown   briefly disconnect to confirm that nothing gets out, then reconnect
  --log FILE        also append the results to FILE, with UTC timestamps
EOF
}

profile=daily
test_lockdown=no
log_file=""

while [ $# -gt 0 ]; do
    case $1 in
        --profile|--log)
            [ $# -ge 2 ] || die "$1 needs a value (see --help)."
            case $1 in
                --profile) profile=$(lower "$2") ;;
                --log) log_file=$2 ;;
            esac
            shift 2
            ;;
        --test-lockdown) test_lockdown=yes; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option '$1' (see --help)." ;;
    esac
done
case $profile in daily|sensitive) ;; *) die "unknown profile '$profile'." ;; esac

failures=0
warnings=0
stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

record() {
    # $1 = PASS, FAIL or WARN; the rest is the observation, recorded verbatim.
    local verdict=$1
    shift
    say "$verdict  $*"
    case $verdict in
        FAIL) failures=$((failures + 1)) ;;
        WARN) warnings=$((warnings + 1)) ;;
    esac
    if [ -n "$log_file" ]; then
        printf '%s %s %s %s\n' "$stamp" "$profile" "$verdict" "$*" >>"$log_file"
    fi
}

# Checks that a line of $2 (a command's output) matching the pattern $3 exists.
expect() {
    local label=$1 output=$2 pattern=$3
    if printf '%s\n' "$output" | grep -Eq "$pattern"; then
        record PASS "$label"
    else
        record FAIL "$label (found: $(printf '%s\n' "$output" | grep -E "${4:-^}" | head -n 1 | sed 's/^[[:space:]]*//'))"
    fi
}

cli() { "$MULLVAD_CLI" "$@" 2>&1 || true; }

say "Mullvad VPN audit, profile $profile, $stamp"
require_macos
require_cli

say ""
say "Integrity"
if signed_by_mullvad "$MULLVAD_APP" deep; then
    record PASS "app signature valid, Mullvad team $MULLVAD_TEAM_ID"
else
    record FAIL "app signature invalid or not from team $MULLVAD_TEAM_ID"
fi
if signed_by_mullvad "$MULLVAD_CLI"; then
    record PASS "command-line tool signature valid"
else
    record FAIL "command-line tool signature invalid or not from team $MULLVAD_TEAM_ID"
fi
gatekeeper=$("$SPCTL" --assess --type execute -vv "$MULLVAD_APP" 2>&1 || true)
if printf '%s\n' "$gatekeeper" | grep -q 'source=Notarized Developer ID'; then
    record PASS "Gatekeeper: notarized by Apple"
else
    record WARN "Gatekeeper did not report the app as notarized ($(printf '%s\n' "$gatekeeper" | head -n 2 | tr '\n' ' '))"
fi

require_daemon
CLI_VERSION=$(cli_version)
CLI_GENERATION=$(cli_generation)
version_info=$(cli version)
if version_supported "$CLI_VERSION"; then
    record PASS "version $CLI_VERSION"
else
    record FAIL "version $CLI_VERSION is older than $MIN_YEAR.$MIN_MINOR"
fi
if printf '%s\n' "$version_info" | grep -q 'Is supported *: *false'; then
    record FAIL "Mullvad reports this version as no longer supported"
fi
upgrade=$(printf '%s\n' "$version_info" | sed -n 's/^Suggested upgrade *: *//p')
if [ -n "$upgrade" ] && [ "$upgrade" != none ]; then
    record WARN "an update is available: $upgrade"
fi

say ""
say "Settings"
expect "lockdown mode on" "$(cli lockdown-mode get)" ': on$' 'Block traffic'
expect "auto-connect on" "$(cli auto-connect get)" 'Autoconnect: on$' 'Autoconnect'
expect "local network sharing blocked" "$(cli lan get)" ': block$' 'Local network'
expect "split tunnelling off" "$(cli split-tunnel get)" 'Split tunneling state: off$' 'Split tunneling state'

tunnel=$(cli tunnel get)
expect "quantum-resistant tunnel on" "$tunnel" 'Quantum resistance:[[:space:]]+on$' 'Quantum resistance'
expect "DAITA on" "$tunnel" 'DAITA:[[:space:]]+(true|on|enabled)' 'DAITA'
expect "IPv6 in the tunnel off" "$tunnel" 'IPv6:[[:space:]]+off$' 'IPv6'

dns=$(cli dns get)
expect "Mullvad's own DNS, no custom resolver" "$dns" '^Custom DNS: no$' 'Custom DNS'
expect "DNS blocks ads" "$dns" '^Block ads: true$' 'Block ads'
expect "DNS blocks trackers" "$dns" '^Block trackers: true$' 'Block trackers'
expect "DNS blocks malware" "$dns" '^Block malware: true$' 'Block malware'

mode=$(cli anti-censorship get | sed -n 's/^mode: //p')
if [ "$profile" = sensitive ]; then
    case $mode in
        quic) record PASS "obfuscation: QUIC" ;;
        lwo|shadowsocks|udp2tcp) record WARN "obfuscation: $mode rather than QUIC (a deliberate choice?)" ;;
        *) record FAIL "obfuscation: ${mode:-unknown}; the sensitive profile needs a forced method to hide VPN use" ;;
    esac
else
    case $mode in
        auto) record PASS "obfuscation: automatic" ;;
        off|'') record FAIL "obfuscation: ${mode:-unknown}; the daily profile uses automatic" ;;
        *) record WARN "obfuscation: $mode rather than automatic (a deliberate choice?)" ;;
    esac
fi

multihop=$(cli relay get | sed -n 's/^[[:space:]]*Multihop state:[[:space:]]*//p')
case "$profile/$CLI_GENERATION/$multihop" in
    daily/A/disabled|daily/B/Auto|sensitive/A/enabled|sensitive/B/Always)
        record PASS "multihop setting: $multihop" ;;
    *)
        record FAIL "multihop setting: ${multihop:-unknown}, not what the $profile profile sets" ;;
esac

say ""
say "Live connection"
out=$(status_raw)
state=$(state_of "$out")
if printf '%s\n' "$out" | grep -q 'failed to setup firewall rules'; then
    record FAIL "the Mullvad service reports it could not set up its firewall rules: traffic may leak"
fi
if [ "$state" != Connected ]; then
    record FAIL "tunnel state: ${state:-unknown}"
else
    record PASS "tunnel state: Connected"
    features=$(features_of "$out")
    has_feature() { printf '%s\n' "$features" | tr ',' '\n' | sed 's/^ *//' | grep -qx "$1"; }

    if has_feature 'DAITA' || has_feature 'DAITA: Multihop'; then
        record PASS "DAITA active on this connection"
    else
        record FAIL "DAITA not active on this connection"
    fi
    for f in 'Quantum Resistance' 'Lockdown Mode' 'Dns Content Blocker'; do
        if has_feature "$f"; then record PASS "active: $f"; else record FAIL "not active: $f"; fi
    done
    for f in 'LAN Sharing' 'Split Tunneling' 'Custom Dns' 'Server Ip Override'; do
        if has_feature "$f"; then record FAIL "unexpectedly active: $f"; fi
    done

    countries=$(relay_countries_of "$out")
    exit_country=$(printf '%s' "$countries" | awk '{ print $1 }')
    entry_country=$(printf '%s' "$countries" | awk '{ print $2 }')
    if [ "$profile" = sensitive ]; then
        if has_feature 'Multihop'; then record PASS "active: Multihop"; else record FAIL "not active: Multihop"; fi
        if has_feature 'Quic'; then record PASS "active: QUIC obfuscation"; else record WARN "QUIC obfuscation not active on this connection"; fi
        if [ -z "$entry_country" ] || [ -z "$exit_country" ]; then
            record WARN "could not read the relay names, so the jurisdictions were not compared"
        elif [ "$entry_country" != "$exit_country" ]; then
            record PASS "entry and exit relays are in different countries"
        else
            record FAIL "entry and exit relays are in the same country"
        fi
    fi

    # Mullvad's own check service answers whether the request arrived from a Mullvad exit.
    # Only that yes-or-no is read; the rest of the answer is discarded unread.
    check=$("$CURL" -sS --max-time 15 -w '\n%{remote_ip}' https://am.i.mullvad.net/json 2>/dev/null || true)
    check_ip=$(printf '%s\n' "$check" | tail -n 1)
    if printf '%s\n' "$check" | grep -Eq '"mullvad_exit_ip"[[:space:]]*:[[:space:]]*true'; then
        record PASS "Mullvad's check service sees a Mullvad exit"
    elif [ -z "$check" ]; then
        record WARN "Mullvad's check service did not answer"
    else
        record FAIL "Mullvad's check service does not see a Mullvad exit"
    fi

    if [ "$test_lockdown" = yes ]; then
        say ""
        say "Lockdown test (the network is cut for a few seconds)"
        # If the script is interrupted mid-test, reconnect on the way out. Until then the
        # Mac is merely offline, never exposed.
        reconnect() { "$MULLVAD_CLI" connect >/dev/null 2>&1 || true; }
        trap reconnect EXIT
        trap 'exit 130' INT TERM
        "$MULLVAD_CLI" disconnect --wait >/dev/null 2>&1 || true
        blocked=$(status_raw)
        if printf '%s\n' "$blocked" | grep -q 'Internet access is blocked due to lockdown mode'; then
            record PASS "disconnected state reports all traffic blocked"
        else
            record FAIL "disconnected state does not report lockdown blocking"
        fi
        # Reach the same server by its address, so that the test does not depend on DNS.
        case $check_ip in *:*) probe_ip="[$check_ip]" ;; *) probe_ip=$check_ip ;; esac
        if [ -n "$check_ip" ] && "$CURL" -sS --max-time 8 -o /dev/null \
            --resolve "am.i.mullvad.net:443:$probe_ip" https://am.i.mullvad.net/json >/dev/null 2>&1; then
            record FAIL "a request got out while disconnected: lockdown is not holding"
        elif [ -n "$check_ip" ]; then
            record PASS "no request got out while disconnected"
        else
            record WARN "no server address from the earlier check, so the leak probe was skipped"
        fi
        reconnect
        trap - EXIT INT TERM
        again=$(wait_for_tunnel 60)
        if [ "$(state_of "$again")" = Connected ]; then
            record PASS "reconnected after the test"
        else
            record FAIL "not reconnected within 60 seconds (state: $(state_of "$again")); traffic stays blocked meanwhile"
        fi
    fi
fi

say ""
if [ "$failures" -eq 0 ]; then
    say "Result: no failures, $warnings warning(s)."
    [ "$test_lockdown" = yes ] || say "Lockdown itself was not tested; run with --test-lockdown to test it."
    say "DNS and WebRTC leaks are checked in the browser, on Mullvad's connection check page."
    exit 0
fi
say "Result: $failures failure(s), $warnings warning(s). Keep these lines as they stand for the audit record (--log keeps them in a file)."
exit 1
