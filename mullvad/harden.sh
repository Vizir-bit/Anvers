#!/bin/bash
# Applies a hardened Mullvad VPN configuration through the app's own command-line tool.
# README.md gives the reasoning for every setting. Run it as your ordinary user: the
# Mullvad service accepts these changes without an administrator password.
#
# It never touches the account: log in through the app before running it.

set -eu

KIT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
. "$KIT_DIR/lib/common.sh"

usage() {
    cat <<'EOF'
Usage:
  harden.sh [--profile daily] [--exit CC] [options]
  harden.sh --profile sensitive --entry CC --exit CC [options]

Profiles:
  daily      DAITA with automatic multihop, automatic obfuscation. The default.
  sensitive  DAITA with multihop through an entry and an exit you choose in two
             different countries, and QUIC obfuscation to hide that a VPN is in use.

CC is a two-letter country code as Mullvad uses it (see: mullvad relay list).
The choice of countries is yours; the script never picks them.

Options:
  --exit CC              exit country (required for sensitive, optional for daily)
  --entry CC             entry country (sensitive only; needs DAITA relays there)
  --owned-exit           use only exit servers Mullvad owns, not rented ones
  --obfuscation MODE     override the profile's method: auto, quic, lwo, shadowsocks, udp2tcp
  --block-adult-content  extra DNS blocklists, each off unless named
  --block-gambling
  --block-social-media
  --dry-run              run every check and print the commands without changing anything
  -h, --help             show this text
EOF
}

profile=daily
entry=""
exit_cc=""
owned=no
obfuscation=""
dry_run=no
dns_extra=""

while [ $# -gt 0 ]; do
    case $1 in
        --profile|--entry|--exit|--obfuscation)
            [ $# -ge 2 ] || die "$1 needs a value (see --help)."
            case $1 in
                --profile) profile=$(lower "$2") ;;
                --entry) entry=$(lower "$2") ;;
                --exit) exit_cc=$(lower "$2") ;;
                --obfuscation) obfuscation=$(lower "$2") ;;
            esac
            shift 2
            ;;
        --owned-exit) owned=yes; shift ;;
        --block-adult-content|--block-gambling|--block-social-media)
            dns_extra="$dns_extra $1"; shift ;;
        --dry-run) dry_run=yes; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option '$1' (see --help)." ;;
    esac
done

case $profile in
    daily)
        [ -z "$entry" ] || die "--entry belongs to the sensitive profile; the daily profile lets DAITA choose its entry."
        [ -n "$obfuscation" ] || obfuscation=auto
        ;;
    sensitive)
        [ -n "$entry" ] && [ -n "$exit_cc" ] ||
            die "the sensitive profile needs both --entry and --exit, in two different countries of your choosing."
        [ "$entry" != "$exit_cc" ] ||
            die "entry and exit are both '$entry'; the point of this profile is two jurisdictions."
        [ -n "$obfuscation" ] || obfuscation=quic
        ;;
    *) die "unknown profile '$profile'; use daily or sensitive." ;;
esac
[ -z "$entry" ] || is_country_code "$entry" || die "'$entry' is not a two-letter country code."
[ -z "$exit_cc" ] || is_country_code "$exit_cc" || die "'$exit_cc' is not a two-letter country code."
case $obfuscation in
    auto|quic|lwo|shadowsocks|udp2tcp) ;;
    *) die "unknown obfuscation mode '$obfuscation'." ;;
esac
if [ "$owned" = yes ] && [ -z "$exit_cc" ]; then
    die "--owned-exit needs --exit, so that the choice can be checked against the relay list."
fi

say "Checking the installation"
require_macos
require_cli
require_authentic_app
say "  signature: valid, Mullvad team $MULLVAD_TEAM_ID"
require_supported_version
require_known_generation
say "  version: $CLI_VERSION (multihop controls: generation $CLI_GENERATION)"
require_daemon

if [ -n "$exit_cc" ]; then
    say "Checking the relay list for your choice"
    result=$(relay_feasibility "${entry:--}" "$exit_cc" "$obfuscation" "$owned")
    case $result in
        entry=*)
            n_entry=$(printf '%s' "$result" | sed -n 's/^entry=\([0-9]*\).*/\1/p')
            n_exit=$(printf '%s' "$result" | sed -n 's/.*exit=\([0-9]*\).*/\1/p')
            entry_needs="DAITA"
            case $obfuscation in quic|lwo) entry_needs="DAITA and $obfuscation" ;; esac
            exit_kind="active"
            [ "$owned" = no ] || exit_kind="active Mullvad-owned"
            if [ -n "$entry" ]; then
                [ "$n_entry" -gt 0 ] ||
                    die "no active relay in '$entry' supports $entry_needs. Choose another entry country; nothing was changed."
                say "  entry candidates ($entry_needs): $n_entry"
            fi
            [ "$n_exit" -gt 0 ] ||
                die "no $exit_kind relay in '$exit_cc'. Choose another exit country; nothing was changed."
            say "  exit candidates ($exit_kind): $n_exit"
            ;;
        *)
            warn "could not read the relay list, so the choice was not checked in advance. If no relay matches, the connection test below will say so, and the tunnel stays blocked (no leak) until you choose again."
            ;;
    esac
fi

# Set to yes once lockdown is on and the tunnel is down, so that a failure can say which
# state it leaves the Mac in.
held=no

run_cli() {
    say "  mullvad $*"
    [ "$dry_run" = yes ] && return 0
    "$MULLVAD_CLI" "$@" >/dev/null && return 0
    if [ "$held" = yes ]; then
        die "the command 'mullvad $*' failed. The settings before it were applied, the rest were not, and the tunnel is left down with lockdown on: the Mac is offline, not exposed. Fix the cause and run the script again."
    fi
    die "the command 'mullvad $*' failed before the configuration began; the connection is as it was. Fix the cause and run the script again."
}

if [ "$dry_run" = yes ]; then
    say "Dry run: these are the commands that would run"
else
    say "Applying the $profile profile"
    say "  (the network is blocked for a few seconds while the settings change)"
fi

# Lockdown first, then disconnect: from here until the new tunnel is up, nothing leaves the
# Mac, and no intermediate configuration is ever used.
run_cli lockdown-mode set on
run_cli disconnect --wait
held=yes

run_cli auto-connect set on
run_cli lan set block
run_cli split-tunnel set off
run_cli tunnel set quantum-resistant on
run_cli tunnel set daita on
run_cli tunnel set ipv6 off
# shellcheck disable=SC2086  # dns_extra is a list of flags
run_cli dns set default --block-ads --block-trackers --block-malware $dns_extra
run_cli relay set ip-version any
run_cli anti-censorship set mode "$obfuscation"

if [ "$owned" = yes ]; then
    run_cli relay set ownership owned
else
    run_cli relay set ownership any
fi
if [ -n "$exit_cc" ]; then
    run_cli relay set location "$exit_cc"
fi

if [ "$profile" = daily ]; then
    if [ "$CLI_GENERATION" = A ]; then
        run_cli tunnel set daita-direct-only off
        run_cli relay set multihop off
    else
        run_cli relay set multihop auto
    fi
else
    run_cli relay set entry location "$entry"
    if [ "$CLI_GENERATION" = A ]; then
        # In 2026.5, leaving "direct only" off makes DAITA replace a chosen entry with one
        # picked near the exit. Turning it on is what keeps the entry you chose.
        run_cli tunnel set daita-direct-only on
        run_cli relay set multihop on
    else
        run_cli relay set multihop always
    fi
fi

if [ "$dry_run" = yes ]; then
    say "Dry run complete; nothing was changed."
    exit 0
fi

say "Connecting"
"$MULLVAD_CLI" connect >/dev/null 2>&1 || true
out=$(wait_for_tunnel 60)

if printf '%s\n' "$out" | grep -q 'not logged in'; then
    die "the app is not logged in to an account. Log in through the app itself, then run this script again. Until then the network stays blocked, which is lockdown mode doing its job."
fi
if printf '%s\n' "$out" | grep -q 'failed to setup firewall rules'; then
    die "the Mullvad service reports that it could not set up its firewall rules, so traffic may leak. Restart the Mac and run audit.sh before trusting the connection."
fi

state=$(state_of "$out")
case $state in
    Connected)
        say "  state: Connected"
        say "  features: $(features_of "$out")"
        say "Done. Run audit.sh$( [ "$profile" = sensitive ] && printf ' --profile sensitive') to verify, then Mullvad's connection check page in the browser."
        ;;
    Blocked:*)
        say "  state: $state"
        die "the tunnel did not come up, and traffic is blocked. If the message names relays or constraints, choose other countries (or drop --owned-exit); to return to the default path, run: harden.sh --profile daily"
        ;;
    *)
        say "  state: ${state:-unknown}"
        die "no connection after 60 seconds. Traffic stays blocked meanwhile. Wait a little and run audit.sh; if it is still not connected, run harden.sh --profile daily."
        ;;
esac
