#!/bin/bash
# Docker 容器化平台配置模块 v5.0 - 智能配置版
# 功能: 安装Docker、优化配置、管理容器

set -euo pipefail

# === 常量定义 ===
readonly CONTAINER_DIRS=(/root /root/proxy /root/vmagent)
readonly DOCKER_CONFIG_DIR="/etc/docker"
readonly DOCKER_DAEMON_CONFIG="$DOCKER_CONFIG_DIR/daemon.json"

# === 日志函数 ===
log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m" [debug]="\033[0;35m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
}

debug_log() {
    [[ "${DEBUG:-}" == "1" ]] && log "DEBUG: $1" "debug" >&2
}

# === 辅助函数 ===
# 获取内存大小
get_memory_mb() {
    debug_log "获取系统内存大小"
    local mem_mb=""
    
    # 方法1：使用 /proc/meminfo（最可靠）
    if [[ -f /proc/meminfo ]]; then
        mem_mb=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "")
        debug_log "从/proc/meminfo获取内存: ${mem_mb}MB"
    fi
    
    # 方法2：使用 free 命令作为备选
    if [[ -z "$mem_mb" ]] && command -v free >/dev/null; then
        debug_log "尝试使用free命令获取内存"
        # 尝试不同的 free 命令格式
        mem_mb=$(free -m 2>/dev/null | awk 'NR==2{print $2}' || echo "")
        
        # 如果上面失败，尝试其他格式
        if [[ -z "$mem_mb" ]]; then
            mem_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "")
        fi
        debug_log "从free命令获取内存: ${mem_mb}MB"
    fi
    
    # 验证结果是否为有效数字
    if [[ "$mem_mb" =~ ^[0-9]+$ ]] && [[ "$mem_mb" -gt 0 ]]; then
        debug_log "内存大小验证成功: ${mem_mb}MB"
        echo "$mem_mb"
    else
        debug_log "内存大小获取失败，返回0"
        echo "0"
    fi
}

# 获取Docker版本
get_docker_version() {
    debug_log "获取Docker版本"
    local version
    version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "未知")
    debug_log "Docker版本: $version"
    echo "$version"
}

# 获取Docker Compose命令
get_compose_command() {
    debug_log "检测Docker Compose命令"
    if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
        debug_log "找到docker compose命令"
        echo "docker compose"
    elif command -v docker-compose &>/dev/null; then
        debug_log "找到docker-compose命令"
        echo "docker-compose"
    else
        debug_log "未找到Docker Compose命令"
        echo ""
    fi
}

# 检查并启动单个目录的容器
check_directory_containers() {
    local dir="$1"
    local compose_cmd="$2"
    local containers_started=0
    
    debug_log "检查目录容器: $dir"
    
    if [[ ! -d "$dir" ]]; then
        debug_log "目录不存在: $dir"
        return 0
    fi
    
    # 查找compose文件
    local compose_file=""
    for file in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
        if [[ -f "$dir/$file" ]]; then
            compose_file="$file"
            debug_log "找到compose文件: $dir/$file"
            break
        fi
    done
    
    if [[ -z "$compose_file" ]]; then
        debug_log "未找到compose文件: $dir"
        return 0
    fi
    
    # 切换到目录并检查容器状态
    local current_dir=$(pwd)
    if ! cd "$dir" 2>/dev/null; then
        debug_log "无法切换到目录: $dir"
        return 0
    fi
    
    local expected_services=$($compose_cmd -f "$compose_file" config --services 2>/dev/null | wc -l || echo "0")
    local running_containers=$($compose_cmd -f "$compose_file" ps --filter status=running --quiet 2>/dev/null | wc -l || echo "0")
    
    debug_log "目录 $dir: 期望服务数=$expected_services, 运行容器数=$running_containers"
    
    if (( expected_services > 0 && running_containers < expected_services )); then
        debug_log "启动容器: $dir"
        if $compose_cmd -f "$compose_file" up -d --force-recreate >/dev/null 2>&1; then
            containers_started=1
            debug_log "容器启动成功: $dir"
        else
            debug_log "容器启动失败: $dir"
        fi
    else
        debug_log "容器状态正常: $dir"
    fi
    
    if ! cd "$current_dir" 2>/dev/null; then
        debug_log "无法切换回原目录: $current_dir"
    fi
    echo "$containers_started"
}
# === 辅助函数结束 ===

# === 核心功能函数 ===
# 安装Docker
install_docker() {
    debug_log "开始安装Docker"
    if command -v docker &>/dev/null; then
        local docker_version=$(get_docker_version)
        echo "Docker状态: 已安装 v$docker_version"
        debug_log "Docker已安装，版本: $docker_version"
        return 0
    fi
    
    echo "安装Docker中..."
    debug_log "开始下载并安装Docker"
    if curl -fsSL https://get.docker.com | sh >/dev/null 2>&1; then
        echo "Docker安装: 成功"
        debug_log "Docker安装成功"
    else
        log "✗ Docker安装失败" "error"
        debug_log "Docker安装失败"
        exit 1
    fi
    
    if ! command -v docker &>/dev/null; then
        log "✗ Docker安装验证失败" "error"
        debug_log "Docker安装后验证失败"
        exit 1
    fi
    debug_log "Docker安装验证成功"
}

# 启动Docker服务
start_docker_service() {
    debug_log "启动Docker服务"
    if systemctl is-active docker &>/dev/null; then
        echo "Docker服务: 已运行"
        debug_log "Docker服务已运行"
    elif systemctl list-unit-files docker.service &>/dev/null; then
        debug_log "启用并启动Docker服务"
        if systemctl enable --now docker.service >/dev/null 2>&1; then
            echo "Docker服务: 已启动并设置开机自启"
            debug_log "Docker服务启动并自启设置成功"
        else
            debug_log "Docker服务启动失败"
        fi
    else
        debug_log "尝试直接启动Docker服务"
        if systemctl start docker >/dev/null 2>&1; then
            systemctl enable docker >/dev/null 2>&1 || {
                debug_log "设置Docker开机自启失败"
                true
            }
            echo "Docker服务: 已启动"
            debug_log "Docker服务启动成功"
        else
            echo "Docker服务: 状态未知，但可能已运行"
            debug_log "Docker服务状态未知"
        fi
    fi
    return 0
}

# 优化Docker配置
optimize_docker_config() {
    debug_log "开始Docker配置优化"
    local mem_mb=$(get_memory_mb)
    
    if [[ "$mem_mb" -eq 0 ]]; then
        echo "内存检测: 失败，跳过优化配置"
        debug_log "内存检测失败，跳过优化"
        return 0
    fi
    
    # 1GB以下才需要优化
    if (( mem_mb >= 1024 )); then
        echo "内存状态: ${mem_mb}MB (充足，无需优化)"
        debug_log "内存充足 (${mem_mb}MB)，无需优化"
        return 0
    fi
    
    echo "内存状态: ${mem_mb}MB (偏低)"
    debug_log "内存偏低 (${mem_mb}MB)，询问是否优化"
    read -p "是否优化Docker配置以降低内存使用? [Y/n] (默认: Y): " -r optimize_choice || optimize_choice="Y"
    optimize_choice=${optimize_choice:-Y}
    
    if [[ "$optimize_choice" =~ ^[Nn]$ ]]; then
        echo "Docker优化: 跳过"
        debug_log "用户选择跳过Docker优化"
        return 0
    fi
    
    debug_log "创建Docker配置目录: $DOCKER_CONFIG_DIR"
    if ! mkdir -p "$DOCKER_CONFIG_DIR" 2>/dev/null; then
        log "创建Docker配置目录失败" "error"
        debug_log "创建Docker配置目录失败"
        return 1
    fi
    
    if [[ -f "$DOCKER_DAEMON_CONFIG" ]] && grep -q "max-size" "$DOCKER_DAEMON_CONFIG"; then
        echo "Docker优化: 已存在"
        debug_log "Docker优化配置已存在"
        return 0
    fi
    
    debug_log "写入Docker优化配置"
    if ! cat > "$DOCKER_DAEMON_CONFIG" << 'EOF'; then
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
        log "写入Docker配置失败" "error"
        debug_log "写入Docker配置文件失败"
        return 1
    fi
    
    debug_log "重启Docker服务以应用配置"
    if systemctl is-active docker &>/dev/null; then
        if systemctl restart docker >/dev/null 2>&1; then
            debug_log "Docker服务重启成功"
        else
            debug_log "Docker服务重启失败"
        fi
    fi
    
    echo "Docker优化: 已配置并重启"
    debug_log "Docker优化配置完成"
    return 0
}

# 管理Docker容器
manage_containers() {
    debug_log "开始管理Docker容器"
    local compose_cmd=$(get_compose_command)
    
    if [[ -z "$compose_cmd" ]]; then
        echo "Docker Compose: 未检测到"
        debug_log "未检测到Docker Compose"
        return 0
    fi
    
    echo "Docker Compose: 检测到 ($compose_cmd)"
    debug_log "检测到Docker Compose命令: $compose_cmd"
    read -p "是否检查并启动容器? [Y/n] (默认: Y): " -r manage_choice || manage_choice="Y"
    manage_choice=${manage_choice:-Y}
    
    if [[ "$manage_choice" =~ ^[Nn]$ ]]; then
        echo "容器管理: 跳过"
        debug_log "用户选择跳过容器管理"
        return 0
    fi
    
    debug_log "开始检查容器目录"
    local total_started=0
    local dirs_with_containers=()
    
    for dir in "${CONTAINER_DIRS[@]}"; do
        local started=$(check_directory_containers "$dir" "$compose_cmd")
        if [[ "$started" -eq 1 ]]; then
            ((total_started++))
            dirs_with_containers+=("$(basename "$dir")")
            debug_log "目录 $dir 中的容器已启动"
        fi
    done
    
    if [[ "$total_started" -gt 0 ]]; then
        echo "容器启动: ${total_started}个目录 (${dirs_with_containers[*]})"
        debug_log "总计启动 $total_started 个目录的容器"
    else
        echo "容器检查: 所有容器已在运行"
        debug_log "所有容器都已在运行"
    fi
    return 0
}

# 显示配置摘要
show_docker_summary() {
    debug_log "显示Docker配置摘要"
    echo
    log "🎯 Docker配置摘要:" "info"
    
    if command -v docker &>/dev/null; then
        local docker_version=$(get_docker_version)
        echo "  Docker: v$docker_version"
        
        if systemctl is-active docker &>/dev/null; then
            echo "  服务状态: 运行中"
            debug_log "Docker服务运行中"
        else
            echo "  服务状态: 未知"
            debug_log "Docker服务状态未知"
        fi
        
        local running_containers=$(docker ps -q 2>/dev/null | wc -l || echo "0")
        echo "  运行容器: ${running_containers}个"
        debug_log "当前运行 $running_containers 个容器"
        
        if [[ -f "$DOCKER_DAEMON_CONFIG" ]] && grep -q "max-size" "$DOCKER_DAEMON_CONFIG"; then
            echo "  配置优化: 已启用"
            debug_log "Docker优化配置已启用"
        fi
    else
        echo "  Docker: 未安装"
        debug_log "Docker未安装"
    fi
    
    local compose_cmd=$(get_compose_command)
    if [[ -n "$compose_cmd" ]]; then
        echo "  Docker Compose: 可用"
        debug_log "Docker Compose可用: $compose_cmd"
    else
        echo "  Docker Compose: 不可用"
        debug_log "Docker Compose不可用"
    fi
    return 0
}

# === 主流程 ===
main() {
    log "🐳 配置Docker容器化平台..." "info"
    
    echo
    if ! install_docker; then
        log "Docker安装失败" "error"
        exit 1
    fi
    
    echo
    if ! start_docker_service; then
        debug_log "Docker服务启动可能失败，但继续执行"
    fi
    
    echo
    if ! optimize_docker_config; then
        debug_log "Docker优化配置失败，但继续执行"
    fi
    
    echo
    if ! manage_containers; then
        debug_log "容器管理失败，但继续执行"
    fi
    
    echo "DEBUG: 准备显示Docker摘要"  # 新增
    show_docker_summary
    echo "DEBUG: Docker摘要显示完成"  # 新增
    
    echo
    log "✅ Docker配置完成!" "info"
    
    echo "DEBUG: 准备检查docker命令"  # 新增
    if command -v docker &>/dev/null; then
        echo "DEBUG: docker命令存在"  # 新增
        echo
        log "常用命令:" "info"
        echo "  查看容器: docker ps"
        echo "  查看镜像: docker images"
        echo "  系统清理: docker system prune -f"
        
        echo "DEBUG: 准备获取compose命令"  # 新增
        local compose_cmd=$(get_compose_command)
        echo "DEBUG: compose_cmd='$compose_cmd'"  # 新增
        if [[ -n "$compose_cmd" ]]; then
            echo "  容器管理: $compose_cmd up -d"
        fi
        echo "DEBUG: compose命令处理完成"  # 新增
    else
        echo "DEBUG: docker命令不存在"  # 新增
    fi
    echo "DEBUG: main函数即将结束"  # 新增
    return 0
}

# 错误处理
trap 'log "脚本执行出错，行号: $LINENO" "error"; exit 1' ERR

main "$@"
