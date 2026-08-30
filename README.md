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
- CI 在 Ubuntu 24.04 和 Debian 13 容器运行全部纯 Shell 测试；systemd 服务切换使用 stub
  验证事务与回滚，不等同于真实主机 E2E；
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
| 3 | `network-optimize.sh` | BBR、fq、动态 TCP 缓冲区与 initcwnd | 交互测速默认 Y；上传、下载各 12.5 GB，合计 25 GB |
| 4 | `zsh-setup.sh` | Zsh、Oh My Zsh、Powerlevel10k 和插件 | 备份后重写 root 的 `.zshrc`，可修改默认 Shell |
| 5 | `mise-setup.sh` | Mise、Python、Node.js 和依赖迁移 | 配置 Shell 集成及每周 Mise 自动更新 |
| 6 | `tools-setup.sh` | NextTrace、Speedtest、htop、jq、tree 等 | 可能添加 NextTrace 第三方 APT 源 |
| 7 | `docker-setup.sh` | Docker Engine、Compose、Buildx、日志轮转 | 添加 Docker 官方 APT 源并管理 Docker 服务 |
| 8 | `auto-update-setup.sh` | 定时完整升级系统和内核 | 更新后需要重启时会等待 30 秒自动重启 |
| 9 | `ssh-security.sh` | SSH 端口、Root 登录与认证策略 | 保留当前 `ListenAddress`，完整管理其余主配置；写入前显示 drop-in 冲突并再次确认 |

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

# 3. 网络优化；交互选择是否测速，测速可能产生大量流量
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
sudo bash <(curl -fsSL "$RAW_BASE/system-customize.sh") xanmod --yes
sudo bash <(curl -fsSL "$RAW_BASE/system-customize.sh") status
sudo bash <(curl -fsSL "$RAW_BASE/system-customize.sh") restore
sudo bash <(curl -fsSL "$RAW_BASE/system-customize.sh") restore initial
sudo bash <(curl -fsSL "$RAW_BASE/system-customize.sh") help
```

`restore` 会统一恢复 MOTD、Locale 和 XanMod 软件源文件；默认恢复上一次运行前状态，
`restore initial` 恢复首次运行前的可信状态。XanMod 的密钥、传统 list 与 Deb822 source
按一个整体预检和恢复；任一状态缺失、冲突或未知时不会进行部分恢复。模块更新 `initial`/`previous`
前会先快照完整旧 backup 组，把三个目标的全部状态写入 stage，全部成功后才提交；capture、旧备份迁移
或 commit 中途失败都会恢复同一世代的完整旧组。生产备份目录必须是 `root:root`、`0700` 的真实目录，
状态项也会校验类型、owner 和写权限。已安装的 XanMod 内核包不会被卸载。

直接执行 `xanmod` 会先完成只读规划；不支持的发行版、非 amd64、x86-64-v1，或目标包与正式仓库
文件已经严格安全有效时，无需确认。只有计划确实包含修改时才使用 `[y/N]`，无 TTY 必须显式传入
`--yes`。`all` 或无参数模式在无 TTY 时仍会完成 MOTD 与 Locale，但只跳过确需修改的 XanMod 步骤。

`network-optimize.sh` 支持自动测速、手动指定参数、查看状态和恢复配置：

```bash
RAW_BASE="https://raw.githubusercontent.com/LucaLin233/Linux/main/modules"
# 交互终端无参数运行：回车默认执行公共 iperf3 测速，选择 N 后手填带宽
sudo bash <(curl -fsSL "$RAW_BASE/network-optimize.sh")

# 非交互自动测速；install 模式可通过 APT 安装缺失的 iperf3 等依赖
sudo bash <(curl -fsSL "$RAW_BASE/network-optimize.sh") install --auto

# 绕过 7 天缓存强制现场测速；失败时仍可回退到 30 天内同路由缓存
sudo bash <(curl -fsSL "$RAW_BASE/network-optimize.sh") install --auto --refresh

# 非交互手动提供完整上下行带宽
bash <(curl -fsSL "$RAW_BASE/network-optimize.sh") \
  plan --download-mbps 1000 --upload-mbps 500

# 使用明确的带宽和 RTT，避免自动测速
sudo bash <(curl -fsSL "$RAW_BASE/network-optimize.sh") \
  install --download-mbps 1000 --upload-mbps 500 --rtt-ms 180

bash <(curl -fsSL "$RAW_BASE/network-optimize.sh") status
sudo bash <(curl -fsSL "$RAW_BASE/network-optimize.sh") restore
sudo bash <(curl -fsSL "$RAW_BASE/network-optimize.sh") restore initial
bash <(curl -fsSL "$RAW_BASE/network-optimize.sh") help
```

主脚本仍以无参数方式调用网络模块，因此进入该模块后会显示同一交互问题，直接回车走默认 Y。
无 TTY 时只接受 `--auto`、`--bandwidth-mbps` 或完整的 `--download-mbps` 与
`--upload-mbps`。自动测速仅使用 IPv4 公共 iperf3，最多选择两个节点，每方向固定
`P=4`、`t=5` 秒并采用有效较高结果；同方向节点差异超过 30% 时只降低可信度并警告。
上传、下载预算各为 12.5 GB，总预算 25 GB，按实际出口接口计数并包含同期后台流量。自动测速
先记录 `1.1.1.1` 对应的默认 IPv4 出口身份，只测试并采纳 ifindex、接口、网关和源地址完全
一致的公共节点；应用前会再次校验，避免路由切换后写入失真的调优值。

成功测量通过路由复核后写入 v2 缓存，固定绑定 `1.1.1.1` 的 ifindex、接口、网关和源地址；旧版
缓存会被忽略。7 天内缓存可直接复用；`--auto --refresh` 会绕过它并强制现场测速。现场测速失败
时，只允许回退到 30 天内且路由身份完全一致的缓存；refresh 回退范围也包含 7 天内缓存。单节点、
结果分歧、预算停止或缓存回退属于低可信度：只要上下行输入完整且应用验证成功，命令仍返回 0，
并把来源、时间、节点、可信度和警告写入配置供 `status` 显示。缺少任一方向、应用验证失败或触发
回滚返回 1。

`initcwnd` 默认为 `auto`：上传带宽不高于 100 Mbps 时保留内核默认，否则在默认路由设置
`initcwnd/initrwnd=32`；`--enable-initcwnd` 和 `--disable-initcwnd` 可显式覆盖。持久化 hook
在最终写路由前会再次检查 ownership marker。模块不接管 ECN、forwarding 或 IPv6 RA。
`verify`、`--probe`、`--yes` 和 `--disable-ecn` 已退休并会被拒绝。

网络模块默认面向同时承载 TCP、UDP 与 Docker 流量的代理节点：连接队列使用
`somaxconn=65535`、`tcp_max_syn_backlog=16384`。基础内存模型兼容 tcpfit v0.5.6 的 mixed role：
TCP 与 core socket default 固定为 2 MiB，长流继续依赖 autotuning；core default 同时影响 TCP、
UDP 和其他未显式设置缓冲区的 socket。`tcp_mem` 的 low/pressure/max 比例值按有效 RAM
（物理 RAM 与当前轻量 cgroup 根限制的较小值）的 1/16、1/8、1/4 推导；低内存 floor 固定为
16/32/64 MiB，最终写入 sysctl 时转换为当前内核 page 数，不假设 page size 固定为 4 KiB。

动态 socket 最大值仍按 `2 × BDP + 2 MiB` 计算，并受有效 RAM / 32 限制；RAM cap 最低
8 MiB、最高 256 MiB，动态最大值另保留 4 MiB 绝对下限。下游继续保留严格应用与验证事务、
initial/previous 双备份，以及 cgroup 根限制增强。模块启用 TCP receive autotuning、window
scaling、SACK、DSACK、时间戳和 syncookies，但保留内核或发行版管理的 `netdev_budget` 与
`netdev_budget_usecs`。`status` 聚焦当前测量记录、BBR/fq、受管缓冲区和 initcwnd 状态，不再
提供通用系统健康面板。

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

[`tools/cloudflare_tunnel.sh`](tools/cloudflare_tunnel.sh) 是 Cloudflare 官方 APT 安装流程的薄包装器，
只支持 Debian/Ubuntu 与 systemd。它使用官方 stable 软件源和 `cloudflared service install`，
不再下载裸二进制。安装完成后会询问是否启用受管的 APT systemd timer，默认不启用；也可稍后
使用独立命令启用。

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/cloudflare_tunnel.sh) install
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/cloudflare_tunnel.sh) upgrade
bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/cloudflare_tunnel.sh) status
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/cloudflare_tunnel.sh) enable-auto-update
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/cloudflare_tunnel.sh) disable-auto-update
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/cloudflare_tunnel.sh) migrate-legacy
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/cloudflare_tunnel.sh) uninstall
```

安装时 Token 使用隐藏输入，不会写入日志。APT 包会随普通 `apt upgrade` 或 `apt full-upgrade`
更新，但这些命令本身不会自动运行。`enable-auto-update` 会创建每日 systemd timer：先执行
`apt-get update`，比较已安装版本与候选版本，只在存在新版时升级 `cloudflared`；服务原本运行时
才会重启。timer 使用随机延迟、APT 锁等待和独立 flock，日志进入 journal。

启用自动更新意味着升级时单实例 Tunnel 会短暂中断。如果已经使用本仓库
`auto-update-setup.sh` 每周执行完整系统升级，通常无需重复启用此 timer；只有需要更频繁检测
cloudflared 时再启用。`upgrade` 可用于立即手动检查、升级并重启服务。

旧版脚本用户无需先卸载，可直接重新运行 `install`。确认旧二进制、unit 路径和版本均匹配旧版
受管安装后，脚本会全自动安装 APT 包，把 `cloudflared.service` 从
`/usr/local/bin/cloudflared` 事务式迁移到 `/usr/bin/cloudflared`，原样保留 Token/config 参数，
验证服务后再备份并移除旧二进制，无需重新输入 Token。任一验证失败都会恢复旧 unit 和运行状态；
归属证据不足则保留文件并停止，不盲删。若上一次迁移已完成 APT 安装和 unit 切换，只留下
`/usr/local/bin/cloudflared -> /usr/bin/cloudflared` 兼容链接，重新运行也会自动识别、备份并收尾。
`migrate-legacy` 可单独执行相同迁移流程。

脚本使用 `service install --no-update-service`，并识别、备份和清理旧版裸二进制更新单元，避免
APT 包与 `cloudflared update` 混用。若旧环境已有每日自动更新 timer，迁移时会自动换成新的
APT timer；旧环境未启用自动更新时仍保持关闭并询问是否启用。`uninstall` 删除服务、APT 包及
本脚本管理的软件源，但保留 Tunnel 配置和凭据。彻底清理须显式运行 `purge`，并在交互终端
输入 `PURGE` 二次确认。

### 出口流量整形 tcshape

基于 tcpfit `v0.5.6` 选择性移植限速器拐点 Sweep 与 `HTB + fq` Shape。它不会修改基础
sysctl，适用于存在出口 policer 的特定 VPS，不是通用必选优化。

首次运行：

```bash
curl -fsSLo /tmp/tcshape.sh https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/traffic-shape.sh && sudo bash /tmp/tcshape.sh
```

该写法先落盘再执行，兼容 Termius，也避免部分 Bash 进程替换场景中的 `/dev/fd/*` 无法二次读取。
新版仍会识别 `bash <(curl ...)`：若启动源不可复制，会从官方仓库重新下载并校验后安装；检测到
旧版遗留的零字节 `/usr/local/sbin/tcshape` 时会自动安全替换，非空且无受管标记的文件仍拒绝覆盖。

随后可使用短命令：

```bash
sudo tcshape s        # 自动选公共节点并扫描
sudo tcshape a        # 应用 24 小时内的最近推荐值
sudo tcshape on 480   # 手动限制为 480 Mbit
sudo tcshape off      # 关闭并恢复原 qdisc
sudo tcshape st       # 只读查看状态，不自安装或安装依赖
sudo tcshape u        # 从 LucaLin233/Linux main 检查更新
sudo tcshape apply --force  # 明确强制使用超过 24 小时的旧推荐值
```

tcshape 明确支持 Debian 12+ 与 Ubuntu 22.04+，要求 root、systemd、APT 及内核允许管理
qdisc。Ubuntu 软件源缺少 `iperf3` 时会提示先启用 `universe`，不会继续半安装。

Sweep 可能消耗大量上传流量，并会临时替换默认出口接口的根 qdisc。单方向上限约 45 GB，
双向合计上限约 90 GB。未检测到限速器或未找到拐点时，不建议且不能自动应用整形。
`tcshape a` 默认只接受 24 小时内的成功结果；相同推荐值已完整启用时直接返回，不重建 qdisc。
超过 24 小时的结果应重新扫描，仅在明确确认线路未变化时使用 `tcshape apply --force`。
自动扫描上限默认 10 Gbit，可用 `tcshape scan --cap N` 明确调整；可用
`--loss-threshold PCT` 覆盖默认 `0.1%` 重传率阈值。跨出口接口重新设置时会验证新整形后清理
旧接口 HTB 并迁移恢复基线，失败则回滚；带自定义参数的 `fq`/`fq_codel` 会被拒绝接管。
不限速单流低于自动选点或 `--nominal` 参考带宽的 70% 时，会按 tcpfit `v0.5.6` 在同一节点
补测两次，并按接收带宽选取最高的完整样本。重传率优先使用 iperf3 实际字节数与 MSS 计算。

`tcshape u`/`tcshape update` 会读取 `LucaLin233/Linux` 的 `main` 最新提交，按固定 Commit 下载并
校验受管标记、版本号和 Bash 语法，再原子替换短命令。上一版本保存在
`/usr/local/sbin/tcshape.previous`；配置、Sweep 结果和当前 qdisc 不会被修改。已安装 `1.0.3`
或更早版本的机器需要先按上面的“首次运行”命令升级一次，之后才能使用更新短命令。

详细参数、安全边界和恢复说明见 [`docs/traffic-shape.md`](docs/traffic-shape.md)。

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

默认生成当前目录的 `config.conf`，采用排他创建且权限为 `600`；已有文件、目录或符号链接均不会被覆盖。
`tools/push.sh` 已带可执行位，可直接使用上述 `./tools/push.sh` 命令。配置作为受信任 Bash 文件从已验证的
文件描述符加载，只接受当前运行用户和当前 GID 所有、权限严格为 `0400` 或 `0600` 的普通文件。
旧配置若为 `0644`、`0640` 等权限，运行前必须执行 `chmod 600 config.conf`。

`--test-auth` 会连接全部配置服务器，并仅执行无副作用的 SSH `true`；不会运行 rsync，也不会写入或删除
远端文件。认证和传输都在独立 session/process group 中运行，并使用 `TOTAL_TIMEOUT` 加短固定
TERM→KILL 宽限，HUP/INT/TERM 会清理 timeout、sshpass、ssh/rsync 及其后代。密钥模式通过
`-F none`、`IdentitiesOnly=yes`、`IdentityAgent=none` 和禁用 ControlMaster 等参数，只允许使用
runtime 内的私钥副本；密码模式禁用 publickey 并限制为一次密码提示。私钥文件必须为当前用户和 GID
所有、权限 `0400` 或 `0600`；密码文件必须为当前用户和 GID 所有且严格为 `0600`。临时密钥和
`SSHPASS` 会在正常退出、失败以及信号退出后清理。runtime 在创建首个目录前安装清理 traps，并拒绝
非 sticky 可写、owner/GID 不可信或包含符号链接组件的 `TMPDIR` 路径。

默认持久化 `known_hosts`。脚本会验证从根目录到文件父目录的完整目录链；普通目录不得由组或其他用户
写入，标准 root:root sticky `/tmp` 仍受支持，任意符号链接组件和非 sticky 可写祖先均会被拒绝。
传给 OpenSSH 的路径只允许字母、数字、点、下划线、斜杠和连字符，避免 `%h`、`${VAR}`、空白、
引号或反斜杠被再次解释。文件必须为当前用户和 GID 所有、owner 可读写且禁止组或其他用户写入，
安全的 `0600`/`0644` 均可。将其指向 `/dev/null` 仍须显式设置
`ALLOW_INSECURE_HOST_KEY_STORAGE="true"`，并会输出 MITM 警告。

示例配置默认 `DELETE_EXTRA="false"`，不会删除目标端多余文件。启用删除时，交互执行必须输入
`DELETE`；非交互执行还须显式设置 `ALLOW_DELETE_EXTRA="true"`。rsync 使用参数数组、
`--protect-args` 和 `--` 边界处理包含空格或 shell 元字符的路径。仓库测试全部使用 fake SSH/rsync，
不会连接真实服务器或执行真实远端写入。

### 独立动态 MOTD

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/setup-motd.sh) install
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/setup-motd.sh) status
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/setup-motd.sh) restore
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/setup-motd.sh) restore initial
```

用于只部署动态登录欢迎信息，与 `modules/system-customize.sh` 使用相同 MOTD 模板和
`previous`/`initial` 两级备份状态。已经运行系统定制模块时通常无需重复安装。静态欢迎文件会
备份后替换为空的普通文件，避免 PAM 重复显示；动态脚本备份保存在
`/var/lib/linux-setup/motd-backups`。状态面板直接显示 load average，不再为计算即时 CPU
百分比而固定延迟每次登录。

### XanMod 内核

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/xanmod-install.sh)
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/xanmod-install.sh) --yes
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/xanmod-install.sh) install --yes
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/xanmod-install.sh) status
sudo bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/xanmod-install.sh) help
```

脚本先执行只读规划，再检测 x86-64 psABI 并选择适合的 XanMod 包。独立工具保留动态 codename
探测；系统定制模块仍使用其原有发行版策略。不支持、非 amd64、x86-64-v1，或目标包和正式仓库文件
已经安全有效时，不要求 `--yes`。只有确需修改时才使用 `[y/N]`；无 TTY 必须显式传入 `--yes`。

生产环境中的正式 keyring、传统 list、Deb822 source 必须是 `root:root`、`0644` 的普通文件；测试模式
要求当前测试 UID/GID 和同样的 `0644`。内容正确但类型、owner 或 mode 不安全仍会判定无效，只能在
授权事务内通过随机 stage 重新生成。候选源和正式路径分别使用隔离 APT lists 验证，正式文件通过
同目录原子替换提交，失败则从三文件运行时快照全量回滚。

事务期间会处理 `HUP`、`INT`、`TERM`，分别以 129、130、143 退出并恢复正式配置；进入包安装阶段后
还会提示 APT 可能部分安装，但不会自动卸载任何内核包。`SIGKILL` 无法被 Shell 捕获，因此不能保证
自动回滚；执行内核操作前仍须保留控制台和可启动的旧内核。删除临时 stage、snapshot 或 APT lists
失败会返回非零并报告具体残留路径。

内核安装完成后通常需要重启才能生效；Debian/Ubuntu 原内核和已安装的其他 XanMod 分支均会保留。
APT 安装失败时请检查 `dpkg --audit` 和 APT 状态。

## 配置文件

- [`p10k-config.zsh`](p10k-config.zsh)：供 Zsh 模块使用的 Powerlevel10k 配置；
- `config.conf`：`push.sh` 生成的本地配置，可能包含敏感信息，不应提交；
- [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)：第三方代码来源和许可证。

## 功能重叠与选择

| 需求 | 推荐脚本 | 避免同时使用 |
| --- | --- | --- |
| 新 Debian/Ubuntu VPS 网络基础调优 | `modules/network-optimize.sh` | 其他会覆盖 sysctl 或根 qdisc 的调优脚本 |
| 特定出口 policer 检测与整形 | `tools/traffic-shape.sh` | tcpfit Shape、CAKE、TBF、其他 HTB |
| 一键系统定制 | `system-customize.sh` | 重复运行 `setup-motd.sh` |
| 仅安装 XanMod | `xanmod-install.sh` | 同时让多个脚本反复管理内核源 |

`network-optimize.sh` 与 `traffic-shape.sh` 职责不同，可以配合：前者管理 BBR、缓冲区、默认
`fq` 和按内核能力启用的 TCP 参数；后者在确实检测到 policer 后才使用 HTB 控制聚合出口速率，
并保留 fq 叶子 pacing。

## 高风险提醒

- **SSH**：修改端口或认证前，先放行云安全组/防火墙，并保持当前会话直到新连接验证成功；
- **自动更新**：系统或内核更新后可能自动重启；
- **系统优化**：首次写入 journald 限额时会重启 `systemd-journald`，并设置 Kernel Panic 30 秒后重启；
- **网络测速**：`network-optimize` 和 tcshape 都可能产生大量流量；
- **qdisc**：不要叠加多个整形工具；tcshape 遇到高级或未知 qdisc 会拒绝覆盖；
- **内核**：安装新内核前确认磁盘空间、架构和可用的旧内核；
- **rsync**：默认不删除远端文件；显式启用 `DELETE_EXTRA=true` 后会要求额外确认；
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
