#!/bin/bash
# Checks that a downloaded Mullvad VPN installer (.pkg) is authentic before it is opened.
#
# Two independent channels are checked. Apple's: the package must be signed with Mullvad's
# Developer ID Installer certificate and notarized. Mullvad's own: if GnuPG is installed and a
# signature file is present, the package must carry a valid signature from the key whose
# fingerprint is pinned in lib/common.sh. Forging both requires compromising both Apple's
# certificate chain and Mullvad's release key, which is the point of checking both.
#
# Usage: verify-download.sh MullvadVPN-<version>.pkg [MullvadVPN-<version>.pkg.asc]

set -eu

KIT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
. "$KIT_DIR/lib/common.sh"

[ $# -ge 1 ] || die "give the path to the downloaded .pkg (and, optionally, its .asc signature)."
case $1 in -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac

pkg=$1
asc=${2:-$1.asc}
[ -f "$pkg" ] || die "no file at '$pkg'."
require_macos

failures=0
pass() { say "PASS  $*"; }
fail() { say "FAIL  $*"; failures=$((failures + 1)); }
note() { say "NOTE  $*"; }

say "Apple's channel"
signature=$("$PKGUTIL" --check-signature "$pkg" 2>&1 || true)
if printf '%s\n' "$signature" | grep -Eq "^[[:space:]]*1\. Developer ID Installer: .*\($MULLVAD_TEAM_ID\)$"; then
    pass "signed with a Developer ID Installer certificate of team $MULLVAD_TEAM_ID"
else
    fail "not signed by team $MULLVAD_TEAM_ID; the signer reported is: $(printf '%s\n' "$signature" | grep -E '^[[:space:]]*1\. ' | sed 's/^[[:space:]]*//')"
fi
assessment=$("$SPCTL" --assess --type install -vv "$pkg" 2>&1 || true)
if printf '%s\n' "$signature" | grep -q 'Notarization: trusted by the Apple notary service' ||
    printf '%s\n' "$assessment" | grep -q 'source=Notarized Developer ID'; then
    pass "notarized by Apple"
else
    fail "neither pkgutil nor Gatekeeper reports the package as notarized"
fi
if printf '%s\n' "$assessment" | grep -q ': accepted' &&
    printf '%s\n' "$assessment" | grep -q "origin=Developer ID Installer: .*($MULLVAD_TEAM_ID)"; then
    pass "Gatekeeper accepts it as Mullvad's"
else
    fail "Gatekeeper does not accept it as Mullvad's: $(printf '%s\n' "$assessment" | tr '\n' ' ')"
fi

say ""
say "Mullvad's channel"
if ! command -v gpg >/dev/null 2>&1; then
    note "GnuPG is not installed, so Mullvad's own signature was not checked. Apple's channel alone is still a meaningful check; GnuPG adds a second, independent one."
elif [ ! -f "$asc" ]; then
    note "no signature file at '$asc'. Download it from the same page as the installer to add Mullvad's own check."
else
    status=$(gpg --status-fd 1 --verify "$asc" "$pkg" 2>/dev/null || true)
    validsig=$(printf '%s\n' "$status" | grep '^\[GNUPG:\] VALIDSIG ' | head -n 1)
    if [ -n "$validsig" ]; then
        # VALIDSIG carries the signing key's fingerprint first and the primary key's last.
        signing=$(printf '%s\n' "$validsig" | awk '{ print $3 }')
        primary=$(printf '%s\n' "$validsig" | awk '{ print $NF }')
        if [ "$signing" = "$MULLVAD_GPG_FPR" ] || [ "$primary" = "$MULLVAD_GPG_FPR" ]; then
            pass "valid signature from Mullvad's code-signing key $MULLVAD_GPG_FPR"
        else
            fail "the signature is valid but from another key ($primary), not Mullvad's"
        fi
    elif printf '%s\n' "$status" | grep -q '^\[GNUPG:\] NO_PUBKEY'; then
        note "Mullvad's public key is not in your keyring. Import it from Mullvad's Open Source page and run this again; whatever the key's source, the fingerprint must equal $MULLVAD_GPG_FPR or the check fails."
    else
        fail "the signature file does not verify against this package"
    fi
fi

say ""
if [ "$failures" -eq 0 ]; then
    say "Result: no failures. The installer may be opened."
    exit 0
fi
say "Result: $failures failure(s). Do not open this installer; download it again from Mullvad's own site."
exit 1
