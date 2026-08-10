# Linux Scripts Collection

一个面向 Debian 系列系统的个人 Linux 运维脚本仓库，包含系统初始化、环境配置、网络优化、服务部署和日常管理工具。

部分脚本使用 AI 工具辅助编写，经过人工检查、修改，并已在个人 VPS 环境中进行功能测试。由于发行版版本、内核、虚拟化环境和软件源配置可能存在差异，使用前仍应阅读脚本并做好备份。

## 项目内容

### Debian 一键部署

[`debian_setup.sh`](debian_setup.sh) 是仓库的主要入口，仅支持 Debian 12 及以上版本。脚本支持全部安装或自定义选择，并会解析模块依赖、按固定 commit 下载模块、记录执行日志以及生成部署摘要。

其功能由 `modules/` 下的模块组成：

| 模块 | 功能 |
| --- | --- |
| `system-optimize.sh` | 根据内存配置 Zram、设置时区并配置 Chrony 时间同步 |
| `system-customize.sh` | 配置动态 MOTD、中文 Locale，并可选安装 XanMod 内核 |
| `network-optimize.sh` | 配置 BBR、fq、IPv4 转发及代理和端口转发相关参数 |
| `zsh-setup.sh` | 安装 Zsh、Oh My Zsh、Powerlevel10k 和常用插件 |
| `mise-setup.sh` | 安装 Mise，管理 Python、Node.js 及运行时更新 |
| `tools-setup.sh` | 安装 NextTrace、Speedtest CLI 和常用系统工具 |
| `docker-setup.sh` | 通过 Docker 官方仓库安装 Docker Engine、Compose 和 Buildx |
| `auto-update-setup.sh` | 配置定期系统与内核更新，并在需要时自动重启 |
| `ssh-security.sh` | 配置 SSH 端口、Root 登录策略和认证方式 |

主脚本会从固定 Commit 的 `modules/*.sh` 自动发现模块。新增模块时无需修改
`debian_setup.sh`，只需在模块脚本的 shebang 后声明元数据：

```bash
#!/usr/bin/env bash
# debian-setup:name=模块显示名称
# debian-setup:order=100
# debian-setup:depends=
# debian-setup:enabled=true
```

模块文件名必须匹配 `[a-z0-9][a-z0-9-]*.sh`。`depends` 使用空格分隔依赖模块；
目前只有 `mise-setup` 将 `zsh-setup` 声明为强依赖。主脚本会检查模块语法、未知依赖
和循环依赖，并按照 `order` 与模块文件名生成稳定执行顺序。

### 独立工具

`tools/` 中的脚本可按需单独使用：

| 脚本 | 功能 |
| --- | --- |
| `cloudflare_tunnel.sh` | 安装、配置、更新或卸载 Cloudflare Tunnel |
| `sbinstall.sh` | 在 Debian 系列系统上安装或卸载 sing-box，并创建 systemd 服务 |
| `kernel.sh` / `kernel2.sh` | 两套独立的网络与内核参数优化方案，请按需选择，不要与新版网络模块重复使用 |
| `xanmod-install.sh` | 在 Debian 上检测 CPU 指令集并安装对应 XanMod 内核 |
| `setup-motd.sh` | 单独部署动态系统欢迎信息 |
| `push.sh` | 通过 SSH/rsync 向多台服务器并发推送文件 |

### 配置文件

- `p10k-config.zsh`：Powerlevel10k 配置，由 Zsh 模块使用。

## 环境要求

- 一键部署脚本：Debian 12 或更高版本
- `sbinstall.sh`：Debian、Ubuntu 等 Debian 系列系统
- Bash 和 systemd
- Root 权限或可用的 `sudo`
- 可访问 GitHub 等脚本所需的上游服务

独立工具的具体支持范围可能不同，请在执行前阅读对应脚本顶部说明。

## 使用方法

### 克隆仓库

```bash
git clone https://github.com/LucaLin233/Linux.git
cd Linux
```

### 运行一键部署脚本

```bash
chmod +x debian_setup.sh
sudo ./debian_setup.sh
```

`debian_setup.sh` 会引导选择全部模块或自定义模块。通常无需手动执行 `modules/` 下的脚本。

### 运行独立工具

```bash
chmod +x tools/cloudflare_tunnel.sh
sudo ./tools/cloudflare_tunnel.sh
```

将文件名替换为需要使用的实际脚本。例如：

```bash
chmod +x tools/sbinstall.sh
sudo ./tools/sbinstall.sh install
```

### 单独运行模块

仅在明确了解模块依赖及影响时单独执行模块：

```bash
chmod +x modules/network-optimize.sh
sudo ./modules/network-optimize.sh status
```

## 使用前须知

- 脚本会安装软件包，并可能修改 SSH、sysctl、内核、Shell、定时任务及 systemd 服务配置。
- 执行系统级操作前，请备份重要数据和相关配置文件。
- 修改 SSH 配置时应保留一个已连接会话，并先验证新连接，避免失去服务器访问权限。
- `kernel.sh`、`kernel2.sh` 与 `modules/network-optimize.sh` 存在功能重叠，请选择其中一种方案。
- 生产环境使用前，建议先在相同系统版本的测试环境中验证。
- 网络代理相关工具应在当地法律法规及服务条款允许的范围内使用。

## 问题排查

脚本执行失败时，请优先检查：

1. 是否使用了受支持的系统版本和 Root 权限。
2. 网络是否可以访问脚本引用的软件源和 GitHub。
3. APT/dpkg 是否被其他进程占用。
4. 终端输出、systemd 日志及脚本生成的日志文件。

一键部署脚本的主要输出文件：

- 日志：`/var/log/debian-setup.log`
- 部署摘要：`/root/deployment_summary.txt`

如仍无法解决，可提交 Issue，并附上系统版本、执行命令和已脱敏的完整错误日志。

## 免责声明

本仓库中的脚本按“原样”提供，不提供任何形式的担保。使用者应自行检查代码、评估风险，并承担执行脚本产生的后果。

## 许可证

本项目采用 [MIT License](LICENSE) 开源许可证。

## 相关文档

- [Debian Reference](https://www.debian.org/doc/manuals/debian-reference/)
- [sing-box Documentation](https://sing-box.sagernet.org/)
- [Cloudflare Tunnel Documentation](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- [Docker Engine on Debian](https://docs.docker.com/engine/install/debian/)
- [Mise Documentation](https://mise.jdx.dev/)
