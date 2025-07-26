#!/bin/bash
# Docker & NextTrace 配置模块 (优化版 v3.1)
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
)

# === 兼容性日志函数 ===
if ! command -v log &> /dev/null; then
    log() {
        local msg="$1" level="${2:-info}"
        local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
        echo -e "${colors[$level]:-\033[0m}$msg\033[0m"
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
        version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "未知")
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
  "max-concurrent-downloads": 2,
  "max-concurrent-uploads": 2,
  "live-restore": true,
  "userland-proxy": false
}
EOF
    else
        log "应用标准配置..." "info"
        # 标准配置（修复版）
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
    
    # 重启Docker服务
    if systemctl restart docker &>/dev/null; then
        log "✓ Docker 配置已应用" "info"
    else
        log "✗ Docker 配置应用失败" "error"
        # 恢复备份
        [[ -f "${DOCKER_DAEMON_CONFIG}.bak" ]] && mv "${DOCKER_DAEMON_CONFIG}.bak" "$DOCKER_DAEMON_CONFIG"
        systemctl restart docker &>/dev/null || true
        return 1
    fi
}

# === NextTrace 安装模块 ===
install_nexttrace() {
    log "检查并安装 NextTrace..." "info"
    
    # 检查是否已安装，使用更安全的方式
    if command -v nexttrace >/dev/null 2>&1; then
        # 尝试获取版本，但不让失败影响脚本
        local version=""
        if nexttrace -V >/dev/null 2>&1; then
            version=$(nexttrace -V 2>/dev/null | head -n1 | awk '{print $2}' 2>/dev/null || echo "")
        fi
        
        if [[ -n "$version" ]]; then
            log "✓ NextTrace 已安装: $version" "info"
        else
            log "✓ NextTrace 已安装" "info"
        fi
        return 0
    fi
    
    log "开始安装 NextTrace..." "info"
    
    # 更安全的安装方式
    local install_result=0
    if curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh | bash >/dev/null 2>&1; then
        install_result=0
    else
        install_result=1
    fi
    
    # 检查安装结果
    if [[ $install_result -eq 0 ]] && command -v nexttrace >/dev/null 2>&1; then
        log "✓ NextTrace 安装成功" "info"
    else
        log "⚠ NextTrace 安装失败，但继续执行其他功能" "warn"
    fi
    
    # 总是返回成功，不影响主脚本
    return 0
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
    
    # 扫描预定义目录
    for dir in "${DEFAULT_CONTAINER_DIRS[@]}"; do
        # 检查目录是否存在
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
            
            # 安全地处理容器项目
            if start_container_project "$dir" "$compose_file" "$compose_cmd"; then
                log "    ✓ 项目处理成功" "info"
            else
                log "    ⚠ 项目处理遇到问题，已跳过" "warn"
            fi
        fi
    done
    
    if (( found_projects == 0 )); then
        log "  未发现 Docker Compose 项目" "info"
    else
        log "项目扫描完成: 发现 $found_projects 个项目" "info"
    fi
    
    # 显示总体容器状态
    local actual_running=0
    if actual_running=$(docker ps -q 2>/dev/null | wc -l 2>/dev/null); then
        log "当前运行容器总数: $actual_running" "info"
    else
        log "无法获取容器状态" "warn"
    fi
    
    return 0
}

start_container_project() {
    local project_dir="$1"
    local compose_file="$2"
    local compose_cmd="$3"
    local original_dir
    
    # 记录原始目录
    original_dir=$(pwd) || return 1
    
    # 切换到项目目录，添加错误处理
    if ! cd "$project_dir" 2>/dev/null; then
        log "    ✗ 无法进入目录: $project_dir" "error"
        return 1
    fi
    
    # 检查 compose 文件是否有效，添加错误捕获
    if ! $compose_cmd -f "$compose_file" config >/dev/null 2>&1; then
        log "    ⚠ Compose 文件格式无效，跳过: $compose_file" "warn"
        cd "$original_dir" || true  # 直接返回原目录
        return 1
    fi
    
    # 获取项目状态，添加错误处理
    local expected_services=0
    local running_containers=0
    
    # 安全地获取服务数量
    expected_services=$($compose_cmd -f "$compose_file" config --services 2>/dev/null | wc -l 2>/dev/null) || expected_services=0
    
    # 安全地获取运行容器数量
    running_containers=$($compose_cmd -f "$compose_file" ps -q --filter status=running 2>/dev/null | wc -l 2>/dev/null) || running_containers=0
    
    log "    服务状态: $running_containers/$expected_services 运行中" "info"
    
    # 如果需要启动容器
    if (( expected_services > 0 && running_containers < expected_services )); then
        log "    启动容器..." "info"
        
        # 安全地执行启动命令
        if $compose_cmd -f "$compose_file" up -d --remove-orphans >/dev/null 2>&1; then
            sleep 2  # 给容器启动时间
            
            # 重新检查运行状态
            local new_running=0
            new_running=$($compose_cmd -f "$compose_file" ps -q --filter status=running 2>/dev/null | wc -l 2>/dev/null) || new_running=0
            log "    ✓ 启动完成: $new_running 个容器运行中" "info"
        else
            log "    ⚠ 容器启动失败，但继续执行" "warn"
        fi
    elif (( expected_services > 0 )); then
        log "    ✓ 容器已在运行" "info"
    else
        log "    ⚠ 未检测到有效服务配置" "warn"
    fi
    
    # 返回原目录
    cd "$original_dir" || true
    return 0
}

# === 状态摘要 ===
show_status_summary() {
    echo
    log "📋 配置摘要:" "info"
    
    # Docker 状态
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
    
    # NextTrace 状态
    if command -v nexttrace &>/dev/null; then
        local nt_version
        nt_version=$(nexttrace -V 2>/dev/null | head -n1 | awk '{print $2}' 2>/dev/null || echo "已安装")
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
    
    # 临时注释掉 NextTrace
    # install_nexttrace
    # echo
    
    # 管理容器项目
    manage_container_projects
    
    # 显示摘要
    show_status_summary
    
    log "🎉 Docker & NextTrace 配置完成!" "info"
}

# 执行主流程
main "$@"
