#!/bin/bash
# Docker 安全版本 - 只检查，不启动容器

set -euo pipefail

# 常量定义
readonly DOCKER_CONFIG_DIR="/etc/docker"
readonly DOCKER_DAEMON_CONFIG="$DOCKER_CONFIG_DIR/daemon.json"

# 容器目录扫描
readonly DEFAULT_CONTAINER_DIRS=(
    "/root"
    "/root/proxy" 
    "/root/vmagent"
    "/opt/docker-compose"
)

# 日志函数
if ! command -v log &> /dev/null; then
    log() {
        local msg="$1" level="${2:-info}"
        local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
        echo -e "${colors[$level]:-\033[0m}$msg\033[0m"
    }
fi

# 系统检查
check_system_requirements() {
    log "检查系统要求..." "info"
    
    local mem_mb arch disk_gb
    mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    arch=$(uname -m)
    disk_gb=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
    
    log "  架构: $arch" "info"
    log "  内存: ${mem_mb}MB" "info"
    log "  可用磁盘: ${disk_gb}GB" "info"
    
    if (( mem_mb < 512 )); then
        log "  ⚠ 内存较低，将应用优化配置" "warn"
        return 1
    fi
    
    return 0
}

# Docker 安装
install_docker() {
    log "检查并安装 Docker..." "info"
    
    if command -v docker &>/dev/null; then
        local version
        version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "未知")
        log "✓ Docker 已安装: $version" "info"
        return 0
    fi
    
    log "开始安装 Docker..." "info"
    if curl -fsSL https://get.docker.com | sh; then
        log "✓ Docker 安装成功" "info"
        systemctl enable --now docker
        
        if docker --version &>/dev/null; then
            log "✓ Docker 服务启动成功" "info"
        else
            log "✗ Docker 服务启动失败" "error"
            return 1
        fi
    else
        log "✗ Docker 安装失败" "error"
        return 1
    fi
}

# Docker 配置
configure_docker_daemon() {
    local low_memory="$1"
    
    log "配置 Docker daemon..." "info"
    
    mkdir -p "$DOCKER_CONFIG_DIR"
    [[ -f "$DOCKER_DAEMON_CONFIG" ]] && cp "$DOCKER_DAEMON_CONFIG" "${DOCKER_DAEMON_CONFIG}.bak"
    
    if [[ "$low_memory" == "true" ]]; then
        log "应用低内存优化配置..." "info"
        cat > "$DOCKER_DAEMON_CONFIG" << 'EOF'
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "max-concurrent-downloads": 2,
  "max-concurrent-uploads": 2,
  "live-restore": true,
  "userland-proxy": false
}
EOF
    else
        log "应用标准配置..." "info"
        cat > "$DOCKER_DAEMON_CONFIG" << 'EOF'
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  },
  "max-concurrent-downloads": 6,
  "max-concurrent-uploads": 4,
  "live-restore": true,
  "userland-proxy": false,
  "experimental": false
}
EOF
    fi
    
    if systemctl restart docker &>/dev/null; then
        log "✓ Docker 配置已应用" "info"
    else
        log "✗ Docker 配置应用失败" "error"
        [[ -f "${DOCKER_DAEMON_CONFIG}.bak" ]] && mv "${DOCKER_DAEMON_CONFIG}.bak" "$DOCKER_DAEMON_CONFIG"
        systemctl restart docker &>/dev/null || true
        return 1
    fi
}

# 检测 Docker Compose
detect_compose_command() {
    if docker compose version &>/dev/null; then
        echo "docker compose"
    elif command -v docker-compose &>/dev/null; then
        echo "docker-compose"
    else
        echo ""
    fi
}

# 安全的容器项目扫描（只检查，不启动）
scan_container_projects() {
    local compose_cmd
    compose_cmd=$(detect_compose_command)
    
    if [[ -z "$compose_cmd" ]]; then
        log "未检测到 Docker Compose，跳过容器项目检查" "warn"
        return 0
    fi
    
    log "使用 Docker Compose: $compose_cmd" "info"
    log "扫描容器项目..." "info"
    
    local found_projects=0
    local total_services=0
    local running_containers=0
    
    # 扫描预定义目录
    for dir in "${DEFAULT_CONTAINER_DIRS[@]}"; do
        [[ ! -d "$dir" ]] && continue
        
        # 查找 compose 文件
        local compose_file=""
        for file in compose.yaml docker-compose.yml docker-compose.yaml compose.yml; do
            if [[ -f "$dir/$file" ]]; then
                compose_file="$file"
                break
            fi
        done
        
        if [[ -n "$compose_file" ]]; then
            log "  发现项目: $dir/$compose_file" "info"
            ((found_projects++))
            
            # 安全地检查项目状态
            local original_dir=$(pwd)
            if cd "$dir" 2>/dev/null; then
                # 检查文件格式
                if $compose_cmd -f "$compose_file" config >/dev/null 2>&1; then
                    # 获取服务数量
                    local services
                    services=$($compose_cmd -f "$compose_file" config --services 2>/dev/null | wc -l) || services=0
                    
                    # 获取运行容器数量
                    local running
                    running=$($compose_cmd -f "$compose_file" ps -q --filter status=running 2>/dev/null | wc -l) || running=0
                    
                    log "    服务状态: $running/$services 运行中" "info"
                    total_services=$((total_services + services))
                    running_containers=$((running_containers + running))
                else
                    log "    ⚠ Compose 文件格式无效" "warn"
                fi
                cd "$original_dir" || true
            else
                log "    ✗ 无法访问目录" "error"
            fi
        fi
    done
    
    if (( found_projects == 0 )); then
        log "  未发现 Docker Compose 项目" "info"
    else
        log "项目扫描完成: 发现 $found_projects 个项目" "info"
        log "总计: $running_containers/$total_services 个容器运行中" "info"
    fi
    
    # 显示所有运行容器
    local all_running
    all_running=$(docker ps -q 2>/dev/null | wc -l) || all_running=0
    log "当前系统运行容器总数: $all_running" "info"
    
    return 0
}

# 状态摘要
show_status_summary() {
    echo
    log "📋 配置摘要:" "info"
    
    if command -v docker &>/dev/null; then
        local version running_containers
        version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "未知")
        running_containers=$(docker ps -q 2>/dev/null | wc -l || echo 0)
        log "  🐳 Docker: $version (运行 $running_containers 个容器)" "info"
        
        if systemctl is-active docker &>/dev/null; then
            log "  ✓ Docker 服务: 运行中" "info"
        else
            log "  ✗ Docker 服务: 未运行" "error"
        fi
    else
        log "  ✗ Docker: 未安装" "error"
    fi
    
    if [[ -f "$DOCKER_DAEMON_CONFIG" ]]; then
        log "  ⚙️ Docker 配置: 已优化" "info"
    else
        log "  ⚙️ Docker 配置: 默认" "info"
    fi
}

# 主执行流程
main() {
    log "🚀 开始 Docker 环境配置..." "info"
    
    # 系统检查
    local low_memory="false"
    if ! check_system_requirements; then
        low_memory="true"
    fi
    echo
    
    # 安装 Docker
    install_docker
    echo
    
    # 配置 Docker
    configure_docker_daemon "$low_memory"
    echo
    
    # 扫描容器项目（只检查，不启动）
    scan_container_projects
    
    # 显示摘要
    show_status_summary
    
    log "🎉 Docker 配置完成!" "info"
    log "注意: 此版本只检查容器项目，不会自动启动" "warn"
}

# 执行主流程
main "$@"
