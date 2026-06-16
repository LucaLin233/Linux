#!/bin/bash
# Cloudflared Tunnel 二进制版本安装与卸载脚本
# 功能：根据用户参数安装或卸载 Cloudflared 二进制版本及其相关服务和配置。

set -e

# ─────────────────────────────────────────────
#  颜色 & 样式
# ─────────────────────────────────────────────
RESET="\033[0m"
BOLD="\033[1m"
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
WHITE="\033[1;37m"
DIM="\033[2m"

# ─────────────────────────────────────────────
#  日志函数
# ─────────────────────────────────────────────
info()    { echo -e "${BLUE}  ℹ ${WHITE}$*${RESET}"; }
success() { echo -e "${GREEN}  ✔ $*${RESET}"; }
warn()    { echo -e "${YELLOW}  ⚠ $*${RESET}" >&2; }
error()   { echo -e "${RED}  ✘ $*${RESET}" >&2; }
step()    { echo -e "${CYAN}${BOLD}▶ $*${RESET}"; }
dim()     { echo -e "${DIM}    $*${RESET}"; }

# 分隔线
hr() { echo -e "${DIM}  ──────────────────────────────────────────${RESET}"; }

# Banner
banner() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║       Cloudflared Tunnel 管理脚本        ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${RESET}"
}

# ─────────────────────────────────────────────
#  辅助函数
# ─────────────────────────────────────────────
command_exists() {
    command -v "$@" >/dev/null 2>&1
}

# 带进度提示的 curl 下载
download_with_progress() {
    local url="$1"
    local dest="$2"
    echo -e "${DIM}    源: $url${RESET}"
    if ! curl -L --progress-bar --fail "$url" -o "$dest"; then
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────
#  自动更新相关路径
# ─────────────────────────────────────────────
UPDATER_SCRIPT="/usr/local/bin/cloudflared-update"
UPDATER_SERVICE="/etc/systemd/system/cloudflared-updater.service"
UPDATER_TIMER="/etc/systemd/system/cloudflared-updater.timer"

# ─────────────────────────────────────────────
#  安装自动更新 (systemd timer)
# ─────────────────────────────────────────────
install_autoupdate() {
    step "配置自动更新 (每日 systemd timer)..."

    # 写入更新脚本
    cat > "$UPDATER_SCRIPT" << 'UPDATER_EOF'
#!/bin/bash
# cloudflared 自动更新脚本 (由安装脚本生成)

TARGET="/usr/local/bin/cloudflared"
ARCH=$(uname -m)

case $ARCH in
    x86_64)        URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
    aarch64|arm64) URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
    armv7l|armv6l) URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
    *) echo "不支持的架构: $ARCH" >&2; exit 1 ;;
esac

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 开始检查更新..."

if ! curl -L --silent --fail "$URL" -o "$TMP"; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 下载失败，跳过本次更新。" >&2
    exit 1
fi

chmod +x "$TMP"

# 比较版本
CURRENT=$("$TARGET" version 2>/dev/null | awk '{print $3}' || echo "unknown")
NEW=$("$TMP" version 2>/dev/null | awk '{print $3}' || echo "unknown")

if [ "$CURRENT" = "$NEW" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 当前已是最新版本 ($CURRENT)，无需更新。"
    exit 0
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 发现新版本: $CURRENT → $NEW，开始更新..."

# 先停服务再替换，避免 "Text file busy"
systemctl stop cloudflared.service 2>/dev/null || true
mv "$TMP" "$TARGET"
systemctl start cloudflared.service 2>/dev/null || true
TMP=""  # 防止 trap 删除已移动的文件

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 更新完成，当前版本: $($TARGET version 2>/dev/null | awk '{print $3}')"
UPDATER_EOF

    chmod +x "$UPDATER_SCRIPT"

    # 写入 systemd service
    cat > "$UPDATER_SERVICE" << SERVICE_EOF
[Unit]
Description=Cloudflared Auto Updater
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$UPDATER_SCRIPT
StandardOutput=journal
StandardError=journal
SERVICE_EOF

    # 写入 systemd timer（每天 03:00 执行，随机延迟 60 分钟）
    cat > "$UPDATER_TIMER" << TIMER_EOF
[Unit]
Description=Cloudflared Auto Updater Timer

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF

    systemctl daemon-reload
    systemctl enable --now cloudflared-updater.timer >/dev/null 2>&1
    success "自动更新已配置 (每日 03:00 运行)"
    dim "更新日志: journalctl -u cloudflared-updater.service"
}

# ─────────────────────────────────────────────
#  卸载自动更新
# ─────────────────────────────────────────────
remove_autoupdate() {
    local found=0
    for unit in cloudflared-updater.timer cloudflared-updater.service; do
        if systemctl list-unit-files --no-pager | grep -q "^$unit"; then
            systemctl stop    "$unit" >/dev/null 2>&1 || true
            systemctl disable "$unit" >/dev/null 2>&1 || true
            found=1
        fi
    done
    for f in "$UPDATER_SCRIPT" "$UPDATER_SERVICE" "$UPDATER_TIMER"; do
        [ -f "$f" ] && rm -f "$f" && found=1
    done
    [ $found -eq 1 ] && success "自动更新组件已移除" || dim "未检测到自动更新组件"
}

# ─────────────────────────────────────────────
#  安装函数
# ─────────────────────────────────────────────
install_cloudflared() {
    banner
    echo -e "  ${WHITE}${BOLD}模式: 安装${RESET}"
    hr

    # 1. 检测架构
    step "检测系统环境..."
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            ;;
        aarch64|arm64)
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
            ;;
        armv7l|armv6l)
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm"
            ;;
        *)
            error "不支持的架构: $ARCH"
            exit 1
            ;;
    esac
    success "架构: $ARCH"

    if ! command_exists curl; then
        error "'curl' 未找到，请先安装: apt install curl"
        exit 1
    fi
    success "依赖检查通过"

    TARGET_BIN_PATH="/usr/local/bin/cloudflared"
    SERVICE_FILE="/etc/systemd/system/cloudflared.service"

    # 2. 处理已有安装
    if [ -f "$TARGET_BIN_PATH" ]; then
        hr
        warn "检测到已有安装: $TARGET_BIN_PATH"
        read -rp "$(echo -e "  ${YELLOW}是否覆盖安装? (y/N): ${RESET}")" OVERWRITE_CONFIRM
        if [[ "$OVERWRITE_CONFIRM" =~ ^[Yy]$ ]]; then
            info "停止现有服务..."
            if systemctl is-active --quiet cloudflared.service 2>/dev/null; then
                if ! systemctl stop cloudflared.service; then
                    error "停止 cloudflared.service 失败，请手动停止后重试。"
                    exit 1
                fi
                success "现有服务已停止"
            else
                dim "服务未在运行，跳过"
            fi
        else
            info "已取消安装。"
            exit 0
        fi
    fi

    # 3. 下载二进制（先下载到临时路径，验证后再替换）
    hr
    step "下载 cloudflared 二进制..."
    TMP_BIN=$(mktemp)
    trap 'rm -f "$TMP_BIN"' EXIT

    if ! download_with_progress "$CLOUDFLARED_URL" "$TMP_BIN"; then
        error "下载失败，请检查网络连接。"
        exit 1
    fi

    chmod +x "$TMP_BIN"

    # 验证下载的二进制可正常执行
    if ! NEW_VER=$("$TMP_BIN" version 2>/dev/null | awk '{print $3}'); then
        error "下载的文件无法执行，可能已损坏。"
        exit 1
    fi
    success "下载成功，版本: ${NEW_VER}"

    # 4. 替换二进制
    step "安装二进制到 $TARGET_BIN_PATH..."
    mv "$TMP_BIN" "$TARGET_BIN_PATH"
    trap - EXIT  # 清除 trap，文件已移走
    success "二进制安装完成"

    # 5. 清理旧服务配置
    hr
    if [ -f "$SERVICE_FILE" ]; then
        step "检测到旧服务配置，清理中..."
        if ! "$TARGET_BIN_PATH" service uninstall 2>/dev/null; then
            warn "自带卸载命令失败，手动清理服务文件..."
            systemctl stop    cloudflared.service >/dev/null 2>&1 || true
            systemctl disable cloudflared.service >/dev/null 2>&1 || true
            rm -f "$SERVICE_FILE"
            systemctl daemon-reload
        fi
        success "旧服务配置已清理"
    else
        dim "未检测到旧服务配置"
    fi

    # 6. 输入 Token
    hr
    step "配置 Tunnel Token..."
    echo -e "  ${DIM}请前往 Cloudflare Zero Trust → Networks → Tunnels 获取令牌${RESET}"
    echo ""
    read -rp "$(echo -e "  ${CYAN}粘贴令牌: ${RESET}")" TOKEN

    if [ -z "$TOKEN" ]; then
        error "令牌不能为空。"
        exit 1
    fi
    success "令牌已接收"

    # 7. 安装服务
    hr
    step "安装 cloudflared systemd 服务..."
    if ! "$TARGET_BIN_PATH" service install "$TOKEN"; then
        error "服务安装失败，请手动运行: sudo cloudflared service install <token>"
        exit 1
    fi
    success "systemd 服务安装完成"

    # 8. 配置自动更新
    hr
    install_autoupdate

    # 9. 启动服务
    hr
    step "启动服务..."
    systemctl daemon-reload
    systemctl enable cloudflared >/dev/null 2>&1 || warn "enable 失败，服务可能不会开机自启"
    if systemctl start cloudflared; then
        success "服务启动成功"
    else
        warn "服务启动失败，请查看日志: journalctl -u cloudflared.service -n 50"
    fi

    # 10. 完成汇总
    hr
    echo ""
    echo -e "${GREEN}${BOLD}  ✔ 安装完成！${RESET}"
    echo ""
    echo -e "  ${WHITE}版本:${RESET}      $("$TARGET_BIN_PATH" version 2>/dev/null | head -1)"
    echo -e "  ${WHITE}二进制:${RESET}    $TARGET_BIN_PATH"
    echo -e "  ${WHITE}服务状态:${RESET}"
    echo ""
    systemctl status cloudflared --no-pager -l 2>/dev/null || true
    echo ""
    echo -e "  ${DIM}查看日志: journalctl -u cloudflared.service -f${RESET}"
    echo ""
}

# ─────────────────────────────────────────────
#  升级函数（仅更新二进制，不动 Token / 服务配置）
# ─────────────────────────────────────────────
upgrade_cloudflared() {
    banner
    echo -e "  ${WHITE}${BOLD}模式: 升级${RESET}"
    hr

    TARGET_BIN_PATH="/usr/local/bin/cloudflared"

    # 检查是否已安装
    if [ ! -f "$TARGET_BIN_PATH" ]; then
        error "未检测到已安装的 cloudflared，请先运行 install。"
        exit 1
    fi

    # 检查 curl
    if ! command_exists curl; then
        error "'curl' 未找到，请先安装: apt install curl"
        exit 1
    fi

    # 检测架构
    step "检测系统环境..."
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)        CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
        aarch64|arm64) CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
        armv7l|armv6l) CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
        *)
            error "不支持的架构: $ARCH"
            exit 1
            ;;
    esac

    CURRENT_VER=$("$TARGET_BIN_PATH" version 2>/dev/null | awk '{print $3}' || echo "unknown")
    success "当前版本: $CURRENT_VER"

    # 下载到临时路径
    hr
    step "下载最新版 cloudflared 二进制..."
    TMP_BIN=$(mktemp)
    trap 'rm -f "$TMP_BIN"' EXIT

    if ! download_with_progress "$CLOUDFLARED_URL" "$TMP_BIN"; then
        error "下载失败，请检查网络连接。"
        exit 1
    fi

    chmod +x "$TMP_BIN"

    # 验证并对比版本
    if ! NEW_VER=$("$TMP_BIN" version 2>/dev/null | awk '{print $3}'); then
        error "下载的文件无法执行，可能已损坏。"
        exit 1
    fi

    if [ "$CURRENT_VER" = "$NEW_VER" ]; then
        success "已是最新版本 ($CURRENT_VER)，无需升级。"
        exit 0
    fi

    info "发现新版本: $CURRENT_VER → $NEW_VER"

    # 停服务 → 替换二进制 → 启服务
    hr
    step "替换二进制..."
    if systemctl is-active --quiet cloudflared.service 2>/dev/null; then
        info "停止服务..."
        systemctl stop cloudflared.service
        success "服务已停止"
    fi

    mv "$TMP_BIN" "$TARGET_BIN_PATH"
    trap - EXIT
    success "二进制已替换"

    step "重启服务..."
    if systemctl start cloudflared.service 2>/dev/null; then
        success "服务已重启"
    else
        warn "服务重启失败，请查看日志: journalctl -u cloudflared.service -n 50"
    fi

    # 完成
    hr
    echo ""
    echo -e "${GREEN}${BOLD}  ✔ 升级完成！${RESET}"
    echo ""
    echo -e "  ${WHITE}版本:${RESET}  $CURRENT_VER  →  $NEW_VER"
    echo -e "  ${WHITE}二进制:${RESET} $TARGET_BIN_PATH"
    echo ""
    echo -e "  ${DIM}Token 和服务配置未做任何改动${RESET}"
    echo ""
}

# ─────────────────────────────────────────────
#  卸载函数
# ─────────────────────────────────────────────
uninstall_cloudflared() {
    banner
    echo -e "  ${WHITE}${BOLD}模式: 卸载${RESET}"
    hr

    warn "此操作将移除 cloudflared 二进制、systemd 服务、自动更新及所有配置文件。"
    warn "配置目录 (/etc/cloudflared, /var/lib/cloudflared 等) 将被删除，请提前备份。"
    echo ""
    read -rp "$(echo -e "  ${RED}确认彻底清除? (y/N): ${RESET}")" CONFIRM_UNINSTALL
    if [[ ! "$CONFIRM_UNINSTALL" =~ ^[Yy]$ ]]; then
        info "已取消。"
        exit 0
    fi
    echo ""

    TARGET_BIN_PATH="/usr/local/bin/cloudflared"

    # 1. 移除自动更新
    step "移除自动更新组件..."
    remove_autoupdate

    # 2. cloudflared 自带卸载
    hr
    step "调用 cloudflared service uninstall..."
    CLOUDFLARED_CMD=""
    if [ -x "$TARGET_BIN_PATH" ]; then
        CLOUDFLARED_CMD="$TARGET_BIN_PATH"
    elif command_exists cloudflared; then
        CLOUDFLARED_CMD="$(command -v cloudflared)"
        warn "主路径未找到，使用 PATH 中的: $CLOUDFLARED_CMD"
    fi

    if [ -n "$CLOUDFLARED_CMD" ]; then
        if "$CLOUDFLARED_CMD" service uninstall 2>/dev/null; then
            success "service uninstall 执行成功"
        else
            warn "service uninstall 失败，将手动清理"
        fi
    else
        dim "未找到 cloudflared 二进制，跳过"
    fi

    # 3. 停止并禁用 systemd 服务
    hr
    step "停止并禁用 systemd 服务..."
    for service in cloudflared.service cloudflared-update.service; do
        if systemctl list-unit-files --no-pager 2>/dev/null | grep -q "^$service"; then
            systemctl stop    "$service" >/dev/null 2>&1 || true
            systemctl disable "$service" >/dev/null 2>&1 || true
            success "已处理: $service"
        else
            dim "未找到: $service"
        fi
    done

    # 4. 删除服务文件
    step "删除服务文件..."
    for f in \
        "/etc/systemd/system/cloudflared.service" \
        "/etc/systemd/system/cloudflared-update.service" \
        "/etc/systemd/system/multi-user.target.wants/cloudflared.service" \
        "/etc/systemd/system/multi-user.target.wants/cloudflared-update.service"; do
        if [ -f "$f" ] || [ -L "$f" ]; then
            rm -f "$f" && success "已删除: $f" || warn "删除失败: $f"
        fi
    done

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed  >/dev/null 2>&1 || true

    # 5. 删除配置目录
    hr
    step "删除配置文件和证书目录..."
    for dir in "/etc/cloudflared" "/var/lib/cloudflared" "/root/.cloudflared" "$HOME/.cloudflared"; do
        if [ -d "$dir" ]; then
            rm -rf "$dir" && success "已删除: $dir" || warn "删除失败: $dir"
        fi
    done

    # 修复原版 -minddepth 拼写错误，改为 -mindepth
    while IFS= read -r -d '' user_home; do
        if [ -d "$user_home/.cloudflared" ]; then
            rm -rf "$user_home/.cloudflared" && success "已删除: $user_home/.cloudflared" || warn "删除失败: $user_home/.cloudflared"
        fi
    done < <(find /home -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)

    # 6. 删除二进制
    hr
    step "删除 cloudflared 二进制文件..."
    for bin in "/usr/local/bin/cloudflared" "/usr/bin/cloudflared" "/usr/sbin/cloudflared" "/bin/cloudflared"; do
        if [ -f "$bin" ] || [ -L "$bin" ]; then
            rm -f "$bin" && success "已删除: $bin" || warn "删除失败: $bin"
        fi
    done

    # 7. 最终验证
    hr
    step "验证清除结果..."
    if [ -x "/usr/local/bin/cloudflared" ] || command_exists cloudflared; then
        warn "cloudflared 二进制仍然存在:"
        command -v cloudflared 2>/dev/null || true
    else
        success "cloudflared 二进制已完全移除"
    fi

    if systemctl list-unit-files --no-pager 2>/dev/null | grep -q "cloudflared"; then
        warn "仍有残留的 systemd 单元:"
        systemctl list-unit-files --no-pager 2>/dev/null | grep cloudflared || true
    else
        success "所有 cloudflared 服务单元已移除"
    fi

    echo ""
    echo -e "${GREEN}${BOLD}  ✔ 卸载完成！${RESET}"
    echo ""
}

# ─────────────────────────────────────────────
#  用法
# ─────────────────────────────────────────────
usage() {
    banner
    echo -e "  ${WHITE}用法:${RESET} sudo $(basename "$0") [install|upgrade|uninstall]"
    echo ""
    echo -e "  ${CYAN}install${RESET}    下载并安装最新版 cloudflared，配置 systemd 服务及每日自动更新"
    echo -e "  ${CYAN}upgrade${RESET}    仅更新 cloudflared 二进制，不修改 Token 和服务配置"
    echo -e "  ${CYAN}uninstall${RESET}  彻底移除 cloudflared 二进制、服务、自动更新及所有配置文件"
    echo ""
    exit 1
}

# ─────────────────────────────────────────────
#  入口
# ─────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}  ✘ 请使用 sudo 运行此脚本。${RESET}" >&2
    exit 1
fi

case "${1:-}" in
    install)   install_cloudflared ;;
    upgrade)   upgrade_cloudflared ;;
    uninstall) uninstall_cloudflared ;;
    *)         usage ;;
esac
