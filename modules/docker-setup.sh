#!/bin/bash
# Docker & NextTrace 配置模块 (优化版 v3.0)
# 功能: Docker安装优化、NextTrace网络工具、容器管理

set -euo pipefail

# === 常量定义 ===
readonly DOCKER_CONFIG_DIR="/etc/docker"
readonly DOCKER_DAEMON_CONFIG="$DOCKER_CONFIG_DIR/daemon.json"
readonly NEXTTRACE_INSTALL_URL="https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh"

# 容器目录扫描 (可配置)
readonly DEFAULT_CONTAINER_DIRS=(
    "/root"
    "/root/proxy" 
    "/root/vmagent"
    "/opt/docker-compose"
    "/home/*/docker"
)

# === 兼容性日志函数 ===
if ! command -v log &> /dev/null; then
    log() {
        local msg="$1" level="${2:-info}"
        local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
        echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
    }
fi

# === 系统检查 ===
check_system_requirements() {
    log "检查系统要求..." "info"
    
    local mem_mb arch disk_gb
    mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    arch=$(uname -m)
    disk_gb=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
    
    log "  架构: $arch" "info"
    log "  内存: ${mem_mb}MB" "info"
    log "  可用磁盘: ${disk_gb}GB" "info"
    
    # 低内存提醒
    if (( mem_mb < 512 )); then
        log "  ⚠ 内存较低，将应用优化配置" "warn"
        return 1  # 返回1表示需要优化
    fi
    
    return 0  # 返回0表示正常配置
}

# === Docker 安装模块 ===
install_docker() {
    log "检查并安装 Docker..." "info"
    
    if command -v docker &>/dev/null; then
        local version
        version=$(docker --version | awk '{print $3}' | tr -d ',')
        log "✓ Docker 已安装: $version" "info"
        return 0
    fi
    
    log "开始安装 Docker..." "info"
    
    # 使用官方安装脚本
    if curl -fsSL https://get.docker.com | sh; then
        log "✓ Docker 安装成功" "info"
        
        # 启用服务
        systemctl enable --now docker
        
        # 验证安装
        if docker --version; then
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

# === Docker 配置优化 ===
configure_docker_daemon() {
    local low_memory="$1"
    
    log "配置 Docker daemon..." "info"
    
    mkdir -p "$DOCKER_CONFIG_DIR"
    
    # 备份现有配置
    [[ -f "$DOCKER_DAEMON_CONFIG" ]] && cp "$DOCKER_DAEMON_CONFIG" "${DOCKER_DAEMON_CONFIG}.bak"
    
    # 根据内存情况生成配置
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
  "default-ulimits": {
    "nofile": {
      "hard": 32768,
      "soft": 32768
    }
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
  "default-ulimits": {
    "nofile": {
      "hard": 65536,
      "soft": 65536
    }
  },
  "max-concurrent-downloads": 6,
  "max-concurrent-uploads": 4,
  "live-restore": true,
  "userland-proxy": false,
  "experimental": false
}
EOF
    fi
    
    # 重启Docker服务
    if systemctl restart docker; then
        log "✓ Docker 配置已应用" "info"
    else
        log "✗ Docker 配置应用失败" "error"
        # 恢复备份
        [[ -f "${DOCKER_DAEMON_CONFIG}.bak" ]] && mv "${DOCKER_DAEMON_CONFIG}.bak" "$DOCKER_DAEMON_CONFIG"
        systemctl restart docker
        return 1
    fi
}

# === NextTrace 安装模块 ===
install_nexttrace() {
    log "检查并安装 NextTrace..." "info"
    
    if command -v nexttrace &>/dev/null; then
        local version
        version=$(nexttrace -V 2>&1 | head -n1 | awk '{print $2}' 2>/dev/null || echo "未知版本")
        log "✓ NextTrace 已安装: $version" "info"
        return 0
    fi
    
    log "开始安装 NextTrace..." "info"
    
    # 下载并执行安装脚本
    if curl -Ls "$NEXTTRACE_INSTALL_URL" | bash; then
        # 验证安装
        if command -v nexttrace &>/dev/null; then
            local version
            version=$(nexttrace -V 2>&1 | head -n1 | awk '{print $2}' 2>/dev/null || echo "安装成功")
            log "✓ NextTrace 安装成功: $version" "info"
        else
            log "✗ NextTrace 安装验证失败" "error"
            return 1
        fi
    else
        log "✗ NextTrace 安装失败" "error"
        return 1
    fi
}

# === 检测 Docker Compose 命令 ===
detect_compose_command() {
    if docker compose version &>/dev/null; then
        echo "docker compose"
    elif command -v docker-compose &>/dev/null; then
        echo "docker-compose"
    else
        echo ""
    fi
}

# === 容器项目管理 ===
manage_container_projects() {
    local compose_cmd
    compose_cmd=$(detect_compose_command)
    
    if [[ -z "$compose_cmd" ]]; then
        log "未检测到 Docker Compose，跳过容器项目检查" "warn"
        return 0
    fi
    
    log "使用 Docker Compose: $compose_cmd" "info"
    log "扫描容器项目..." "info"
    
    local found_projects=0
    local total_containers=0
    
    # 扫描预定义目录
    for dir_pattern in "${DEFAULT_CONTAINER_DIRS[@]}"; do
        # 展开路径（处理通配符）
        for dir in $dir_pattern; do
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
                
                # 检查并启动容器
                start_container_project "$dir" "$compose_file" "$compose_cmd"
                
                # 统计运行的容器
                local running
                running=$($compose_cmd -f "$dir/$compose_file" ps -q --filter status=running 2>/dev/null | wc -l)
                total_containers=$((total_containers + running))
            fi
        done
    done
    
    if (( found_projects == 0 )); then
        log "  未发现 Docker Compose 项目" "info"
    else
        log "项目扫描完成: 发现 $found_projects 个项目" "info"
    fi
    
    # 显示总体容器状态
    local actual_running
    actual_running=$(docker ps -q 2>/dev/null | wc -l)
    log "当前运行容器总数: $actual_running" "info"
}

start_container_project() {
    local project_dir="$1"
    local compose_file="$2"
    local compose_cmd="$3"
    
    cd "$project_dir"
    
    # 获取项目状态
    local expected_services running_containers
    expected_services=$($compose_cmd -f "$compose_file" config --services 2>/dev/null | wc -l)
    running_containers=$($compose_cmd -f "$compose_file" ps -q --filter status=running 2>/dev/null | wc -l)
    
    log "    服务状态: $running_containers/$expected_services 运行中" "info"
    
    if (( running_containers < expected_services )); then
        log "    启动容器..." "info"
        if $compose_cmd -f "$compose_file" up -d --remove-orphans; then
            sleep 2  # 给容器启动时间
            local new_running
            new_running=$($compose_cmd -f "$compose_file" ps -q --filter status=running 2>/dev/null | wc -l)
            log "    ✓ 启动完成: $new_running 个容器运行中" "info"
        else
            log "    ✗ 容器启动失败" "error"
        fi
    else
        log "    ✓ 容器已在运行" "info"
    fi
    
    cd - >/dev/null
}

# === 状态摘要 ===
show_status_summary() {
    echo
    log "📋 配置摘要:" "info"
    
    # Docker 状态
    if command -v docker &>/dev/null; then
        local version running_containers
        version=$(docker --version | awk '{print $3}' | tr -d ',')
        running_containers=$(docker ps -q 2>/dev/null | wc -l)
        log "  🐳 Docker: $version (运行 $running_containers 个容器)" "info"
        
        if systemctl is-active docker &>/dev/null; then
            log "  ✓ Docker 服务: 运行中" "info"
        else
            log "  ✗ Docker 服务: 未运行" "error"
        fi
    else
        log "  ✗ Docker: 未安装" "error"
    fi
    
    # NextTrace 状态
    if command -v nexttrace &>/dev/null; then
        local nt_version
        nt_version=$(nexttrace -V 2>&1 | head -n1 | awk '{print $2}' 2>/dev/null || echo "已安装")
        log "  🌐 NextTrace: $nt_version" "info"
    else
        log "  ✗ NextTrace: 未安装" "error"
    fi
    
    # 配置文件状态
    if [[ -f "$DOCKER_DAEMON_CONFIG" ]]; then
        log "  ⚙️ Docker 配置: 已优化" "info"
    else
        log "  ⚙️ Docker 配置: 默认" "info"
    fi
}

# === 主执行流程 ===
main() {
    log "🚀 开始 Docker & NextTrace 环境配置..." "info"
    
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
    
    # 安装 NextTrace
    install_nexttrace
    echo
    
    # 管理容器项目
    manage_container_projects
    
    # 显示摘要
    show_status_summary
    
    log "🎉 Docker & NextTrace 配置完成!" "info"
}

# 执行主流程
main "$@"
