#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [--keep-config] [--remove-package]

Remove the runtime installed by this plugin.
  --keep-config     Preserve ~/.config/hypr-rdp and its TLS identity
  --remove-package  Also uninstall the hypr-rdp package
EOF
}

KEEP_CONFIG=false
REMOVE_PACKAGE=false
while (( $# > 0 )); do
  case "$1" in
  --keep-config) KEEP_CONFIG=true ;;
  --remove-package) REMOVE_PACKAGE=true ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
  esac
  shift
done
[[ $EUID -ne 0 ]] || { echo "Run this as the Omarchy desktop user, not root." >&2; exit 2; }

CONF_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/hypr-rdp
UNIT=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/hypr-rdp.service
RUN_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr-rdp

service_state() {
  local state rc=0
  state=$(systemctl --user is-active hypr-rdp.service 2>&1) || rc=$?
  case "$rc:$state" in
  *:active | *:activating | *:reloading | *:deactivating) echo active ;;
  3:inactive | 3:failed) echo inactive ;;
  *) printf 'Unable to determine Remote Desktop service state: %s\n' "$state" >&2; return 1 ;;
  esac
}

STATE=$(service_state) || exit 1
if [[ $STATE == active ]]; then
  systemctl --user stop hypr-rdp.service
fi
STATE=$(service_state) || exit 1
if [[ $STATE != inactive ]]; then
  echo "Remote Desktop is still running; uninstall aborted." >&2
  exit 1
fi
systemctl --user disable hypr-rdp.service 2>/dev/null || true
rm -f "$UNIT"
systemctl --user daemon-reload
systemctl --user reset-failed hypr-rdp.service 2>/dev/null || true
rm -f "$HOME/.local/bin/omarchy-rdp-server" \
  "$HOME/.local/bin/omarchy-rdp-password" \
  "$HOME/.local/bin/omarchy-rdp-status" \
  "$HOME/.local/bin/omarchy-rdp-stop"
rm -rf "$RUN_DIR"

if $KEEP_CONFIG; then
  echo "Kept $CONF_DIR."
else
  rm -rf "$CONF_DIR"
fi
if $REMOVE_PACKAGE; then
  omarchy-pkg-drop hypr-rdp
fi

echo "Remote Desktop runtime removed. The Omarchy account password was not changed."
echo "Remove the shell plugin separately with: omarchy plugin remove io.github.ylaung-uod.omarchy-rdp"
