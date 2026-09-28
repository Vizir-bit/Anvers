#!/bin/bash
#
# wipe-node.sh: find every Node.js runtime running or installed on this Mac,
# kill the processes and the applications that spawn them, and, when you type
# an application's name, delete that application and its support files.
#
#   bash wipe-node.sh            inventory: read-only report (the default)
#   bash wipe-node.sh stop       kill every node process, its descendants, and every
#                                process of the application that owns it
#   bash wipe-node.sh remove     kill, then offer each application that runs or contains
#                                node for deletion; loose node files are listed, not deleted
#
# An application's own files are those named by its bundle id, as a whole name or
# a dotted component, or exactly by one of its names, plus the dot-folder named
# after the last part of its bundle id (~/.codex for com.openai.codex). Items that
# carry only its vendor's prefix or signing team are offered after it, separately.
# Nothing is deleted until you type the name you are shown.
#
# Killing is lethal and precise: targets are frozen with SIGSTOP, which cannot be
# caught or ignored, so no parent can restart a child it sees die; the frozen set
# is widened until no member has an unfrozen descendant, and only then does each
# member receive SIGKILL. A pid is signalled only while it still runs the
# executable recorded for it, so a recycled pid is never hit; launchd, this
# script and its ancestors are never targets.
#
# Prefix with sudo to reach other users' processes and system launch items; the
# invoking user's home is used either way. Every run writes a record to
# ~/mdm-defense and prints its SHA-256. Written for the bash 3.2 of macOS.

set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
LC_ALL=C
export PATH LC_ALL
PLISTBUDDY=/usr/libexec/PlistBuddy

MODE=${1:-inventory}
case $MODE in
  inventory | stop | remove) ;;
  *) printf 'usage: bash %s [inventory|stop|remove]\n' "${0##*/}" >&2; exit 2 ;;
esac
if [ "$(uname -s)" != Darwin ]; then
  echo "wipe-node.sh is written for macOS." >&2
  exit 2
fi

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1
if [ $IS_ROOT -eq 1 ] && [ -n "${SUDO_USER:-}" ]; then TARGET_USER=$SUDO_USER; else TARGET_USER=$(id -un); fi
TARGET_UID=$(id -u "$TARGET_USER")
TARGET_HOME=$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
[ -d "$TARGET_HOME" ] || TARGET_HOME=$HOME

RECORD_DIR=$TARGET_HOME/mdm-defense
RECORD=$RECORD_DIR/wipe-node-$MODE-$(date -u +%Y%m%dT%H%M%SZ).txt
mkdir -p "$RECORD_DIR" && : >"$RECORD" || exit 1
[ $IS_ROOT -eq 1 ] && chown "$TARGET_USER" "$RECORD_DIR" "$RECORD"

say() { printf '%s\n' "$*"; printf '%s\n' "$*" >>"$RECORD"; }
indent() { while IFS= read -r line; do say "    $line"; done; }
indent_more() { while IFS= read -r line; do say "      $line"; done; }
OWN=""
VENDOR=""
section() { say ""; say "== $*"; }

# ---- processes -------------------------------------------------------------

# Every running process as: pid ppid user executable (the executable may contain spaces).
process_table() { ps -axww -o pid=,ppid=,user=,comm= 2>/dev/null; }

node_rows() {  # processes whose executable is called node, nodejs or node_repl
  process_table | while read -r pid ppid user exe; do
    case ${exe##*/} in node | nodejs | node_repl) printf '%s %s %s %s\n' "$pid" "$ppid" "$user" "$exe" ;; esac
  done
}

bundle_rows() {  # $1 = bundle; processes whose executable lies inside it
  process_table | while read -r pid ppid user exe; do
    case $exe in "$1"/*) printf '%s %s %s %s\n' "$pid" "$ppid" "$user" "$exe" ;; esac
  done
}

bundle_of() {  # outermost .app bundle that contains path $1, if any
  case $1 in *.app/*) printf '%s\n' "${1%%.app/*}.app" ;; esac
}

tree() {  # $1 = pids, one per line; prints "pid executable" for them and all their descendants
  ps -axww -o pid=,ppid=,comm= 2>/dev/null |
    awk -v roots="$(printf '%s' "$1" | tr '\n' ' ')" -v self="$$" '
      {
        if (!match($0, /^ *[0-9]+ +[0-9]+ /)) next
        split(substr($0, 1, RLENGTH), f, " ")
        e = substr($0, RLENGTH + 1)
        sub(/ +$/, "", e)
        exe[f[1]] = e; parent[f[1]] = f[2]; order[++n] = f[1]
      }
      END {
        for (a = self; (a in parent) && a + 0 > 1; a = parent[a]) spare[a] = 1
        k = split(roots, r, " ")
        for (i = 1; i <= k; i++) if (r[i] in exe) keep[r[i]] = 1
        do {
          grew = 0
          for (i = 1; i <= n; i++) {
            p = order[i]
            if (!(p in keep) && (parent[p] in keep)) { keep[p] = 1; grew = 1 }
          }
        } while (grew)
        for (p in keep) if (p + 0 > 1 && !(p in spare)) print p " " exe[p]
      }'
}

runs() {  # $1 = pid, $2 = executable; true while that pid lives and still runs that executable
  local stat exe
  stat=$(ps -p "$1" -o stat= 2>/dev/null | tr -d ' ')
  case $stat in '' | Z*) return 1 ;; esac
  exe=$(ps -p "$1" -o comm= 2>/dev/null | sed 's/^ *//; s/ *$//')
  [ "$exe" = "$2" ]
}

kill_tree() {  # $1 = pids, one per line; freeze them and every descendant, then kill them all
  local frozen seen snap grew pid exe pass left i
  frozen=""
  seen=" "
  pass=0
  while [ $pass -lt 10 ]; do
    snap=$(tree "$1")
    grew=0
    while read -r pid exe; do
      [ -n "$pid" ] || continue
      case $seen in *" $pid "*) continue ;; esac
      runs "$pid" "$exe" && kill -STOP "$pid" 2>/dev/null
      seen="$seen$pid "
      frozen="$frozen$pid $exe
"
      grew=1
    done <<EOF
$snap
EOF
    [ $grew -eq 1 ] || break
    pass=$((pass + 1))
  done
  [ -n "$frozen" ] || return 0
  say "  frozen:$seen"
  printf '%s\n' "$frozen" | while read -r pid exe; do
    runs "$pid" "$exe" && kill -KILL "$pid" 2>/dev/null
  done
  i=0
  while :; do
    left=$(printf '%s\n' "$frozen" | while read -r pid exe; do
      runs "$pid" "$exe" && printf '%s ' "$pid"
    done)
    if [ -z "$left" ] || [ $i -ge 10 ]; then break; fi
    sleep 0.5
    i=$((i + 1))
  done
  if [ -n "$left" ]; then
    say "  [!!] still alive: $left"
    [ $IS_ROOT -eq 0 ] && say "       run with sudo if they belong to another user"
    return 1
  fi
  say "  [OK] killed $(printf '%s\n' "$frozen" | grep -c .) processes"
}

# ---- applications ----------------------------------------------------------

plist_get() { "$PLISTBUDDY" -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }

valid_id() {  # a reverse-DNS bundle id safe to use in name patterns and queries
  case $1 in '' | *[!A-Za-z0-9.-]* | .* | *. | *..*) return 1 ;; *.*) return 0 ;; esac
  return 1
}

protected() {  # $1 = bundle, $2 = bundle id; parts of macOS are never offered for deletion
  case $1 in /System/*) return 0 ;; esac
  case $2 in com.apple.*) return 0 ;; esac
  return 1
}

launch_items() {  # $1 = bundle, $2 = valid bundle id; launchd plists that start it
  local dir plist
  for dir in "$1/Contents/Library/LaunchAgents" "$1/Contents/Library/LaunchDaemons" \
    "$TARGET_HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons; do
    [ -d "$dir" ] || continue
    for plist in "$dir"/*.plist; do
      [ -f "$plist" ] || continue
      case $plist in "$1"/*) printf '%s\n' "$plist"; continue ;; esac
      if plutil -convert xml1 -o - "$plist" 2>/dev/null | grep -qF -e "$1" -e "$2"; then
        printf '%s\n' "$plist"
      fi
    done
  done
}

bootout() {  # $1 = launchd plist; unload its job so launchd cannot restart what is killed
  local label domain
  label=$("$PLISTBUDDY" -c 'Print :Label' "$1" 2>/dev/null) || return 0
  case $1 in */LaunchDaemons/*) domain=system ;; *) domain=gui/$TARGET_UID ;; esac
  if launchctl bootout "$domain/$label" 2>/dev/null; then say "  unloaded $domain/$label"; fi
}

LIBRARY_DIRS='Application Support
Caches
Preferences
Preferences/ByHost
HTTPStorages
Saved Application State
WebKit
Containers
Group Containers
Application Scripts
Logs
Cookies
LaunchAgents
LaunchDaemons
PrivilegedHelperTools'

library_find() {  # $@ = find name tests; entries directly inside each Library folder, user and system
  local sub base
  while IFS= read -r sub; do
    for base in "$TARGET_HOME/Library/$sub" "/Library/$sub"; do
      [ -d "$base" ] || continue
      find "$base" -mindepth 1 -maxdepth 1 \( "$@" \) 2>/dev/null
    done
  done <<EOF
$LIBRARY_DIRS
EOF
}

app_names() {  # $1 = bundle; the names the app goes by, safe as exact name patterns
  { basename "$1" .app; plist_get "$1" CFBundleName; plist_get "$1" CFBundleDisplayName; } |
    grep -v -e '^$' -e '[][*?/]' | sort -u
}

team_of() {  # $1 = bundle; the signing team identifier, if the bundle has one
  codesign -dvv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p' | grep -E '^[A-Z0-9]{10}$'
}

support_paths() {  # $1 = bundle, $2 = valid bundle id; what the app keeps outside its bundle
  local bundle=$1 id=$2 names n p
  names=$(app_names "$bundle")
  set -- -name "$id" -o -name "$id.*" -o -name "*.$id" -o -name "*.$id.*"
  while IFS= read -r n; do
    [ -n "$n" ] && set -- "$@" -o -name "$n"
  done <<EOF
$names
EOF
  {
    library_find "$@"
    # the dot-folder named after the last part of the bundle id, as ~/.codex for com.openai.codex
    for p in "$TARGET_HOME/.${id##*.}" "$TARGET_HOME/.config/${id##*.}"; do
      if [ -e "$p" ] || [ -L "$p" ]; then printf '%s\n' "$p"; fi
    done
  } | sort -u
}

vendor_paths() {  # $1 = valid bundle id, $2 = team id (may be empty); items of the same vendor or signing team
  local vendor=${1%.*}
  valid_id "$vendor" || return 0
  if [ -n "$2" ]; then
    library_find -name "$vendor.*" -o -name "*.$vendor.*" -o -name "$2.*"
  else
    library_find -name "$vendor.*" -o -name "*.$vendor.*"
  fi | sort -u
}

minus() {  # lines of list $1 that are neither in list $2 nor inside bundle $3
  printf '%s\n' "$1" | while IFS= read -r l; do
    [ -n "$l" ] || continue
    if [ -n "$3" ]; then
      case $l in "$3" | "$3"/*) continue ;; esac
    fi
    case "
$2
" in *"
$l
"*) continue ;; esac
    printf '%s\n' "$l"
  done
}

deletion_lists() {  # $1 = bundle, $2 = valid bundle id; sets OWN and VENDOR for the preview and the deletion
  OWN=$({ support_paths "$1" "$2"; launch_items "$1" "$2"; } | sort -u)
  OWN=$(minus "$OWN" "" "$1")
  VENDOR=$(minus "$(vendor_paths "$2" "$(team_of "$1")")" "$OWN" "$1")
}

delete_paths() {  # $1 = newline list of paths
  printf '%s\n' "$1" | while IFS= read -r p; do
    [ -n "$p" ] || continue
    rm -rf -- "$p" 2>/dev/null
    if [ -e "$p" ] || [ -L "$p" ]; then say "  [!!] could not delete $p"; else say "  [OK] deleted $p"; fi
  done
}

tcc_grants() {  # $1 = valid bundle id; what the privacy databases record for it
  local db label rows
  for db in "/Library/Application Support/com.apple.TCC/TCC.db" \
    "$TARGET_HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
    case $db in /Library/*) label=system ;; *) label=user ;; esac
    if rows=$(sqlite3 -readonly "$db" "SELECT service, auth_value FROM access WHERE client = '$1';" 2>/dev/null); then
      if [ -z "$rows" ]; then
        say "    privacy, $label database: no entry"
        continue
      fi
      printf '%s\n' "$rows" | awk -F'|' '{
          v = $2 == 2 ? "allowed" : $2 == 0 ? "denied" : $2 == 3 ? "limited" : "value " $2
          print $1 " " v }' | while IFS= read -r l; do say "    privacy, $label database: $l"; done
    else
      say "    privacy, $label database: not readable; the terminal needs Full Disk Access"
    fi
  done
}

reset_tcc() {  # $1 = valid bundle id; withdraw every privacy grant while tccutil can still resolve it
  if [ $IS_ROOT -eq 1 ] && [ "$TARGET_USER" != root ]; then
    say "  tccutil in $TARGET_USER's session: $(launchctl asuser "$TARGET_UID" sudo -u "$TARGET_USER" /usr/bin/tccutil reset All "$1" 2>&1)"
  fi
  say "  tccutil as $(id -un): $(tccutil reset All "$1" 2>&1)"
}

describe_app() {  # $1 = bundle
  local id ver out team
  id=$(plist_get "$1" CFBundleIdentifier)
  ver=$(plist_get "$1" CFBundleShortVersionString)
  say "  $1"
  say "    bundle id ${id:-unknown}, version ${ver:-unknown}"
  codesign -dvv "$1" 2>&1 | grep -E '^(Authority|TeamIdentifier|Timestamp)=' | indent
  if out=$(codesign --verify --deep --strict "$1" 2>&1); then
    say "    signature verified: the bundle is unchanged since it was signed"
  else
    say "    [!!] signature verification failed:"
    printf '%s\n' "$out" | indent
  fi
  say "    processes running from it: $(bundle_rows "$1" | grep -c .)"
  if valid_id "$id"; then
    launch_items "$1" "$id" | while IFS= read -r p; do say "    launch item: $p"; done
    tcc_grants "$id"
    if ! protected "$1" "$id"; then
      deletion_lists "$1" "$id"
      team=$(team_of "$1")
      say "    its own files outside the bundle, which remove offers with it:"
      printf '%s\n' "${OWN:-none}" | indent_more
      say "    other items of vendor ${id%.*}${team:+ or team $team}, which remove offers separately:"
      printf '%s\n' "${VENDOR:-none}" | indent_more
    fi
  fi
}

# ---- files -----------------------------------------------------------------

node_files() {  # Mach-O executables named node, nodejs or node_repl, in the places runtimes live
  local root
  for root in /Applications "$TARGET_HOME/Applications" /usr/local /opt \
    "/Library/Application Support" "$TARGET_HOME/Library/Application Support" \
    "$TARGET_HOME/.nvm" "$TARGET_HOME/.volta" "$TARGET_HOME/.fnm" "$TARGET_HOME/.asdf" \
    "$TARGET_HOME/.local" "$TARGET_HOME/n" "$TARGET_HOME/.n"; do
    [ -d "$root" ] || continue
    find "$root" \( -name node -o -name nodejs -o -name node_repl \) -type f -perm -100 2>/dev/null
  done | sort -u | while IFS= read -r f; do
    case $(file -b "$f" 2>/dev/null) in Mach-O*) printf '%s\n' "$f" ;; esac
  done
}

list_files() {  # $1 = newline list of files
  if [ -z "$1" ]; then
    say "  none"
    return
  fi
  printf '%s\n' "$1" | while IFS= read -r f; do
    say "  $f"
    say "    sha256 $(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')"
    if [ -n "$(bundle_of "$f")" ]; then say "    inside $(bundle_of "$f")"; else say "    not inside an application bundle"; fi
  done
}

# ---- actions ---------------------------------------------------------------

stop_loose() {  # node processes that belong to no application bundle
  if [ -z "$LOOSE_NODES" ]; then
    say "  no node process outside an application"
    return
  fi
  printf '%s\n' "$LOOSE_NODES" | indent
  kill_tree "$(printf '%s\n' "$LOOSE_NODES" | awk '{print $1}')"
}

stop_bundle() {  # $1 = bundle, $2 = bundle id (may be empty)
  say "  $1"
  if valid_id "$2"; then
    launch_items "$1" "$2" | while IFS= read -r p; do bootout "$p"; done
  fi
  kill_tree "$(bundle_rows "$1" | awk '{print $1}')"
}

remove_bundle() {  # $1 = bundle
  local name id vendor answer p
  name=$(basename "$1" .app)
  id=$(plist_get "$1" CFBundleIdentifier)
  section "delete $1?"
  if protected "$1" "$id"; then
    say "  refused: this belongs to macOS"
    return
  fi
  OWN=""
  VENDOR=""
  if valid_id "$id"; then
    deletion_lists "$1" "$id"
  else
    say "  no usable bundle id, so only the bundle itself is offered"
  fi
  say "  would delete:"
  say "    $1"
  [ -n "$OWN" ] && printf '%s\n' "$OWN" | indent
  printf '  Type %s to delete all of this, or press Return to keep it: ' "$name" >/dev/tty
  answer=""
  read -r answer </dev/tty
  if [ "$answer" != "$name" ]; then
    say "  kept"
    return
  fi
  say "  confirmed by typing the name"
  find "$1" \( -name node -o -name nodejs -o -name node_repl \) -type f -perm -100 2>/dev/null | while IFS= read -r p; do
    say "  sha256 $(shasum -a 256 "$p" | awk '{print $1}')  $p"
  done
  stop_bundle "$1" "$id"
  valid_id "$id" && reset_tcc "$id"
  rm -rf -- "$1" 2>/dev/null
  if [ -e "$1" ]; then
    say "  [!!] could not delete $1: macOS refuses this to a terminal without App Management"
    say "       permission, or the bundle needs sudo. Drag it to the Bin in Finder, empty the"
    say "       Bin, then run 'bash wipe-node.sh inventory' to confirm."
  else
    say "  [OK] deleted $1"
  fi
  delete_paths "$OWN"
  [ -n "$VENDOR" ] || return 0
  vendor=${id%.*}
  say "  other items of vendor $vendor or its signing team, not tied to this app by name:"
  printf '%s\n' "$VENDOR" | indent
  printf '  Type %s to delete these too, or press Return to keep them: ' "$vendor" >/dev/tty
  answer=""
  read -r answer </dev/tty
  if [ "$answer" != "$vendor" ]; then
    say "  kept"
    return
  fi
  say "  confirmed by typing $vendor"
  delete_paths "$VENDOR"
}

verify() {  # $1 = newline list of bundles that were acted on
  local now rows b
  sleep 5
  section "verification, 5 s later"
  now=$(node_rows)
  if [ -z "$now" ]; then
    say "  [OK] no node process is running"
  else
    say "  [!!] node processes running now (pid ppid user executable):"
    printf '%s\n' "$now" | indent
  fi
  printf '%s\n' "$1" | while IFS= read -r b; do
    [ -n "$b" ] || continue
    rows=$(bundle_rows "$b")
    if [ -z "$rows" ]; then
      say "  [OK] nothing from $b is running"
    else
      say "  [!!] $b is running again (pid ppid user executable):"
      printf '%s\n' "$rows" | indent
    fi
  done
}

seal() {
  say ""
  say "record: $RECORD"
  printf 'Record SHA-256: %s  (note it; it seals this record)\n' "$(shasum -a 256 "$RECORD" | awk '{print $1}')"
}

# ---- run -------------------------------------------------------------------

say "wipe-node.sh $MODE  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "user $TARGET_USER, running as $(id -un), macOS $(sw_vers -productVersion 2>/dev/null) build $(sw_vers -buildVersion 2>/dev/null)"

section "running node processes"
NODES=$(node_rows)
if [ -z "$NODES" ]; then
  say "  none"
else
  printf '%s\n' "$NODES" | while read -r pid ppid user exe; do
    say "  pid $pid, user $user, started $(ps -p "$pid" -o lstart= 2>/dev/null)"
    say "    $exe"
    say "    parent $ppid: $(ps -p "$ppid" -o comm= 2>/dev/null)"
  done
fi
RUNNING_APPS=$(printf '%s\n' "$NODES" | while read -r pid ppid user exe; do
  [ -n "$exe" ] && bundle_of "$exe"
done | sort -u)
LOOSE_NODES=$(printf '%s\n' "$NODES" | while read -r pid ppid user exe; do
  [ -n "$exe" ] && [ -z "$(bundle_of "$exe")" ] && printf '%s %s %s %s\n' "$pid" "$ppid" "$user" "$exe"
done)

APPS=$RUNNING_APPS
if [ "$MODE" != stop ]; then
  section "node executables on disk (Mach-O files named node, nodejs or node_repl; symlinks excluded)"
  printf '  searching; this can take a minute...\n'
  FILES=$(node_files)
  list_files "$FILES"
  DISK_APPS=$(printf '%s\n' "$FILES" | while IFS= read -r f; do [ -n "$f" ] && bundle_of "$f"; done | sort -u)
  APPS=$(printf '%s\n%s\n' "$RUNNING_APPS" "$DISK_APPS" | grep . | sort -u)
fi

section "applications that run or contain node"
if [ -z "$APPS" ]; then
  say "  none"
else
  printf '%s\n' "$APPS" | while IFS= read -r b; do describe_app "$b"; done
fi

case $MODE in
  stop)
    section "killing"
    stop_loose
    printf '%s\n' "$RUNNING_APPS" | while IFS= read -r b; do
      [ -n "$b" ] && stop_bundle "$b" "$(plist_get "$b" CFBundleIdentifier)"
    done
    verify "$RUNNING_APPS"
    ;;
  remove)
    section "killing node processes outside applications"
    stop_loose
    while IFS= read -r b <&3; do
      [ -n "$b" ] && remove_bundle "$b"
    done 3<<EOF
$APPS
EOF
    verify "$APPS"
    section "node executables still on disk (loose files are listed, never deleted)"
    printf '  searching; this can take a minute...\n'
    list_files "$(node_files)"
    ;;
esac

seal
