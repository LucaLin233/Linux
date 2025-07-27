#!/bin/bash
# Docker 容器化平台配置模块 v4.1
# 修复服务检测和版本获取问题

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

# 获取Docker版本
get_docker_version() {
    docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "未知"
}

# 获取NextTrace版本（修复版）
get_nexttrace_version() {
    local version_output
    version_output=$(nexttrace -V 2>&1 | head -n1 2>/dev/null || echo "")
    
    # 提取版本号并去掉换行符
    if [[ "$version_output" =~ v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "未知"
    fi
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
    log "检查并安装 Docker..." "info"
    
    if command -v docker &>/dev/null; then
        local docker_version=$(get_docker_version)
        log "Docker 已安装 (版本: $docker_version)" "info"
        return 0
    fi
    
    log "安装 Docker..." "info"
    if curl -fsSL https://get.docker.com | sh; then
        log "✓ Docker 安装完成" "info"
    else
        log "✗ Docker 安装失败" "error"
        exit 1
    fi
    
    # 验证安装
    if ! command -v docker &>/dev/null; then
        log "✗ Docker 安装验证失败" "error"
        exit 1
    fi
}

# 启动Docker服务（修复版）
start_docker_service() {
    log "配置 Docker 服务..." "info"
    
    # 更健壮的服务检测方式
    if systemctl status docker &>/dev/null; then
        log "✓ Docker 服务已运行" "info"
    elif systemctl list-unit-files docker.service &>/dev/null; then
        systemctl enable --now docker.service
        log "✓ Docker 服务已启动并设置为开机自启" "info"
    else
        # 尝试启动服务，即使检测失败
        if systemctl start docker &>/dev/null; then
            systemctl enable docker &>/dev/null || true
            log "✓ Docker 服务已启动" "info"
        else
            log "⚠ 无法管理Docker服务，但可能已运行" "warn"
        fi
    fi
}

# 优化Docker配置(低内存环境)
optimize_docker_config() {
    local mem_total=$(free -m | awk '/^Mem:/ {print $2}')
    
    if (( mem_total >= 1024 )); then
        log "内存充足 (${mem_total}MB)，无需优化Docker配置" "info"
        return 0
    fi
    
    echo
    log "检测到低内存环境 (${mem_total}MB)" "warn"
    read -p "是否优化Docker配置以降低内存使用? [Y/n] (默认: Y): " -r optimize_choice
    
    if [[ "$optimize_choice" =~ ^[Nn]$ ]]; then
        log "跳过Docker优化配置" "info"
        return 0
    fi
    
    log "优化 Docker 配置..." "info"
    mkdir -p "$DOCKER_CONFIG_DIR"
    
    # 检查是否已经配置过
    if [[ -f "$DOCKER_DAEMON_CONFIG" ]] && grep -q "max-size" "$DOCKER_DAEMON_CONFIG"; then
        log "Docker优化配置已存在" "info"
        return 0
    fi
    
    # 创建优化配置
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
    
    # 重启Docker服务应用配置
    if systemctl is-active docker &>/dev/null; then
        log "重启Docker服务以应用配置..." "info"
        systemctl restart docker
    fi
    
    log "✓ Docker日志配置已优化" "info"
}

# 安装NextTrace
install_nexttrace() {
    echo
    read -p "是否安装 NextTrace 网络追踪工具? [Y/n] (默认: Y): " -r install_choice
    
    if [[ "$install_choice" =~ ^[Nn]$ ]]; then
        log "跳过 NextTrace 安装" "info"
        return 0
    fi
    
    log "检查并安装 NextTrace..." "info"
    
    if command -v nexttrace &>/dev/null; then
        local nexttrace_version=$(get_nexttrace_version)
        log "NextTrace 已安装 (版本: $nexttrace_version)" "info"
        return 0
    fi
    
    log "安装 NextTrace..." "info"
    if curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh | bash; then
        if command -v nexttrace &>/dev/null; then
            log "✓ NextTrace 安装完成" "info"
        else
            log "✗ NextTrace 安装验证失败" "warn"
        fi
    else
        log "✗ NextTrace 安装失败" "warn"
    fi
}

# 检查单个目录的容器
check_directory_containers() {
    local dir="$1"
    local compose_cmd="$2"
    
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
    
    log "检查目录: $dir ($compose_file)" "info"
    
    # 切换到目录并检查容器状态
    local current_dir=$(pwd)
    cd "$dir"
    
    local expected_services=$($compose_cmd -f "$compose_file" config --services 2>/dev/null | wc -l || echo "0")
    local running_containers=$($compose_cmd -f "$compose_file" ps --filter status=running --quiet 2>/dev/null | wc -l || echo "0")
    
    if (( expected_services == 0 )); then
        log "  未检测到服务定义" "warn"
        cd "$current_dir"
        return 0
    fi
    
    if (( running_containers < expected_services )); then
        log "  启动容器 ($running_containers/$expected_services 运行中)" "info"
        if $compose_cmd -f "$compose_file" up -d --force-recreate; then
            sleep 3
            local new_running=$($compose_cmd -f "$compose_file" ps --filter status=running --quiet 2>/dev/null | wc -l || echo "0")
            log "  ✓ 容器启动完成 ($new_running/$expected_services 运行中)" "info"
        else
            log "  ✗ 容器启动失败" "warn"
        fi
    else
        log "  ✓ 容器已在运行 ($running_containers/$expected_services)" "info"
    fi
    
    cd "$current_dir"
}

# 管理Docker容器
manage_containers() {
    local compose_cmd=$(get_compose_command)
    
    if [[ -z "$compose_cmd" ]]; then
        log "未检测到 Docker Compose，跳过容器管理" "warn"
        return 0
    fi
    
    echo
    log "检测到 Docker Compose: $compose_cmd" "info"
    read -p "是否检查并启动Docker容器? [Y/n] (默认: Y): " -r manage_choice
    
    if [[ "$manage_choice" =~ ^[Nn]$ ]]; then
        log "跳过容器管理" "info"
        return 0
    fi
    
    log "检查 Docker Compose 容器..." "info"
    
    # 遍历所有容器目录
    for dir in "${CONTAINER_DIRS[@]}"; do
        check_directory_containers "$dir" "$compose_cmd"
    done
}

# 显示配置摘要
show_docker_summary() {
    echo
    log "🎯 Docker 配置摘要:" "info"
    
    # Docker状态
    if command -v docker &>/dev/null; then
        local docker_version=$(get_docker_version)
        log "  ✓ Docker版本: $docker_version" "info"
        
        # Docker服务状态
        if systemctl is-active docker &>/dev/null; then
            log "  ✓ Docker服务: 运行中" "info"
        else
            log "  ⚠ Docker服务: 状态未知" "warn"
        fi
        
        # 容器统计
        local running_containers=$(docker ps -q 2>/dev/null | wc -l || echo "0")
        local total_containers=$(docker ps -a -q 2>/dev/null | wc -l || echo "0")
        log "  📦 容器状态: $running_containers/$total_containers 运行中" "info"
        
        # Docker配置优化状态
        if [[ -f "$DOCKER_DAEMON_CONFIG" ]] && grep -q "max-size" "$DOCKER_DAEMON_CONFIG"; then
            log "  ⚡ 配置优化: 已启用" "info"
        fi
    else
        log "  ✗ Docker: 未安装" "error"
    fi
    
    # NextTrace状态
    if command -v nexttrace &>/dev/null; then
        local nexttrace_version=$(get_nexttrace_version)
        log "  ✓ NextTrace: $nexttrace_version" "info"
    else
        log "  ✗ NextTrace: 未安装" "info"
    fi
    
    # Docker Compose状态
    local compose_cmd=$(get_compose_command)
    if [[ -n "$compose_cmd" ]]; then
        log "  ✓ Docker Compose: $compose_cmd" "info"
    else
        log "  ✗ Docker Compose: 未安装" "warn"
    fi
}

# === 主流程 ===
main() {
    log "🐳 配置 Docker 容器化平台..." "info"
    
    echo
    install_docker
    
    echo
    start_docker_service
    
    echo
    optimize_docker_config
    
    install_nexttrace
    
    manage_containers
    
    show_docker_summary
    
    echo
    log "🎉 Docker 配置完成!" "info"
    
    # 显示有用的命令
    if command -v docker &>/dev/null; then
        echo
        log "常用命令:" "info"
        log "  查看容器: docker ps" "info"
        log "  查看镜像: docker images" "info"
        log "  系统信息: docker system df" "info"
        
        local compose_cmd=$(get_compose_command)
        if [[ -n "$compose_cmd" ]]; then
            log "  容器管理: $compose_cmd up -d" "info"
        fi
    fi
}

main "$@"
