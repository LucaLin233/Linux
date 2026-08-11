#!/usr/bin/env bash
# linux-setup:name=Docker 容器化平台
# linux-setup:order=70
# linux-setup:depends=
# linux-setup:enabled=true
# Docker 容器化平台配置模块
# 功能：通过 Docker 官方 APT 仓库安装 Docker、Compose、Buildx，
#       并可选配置容器日志轮转。

set -euo pipefail

readonly DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
readonly DOCKER_SOURCE="/etc/apt/sources.list.d/docker.sources"
readonly DOCKER_DAEMON_DIR="/etc/docker"
readonly DOCKER_DAEMON_CONFIG="$DOCKER_DAEMON_DIR/daemon.json"
readonly DOCKER_DAEMON_PREVIOUS_BACKUP="$DOCKER_DAEMON_DIR/daemon.json.previous-backup"

DOCKER_GPG_URL=""
DOCKER_REPO_URL=""

readonly DOCKER_PACKAGES=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
    docker-compose-plugin
)

APT_UPDATED=false

backup_managed_file() {
    local target="$1"
    local backup_prefix="$target"
    local state_dir="/var/lib/linux-setup/apt-source-backups"
    local suffix
    local legacy_state
    local state_file

    if [[ "$target" == /etc/apt/sources.list.d/* ]]; then
        install -d -m 0700 "$state_dir"
        backup_prefix="$state_dir/$(basename "$target")"

        for suffix in initial-backup previous-backup initial-absent previous-absent initial-unknown; do
            legacy_state="${target}.${suffix}"
            [[ -e "$legacy_state" || -L "$legacy_state" ]] || continue
            state_file="${backup_prefix}.${suffix}"
            if [[ -e "$state_file" || -L "$state_file" ]]; then
                state_file="${state_file}.legacy.$(date +%s).$$"
            fi
            mv "$legacy_state" "$state_file" || return 1
            chmod 600 "$state_file" 2>/dev/null || true
        done
    fi

    local initial_backup="${backup_prefix}.initial-backup"
    local previous_backup="${backup_prefix}.previous-backup"
    local initial_absent="${backup_prefix}.initial-absent"
    local previous_absent="${backup_prefix}.previous-absent"
    local initial_unknown="${backup_prefix}.initial-unknown"

    if [[ ! -e "$initial_backup" && ! -e "$initial_absent" && ! -e "$initial_unknown" ]]; then
        if [[ -e "$target" || -L "$target" ]]; then
            cp -a "$target" "$initial_backup" || return 1
        else
            install -D -m 0600 /dev/null "$initial_absent" || return 1
        fi
    fi
    rm -f "$previous_backup" "$previous_absent"
    if [[ -e "$target" || -L "$target" ]]; then
        cp -a "$target" "$previous_backup" || return 1
    else
        install -D -m 0600 /dev/null "$previous_absent" || return 1
    fi
}

log() {
    local message="$1"
    local level="${2:-info}"
    local -A colors=(
        [info]="\033[0;36m"
        [warn]="\033[0;33m"
        [error]="\033[0;31m"
        [success]="\033[0;32m"
    )

    echo -e "${colors[$level]:-\033[0;32m}${message}\033[0m"
}

info() { log "$1" "info"; }
warn() { log "$1" "warn"; }
error() { log "$1" "error"; }
success() { log "$1" "success"; }

require_root() {
    if (( EUID != 0 )); then
        error "需要 root 权限运行"
        exit 1
    fi
}

apt_update_once() {
    if [[ "$APT_UPDATED" == "true" ]]; then
        return 0
    fi

    if ! apt-get update -qq; then
        error "APT 软件包索引更新失败"
        return 1
    fi

    APT_UPDATED=true
}

detect_supported_distribution() {
    if [[ ! -r /etc/os-release ]]; then
        error "无法读取 /etc/os-release，无法识别系统"
        return 1
    fi

    local os_id
    local version_id
    local major_version

    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
    version_id="${VERSION_ID:-}"
    major_version="${version_id%%.*}"

    case "$os_id" in
        debian)
            if [[ ! "$major_version" =~ ^[0-9]+$ ]] || (( major_version < 12 )); then
                error "Docker 模块仅支持 Debian 12+，当前版本：${version_id:-未知}"
                return 1
            fi
            ;;
        ubuntu)
            if [[ "$version_id" != "22.04" && "$version_id" != "24.04" ]]; then
                error "Docker 模块仅支持 Ubuntu 22.04/24.04，当前版本：${version_id:-未知}"
                return 1
            fi
            ;;
        *)
            error "Docker 模块不支持当前系统：${PRETTY_NAME:-${os_id:-未知}}"
            return 1
            ;;
    esac

    if [[ -z "${VERSION_CODENAME:-}" ]]; then
        error "无法识别系统发行版代号"
        return 1
    fi

    DOCKER_GPG_URL="https://download.docker.com/linux/${os_id}/gpg"
    DOCKER_REPO_URL="https://download.docker.com/linux/${os_id}"
}

get_os_codename() {
    # detect_supported_distribution 已加载并验证 /etc/os-release。
    printf '%s\n' "$VERSION_CODENAME"
}

docker_repository_configured() {
    local codename
    codename=$(get_os_codename) || return 1

    [[ -s "$DOCKER_KEYRING" ]] &&
        [[ -f "$DOCKER_SOURCE" ]] &&
        grep -Fq "$DOCKER_REPO_URL" "$DOCKER_SOURCE" &&
        grep -Fxq "Suites: $codename" "$DOCKER_SOURCE" &&
        grep -Fq "Signed-By: $DOCKER_KEYRING" "$DOCKER_SOURCE"
}

configure_docker_repository() {
    local codename
    local architecture
    local key_temp
    local managed_file
    local state_prefix

    if docker_repository_configured; then
        for managed_file in "$DOCKER_KEYRING" "$DOCKER_SOURCE"; do
            if [[ "$managed_file" == /etc/apt/sources.list.d/* ]]; then
                state_prefix="/var/lib/linux-setup/apt-source-backups/$(basename "$managed_file")"
                if [[ ! -e "${state_prefix}.initial-backup" && ! -e "${state_prefix}.initial-absent" &&
                    ! -e "${state_prefix}.initial-unknown" &&
                    ! -e "${managed_file}.initial-backup" && ! -e "${managed_file}.initial-absent" &&
                    ! -e "${managed_file}.initial-unknown" ]]; then
                    install -D -m 0600 /dev/null "${state_prefix}.initial-unknown"
                fi
            elif [[ ! -e "${managed_file}.initial-backup" && ! -e "${managed_file}.initial-absent" &&
                ! -e "${managed_file}.initial-unknown" ]]; then
                install -D -m 0600 /dev/null "${managed_file}.initial-unknown"
            fi
            backup_managed_file "$managed_file" || return 1
        done
        return 0
    fi

    codename=$(get_os_codename) || {
        error "无法识别系统发行版代号"
        return 1
    }

    architecture=$(dpkg --print-architecture)
    install -d -m 0755 /etc/apt/keyrings
    backup_managed_file "$DOCKER_KEYRING" || return 1
    backup_managed_file "$DOCKER_SOURCE" || return 1

    if ! key_temp=$(mktemp); then
        error "无法创建 Docker GPG 密钥临时文件"
        return 1
    fi

    info "配置 Docker 官方 APT 软件源..."

    if ! curl -fsSL \
        --connect-timeout 10 \
        --max-time 30 \
        "$DOCKER_GPG_URL" \
        -o "$key_temp"; then
        rm -f "$key_temp"
        error "Docker GPG 密钥下载失败"
        return 1
    fi

    if [[ ! -s "$key_temp" ]]; then
        rm -f "$key_temp"
        error "Docker GPG 密钥为空"
        return 1
    fi

    if ! install -m 0644 "$key_temp" "$DOCKER_KEYRING"; then
        rm -f "$key_temp"
        error "Docker GPG 密钥安装失败"
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

    APT_UPDATED=false
    echo "Docker 官方软件源: 已配置（$codename / $architecture）"
}

package_is_installed() {
    dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -qx installed
}

docker_ce_installed() {
    package_is_installed docker-ce &&
        package_is_installed docker-ce-cli &&
        package_is_installed containerd.io &&
        command -v docker >/dev/null 2>&1 &&
        command -v dockerd >/dev/null 2>&1
}

docker_installed() {
    command -v docker >/dev/null 2>&1
}

handle_conflicting_packages() {
    local package
    local choice
    local conflicts=()
    local candidates=(docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc)

    for package in "${candidates[@]}"; do
        package_is_installed "$package" && conflicts+=("$package")
    done

    (( ${#conflicts[@]} == 0 )) && return 0

    warn "检测到与 Docker CE 冲突的软件包: ${conflicts[*]}"
    echo "现有 /var/lib/docker 数据不会被删除。"
    read -r -p "是否卸载冲突包并继续安装 Docker CE？[y/N]: " choice
    [[ "$choice" =~ ^[Yy]$ ]] || return 1

    apt-get remove -y "${conflicts[@]}"
}

get_docker_version() {
    docker --version 2>/dev/null || echo "版本未知"
}

install_docker() {
    if docker_ce_installed; then
        printf 'Docker CE 状态: 已完整安装（%s）\n' "$(get_docker_version)"
        return 0
    fi

    handle_conflicting_packages || {
        error "未处理冲突软件包，已取消 Docker CE 安装"
        return 1
    }

    configure_docker_repository || return 1
    apt_update_once || return 1

    info "安装 Docker、Compose 和 Buildx..."

    if ! apt-get install -y "${DOCKER_PACKAGES[@]}"; then
        error "Docker 安装失败"
        return 1
    fi

    if ! docker_installed; then
        error "Docker 安装后验证失败"
        return 1
    fi

    if ! command -v dockerd >/dev/null 2>&1; then
        error "Docker 安装后未找到 dockerd"
        return 1
    fi

    printf 'Docker 安装: 成功（%s）\n' "$(get_docker_version)"
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

    info "补充 Docker 插件: ${missing_packages[*]}"

    configure_docker_repository || {
        warn "无法配置 Docker 官方软件源，跳过缺失插件安装"
        return 1
    }

    apt_update_once || {
        warn "APT 软件包索引更新失败，跳过缺失插件安装"
        return 1
    }

    if ! apt-get install -y "${missing_packages[@]}"; then
        warn "Docker 插件安装失败"
        return 1
    fi
}

start_docker_service() {
    info "启动 Docker 服务..."

    if ! systemctl enable --now docker; then
        error "Docker 服务启动失败"
        return 1
    fi

    if ! systemctl is-active --quiet docker; then
        error "Docker 服务未处于运行状态"
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        error "Docker daemon 无法正常响应"
        return 1
    fi

    echo "Docker 服务: 运行中，已设置开机自启"
}

is_log_rotation_configured() {
    [[ -f "$DOCKER_DAEMON_CONFIG" ]] || return 1

    jq -e '
        .["log-driver"] == "json-file" and
        .["log-opts"]["max-size"] == "10m" and
        .["log-opts"]["max-file"] == "3"
    ' "$DOCKER_DAEMON_CONFIG" >/dev/null 2>&1
}

backup_daemon_config() {
    if is_log_rotation_configured &&
        [[ ! -e "${DOCKER_DAEMON_CONFIG}.initial-backup" &&
            ! -e "${DOCKER_DAEMON_CONFIG}.initial-absent" &&
            ! -e "${DOCKER_DAEMON_CONFIG}.initial-unknown" ]]; then
        install -D -m 0600 /dev/null "${DOCKER_DAEMON_CONFIG}.initial-unknown"
    fi
    backup_managed_file "$DOCKER_DAEMON_CONFIG"
}

restore_daemon_config() {
    if [[ -f "$DOCKER_DAEMON_PREVIOUS_BACKUP" ]]; then
        cp -a "$DOCKER_DAEMON_PREVIOUS_BACKUP" "$DOCKER_DAEMON_CONFIG"
        warn "已恢复 Docker 上一次配置"
    else
        rm -f "$DOCKER_DAEMON_CONFIG"
        warn "已删除本次新建的 Docker 配置文件"
    fi
}

validate_docker_config() {
    local config_file="$1"

    if ! jq empty "$config_file" >/dev/null 2>&1; then
        error "Docker 配置 JSON 格式无效"
        return 1
    fi

    if ! dockerd --validate --config-file "$config_file" >/dev/null 2>&1; then
        error "Docker 配置内容无效"
        return 1
    fi
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

    read -r -p \
        "是否配置 Docker 容器日志轮转（单文件 10MB，保留 3 份）？[Y/n]: " \
        choice
    choice="${choice:-Y}"

    if [[ "$choice" =~ ^[Nn]$ ]]; then
        echo "Docker 日志轮转: 已跳过"
        return 0
    fi

    mkdir -p "$DOCKER_DAEMON_DIR"

    if [[ -f "$DOCKER_DAEMON_CONFIG" ]] &&
        ! jq empty "$DOCKER_DAEMON_CONFIG" >/dev/null 2>&1; then
        error "现有 $DOCKER_DAEMON_CONFIG 不是有效 JSON，拒绝覆盖"
        return 1
    fi

    if ! temp_config=$(mktemp "$DOCKER_DAEMON_DIR/daemon.json.new.XXXXXX"); then
        error "无法创建 Docker 配置临时文件"
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
            error "合并 Docker 日志配置失败"
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

    if systemctl is-active --quiet docker; then
        docker_was_active=true
    fi

    if ! install -m 0644 "$temp_config" "$DOCKER_DAEMON_CONFIG"; then
        rm -f "$temp_config"
        error "替换 Docker 配置失败"
        return 1
    fi

    rm -f "$temp_config"

    if ! systemctl restart docker || ! systemctl is-active --quiet docker; then
        error "Docker 重启失败，开始恢复原配置"
        restore_daemon_config

        if [[ "$docker_was_active" == "true" ]]; then
            systemctl restart docker >/dev/null 2>&1 || true
        fi

        return 1
    fi

    echo "Docker 日志轮转: 已启用（单文件 10MB，保留 3 份）"
}

show_docker_summary() {
    local docker_version
    local containers
    local images

    echo
    info "🎯 Docker 配置摘要："

    if ! docker_installed; then
        echo "  Docker: 未安装"
        return 0
    fi

    docker_version=$(get_docker_version)
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

main() {
    require_root
    detect_supported_distribution || exit 1

    local command_name
    for command_name in apt-get curl dpkg dpkg-query grep install jq mktemp systemctl; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            error "缺少必要命令: $command_name"
            exit 1
        fi
    done

    info "🐳 配置 Docker 容器化平台..."

    echo
    install_docker || exit 1

    echo
    start_docker_service || exit 1

    echo
    ensure_docker_plugins || true

    echo
    configure_log_rotation ||
        warn "Docker 日志轮转配置失败，已保留或恢复原有 Docker 配置"

    show_docker_summary

    echo
    success "Docker 配置完成"
    echo "常用命令："
    echo "  查看容器: docker ps"
    echo "  查看镜像: docker images"
    echo "  使用 Compose: docker compose up -d"
}

trap 'error "Docker 配置脚本在第 $LINENO 行执行失败"' ERR

main "$@"
