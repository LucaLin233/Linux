# Third-Party Notices

## tcpfit

`tools/traffic-shape.sh` 包含从
[Kylin010/tcpfit](https://github.com/Kylin010/tcpfit) 移植和修改的 Sweep、Shape、
公共 iperf3 节点选择及 qdisc 管理逻辑。

当前移植基线为 tcpfit `v0.5.4`：

```text
65885816bb77be38d041218f1bf62fe4ebe5c300
```

本项目只移植适合独立 `tcshape` 工具的 Sweep、Shape 和 qdisc 管理逻辑，不追求与 tcpfit
全部命令、交互流程及 TCP/sysctl 调优功能完全一致。

原项目采用 MIT License：

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
