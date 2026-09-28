#!/bin/bash
#
# install-node.sh: install Node.js v24.21.0 (LTS) on this Mac from the official
# macOS installer, only after the installer has passed every check below, and
# record what was installed.
#
#   bash install-node.sh [path/to/node-v24.21.0.pkg]
#
# The default path is ~/Downloads/node-v24.21.0.pkg. Run it without sudo: it asks
# for your administrator password only for Apple's installer, at the end.
#
# Each check stops the script on failure, before anything is installed:
#   1. The file's SHA-256 equals the value for node-v24.21.0.pkg in the release's
#      SHASUMS256.txt, whose PGP signature verifies against the Node.js release
#      keys (checked when this script was written; the value is fixed below).
#   2. pkgutil reports a signature by "Developer ID Installer: Node.js Foundation
#      (HX7739G8FX)" issued by Apple, with that certificate's SHA-256 fingerprint,
#      and a chain ending at the Apple Root CA, with its fingerprint.
#   3. Gatekeeper (spctl) accepts the package for installation as notarized
#      Developer ID. This may ask Apple whether the package is notarized.
# Then you type "install", Apple's installer runs, and the script confirms that the
# installed node reports v24.21.0. Every run writes a record to ~/mdm-defense and
# prints its SHA-256. Written for the bash 3.2 of macOS.

set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
LC_ALL=C
export PATH LC_ALL

EXPECTED_VERSION=v24.21.0
EXPECTED_SHA256=9831a74b04c270a429bd5a240e37712c4fe229b02b032e18ff2e0702c17c20fd
EXPECTED_SIGNER='Developer ID Installer: Node.js Foundation (HX7739G8FX)'
SIGNER_SHA256=8454FE7FFEC97EBB6535249FAC471416788BF5757582B42B19C7AA91DB52E02A
APPLE_ROOT_SHA256=B0B1730ECBC7FF4505142C49F1295E6EDA6BCAED7E2C68C5BE91B5A11001F024
NODE_BIN=/usr/local/bin/node

PKG=${1:-$HOME/Downloads/node-$EXPECTED_VERSION.pkg}

if [ "$(uname -s)" != Darwin ]; then
  echo "install-node.sh is written for macOS." >&2
  exit 2
fi
if [ "$(id -u)" -eq 0 ]; then
  echo "Run it without sudo; it asks for your password only for the installer." >&2
  exit 2
fi

RECORD_DIR=$HOME/mdm-defense
RECORD=$RECORD_DIR/install-node-$(date -u +%Y%m%dT%H%M%SZ).txt
[ -e "$RECORD" ] && RECORD=${RECORD%.txt}-$$.txt  # never overwrite an earlier record
mkdir -p "$RECORD_DIR" && : >"$RECORD" || exit 1

say() { printf '%s\n' "$*"; printf '%s\n' "$*" >>"$RECORD"; }
indent() { while IFS= read -r line; do say "    $line"; done; }

seal() {
  say ""
  say "record: $RECORD"
  printf 'Record SHA-256: %s  (note it; it seals this record)\n' "$(shasum -a 256 "$RECORD" | awk '{print $1}')"
}

fail() {  # $* = reason; nothing has been installed when this is called
  say "  [!!] $*"
  say ""
  say "Stopped. Nothing was installed."
  seal
  exit 1
}

say "install-node.sh  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "user $(id -un), macOS $(sw_vers -productVersion 2>/dev/null) build $(sw_vers -buildVersion 2>/dev/null)"
say "package: $PKG"
[ -f "$PKG" ] || fail "no file at $PKG; download node-$EXPECTED_VERSION.pkg from nodejs.org or give its path"

say ""
say "== 1. fingerprint"
sum=$(shasum -a 256 "$PKG" | awk '{print $1}')
say "  computed $sum"
say "  expected $EXPECTED_SHA256"
[ "$sum" = "$EXPECTED_SHA256" ] || fail "the file is not the signed release; delete it"
say "  [OK] identical"

say ""
say "== 2. installer signature (pkgutil)"
sig=$(pkgutil --check-signature "$PKG" 2>&1)
printf '%s\n' "$sig" | indent
# Fingerprints are printed as spaced hex pairs over several lines; compare them with all blanks removed.
flat=$(printf '%s' "$sig" | tr -d ' \t\n' | tr '[:lower:]' '[:upper:]')
printf '%s\n' "$sig" | grep -q 'issued by Apple' || fail "pkgutil does not report a certificate issued by Apple"
printf '%s\n' "$sig" | grep -qF "$EXPECTED_SIGNER" || fail "the signer is not $EXPECTED_SIGNER"
case $flat in *"$SIGNER_SHA256"*) ;; *) fail "the signing certificate's fingerprint is not the Node.js Foundation's" ;; esac
case $flat in *"$APPLE_ROOT_SHA256"*) ;; *) fail "the chain does not end at the Apple Root CA" ;; esac
say "  [OK] signed by $EXPECTED_SIGNER, chain to the Apple Root CA, fingerprints as expected"

say ""
say "== 3. Gatekeeper (spctl)"
gk=$(spctl --assess --type install -vv "$PKG" 2>&1)
printf '%s\n' "$gk" | indent
printf '%s\n' "$gk" | grep -q ': accepted' || fail "Gatekeeper does not accept the package"
printf '%s\n' "$gk" | grep -q 'source=Notarized Developer ID' || fail "Gatekeeper does not report it as notarized Developer ID"
say "  [OK] accepted as notarized Developer ID"

say ""
say "== 4. install"
if [ -e "$NODE_BIN" ]; then
  say "  a node is already present: $NODE_BIN, $("$NODE_BIN" --version 2>/dev/null); the installer will replace it"
fi
printf '  Type install to install Node.js %s, or press Return to stop: ' "$EXPECTED_VERSION" >/dev/tty
answer=""
read -r answer </dev/tty
[ "$answer" = install ] || fail "not confirmed"
say "  confirmed by typing install"
sudo /usr/sbin/installer -pkg "$PKG" -target / 2>&1 | indent

say ""
say "== 5. verification"
[ -x "$NODE_BIN" ] || fail "no node at $NODE_BIN after the installer ran"
ver=$("$NODE_BIN" --version 2>&1)
say "  $NODE_BIN reports $ver"
[ "$ver" = "$EXPECTED_VERSION" ] || fail "expected $EXPECTED_VERSION"
say "  sha256 $(shasum -a 256 "$NODE_BIN" | awk '{print $1}')  $NODE_BIN"
if codesign --verify --strict "$NODE_BIN" 2>/dev/null; then
  say "  signature of the node program verified"
else
  say "  [!!] the node program's own signature did not verify"
fi
codesign -dvv "$NODE_BIN" 2>&1 | grep -E '^(Authority|TeamIdentifier)=' | indent
say "  installer receipts, which also list every installed file (pkgutil --files <id>):"
pkgutil --pkgs 2>/dev/null | grep -i nodejs | indent
say "  [OK] Node.js $EXPECTED_VERSION is installed"
seal
