#!/bin/bash
# Debian MOTD 一键定制脚本 — 彩色版 (locale 兼容改进)
set -e

echo ">>> 清空静态文件..."
echo "" | sudo tee /etc/motd /etc/issue /etc/issue.net > /dev/null

echo ">>> 禁用原生脚本..."
for f in /etc/update-motd.d/10-uname /etc/update-motd.d/50-motd-news; do
    [ -x "$f" ] && sudo chmod -x "$f" && echo "    已禁用 $(basename "$f")"
done

echo ">>> 部署欢迎脚本..."
sudo tee /etc/update-motd.d/00-custom-welcome > /dev/null << 'SCRIPT'
#!/bin/bash
# 欢迎横幅 + 系统面板（彩色版，不依赖 locale）

hn=$(hostname)
kernel=$(uname -r)

# uptime -p 不可用（老 procps）时回退原始格式
uptime_str=$(uptime -p 2>/dev/null | sed 's/^up //')
[ -z "$uptime_str" ] && uptime_str=$(uptime | sed -E 's/.*up\s+//; s/,\s+[0-9]+ user.*//')

# CPU: 两次 /proc/stat 采样 → 消除 top/grep/locale 依赖
read -r _ u1 n1 s1 i1 _ <<< "$(grep '^cpu ' /proc/stat)"
t1=$((u1 + n1 + s1 + i1))
d1=$((u1 + n1 + s1))
sleep 0.5
read -r _ u2 n2 s2 i2 _ <<< "$(grep '^cpu ' /proc/stat)"
t2=$((u2 + n2 + s2 + i2))
d2=$((u2 + n2 + s2))
td=$((t2 - t1))
dd=$((d2 - d1))
[ "$td" -gt 0 ] \
    && cpu_percent=$(awk -v u="$dd" -v t="$td" 'BEGIN {printf "%.1f%%", u/t*100}') \
    || cpu_percent="N/A"

load=$(awk '{printf "%.2f %.2f %.2f", $1, $2, $3}' /proc/loadavg)

# free -h 不可用时回退 free -m
mem=$(free -h 2>/dev/null | awk '/^Mem:/ {p=$3/$2*100; printf "%s / %s  (%d%%)", $3, $2, p}')
[ -z "$mem" ] && mem=$(free -m | awk '/^Mem:/ {p=$3/$2*100; printf "%dM / %dM  (%d%%)", $3, $2, p}')

disk=$(df -h / | awk 'NR==2 {printf "%s / %s  (%s)", $3, $2, $5}')

ESC=$'\033'
RESET="${ESC}[0m"

BLUE_BG="${ESC}[44;37m"      # 蓝底白字 — 主标题
ITALIC_DIM="${ESC}[2;3;37m"  # 暗+斜体+白 — 副标题
LABEL="${ESC}[1;36m"         # 粗体青 — 标签
VALUE="${ESC}[37m"           # 白色 — 数值

printf "\n${BLUE_BG} 已连接 %s 服务器 ${RESET}\n" "$hn"
printf "${ITALIC_DIM} 今天想要做些什么？${RESET}\n"
echo ""
printf "  ${LABEL}内核${RESET}      ${VALUE}%s${RESET}\n" "$kernel"
printf "  ${LABEL}运行时间${RESET}  ${VALUE}%s${RESET}\n" "$uptime_str"
printf "  ${LABEL}CPU负载${RESET}   ${VALUE}%s  (%s)${RESET}\n" "$load" "$cpu_percent"
printf "  ${LABEL}内存${RESET}      ${VALUE}%s${RESET}\n" "$mem"
printf "  ${LABEL}磁盘${RESET}      ${VALUE}%s${RESET}\n" "$disk"
SCRIPT

sudo chmod +x /etc/update-motd.d/00-custom-welcome
echo "    部署完成"

echo ">>> 重启 sshd..."
sudo systemctl restart sshd

echo ""
echo ">>> 预览："
echo "----------------------------------------"
run-parts /etc/update-motd.d/
echo "----------------------------------------"
echo ""
echo "✅ 完成。"
