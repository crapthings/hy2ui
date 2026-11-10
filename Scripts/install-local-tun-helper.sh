#!/bin/bash
# Installs the fixed local TUN daemon only after an explicit administrator invocation.
set -euo pipefail
umask 077
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# Rejects paths whose directory entries can be replaced by an ordinary user.
require_root_directory() {
  local checked_path="$1" checked_mode
  [[ -d "$checked_path" && ! -L "$checked_path" ]] || { echo "Unsafe directory: $checked_path" >&2; exit 1; }
  [[ "$(/usr/bin/stat -f %u "$checked_path")" = 0 ]] || { echo "Directory must be root-owned: $checked_path" >&2; exit 1; }
  checked_mode="$(/usr/bin/stat -f %Lp "$checked_path")"
  (( (8#$checked_mode & 8#022) == 0 )) || { echo "Directory must not be group/world writable: $checked_path" >&2; exit 1; }
}

# Rejects a privileged executable or state file that ordinary users could replace or modify.
require_root_file() {
  local checked_path="$1" checked_mode
  [[ -f "$checked_path" && ! -L "$checked_path" ]] || { echo "Unsafe file: $checked_path" >&2; exit 1; }
  [[ "$(/usr/bin/stat -f %u "$checked_path")" = 0 ]] || { echo "File must be root-owned: $checked_path" >&2; exit 1; }
  checked_mode="$(/usr/bin/stat -f %Lp "$checked_path")"
  (( (8#$checked_mode & 8#022) == 0 )) || { echo "File must not be group/world writable: $checked_path" >&2; exit 1; }
}

# Checks the user-approved source bundle without trusting paths writable by other accounts.
require_source_path() {
  local checked_path="$1" checked_mode checked_owner
  while [[ "$checked_path" != / ]]; do
    [[ ! -L "$checked_path" && -e "$checked_path" ]] || { echo "Unsafe source path: $checked_path" >&2; exit 1; }
    checked_owner="$(/usr/bin/stat -f %u "$checked_path")"
    [[ "$checked_owner" = 0 || "$checked_owner" = "$allowed_uid" ]] || { echo "Source is owned by another user: $checked_path" >&2; exit 1; }
    checked_mode="$(/usr/bin/stat -f %Lp "$checked_path")"
    (( (8#$checked_mode & 8#022) == 0 )) || { echo "Source is writable by another account: $checked_path" >&2; exit 1; }
    checked_path="$(/usr/bin/dirname "$checked_path")"
  done
}

# Removes only this invocation's root-private staging directory.
cleanup_staging() {
  case "${staging_directory:-}" in
    "$helper_directory"/.install.*) /bin/rm -rf -- "$staging_directory" ;;
  esac
}

# Waits briefly for the old daemon's exclusive recovery lock before refusing an unsafe replacement.
recover_dns() {
  local recovery_deadline=$((SECONDS + 20)) recovery_error
  while ! recovery_error="$("$helper_path" --recover-dns 2>&1)"; do
    if (( SECONDS >= recovery_deadline )); then
      echo "$recovery_error" >&2
      echo 'DNS recovery did not complete; installed files were preserved. Retry after the old service has stopped.' >&2
      exit 1
    fi
    /bin/sleep 0.2
  done
}

[[ "$EUID" = 0 ]] || { echo 'Run from your normal account with: sudo Scripts/install-local-tun-helper.sh [Hy2UI.app]' >&2; exit 1; }
allowed_uid="${SUDO_UID:-}"
[[ "$allowed_uid" =~ ^[0-9]+$ ]] && (( 10#$allowed_uid > 0 && 10#$allowed_uid < 4294967295 )) || {
  echo 'SUDO_UID must identify the normal account that will use Hy2UI; invoke this script through sudo.' >&2
  exit 1
}
[[ "$#" -le 1 ]] || { echo 'Usage: sudo Scripts/install-local-tun-helper.sh [Hy2UI.app]' >&2; exit 1; }
script_directory="$(cd "$(/usr/bin/dirname "$0")" && pwd -P)"
project_directory="$(/usr/bin/dirname "$script_directory")"
source_app="${1:-$project_directory/.build/xcode/Build/Products/Debug/Hy2UI.app}"
[[ -d "$source_app" && ! -L "$source_app" ]] || { echo 'Build Hy2UI first, or pass the application bundle path.' >&2; exit 1; }
source_app="$(cd "$source_app" && pwd -P)"
source_helper="$source_app/Contents/Helpers/hy2-local-tun-helper"
source_worker="$source_app/Contents/Helpers/hy2-tun-worker"
for source_binary in "$source_helper" "$source_worker"; do
  require_source_path "$source_binary"
  [[ -x "$source_binary" ]] || { echo "Missing executable: $source_binary" >&2; exit 1; }
  /usr/bin/codesign --verify --strict "$source_binary"
done

helper_directory=/Library/PrivilegedHelperTools/dev.hy2ui
helper_path="$helper_directory/hy2-local-tun-helper"
worker_path="$helper_directory/hy2-tun-worker"
plist_path=/Library/LaunchDaemons/dev.hy2ui.local-tun.plist
socket_path="$helper_directory/control.sock"
log_path=/private/var/log/dev.hy2ui.local-tun.log
label=dev.hy2ui.local-tun
manifest_path="$helper_directory/installation.plist"
expected_helper_hash="${HY2_EXPECTED_HELPER_SHA256:-}"
expected_worker_hash="${HY2_EXPECTED_WORKER_SHA256:-}"
for expected_hash in "$expected_helper_hash" "$expected_worker_hash"; do
  [[ -z "$expected_hash" || "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || { echo 'Invalid expected executable digest.' >&2; exit 1; }
done
for root_directory in / /Library /Library/LaunchDaemons /private /private/var /private/var/log; do require_root_directory "$root_directory"; done
if [[ ! -e /Library/PrivilegedHelperTools && ! -L /Library/PrivilegedHelperTools ]]; then
  /usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
fi
require_root_directory /Library/PrivilegedHelperTools
if [[ ! -e "$helper_directory" && ! -L "$helper_directory" ]]; then
  /usr/bin/install -d -o root -g wheel -m 755 "$helper_directory"
fi
require_root_directory "$helper_directory"
for installed_file in "$helper_path" "$worker_path" "$plist_path" "$log_path" "$manifest_path"; do
  if [[ -e "$installed_file" || -L "$installed_file" ]]; then require_root_file "$installed_file"; fi
done

staging_directory="$(/usr/bin/mktemp -d "$helper_directory/.install.XXXXXX")"
trap cleanup_staging EXIT
/usr/bin/install -o root -g wheel -m 755 "$source_helper" "$staging_directory/hy2-local-tun-helper"
/usr/bin/install -o root -g wheel -m 755 "$source_worker" "$staging_directory/hy2-tun-worker"
/usr/bin/codesign --verify --strict "$staging_directory/hy2-local-tun-helper"
/usr/bin/codesign --verify --strict "$staging_directory/hy2-tun-worker"
helper_hash="$(/usr/bin/shasum -a 256 "$staging_directory/hy2-local-tun-helper" | /usr/bin/cut -d ' ' -f 1)"
worker_hash="$(/usr/bin/shasum -a 256 "$staging_directory/hy2-tun-worker" | /usr/bin/cut -d ' ' -f 1)"
[[ -z "$expected_helper_hash" || "$helper_hash" = "$expected_helper_hash" ]] || { echo 'Helper changed after administrator authorization was requested.' >&2; exit 1; }
[[ -z "$expected_worker_hash" || "$worker_hash" = "$expected_worker_hash" ]] || { echo 'Worker changed after administrator authorization was requested.' >&2; exit 1; }
/usr/bin/plutil -create xml1 "$staging_directory/installation.plist"
/usr/bin/plutil -insert version -integer 1 "$staging_directory/installation.plist"
/usr/bin/plutil -insert helperSHA256 -string "$helper_hash" "$staging_directory/installation.plist"
/usr/bin/plutil -insert workerSHA256 -string "$worker_hash" "$staging_directory/installation.plist"
/usr/bin/plutil -insert allowedUID -integer "$allowed_uid" "$staging_directory/installation.plist"
cat > "$staging_directory/daemon.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$helper_path</string><string>--allowed-uid</string><string>$allowed_uid</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ExitTimeOut</key><integer>20</integer>
<key>StandardOutPath</key><string>$log_path</string>
<key>StandardErrorPath</key><string>$log_path</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$staging_directory/daemon.plist" >/dev/null

# Old credentials and routing remain confined to the old session until its DNS recovery succeeds.
if /bin/launchctl print "system/$label" >/dev/null 2>&1; then /bin/launchctl bootout "system/$label"; fi
if [[ -e "$helper_path" ]]; then
  recover_dns
elif [[ -e "$helper_directory/dns-recovery.plist" || -L "$helper_directory/dns-recovery.plist" || -e "$helper_directory/direct-routes.json" || -L "$helper_directory/direct-routes.json" ]]; then
  echo 'DNS recovery exists but the installed recovery helper is missing; installation stopped without replacing it.' >&2
  exit 1
fi
if [[ -e "$socket_path" || -L "$socket_path" ]]; then
  [[ -S "$socket_path" && ! -L "$socket_path" ]] || { echo 'Unexpected object at the fixed local TUN socket path.' >&2; exit 1; }
  /bin/rm -- "$socket_path"
fi
/bin/mv -f "$staging_directory/hy2-tun-worker" "$worker_path"
/bin/mv -f "$staging_directory/hy2-local-tun-helper" "$helper_path"
/usr/bin/install -o root -g wheel -m 644 "$staging_directory/daemon.plist" "$plist_path"
/usr/bin/install -o root -g wheel -m 644 "$staging_directory/installation.plist" "$manifest_path"
if [[ ! -e "$log_path" ]]; then /usr/bin/touch "$log_path"; fi
/usr/sbin/chown root:wheel "$log_path"
/bin/chmod 600 "$log_path"
/bin/launchctl bootstrap system "$plist_path"
echo 'Local TUN helper installed for your account. Return to Hy2UI and enable 增强模式（本地 TUN）.'
