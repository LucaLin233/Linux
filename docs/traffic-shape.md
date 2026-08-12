# tcshape：出口限速器扫描与流量整形

`tools/traffic-shape.sh` 以 [Kylin010/tcpfit](https://github.com/Kylin010/tcpfit)
`v0.5.4`（提交 `65885816bb77be38d041218f1bf62fe4ebe5c300`）为当前移植基线，选择性移植
Sweep 与 Shape 核心逻辑，用于检测 VPS 出口 policer 的限速拐点，并在用户确认后应用
`HTB + fq` 出口整形。tcshape 是独立、安全边界更严格的工具，不追求完整复制 tcpfit 的命令、
交互流程或 TCP/sysctl 调优功能。

基础 BBR、TCP 缓冲区与 sysctl 调优仍由 `modules/network-optimize.sh` 管理；tcshape 不修改
任何 sysctl。

## 系统要求

明确支持：

- Debian 12 或更高版本；
- Ubuntu 22.04 或更高版本。

脚本通过 `/etc/os-release` 校验发行版和版本，并要求 root、systemd、APT 以及可管理 qdisc 的
内核权限。OpenVZ、LXC、Docker 等环境即使发行版符合要求，也必须具备 `CAP_NET_ADMIN`。
Ubuntu 找不到 `iperf3` 时会停止并提示启用 `universe`：

```bash
sudo apt-get install -y software-properties-common
sudo add-apt-repository universe
sudo apt-get update
```

## 适用场景

适合不限速发送时出现明显重传，而略低于端口上限发送时丢包明显下降的 VPS。若 Sweep 未检测到
限速器或未定位到拐点，工具会明确建议不要整形，并拒绝应用推荐值。

不适合：

- 已使用 CAKE、TBF、NETEM、TAPRIO 或第三方 HTB；
- 接口存在自定义 class/filter；
- 无法接受 Sweep 流量消耗或测试期间的短暂出口波动；
- 需要入向整形；本工具只管理默认出口接口的 egress。

## 安装与短命令

首次运行会静默安装缺失依赖，并把自身安装为 `/usr/local/sbin/tcshape`。Termius 等终端推荐
先下载到普通文件再执行：

```bash
curl -fsSLo /tmp/tcshape.sh https://raw.githubusercontent.com/LucaLin233/Linux/main/tools/traffic-shape.sh && sudo bash /tmp/tcshape.sh
```

直接运行仓库文件也可以：

```bash
sudo ./tools/traffic-shape.sh
```

脚本不会直接复制不可再次读取或显示为零字节的 `/dev/fd/*`；这类启动源会触发官方仓库重新下载、
受管标记、版本和 Bash 语法校验。历史版本留下的零字节 `/usr/local/sbin/tcshape` 会自动替换；
非空、符号链接或没有 `tcshape-managed` 标记的未知文件仍拒绝覆盖。

常用命令：

```bash
sudo tcshape s        # 自动选节点并扫描
sudo tcshape a        # 应用最近推荐值
sudo tcshape on 480   # 手动设置 480 Mbit
sudo tcshape off      # 关闭并恢复原 qdisc
sudo tcshape st       # 查看状态
```

完整命令：

```bash
sudo tcshape scan [HOST] [--port N] [--nominal N] [--from N --to N]
                  [--step N] [--dur N] [--margin N] [--cap N]
                  [--loss-threshold PCT] [--yes] [-4|-6]
sudo tcshape apply [--force]
sudo tcshape set RATE
sudo tcshape status
sudo tcshape off
```

默认 IPv4；使用 `-6` 才启用 IPv6。省略 `HOST` 时，工具参考 tcpfit 的节点池，根据 RTT、
端口可达性和 iperf3 实际结果自动选择公共服务器，并轮换 `5201–5210` 和 `5200`。
自动扫描上限默认 10,000 Mbit；不限速送达量高于该值时记录 `ABOVE_CAP` 并停止。确需扫描
更高带宽可显式使用 `--cap 100000`。默认重传率阈值为 `0.1%`，特殊线路可通过
`--loss-threshold` 在 `0.0001%–10%` 范围内覆盖。

## 更新短命令

```bash
sudo tcshape u
sudo tcshape update
sudo tcshape update --yes   # 非交互确认
```

更新流程：

1. 从 GitHub API 获取 `LucaLin233/Linux` 的 `main` 最新 Commit；
2. 按该固定 Commit 下载 `tools/traffic-shape.sh`，避免分支在下载期间变化；
3. 校验 `tcshape-managed` 标记、更新源、版本号以及 `bash -n`；
4. 备份当前程序到 `/usr/local/sbin/tcshape.previous`；
5. 使用同目录临时文件和原子 `mv` 替换 `/usr/local/sbin/tcshape`。

更新只替换短命令，不修改 `/etc/tcshape.conf`、Sweep 结果、systemd 服务文件或当前 qdisc。
菜单内更新完成后会直接用新版本重新进入菜单；命令行更新则从下一次执行开始使用新版本。
发布脚本改动时必须同步递增脚本顶部的 `VERSION`，相同版本号不会重复覆盖。

需要回退上一版本时：

```bash
sudo install -m 0755 /usr/local/sbin/tcshape.previous /usr/local/sbin/tcshape
sudo tcshape --version
```

## Sweep 行为

1. 检查当前 qdisc 与其他整形服务冲突；
2. 记录网卡流量计数和原根 qdisc；
3. 自动选择附近且可用的公共 iperf3 节点；
4. 不限速单流同时读取发送端重传与接收端实际吞吐，判断是否存在 policer；
5. 根据接收端吞吐推导扫描区间；小带宽和窄区间会自动使用更细步长；
6. 在 `HTB + fq` 下进行粗扫、异常复测和细扫；
7. 恢复原 qdisc；
8. 仅保存结果，不自动应用整形。

结果可能是：

- `KNEE_FOUND`：找到拐点，可以在确认后执行 `tcshape a`；
- `NO_POLICER`：未检测到限速器，不建议整形；
- `NO_KNEE`：扫描范围内没有拐点，不建议整形；
- `PEER_UNSUITABLE`：对端过慢或路径不干净；
- `BUDGET_EXCEEDED`：达到流量上限后停止；
- `INCONCLUSIVE` / `FAILED`：结果不足，不允许自动应用。

结果保存于：

```text
/var/lib/tcshape/sweep.result
```

## 流量限制

与 `modules/network-optimize.sh` 保持一致：

```text
单方向：45,000,000,000 字节
双向合计：90,000,000,000 字节
```

工具在每轮测试前及 iperf3 运行过程中检查网卡计数。达到任一限制时立即停止本工具启动的
iperf3，并恢复 qdisc。流量上限与扫描速率不是同一概念：没有丢包时会直接判定无 policer，
不会为了耗尽 45 GB 而继续扫描；存在明显丢包时才进入拐点扫描。高速线路会根据自动选点时
测得的速率缩短单档时长，并在 2.5 Gbit 以上增大粗扫步长，尽量在 45 GB 内完成粗扫、细扫
和异常复测。显式传入 `--dur` 时则尊重用户指定值。

## Shape 行为

持久整形结构：

```text
HTB root：控制所有连接的总出口速率
└── HTB class
    └── fq：保留逐流 pacing
```

只有执行 `tcshape on RATE` 或 `tcshape a` 时才创建：

```text
/usr/local/sbin/tcshape
/etc/tcshape.conf
/etc/systemd/system/tcshape.service
/var/lib/tcshape/qdisc-baseline
```

`tcshape off` 仅移除本工具创建的 HTB，恢复当前受管接口首次启用前记录的简单 qdisc；不会删除或修改
`/etc/sysctl.d/99-network-optimize.conf`。重新设置时若出口接口发生变化，工具会先记录新接口基线，
验证新整形和持久服务后移除旧接口 HTB，再把新接口基线提升为正式基线；任一步失败都会尝试回滚。
`tcshape apply` 会使用 Sweep 结果中记录的接口，避免
IPv4 与 IPv6 使用不同出口时把推荐值应用到另一张网卡。

`tcshape a`/`tcshape apply` 默认只应用 24 小时内的 `KNEE_FOUND` 结果，并显示测试时间、结果
年龄和推荐速率。超过 24 小时或缺少有效时间的结果会被拒绝，应重新执行 Sweep；确认线路、
套餐和出口接口均未变化时，才使用：

```bash
sudo tcshape apply --force
```

如果相同推荐速率已经由 tcshape 完整启用，脚本直接返回成功，不重建 qdisc，因此不会因为忘记
是否执行过 `tcshape a` 而产生重复限速或额外网络抖动。`--force` 只绕过时间检查，不会绕过
Sweep 状态、推荐值、接口和 qdisc 所有权检查。

## qdisc 安全边界

允许自动接管并按该 qdisc 类型的默认参数恢复：

```text
fq、fq_codel、pfifo_fast、mq、noqueue
```

发现以下配置时拒绝覆盖：

```text
CAKE、TBF、NETEM、TAPRIO、非本工具 HTB、根队列或 mq 子队列的自定义 class/filter
```

仅允许使用内核默认参数的 `fq`/`fq_codel`；检测到非默认 `limit`、`flow_limit`、`quantum`、
`target`、`interval` 等参数时直接拒绝接管，因为无法保证逐项原样恢复。JSON 快照只用于人工核查，
自动恢复仅重建已验证为默认参数的 qdisc 类型。`mq` 自动生成的 `class mq`、标准
fq/fq_codel 子队列，以及独立的 clsact/ingress filter 不视为冲突：替换根 qdisc 时
clsact/ingress 会继续保留，关闭后由内核恢复 mq 拓扑。已经由 tcshape
管理的 `HTB + fq` 也允许再次 Sweep；测试结束后会重新应用原固定速率。检测到
`tcpfit-qdisc.service` 时也会拒绝运行。Sweep 遇到退出、错误、`Ctrl-C`、`TERM` 或流量超限
时都会执行恢复流程。

## 验证与排查

```bash
sudo tcshape st
systemctl status tcshape.service
tc qdisc show dev "$(ip route show default | awk '{print $5; exit}')"
tc class show dev "$(ip route show default | awk '{print $5; exit}')"
cat /var/lib/tcshape/sweep.result
```

如果工具拒绝接管，请先检查现有 qdisc、class、filter 和其他流量管理服务，不要手工删除未知
规则。第三方代码来源和许可证见 [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md)。
