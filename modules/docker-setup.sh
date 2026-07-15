#!/usr/bin/env bash
# Docker 容器化平台配置模块
# 功能：通过 Docker 官方 APT 仓库安装 Docker、Compose、Buildx，并配置容器日志轮转

set -euo pipefail

# === 常量定义 ===
readonly DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
readonly DOCKER_SOURCE="/etc/apt/sources.list.d/docker.sources"
readonly DOCKER_DAEMON_DIR="/etc/docker"
readonly DOCKER_DAEMON_CONFIG="$DOCKER_DAEMON_DIR/daemon.json"
readonly DOCKER_DAEMON_BACKUP="$DOCKER_DAEMON_DIR/daemon.json.backup"

readonly DOCKER_GPG_URL="https://download.docker.com/linux/debian/gpg"
readonly DOCKER_REPO_URL="https://download.docker.com/linux/debian"

readonly DOCKER_PACKAGES=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
    docker-compose-plugin
)

# === 日志函数 ===
log() {
    local msg="$1"
    local level="${2:-info}"
    local -A colors=(
        [info]="\033[0;36m"
        [warn]="\033[0;33m"
        [error]="\033[0;31m"
        [success]="\033[0;32m"
        [debug]="\033[0;35m"
    )

    if [[ "$level" == "debug" && "${DEBUG:-}" != "1" ]]; then
        return 0
    fi

    echo -e "${colors[$level]:-\033[0;32m}${msg}\033[0m"
}

debug_log() {
    log "DEBUG: $1" "debug"
}

require_root() {
    if (( EUID != 0 )); then
        log "需要 root 权限运行" "error"
        exit 1
    fi
}

# === Docker 官方软件源 ===
get_debian_codename() {
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release

        if [[ -n "${VERSION_CODENAME:-}" ]]; then
            echo "$VERSION_CODENAME"
            return 0
        fi
    fi

    return 1
}

configure_docker_repository() {
    local codename
    local architecture
    local key_temp

    if [[ -s "$DOCKER_KEYRING" && -f "$DOCKER_SOURCE" ]]; then
        debug_log "Docker 官方软件源已配置"
        return 0
    fi

    if ! codename=$(get_debian_codename); then
        log "无法识别 Debian 版本代号，无法配置 Docker 官方软件源" "error"
        return 1
    fi

    architecture=$(dpkg --print-architecture)

    install -d -m 0755 /etc/apt/keyrings

    if ! key_temp=$(mktemp); then
        log "无法创建 Docker GPG 密钥临时文件" "error"
        return 1
    fi

    log "配置 Docker 官方 APT 软件源..." "info"

    if ! curl -fsSL \
        --connect-timeout 10 \
        --max-time 30 \
        "$DOCKER_GPG_URL" \
        -o "$key_temp"; then
        rm -f "$key_temp"
        log "Docker GPG 密钥下载失败" "error"
        return 1
    fi

    if [[ ! -s "$key_temp" ]]; then
        rm -f "$key_temp"
        log "Docker GPG 密钥为空" "error"
        return 1
    fi

    if ! install -m 0644 "$key_temp" "$DOCKER_KEYRING"; then
        rm -f "$key_temp"
        log "Docker GPG 密钥安装失败" "error"
        return 1
    fi

    rm -f "$key_temp"

    cat > "$DOCKER_SOURCE" <<EOF
Types: deb
URIs: $DOCKER_REPO_URL
Suites: $codename
Components: stable
Architectures: $architecture
Signed-By: $DOCKER_KEYRING
EOF

    echo "Docker 官方软件源: 已配置（$codename / $architecture）"
}

# === Docker 安装与服务 ===
is_docker_installed() {
    command -v docker >/dev/null 2>&1
}

install_docker() {
    if is_docker_installed; then
        echo "Docker 状态: 已安装（$(docker --version 2>/dev/null || echo "版本未知"）"
        return 0
    fi

    configure_docker_repository || return 1

    if ! apt-get update -qq; then
        log "Docker 软件源索引更新失败" "error"
        return 1
    fi

    log "安装 Docker、Compose 和 Buildx..." "info"

    if ! apt-get install -y "${DOCKER_PACKAGES[@]}"; then
        log "Docker 安装失败" "error"
        return 1
    fi

    if ! is_docker_installed; then
        log "Docker 安装后验证失败" "error"
        return 1
    fi

    echo "Docker 安装: 成功（$(docker --version 2>/dev/null)）"
}

ensure_docker_plugins() {
    local missing_packages=()

    if ! docker compose version >/dev/null 2>&1; then
        missing_packages+=("docker-compose-plugin")
    fi

    if ! docker buildx version >/dev/null 2>&1; then
        missing_packages+=("docker-buildx-plugin")
    fi

    if (( ${#missing_packages[@]} == 0 )); then
        echo "Docker 插件: Compose 和 Buildx 均可用"
        return 0
    fi

    log "补充 Docker 插件: ${missing_packages[*]}" "info"

    if ! configure_docker_repository; then
        log "无法配置 Docker 官方软件源，跳过缺失插件安装" "warn"
        return 1
    fi

    if ! apt-get update -qq; then
        log "APT 软件包索引更新失败，跳过缺失插件安装" "warn"
        return 1
    fi

    if ! apt-get install -y "${missing_packages[@]}"; then
        log "Docker 插件安装失败" "warn"
        return 1
    fi

    return 0
}

start_docker_service() {
    log "启动 Docker 服务..." "info"

    if ! systemctl enable --now docker; then
        log "Docker 服务启动失败" "error"
        return 1
    fi

    if ! systemctl is-active --quiet docker; then
        log "Docker 服务未处于运行状态" "error"
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        log "Docker daemon 无法正常响应" "error"
        return 1
    fi

    echo "Docker 服务: 运行中，已设置开机自启"
}

# === Docker 日志轮转配置 ===
backup_daemon_config() {
    [[ -f "$DOCKER_DAEMON_CONFIG" ]] || return 0

    if cp "$DOCKER_DAEMON_CONFIG" "$DOCKER_DAEMON_BACKUP"; then
        chmod 600 "$DOCKER_DAEMON_BACKUP" 2>/dev/null || true
        debug_log "已更新 Docker 配置备份：$DOCKER_DAEMON_BACKUP"
        return 0
    fi

    log "Docker 配置备份失败" "error"
    return 1
}

restore_daemon_config() {
    if [[ -f "$DOCKER_DAEMON_BACKUP" ]]; then
        cp "$DOCKER_DAEMON_BACKUP" "$DOCKER_DAEMON_CONFIG"
        log "已恢复 Docker 配置备份" "warn"
    else
        rm -f "$DOCKER_DAEMON_CONFIG"
        log "已删除新建的 Docker 配置文件" "warn"
    fi
}

validate_docker_config() {
    local config_file="$1"

    if ! jq empty "$config_file" >/dev/null 2>&1; then
        log "Docker 配置 JSON 格式无效" "error"
        return 1
    fi

    if ! dockerd --validate --config-file "$config_file" >/dev/null 2>&1; then
        log "Docker 配置内容无效" "error"
        return 1
    fi

    return 0
}

is_log_rotation_configured() {
    [[ -f "$DOCKER_DAEMON_CONFIG" ]] || return 1

    jq -e '
        .["log-driver"] == "json-file" and
        .["log-opts"]["max-size"] == "10m" and
        .["log-opts"]["max-file"] == "3"
    ' "$DOCKER_DAEMON_CONFIG" >/dev/null 2>&1
}

configure_log_rotation() {
    local choice
    local temp_config
    local docker_was_active=false

    if is_log_rotation_configured; then
        echo "Docker 日志轮转: 已配置（单文件 10MB，保留 3 份）"
        return 0
    fi

    echo
    echo "Docker 日志轮转可避免容器 json-file 日志无限增长并占满磁盘。"
    echo "应用配置需要重启 Docker，运行中的容器可能短暂中断。"

    read -r -p "是否配置 Docker 容器日志轮转（单文件 10MB，保留 3 份）？[Y/n]: " choice
    choice="${choice:-Y}"

    if [[ "$choice" =~ ^[Nn]$ ]]; then
        echo "Docker 日志轮转: 已跳过"
        return 0
    fi

    mkdir -p "$DOCKER_DAEMON_DIR"

    if [[ -f "$DOCKER_DAEMON_CONFIG" ]] &&
        ! jq empty "$DOCKER_DAEMON_CONFIG" >/dev/null 2>&1; then
        log "现有 $DOCKER_DAEMON_CONFIG 不是有效 JSON，拒绝覆盖" "error"
        return 1
    fi

    if ! temp_config=$(mktemp "$DOCKER_DAEMON_DIR/daemon.json.XXXXXX"); then
        log "无法创建 Docker 配置临时文件" "error"
        return 1
    fi

    if [[ -f "$DOCKER_DAEMON_CONFIG" ]]; then
        if ! jq '
            .["log-driver"] = "json-file" |
            .["log-opts"] = ((.["log-opts"] // {}) + {
                "max-size": "10m",
                "max-file": "3"
            })
        ' "$DOCKER_DAEMON_CONFIG" > "$temp_config"; then
            rm -f "$temp_config"
            log "合并 Docker 日志配置失败" "error"
            return 1
        fi
    else
        cat > "$temp_config" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    fi

    if ! validate_docker_config "$temp_config"; then
        rm -f "$temp_config"
        return 1
    fi

    backup_daemon_config || {
        rm -f "$temp_config"
        return 1
    }

    systemctl is-active --quiet docker && docker_was_active=true

    if ! mv "$temp_config" "$DOCKER_DAEMON_CONFIG"; then
        rm -f "$temp_config"
        log "替换 Docker 配置失败" "error"
        return 1
    fi

    chmod 644 "$DOCKER_DAEMON_CONFIG"

    if ! systemctl restart docker || ! systemctl is-active --quiet docker; then
        log "Docker 重启失败，开始恢复原配置" "error"
        restore_daemon_config

        if [[ "$docker_was_active" == "true" ]]; then
            systemctl restart docker >/dev/null 2>&1 || true
        fi

        return 1
    fi

    echo "Docker 日志轮转: 已启用（单文件 10MB，保留 3 份）"
    return 0
}

# === 摘要 ===
show_docker_summary() {
    local docker_version
    local containers
    local images

    echo
    log "🎯 Docker 配置摘要：" "info"

    if ! is_docker_installed; then
        echo "  Docker: 未安装"
        return 0
    fi

    docker_version=$(docker --version 2>/dev/null || echo "未知")
    containers=$(docker ps -aq 2>/dev/null | wc -l)
    images=$(docker images -q 2>/dev/null | wc -l)

    echo "  Docker: $docker_version"

    if systemctl is-active --quiet docker; then
        echo "  服务状态: 运行中"
    else
        echo "  服务状态: 未运行"
    fi

    if docker compose version >/dev/null 2>&1; then
        echo "  Compose: $(docker compose version 2>/dev/null)"
    else
        echo "  Compose: 未安装"
    fi

    if docker buildx version >/dev/null 2>&1; then
        echo "  Buildx: 已安装"
    else
        echo "  Buildx: 未安装"
    fi

    echo "  容器数量: $containers"
    echo "  镜像数量: $images"

    if is_log_rotation_configured; then
        echo "  日志轮转: 已启用（10MB × 3）"
    else
        echo "  日志轮转: 未配置"
    fi
}

# === 主流程 ===
main() {
    require_root

    local command
    for command in apt-get curl dpkg install jq mktemp systemctl dockerd; do
        if ! command -v "$command" >/dev/null 2>&1; then
            log "缺少必要命令: $command" "error"
            exit 1
        fi
    done

    log "🐳 配置 Docker 容器化平台..." "info"

    echo
    install_docker || exit 1

    echo
    start_docker_service || exit 1

    echo
    ensure_docker_plugins || true

    echo
    configure_log_rotation || log "Docker 日志轮转配置失败，保留现有 Docker 配置" "warn"

    show_docker_summary

    echo
    log "✅ Docker 配置完成" "success"
    echo "常用命令："
    echo "  查看容器: docker ps"
    echo "  查看镜像: docker images"
    echo "  使用 Compose: docker compose up -d"
}

trap 'log "Docker 配置脚本在第 $LINENO 行执行失败" "error"' ERR

main "$@"
