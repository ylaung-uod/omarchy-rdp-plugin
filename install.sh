#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./install.sh [--bind lan|localhost] [--skip-password]

Install the runtime components for the Remote Desktop Omarchy plugin.
  --bind localhost   Explicitly listen only on 127.0.0.1 (use an SSH tunnel)
  --bind lan         Explicitly listen on all interfaces (trusted LAN/VPN only)
  --skip-password    Install without setting the RDP password

Without --bind, a new installation defaults to localhost and a reinstall
preserves the existing BIND setting.
EOF
}

BIND_MODE=localhost
BIND_EXPLICIT=false
SET_PASSWORD=true
while (( $# > 0 )); do
  case "$1" in
  --bind)
    (( $# >= 2 )) || { echo "--bind needs lan or localhost" >&2; exit 2; }
    BIND_MODE=$2
    BIND_EXPLICIT=true
    shift 2
    ;;
  --skip-password) SET_PASSWORD=false; shift ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
  esac
done
[[ $BIND_MODE == "lan" || $BIND_MODE == "localhost" ]] || {
  echo "--bind must be lan or localhost" >&2
  exit 2
}
[[ $EUID -ne 0 ]] || { echo "Run this as the Omarchy desktop user, not root." >&2; exit 2; }
command -v omarchy-version >/dev/null || { echo "Omarchy was not detected." >&2; exit 1; }
OMARCHY_VERSION=$(omarchy-version 2>/dev/null || true)
[[ $OMARCHY_VERSION == 4.* ]] || {
  printf 'Omarchy 4.x is required; detected: %s\n' "${OMARCHY_VERSION:-unknown}" >&2
  exit 1
}

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ID=io.github.ylaung-uod.omarchy-rdp
BIN_DIR=$HOME/.local/bin
CONF_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/hypr-rdp
UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-rdp
OWNERSHIP_DIR=$STATE_DIR/installed-files
OWNER_MARKER=$OWNERSHIP_DIR/owner

ownership_record_checksum() {
  local record=$1 expected record_size
  local -a record_lines
  [[ ! -L $record && -f $record ]] || return 1
  record_size=$(wc -c <"$record")
  [[ $record_size == 65 ]] || return 1
  mapfile -t record_lines <"$record"
  (( ${#record_lines[@]} == 1 )) || return 1
  expected=${record_lines[0]}
  [[ $expected =~ ^[[:xdigit:]]{64}$ ]] || return 1
  cmp -s "$record" <(printf '%s\n' "$expected") || return 1
  printf '%s\n' "$expected"
}

check_managed_target() {
  local source=$1 target=$2 key=$3 expected= actual record
  record=$OWNERSHIP_DIR/$key.sha256
  if [[ -e $record || -L $record ]]; then
    expected=$(ownership_record_checksum "$record") || {
      echo "Refusing to use invalid ownership record at $record." >&2
      return 1
    }
  fi
  [[ ! -L $target ]] || {
    echo "Refusing to replace symlink at $target." >&2
    return 1
  }
  [[ ! -e $target ]] && return 0
  [[ -f $target ]] || {
    echo "Refusing to replace non-regular file at $target." >&2
    return 1
  }
  cmp -s "$source" "$target" && return 0
  if [[ -n $expected ]]; then
    actual=$(sha256sum "$target" | cut -d' ' -f1)
    [[ $actual == "$expected" ]] && return 0
  fi
  echo "Refusing to overwrite $target because it is not an unmodified file installed by this plugin." >&2
  return 1
}

install_managed_file() {
  local mode=$1 source=$2 target=$3 key=$4 checksum record temporary
  install -Dm"$mode" "$source" "$target"
  checksum=$(sha256sum "$target" | cut -d' ' -f1)
  record=$OWNERSHIP_DIR/$key.sha256
  temporary=$(mktemp "$OWNERSHIP_DIR/.${key}.XXXXXX")
  printf '%s\n' "$checksum" >"$temporary"
  chmod 0600 "$temporary"
  mv -fT "$temporary" "$record"
}

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

owner_marker_valid() {
  local marker_size expected_size=$(( ${#PLUGIN_ID} + 1 ))
  [[ ! -L $OWNER_MARKER && -f $OWNER_MARKER ]] || return 1
  marker_size=$(wc -c <"$OWNER_MARKER")
  [[ $marker_size == "$expected_size" ]] || return 1
  cmp -s "$OWNER_MARKER" <(printf '%s\n' "$PLUGIN_ID")
}

for destination_dir in "$BIN_DIR" "$CONF_DIR" "$UNIT_DIR" "$STATE_DIR" "$OWNERSHIP_DIR"; do
  ! has_symlink_component "$destination_dir" || {
    echo "Refusing to use relative or symlinked destination path: $destination_dir." >&2
    exit 1
  }
  [[ ! -e $destination_dir || -d $destination_dir ]] || {
    echo "Refusing to replace non-directory destination path at $destination_dir." >&2
    exit 1
  }
done

if [[ -e $OWNER_MARKER || -L $OWNER_MARKER ]]; then
  owner_marker_valid || {
    echo "Refusing to use invalid ownership marker at $OWNER_MARKER." >&2
    exit 1
  }
elif [[ -d $OWNERSHIP_DIR ]]; then
  echo "Refusing to use pre-existing ownership directory without this plugin's marker: $OWNERSHIP_DIR." >&2
  exit 1
fi

for config_file in "$CONF_DIR/options" "$CONF_DIR/tls.crt" "$CONF_DIR/tls.key"; do
  [[ ! -L $config_file ]] || {
    echo "Refusing to use symlinked configuration file at $config_file." >&2
    exit 1
  }
  [[ ! -e $config_file || -f $config_file ]] || {
    echo "Refusing to replace non-regular configuration path at $config_file." >&2
    exit 1
  }
done

if [[ -e $CONF_DIR/tls.crt || -e $CONF_DIR/tls.key ]] \
  && [[ ! -s $CONF_DIR/tls.crt || ! -s $CONF_DIR/tls.key ]]; then
  echo "TLS configuration is incomplete; refusing to overwrite the existing certificate or key." >&2
  exit 1
fi

check_managed_target "$ROOT/scripts/omarchy-rdp-server" "$BIN_DIR/omarchy-rdp-server" omarchy-rdp-server
check_managed_target "$ROOT/scripts/omarchy-rdp-password" "$BIN_DIR/omarchy-rdp-password" omarchy-rdp-password
check_managed_target "$ROOT/scripts/omarchy-rdp-status" "$BIN_DIR/omarchy-rdp-status" omarchy-rdp-status
check_managed_target "$ROOT/scripts/omarchy-rdp-stop" "$BIN_DIR/omarchy-rdp-stop" omarchy-rdp-stop
check_managed_target "$ROOT/systemd/hypr-rdp.service" "$UNIT_DIR/hypr-rdp.service" hypr-rdp.service

omarchy-pkg-add hypr-rdp
command -v openssl >/dev/null || omarchy-pkg-add openssl

install -d -m0700 "$OWNERSHIP_DIR"
if [[ ! -e $OWNER_MARKER ]]; then
  marker_temporary=$(mktemp "$OWNERSHIP_DIR/.owner.XXXXXX")
  printf '%s\n' "$PLUGIN_ID" >"$marker_temporary"
  chmod 0600 "$marker_temporary"
  mv -fT "$marker_temporary" "$OWNER_MARKER"
fi
install_managed_file 0755 "$ROOT/scripts/omarchy-rdp-server" "$BIN_DIR/omarchy-rdp-server" omarchy-rdp-server
install_managed_file 0755 "$ROOT/scripts/omarchy-rdp-password" "$BIN_DIR/omarchy-rdp-password" omarchy-rdp-password
install_managed_file 0755 "$ROOT/scripts/omarchy-rdp-status" "$BIN_DIR/omarchy-rdp-status" omarchy-rdp-status
install_managed_file 0755 "$ROOT/scripts/omarchy-rdp-stop" "$BIN_DIR/omarchy-rdp-stop" omarchy-rdp-stop
install -d -m0700 "$CONF_DIR"

if [[ ! -e $CONF_DIR/options ]]; then
  install -m0600 "$ROOT/config/options" "$CONF_DIR/options"
  if [[ $BIND_MODE == "lan" ]]; then
    sed -i 's/^BIND=.*/BIND="0.0.0.0:3389"/' "$CONF_DIR/options"
  fi
elif $BIND_EXPLICIT; then
  if [[ $BIND_MODE == "lan" ]]; then
    BIND_VALUE="0.0.0.0:3389"
  else
    BIND_VALUE="127.0.0.1:3389"
  fi
  if grep -q '^BIND=' "$CONF_DIR/options"; then
    sed -i "s/^BIND=.*/BIND=\"$BIND_VALUE\"/" "$CONF_DIR/options"
  else
    printf '\nBIND="%s"\n' "$BIND_VALUE" >>"$CONF_DIR/options"
  fi
  echo "Updated $CONF_DIR/options to $BIND_VALUE."
else
  echo "Keeping existing $CONF_DIR/options; pass --bind to change it."
fi

if [[ ! -e $CONF_DIR/tls.crt && ! -e $CONF_DIR/tls.key ]]; then
  HOST=$(hostname -f 2>/dev/null || hostname)
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 \
    -subj "/CN=$HOST" -keyout "$CONF_DIR/tls.key" -out "$CONF_DIR/tls.crt" \
    >/dev/null 2>&1
  chmod 0600 "$CONF_DIR/tls.key"
  chmod 0644 "$CONF_DIR/tls.crt"
else
  echo "Keeping existing TLS certificate and key."
fi

install_managed_file 0644 "$ROOT/systemd/hypr-rdp.service" "$UNIT_DIR/hypr-rdp.service" hypr-rdp.service
systemctl --user daemon-reload
systemctl --user enable hypr-rdp.service

echo "Remote Desktop runtime installed for Omarchy $OMARCHY_VERSION."
if $SET_PASSWORD; then
  exec "$BIN_DIR/omarchy-rdp-password"
else
  echo "Start it later with: omarchy-rdp-password"
fi
