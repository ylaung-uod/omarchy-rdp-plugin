# Remote Desktop for Omarchy

An Omarchy 4 bar widget and runtime setup for serving the current Hyprland session through RDP. The widget shows package, password, service, listener, and endpoint state; opens the password/start flow in a terminal; stops and disarms the service; and opens its journal.

## Requirements

- Omarchy 4.x with Hyprland 0.54 or later
- An x86-64 system supported by the upstream `hypr-rdp` package
- A running local Omarchy graphical session
- `hypr-rdp` from the Arch User Repository, installed by this plugin's setup through `omarchy-pkg-add`
- An RDP client

Upstream RDP server: <https://github.com/MuNeNICK/hypr-rdp>

Omarchy plugins are unsandboxed code. Review this repository before enabling it. The Omarchy plugin command clones and validates the shell widget but deliberately does not run `install.sh` or request elevated privileges.

## Install the shell plugin

Once the repository is available on GitHub (authorized access is required while it remains private):

```bash
omarchy plugin add https://github.com/ylaung-uod/omarchy-rdp-plugin.git --enable
```

For local development, copy or clone it into:

```text
~/.config/omarchy/plugins/io.github.ylaung-uod.omarchy-rdp/
```

Validate it before enabling:

```bash
omarchy plugin validate ~/.config/omarchy/plugins/io.github.ylaung-uod.omarchy-rdp
omarchy plugin enable io.github.ylaung-uod.omarchy-rdp --section right
```

## Install the runtime

On a new installation, omitting `--bind` uses the safe localhost-only default:

```bash
cd ~/.config/omarchy/plugins/io.github.ylaung-uod.omarchy-rdp
./install.sh
```

This requires an SSH tunnel or a networking tool that can reach a localhost-only service. To opt into direct access from a trusted LAN or VPN:

```bash
./install.sh --bind lan
```

The setup:

1. Installs the `hypr-rdp` package with `omarchy-pkg-add`.
2. Installs four plugin-specific commands under `~/.local/bin`.
3. Creates a stable self-signed TLS identity under `~/.config/hypr-rdp`.
4. Installs and enables a systemd user service.
5. Prompts for a separate RDP-only password.

Existing TLS files are preserved. A plain reinstall also preserves the options file; an explicit `--bind localhost` or `--bind lan` updates only its `BIND` setting. The setup does not enable SSH, auto-login, router port forwarding, or firewall rules.

## Password and reboot behaviour

The RDP password is deliberately separate from the Omarchy account password. Its plaintext exists only at:

```text
$XDG_RUNTIME_DIR/hypr-rdp/password
```

That directory is RAM-backed and is cleared at reboot. Consequently, RDP remains disabled after reboot until an Omarchy graphical session is running and you re-arm it locally or over SSH:

```bash
omarchy-rdp-password
```

The password is never placed in a command-line argument and cannot authenticate to the local account or elevate privileges.

Stop the service and immediately remove the RAM-held RDP password with:

```bash
omarchy-rdp-stop
```

## Connect

In LAN mode, connect to the endpoint shown by the widget or `omarchy-rdp-password`, normally:

```text
<machine-LAN-IP>:3389
```

Use the Omarchy account name and the separate RDP password entered during setup.

Do not forward TCP 3389 directly from an internet router. For localhost mode, establish an SSH tunnel from the client:

```bash
ssh -N -L 3389:127.0.0.1:3389 your-user@machine-address
```

Then connect the RDP client to `127.0.0.1:3389`.

## Configure

Edit:

```text
~/.config/hypr-rdp/options
```

Apply changes after re-arming the service:

```bash
systemctl --user restart hypr-rdp.service
```

Defaults are 30 fps, 8 Mbit/s, and automatic encoder selection. The options file includes examples for resolution, scale, audio, capture protocol, and a particular physical output.

Diagnostics:

```bash
omarchy-rdp-status | jq
systemctl --user status hypr-rdp.service
journalctl --user -u hypr-rdp.service -b
ss -ltn | grep ':3389'
```

If the default capture method fails, add `--capture-mode ext` to the `OPTIONS` array.

## Update

```bash
omarchy plugin update io.github.ylaung-uod.omarchy-rdp
```

If an update changes runtime scripts or the service unit, rerun `./install.sh` to preserve the current network setting. Use `./install.sh --bind localhost` or `./install.sh --bind lan` to change an existing binding explicitly.

## Uninstall

Remove the runtime before removing the shell plugin:

```bash
cd ~/.config/omarchy/plugins/io.github.ylaung-uod.omarchy-rdp
./uninstall.sh
omarchy plugin remove io.github.ylaung-uod.omarchy-rdp
```

Preserve configuration and the stable TLS fingerprint:

```bash
./uninstall.sh --keep-config
```

Also remove the upstream package if no other setup uses it:

```bash
./uninstall.sh --remove-package
```

Installation and uninstallation do not change the Omarchy account password.

## Development and tests

```bash
./tests/run.sh
omarchy plugin validate .
```

The project is licensed under the MIT License.
