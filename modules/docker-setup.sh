#!/bin/bash
# Docker 容器化平台配置模块 v4.2 - 简化修正版
# 功能: 安装Docker、优化配置、管理容器

set -euo pipefail

# === 常量定义 ===
readonly CONTAINER_DIRS=(/root /root/proxy /root/vmagent)
readonly DOCKER_CONFIG_DIR="/etc/docker"
readonly DOCKER_DAEMON_CONFIG="$DOCKER_CONFIG_DIR/daemon.json"

# === 日志函数 ===
log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
}

# === 核心函数 ===

# 获取内存大小（改进版）
get_memory_mb() {
    local mem_mb=""
    
    # 方法1：使用 /proc/meminfo（最可靠）
    if [[ -f /proc/meminfo ]]; then
        mem_mb=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "")
    fi
    
    # 方法2：使用 free 命令作为备选
    if [[ -z "$mem_mb" ]] && command -v free >/dev/null; then
        # 尝试不同的 free 命令格式
        mem_mb=$(free -m 2>/dev/null | awk 'NR==2{print $2}' || echo "")
        
        # 如果上面失败，尝试其他格式
        if [[ -z "$mem_mb" ]]; then
            mem_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "")
        fi
    fi
    
    # 验证结果是否为有效数字
    if [[ "$mem_mb" =~ ^[0-9]+$ ]] && [[ "$mem_mb" -gt 0 ]]; then
        echo "$mem_mb"
    else
        echo "0"
    fi
}

# 获取Docker版本
get_docker_version() {
    docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "未知"
}

# 获取Docker Compose命令
get_compose_command() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose &>/dev/null; then
        echo "docker-compose"
    else
        echo ""
    fi
}

# 安装Docker
install_docker() {
    if command -v docker &>/dev/null; then
        local docker_version=$(get_docker_version)
        echo "Docker状态: 已安装 v$docker_version"
        return 0
    fi
    
    echo "安装Docker中..."
    if curl -fsSL https://get.docker.com | sh >/dev/null 2>&1; then
        echo "Docker安装: 成功"
    else
        log "✗ Docker安装失败" "error"
        exit 1
    fi
    
    if ! command -v docker &>/dev/null; then
        log "✗ Docker安装验证失败" "error"
        exit 1
    fi
}

# 启动Docker服务
start_docker_service() {
    if systemctl is-active docker &>/dev/null; then
        echo "Docker服务: 已运行"
    elif systemctl list-unit-files docker.service &>/dev/null; then
        systemctl enable --now docker.service >/dev/null 2>&1
        echo "Docker服务: 已启动并设置开机自启"
    else
        if systemctl start docker >/dev/null 2>&1; then
            systemctl enable docker >/dev/null 2>&1 || true
            echo "Docker服务: 已启动"
        else
            echo "Docker服务: 状态未知，但可能已运行"
        fi
    fi
}

# 优化Docker配置 - 1GB阈值版
optimize_docker_config() {
    local mem_mb=$(get_memory_mb)
    
    if [[ "$mem_mb" -eq 0 ]]; then
        echo "内存检测: 失败，跳过优化配置"
        return 0
    fi
    
    # 1GB以下才需要优化
    if (( mem_mb >= 1024 )); then
        echo "内存状态: ${mem_mb}MB (充足，无需优化)"
        return 0
    fi
    
    echo "内存状态: ${mem_mb}MB (偏低)"
    read -p "是否优化Docker配置以降低内存使用? [Y/n]: " -r optimize_choice
    
    if [[ "$optimize_choice" =~ ^[Nn]$ ]]; then
        echo "Docker优化: 跳过"
        return 0
    fi
    
    mkdir -p "$DOCKER_CONFIG_DIR"
    
    if [[ -f "$DOCKER_DAEMON_CONFIG" ]] && grep -q "max-size" "$DOCKER_DAEMON_CONFIG"; then
        echo "Docker优化: 已存在"
        return 0
    fi
    
    cat > "$DOCKER_DAEMON_CONFIG" << 'EOF'
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    
    if systemctl is-active docker &>/dev/null; then
        systemctl restart docker >/dev/null 2>&1
    fi
    
    echo "Docker优化: 已配置并重启"
}

# 检查并启动单个目录的容器
check_directory_containers() {
    local dir="$1"
    local compose_cmd="$2"
    local containers_started=0
    
    if [[ ! -d "$dir" ]]; then
        return 0
    fi
    
    # 查找compose文件
    local compose_file=""
    for file in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
        if [[ -f "$dir/$file" ]]; then
            compose_file="$file"
            break
        fi
    done
    
    if [[ -z "$compose_file" ]]; then
        return 0
    fi
    
    # 切换到目录并检查容器状态
    local current_dir=$(pwd)
    cd "$dir"
    
    local expected_services=$($compose_cmd -f "$compose_file" config --services 2>/dev/null | wc -l || echo "0")
    local running_containers=$($compose_cmd -f "$compose_file" ps --filter status=running --quiet 2>/dev/null | wc -l || echo "0")
    
    if (( expected_services > 0 && running_containers < expected_services )); then
        if $compose_cmd -f "$compose_file" up -d --force-recreate >/dev/null 2>&1; then
            containers_started=1
        fi
    fi
    
    cd "$current_dir"
    echo "$containers_started"
}

# 管理Docker容器
manage_containers() {
    local compose_cmd=$(get_compose_command)
    
    if [[ -z "$compose_cmd" ]]; then
        echo "Docker Compose: 未检测到"
        return 0
    fi
    
    echo "Docker Compose: 检测到 ($compose_cmd)"
    read -p "是否检查并启动容器? [Y/n] (默认: Y): " -r manage_choice
    manage_choice=${manage_choice:-Y}
    
    if [[ "$manage_choice" =~ ^[Nn]$ ]]; then
        echo "容器管理: 跳过"
        return 0
    fi
    
    local total_started=0
    local dirs_with_containers=()
    
    for dir in "${CONTAINER_DIRS[@]}"; do
        local started=$(check_directory_containers "$dir" "$compose_cmd")
        if [[ "$started" -eq 1 ]]; then
            ((total_started++))
            dirs_with_containers+=("$(basename "$dir")")
        fi
    done
    
    if [[ "$total_started" -gt 0 ]]; then
        echo "容器启动: ${total_started}个目录 (${dirs_with_containers[*]})"
    else
        echo "容器检查: 所有容器已在运行"
    fi
}

# 显示配置摘要
show_docker_summary() {
    echo
    log "🎯 Docker配置摘要:" "info"
    
    if command -v docker &>/dev/null; then
        local docker_version=$(get_docker_version)
        echo "  Docker: v$docker_version"
        
        if systemctl is-active docker &>/dev/null; then
            echo "  服务状态: 运行中"
        else
            echo "  服务状态: 未知"
        fi
        
        local running_containers=$(docker ps -q 2>/dev/null | wc -l || echo "0")
        echo "  运行容器: ${running_containers}个"
        
        if [[ -f "$DOCKER_DAEMON_CONFIG" ]] && grep -q "max-size" "$DOCKER_DAEMON_CONFIG"; then
            echo "  配置优化: 已启用"
        fi
    else
        echo "  Docker: 未安装"
    fi
    
    local compose_cmd=$(get_compose_command)
    if [[ -n "$compose_cmd" ]]; then
        echo "  Docker Compose: 可用"
    else
        echo "  Docker Compose: 不可用"
    fi
}

# === 主流程 ===
main() {
    log "🐳 配置Docker容器化平台..." "info"
    
    echo
    install_docker
    
    echo
    start_docker_service
    
    echo
    optimize_docker_config
    
    echo
    manage_containers
    
    show_docker_summary
    
    echo
    log "✅ Docker配置完成!" "info"
    
    if command -v docker &>/dev/null; then
        echo
        log "常用命令:" "info"
        echo "  查看容器: docker ps"
        echo "  查看镜像: docker images"
        echo "  系统清理: docker system prune -f"
        
        local compose_cmd=$(get_compose_command)
        if [[ -n "$compose_cmd" ]]; then
            echo "  容器管理: $compose_cmd up -d"
        fi
    fi
}

main "$@"
