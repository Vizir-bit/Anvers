# Mullvad VPN on the Mac, hardened

This folder holds a small kit for setting up the Mullvad VPN app on macOS as stealthily as the tool allows, and for checking afterwards that it stays that way. You run it yourself on the Mac. Nothing in it reads, stores or prints the Mullvad account number, and nothing prints a location or an IP address: status output is filtered down to states and feature names, and the audit log uses UTC timestamps so that it does not even record a time zone.

Every setting and command was checked against Mullvad's own source code at release 2026.5 (tag commit `19fb874`, released 11 September 2026) and against Mullvad's public relay list as served on 28 September 2026. Where a statement rests on that reading it is marked established; where it is drawn from it, inferred; where it is Mullvad's word, reported.

## What a VPN can buy, and what it cannot

A VPN protects the network layer and nothing else. It hides your traffic from the local network and the internet provider, and moves your apparent origin to Mullvad's exit. It does nothing for a compromised machine: whatever sits on the Mac reads the traffic before it is encrypted. The clean rebuild therefore comes first, and this configuration is applied to the trusted machine afterwards; if the rebuild is not finished, treat this as preparation.

With the settings below, Mullvad offers stealth, not anonymity. DAITA resists an observer who tries to recognise websites or activity from the shape of the traffic; QUIC obfuscation hides that a VPN is in use at all; two hops in two jurisdictions complicate correlation. None of it defeats an adversary who watches both ends of the connection at once, because one or two relays are not a mixnet. The Nym mixnet stays reserved for the sessions where that matters more than speed.

## Order of operations

1. **Get the installer and prove it is Mullvad's.** Download the macOS installer from Mullvad's own site, and its signature file (the `.asc`), which Mullvad publishes alongside each release. Then run:

   ```
   ./verify-download.sh ~/Downloads/MullvadVPN-2026.5.pkg
   ```

   It checks two independent channels. Apple's: the package must be signed with the Developer ID Installer certificate of Mullvad's Apple team (`CKG9MXH72F`) and notarized. Mullvad's own: if GnuPG is installed, the `.asc` must be a valid signature from the key whose fingerprint is pinned in the kit (`A119 8702 FC3E 0A09 A9AE 5B75 D5A1 D4F2 66DE 8DDF`). A forgery would have to defeat both Apple's certificate chain and Mullvad's release key. Without GnuPG only Apple's channel is checked, which is still meaningful. This route is preferable to the Homebrew cask, which adds a third party (the cask's maintainers and the checksum they pin) to the chain of trust.

2. **Install, and create the account in the app.** The account number is the only credential Mullvad has: no e-mail, no name. Write it down offline and keep it out of every file and conversation, this one included. Mullvad reports that it accepts cash by post and Monero, among other methods.

3. **In the app, open Settings, then VPN settings, and turn on both "Launch app on start-up" and "Auto-connect".** Both are needed, and the reason is in the code (established): the app sets the service's own auto-connect to the conjunction of these two switches whenever either changes, so turning on only one silently leaves the service's auto-connect off. It is the service's auto-connect that brings the tunnel up at boot, before you log in.

4. **Apply the daily profile:**

   ```
   ./harden.sh
   ```

   It checks the app's signature and version, turns lockdown on, disconnects (from that moment nothing leaves the Mac), applies every setting, reconnects, and shows the connection's active features. The network drops for a few seconds. Add `--dry-run` first if you want to read the commands before they run. No administrator password is asked for, and that is itself a finding: Mullvad's security document states that any local process can control the VPN service, which is why step 5 exists.

5. **Audit it:**

   ```
   ./audit.sh --test-lockdown --log ~/mullvad-audit.log
   ```

   It re-checks the signatures and every setting, then the live connection: which features are actually active, whether Mullvad's check service sees a Mullvad exit, and, with `--test-lockdown`, whether anything gets out while the tunnel is down (it disconnects, tries to reach a known server by its address, and reconnects). Finally, open Mullvad's connection check page in Mullvad Browser; it tests DNS and WebRTC leaks, which the script does not.

6. **For sensitive sessions,** choose an entry country and an exit country, different from each other, and run:

   ```
   ./harden.sh --profile sensitive --entry XX --exit YY
   ./audit.sh --profile sensitive
   ```

   Add `--owned-exit` to use only exit servers Mullvad owns. Return to daily use with `./harden.sh`. The exit country stays as last chosen until you give another `--exit`.

The choice of countries is yours; the kit never picks them. Choose by purpose (the jurisdictions you want the traffic to cross, the apparent origin a given task needs), not by where you are. As of 28 September 2026, entries able to carry both DAITA and QUIC exist in Albania, Bulgaria, Canada, Switzerland, Germany, Estonia, Spain, France, the United Kingdom, Ireland, Japan, Mexico, the Netherlands, Norway, Romania, Sweden, Singapore and the United States (codes `al bg ca ch de ee es fr gb ie jp mx nl no ro se sg us`). The script checks your choice against the app's current relay list before changing anything, and refuses one that no server can satisfy, because with lockdown on an unsatisfiable choice would leave the Mac offline.

## The two profiles

| Setting | Daily | Sensitive |
|---|---|---|
| Lockdown mode | on | on |
| Auto-connect | on | on |
| Local network sharing | blocked | blocked |
| Split tunnelling | off | off |
| Quantum-resistant tunnel | on | on |
| DAITA | on | on |
| Multihop | automatic, when DAITA needs it | always, through the entry you choose |
| DAITA "Direct only" (2026.5) | off | on |
| Obfuscation | automatic | QUIC |
| DNS | Mullvad's, blocking ads, trackers, malware | same |
| IPv6 inside the tunnel | off | off |
| Exit servers | any (owned only with `--owned-exit`) | same |

## Why each setting

**DAITA** is the one feature that attacks website fingerprinting directly: it pads packets to constant size, injects cover traffic and distorts the timing of a session, so that a machine-learning classifier cannot read the site or activity off the packet stream (reported, Mullvad; built on the peer-reviewed Maybenot framework). The cost is bandwidth and some latency.

**Multihop, and a trap in release 2026.5.** DAITA runs only on some servers: 122 of the 536 active ones, in 21 countries (established, from the relay list). When the chosen exit lacks it, the app routes through a DAITA-capable entry automatically, and that entry is chosen as the one geographically closest to the exit (established, from the relay selector's code). Automatic multihop therefore gives you DAITA, but in practice not a second jurisdiction (inferred: the nearest server to the exit is normally in the same city or country). For that you need explicit multihop, and here is the trap: in 2026.5, with DAITA on and "Direct only" off, the app replaces the entry you chose with its own nearest-to-exit pick (established: with both switches in that position the code builds a multihop query whose entry is chosen automatically). The sensitive profile therefore turns "Direct only" on, which is what keeps your entry. The next release replaces both switches with a single multihop setting (always, auto or never) and removes the "Direct only" command; the kit detects which generation it is talking to and uses the right commands, and stops without changing anything if it meets a third.

**Obfuscation.** "Automatic" first tries plain WireGuard and falls back to obfuscation only when that fails (established, relay-selector documentation), so on an ordinary network it does not hide VPN use. Forcing QUIC wraps the tunnel in QUIC on port 443 (established; the app's implementation is MASQUE, the HTTP/3 proxying protocol), traffic that is common on any network. For this purpose it beats LWO. LWO scrambles WireGuard's headers but leaves its fixed message sizes intact (inferred from the code: it XORs the header in place and adds nothing), and traffic that looks like no protocol at all is itself a signal to censors who flag fully encrypted traffic, as the Great Firewall has been documented to do (reported, Wu and colleagues, USENIX Security 2023). The cost of QUIC is overhead and a smaller pool of servers (230 of 536).

**Lockdown and auto-connect** close the windows in which the Mac could touch the network uncovered. The kill switch proper is always on in Mullvad and covers reconnections and failures; lockdown extends the block to the state in which you have deliberately disconnected (established, Mullvad's security document), so that the Mac's only choices are the tunnel or nothing.

**The quantum-resistant tunnel** protects against traffic recorded now and decrypted later. It is the default; the kit sets it anyway, so that the audit has something definite to check.

**DNS** stays with Mullvad's own resolver inside the tunnel. A third-party resolver would hand your browsing metadata to one more party. Ads, trackers and malware are blocked; adult content, gambling and social media are left for you to decide (`--block-adult-content`, `--block-gambling`, `--block-social-media`).

**Local network sharing off, split tunnelling off, IPv6 in the tunnel off**: fewer paths out and fewer ways in. The one cost is named below.

**Owned exits** (`--owned-exit`) remove the hosting company from the list of parties with physical access to the exit server. The gain is real but smaller than it sounds: every active server in the relay list is flagged as booting diskless from RAM through System Transparency's stboot (established that the flag is set on all 536; its meaning is reported by Mullvad). The cost is choice: 113 owned servers in 12 countries. It is worth adding to sensitive sessions whenever the exit country you need has owned servers.

## Corrections to the earlier notes

The working notes of 26 August 2026 that this setup started from (the Mullvad hardening skill) are wrong on three points, now established from the source and the relay list. DAITA is not available across all servers but on about a quarter of them. Automatic multihop does not carry most of the benefit of explicit multihop: it carries DAITA, not jurisdictional separation. And "leave Direct only off" is right for daily use but wrong, in release 2026.5, for multihop through a chosen entry.

## What remains exposed

- **Boot.** On Windows and Linux, Mullvad blocks traffic from early in boot until its service starts; its security document describes no such mechanism for macOS, and its macOS firewall code contains none (established, from a reading of both). Since the macOS packet filter's rules live in memory, the inference is a short window at boot in which system processes could reach the network before the service applies its rules. Its length on your Mac is unknown. When it matters, turn Wi-Fi off before shutting down and back on only once the Mullvad icon shows the tunnel connected or blocked.
- **Local reconfiguration.** Any process on the Mac can change these settings. `audit.sh` is the answer: run it after every update and periodically, and keep its log. A setting found changed that you did not change is an audit observation to keep verbatim, not something to tidy away.
- **What the audit can and cannot prove.** Most of its checks rest on what the Mullvad service reports about itself. Two do not: the answer from Mullvad's check service about where the traffic arrived from, and the lockdown probe. Those two are the ones to trust if the others disagree with them.
- **The local network.** Blocking local network sharing and lockdown mode will stop the screen-shadowing arrangement between two Macs, which needs local reachability. Use the two at different times, or reconcile them deliberately; do not quietly loosen the VPN.
- **The API.** While blocked, the service (and other root processes) can still reach Mullvad's API, so that it can log in and fetch server lists (established, security document). That is not a leak of your traffic, but it means "blocked" is not total silence.
- **The default exit.** Since release 2026.2 the app's default location is wherever the machine appears to be, if Mullvad has servers there (established, changelog). Unless you choose an exit, the exit therefore sits in your own jurisdiction.

## What was tested, and what was not

`tests/run.sh` runs 74 checks against a simulated Mac: a stand-in for Mullvad's command-line tool that reproduces the output formats of release 2026.5 and of the next generation, and stand-ins for the signing, network and GnuPG tools. The suite passes with bash 5 and with bash 3.2.57, the version macOS ships. It covers both profiles, both command generations, every refusal (wrong signature, old version, logged out, impossible server choice, same country twice), the audit's detection of changed settings, of a leaking lockdown and of the entry-override trap, and it checks that no output ever contains a location or an address. The relay-availability check was also run against Mullvad's real relay list and agrees with an independent count.

What could not be tested here is the Mac itself: the exact wording that `pkgutil` and `spctl` print on your version of macOS, reading the relay list through JavaScript for Automation, and the real service's behaviour. The first real run is the real test; if a check fails on wording alone, the output shows what was found.

## Maintenance

This setup stays on permanently, so the work is maintenance: keep the app updated (the stealth features change quickly), and after every macOS update run `./audit.sh --test-lockdown`, since system updates can reset network settings. The kit requires release 2026.5 or later. When Mullvad changes its commands again, the scripts stop before changing anything and say so.

## Next to this

Website fingerprinting is also a browser problem, and Mullvad Browser (built with the Tor Project) is the companion to this VPN. For the most sensitive sessions, the Nym mixnet remains the tool. And on the local network, macOS can rotate the Wi-Fi hardware address (reported, System Settings, Wi-Fi, "Private Wi-Fi address"), which the VPN cannot hide.

## Files

- `verify-download.sh` checks an installer before it is opened.
- `harden.sh` applies a profile and reconnects.
- `audit.sh` checks the configuration and the live connection, read-only unless `--test-lockdown` is given.
- `lib/common.sh` holds the shared checks and the pinned identifiers.
- `lib/relay-check.js` counts the servers able to satisfy a choice of countries.
- `tests/` holds the simulated Mac and the test suite.

Pages of record, for re-verification:

- DAITA: https://mullvad.net/en/vpn/daita
- Security model of the app: https://github.com/mullvad/mullvadvpn-app/blob/main/docs/security.md
- Relay selection: https://github.com/mullvad/mullvadvpn-app/blob/main/docs/relay-selector.md
- Changelog: https://github.com/mullvad/mullvadvpn-app/blob/main/CHANGELOG.md
- Verifying downloads and signing keys: https://mullvad.net/en/open-source
