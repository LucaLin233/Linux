# tcshape：出口限速器扫描与流量整形

`tools/traffic-shape.sh` 从 [Kylin010/tcpfit](https://github.com/Kylin010/tcpfit)
移植 Sweep 与 Shape 核心逻辑，用于检测 VPS 出口 policer 的限速拐点，并在用户确认后应用
`HTB + fq` 出口整形。

基础 BBR、TCP 缓冲区与 sysctl 调优仍由 `modules/network-optimize.sh` 管理；tcshape 不修改
任何 sysctl。

## 适用场景

适合不限速发送时出现明显重传，而略低于端口上限发送时丢包明显下降的 VPS。若 Sweep 未检测到
限速器或未定位到拐点，工具会明确建议不要整形，并拒绝应用推荐值。

不适合：

- 已使用 CAKE、TBF、NETEM、TAPRIO 或第三方 HTB；
- 接口存在自定义 class/filter；
- 无法接受 Sweep 流量消耗或测试期间的短暂出口波动；
- 需要入向整形；本工具只管理默认出口接口的 egress。

## 安装与短命令

首次运行会静默安装缺失依赖，并把自身安装为 `/usr/local/sbin/tcshape`：

```bash
sudo ./tools/traffic-shape.sh
```

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
                  [--step N] [--dur N] [--margin N] [--yes] [-4|-6]
sudo tcshape apply
sudo tcshape set RATE
sudo tcshape status
sudo tcshape off
```

默认 IPv4；使用 `-6` 才启用 IPv6。省略 `HOST` 时，工具参考 tcpfit 的节点池，根据 RTT、
端口可达性和 iperf3 实际结果自动选择公共服务器，并轮换 `5201–5210` 和 `5200`。

## Sweep 行为

1. 检查当前 qdisc 与其他整形服务冲突；
2. 记录网卡流量计数和原根 qdisc；
3. 自动选择附近且可用的公共 iperf3 节点；
4. 不限速单流探测是否存在 policer；
5. 在 `HTB + fq` 下进行粗扫、异常复测和细扫；
6. 恢复原 qdisc；
7. 仅保存结果，不自动应用整形。

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

`tcshape off` 仅移除本工具创建的 HTB，恢复首次启用前记录的简单 qdisc；不会删除或修改
`/etc/sysctl.d/99-network-optimize.conf`。

## qdisc 安全边界

允许自动接管并恢复：

```text
fq、fq_codel、pfifo_fast、mq、noqueue
```

发现以下配置时拒绝覆盖：

```text
CAKE、TBF、NETEM、TAPRIO、非本工具 HTB、根队列或 mq 子队列的自定义 class/filter
```

`mq` 自动生成的 `class mq`、标准 fq/fq_codel 子队列，以及独立的 clsact/ingress filter 不视为
冲突：替换根 qdisc 时 clsact/ingress 会继续保留，关闭后由内核恢复 mq 拓扑。已经由 tcshape
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
