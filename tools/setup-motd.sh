#!/bin/bash
# Debian MOTD 一键定制脚本 — 彩色版 (v4: 负载颜色分级)
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
# 欢迎横幅 + 系统面板（彩色版 + 负载颜色分级）

hn=$(hostname)
kernel=$(uname -r)

uptime_str=$(uptime -p 2>/dev/null | sed 's/^up //')
[ -z "$uptime_str" ] && uptime_str=$(uptime | sed -E 's/.*up\s+//; s/,\s+[0-9]+ user.*//')

# ---- ANSI ----
ESC=$'\033'
RESET="${ESC}[0m"
BLUE_BG="${ESC}[44;37m"
ITALIC_DIM="${ESC}[2;3;37m"
LABEL="${ESC}[1;36m"
VALUE="${ESC}[37m"
GREEN="${ESC}[32m"
ORANGE="${ESC}[33m"
RED="${ESC}[31m"

# ---- 颜色选择函数 ----
# 用 bash 整数比较，避免 awk -v 传 ANSI 码时的转义问题
# $1: 浮点百分比  $2: 类型 cpu|mem|disk
pick_color() {
    local lo hi pct_int
    case "${2:-}" in
        disk) lo=70; hi=90 ;;
        *)    lo=50; hi=80 ;;
    esac
    pct_int=$(awk -v p="$1" 'BEGIN { printf "%d", int(p + 0.5) }')
    if   [ "$pct_int" -ge "$hi" ]; then printf '%s' "$RED"
    elif [ "$pct_int" -ge "$lo" ]; then printf '%s' "$ORANGE"
    else printf '%s' "$GREEN"
    fi
}

# ---- CPU: /proc/stat 两次采样 ----
read -r _ u1 n1 s1 i1 _ <<< "$(grep '^cpu ' /proc/stat)"
t1=$((u1 + n1 + s1 + i1)); d1=$((u1 + n1 + s1))
sleep 0.5
read -r _ u2 n2 s2 i2 _ <<< "$(grep '^cpu ' /proc/stat)"
t2=$((u2 + n2 + s2 + i2)); d2=$((u2 + n2 + s2))
td=$((t2 - t1)); dd=$((d2 - d1))
if [ "$td" -gt 0 ]; then
    cpu_pct=$(awk -v u="$dd" -v t="$td" 'BEGIN { printf "%.1f", u/t*100 }')
    cpu_color=$(pick_color "$cpu_pct" cpu)
else
    cpu_pct="N/A"; cpu_color="$VALUE"
fi

load=$(awk '{printf "%.2f %.2f %.2f", $1, $2, $3}' /proc/loadavg)

# ---- 内存: /proc/meminfo，用 | 分隔避免空格歧义 ----
mem_raw=$(awk '
    /^MemTotal:/     { t=$2 }
    /^MemAvailable:/ { a=$2 }
    END { u=t-a; p=(t>0)?u/t*100:0
          printf "%.1f|%.1f|%.1f", u/1048576, t/1048576, p }
' /proc/meminfo)
mem_used="${mem_raw%%|*}G"
mem_rest="${mem_raw#*|}"; mem_total="${mem_rest%%|*}G"; mem_pct="${mem_raw##*|}"
mem_color=$(pick_color "$mem_pct" mem)

# ---- 磁盘 ----
disk_pct=$(df / | awk 'NR==2 { gsub(/%/,""); print $5 }')
disk_sizes=$(df -h / | awk 'NR==2 { printf "%s / %s", $3, $2 }')
disk_color=$(pick_color "$disk_pct" disk)

# ---- 输出 ----
# 关键: ) 前加 ${VALUE} 显式回到白色，防止继承颜色状态导致括号变色
printf "\n${BLUE_BG} 已连接 %s 服务器 ${RESET}\n" "$hn"
printf "${ITALIC_DIM} 今天想要做些什么？${RESET}\n"
echo ""
printf "  ${LABEL}内核${RESET}      ${VALUE}%s${RESET}\n"                                                     "$kernel"
printf "  ${LABEL}运行时间${RESET}  ${VALUE}%s${RESET}\n"                                                     "$uptime_str"
printf "  ${LABEL}CPU负载${RESET}   ${VALUE}%s  (${cpu_color}%s%%${VALUE})${RESET}\n"                        "$load"     "$cpu_pct"
printf "  ${LABEL}内存${RESET}      ${VALUE}%s / %s  (${mem_color}%s%%${VALUE})${RESET}\n"                   "$mem_used" "$mem_total" "$mem_pct"
printf "  ${LABEL}磁盘${RESET}      ${VALUE}%s  (${disk_color}%s%%${VALUE})${RESET}\n"                       "$disk_sizes" "$disk_pct"
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
