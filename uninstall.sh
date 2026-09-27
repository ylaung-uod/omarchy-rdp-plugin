#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [--remove-config] [--remove-package]

Remove the runtime installed by this plugin.
  --remove-config   Remove this plugin's known configuration files
  --remove-package  Also uninstall the hypr-rdp package

Configuration is preserved by default. Unrelated files are never removed.
EOF
}

REMOVE_CONFIG=false
REMOVE_PACKAGE=false
while (( $# > 0 )); do
  case "$1" in
  --keep-config) REMOVE_CONFIG=false ;;
  --remove-config) REMOVE_CONFIG=true ;;
  --remove-package) REMOVE_PACKAGE=true ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
  esac
  shift
done
[[ $EUID -ne 0 ]] || { echo "Run this as the Omarchy desktop user, not root." >&2; exit 2; }

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ID=io.github.ylaung-uod.omarchy-rdp
CONF_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/hypr-rdp
UNIT=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/hypr-rdp.service
RUN_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr-rdp
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-rdp
OWNERSHIP_DIR=$STATE_DIR/installed-files
OWNER_MARKER=$OWNERSHIP_DIR/owner

has_symlink_component() {
  local path=$1 current=/ component
  local -a components
  [[ $path == /* ]] || return 0
  IFS='/' read -r -a components <<<"$path"
  for component in "${components[@]}"; do
    [[ -n $component ]] || continue
    current=${current%/}/$component
    [[ ! -L $current ]] || return 0
    [[ -e $current ]] || return 1
  done
  return 1
}

OWNERSHIP_SAFE=false
if ! has_symlink_component "$STATE_DIR" \
  && ! has_symlink_component "$OWNERSHIP_DIR" \
  && [[ ! -L $OWNER_MARKER && -f $OWNER_MARKER ]] \
  && [[ $(<"$OWNER_MARKER") == "$PLUGIN_ID" ]]; then
  OWNERSHIP_SAFE=true
elif [[ -e $OWNERSHIP_DIR || -L $OWNERSHIP_DIR ]]; then
  echo "Ignoring unverified plugin state path; no ownership records will be read or removed."
fi

managed_file_unchanged() {
  local source=$1 target=$2 key=$3 expected actual
  ! has_symlink_component "$target" || return 1
  [[ ! -L $target && -f $target ]] || return 1
  if $OWNERSHIP_SAFE && [[ -f $OWNERSHIP_DIR/$key.sha256 && ! -L $OWNERSHIP_DIR/$key.sha256 ]]; then
    read -r expected <"$OWNERSHIP_DIR/$key.sha256"
    actual=$(sha256sum "$target" | cut -d' ' -f1)
    [[ $actual == "$expected" ]]
  else
    cmp -s "$source" "$target"
  fi
}

remove_managed_file() {
  local source=$1 target=$2 key=$3
  if [[ ! -e $target && ! -L $target ]]; then
    if $OWNERSHIP_SAFE && [[ ! -L $OWNERSHIP_DIR/$key.sha256 ]]; then
      rm -f "$OWNERSHIP_DIR/$key.sha256"
    fi
  elif managed_file_unchanged "$source" "$target" "$key"; then
    rm -f "$target"
    if $OWNERSHIP_SAFE && [[ ! -L $OWNERSHIP_DIR/$key.sha256 ]]; then
      rm -f "$OWNERSHIP_DIR/$key.sha256"
    fi
  else
    echo "Keeping $target because it is not an unmodified file installed by this plugin."
  fi
}

service_state() {
  local state rc=0
  state=$(systemctl --user is-active hypr-rdp.service 2>&1) || rc=$?
  case "$rc:$state" in
  *:active | *:activating | *:reloading | *:deactivating) echo active ;;
  3:inactive | 3:failed) echo inactive ;;
  *) printf 'Unable to determine Remote Desktop service state: %s\n' "$state" >&2; return 1 ;;
  esac
}

UNIT_MANAGED=false
if ! has_symlink_component "$UNIT"; then
  if [[ ! -e $UNIT && ! -L $UNIT ]] \
    || managed_file_unchanged "$ROOT/systemd/hypr-rdp.service" "$UNIT" hypr-rdp.service; then
    UNIT_MANAGED=true
  fi
fi

STATE=$(service_state) || exit 1
if [[ $STATE == active ]]; then
  $UNIT_MANAGED || {
    echo "Remote Desktop service is active but $UNIT is not an unmodified unit installed by this plugin; uninstall aborted." >&2
    exit 1
  }
  systemctl --user stop hypr-rdp.service
fi
STATE=$(service_state) || exit 1
if [[ $STATE != inactive ]]; then
  echo "Remote Desktop is still running; uninstall aborted." >&2
  exit 1
fi
if $UNIT_MANAGED; then
  systemctl --user disable hypr-rdp.service 2>/dev/null || true
  remove_managed_file "$ROOT/systemd/hypr-rdp.service" "$UNIT" hypr-rdp.service
  systemctl --user daemon-reload
  systemctl --user reset-failed hypr-rdp.service 2>/dev/null || true
else
  echo "Keeping $UNIT because it is not an unmodified unit installed by this plugin."
fi
remove_managed_file "$ROOT/scripts/omarchy-rdp-server" "$HOME/.local/bin/omarchy-rdp-server" omarchy-rdp-server
remove_managed_file "$ROOT/scripts/omarchy-rdp-password" "$HOME/.local/bin/omarchy-rdp-password" omarchy-rdp-password
remove_managed_file "$ROOT/scripts/omarchy-rdp-status" "$HOME/.local/bin/omarchy-rdp-status" omarchy-rdp-status
remove_managed_file "$ROOT/scripts/omarchy-rdp-stop" "$HOME/.local/bin/omarchy-rdp-stop" omarchy-rdp-stop
if has_symlink_component "$RUN_DIR"; then
  echo "Keeping relative or symlinked runtime path: $RUN_DIR."
elif [[ -d $RUN_DIR ]]; then
  rm -f "$RUN_DIR/password"
  rmdir "$RUN_DIR" 2>/dev/null || echo "Keeping non-plugin files in $RUN_DIR."
fi

if $REMOVE_CONFIG; then
  if has_symlink_component "$CONF_DIR"; then
    echo "Keeping relative or symlinked configuration path: $CONF_DIR."
  elif [[ -d $CONF_DIR ]]; then
    rm -f "$CONF_DIR/options" "$CONF_DIR/tls.crt" "$CONF_DIR/tls.key"
    rmdir "$CONF_DIR" 2>/dev/null || echo "Keeping non-plugin files in $CONF_DIR."
  fi
else
  echo "Kept $CONF_DIR; pass --remove-config to remove the plugin's known configuration files."
fi
if $OWNERSHIP_SAFE; then
  (
    shopt -s dotglob nullglob
    entries=("$OWNERSHIP_DIR"/*)
    if (( ${#entries[@]} == 1 )) && [[ ${entries[0]} == "$OWNER_MARKER" ]]; then
      rm -f "$OWNER_MARKER"
      rmdir "$OWNERSHIP_DIR" 2>/dev/null || true
      rmdir "$STATE_DIR" 2>/dev/null || true
    fi
  )
fi
if $REMOVE_PACKAGE; then
  omarchy-pkg-drop hypr-rdp
fi

echo "Remote Desktop runtime removed. The Omarchy account password was not changed."
echo "Remove the shell plugin separately with: omarchy plugin remove io.github.ylaung-uod.omarchy-rdp"
