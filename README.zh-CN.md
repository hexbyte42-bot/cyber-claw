# OpenClaw 的 Debian XFCE + XRDP 配置指南

[![Integration Run (Self-hosted)](https://github.com/riverscn/cyber-claw/actions/workflows/integration-run.yml/badge.svg)](https://github.com/riverscn/cyber-claw/actions/workflows/integration-run.yml)

[English README](./README.md)

![XFCE 桌面截图](./assets/screenshot.png)

## 远程桌面使用能力说明（非常适合人机协作）

- 非常适合人机协作的远程桌面环境。
- 定制化 XFCE，提供仿 macOS 核心 GUI 体验。
- 通过 RDP 协议连接远程桌面，相比 VNC 更加流畅；支持主机间共享剪贴板、复制粘贴文件、传输音频和视频。
- 已配置好 OpenClaw 在启动时自动拉起 XRDP 会话，以便工作在人远程登录的桌面环境中。

## ISO 安装后的准备说明（sudo + curl）

如果你是通过 Debian ISO 安装系统，当前登录用户可能还没有 `sudo` 权限，也可能没有安装 `curl`。

1. **给当前用户添加 sudo 权限**
   - 先以 `root` 登录（或通过 `su -` 切换到 root）。
   - 安装 sudo，并把你的用户加入 sudo 组：

```bash
apt-get update
apt-get install -y sudo
usermod -aG sudo <你的用户名>
```

   - 退出并重新登录后，执行下面命令确认 sudo 生效：

```bash
sudo -v
```

2. **如果没有 curl，先安装 curl**

```bash
sudo apt-get update
sudo apt-get install -y curl
```

完成后，再继续执行下面的一行安装命令。

## 一行安装（curl）

请在**全新 Debian 13（trixie）系统**上运行本脚本。推荐使用云镜像，流程最简单。

你可以在 <https://www.debian.org/distrib/> 查看并选择合适的 Debian 云镜像。

如果你是通过 ISO 安装，请在任务选择时：**只勾选 Xfce 桌面**，并**取消其它所有桌面环境**。

通过 SSH 登录到新安装的虚拟机后，执行：

```bash
curl -fsSL https://github.com/riverscn/cyber-claw/raw/main/install-xfce-xrdp-on-debian.sh | bash
```

本仓库包含一个脚本，用于把 Debian 机器配置为 XFCE + XRDP，配置中文输入（fcitx5 + 拼音），优化桌面体验，并接好 OpenClaw 会话行为，以便后续 OpenClaw 安装能够顺利进行。

安装完成并重启后，你可以使用 ***Windows 远程桌面*** 或 ***Windows App for Mac***，通过 VM IP 连接到你的虚拟机。

## 安装后如何使用

1. 脚本执行完成后，先重启一次 VM。
2. 打开 RDP 客户端（Windows 远程桌面 / Windows App for Mac）。
3. 使用 `<VM-IP>:3389`，输入 Linux 用户名和密码登录。
4. 登录后，在 XFCE 桌面中使用 OpenClaw。

### Plank（dock）使用提示

本配置使用 `plank-reloaded` 作为 dock。需要打开它的配置菜单时，在 dock 上**按住 Ctrl 再点击**即可弹出。

## 脚本会做什么

`install-xfce-xrdp-on-debian.sh` 会执行以下操作：

1. 更新 apt，并安装 XFCE、XRDP、Xorg XRDP、一些辅助工具（如 `xclip`）以及字体（包括 Noto CJK/Emoji）。
2. 安装并配置 `fcitx5`，启用中文拼音输入（默认保留英文）。
3. 安装 Papirus 图标主题、XFCE appmenu 插件、LibreOffice 和 Chromium。
4. 在运行中的 XRDP 会话内将 Papirus 设为默认图标主题。
5. 从 zquestz 的 Debian 仓库安装 `plank-reloaded`，并启用开机自启动。
6. 配置 XFCE 面板：
   - 删除 `panel-2`
   - 强制 `plugin-2` 使用 appmenu 插件
   - 应用 appmenu 设置
7. 配置 OpenClaw 网关集成，目标是让 OpenClaw 运行在 XRDP 桌面会话上下文中（而不是纯 TTY/后台上下文）：
   - 添加 systemd 用户级 override：网关启动前先检查/拉起 XRDP 会话
   - 配置 XFCE 自动启动：桌面登录后重启网关，把运行上下文绑定到该 XRDP 用户会话
8. 禁用 `lightdm`（无头/远程工作流）。

脚本结束时会打印安装 OpenClaw 的手动步骤。

## 运行要求

- 基于 Debian 且使用 `apt` 的系统
- 使用 `sudo` 运行（或直接使用 `root`）
- 需要网络访问以安装软件包并拉取 Plank 仓库密钥
- 内存：**2 GB 及以上**即可。安装完成后，基础服务 + 桌面环境常驻内存占用通常约 **700 MB**。

## 用法

```bash
sudo bash install-xfce-xrdp-on-debian.sh
```

该脚本设计为在全新或干净的 Debian 实例上运行一次。它会尝试识别目标用户（调用 `sudo` 的用户），并为该用户的主目录写入 XFCE 设置、autostart 条目和 systemd 用户级 override。

## 最后手动步骤（安装 OpenClaw）

脚本执行完成后，请手动安装 OpenClaw：

```bash
curl -fsSL https://openclaw.ai/install.sh | bash
```

## 说明

- 设计目标是：让 OpenClaw 网关运行在 XRDP 桌面会话上下文里，避免 GUI 相关行为跑在错误上下文（例如纯后台会话）。
- 脚本会尝试与一个正在运行的 XRDP 会话交互，以可靠应用 XFCE 设置。若不存在 XRDP 会话，它会尝试创建一个。
- XFCE 面板设置会通过 XRDP 会话内的 `xfconf-query` 写入。
- 脚本默认禁用 `lightdm`（无头/远程工作流）；如果你需要本地 GUI 登录，请手动重新启用。
- 脚本只会在交互式终端里询问是否重启；如果是非交互方式运行（例如 `curl | bash`），会跳过询问并提示你手动重启。

## 故障排查

- 如果 XRDP 启动失败，请检查：
  - `systemctl status xrdp`
  - `journalctl -u xrdp -e`
- 如果 XFCE 设置没有生效，请先通过 XRDP 登录一次，然后重新运行脚本。
- 如果 `plank` 没有自动启动，请检查以下路径中的 autostart 文件：
  - `~/.config/autostart/plank-reloaded.desktop`

## 文件

- `install-xfce-xrdp-on-debian.sh`：主安装脚本
