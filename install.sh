#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./install.sh [--bind lan|localhost] [--skip-password]

Install the runtime components for the Remote Desktop Omarchy plugin.
  --bind localhost   Listen only on 127.0.0.1 (default; use an SSH tunnel)
  --bind lan         Listen on all interfaces (trusted LAN/VPN only)
  --skip-password    Install without setting the RDP password
EOF
}

BIND_MODE=localhost
SET_PASSWORD=true
while (( $# > 0 )); do
  case "$1" in
  --bind)
    (( $# >= 2 )) || { echo "--bind needs lan or localhost" >&2; exit 2; }
    BIND_MODE=$2
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
BIN_DIR=$HOME/.local/bin
CONF_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/hypr-rdp
UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user

omarchy-pkg-add hypr-rdp
command -v openssl >/dev/null || omarchy-pkg-add openssl

install -Dm0755 "$ROOT/scripts/omarchy-rdp-server" "$BIN_DIR/omarchy-rdp-server"
install -Dm0755 "$ROOT/scripts/omarchy-rdp-password" "$BIN_DIR/omarchy-rdp-password"
install -Dm0755 "$ROOT/scripts/omarchy-rdp-status" "$BIN_DIR/omarchy-rdp-status"
install -Dm0755 "$ROOT/scripts/omarchy-rdp-stop" "$BIN_DIR/omarchy-rdp-stop"
install -d -m0700 "$CONF_DIR"

if [[ ! -e $CONF_DIR/options ]]; then
  install -m0600 "$ROOT/config/options" "$CONF_DIR/options"
  if [[ $BIND_MODE == "lan" ]]; then
    sed -i 's/^BIND=.*/BIND="0.0.0.0:3389"/' "$CONF_DIR/options"
  fi
else
  echo "Keeping existing $CONF_DIR/options."
fi

if [[ ! -s $CONF_DIR/tls.crt || ! -s $CONF_DIR/tls.key ]]; then
  HOST=$(hostname -f 2>/dev/null || hostname)
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 \
    -subj "/CN=$HOST" -keyout "$CONF_DIR/tls.key" -out "$CONF_DIR/tls.crt" \
    >/dev/null 2>&1
  chmod 0600 "$CONF_DIR/tls.key"
  chmod 0644 "$CONF_DIR/tls.crt"
else
  echo "Keeping existing TLS certificate and key."
fi

install -Dm0644 "$ROOT/systemd/hypr-rdp.service" "$UNIT_DIR/hypr-rdp.service"
systemctl --user daemon-reload
systemctl --user enable hypr-rdp.service

echo "Remote Desktop runtime installed for Omarchy $OMARCHY_VERSION."
if $SET_PASSWORD; then
  exec "$BIN_DIR/omarchy-rdp-password"
else
  echo "Start it later with: omarchy-rdp-password"
fi
