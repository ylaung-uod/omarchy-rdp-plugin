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

grep -q 'READY=false' "$ROOT/scripts/omarchy-rdp-password"
grep -q 'ss -ltnH "sport = :$PORT"' "$ROOT/scripts/omarchy-rdp-password"

echo "Plugin tests: PASS"
