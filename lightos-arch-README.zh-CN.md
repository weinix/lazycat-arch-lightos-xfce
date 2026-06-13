# LightOS on Arch Linux —— XFCE 桌面搭建

*[English README / 英文文档](lightos-arch-README.md)*

LightOS 官方指南（[lazycat.cloud/playground/guideline/1537](https://lazycat.cloud/playground/guideline/1537)）
只提供了 **Debian** 版的辅助脚本（`lightos-debian-utils.sh`）。本项目是它的
**Arch Linux** 等价实现，用于搭建一个可以在浏览器里使用的 XFCE 桌面。

## 为什么 Arch 需要一份不同的脚本

| 组件        | Debian（`apt`）           | Arch                                   |
|------------|---------------------------|----------------------------------------|
| XFCE       | `xfce4`（官方源）          | `xfce4`（官方源）✅                      |
| VNC 服务端  | `tigervnc-*`（官方源）     | `tigervnc`（官方源）✅                   |
| noVNC 网页  | `novnc`（官方源）          | **仅 AUR** → 改用 `git clone`           |
| websockify | `websockify`（官方源）     | **仅 AUR** → 改用 `python venv`         |
| xrdp       | `xrdp`（官方源）           | **仅 AUR** → 需要自行编译                |

因此默认路径把所有东西都放在 **官方源 + git + venv** 上，而把 **xrdp 作为可选的
从 AUR 编译的步骤** 来处理。

## 推荐路径：浏览器里的 XFCE + noVNC（端口 6080）

这与 Debian 指南里的“浏览器桌面”一致，并配合 LightOS 的 **服务转发** 使用。

```bash
# 用你的普通用户运行（需要时会自动 sudo）
bash lightos-arch-utils.sh desktop
```

如果你以 `root` 登录，请指定桌面应以哪个用户运行：

```bash
TARGET_USER=youruser bash lightos-arch-utils.sh desktop
```

它会安装/创建：
- 软件包：`xfce4 xfce4-goodies tigervnc dbus xorg-xrdb xorg-xauth git python` + 中日韩字体/区域设置
- `/opt/novnc`：noVNC 网页资源（git clone，标签 `v1.5.0`）
- `/opt/novnc-venv`：放在 venv 里的 `websockify`
- `~/.vnc/config` → 分辨率/色深/`localhost`/`SecurityTypes=None` + `session=xfce`
  （TigerVNC ≥ 1.13 从这里读取选项，**而不是**命令行参数）
- `~/bin/start-browser-desktop` 启动脚本（先起 D-Bus 会话，再起 VNC 服务，最后起 websockify）
- `browser-desktop.service`（systemd 服务），开机自启

### 连接

1. 在 LightOS 控制台里添加一条 **服务转发** 规则：
   - 地址 `127.0.0.1`，端口 `6080`
2. 在浏览器里打开转发后的地址：`http://127.0.0.1:6080/`

> VNC 认证被 **禁用**（`SecurityTypes=None`），并且服务只监听本地回环
> （`~/.vnc/config` 里的 `localhost`），与 Debian 默认行为一致 —— 访问由 LightOS 的
> 转发来把关。**切勿**把 6080 端口公开暴露到公网。

### 管理

```bash
systemctl status  browser-desktop.service
systemctl restart browser-desktop.service
journalctl -u browser-desktop.service -f
bash lightos-arch-utils.sh status      # 即使 systemctl 不可用也能查看
```

### 在新版 TigerVNC（≥ 1.13，例如 Arch 的 1.16）上的工作原理

Arch 自带的 `vncserver` 比 Debian 的新很多，其行为发生了变化，会让一个简单的
`apt`→`pacman` 直译移植失效。本启动脚本对这些差异都做了处理：

- **选项来自配置文件，而非命令行。** `vncserver` 只接受 `vncserver <display>`，
  `-geometry/-depth/-localhost/-SecurityTypes` 都会被拒绝。
  → 改为写入 `~/.vnc/config`。
- **桌面会话来自 `/usr/share/xsessions/*.desktop`**，而不再是 `~/.vnc/xstartup`
  （后者现在会被忽略）。`session=xfce` 选中 `xfce.desktop`（`Exec=startxfce4`）。
- **`vncserver` 以前台方式运行 `xinit`**（不再变成守护进程），因此脚本会把它放到
  后台，等待 VNC 端口就绪后，再在前台运行 websockify。
- **`vncserver -kill` 已不存在**；清理改为杀掉进程并删除残留的
  `/tmp/.X<n>-lock` 与套接字。
- **`XAUTHORITY` 被强制为 `~/.Xauthority`。** LightOS 会注入
  `XAUTHORITY=/run/catlink/.Xauthority`，它无法被加锁 —— 保留它会导致 X 会话授权
  失败、桌面始终起不来。
- **启动前会准备好真正的 D-Bus 会话总线 + `XDG_RUNTIME_DIR`**（通过 `dbus-launch`）。
  没有它们时 `xfce4-session` 虽会启动，但不会拉起任何组件（你只会看到一块灰屏）。

## 可选路径：xrdp（LightOS 原生 RDP，端口 3389）

如果你想用 LightOS 内置的 **RDP** 远程桌面而非浏览器，可走这条路。xrdp 在 Arch 上
仅在 AUR 提供，因此这一步会 **编译** `xorgxrdp` 和 `xrdp`。必须以一个带 sudo 的
**非 root** 用户运行（makepkg 拒绝以 root 运行）：

```bash
bash lightos-arch-utils.sh xrdp
```

它会编译两个 AUR 包，设置 `~/.xinitrc → exec startxfce4`，并启用 `xrdp` 与
`xrdp-sesman`。用任意 RDP 客户端（或 LightOS RDP）连接 3389 端口即可。

## 可选：开发 / 命令行工具

```bash
bash lightos-arch-utils.sh tools
```

从官方源安装 `ripgrep fd starship` 及网络工具（在 Arch 上 `ripgrep`/`fd` 都已打包，
不像 Debian 需要走 GitHub deb 的变通办法），并可选为目标用户安装 `nvm`+Node LTS 和
`uv`。

## 其它子命令

```bash
bash lightos-arch-utils.sh hostname myhost   # 修正 /etc/hostname + /etc/hosts
bash lightos-arch-utils.sh all               # hostname + desktop + tools
bash lightos-arch-utils.sh --help
```

## 可调参数（环境变量）

| 变量            | 默认值         | 含义                     |
|-----------------|----------------|--------------------------|
| `TARGET_USER`   | 当前用户       | 桌面以哪个用户运行       |
| `NOVNC_PORT`    | `6080`         | 要转发的浏览器端口       |
| `GEOMETRY`      | `1280x800`     | 屏幕分辨率               |
| `DEPTH`         | `24`           | 色深                     |
| `DESKTOP_LANG`  | `en_US.UTF-8`  | 桌面区域设置             |
| `NOVNC_VERSION` | `v1.5.0`       | noVNC 的 git 标签        |

## 说明 / 注意事项

- 需要容器内有以 PID 1 运行的 `systemd`（LightOS 系统容器满足此条件），
  `systemctl enable`/`restart` 才会生效。
- TigerVNC 的 `vncserver` 包装脚本由官方 `tigervnc` 包提供。参见上文
  *“在新版 TigerVNC 上的工作原理”* —— 它的命令行/行为与 Debian 的旧版差别很大。
- `dbus-launch` 来自 Arch 的 `dbus` 包（Arch 上没有 `dbus-x11` 包）。
- 无头容器里的无害日志噪音：`libEGL … /dev/dri/card0 Permission denied`（无 GPU）、
  `dbus-update-activation-environment … systemd1 exited`（无 `systemd --user`）、
  以及 `tumblerd` 缩略图插件和 `xfce4-power-manager` 的提示。它们都不会影响桌面运行。
