# LightOS on Arch Linux — XFCE desktop setup

The official LightOS guide ([lazycat.cloud/playground/guideline/1537](https://lazycat.cloud/playground/guideline/1537))
only ships a **Debian** helper (`lightos-debian-utils.sh`). This is the **Arch Linux**
equivalent for getting an XFCE desktop you can use from your browser.

## Why Arch needs a different script

| Component  | Debian (`apt`)            | Arch                                  |
|------------|---------------------------|---------------------------------------|
| XFCE       | `xfce4` (official)        | `xfce4` (official) ✅                  |
| VNC server | `tigervnc-*` (official)   | `tigervnc` (official) ✅               |
| noVNC web  | `novnc` (official)        | **AUR only** → use `git clone` instead |
| websockify | `websockify` (official)   | **AUR only** → use a `python venv`     |
| xrdp       | `xrdp` (official)         | **AUR only** → must compile           |

So the Arch script keeps everything on the **official repos + git + a venv** for the
default path, and treats **xrdp as an optional compile-from-AUR step**.

## Recommended path: XFCE + noVNC in the browser (port 6080)

This mirrors the Debian guide's "browser desktop" and works with LightOS
**service forwarding**.

```bash
# run as your normal user (it sudo's when needed)
bash lightos-arch-utils.sh desktop
```

If you are logged in as `root`, tell it which user the desktop should run as:

```bash
TARGET_USER=youruser bash lightos-arch-utils.sh desktop
```

What it installs/creates:
- packages: `xfce4 xfce4-goodies tigervnc dbus xorg-xrdb xorg-xauth git python` + CJK fonts/locales
- noVNC web assets in `/opt/novnc` (git clone, tag `v1.5.0`)
- `websockify` in a venv at `/opt/novnc-venv`
- `~/.vnc/xstartup` → `dbus-run-session -- startxfce4`
- `~/bin/start-browser-desktop` launcher
- `browser-desktop.service` (systemd), enabled on boot

### Connecting

1. In the LightOS console, add a **service forwarding** rule:
   - address `127.0.0.1`, port `6080`
2. Open the forwarded URL in your browser: `http://127.0.0.1:6080/`

> VNC auth is **disabled** (`-SecurityTypes None`) and the server binds to
> localhost only, exactly like the Debian default — access is gated by LightOS's
> forwarding. Do **not** expose port 6080 publicly.

### Managing it

```bash
systemctl status  browser-desktop.service
systemctl restart browser-desktop.service
journalctl -u browser-desktop.service -f
bash lightos-arch-utils.sh status      # works even if systemctl is unavailable
```

## Optional path: xrdp (LightOS-native RDP, port 3389)

Use this if you want LightOS's built-in **RDP** remote desktop instead of the
browser. xrdp is AUR-only on Arch, so this **compiles** `xorgxrdp` and `xrdp`.
Must be run as a **non-root** user with sudo (makepkg refuses root):

```bash
bash lightos-arch-utils.sh xrdp
```

It builds the two AUR packages, sets `~/.xinitrc → exec startxfce4`, and enables
`xrdp` + `xrdp-sesman`. Connect with any RDP client (or LightOS RDP) to port 3389.

## Optional: dev/CLI tools

```bash
bash lightos-arch-utils.sh tools
```

Installs `ripgrep fd starship` + network tools from the official repos (on Arch
`ripgrep`/`fd` are packaged, unlike Debian's GitHub-deb workaround), and offers
`nvm`+Node LTS and `uv` for the target user.

## Other subcommands

```bash
bash lightos-arch-utils.sh hostname myhost   # fix /etc/hostname + /etc/hosts
bash lightos-arch-utils.sh all               # hostname + desktop + tools
bash lightos-arch-utils.sh --help
```

## Tunables (env vars)

| Var             | Default        | Meaning                          |
|-----------------|----------------|----------------------------------|
| `TARGET_USER`   | current user   | user the desktop runs as         |
| `NOVNC_PORT`    | `6080`         | browser port to forward          |
| `GEOMETRY`      | `1280x800`     | screen size                      |
| `DEPTH`         | `24`           | color depth                      |
| `DESKTOP_LANG`  | `en_US.UTF-8`  | desktop locale                   |
| `NOVNC_VERSION` | `v1.5.0`       | noVNC git tag                    |

## Notes / caveats

- Requires `systemd` running as PID 1 in the container (LightOS system containers
  provide this) for the `--now` service enable to take effect.
- TigerVNC's `vncserver` wrapper is provided by the official `tigervnc` package.
- `dbus-run-session` comes from `dbus` on Arch (there is no `dbus-x11` package).
