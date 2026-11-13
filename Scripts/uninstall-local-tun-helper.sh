#!/bin/bash
# Removes the fixed local TUN daemon only after its installed helper has restored DNS.
set -euo pipefail
umask 077
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# Rejects privileged directories whose entries ordinary users could replace.
require_root_directory() {
  local checked_path="$1" checked_mode
  [[ -d "$checked_path" && ! -L "$checked_path" ]] || { echo "Unsafe directory: $checked_path" >&2; exit 1; }
  [[ "$(/usr/bin/stat -f %u "$checked_path")" = 0 ]] || { echo "Directory must be root-owned: $checked_path" >&2; exit 1; }
  checked_mode="$(/usr/bin/stat -f %Lp "$checked_path")"
  (( (8#$checked_mode & 8#022) == 0 )) || { echo "Directory must not be group/world writable: $checked_path" >&2; exit 1; }
}

# Rejects a recovery executable or state file that an ordinary user could modify.
require_root_file() {
  local checked_path="$1" checked_mode
  [[ -f "$checked_path" && ! -L "$checked_path" ]] || { echo "Unsafe file: $checked_path" >&2; exit 1; }
  [[ "$(/usr/bin/stat -f %u "$checked_path")" = 0 ]] || { echo "File must be root-owned: $checked_path" >&2; exit 1; }
  checked_mode="$(/usr/bin/stat -f %Lp "$checked_path")"
  (( (8#$checked_mode & 8#022) == 0 )) || { echo "File must not be group/world writable: $checked_path" >&2; exit 1; }
}

# Waits briefly for the old daemon's exclusive recovery lock before refusing an unsafe replacement.
recover_dns() {
  local recovery_deadline=$((SECONDS + 35)) recovery_error
  while ! recovery_error="$("$helper_path" --recover-dns 2>&1)"; do
    if (( SECONDS >= recovery_deadline )); then
      echo "$recovery_error" >&2
      echo 'DNS recovery did not complete; installed files were preserved. Retry after the old service has stopped.' >&2
      exit 1
    fi
    /bin/sleep 0.2
  done
}

[[ "$EUID" = 0 ]] || { echo 'Run: sudo Scripts/uninstall-local-tun-helper.sh' >&2; exit 1; }
[[ "$#" = 0 ]] || { echo 'Usage: sudo Scripts/uninstall-local-tun-helper.sh' >&2; exit 1; }
helper_directory=/Library/PrivilegedHelperTools/dev.hy2ui
helper_path="$helper_directory/hy2-local-tun-helper"
worker_path="$helper_directory/hy2-tun-worker"
plist_path=/Library/LaunchDaemons/dev.hy2ui.local-tun.plist
socket_path="$helper_directory/control.sock"
label=dev.hy2ui.local-tun
manifest_path="$helper_directory/installation.plist"
for root_directory in / /Library /Library/LaunchDaemons; do require_root_directory "$root_directory"; done
if [[ -e /Library/PrivilegedHelperTools || -L /Library/PrivilegedHelperTools ]]; then require_root_directory /Library/PrivilegedHelperTools; fi
if [[ -e "$helper_directory" || -L "$helper_directory" ]]; then require_root_directory "$helper_directory"; fi
for installed_file in "$helper_path" "$worker_path" "$plist_path" "$manifest_path"; do
  if [[ -e "$installed_file" || -L "$installed_file" ]]; then require_root_file "$installed_file"; fi
done
if /bin/launchctl print "system/$label" >/dev/null 2>&1; then /bin/launchctl bootout "system/$label"; fi
if [[ -e "$helper_path" ]]; then
  recover_dns
elif [[ -e "$helper_directory/dns-recovery.plist" || -L "$helper_directory/dns-recovery.plist" || -e "$helper_directory/direct-routes.json" || -L "$helper_directory/direct-routes.json" ]]; then
  echo 'DNS recovery exists but the installed recovery helper is missing; leaving installed files intact.' >&2
  exit 1
fi
# Older helpers may not understand the newer route journal; never replace its recovery binary.
if [[ -e "$helper_directory/tun-routes-v1.json" || -L "$helper_directory/tun-routes-v1.json" ]]; then
  echo 'TUN route recovery is not confirmed; installed files and the journal were preserved.' >&2
  exit 1
fi
if [[ -e "$socket_path" || -L "$socket_path" ]]; then
  [[ -S "$socket_path" && ! -L "$socket_path" ]] || { echo 'Unexpected object at the fixed local TUN socket path.' >&2; exit 1; }
  /bin/rm -- "$socket_path"
fi
# Remove only known files and preserve unexpected files for manual inspection.
/bin/rm -f -- "$plist_path" "$worker_path" "$helper_path" "$manifest_path"
if [[ -e "$helper_directory/helper.lock" || -L "$helper_directory/helper.lock" ]]; then
  require_root_file "$helper_directory/helper.lock"
  /bin/rm -- "$helper_directory/helper.lock"
fi
if [[ -d "$helper_directory" ]]; then /bin/rmdir "$helper_directory" 2>/dev/null || true; fi
echo 'Local TUN helper removed after DNS recovery. Application profiles and Keychain credentials were preserved.'
