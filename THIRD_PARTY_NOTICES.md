# Third-Party Notices

## `tools/traffic-shape.sh`

`tools/traffic-shape.sh` 包含从
[Kylin010/tcpfit](https://github.com/Kylin010/tcpfit) 移植和修改的 Sweep、Shape、
公共 iperf3 节点选择及 qdisc 管理逻辑。

当前移植基线为 tcpfit `v0.5.6`：

```text
67c0bdfb35dd98e86982600298237b6ecc08ebe4
```

本项目只移植适合独立 `tcshape` 工具的 Sweep、Shape 和 qdisc 管理逻辑，不追求与 tcpfit
全部命令、交互流程及 TCP/sysctl 调优功能完全一致。

## `modules/network-optimize.sh`

`modules/network-optimize.sh` 移植或参考
[Kylin010/tcpfit](https://github.com/Kylin010/tcpfit) `v0.5.6`（提交
`67c0bdfb35dd98e86982600298237b6ecc08ebe4`）的以下 MIT 许可实现与策略：

- 公共 iperf3 节点及多端口策略
- 带宽探测思路
- BDP 与 2 MiB 余量
- 物理内存/cgroup 有效内存 cap
- initcwnd 100 Mbps 策略
- initcwnd ownership 与 owned-only 清理思路

下游主要差异：tcpfit 被拆为基础调优与 `traffic-shape` 两部分；
`network-optimize.sh` 仅做 IPv4 TCP 调优；自动 RTT 固定为 150 ms；备份、恢复和交互流程
使用本仓库实现。本条目描述移植与参考范围，不代表对 tcpfit 的完整等价实现。

上述上游代码采用 MIT License：

```text
MIT License

Copyright (c) 2026 Kylin010

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
