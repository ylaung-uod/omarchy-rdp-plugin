#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

required=(
  manifest.json README.md LICENSE Panel.qml install.sh uninstall.sh
  scripts/omarchy-rdp-password scripts/omarchy-rdp-server
  scripts/omarchy-rdp-status scripts/omarchy-rdp-stop
  systemd/hypr-rdp.service config/options
)
for file in "${required[@]}"; do
  [[ -f $ROOT/$file ]] || { echo "missing: $file" >&2; exit 1; }
done

jq -e '
  .schemaVersion == 1 and
  .id == "io.github.ylaung-uod.omarchy-rdp" and
  .kinds == ["bar-widget"] and
  .entryPoints.barWidget == "Panel.qml" and
  .barWidget.defaultSection == "right"
' "$ROOT/manifest.json" >/dev/null

for script in install.sh uninstall.sh scripts/omarchy-rdp-password \
  scripts/omarchy-rdp-server scripts/omarchy-rdp-status scripts/omarchy-rdp-stop; do
  bash -n "$ROOT/$script"
done

grep -q 'omarchy-pkg-add hypr-rdp' "$ROOT/install.sh"
grep -q 'ConditionPathExists=%t/hypr-rdp/password' "$ROOT/systemd/hypr-rdp.service"
grep -q '^BIND="127.0.0.1:3389"$' "$ROOT/config/options"
grep -q '^BIND="127.0.0.1:3389"$' "$ROOT/scripts/omarchy-rdp-password"
grep -q 'PORT=${BIND##\*:}' "$ROOT/scripts/omarchy-rdp-status"
grep -q 'systemctl --user is-active' "$ROOT/scripts/omarchy-rdp-stop"
if grep -q 'systemctl --user stop .*|| true' "$ROOT/scripts/omarchy-rdp-stop"; then
  echo "stop failures must not be suppressed" >&2
  exit 1
fi
if grep -R -E '\bsudo\b|\bchpasswd\b' "$ROOT/scripts"; then
  echo "runtime scripts must not expose the account password or require privilege" >&2
  exit 1
fi
if find "$ROOT" -path "$ROOT/.git" -prune -o -type f -exec file {} + | grep -q 'ELF.*executable'; then
  echo "bundled executable found" >&2
  exit 1
fi
if grep -R -E '(curl|wget).*(\||bash|sh)' "$ROOT" --exclude-dir=.git --exclude=run.sh; then
  echo "download-to-shell pattern found" >&2
  exit 1
fi

# A failed service stop must leave the credential in place and report failure;
# deleting only the file would not revoke a credential already loaded in RAM.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/runtime/hypr-rdp"
printf 'test-only\n' >"$TMP/runtime/hypr-rdp/password"
cat >"$TMP/bin/systemctl" <<'EOF'
#!/bin/bash
case "$*" in
  *"is-active"*) echo active; exit 0 ;;
  *"stop"*) exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod 0755 "$TMP/bin/systemctl"
if PATH="$TMP/bin:$PATH" XDG_RUNTIME_DIR="$TMP/runtime" \
    "$ROOT/scripts/omarchy-rdp-stop" >/dev/null 2>&1; then
  echo "stop helper reported success after service stop failure" >&2
  exit 1
fi
[[ -f $TMP/runtime/hypr-rdp/password ]] || {
  echo "stop helper removed the credential while the service remained active" >&2
  exit 1
}

# An indeterminate systemd result is not the same as inactive. Fail closed and
# retain the credential because a running process may already have loaded it.
cat >"$TMP/bin/systemctl" <<'EOF'
#!/bin/bash
exit 1
EOF
if PATH="$TMP/bin:$PATH" XDG_RUNTIME_DIR="$TMP/runtime" \
    "$ROOT/scripts/omarchy-rdp-stop" >/dev/null 2>&1; then
  echo "stop helper treated a systemd error as inactive" >&2
  exit 1
fi
[[ -f $TMP/runtime/hypr-rdp/password ]] || {
  echo "stop helper removed the credential after an indeterminate status" >&2
  exit 1
}

# systemctl reports transitional states with a nonzero code on some versions.
# They are still live and must be stopped before the credential is removed.
cat >"$TMP/bin/systemctl" <<'EOF'
#!/bin/bash
if [[ $* == *"is-active"* ]]; then
  if [[ -f $TEST_STOPPED ]]; then echo inactive; exit 3; fi
  echo activating
  exit 3
fi
if [[ $* == *"stop"* ]]; then touch "$TEST_STOPPED"; exit 0; fi
exit 0
EOF
printf 'test-only\n' >"$TMP/runtime/hypr-rdp/password"
TEST_STOPPED="$TMP/stopped" PATH="$TMP/bin:$PATH" XDG_RUNTIME_DIR="$TMP/runtime" \
  "$ROOT/scripts/omarchy-rdp-stop" >/dev/null
[[ -f $TMP/stopped && ! -f $TMP/runtime/hypr-rdp/password ]] || {
  echo "stop helper did not stop an activating service before disarming" >&2
  exit 1
}
rm -f "$TMP/stopped"
STATUS_JSON=$(TEST_STOPPED="$TMP/stopped" PATH="$TMP/bin:$PATH" \
  XDG_RUNTIME_DIR="$TMP/runtime" "$ROOT/scripts/omarchy-rdp-status")
jq -e '.active == true and .serviceKnown == true' <<<"$STATUS_JSON" >/dev/null || {
  echo "status helper did not recognize an activating service" >&2
  exit 1
}

# An explicit --bind selection must update an existing options file. A plain
# reinstall may preserve it, but the command-line choice cannot be ignored.
mkdir -p "$TMP/home/.config/hypr-rdp" "$TMP/install-bin"
printf 'certificate\n' >"$TMP/home/.config/hypr-rdp/tls.crt"
printf 'private-key\n' >"$TMP/home/.config/hypr-rdp/tls.key"
printf 'BIND="0.0.0.0:3389"\nOPTIONS=()\n' >"$TMP/home/.config/hypr-rdp/options"
cat >"$TMP/install-bin/omarchy-version" <<'EOF'
#!/bin/bash
echo 4.0.4
EOF
cat >"$TMP/install-bin/omarchy-pkg-add" <<'EOF'
#!/bin/bash
exit 0
EOF
cat >"$TMP/install-bin/systemctl" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod 0755 "$TMP/install-bin/"*

mkdir -p "$TMP/home-new/.config/hypr-rdp"
printf 'certificate\n' >"$TMP/home-new/.config/hypr-rdp/tls.crt"
printf 'private-key\n' >"$TMP/home-new/.config/hypr-rdp/tls.key"
HOME="$TMP/home-new" XDG_CONFIG_HOME="$TMP/home-new/.config" \
  PATH="$TMP/install-bin:$PATH" "$ROOT/install.sh" --skip-password >/dev/null
grep -q '^BIND="127.0.0.1:3389"$' "$TMP/home-new/.config/hypr-rdp/options" || {
  echo "new installation did not default to localhost" >&2
  exit 1
}

HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" \
  PATH="$TMP/install-bin:$PATH" "$ROOT/install.sh" --bind localhost --skip-password >/dev/null
grep -q '^BIND="127.0.0.1:3389"$' "$TMP/home/.config/hypr-rdp/options" || {
  echo "explicit localhost bind did not update existing options" >&2
  exit 1
}
HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" \
  PATH="$TMP/install-bin:$PATH" "$ROOT/install.sh" --bind lan --skip-password >/dev/null
grep -q '^BIND="0.0.0.0:3389"$' "$TMP/home/.config/hypr-rdp/options" || {
  echo "explicit LAN bind did not update existing options" >&2
  exit 1
}
OPTIONS_HASH_BEFORE=$(sha256sum "$TMP/home/.config/hypr-rdp/options" | cut -d' ' -f1)
HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" \
  PATH="$TMP/install-bin:$PATH" "$ROOT/install.sh" --skip-password >/dev/null
OPTIONS_HASH_AFTER=$(sha256sum "$TMP/home/.config/hypr-rdp/options" | cut -d' ' -f1)
[[ $OPTIONS_HASH_BEFORE == "$OPTIONS_HASH_AFTER" ]] || {
  echo "plain reinstall modified the existing options file" >&2
  exit 1
}

printf 'OPTIONS=()\n' >"$TMP/home/.config/hypr-rdp/options"
HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" \
  PATH="$TMP/install-bin:$PATH" "$ROOT/install.sh" --bind localhost --skip-password >/dev/null
[[ $(grep -c '^BIND=' "$TMP/home/.config/hypr-rdp/options") == 1 ]] \
  && grep -q '^BIND="127.0.0.1:3389"$' "$TMP/home/.config/hypr-rdp/options" || {
  echo "explicit bind was not added to options without a BIND entry" >&2
  exit 1
}

# Installation must fail closed rather than overwrite an unrelated command at
# one of the plugin's fixed user-local paths.
mkdir -p "$TMP/home-collision/.config/hypr-rdp" "$TMP/home-collision/.local/bin"
printf 'certificate\n' >"$TMP/home-collision/.config/hypr-rdp/tls.crt"
printf 'private-key\n' >"$TMP/home-collision/.config/hypr-rdp/tls.key"
printf '#!/bin/bash\necho unrelated\n' >"$TMP/home-collision/.local/bin/omarchy-rdp-status"
if HOME="$TMP/home-collision" XDG_CONFIG_HOME="$TMP/home-collision/.config" \
    PATH="$TMP/install-bin:$PATH" "$ROOT/install.sh" --skip-password >/dev/null 2>&1; then
  echo "installer overwrote or accepted an unrelated command" >&2
  exit 1
fi
grep -q '^echo unrelated$' "$TMP/home-collision/.local/bin/omarchy-rdp-status" || {
  echo "installer changed an unrelated command before aborting" >&2
  exit 1
}

# Ownership records must not follow symlinks into unrelated user files.
mkdir -p "$TMP/home-record/.config/hypr-rdp" \
  "$TMP/home-record/.local/state/omarchy-rdp/installed-files"
printf 'certificate\n' >"$TMP/home-record/.config/hypr-rdp/tls.crt"
printf 'private-key\n' >"$TMP/home-record/.config/hypr-rdp/tls.key"
printf 'do-not-change\n' >"$TMP/record-victim"
printf 'io.github.ylaung-uod.omarchy-rdp\n' \
  >"$TMP/home-record/.local/state/omarchy-rdp/installed-files/owner"
ln -s "$TMP/record-victim" \
  "$TMP/home-record/.local/state/omarchy-rdp/installed-files/omarchy-rdp-status.sha256"
if HOME="$TMP/home-record" XDG_CONFIG_HOME="$TMP/home-record/.config" \
    PATH="$TMP/install-bin:$PATH" "$ROOT/install.sh" --skip-password >/dev/null 2>&1; then
  echo "installer accepted a symlinked ownership record" >&2
  exit 1
fi
grep -q '^do-not-change$' "$TMP/record-victim" || {
  echo "installer followed a symlinked ownership record" >&2
  exit 1
}

mkdir -p "$TMP/home-malformed-record/.config/hypr-rdp" \
  "$TMP/home-malformed-record/.local/bin" \
  "$TMP/home-malformed-record/.local/state/omarchy-rdp/installed-files"
printf 'certificate\n' >"$TMP/home-malformed-record/.config/hypr-rdp/tls.crt"
printf 'private-key\n' >"$TMP/home-malformed-record/.config/hypr-rdp/tls.key"
printf 'io.github.ylaung-uod.omarchy-rdp\n' \
  >"$TMP/home-malformed-record/.local/state/omarchy-rdp/installed-files/owner"
printf '#!/bin/bash\necho unrelated-malformed\n' \
  >"$TMP/home-malformed-record/.local/bin/omarchy-rdp-status"
malformed_install_checksum=$(sha256sum \
  "$TMP/home-malformed-record/.local/bin/omarchy-rdp-status" | cut -d' ' -f1)
printf '%s\nTRAILING-GARBAGE\n' "$malformed_install_checksum" \
  >"$TMP/home-malformed-record/.local/state/omarchy-rdp/installed-files/omarchy-rdp-status.sha256"
if HOME="$TMP/home-malformed-record" XDG_CONFIG_HOME="$TMP/home-malformed-record/.config" \
    PATH="$TMP/install-bin:$PATH" "$ROOT/install.sh" --skip-password >/dev/null 2>&1; then
  echo "installer accepted a malformed ownership record" >&2
  exit 1
fi
grep -q '^echo unrelated-malformed$' \
  "$TMP/home-malformed-record/.local/bin/omarchy-rdp-status" || {
  echo "installer trusted a malformed record and overwrote an unrelated command" >&2
  exit 1
}

# Installation must reject symlinked components in every destination directory.
mkdir -p "$TMP/home-config-link" "$TMP/config-link-victim/hypr-rdp"
printf 'certificate\n' >"$TMP/config-link-victim/hypr-rdp/tls.crt"
printf 'private-key\n' >"$TMP/config-link-victim/hypr-rdp/tls.key"
printf 'BIND="0.0.0.0:3389"\n' >"$TMP/config-link-victim/hypr-rdp/options"
ln -s "$TMP/config-link-victim" "$TMP/home-config-link/config-link"
if HOME="$TMP/home-config-link" XDG_CONFIG_HOME="$TMP/home-config-link/config-link" \
    PATH="$TMP/install-bin:$PATH" "$ROOT/install.sh" --bind localhost --skip-password \
    >/dev/null 2>&1; then
  echo "installer accepted a symlinked configuration path component" >&2
  exit 1
fi
grep -q '^BIND="0.0.0.0:3389"$' "$TMP/config-link-victim/hypr-rdp/options" || {
  echo "installer modified a symlinked configuration target" >&2
  exit 1
}

# Known configuration paths must be regular files; TLS generation must never
# follow a symlink or overwrite a partial existing identity.
mkdir -p "$TMP/home-config-file/.config/hypr-rdp"
printf 'certificate-victim\n' >"$TMP/tls-certificate-victim"
ln -s "$TMP/tls-certificate-victim" \
  "$TMP/home-config-file/.config/hypr-rdp/tls.crt"
if HOME="$TMP/home-config-file" XDG_CONFIG_HOME="$TMP/home-config-file/.config" \
    PATH="$TMP/install-bin:$PATH" "$ROOT/install.sh" --skip-password >/dev/null 2>&1; then
  echo "installer accepted a symlinked TLS configuration file" >&2
  exit 1
fi
[[ -L $TMP/home-config-file/.config/hypr-rdp/tls.crt ]] \
  && grep -q '^certificate-victim$' "$TMP/tls-certificate-victim" || {
  echo "installer replaced or followed a symlinked TLS configuration file" >&2
  exit 1
}

mkdir -p "$TMP/home-partial-tls/.config/hypr-rdp"
printf 'certificate-only\n' >"$TMP/home-partial-tls/.config/hypr-rdp/tls.crt"
if HOME="$TMP/home-partial-tls" XDG_CONFIG_HOME="$TMP/home-partial-tls/.config" \
    PATH="$TMP/install-bin:$PATH" "$ROOT/install.sh" --skip-password >/dev/null 2>&1; then
  echo "installer accepted an incomplete TLS identity" >&2
  exit 1
fi
[[ ! -e $TMP/home-partial-tls/.local/bin/omarchy-rdp-server \
  && ! -e $TMP/home-partial-tls/.local/state/omarchy-rdp \
  && ! -e $TMP/home-partial-tls/.config/hypr-rdp/options ]] || {
  echo "installer made changes before rejecting an incomplete TLS identity" >&2
  exit 1
}
grep -q '^certificate-only$' "$TMP/home-partial-tls/.config/hypr-rdp/tls.crt" || {
  echo "installer changed an incomplete TLS identity before aborting" >&2
  exit 1
}

mkdir -p "$TMP/home-partial-key/.config/hypr-rdp"
printf 'key-only\n' >"$TMP/home-partial-key/.config/hypr-rdp/tls.key"
if HOME="$TMP/home-partial-key" XDG_CONFIG_HOME="$TMP/home-partial-key/.config" \
    PATH="$TMP/install-bin:$PATH" "$ROOT/install.sh" --skip-password >/dev/null 2>&1; then
  echo "installer accepted a TLS identity containing only a key" >&2
  exit 1
fi
[[ ! -e $TMP/home-partial-key/.local/bin/omarchy-rdp-server \
  && ! -e $TMP/home-partial-key/.local/state/omarchy-rdp \
  && ! -e $TMP/home-partial-key/.config/hypr-rdp/options ]] || {
  echo "installer made changes before rejecting a key-only TLS identity" >&2
  exit 1
}
grep -q '^key-only$' "$TMP/home-partial-key/.config/hypr-rdp/tls.key" || {
  echo "installer changed a key-only TLS identity before aborting" >&2
  exit 1
}

# Source-identical files are not owned without valid plugin state. An uninstall
# must preserve independently installed helpers and units instead of adopting
# them based only on byte equality.
mkdir -p "$TMP/home-unowned/.local/bin" \
  "$TMP/home-unowned/.config/systemd/user" \
  "$TMP/home-unowned/.local/state/omarchy-rdp/installed-files"
printf 'io.github.ylaung-uod.omarchy-rdp\n' \
  >"$TMP/home-unowned/.local/state/omarchy-rdp/installed-files/owner"
install -m0755 "$ROOT/scripts/omarchy-rdp-server" \
  "$TMP/home-unowned/.local/bin/omarchy-rdp-server"
install -m0755 "$ROOT/scripts/omarchy-rdp-password" \
  "$TMP/home-unowned/.local/bin/omarchy-rdp-password"
install -m0755 "$ROOT/scripts/omarchy-rdp-status" \
  "$TMP/home-unowned/.local/bin/omarchy-rdp-status"
install -m0755 "$ROOT/scripts/omarchy-rdp-stop" \
  "$TMP/home-unowned/.local/bin/omarchy-rdp-stop"
install -m0644 "$ROOT/systemd/hypr-rdp.service" \
  "$TMP/home-unowned/.config/systemd/user/hypr-rdp.service"
cat >"$TMP/install-bin/systemctl" <<'EOF'
#!/bin/bash
if [[ -n ${TEST_SYSTEMCTL_LOG:-} ]]; then
  printf '%s\n' "$*" >>"$TEST_SYSTEMCTL_LOG"
fi
if [[ $* == *"is-active"* ]]; then
  echo inactive
  exit 3
fi
exit 0
EOF
TEST_SYSTEMCTL_LOG="$TMP/unowned-systemctl.log" HOME="$TMP/home-unowned" \
  XDG_CONFIG_HOME="$TMP/home-unowned/.config" XDG_RUNTIME_DIR="$TMP/unowned-runtime" \
  PATH="$TMP/install-bin:$PATH" "$ROOT/uninstall.sh" >/dev/null
for unowned_path in \
  "$TMP/home-unowned/.local/bin/omarchy-rdp-server" \
  "$TMP/home-unowned/.local/bin/omarchy-rdp-password" \
  "$TMP/home-unowned/.local/bin/omarchy-rdp-status" \
  "$TMP/home-unowned/.local/bin/omarchy-rdp-stop" \
  "$TMP/home-unowned/.config/systemd/user/hypr-rdp.service"; do
  [[ -f $unowned_path ]] || {
    echo "uninstaller removed a source-identical file without valid plugin ownership state" >&2
    exit 1
  }
done
if grep -qE '(^| )stop( |$)|(^| )disable( |$)' "$TMP/unowned-systemctl.log"; then
  echo "uninstaller changed service state without valid plugin ownership state" >&2
  exit 1
fi

# A checksum record must contain exactly one valid checksum line. Malformed
# records fail closed and preserve the corresponding managed file.
mkdir -p "$TMP/home-malformed/.config/hypr-rdp"
printf 'certificate\n' >"$TMP/home-malformed/.config/hypr-rdp/tls.crt"
printf 'private-key\n' >"$TMP/home-malformed/.config/hypr-rdp/tls.key"
HOME="$TMP/home-malformed" XDG_CONFIG_HOME="$TMP/home-malformed/.config" \
  PATH="$TMP/install-bin:$PATH" "$ROOT/install.sh" --skip-password >/dev/null
printf 'TRAILING-GARBAGE\n' \
  >>"$TMP/home-malformed/.local/state/omarchy-rdp/installed-files/omarchy-rdp-status.sha256"
HOME="$TMP/home-malformed" XDG_CONFIG_HOME="$TMP/home-malformed/.config" \
  XDG_RUNTIME_DIR="$TMP/malformed-runtime" PATH="$TMP/install-bin:$PATH" \
  "$ROOT/uninstall.sh" >/dev/null
[[ -f $TMP/home-malformed/.local/bin/omarchy-rdp-status ]] || {
  echo "uninstaller trusted a malformed checksum record" >&2
  exit 1
}
status_checksum=$(sha256sum "$TMP/home-malformed/.local/bin/omarchy-rdp-status" | cut -d' ' -f1)
printf '%s\0' "$status_checksum" \
  >"$TMP/home-malformed/.local/state/omarchy-rdp/installed-files/omarchy-rdp-status.sha256"
HOME="$TMP/home-malformed" XDG_CONFIG_HOME="$TMP/home-malformed/.config" \
  XDG_RUNTIME_DIR="$TMP/malformed-runtime" PATH="$TMP/install-bin:$PATH" \
  "$ROOT/uninstall.sh" >/dev/null
[[ -f $TMP/home-malformed/.local/bin/omarchy-rdp-status ]] || {
  echo "uninstaller trusted a NUL-containing checksum record" >&2
  exit 1
}
[[ ! -e $TMP/home-malformed/.local/bin/omarchy-rdp-server ]] || {
  echo "uninstaller failed to remove a file with a valid ownership record" >&2
  exit 1
}

mkdir -p "$TMP/home-nul-owner/.local/bin" \
  "$TMP/home-nul-owner/.local/state/omarchy-rdp/installed-files"
install -m0755 "$ROOT/scripts/omarchy-rdp-server" \
  "$TMP/home-nul-owner/.local/bin/omarchy-rdp-server"
nul_owner_checksum=$(sha256sum "$TMP/home-nul-owner/.local/bin/omarchy-rdp-server" | cut -d' ' -f1)
printf '%s\n' "$nul_owner_checksum" \
  >"$TMP/home-nul-owner/.local/state/omarchy-rdp/installed-files/omarchy-rdp-server.sha256"
printf 'io.github.ylaung-uod.omarchy-rdp\0' \
  >"$TMP/home-nul-owner/.local/state/omarchy-rdp/installed-files/owner"
HOME="$TMP/home-nul-owner" XDG_CONFIG_HOME="$TMP/home-nul-owner/.config" \
  XDG_RUNTIME_DIR="$TMP/nul-owner-runtime" PATH="$TMP/install-bin:$PATH" \
  "$ROOT/uninstall.sh" >/dev/null 2>&1
[[ -f $TMP/home-nul-owner/.local/bin/omarchy-rdp-server ]] || {
  echo "uninstaller trusted a NUL-containing ownership marker" >&2
  exit 1
}

# A historical unit checksum is not enough to manage an active service when
# the unit path itself is missing; another unit with the same name may be loaded.
mkdir -p "$TMP/home-missing-unit/.config/hypr-rdp"
printf 'certificate\n' >"$TMP/home-missing-unit/.config/hypr-rdp/tls.crt"
printf 'private-key\n' >"$TMP/home-missing-unit/.config/hypr-rdp/tls.key"
HOME="$TMP/home-missing-unit" XDG_CONFIG_HOME="$TMP/home-missing-unit/.config" \
  PATH="$TMP/install-bin:$PATH" "$ROOT/install.sh" --skip-password >/dev/null
rm -f "$TMP/home-missing-unit/.config/systemd/user/hypr-rdp.service"
cat >"$TMP/install-bin/systemctl" <<'EOF'
#!/bin/bash
if [[ -n ${TEST_SYSTEMCTL_LOG:-} ]]; then
  printf '%s\n' "$*" >>"$TEST_SYSTEMCTL_LOG"
fi
if [[ $* == *"is-active"* ]]; then
  echo active
  exit 0
fi
exit 0
EOF
if TEST_SYSTEMCTL_LOG="$TMP/missing-unit-systemctl.log" HOME="$TMP/home-missing-unit" \
    XDG_CONFIG_HOME="$TMP/home-missing-unit/.config" \
    XDG_RUNTIME_DIR="$TMP/missing-unit-runtime" PATH="$TMP/install-bin:$PATH" \
    "$ROOT/uninstall.sh" >/dev/null 2>&1; then
  echo "uninstaller accepted an active service whose unit path was missing" >&2
  exit 1
fi
if grep -qE '(^| )stop( |$)|(^| )disable( |$)' "$TMP/missing-unit-systemctl.log"; then
  echo "uninstaller changed a service using only a historical unit checksum" >&2
  exit 1
fi
[[ -f $TMP/home-missing-unit/.local/bin/omarchy-rdp-server ]] || {
  echo "uninstaller removed helpers after rejecting a missing active unit" >&2
  exit 1
}

# Uninstallation must preserve locally modified managed paths and preserve
# configuration by default, including unrelated files in the config directory.
mkdir -p "$TMP/home-uninstall/.config/hypr-rdp"
printf 'certificate\n' >"$TMP/home-uninstall/.config/hypr-rdp/tls.crt"
printf 'private-key\n' >"$TMP/home-uninstall/.config/hypr-rdp/tls.key"
HOME="$TMP/home-uninstall" XDG_CONFIG_HOME="$TMP/home-uninstall/.config" \
  PATH="$TMP/install-bin:$PATH" "$ROOT/install.sh" --skip-password >/dev/null
printf '\n# local command change\n' >>"$TMP/home-uninstall/.local/bin/omarchy-rdp-status"
printf '\n# local unit change\n' >>"$TMP/home-uninstall/.config/systemd/user/hypr-rdp.service"
printf 'unrelated\n' >"$TMP/home-uninstall/.config/hypr-rdp/notes.txt"
cat >"$TMP/install-bin/systemctl" <<'EOF'
#!/bin/bash
if [[ $* == *"is-active"* ]]; then
  echo inactive
  exit 3
fi
exit 0
EOF
HOME="$TMP/home-uninstall" XDG_CONFIG_HOME="$TMP/home-uninstall/.config" \
  XDG_RUNTIME_DIR="$TMP/runtime-uninstall" PATH="$TMP/install-bin:$PATH" \
  "$ROOT/uninstall.sh" >/dev/null
[[ -f $TMP/home-uninstall/.local/bin/omarchy-rdp-status ]] || {
  echo "uninstaller removed a locally modified command" >&2
  exit 1
}
[[ -f $TMP/home-uninstall/.config/systemd/user/hypr-rdp.service ]] || {
  echo "uninstaller removed a locally modified service unit" >&2
  exit 1
}
[[ -f $TMP/home-uninstall/.config/hypr-rdp/options \
  && -f $TMP/home-uninstall/.config/hypr-rdp/notes.txt ]] || {
  echo "uninstaller removed configuration without explicit consent" >&2
  exit 1
}
[[ ! -e $TMP/home-uninstall/.local/bin/omarchy-rdp-server ]] || {
  echo "uninstaller kept an unmodified managed command" >&2
  exit 1
}
HOME="$TMP/home-uninstall" XDG_CONFIG_HOME="$TMP/home-uninstall/.config" \
  XDG_RUNTIME_DIR="$TMP/runtime-uninstall" PATH="$TMP/install-bin:$PATH" \
  "$ROOT/uninstall.sh" --remove-config >/dev/null
[[ ! -e $TMP/home-uninstall/.config/hypr-rdp/options \
  && ! -e $TMP/home-uninstall/.config/hypr-rdp/tls.crt \
  && ! -e $TMP/home-uninstall/.config/hypr-rdp/tls.key ]] || {
  echo "explicit config removal kept plugin configuration files" >&2
  exit 1
}
[[ -f $TMP/home-uninstall/.config/hypr-rdp/notes.txt ]] || {
  echo "explicit config removal deleted an unrelated file" >&2
  exit 1
}

# Uninstallation must not follow configuration or runtime directory symlinks.
mkdir -p "$TMP/home-symlink/.config" "$TMP/symlink-config-victim" \
  "$TMP/runtime-symlink" "$TMP/symlink-runtime-victim" \
  "$TMP/state-symlink" "$TMP/symlink-state-victim/installed-files"
printf 'options-victim\n' >"$TMP/symlink-config-victim/options"
printf 'certificate-victim\n' >"$TMP/symlink-config-victim/tls.crt"
printf 'key-victim\n' >"$TMP/symlink-config-victim/tls.key"
printf 'password-victim\n' >"$TMP/symlink-runtime-victim/password"
printf 'record-victim\n' >"$TMP/symlink-state-victim/installed-files/omarchy-rdp-server.sha256"
ln -s "$TMP/symlink-config-victim" "$TMP/home-symlink/.config/hypr-rdp"
ln -s "$TMP/symlink-runtime-victim" "$TMP/runtime-symlink/hypr-rdp"
ln -s "$TMP/symlink-state-victim" "$TMP/state-symlink/omarchy-rdp"
HOME="$TMP/home-symlink" XDG_CONFIG_HOME="$TMP/home-symlink/.config" \
  XDG_RUNTIME_DIR="$TMP/runtime-symlink" XDG_STATE_HOME="$TMP/state-symlink" \
  PATH="$TMP/install-bin:$PATH" "$ROOT/uninstall.sh" --remove-config >/dev/null
[[ -f $TMP/symlink-config-victim/options \
  && -f $TMP/symlink-config-victim/tls.crt \
  && -f $TMP/symlink-config-victim/tls.key \
  && -f $TMP/symlink-runtime-victim/password \
  && -f $TMP/symlink-state-victim/installed-files/omarchy-rdp-server.sha256 ]] || {
  echo "uninstaller followed a configuration or runtime directory symlink" >&2
  exit 1
}

mkdir -p "$TMP/home-ancestor-link" "$TMP/ancestor-config-victim/hypr-rdp" \
  "$TMP/ancestor-runtime-victim/hypr-rdp"
printf 'options-victim\n' >"$TMP/ancestor-config-victim/hypr-rdp/options"
printf 'password-victim\n' >"$TMP/ancestor-runtime-victim/hypr-rdp/password"
ln -s "$TMP/ancestor-config-victim" "$TMP/home-ancestor-link/config-root"
ln -s "$TMP/ancestor-runtime-victim" "$TMP/home-ancestor-link/runtime-root"
HOME="$TMP/home-ancestor-link" XDG_CONFIG_HOME="$TMP/home-ancestor-link/config-root" \
  XDG_RUNTIME_DIR="$TMP/home-ancestor-link/runtime-root" PATH="$TMP/install-bin:$PATH" \
  "$ROOT/uninstall.sh" --remove-config >/dev/null
[[ -f $TMP/ancestor-config-victim/hypr-rdp/options \
  && -f $TMP/ancestor-runtime-victim/hypr-rdp/password ]] || {
  echo "uninstaller followed a symlinked configuration or runtime ancestor" >&2
  exit 1
}

mkdir -p "$TMP/relative-cwd/relative-config/hypr-rdp" \
  "$TMP/relative-cwd/relative-runtime/hypr-rdp"
printf 'relative-options-victim\n' >"$TMP/relative-cwd/relative-config/hypr-rdp/options"
printf 'relative-password-victim\n' >"$TMP/relative-cwd/relative-runtime/hypr-rdp/password"
(
  cd "$TMP/relative-cwd"
  HOME="$TMP/home-ancestor-link" XDG_CONFIG_HOME=relative-config \
    XDG_RUNTIME_DIR=relative-runtime PATH="$TMP/install-bin:$PATH" \
    "$ROOT/uninstall.sh" --remove-config >/dev/null
)
[[ -f $TMP/relative-cwd/relative-config/hypr-rdp/options \
  && -f $TMP/relative-cwd/relative-runtime/hypr-rdp/password ]] || {
  echo "uninstaller accepted a relative XDG path" >&2
  exit 1
}

mkdir -p "$TMP/home-unrelated-state" \
  "$TMP/unrelated-state/omarchy-rdp/installed-files"
printf 'unrelated-record\n' \
  >"$TMP/unrelated-state/omarchy-rdp/installed-files/omarchy-rdp-server.sha256"
HOME="$TMP/home-unrelated-state" XDG_CONFIG_HOME="$TMP/home-unrelated-state/.config" \
  XDG_RUNTIME_DIR="$TMP/home-unrelated-state/runtime" XDG_STATE_HOME="$TMP/unrelated-state" \
  PATH="$TMP/install-bin:$PATH" "$ROOT/uninstall.sh" >/dev/null
[[ -f $TMP/unrelated-state/omarchy-rdp/installed-files/omarchy-rdp-server.sha256 ]] || {
  echo "uninstaller deleted an ownership record without a plugin ownership marker" >&2
  exit 1
}

grep -q 'READY=false' "$ROOT/scripts/omarchy-rdp-password"
grep -q 'ss -ltnH "sport = :$PORT"' "$ROOT/scripts/omarchy-rdp-password"

echo "Plugin tests: PASS"
