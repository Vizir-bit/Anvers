#!/bin/bash
# shellcheck disable=SC2015,SC2016  # ok() always succeeds; $BASH_VERSION is meant for the inner shell
# Tests the kit's own logic against a simulated Mac: a fake app bundle holding fake-mullvad,
# and fake codesign, spctl, pkgutil, osascript (run through Node), curl, gpg and uname.
# It tests the scripts, not Mullvad; the real tool's behaviour is only as good as the
# simulation in fake-mullvad.
#
# Usage: tests/run.sh [path-to-bash]   (default: bash; pass a bash 3.2 to test what macOS runs)
# Needs Node.js for the relay-list check.

set -u

SH=${1:-bash}
TESTS=$(cd "$(dirname "$0")" && pwd)
KIT=$(dirname "$TESTS")
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0
ok()  { passed=$((passed + 1)); printf 'ok    %s\n' "$1"; }
nok() { failed=$((failed + 1)); printf 'FAIL  %s\n' "$1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/      | /'; }

# A copy of the kit whose tool paths point at the fakes.
mkdir -p "$WORK/kit" "$WORK/bin" "$WORK/app/Mullvad VPN.app/Contents/Resources" "$WORK/cache"
cp -R "$KIT/harden.sh" "$KIT/audit.sh" "$KIT/verify-download.sh" "$KIT/lib" "$WORK/kit/"
sed -i.bak \
    -e "s#^CODESIGN=.*#CODESIGN=$WORK/bin/codesign#" \
    -e "s#^SPCTL=.*#SPCTL=$WORK/bin/spctl#" \
    -e "s#^PKGUTIL=.*#PKGUTIL=$WORK/bin/pkgutil#" \
    -e "s#^OSASCRIPT=.*#OSASCRIPT=$WORK/bin/osascript#" \
    -e "s#^CURL=.*#CURL=$WORK/bin/curl#" \
    -e "s#^RELAY_CACHE=.*#RELAY_CACHE=$WORK/cache/relays.json#" \
    "$WORK/kit/lib/common.sh"
cp "$TESTS/fake-mullvad" "$WORK/app/Mullvad VPN.app/Contents/Resources/mullvad"
cp "$TESTS/fixtures/relays.json" "$WORK/cache/relays.json"

cat >"$WORK/bin/uname" <<'EOF'
#!/bin/sh
echo Darwin
EOF
cat >"$WORK/bin/codesign" <<'EOF'
#!/bin/sh
case "$*" in
    *--verify*) [ "${FAKE_BAD_SIGNATURE:-0}" = 1 ] && exit 1; exit 0 ;;
    *-dv*) echo "TeamIdentifier=${FAKE_TEAM:-CKG9MXH72F}" >&2 ;;
esac
EOF
cat >"$WORK/bin/spctl" <<'EOF'
#!/bin/sh
echo "$(eval echo \${$#}): accepted"
echo "source=Notarized Developer ID"
case "$*" in
    *install*) echo "origin=Developer ID Installer: Mullvad VPN AB (${FAKE_PKG_TEAM:-CKG9MXH72F})" ;;
    *) echo "origin=Developer ID Application: Mullvad VPN AB (CKG9MXH72F)" ;;
esac
EOF
cat >"$WORK/bin/pkgutil" <<'EOF'
#!/bin/sh
echo "Package \"x.pkg\":"
echo "   Status: signed by a developer certificate issued by Apple for distribution"
echo "   Notarization: trusted by the Apple notary service"
echo "   Certificate Chain:"
echo "    1. Developer ID Installer: Mullvad VPN AB (${FAKE_PKG_TEAM:-CKG9MXH72F})"
echo "       Expires: 2030-01-01"
echo "    2. Developer ID Certification Authority"
EOF
cat >"$WORK/bin/osascript" <<'EOF'
#!/bin/sh
# osascript -l JavaScript <file> <args...>
shift 2
exec node -e 'const m = require(process.argv[1]); console.log(m.run(process.argv.slice(2)));' "$@"
EOF
cat >"$WORK/bin/curl" <<'EOF'
#!/bin/sh
# Answers like am.i.mullvad.net while the fake tunnel is up; times out otherwise, unless
# FAKE_LEAK=1 simulates a lockdown that does not hold.
connected=$(sed -n 's/^connected=//p' "$FAKE_STATE" | tail -n 1)
if [ "$connected" != yes ] && [ "${FAKE_LEAK:-0}" != 1 ]; then
    exit 28
fi
case "$*" in *-o\ /dev/null*) exit 0 ;; esac
printf '{"ip":"203.0.113.9","country":"Testland","city":"Testcity","mullvad_exit_ip":%s}' "${FAKE_EXIT:-true}"
case "$*" in *remote_ip*) printf '\n192.0.2.80' ;; esac
EOF
cat >"$WORK/bin/gpg" <<'EOF'
#!/bin/sh
case "${FAKE_GPG:-good}" in
    good) echo "[GNUPG:] VALIDSIG 0000000000000000000000000000000000000000 2026-09-11 0 0 4 0 1 10 00 A1198702FC3E0A09A9AE5B75D5A1D4F266DE8DDF" ;;
    other) echo "[GNUPG:] VALIDSIG 1111111111111111111111111111111111111111 2026-09-11 0 0 4 0 1 10 00 2222222222222222222222222222222222222222" ;;
    nokey) echo "[GNUPG:] NO_PUBKEY D5A1D4F266DE8DDF" ;;
    bad) echo "[GNUPG:] BADSIG D5A1D4F266DE8DDF" ;;
esac
EOF
chmod +x "$WORK"/bin/*

export PATH="$WORK/bin:$PATH"
export MULLVAD_APP="$WORK/app/Mullvad VPN.app"
export FAKE_STATE="$WORK/state"

fresh_state() {
    cat >"$FAKE_STATE" <<EOF
version=${1:-2026.5}
logged_in=yes
connected=yes
lockdown=off
autoconnect=off
lan=allow
split=off
qr=on
daita=off
direct_only=off
ipv6=off
dns_blocks=
mode=auto
location=any
entry=any
multihop=off
ownership=any
EOF
}

run() { "$SH" "$WORK/kit/$1" "${@:2}" 2>&1; }
setting() { sed -n "s/^$1=//p" "$FAKE_STATE" | tail -n 1; }

# The scripts must never show the visible location or an IP address, whatever happens.
no_leak() {
    if printf '%s\n' "$2" | grep -Eq 'Testland|Testcity|Hometown|Homecity|203\.0\.113|198\.51\.100|192\.0\.2\.'; then
        nok "$1: output reveals a location or an address" "$2"
    else
        ok "$1: output reveals no location or address"
    fi
}

expect_exit() {
    # $1 label, $2 expected status, $3 actual status, $4 output
    if [ "$2" = "$3" ]; then ok "$1"; else nok "$1 (exit $3, expected $2)" "$4"; fi
}

expect_setting() {
    if [ "$(setting "$1")" = "$2" ]; then ok "$3"; else nok "$3 ($1=$(setting "$1"), expected $2)"; fi
}

say_section() { printf '\n%s\n' "$1"; }

say_section "relay-check.js"
out=$(node -e 'const m = require(process.argv[1]); console.log(m.run(process.argv.slice(2)));' \
    "$KIT/lib/relay-check.js" "$TESTS/fixtures/relays.json" de se quic no)
[ "$out" = "entry=1 exit=1" ] && ok "DAITA+QUIC entry in de, any exit in se" || nok "de/se quic: $out"
out=$(node -e 'const m = require(process.argv[1]); console.log(m.run(process.argv.slice(2)));' \
    "$KIT/lib/relay-check.js" "$TESTS/fixtures/relays.json" de ch auto yes)
[ "$out" = "entry=2 exit=0" ] && ok "owned exits only: none in ch" || nok "de/ch owned: $out"
out=$(node -e 'const m = require(process.argv[1]); console.log(m.run(process.argv.slice(2)));' \
    "$KIT/lib/relay-check.js" "$TESTS/fixtures/relays.json" nl - auto no)
[ "$out" = "entry=0 exit=0" ] && ok "no DAITA relay in nl" || nok "nl: $out"
out=$(node -e 'const m = require(process.argv[1]); console.log(m.run(process.argv.slice(2)));' \
    "$KIT/lib/relay-check.js" "$TESTS/fixtures/relays.json" fr no quic no)
[ "$out" = "entry=0 exit=0" ] && ok "inactive and country-excluded relays are not counted" || nok "fr/no: $out"

say_section "harden.sh, generation A (2026.5)"
export FAKE_GEN=A
fresh_state
out=$(run harden.sh --dry-run); st=$?
expect_exit "dry run succeeds" 0 $st "$out"
expect_setting lockdown off "dry run changes nothing"
printf '%s\n' "$out" | grep -q 'mullvad tunnel set daita-direct-only off' && ok "dry run lists the commands" || nok "dry run lists the commands" "$out"

out=$(run harden.sh); st=$?
expect_exit "daily profile applies and connects" 0 $st "$out"
no_leak "daily profile" "$out"
for pair in lockdown=on autoconnect=on lan=block split=off qr=on daita=on ipv6=off \
    "dns_blocks=ads trackers malware" mode=auto direct_only=off multihop=off ownership=any connected=yes; do
    expect_setting "${pair%%=*}" "${pair#*=}" "daily sets ${pair}"
done

out=$(run audit.sh); st=$?
expect_exit "audit passes after the daily profile" 0 $st "$out"
no_leak "audit (daily)" "$out"

out=$(run audit.sh --profile sensitive); st=$?
expect_exit "audit against the wrong profile fails" 1 $st "$out"

out=$(run harden.sh --profile sensitive --entry de); st=$?
expect_exit "sensitive profile refuses a missing exit" 1 $st "$out"
out=$(run harden.sh --profile sensitive --entry de --exit de); st=$?
expect_exit "sensitive profile refuses one country for both hops" 1 $st "$out"
out=$(run harden.sh --profile daily --entry de); st=$?
expect_exit "daily profile refuses --entry" 1 $st "$out"

fresh_state
out=$(run harden.sh --profile sensitive --entry nl --exit se); st=$?
expect_exit "sensitive profile refuses an entry without DAITA relays" 1 $st "$out"
expect_setting lockdown off "a refused choice changes nothing"

out=$(run harden.sh --profile sensitive --entry de --exit ch --owned-exit); st=$?
expect_exit "--owned-exit refuses a country without owned relays" 1 $st "$out"

out=$(run harden.sh --profile sensitive --entry de --exit se --owned-exit); st=$?
expect_exit "sensitive profile applies and connects" 0 $st "$out"
no_leak "sensitive profile" "$out"
for pair in direct_only=on multihop=on entry=de location=se mode=quic ownership=owned; do
    expect_setting "${pair%%=*}" "${pair#*=}" "sensitive sets ${pair}"
done
out=$(run audit.sh --profile sensitive); st=$?
expect_exit "audit passes after the sensitive profile" 0 $st "$out"
no_leak "audit (sensitive)" "$out"

printf 'direct_only=off\n' >>"$FAKE_STATE"
out=$(run audit.sh --profile sensitive); st=$?
expect_exit "audit catches DAITA overriding the chosen entry" 1 $st "$out"
printf '%s\n' "$out" | grep -q 'FAIL  entry and exit relays are in the same country' &&
    ok "and names the failure" || nok "and names the failure" "$out"

out=$(run harden.sh --profile daily); st=$?
expect_exit "back to the daily profile" 0 $st "$out"
expect_setting direct_only off "daily restores direct-only off"
expect_setting multihop off "daily restores multihop off"

out=$(run audit.sh --test-lockdown --log "$WORK/audit.log"); st=$?
expect_exit "lockdown test passes and reconnects" 0 $st "$out"
expect_setting connected yes "tunnel is up again after the test"
no_leak "lockdown test" "$out"
if [ -s "$WORK/audit.log" ] && ! grep -Eq 'Testcity|203\.0\.113|192\.0\.2\.' "$WORK/audit.log" &&
    grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z daily PASS ' "$WORK/audit.log"; then
    ok "log file written, UTC timestamps, no addresses"
else
    nok "log file" "$(cat "$WORK/audit.log" 2>/dev/null)"
fi

out=$(FAKE_LEAK=1 run audit.sh --test-lockdown); st=$?
expect_exit "a lockdown that leaks is caught" 1 $st "$out"
printf '%s\n' "$out" | grep -q 'FAIL  a request got out while disconnected' && ok "and named" || nok "and named" "$out"

out=$(FAKE_EXIT=false run audit.sh); st=$?
expect_exit "a non-Mullvad exit is caught" 1 $st "$out"

printf 'lan=allow\n' >>"$FAKE_STATE"
out=$(run audit.sh); st=$?
expect_exit "a setting changed behind our back is caught" 1 $st "$out"
printf '%s\n' "$out" | grep -q 'FAIL  local network sharing blocked' && ok "and named" || nok "and named" "$out"

say_section "harden.sh refusals"
fresh_state
out=$(FAKE_TEAM=ABCDE12345 run harden.sh); st=$?
expect_exit "refuses an app signed by another team" 1 $st "$out"
expect_setting lockdown off "and changes nothing"
out=$(FAKE_BAD_SIGNATURE=1 run harden.sh); st=$?
expect_exit "refuses an app with a broken signature" 1 $st "$out"
fresh_state 2026.4
out=$(run harden.sh); st=$?
expect_exit "refuses a version older than 2026.5" 1 $st "$out"
fresh_state
printf 'logged_in=no\n' >>"$FAKE_STATE"
out=$(run harden.sh); st=$?
expect_exit "stops when the app is not logged in" 1 $st "$out"
printf '%s\n' "$out" | grep -q 'not logged in' && ok "and says so" || nok "and says so" "$out"
fresh_state
out=$(FAKE_NO_RELAY=1 run harden.sh); st=$?
expect_exit "stops when no relay matches" 1 $st "$out"

say_section "harden.sh, generation B (after 2026.5)"
export FAKE_GEN=B
fresh_state 2026.6
out=$(run harden.sh); st=$?
expect_exit "daily profile applies" 0 $st "$out"
expect_setting multihop auto "daily sets multihop auto"
out=$(run audit.sh); st=$?
expect_exit "audit passes" 0 $st "$out"
out=$(run harden.sh --profile sensitive --entry de --exit se); st=$?
expect_exit "sensitive profile applies" 0 $st "$out"
expect_setting multihop always "sensitive sets multihop always"
out=$(run audit.sh --profile sensitive); st=$?
expect_exit "audit passes" 0 $st "$out"

say_section "verify-download.sh"
touch "$WORK/MullvadVPN-2026.5.pkg" "$WORK/MullvadVPN-2026.5.pkg.asc"
out=$(run verify-download.sh "$WORK/MullvadVPN-2026.5.pkg"); st=$?
expect_exit "an authentic package passes both channels" 0 $st "$out"
out=$(FAKE_GPG=other run verify-download.sh "$WORK/MullvadVPN-2026.5.pkg"); st=$?
expect_exit "a signature from another key fails" 1 $st "$out"
out=$(FAKE_GPG=bad run verify-download.sh "$WORK/MullvadVPN-2026.5.pkg"); st=$?
expect_exit "a bad signature fails" 1 $st "$out"
out=$(FAKE_GPG=nokey run verify-download.sh "$WORK/MullvadVPN-2026.5.pkg"); st=$?
expect_exit "a missing key is a note, not a pass of Mullvad's channel" 0 $st "$out"
printf '%s\n' "$out" | grep -q "NOTE  Mullvad's public key is not in your keyring" && ok "and says so" || nok "and says so" "$out"
out=$(FAKE_PKG_TEAM=ZZZZZZZZZZ run verify-download.sh "$WORK/MullvadVPN-2026.5.pkg"); st=$?
expect_exit "a package signed by another team fails" 1 $st "$out"

printf '\n%d passed, %d failed (shell: %s)\n' "$passed" "$failed" "$("$SH" -c 'echo $BASH_VERSION')"
[ "$failed" -eq 0 ]
