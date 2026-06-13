#!/usr/bin/env bash
#
# lightos-arch-utils.sh
# -----------------------------------------------------------------------------
# Arch Linux port of the LightOS "lightos-debian-utils.sh" desktop helper.
#
# Goal: stand up an XFCE desktop inside a LightOS Arch container and reach it
# from your browser through LightOS "service forwarding" (default port 6080),
# the same way the Debian guide does it.
#
# Why this differs from the Debian script:
#   - Arch's official repos have `xfce4` and `tigervnc`, but NOT `novnc` or
#     `websockify` (those are AUR-only), and NOT `xrdp` (AUR-only).
#   - To stay reliable without an AUR helper, this script gets noVNC via a
#     plain `git clone` and runs `websockify` from a dedicated python venv.
#   - xrdp (LightOS-native RDP, port 3389) is offered as an OPTIONAL path that
#     builds two AUR packages; see the `xrdp` subcommand notes.
#
# Usage:
#   bash lightos-arch-utils.sh                 # = `desktop`, the default
#   bash lightos-arch-utils.sh desktop         # XFCE + noVNC browser desktop (6080)
#   bash lightos-arch-utils.sh tools           # ripgrep/fd/nvm-node/uv/network tools
#   bash lightos-arch-utils.sh hostname [name] # fix /etc/hostname + /etc/hosts
#   bash lightos-arch-utils.sh xrdp            # optional: xrdp via AUR (RDP 3389)
#   bash lightos-arch-utils.sh status          # show/inspect browser-desktop.service
#
# Run as your normal user (it calls sudo when needed), or as root with
#   TARGET_USER=<youruser> bash lightos-arch-utils.sh
# so the desktop runs under that user instead of root.
# -----------------------------------------------------------------------------

set -u -o pipefail

# ------------------------------- configuration -------------------------------
TARGET_USER="${TARGET_USER:-}"
CURRENT_USER="$(id -un)"

# Where noVNC web assets and the websockify venv live (system-wide, read-only
# to the desktop service user).
NOVNC_DIR="${NOVNC_DIR:-/opt/novnc}"
NOVNC_VERSION="${NOVNC_VERSION:-v1.5.0}"          # noVNC git tag to check out
NOVNC_VENV="${NOVNC_VENV:-/opt/novnc-venv}"       # python venv holding websockify

# Desktop / VNC defaults (override via env before running, or edit the unit).
VNC_DISPLAY_NUM="${VNC_DISPLAY_NUM:-1}"           # X display :1 -> VNC port 5901
NOVNC_PORT="${NOVNC_PORT:-6080}"                  # browser port (forward this)
GEOMETRY="${GEOMETRY:-1280x800}"
DEPTH="${DEPTH:-24}"

# Locale: default to English UTF-8 but also generate zh_CN and install CJK fonts
# (LightOS is a Chinese product; this keeps Chinese rendering working).
DESKTOP_LANG="${DESKTOP_LANG:-en_US.UTF-8}"

# -------------------------------- logging ------------------------------------
log()   { printf '[INFO] %s\n' "$*"; }
warn()  { printf '[WARN] %s\n' "$*" >&2; }
error() { printf '[ERROR] %s\n' "$*" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { error "missing command: $1"; return 1; }; }

run_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then "$@"; else need_cmd sudo || return 1; sudo "$@"; fi
}

confirm() {
  local answer=""
  read -r -p "$1 [y/N]: " answer
  case "${answer}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ------------------------------ system checks --------------------------------
ensure_arch() {
  [[ -r /etc/os-release ]] || { error "cannot read /etc/os-release"; return 1; }
  local id; id="$(. /etc/os-release && printf '%s' "${ID}")"
  if [[ "${id}" != "arch" && "${id}" != "archarm" && "${id}" != "manjaro" ]]; then
    warn "this script targets Arch Linux; detected ID=${id:-unknown}. Continuing anyway."
  fi
}

resolve_target_user() {
  if [[ -z "${TARGET_USER}" ]]; then
    if [[ "${CURRENT_USER}" != "root" ]]; then
      TARGET_USER="${CURRENT_USER}"
    else
      warn "running as root and TARGET_USER is unset; the desktop will run as root."
      warn "re-run as 'TARGET_USER=<youruser> bash $0 ...' to use a normal user."
      TARGET_USER="root"
    fi
  fi
  getent passwd "${TARGET_USER}" >/dev/null 2>&1 || { error "user does not exist: ${TARGET_USER}"; return 1; }
  log "target user: ${TARGET_USER}"
}

user_home() { getent passwd "$1" | cut -d: -f6; }
user_group() { id -gn "$1"; }

# Run a login shell as a given user (handles root/self/other like the Debian one).
run_as_user() {
  local user="$1" script="$2" home
  home="$(user_home "${user}")" || { error "no home for ${user}"; return 1; }
  if [[ "${EUID}" -ne 0 && "${user}" == "${CURRENT_USER}" ]]; then
    HOME="${home}" USER="${user}" bash -lc "${script}"
  elif [[ "${EUID}" -eq 0 && "${user}" == "root" ]]; then
    HOME="${home}" USER="${user}" bash -lc "${script}"
  else
    run_sudo -H -u "${user}" env HOME="${home}" USER="${user}" bash -lc "${script}"
  fi
}

# Install a file with correct ownership for the target user (or root).
write_owned_file() {
  local user="$1" path="$2" mode="$3" content="$4" tmp grp
  tmp="$(mktemp)"; printf '%s' "${content}" >"${tmp}"
  if [[ "${user}" == "${CURRENT_USER}" && "${EUID}" -ne 0 ]]; then
    mkdir -p "$(dirname "${path}")"; install -m "${mode}" "${tmp}" "${path}"
  elif [[ "${user}" == "root" ]]; then
    run_sudo install -D -m "${mode}" "${tmp}" "${path}"
  else
    grp="$(user_group "${user}")"
    run_sudo install -D -m "${mode}" -o "${user}" -g "${grp}" "${tmp}" "${path}"
  fi
  rm -f "${tmp}"
}

# ------------------------------ pacman helpers -------------------------------
PACMAN_SYNCED=0
pacman_sync_once() {
  [[ "${PACMAN_SYNCED}" -eq 1 ]] && return 0
  PACMAN_SYNCED=1
  log "refreshing package databases (pacman -Sy)"
  run_sudo pacman -Sy --noconfirm
}

pac_install() {
  # --needed skips already-installed packages; groups (e.g. xfce4) are fine.
  pacman_sync_once || return 1
  log "installing: $*"
  run_sudo pacman -S --needed --noconfirm "$@"
}

# ------------------------------- locale/fonts --------------------------------
setup_locale_and_fonts() {
  pac_install noto-fonts noto-fonts-cjk noto-fonts-emoji wqy-zenhei ttf-dejavu || return 1

  local want
  for want in "${DESKTOP_LANG%.*}.UTF-8 UTF-8" "zh_CN.UTF-8 UTF-8" "en_US.UTF-8 UTF-8"; do
    local lname="${want%% *}"
    if ! locale -a 2>/dev/null | tr 'A-Z' 'a-z' | grep -qx "$(printf '%s' "${lname}" | tr 'A-Z' 'a-z' | sed 's/\.utf-8/.utf8/')"; then
      log "enabling locale: ${want}"
      run_sudo sed -i "s/^#\s*${lname} UTF-8/${lname} UTF-8/" /etc/locale.gen 2>/dev/null || true
      grep -q "^${lname} UTF-8" /etc/locale.gen 2>/dev/null || \
        printf '%s\n' "${want}" | run_sudo tee -a /etc/locale.gen >/dev/null
    fi
  done
  run_sudo locale-gen || warn "locale-gen reported a problem"
  command -v fc-cache >/dev/null 2>&1 && run_sudo fc-cache -f >/dev/null 2>&1 || true
}

# ------------------------------ hostname fix ---------------------------------
action_hostname() {
  local name="${1:-}"
  if [[ -z "${name}" ]]; then
    name="$(hostname 2>/dev/null || true)"
    if [[ -z "${name}" || "${name}" == "localhost" || "${name}" == "(none)" ]]; then
      read -r -p "enter hostname to use: " name
    fi
  fi
  [[ -n "${name}" ]] || { error "hostname must not be empty"; return 1; }

  printf '%s\n' "${name}" | run_sudo tee /etc/hostname >/dev/null
  printf '127.0.0.1 localhost\n127.0.1.1 %s\n::1 localhost ip6-localhost ip6-loopback\n' "${name}" \
    | run_sudo tee /etc/hosts >/dev/null
  if command -v hostnamectl >/dev/null 2>&1; then
    run_sudo hostnamectl set-hostname "${name}" || warn "hostnamectl failed; effective after reboot"
  else
    run_sudo hostname "${name}" || warn "hostname command failed; effective after reboot"
  fi
  log "hostname set to: ${name}"
}

# --------------------------- systemd user session ----------------------------
# On Arch, pam_systemd and dbus user sessions already ship with systemd/dbus;
# we just make sure the env vars exist in the user's shell, like the Debian one.
ensure_user_bus_env() {
  local user="$1" home block
  home="$(user_home "${user}")" || return 1
  block=$'# >>> lightos-arch:user-bus-env >>>\nexport XDG_RUNTIME_DIR="/run/user/$(id -u)"\nexport DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"\n# <<< lightos-arch:user-bus-env <<<'
  local rc="${home}/.bashrc" current
  current="$(run_as_user "${user}" 'cat ~/.bashrc 2>/dev/null' || true)"
  if ! printf '%s' "${current}" | grep -q 'lightos-arch:user-bus-env'; then
    write_owned_file "${user}" "${rc}" 0644 "${current}"$'\n\n'"${block}"$'\n'
    log "wrote XDG_RUNTIME_DIR/DBUS env block to ${user}'s ~/.bashrc"
  fi
}

# ============================================================================
#  noVNC browser desktop  (XFCE + TigerVNC + noVNC + websockify) on port 6080
# ============================================================================
install_desktop_packages() {
  # dbus provides dbus-run-session; xorg-xrdb for xstartup; tigervnc for Xvnc.
  pac_install xfce4 xfce4-goodies tigervnc dbus xorg-xrdb xorg-xauth \
              git python || return 1
  setup_locale_and_fonts
}

# Fetch noVNC static web assets (no AUR) and a websockify venv (no AUR).
install_novnc_and_websockify() {
  if [[ -d "${NOVNC_DIR}/.git" ]]; then
    log "updating noVNC checkout in ${NOVNC_DIR}"
    run_sudo git -C "${NOVNC_DIR}" fetch --depth 1 origin "${NOVNC_VERSION}" || true
    run_sudo git -C "${NOVNC_DIR}" checkout -f "${NOVNC_VERSION}" || true
  else
    log "cloning noVNC ${NOVNC_VERSION} into ${NOVNC_DIR}"
    run_sudo git clone --depth 1 --branch "${NOVNC_VERSION}" \
      https://github.com/novnc/noVNC "${NOVNC_DIR}" || {
        error "noVNC clone failed (check network / NOVNC_VERSION tag)"; return 1; }
  fi

  # Browser entry point: redirect / to the noVNC client with autoconnect.
  printf '%s\n' \
    '<!doctype html><html><head><meta charset="utf-8"><title>noVNC</title>' \
    '<meta http-equiv="refresh" content="0; url=vnc.html?autoconnect=true&resize=remote"></head>' \
    '<body><a href="vnc.html?autoconnect=true&resize=remote">Open noVNC</a></body></html>' \
    | run_sudo tee "${NOVNC_DIR}/index.html" >/dev/null

  if [[ -x "${NOVNC_VENV}/bin/websockify" ]]; then
    log "websockify venv already present at ${NOVNC_VENV}"
  else
    log "creating websockify venv at ${NOVNC_VENV}"
    run_sudo python -m venv "${NOVNC_VENV}" || return 1
    run_sudo "${NOVNC_VENV}/bin/pip" install --upgrade pip >/dev/null || return 1
    run_sudo "${NOVNC_VENV}/bin/pip" install websockify || {
      error "pip install websockify failed (check network)"; return 1; }
  fi
}

write_vnc_xstartup() {
  local user="$1" home content
  home="$(user_home "${user}")" || return 1
  content="$(cat <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export LANG="${DESKTOP_LANG:-en_US.UTF-8}"
export LC_ALL="${DESKTOP_LC_ALL:-${DESKTOP_LANG:-en_US.UTF-8}}"

[ -r "$HOME/.Xresources" ] && xrdb "$HOME/.Xresources" 2>/dev/null
exec dbus-run-session -- startxfce4
EOF
)"
  write_owned_file "${user}" "${home}/.vnc/xstartup" 0755 "${content}"
}

write_desktop_start_script() {
  local user="$1" home content
  home="$(user_home "${user}")" || return 1
  content="$(cat <<EOF
#!/bin/sh
set -eu

DISPLAY_NUM="\${DISPLAY_NUM:-${VNC_DISPLAY_NUM}}"
GEOMETRY="\${GEOMETRY:-${GEOMETRY}}"
DEPTH="\${DEPTH:-${DEPTH}}"
NOVNC_PORT="\${NOVNC_PORT:-${NOVNC_PORT}}"
NOVNC_DIR="\${NOVNC_DIR:-${NOVNC_DIR}}"
WEBSOCKIFY="\${WEBSOCKIFY:-${NOVNC_VENV}/bin/websockify}"
VNC_PORT=\$((5900 + DISPLAY_NUM))
export DESKTOP_LANG="\${DESKTOP_LANG:-${DESKTOP_LANG}}"

command -v vncserver >/dev/null 2>&1 || { echo "vncserver not found (pacman -S tigervnc)" >&2; exit 1; }
[ -x "\$WEBSOCKIFY" ] || { echo "websockify not found at \$WEBSOCKIFY" >&2; exit 1; }

cleanup() { vncserver -kill ":\$DISPLAY_NUM" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM HUP

# Restart cleanly if a stale server is on this display.
vncserver -kill ":\$DISPLAY_NUM" >/dev/null 2>&1 || true

# No VNC password: access is gated by LightOS service forwarding to localhost.
vncserver ":\$DISPLAY_NUM" -geometry "\$GEOMETRY" -depth "\$DEPTH" \\
  -localhost yes -SecurityTypes None

echo "XFCE VNC on display :\$DISPLAY_NUM (127.0.0.1:\$VNC_PORT)"
echo "Browser URL via service forwarding: http://127.0.0.1:\$NOVNC_PORT/"
echo "WARNING: VNC auth is disabled; only expose port \$NOVNC_PORT over localhost/forwarding."

exec "\$WEBSOCKIFY" --web="\$NOVNC_DIR" "0.0.0.0:\$NOVNC_PORT" "127.0.0.1:\$VNC_PORT"
EOF
)"
  write_owned_file "${user}" "${home}/bin/start-browser-desktop" 0755 "${content}"
}

write_desktop_service() {
  local user="$1" home grp content
  home="$(user_home "${user}")" || return 1
  grp="$(user_group "${user}")" || return 1
  content="$(cat <<EOF
[Unit]
Description=XFCE Browser Desktop via noVNC + TigerVNC
After=network.target

[Service]
Type=simple
User=${user}
Group=${grp}
WorkingDirectory=${home}
Environment=HOME=${home}
Environment=USER=${user}
Environment=LOGNAME=${user}
Environment=DISPLAY_NUM=${VNC_DISPLAY_NUM}
Environment=GEOMETRY=${GEOMETRY}
Environment=DEPTH=${DEPTH}
Environment=NOVNC_PORT=${NOVNC_PORT}
Environment=NOVNC_DIR=${NOVNC_DIR}
Environment=DESKTOP_LANG=${DESKTOP_LANG}
ExecStart=${home}/bin/start-browser-desktop
ExecStopPost=-/usr/bin/vncserver -kill :${VNC_DISPLAY_NUM}
Restart=on-failure
RestartSec=2
KillSignal=SIGTERM
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF
)"
  write_owned_file "root" "/etc/systemd/system/browser-desktop.service" 0644 "${content}"
}

enable_desktop_service() {
  command -v systemctl >/dev/null 2>&1 || { warn "no systemctl; skipping service enable"; return 0; }
  run_sudo systemctl daemon-reload || { warn "daemon-reload failed (is systemd PID 1 in this container?)"; return 0; }
  if run_sudo systemctl enable --now browser-desktop.service; then
    log "browser-desktop.service enabled and started"
  else
    warn "service failed to start; inspect with: bash $0 status"
  fi
}

action_desktop() {
  resolve_target_user || return 1
  install_desktop_packages || return 1
  install_novnc_and_websockify || return 1
  ensure_user_bus_env "${TARGET_USER}" || return 1
  write_vnc_xstartup "${TARGET_USER}" || return 1
  write_desktop_start_script "${TARGET_USER}" || return 1
  write_desktop_service "${TARGET_USER}" || return 1
  enable_desktop_service || return 1

  cat <<EOF

==================================================================
XFCE browser desktop configured.

  service : browser-desktop.service  (runs as ${TARGET_USER})
  desktop : XFCE
  port    : ${NOVNC_PORT}  (noVNC over TigerVNC display :${VNC_DISPLAY_NUM})

How to connect from your machine:
  In the LightOS console, add a "service forwarding" rule:
      address: 127.0.0.1   port: ${NOVNC_PORT}
  then open the forwarded URL in your browser:
      http://127.0.0.1:${NOVNC_PORT}/

Manual launch (debug):  ~${TARGET_USER}/bin/start-browser-desktop
Useful commands:
  systemctl status browser-desktop.service
  systemctl restart browser-desktop.service
  journalctl -u browser-desktop.service -f
==================================================================
EOF
}

# ============================================================================
#  Optional: xrdp via AUR  (LightOS-native RDP, port 3389)
# ============================================================================
aur_build_install() {
  # Build a single AUR package as the (non-root) target user with makepkg,
  # then install exactly the files makepkg reports (robust, no time guessing).
  local pkg="$1" user="$2" url="https://aur.archlinux.org/${1}.git"
  local home builddir listfile
  home="$(user_home "${user}")" || return 1
  builddir="${home}/.cache/lightos-aur/${pkg}"

  run_as_user "${user}" "
    set -eu
    src='${builddir}'
    rm -rf \"\$src\"; mkdir -p \"\$(dirname \"\$src\")\"
    git clone --depth 1 ${url} \"\$src\"
    cd \"\$src\"
    makepkg -sf --noconfirm
    makepkg --packagelist > .built-packages
  " || return 1

  listfile="${builddir}/.built-packages"
  # Read the built package paths (owned by the target user) and install as root.
  local pkgs
  pkgs="$(run_as_user "${user}" "cat '${listfile}'")" || return 1
  [[ -n "${pkgs}" ]] || { error "makepkg produced no packages for ${pkg}"; return 1; }
  # shellcheck disable=SC2086
  run_sudo pacman -U --noconfirm ${pkgs} || return 1
}

action_xrdp() {
  resolve_target_user || return 1
  cat <<EOF

xrdp on Arch is AUR-only and must be COMPILED. This needs:
  - base-devel + git
  - a NON-root user with sudo (makepkg refuses to run as root)
  - building two AUR packages: xorgxrdp, then xrdp

EOF
  if [[ "${TARGET_USER}" == "root" ]]; then
    error "xrdp build needs a normal user; re-run as that user or set TARGET_USER."
    return 1
  fi
  confirm "Proceed to install base-devel and build xrdp + xorgxrdp from AUR?" || { warn "aborted"; return 0; }

  pac_install base-devel git xfce4 xfce4-goodies xorg-server dbus || return 1
  setup_locale_and_fonts

  # makepkg deps resolution does not pull AUR deps, so build xorgxrdp first.
  log "building xorgxrdp (AUR)";  aur_build_install xorgxrdp "${TARGET_USER}" || { error "xorgxrdp build failed"; return 1; }
  log "building xrdp (AUR)";      aur_build_install xrdp     "${TARGET_USER}" || { error "xrdp build failed"; return 1; }

  # Point xrdp's session at XFCE for the target user.
  write_owned_file "${TARGET_USER}" "$(user_home "${TARGET_USER}")/.xinitrc" 0644 $'#!/bin/sh\nexec startxfce4\n'
  # startwm.sh fallback (used if ~/.xinitrc is absent).
  if [[ -f /etc/xrdp/startwm.sh ]]; then
    run_sudo sed -i 's/^test -x .*$/exec startxfce4/; s/^exec \/bin\/sh.*$/exec startxfce4/' /etc/xrdp/startwm.sh 2>/dev/null || true
  fi

  run_sudo systemctl enable --now xrdp xrdp-sesman || warn "could not enable xrdp services"

  cat <<EOF

xrdp installed.
  port: 3389 (RDP). Use LightOS's built-in RDP remote desktop, or forward 3389.
  session: XFCE (via ~/.xinitrc -> startxfce4)
Check:  systemctl status xrdp ; journalctl -u xrdp -f
EOF
}

# ============================================================================
#  Dev / CLI tools  (mostly official repos on Arch -> simpler than Debian)
# ============================================================================
action_tools() {
  resolve_target_user || return 1
  # Unlike Debian, ripgrep + fd are official Arch packages (no GitHub deb dance).
  pac_install ripgrep fd starship \
              iproute2 iputils lsof bind traceroute openbsd-netcat tcpdump \
              net-tools curl wget git base-devel || return 1

  # nvm + Node LTS for the target user (same approach as the Debian script).
  if confirm "Install nvm + Node.js LTS for ${TARGET_USER}?"; then
    run_as_user "${TARGET_USER}" '
      export NVM_DIR="$HOME/.nvm"; mkdir -p "$NVM_DIR"
      [ -s "$NVM_DIR/nvm.sh" ] || curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | PROFILE=/dev/null bash
      . "$NVM_DIR/nvm.sh"
      nvm install --lts && nvm alias default "lts/*" && nvm use default
      node -v; npm -v
    ' || warn "nvm/node install reported an error"
  fi

  # uv (Python) for the target user.
  if confirm "Install uv for ${TARGET_USER}?"; then
    run_as_user "${TARGET_USER}" '
      [ -x "$HOME/.local/bin/uv" ] || curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$HOME/.local/bin" UV_NO_MODIFY_PATH=1 sh
      "$HOME/.local/bin/uv" --version 2>/dev/null || true
    ' || warn "uv install reported an error"
  fi
}

# ------------------------------- status --------------------------------------
action_status() {
  if systemctl status browser-desktop.service --no-pager 2>/dev/null; then :; else
    warn "systemctl could not read the unit; falling back to port/process checks."
    command -v ss    >/dev/null 2>&1 && ss -ltnp 2>/dev/null | grep -E ":(${NOVNC_PORT}|59[0-9][0-9])" || true
    command -v pgrep >/dev/null 2>&1 && pgrep -af 'start-browser-desktop|websockify|Xvnc|Xtigervnc' || true
  fi
  printf '\nBrowser URL (via service forwarding): http://127.0.0.1:%s/\n' "${NOVNC_PORT}"
}

# --------------------------------- main --------------------------------------
usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  ensure_arch || true
  local cmd="${1:-desktop}"; shift || true
  case "${cmd}" in
    desktop)        action_desktop "$@" ;;
    xrdp)           action_xrdp "$@" ;;
    tools)          action_tools "$@" ;;
    hostname)       resolve_target_user >/dev/null 2>&1 || true; action_hostname "$@" ;;
    status)         action_status "$@" ;;
    all)            action_hostname "" ; action_desktop ; action_tools ;;
    -h|--help|help) usage ;;
    *)              error "unknown command: ${cmd}"; usage; exit 1 ;;
  esac
}

main "$@"
