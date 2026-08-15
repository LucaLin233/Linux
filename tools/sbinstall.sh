#!/usr/bin/env bash
# Transactional sing-box installer for Debian-based systems.

set -euo pipefail

readonly INSTALL_DIR="${SBINSTALL_INSTALL_DIR:-/root/proxy}"
readonly SRC_DIR="${INSTALL_DIR}/src"
readonly BACKUP_DIR="${INSTALL_DIR}/backup"
readonly SERVICE_FILE="${SBINSTALL_SERVICE_FILE:-/etc/systemd/system/sing-box.service}"
readonly RELEASE_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"

STAGING_ROOT=""
STAGED_SRC=""
STAGED_SERVICE=""
ROLLBACK_DIR=""
TRANSACTION_ACTIVE=false
OLD_SRC_MOVED=false
NEW_SRC_ACTIVATED=false
SERVICE_WAS_ACTIVE=false
SERVICE_WAS_ENABLED=false
SERVICE_EXISTED=false

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
error() { printf '[ERROR] %s\n' "$*" >&2; }
error_exit() { error "$1"; exit 1; }

require_root() {
    (( EUID == 0 )) || error_exit "请使用 sudo 运行此脚本"
}

detect_os() {
    [[ -r /etc/os-release ]] || error_exit "无法检测操作系统类型"
    . /etc/os-release
    if [[ "${ID:-}" != debian && " ${ID_LIKE:-} " != *" debian "* ]]; then
        error_exit "仅支持 Debian 系列系统，当前系统: ${PRETTY_NAME:-unknown}"
    fi
    command -v apt-get >/dev/null || error_exit "未找到 apt-get"
    command -v systemctl >/dev/null || error_exit "未找到 systemctl"
    [[ -d /run/systemd/system ]] || error_exit "当前环境未运行 systemd"
}

install_dependencies() {
    local packages=(ca-certificates curl tar gzip jq coreutils)
    local missing_cert=() package
    for package in "${packages[@]}"; do
        dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed ||
            missing_cert+=("$package")
    done
    (( ${#missing_cert[@]} == 0 )) && return 0
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_cert[@]}"
}

create_directories() {
    install -d -m 0700 "$INSTALL_DIR" "$BACKUP_DIR"
}

verify_config_files() {
    [[ -f "$INSTALL_DIR/config.json" ]] || error_exit "配置文件不存在: $INSTALL_DIR/config.json"
    jq empty "$INSTALL_DIR/config.json" >/dev/null 2>&1 || error_exit "配置文件 JSON 格式无效"

    local file answer certs_missing
    for file in cert.crt private.key; do
        if [[ ! -f "$INSTALL_DIR/$file" ]]; then
            warn "证书文件不存在: $INSTALL_DIR/$file"
            certs_missing=true
        fi
    done
    if [[ "$certs_missing" == true ]]; then
        [[ -t 0 ]] || error_exit "非交互安装不能忽略缺失的证书文件"
        read -r -p "证书可能由配置外部管理，仍要继续？[y/N]: " answer
        [[ "$answer" =~ ^[Yy]$ ]] || error_exit "安装已取消"
    fi

    [[ -f "$INSTALL_DIR/private.key" ]] && chmod 600 "$INSTALL_DIR/private.key"
    [[ -f "$INSTALL_DIR/cert.crt" ]] && chmod 644 "$INSTALL_DIR/cert.crt"
}

backup_config_files() {
    local stamp file
    stamp=$(date +%Y%m%d_%H%M%S)
    for file in config.json cert.crt private.key; do
        [[ -f "$INSTALL_DIR/$file" ]] || continue
        cp -a "$INSTALL_DIR/$file" "$BACKUP_DIR/$file.$stamp"
    done
}

map_architecture() {
    case "$(uname -m)" in
        x86_64|amd64) printf '%s\n' amd64 ;;
        aarch64|arm64) printf '%s\n' arm64 ;;
        *) return 1 ;;
    esac
}

release_asset_metadata() {
    local release_json="$1" asset_name="$2"
    jq -er --arg name "$asset_name" '
        .assets[] | select(.name == $name) |
        [.browser_download_url, .digest] | @tsv
    ' "$release_json"
}

prepare_staged_install() {
    local release_json tag version arch asset_name metadata url digest archive extracted
    STAGING_ROOT=$(mktemp -d "$INSTALL_DIR/.install.XXXXXX")
    STAGED_SRC="$STAGING_ROOT/src"
    STAGED_SERVICE="$STAGING_ROOT/sing-box.service"
    install -d -m 0700 "$STAGED_SRC"

    release_json="$STAGING_ROOT/release.json"
    curl -fsSL --connect-timeout 10 --max-time 60 "$RELEASE_API" -o "$release_json"
    tag=$(jq -er '.tag_name | select(startswith("v"))' "$release_json")
    version="${tag#v}"
    arch=$(map_architecture) || error_exit "不支持的系统架构: $(uname -m)"
    asset_name="sing-box-${version}-linux-${arch}.tar.gz"
    metadata=$(release_asset_metadata "$release_json" "$asset_name") ||
        error_exit "发布页缺少目标文件: $asset_name"
    IFS=$'\t' read -r url digest <<< "$metadata"
    digest="${digest#sha256:}"
    [[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]] || error_exit "发布页缺少有效 SHA-256 摘要"

    archive="$STAGING_ROOT/$asset_name"
    curl -fL --retry 3 --connect-timeout 10 --max-time 300 "$url" -o "$archive"
    printf '%s  %s\n' "$digest" "$archive" | sha256sum -c -

    extracted="$STAGING_ROOT/extracted"
    install -d -m 0700 "$extracted"
    tar -xzf "$archive" -C "$extracted" --no-same-owner --no-same-permissions
    install -m 0755 "$extracted/sing-box-${version}-linux-${arch}/sing-box" "$STAGED_SRC/sing-box"

    "$STAGED_SRC/sing-box" version
    "$STAGED_SRC/sing-box" check -c "$INSTALL_DIR/config.json"
}

write_staged_service() {
    cat > "$STAGED_SERVICE" <<EOF
# Managed by tools/sbinstall.sh
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=$SRC_DIR/sing-box run -c $INSTALL_DIR/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
Type=simple
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF
}

service_file_is_managed() {
    [[ -f "$SERVICE_FILE" ]] || return 1
    grep -Fq '# Managed by tools/sbinstall.sh' "$SERVICE_FILE" && return 0
    grep -Fq "ExecStart=$SRC_DIR/sing-box run -c $INSTALL_DIR/config.json" "$SERVICE_FILE"
}

capture_service_state() {
    SERVICE_EXISTED=false
    SERVICE_WAS_ACTIVE=false
    SERVICE_WAS_ENABLED=false
    if [[ -e "$SERVICE_FILE" ]]; then
        service_file_is_managed || error_exit "现有 sing-box unit 不受本脚本管理，拒绝覆盖: $SERVICE_FILE"
        SERVICE_EXISTED=true
    fi
    systemctl is-active --quiet sing-box.service && SERVICE_WAS_ACTIVE=true || true
    systemctl is-enabled --quiet sing-box.service && SERVICE_WAS_ENABLED=true || true
}

rollback_install() {
    [[ "$TRANSACTION_ACTIVE" == true ]] || return 0
    warn "安装失败，恢复原 sing-box 状态"
    systemctl stop sing-box.service >/dev/null 2>&1 || true
    if [[ "$NEW_SRC_ACTIVATED" == true ]]; then
        rm -rf "$SRC_DIR"
    fi
    if [[ "$OLD_SRC_MOVED" == true && -d "$ROLLBACK_DIR/src" ]]; then
        mv "$ROLLBACK_DIR/src" "$SRC_DIR"
    fi
    if [[ -e "$ROLLBACK_DIR/sing-box.service" ]]; then
        cp -a "$ROLLBACK_DIR/sing-box.service" "$SERVICE_FILE"
    elif [[ "$SERVICE_EXISTED" == false ]]; then
        rm -f "$SERVICE_FILE"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ "$SERVICE_WAS_ENABLED" == true ]]; then
        systemctl enable sing-box.service >/dev/null 2>&1 || true
    else
        systemctl disable sing-box.service >/dev/null 2>&1 || true
    fi
    if [[ "$SERVICE_WAS_ACTIVE" == true ]]; then
        systemctl start sing-box.service >/dev/null 2>&1 || true
    fi
    OLD_SRC_MOVED=false
    NEW_SRC_ACTIVATED=false
    TRANSACTION_ACTIVE=false
}

activate_staged_install() {
    OLD_SRC_MOVED=false
    NEW_SRC_ACTIVATED=false
    capture_service_state
    ROLLBACK_DIR=$(mktemp -d "$BACKUP_DIR/rollback-$(date +%Y%m%d_%H%M%S).XXXXXX")
    TRANSACTION_ACTIVE=true

    if [[ -d "$SRC_DIR" ]]; then
        mv "$SRC_DIR" "$ROLLBACK_DIR/src"
        OLD_SRC_MOVED=true
    fi
    [[ -e "$SERVICE_FILE" ]] && cp -a "$SERVICE_FILE" "$ROLLBACK_DIR/sing-box.service"
    [[ "$SERVICE_WAS_ACTIVE" == true ]] && systemctl stop sing-box.service

    mv "$STAGED_SRC" "$SRC_DIR"
    NEW_SRC_ACTIVATED=true
    install -m 0644 "$STAGED_SERVICE" "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable sing-box.service
    systemctl restart sing-box.service
    systemctl is-active --quiet sing-box.service
    "$SRC_DIR/sing-box" version

    OLD_SRC_MOVED=false
    NEW_SRC_ACTIVATED=false
    TRANSACTION_ACTIVE=false
    info "sing-box 已安装；回滚快照: $ROLLBACK_DIR"
}

cleanup() {
    local exit_code=$?
    if (( exit_code != 0 )); then
        rollback_install || true
    fi
    [[ -n "$STAGING_ROOT" && -d "$STAGING_ROOT" ]] && rm -rf "$STAGING_ROOT"
}

uninstall_singbox() {
    require_root
    detect_os
    if [[ -e "$SERVICE_FILE" ]] && ! service_file_is_managed; then
        error_exit "现有 sing-box unit 不受本脚本管理，拒绝卸载"
    fi

    warn "将删除本脚本管理的 sing-box 二进制和 unit；配置及证书保留。"
    local answer
    [[ -t 0 ]] || error_exit "卸载必须在交互终端确认"
    read -r -p "继续卸载？[y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { info "已取消"; return 0; }

    systemctl disable --now sing-box.service >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"
    rm -rf "$SRC_DIR"
    systemctl daemon-reload
    info "卸载完成；$INSTALL_DIR/config.json 与证书未删除"
}

show_status() {
    if [[ -x "$SRC_DIR/sing-box" ]]; then
        "$SRC_DIR/sing-box" version
    else
        echo "sing-box 二进制: 未安装"
    fi
    if command -v systemctl >/dev/null && systemctl is-active --quiet sing-box.service; then
        echo "服务: 运行中"
    else
        echo "服务: 未运行"
    fi
    [[ -f "$INSTALL_DIR/config.json" ]] && echo "配置: $INSTALL_DIR/config.json" || echo "配置: 缺失"
}

show_help() {
    cat <<'EOF'
用法：
  sbinstall.sh [install]   校验发布物和配置后事务式安装或升级
  sbinstall.sh status      查看版本、服务与配置状态
  sbinstall.sh uninstall   删除受管程序和服务，保留配置与证书
  sbinstall.sh help        显示帮助
EOF
}

install_singbox() {
    require_root
    detect_os
    install_dependencies
    create_directories
    verify_config_files
    backup_config_files
    prepare_staged_install
    write_staged_service
    activate_staged_install
}

main() {
    case "${1:-install}" in
        install) install_singbox ;;
        status) show_status ;;
        uninstall) uninstall_singbox ;;
        help|-h|--help) show_help ;;
        *) error "未知参数: $1"; show_help; return 1 ;;
    esac
}

trap cleanup EXIT

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
