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

## 开发与验证

分支修改 → 轻量检查 → PR → CI → 独立复核 → 确认合并。具体规则见 [AGENTS.md](AGENTS.md)。

生产宿主机（包括 Netcup）仅执行差异检查及改动脚本的 `bash -n`，不运行全量 ShellCheck 或完整测试集；
分析和测试交由 CI：PR 按完整差异及依赖映射选择套件，README/许可证修改无需业务测试；
公共设施或未知依赖改动回退全量，main 推送仍执行全量。两个必需 Job 始终运行，输出选择和跳过记录。
ShellCheck 与语法检查仍覆盖全部脚本；文档修改无需本地全套测试，但仍须通过必需 CI。
本机重测试必须使用原生资源限制及权限隔离；无法隔离或超限时停止，不自动提高额度或转宿主机执行。

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
| 3 | `zsh-setup.sh` | Zsh、Oh My Zsh、Powerlevel10k 和插件 | 备份后重写 root 的 `.zshrc`，可修改默认 Shell |
| 4 | `mise-setup.sh` | Mise、Python、Node.js 和依赖迁移 | 配置 Shell 集成及每周 Mise 自动更新 |
| 5 | `tools-setup.sh` | NextTrace、Speedtest、htop、jq、tree 等 | 可能添加 NextTrace 第三方 APT 源 |
| 6 | `docker-setup.sh` | Docker Engine、Compose、Buildx、日志轮转 | 添加 Docker 官方 APT 源并管理 Docker 服务 |
| 7 | `auto-update-setup.sh` | 定时完整升级系统和内核 | 更新后需要重启时会等待 30 秒自动重启 |
| 8 | `ssh-security.sh` | SSH 端口、Root 登录与认证策略 | 保留当前 `ListenAddress`，完整管理其余主配置；写入前显示 drop-in 冲突并再次确认 |

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

# 3. Zsh、Oh My Zsh、Powerlevel10k 和插件
sudo bash <(curl -fsSL "$RAW_BASE/zsh-setup.sh")

# 4. Mise、Python 和 Node.js；请先完成第 3 项
sudo bash <(curl -fsSL "$RAW_BASE/mise-setup.sh")

# 5. NextTrace、Speedtest、htop、jq、tree 等工具
sudo bash <(curl -fsSL "$RAW_BASE/tools-setup.sh")

# 6. Docker Engine、Compose 和 Buildx
sudo bash <(curl -fsSL "$RAW_BASE/docker-setup.sh")

# 7. 每周系统与内核更新；需要时会自动重启
sudo bash <(curl -fsSL "$RAW_BASE/auto-update-setup.sh")

# 8. SSH 安全配置；操作前先确认控制台和云防火墙可用
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

Linux 仓库不再内置 `network-optimize` 和 `traffic-shape` 网络调优脚本。

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
只支持 Debian/Ubuntu 与 systemd。它使用 Cloudflare 官方 key/source：
`deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflare-main.gpg any main`，
并以 `cloudflared service install` 配置服务，不再下载裸二进制。keyring 会严格校验单一主公钥
fingerprint `CC94B39C77AE7342A68B89628A682D308D4E5E73` 与 UID
`CloudFlare Software Packaging 2025 <help@cloudflare.com>`。key/source 同一事务提交；APT probe 或安装
失败、进程异常退出或收到 HUP/INT/TERM 时恢复旧世代并保留失败证据。安装完成后会询问是否启用
受管的 APT systemd timer，默认不启用；也可稍后使用独立命令启用。

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
APT timer；旧环境未启用自动更新时仍保持关闭并询问是否启用。`uninstall` 在同一事务锁内验证
`current` 清单与 key/source 摘要，备份并删除受管 source，保留 keyring、Tunnel 配置和凭据。
文件阶段失败会恢复可恢复配置；APT 包删除属于不可逆边界，失败时不会尝试自动重装。
卸载快照固定包含六个受管目标，完整捕获后才进入 ACTIVE。恢复失败保留原 manifest、payload
和 journal，不覆盖失败证据。成功卸载或完整恢复后，终态 journal 与快照在锁内归档，目录
权限为 `0500`、文件为 `0400`；不自动清理历史证据。只删除身份仍匹配的本事务临时文件。
`SIGKILL` 或收尾失败留下 `pending-uninstall-*`、快照/归档及可能的锁。后续 install、upgrade、
uninstall、disable-auto-update 拒绝继续；应先人工审查错误输出中的状态路径，不要仅删除锁后重试。
HUP/INT/TERM 分别返回 129/130/143；终态归档开始后的中断不会再次执行配置回滚。
彻底清理须显式运行 `purge`，并在交互终端输入 `PURGE` 二次确认。

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
`SSHPASS` 会在正常退出、失败以及信号退出后清理。runtime 在任何目录创建前先由父进程发布高熵
candidate、building 状态及 allocator 身份；HUP/INT/TERM 会先终止并回收 allocator，再删除经证明
属于本次运行的目录。`TMPDIR` 中非 sticky 可写、owner/GID 不可信或包含符号链接组件的路径会被拒绝。

每个 worker 会在可信 `0700` runtime 中原子发布 `0600` session 状态。主进程给 worker 留出完整
TERM→KILL 清理余量；worker 无响应或异常退出时，主进程会根据 PID/start time/PGID/SID 独立枚举并
清理同一 SID 的全部 PGID。清理失败会保留状态和 runtime，阻止重试或启动下一台服务器。

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

用于只部署动态登录欢迎信息，与 `modules/system-customize.sh` 使用相同模板、锁路径和组级
`previous`/`initial` snapshot 格式。六个目标会先完整快照，再通过同目录 stage 原子替换；任一
install/restore 提交失败或收到 HUP/INT/TERM 都会回滚整个文件组。状态目录为
`/var/lib/linux-setup/motd-backups`，互斥锁为 `/run/lock/linux-setup-motd.lock`。

相邻和旧状态目录中的 legacy 备份仅在六项目标完整、无冲突时原子导入，旧文件不会逐项移动。
`SIGKILL` 无法被 Shell 捕获，可能留下可信 pending journal；下一次操作会先验证并恢复或清理。
状态面板直接显示 load average，不再固定延迟每次登录。

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

## 功能重叠与选择

| 需求 | 推荐脚本 | 避免同时使用 |
| --- | --- | --- |
| 一键系统定制 | `system-customize.sh` | 重复运行 `setup-motd.sh` |
| 仅安装 XanMod | `xanmod-install.sh` | 同时让多个脚本反复管理内核源 |

## 高风险提醒

- **SSH**：修改端口或认证前，先放行云安全组/防火墙，并保持当前会话直到新连接验证成功；
- **自动更新**：系统或内核更新后可能自动重启；
- **系统优化**：首次写入 journald 限额时会重启 `systemd-journald`，并设置 Kernel Panic 30 秒后重启；
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
systemctl status ssh docker chrony cron
sshd -t
```

提交 Issue 时请提供系统版本、执行命令、退出码和已脱敏的完整日志，不要包含 Token、密码、
私钥、服务器清单或公网管理地址。

## 许可证与免责声明

本仓库采用 [MIT License](LICENSE)。

脚本按“原样”提供，不附带任何担保。发行版、内核、虚拟化、机房网络和软件源存在差异，使用者
应自行审查、备份、验证并承担操作后果。
