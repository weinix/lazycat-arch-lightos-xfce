# LightOS on Arch Linux — XFCE desktop setup

*[中文文档 / Chinese README](lightos-arch-README.zh-CN.md)*

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
- `~/.vnc/config` → geometry/depth/`localhost`/`SecurityTypes=None` + `session=xfce`
  (TigerVNC ≥ 1.13 reads options from here, **not** from CLI flags)
- `~/bin/start-browser-desktop` launcher (starts a D-Bus session, the VNC server,
  then websockify)
- `browser-desktop.service` (systemd), enabled on boot

### Connecting

1. In the LightOS console, add a **service forwarding** rule:
   - address `127.0.0.1`, port `6080`
2. Open the forwarded URL in your browser: `http://127.0.0.1:6080/`

> VNC auth is **disabled** (`SecurityTypes=None`) and the server binds to
> localhost only (`localhost` in `~/.vnc/config`), exactly like the Debian default —
> access is gated by LightOS's forwarding. Do **not** expose port 6080 publicly.

### Managing it

```bash
systemctl status  browser-desktop.service
systemctl restart browser-desktop.service
journalctl -u browser-desktop.service -f
bash lightos-arch-utils.sh status      # works even if systemctl is unavailable
```

### How it works on modern TigerVNC (≥ 1.13, e.g. Arch's 1.16)

Arch ships a much newer `vncserver` than Debian, and its behaviour changed in ways
that broke a naive `apt`→`pacman` port. The launcher accounts for all of these:

- **Options come from a config file, not the CLI.** `vncserver` only accepts
  `vncserver <display>`; `-geometry/-depth/-localhost/-SecurityTypes` are rejected.
  → written to `~/.vnc/config` instead.
- **The desktop session comes from `/usr/share/xsessions/*.desktop`,** not from
  `~/.vnc/xstartup` (which is now ignored). `session=xfce` selects `xfce.desktop`
  (`Exec=startxfce4`).
- **`vncserver` runs `xinit` in the foreground** (it no longer daemonises), so the
  launcher backgrounds it, waits for the VNC port, then runs websockify in front.
- **`vncserver -kill` is gone;** teardown kills the process and removes the stale
  `/tmp/.X<n>-lock` + socket.
- **`XAUTHORITY` is forced to `~/.Xauthority`.** LightOS injects
  `XAUTHORITY=/run/catlink/.Xauthority`, which can't be locked — leaving it set makes
  the X session fail to authorize and the desktop never appears.
- **A real D-Bus session bus + `XDG_RUNTIME_DIR` are set up** before launch (via
  `dbus-launch`). Without them `xfce4-session` starts but launches none of its
  components (you'd get a blank grey screen).

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
  provide this) for `systemctl enable`/`restart` to take effect.
- TigerVNC's `vncserver` wrapper is provided by the official `tigervnc` package.
  See *"How it works on modern TigerVNC"* above — its CLI/behaviour differs a lot
  from Debian's older build.
- `dbus-launch` comes from `dbus` on Arch (there is no `dbus-x11` package).
- Benign log noise in a headless container: `libEGL … /dev/dri/card0 Permission
  denied` (no GPU), `dbus-update-activation-environment … systemd1 exited` (no
  `systemd --user`), `tumblerd` thumbnail-plugin and `xfce4-power-manager` messages.
  None of these stop the desktop.
