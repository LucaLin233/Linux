# Linux Scripts Collection

面向 Debian 与 Ubuntu VPS 的系统初始化、网络调优、运行时配置和日常运维脚本集合。

脚本会修改系统配置、安装软件包或管理服务。使用前请阅读对应说明并备份重要数据；生产环境建议
先在相同发行版与版本的测试机验证。

## 支持范围

- 一键部署与模块：Debian 12 或更高版本、Ubuntu 22.04/24.04，Bash，systemd，root 权限；
- Ubuntu 需启用发行版软件源中的 `universe`，否则 Zram 或 Speedtest 等软件包可能不可用；
- Ubuntu 22.04（Jammy）不在 XanMod 官方 APT 支持范围内，内核步骤会安全跳过；
- 独立工具：以脚本顶部说明为准；大部分面向 Debian/Ubuntu 系统；
- `xanmod-install.sh`：主要面向 amd64/x86-64；
- 需要访问 GitHub、系统 APT 软件源和各工具的上游服务。

## 快速开始

推荐直接远程运行最新主脚本。脚本需要交互输入，因此使用进程替换，避免将标准输入占用为脚本内容：

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/linux_setup.sh)
```

如需先审阅再执行：

```bash
curl -fsSLo /tmp/linux_setup.sh \
  https://raw.githubusercontent.com/LucaLin233/Linux/main/linux_setup.sh
less /tmp/linux_setup.sh
sudo bash /tmp/linux_setup.sh
```

需要修改脚本或离线保留副本时，再克隆仓库：

```bash
git clone https://github.com/LucaLin233/Linux.git
cd Linux
sudo ./linux_setup.sh
```

> 运行过程中可能安装软件、修改 sysctl、SSH、Shell、定时任务和 systemd 服务。不要在未备份、
> 无控制台或无法接受中断的生产机上直接选择全部安装。

## Linux 一键部署

[`linux_setup.sh`](linux_setup.sh) 是主要入口。它会：

1. 检查 Debian/Ubuntu 版本、root、磁盘和网络；
2. 安装基础依赖并更新软件包索引；
3. 获取 GitHub 最新 Commit；
4. 从该固定 Commit 自动发现、下载和校验 `modules/*.sh`；
5. 解析模块顺序和依赖，执行全部或用户选择的模块；
6. 写入部署日志和摘要。

常用选项：

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/linux_setup.sh) --check-status
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/linux_setup.sh) --clean-cache
bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/linux_setup.sh) --version
bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/linux_setup.sh) --help
```

主要文件：

```text
/var/log/linux-setup.log
/root/deployment_summary.txt
/var/cache/linux-setup/
```

### 部署模块

| 菜单编号 | 模块 | 功能 | 主要影响 |
| ---: | --- | --- | --- |
| 1 | `system-optimize.sh` | Zram、系统 sysctl、journald、THP、时区和 Chrony | 为 headless VPS 设置 Panic 恢复、日志上限和低干扰 THP 策略；Ubuntu 可能安装内核模块、固件与 CPU 微码 |
| 2 | `system-customize.sh` | 动态 MOTD、中文 Locale、可选 XanMod | 可能修改 Locale、欢迎信息和内核 |
| 3 | `network-optimize.sh` | BBR、fq、动态 TCP/UDP 缓冲区、IPv4/IPv6 转发 | 仅在上联网卡使用 `accept_ra=2` 保留云平台 IPv6 RA；自动测速最多约 90 GB |
| 4 | `zsh-setup.sh` | Zsh、Oh My Zsh、Powerlevel10k 和插件 | 备份后重写 root 的 `.zshrc`，可修改默认 Shell |
| 5 | `mise-setup.sh` | Mise、Python、Node.js 和依赖迁移 | 配置 Shell 集成及每周 Mise 自动更新 |
| 6 | `tools-setup.sh` | NextTrace、Speedtest、htop、jq、tree 等 | 可能添加 NextTrace 第三方 APT 源 |
| 7 | `docker-setup.sh` | Docker Engine、Compose、Buildx、日志轮转 | 添加 Docker 官方 APT 源并管理 Docker 服务 |
| 8 | `auto-update-setup.sh` | 定时完整升级系统和内核 | 更新后需要重启时会等待 30 秒自动重启 |
| 9 | `ssh-security.sh` | SSH 端口、Root 登录与认证策略 | 完整管理 `sshd_config`，操作不当可能失去远程连接 |

当前只有 `mise-setup` 声明 `zsh-setup` 为强依赖；其他模块可以单独执行。
SSH 模块要求系统已安装并运行 `openssh-server`；精简镜像请先执行 `sudo apt install -y openssh-server`。
Docker 模块会按发行版自动选择 Docker 官方 Debian 或 Ubuntu APT 仓库。
菜单编号由主脚本按模块顺序动态生成。模块元数据中的 `order=10`、`20` 等值仅用于排序，
不是用户需要输入的编号。

### 配置备份与恢复

模块修改受管配置前会保留两级状态：

```text
*.initial-backup / *.initial-absent
*.previous-backup / *.previous-absent
```

- `initial`：第一次可信修改前的配置；旧版没有记录且无法证明原始状态时标记为 `initial-unknown`，不会猜测；
- `previous`：本次运行前的配置，每次运行更新一次；
- 共享配置（Crontab、`.zshrc`、`.bashrc`）按模块分别保存状态，避免不同模块互相覆盖；
- APT 软件源备份统一存放在 `/var/lib/linux-setup/apt-source-backups/`，避免 APT 扫描备份文件时产生无效扩展名提示；
- 恢复配置不会卸载软件包、内核、容器、Mise 运行时或用户数据。

支持恢复子命令的模块默认恢复 `previous`；追加 `initial` 恢复首次可信状态：

```bash
sudo bash module.sh restore
sudo bash module.sh restore initial
```

已经运行旧版脚本的服务器首次执行新版时，会先把当前配置保存为 `previous`。现有
`initial-backup` 永不覆盖；无法确认的旧版初始状态会拒绝 `restore initial`，普通 `restore`
仍可回到升级新版前的配置。

### 单独远程运行模块

直接运行模块会绕过主脚本的系统预检查、基础依赖安装、固定 Commit、统一日志和部署摘要。
新服务器优先运行主脚本并选择“自定义选择”；仅需重跑或单独配置某项功能时，再直接运行模块。

最小化安装的 Debian/Ubuntu 建议先准备与主脚本相同的基础依赖：

```bash
sudo apt update
sudo apt install -y curl wget git jq rsync sudo dnsutils cron psmisc locales gpg gpg-agent dirmngr
```

以下命令从 `main` 分支下载并立即执行最新模块。

> ⚠️ 以下代码块是命令索引。**每次只复制并执行需要的模块命令，不要整段执行。** 整段执行会依次
> 修改系统、网络、Shell、Docker、自动更新和 SSH 配置，并可能产生大量流量、自动重启或导致失联。

```bash
RAW_BASE="https://raw.githubusercontent.com/LucaLin233/Linux/main/modules"

# 1. Zram、系统调优、journald、THP、时区和 Chrony
sudo bash <(curl -fsSL "$RAW_BASE/system-optimize.sh")

# 2. 欢迎信息、中文环境和可选 XanMod
sudo bash <(curl -fsSL "$RAW_BASE/system-customize.sh")

# 3. 网络优化；默认会自动探测并应用，可能产生大量流量
sudo bash <(curl -fsSL "$RAW_BASE/network-optimize.sh")

# 4. Zsh、Oh My Zsh、Powerlevel10k 和插件
sudo bash <(curl -fsSL "$RAW_BASE/zsh-setup.sh")

# 5. Mise、Python 和 Node.js；请先完成第 4 项
sudo bash <(curl -fsSL "$RAW_BASE/mise-setup.sh")

# 6. NextTrace、Speedtest、htop、jq、tree 等工具
sudo bash <(curl -fsSL "$RAW_BASE/tools-setup.sh")

# 7. Docker Engine、Compose 和 Buildx
sudo bash <(curl -fsSL "$RAW_BASE/docker-setup.sh")

# 8. 每周系统与内核更新；需要时会自动重启
sudo bash <(curl -fsSL "$RAW_BASE/auto-update-setup.sh")

# 9. SSH 安全配置；操作前先确认控制台和云防火墙可用
sudo bash <(curl -fsSL "$RAW_BASE/ssh-security.sh")
```

`system-optimize.sh` 的 `restore` 只恢复该模块管理的配置和关联运行值，不卸载已安装软件：

```bash
RAW_BASE="https://raw.githubusercontent.com/LucaLin233/Linux/main/modules"
sudo bash <(curl -fsSL "$RAW_BASE/system-optimize.sh") restore
sudo bash <(curl -fsSL "$RAW_BASE/system-optimize.sh") restore initial
```

`system-customize.sh` 支持只运行指定功能：

```bash
RAW_BASE="https://raw.githubusercontent.com/LucaLin233/Linux/main/modules"
sudo bash <(curl -fsSL "$RAW_BASE/system-customize.sh") motd
sudo bash <(curl -fsSL "$RAW_BASE/system-customize.sh") locale
sudo bash <(curl -fsSL "$RAW_BASE/system-customize.sh") xanmod
sudo bash <(curl -fsSL "$RAW_BASE/system-customize.sh") status
sudo bash <(curl -fsSL "$RAW_BASE/system-customize.sh") help
```

`network-optimize.sh` 支持先计算、手动指定参数、查看状态和恢复配置：

```bash
RAW_BASE="https://raw.githubusercontent.com/LucaLin233/Linux/main/modules"
# 不执行外部测速，只显示保守配置计划
bash <(curl -fsSL "$RAW_BASE/network-optimize.sh") plan --no-probe

# 使用明确的带宽和 RTT，避免自动测速
sudo bash <(curl -fsSL "$RAW_BASE/network-optimize.sh") \
  install --download-mbps 1000 --upload-mbps 500 --rtt-ms 180

bash <(curl -fsSL "$RAW_BASE/network-optimize.sh") status
sudo bash <(curl -fsSL "$RAW_BASE/network-optimize.sh") restore
sudo bash <(curl -fsSL "$RAW_BASE/network-optimize.sh") restore initial
bash <(curl -fsSL "$RAW_BASE/network-optimize.sh") help
```

网络模块默认面向同时承载 TCP、UDP 与 Docker 流量的代理节点：连接队列使用
`somaxconn=65535`、`tcp_max_syn_backlog=16384`，默认 socket 缓冲区为 256 KiB，UDP 最小
缓冲区为 8 KiB，`tcp_fin_timeout=30`。动态最大缓冲区按 `2 × BDP` 计算，限制在
`RAM / 16` 且不超过 256 MiB；`--static` 仍保持固定 32 MiB。`netdev_budget` 在带宽达到
2.5 Gbps 且至少 2 个在线 CPU 时使用 600，其他环境明确使用内核默认值 300。

> `RAW_BASE` 只在当前 Shell 会话有效。上述进程替换语法需要 Bash 或 Zsh；不要改成
> `curl ... | sudo bash`，否则交互模块可能无法正常读取终端输入。SSH、自动更新、内核和网络
> 模块具有断连、重启或大量流量风险，执行前请阅读“高风险提醒”。

### 新增模块

新增脚本只需放入 `modules/`，无需修改主脚本。文件名必须匹配：

```text
[a-z0-9][a-z0-9-]*.sh
```

脚本开头声明：

```bash
#!/usr/bin/env bash
# linux-setup:name=模块显示名称
# linux-setup:order=100
# linux-setup:depends=
# linux-setup:enabled=true
```

主脚本会检查 Bash 语法、未知依赖和循环依赖，并按照 `order` 和文件名生成稳定顺序。
退出码约定：`0` 成功、`2` 部分完成、其他值失败。

## 独立工具

`tools/` 下的脚本不会被一键部署自动执行，应按需手动运行。

### Cloudflare Tunnel

安装、升级或彻底卸载 cloudflared Tunnel；安装流程会配置 systemd 服务和每日自动更新。

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/cloudflare_tunnel.sh) install
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/cloudflare_tunnel.sh) upgrade
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/cloudflare_tunnel.sh) uninstall
```

Token 属于敏感凭据，不要写入日志、README 或提交到 Git。
`uninstall` 会删除本脚本管理的二进制、服务、自动更新和配置文件。

### 出口流量整形 tcshape

从 tcpfit 移植限速器拐点 Sweep 与 `HTB + fq` Shape。它不会修改基础 sysctl，适用于存在
出口 policer 的特定 VPS，不是通用必选优化。

首次运行：

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/traffic-shape.sh)
```

随后可使用短命令：

```bash
sudo tcshape s        # 自动选公共节点并扫描
sudo tcshape a        # 应用最近推荐值
sudo tcshape on 480   # 手动限制为 480 Mbit
sudo tcshape off      # 关闭并恢复原 qdisc
sudo tcshape st       # 查看状态
```

Sweep 可能消耗大量上传流量，并会临时替换默认出口接口的根 qdisc。单方向上限约 45 GB，
双向合计上限约 90 GB。未检测到限速器或未找到拐点时，不建议且不能自动应用整形。

详细参数、安全边界和恢复说明见 [`docs/traffic-shape.md`](docs/traffic-shape.md)。

### 旧版网络优化脚本

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/kernel.sh) install -c    # 国内场景
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/kernel.sh) install -i    # 国际场景
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/kernel.sh) status
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/kernel.sh) restore

sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/kernel2.sh) install
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/kernel2.sh) status
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/kernel2.sh) restore
```

`kernel.sh`、`kernel2.sh` 和 `modules/network-optimize.sh` 会管理重叠的 sysctl、BBR、资源限制
或根 qdisc。**不要叠加执行。** 新部署优先使用 `network-optimize.sh`；旧脚本主要用于已有环境的
兼容和恢复。

### 多服务器文件推送

[`tools/push.sh`](tools/push.sh) 使用 SSH 和 rsync 并发同步文件，支持密钥或密码认证。

该工具依赖本地 `config.conf` 和待推送文件，不适合远程即用方式，请克隆仓库后运行：
```bash
git clone https://github.com/LucaLin233/Linux.git
cd Linux
./tools/push.sh --generate-config
./tools/push.sh --test-auth
./tools/push.sh TASK_NAME
./tools/push.sh /local/path/ /remote/path/
```

默认生成当前目录的 `config.conf`，权限为 `600`，且仓库已通过 `.gitignore` 忽略根目录和
`tools/` 下的该文件。推荐密钥认证，不要把密码直接写进仓库。

> 示例配置默认 `DELETE_EXTRA="true"`，等同于 rsync 删除目标端多余文件。首次使用前必须核对
> 源路径、目标路径和服务器列表，必要时将它改为 `false`。

### sing-box 安装

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/sbinstall.sh) install
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/sbinstall.sh) uninstall
```

安装前需要准备有效的 `/root/proxy/config.json` 以及脚本要求的证书文件权限。脚本会下载
sing-box、创建目录和 systemd 服务；卸载会停止并移除本脚本管理的服务和程序文件。

### 独立动态 MOTD

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/setup-motd.sh)
```

用于只部署动态登录欢迎信息，与 `modules/system-customize.sh` 的 MOTD 功能重叠；已经运行系统
定制模块时通常无需再次执行。脚本会备份并清空静态登录欢迎文件；其中静态 MOTD 会被替换为
普通空文件，避免其链接到运行时动态 MOTD 时被 PAM 重复显示。

### XanMod 内核

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/xanmod-install.sh)
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/xanmod-install.sh) status
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/xanmod-install.sh) help
```

脚本检测 x86-64 psABI 级别并选择适合的 XanMod 包。内核安装完成后通常需要重启才能生效；
请保留可用旧内核和控制台访问方式。

## 配置文件

- [`p10k-config.zsh`](p10k-config.zsh)：供 Zsh 模块使用的 Powerlevel10k 配置；
- `config.conf`：`push.sh` 生成的本地配置，可能包含敏感信息，不应提交；
- [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)：第三方代码来源和许可证。

## 功能重叠与选择

| 需求 | 推荐脚本 | 避免同时使用 |
| --- | --- | --- |
| 新 Debian/Ubuntu VPS 网络基础调优 | `modules/network-optimize.sh` | `kernel.sh`、`kernel2.sh` |
| 特定出口 policer 检测与整形 | `tools/traffic-shape.sh` | tcpfit Shape、CAKE、TBF、其他 HTB |
| 一键系统定制 | `system-customize.sh` | 重复运行 `setup-motd.sh` |
| 仅安装 XanMod | `xanmod-install.sh` | 同时让多个脚本反复管理内核源 |

`network-optimize.sh` 与 `traffic-shape.sh` 职责不同，可以配合：前者管理 BBR、缓冲区和默认
`fq`、仅上联网卡接收 RA 的 IPv6 转发和按能力启用的 TCP/Conntrack 参数；现有 Docker、veth、CNI 与隧道接口的 RA 会在运行时设为 `0` 并纳入回滚快照。后者在确实检测到 policer 后才使用 HTB 控制聚合出口速率，并保留 fq 叶子 pacing。

## 高风险提醒

- **SSH**：修改端口或认证前，先放行云安全组/防火墙，并保持当前会话直到新连接验证成功；
- **自动更新**：系统或内核更新后可能自动重启；
- **系统优化**：首次写入 journald 限额时会重启 `systemd-journald`，并设置 Kernel Panic 30 秒后重启；
- **IPv6 转发**：网络模块会使用 `accept_ra=2` 保留云平台 RA，但仍需确认云安全组和主机防火墙允许预期的 IPv6 流量；
- **网络测速**：`network-optimize` 和 tcshape 都可能产生大量流量；
- **qdisc**：不要叠加多个整形工具；tcshape 遇到高级或未知 qdisc 会拒绝覆盖；
- **内核**：安装新内核前确认磁盘空间、架构和可用的旧内核；
- **rsync**：`DELETE_EXTRA=true` 会删除目标端多余文件；
- **凭据**：不要提交 Token、密码、私钥、`.env` 或 `config.conf`。

## 问题排查

先收集完整、脱敏的信息：

```bash
cat /etc/os-release
uname -a
sudo tail -n 200 /var/log/linux-setup.log
systemctl --failed
journalctl -p warning -b --no-pager
```

根据故障再检查对应服务：

```bash
systemctl status ssh docker chrony cron tcshape.service
sshd -t
tc qdisc show
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
```

提交 Issue 时请提供系统版本、执行命令、退出码和已脱敏的完整日志，不要包含 Token、密码、
私钥、服务器清单或公网管理地址。

## 许可证与免责声明

本仓库采用 [MIT License](LICENSE)。第三方移植代码见
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

脚本按“原样”提供，不附带任何担保。发行版、内核、虚拟化、机房网络和软件源存在差异，使用者
应自行审查、备份、验证并承担操作后果。
