#!/bin/bash
# Mise 版本管理器配置模块 v4.2
# 功能: 安装Mise、智能选择Python版本、Shell集成
# 统一代码风格，智能版本选择

set -euo pipefail

# === 常量定义 ===
readonly MISE_PATH="$HOME/.local/bin/mise"
readonly MISE_BIN_DIR="$HOME/.local/bin"

# === 日志函数 ===
log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
}

# === 核心函数 ===

# 获取Mise版本
get_mise_version() {
    local version_output
    version_output=$("$MISE_PATH" --version 2>/dev/null || echo "")
    
    # mise --version 可能输出格式: "mise 2024.1.0" 或 "mise linux-x64 v2024.1.0"
    if [[ "$version_output" =~ v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "未知"
    fi
}

# 获取Python版本
get_python_version() {
    local python_path python_version
    
    # 通过mise获取Python路径
    python_path=$("$MISE_PATH" which python 2>/dev/null || echo "")
    
    if [[ -x "$python_path" ]]; then
        python_version=$("$python_path" --version 2>/dev/null || echo "")
        echo "$python_version"
    else
        # 备用方法: 通过mise exec执行
        python_version=$("$MISE_PATH" exec python -- --version 2>/dev/null || echo "版本获取失败")
        echo "$python_version"
    fi
}

# 安装或更新Mise
install_mise() {
    log "检查并安装 Mise..." "info"
    
    # 确保目录存在
    mkdir -p "$MISE_BIN_DIR"
    
    if [[ -f "$MISE_PATH" ]]; then
        local mise_version=$(get_mise_version)
        log "Mise 已安装 (版本: $mise_version)" "info"
        
        echo
        read -p "是否更新 Mise 到最新版本? [y/N] (默认: N): " -r update_choice
        if [[ "$update_choice" =~ ^[Yy]$ ]]; then
            log "更新 Mise..." "info"
            curl -fsSL https://mise.run | sh
            log "✓ Mise 已更新" "info"
        fi
    else
        log "安装 Mise..." "info"
        if curl -fsSL https://mise.run | sh; then
            log "✓ Mise 安装完成" "info"
        else
            log "✗ Mise 安装失败" "error"
            exit 1
        fi
    fi
    
    # 验证安装
    if [[ ! -f "$MISE_PATH" ]]; then
        log "✗ Mise 安装验证失败" "error"
        exit 1
    fi
}

# 获取最新的三个Python主版本
get_top3_python_versions() {
    # 获取所有标准版本，提取主版本号，去重并排序，取最新3个
    local major_versions
    major_versions=$("$MISE_PATH" ls-remote python | \
        grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" | \
        sed -E 's/^([0-9]+\.[0-9]+)\.[0-9]+$/\1/' | \
        sort -V -u | \
        tail -3)
    
    # 对每个主版本获取最新的patch版本
    echo "$major_versions" | while read -r major; do
        "$MISE_PATH" ls-remote python | \
            grep -E "^${major}\.[0-9]+$" | \
            sort -V | tail -1
    done
}

# 让用户选择Python版本
choose_python_version() {
    local versions=($(get_top3_python_versions))
    local latest_version=$("$MISE_PATH" latest python 2>/dev/null || echo "")
    
    echo >&2
    echo "Python版本选择:" >&2
    
    # 显示版本选项
    for i in "${!versions[@]}"; do
        local version="${versions[$i]}"
        local label=""
        [[ "$version" == "$latest_version" ]] && label=" (latest)"
        echo "  $((i+1))) Python $version$label" >&2
    done
    
    echo "  4) 保持当前配置" >&2
    echo >&2
    
    # 获取用户选择
    local choice
    read -p "请选择 [1-4] (默认: 2): " choice </dev/tty >&2
    choice=${choice:-2}
    
    # 返回选择的版本
    case "$choice" in
        1|2|3) 
            local selected_version="${versions[$((choice-1))]}"
            [[ -n "$selected_version" ]] && echo "$selected_version" || echo "${versions[1]}"
            ;;
        4) echo "current" ;;
        *) echo "${versions[1]}" ;;  # 默认第2个
    esac
}

# 获取已安装的Python版本列表
get_installed_python_versions() {
    "$MISE_PATH" ls python 2>/dev/null | awk '/^python/ {print $2}' | grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" || true
}

# 清理旧版本Python
cleanup_old_python_versions() {
    local current_version="$1"
    local installed_versions
    
    installed_versions=$(get_installed_python_versions | grep -v "^$current_version$" || true)
    
    if [[ -n "$installed_versions" ]]; then
        echo
        log "检测到其他Python版本:" "info"
        echo "$installed_versions" | sed 's/^/  - Python /'
        
        echo
        read -p "是否删除其他版本? [y/N] (默认: N): " -r cleanup_choice
        
        if [[ "$cleanup_choice" =~ ^[Yy]$ ]]; then
            echo "$installed_versions" | while read -r version; do
                if [[ -n "$version" ]]; then
                    log "删除 Python $version..." "info"
                    if "$MISE_PATH" uninstall "python@$version" 2>/dev/null; then
                        log "✓ Python $version 已删除" "info"
                    else
                        log "✗ 删除 Python $version 失败" "warn"
                    fi
                fi
            done
        fi
    else
        log "没有其他Python版本需要清理" "info"
    fi
}

# 配置Python
setup_python() {
    log "配置 Python..." "info"
    
    # 检查当前配置
    local current_version=$("$MISE_PATH" current python 2>/dev/null || echo "")
    
    if [[ -n "$current_version" ]]; then
        log "当前Python版本: $current_version" "info"
    fi
    
    # 让用户选择版本
    local selected_version=$(choose_python_version)
    
    if [[ "$selected_version" == "current" ]]; then
        log "保持当前Python配置" "info"
        return 0
    fi
    
    log "安装 Python $selected_version..." "info"
    if "$MISE_PATH" use -g "python@$selected_version"; then
        log "✓ Python $selected_version 安装完成" "info"
        
        # 询问是否清理旧版本
        cleanup_old_python_versions "$selected_version"
    else
        log "✗ Python $selected_version 安装失败" "error"
        return 1
    fi
}

# 创建系统Python链接
link_python_globally() {
    log "创建系统Python链接..." "info"
    
    local python_path
    python_path=$("$MISE_PATH" which python 2>/dev/null || echo "")
    
    if [[ -x "$python_path" ]]; then
        log "创建 /usr/bin/python 链接..." "info"
        sudo ln -sf "$python_path" /usr/bin/python
        
        log "创建 /usr/bin/python3 链接..." "info"
        sudo ln -sf "$python_path" /usr/bin/python3
        
        log "✓ Python链接已创建" "info"
        log "  /usr/bin/python -> $python_path" "info"
        log "  /usr/bin/python3 -> $python_path" "info"
    else
        log "✗ 无法找到Mise管理的Python，跳过链接创建" "warn"
    fi
}

# 配置Shell集成
configure_shell_integration() {
    log "配置 Shell 集成..." "info"
    
    # Shell配置数组: shell名称:配置文件:激活命令
    local shells=(
        "bash:$HOME/.bashrc:eval \"\$(\$HOME/.local/bin/mise activate bash)\""
        "zsh:$HOME/.zshrc:eval \"\$(mise activate zsh)\""
    )
    
    for shell_info in "${shells[@]}"; do
        local shell_name="${shell_info%%:*}"
        local config_file="${shell_info#*:}"
        config_file="${config_file%%:*}"
        local activate_cmd="${shell_info##*:}"
        
        # 检查shell是否可用
        if ! command -v "$shell_name" &>/dev/null; then
            continue
        fi
        
        # 确保配置文件存在
        [[ ! -f "$config_file" ]] && touch "$config_file"
        
        # 检查是否已配置
        if grep -q "mise activate $shell_name" "$config_file"; then
            log "$shell_name 集成已存在" "info"
        else
            # 添加配置
            if [[ "$shell_name" == "bash" ]]; then
                echo -e "\n# Mise version manager\n$activate_cmd" >> "$config_file"
            else
                # 对于zsh，插入到mise注释后面（zsh-setup模块已经添加了注释）
                if grep -q "# mise 版本管理器配置" "$config_file"; then
                    sed -i "/# mise 版本管理器配置/a $activate_cmd" "$config_file"
                else
                    echo -e "\n# Mise version manager\n$activate_cmd" >> "$config_file"
                fi
            fi
            log "✓ Mise 已添加到 $config_file" "info"
        fi
    done
}

# 显示配置摘要
show_mise_summary() {
    echo
    log "🎯 Mise 配置摘要:" "info"
    
    # Mise版本
    if [[ -f "$MISE_PATH" ]]; then
        local mise_version=$(get_mise_version)
        log "  ✓ Mise版本: $mise_version" "info"
        
        # Python状态
        if "$MISE_PATH" which python &>/dev/null; then
            local python_version=$(get_python_version)
            local current_version=$("$MISE_PATH" current python 2>/dev/null || echo "未知")
            log "  ✓ Python: $python_version (当前: $current_version)" "info"
        else
            log "  ✗ Python: 未配置" "info"
        fi
        
        # 全局工具列表
        local tools_count=$("$MISE_PATH" list 2>/dev/null | wc -l || echo "0")
        log "  📦 已安装工具: $tools_count 个" "info"
    else
        log "  ✗ Mise: 未安装" "error"
    fi
    
    # Shell集成状态
    if grep -q "mise activate" "$HOME/.bashrc" 2>/dev/null; then
        log "  ✓ Bash集成: 已配置" "info"
    fi
    
    if [[ -f "$HOME/.zshrc" ]] && grep -q "mise activate" "$HOME/.zshrc" 2>/dev/null; then
        log "  ✓ Zsh集成: 已配置" "info"
    fi
}

# === 主流程 ===
main() {
    log "🔧 配置 Mise 版本管理器..." "info"
    
    echo
    install_mise
    
    echo
    setup_python
    
    echo
    link_python_globally
    
    echo
    configure_shell_integration
    
    show_mise_summary
    
    echo
    log "🎉 Mise 配置完成!" "info"
    log "💡 提示: 运行 'source ~/.bashrc' 或重新登录以激活 Mise" "info"
    
    # 显示有用的命令
    if [[ -f "$MISE_PATH" ]]; then
        echo
        log "常用命令:" "info"
        log "  查看工具: $MISE_PATH list" "info"
        log "  安装工具: $MISE_PATH use -g <tool>@<version>" "info"
        log "  查看帮助: $MISE_PATH --help" "info"
    fi
}

main "$@"
