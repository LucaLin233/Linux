#!/bin/bash
# Mise 版本管理器配置模块 v4.4
# 功能: 安装Mise、智能选择Python版本、Shell集成、智能链接管理
# 新增: 系统状态检测、PATH优先级管理、可重复运行安全

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

# === 系统状态检测函数 ===

# 检测当前Python链接状态
detect_python_status() {
    local status_info=""
    local link_status="正常"
    
    # 检查 /usr/bin/python3 指向
    if [[ -L /usr/bin/python3 ]]; then
        local python3_target=$(readlink /usr/bin/python3)
        if [[ "$python3_target" == *"mise"* ]]; then
            status_info="系统链接被mise劫持"
            link_status="劫持"
        else
            status_info="使用系统Python链接"
        fi
    elif [[ -f /usr/bin/python3 ]]; then
        status_info="直接使用系统Python文件"
    else
        status_info="无python3链接"
        link_status="异常"
    fi
    
    # 检查 PATH 中的 python3 优先级
    local which_python=$(which python3 2>/dev/null || echo "")
    local path_status=""
    local path_priority="正常"
    
    if [[ "$which_python" == *"mise"* ]]; then
        path_status="PATH中mise Python优先"
        path_priority="劫持"
    elif [[ "$which_python" == "/usr/bin/python3" ]]; then
        path_status="PATH中系统Python优先"
    else
        path_status="PATH配置异常"
        path_priority="异常"
    fi
    
    log "🔍 当前Python状态:" "info"
    log "  系统链接: $status_info" "info"  
    log "  PATH优先: $path_status" "info"
    log "  当前版本: $(python3 --version 2>/dev/null || echo '无法获取')" "info"
    
    # 检查系统模块可用性
    if python3 -c "import apt_pkg" &>/dev/null; then
        log "  系统模块: apt_pkg 可用 ✓" "info"
    else
        log "  系统模块: apt_pkg 不可用 ✗" "warn"
    fi
    
    # 返回是否需要修复 (0=需要修复, 1=正常)
    if [[ "$link_status" == "劫持" || "$path_priority" == "劫持" ]] && [[ ! "$1" == "allow_global" ]]; then
        return 0  # 需要修复
    else
        return 1  # 状态正常
    fi
}

# 修复系统Python链接和PATH
fix_python_system_priority() {
    log "🔧 修复系统Python优先级..." "info"
    
    # 修复系统链接（如果被劫持）
    if [[ -L /usr/bin/python3 ]]; then
        local python3_target=$(readlink /usr/bin/python3)
        if [[ "$python3_target" == *"mise"* ]]; then
            log "修复被劫持的系统Python链接..." "info"
            sudo rm /usr/bin/python3 2>/dev/null || true
            
            # 寻找合适的系统Python版本
            if [[ -x /usr/bin/python3.11 ]]; then
                sudo ln -sf /usr/bin/python3.11 /usr/bin/python3
                log "✓ 已链接到系统Python 3.11" "info"
            elif [[ -x /usr/bin/python3.10 ]]; then
                sudo ln -sf /usr/bin/python3.10 /usr/bin/python3
                log "✓ 已链接到系统Python 3.10" "info"
            else
                log "✗ 未找到合适的系统Python版本" "error"
                return 1
            fi
        fi
    fi
    
    # 确保PATH顺序正确
    log "配置PATH优先级..." "info"
    configure_path_priority
}

# 配置PATH优先级
configure_path_priority() {
    local shells=("bash:$HOME/.bashrc" "zsh:$HOME/.zshrc")
    
    for shell_info in "${shells[@]}"; do
        local shell_name="${shell_info%%:*}"
        local config_file="${shell_info#*:}"
        
        if ! command -v "$shell_name" &>/dev/null; then
            continue
        fi
        
        [[ ! -f "$config_file" ]] && touch "$config_file"
        
        # 移除旧的PATH配置
        sed -i '/# Mise PATH priority/,/^$/d' "$config_file" 2>/dev/null || true
        sed -i '/# Mise global mode PATH/,/^$/d' "$config_file" 2>/dev/null || true
        
        # 添加新的PATH配置，确保系统路径优先
        cat >> "$config_file" << 'EOF'

# Mise PATH priority - 确保系统工具使用系统Python
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin"
EOF
        log "✓ 已配置 $shell_name PATH优先级" "info"
    done
}

# 配置全局模式的PATH
configure_path_for_global_mode() {
    log "配置全局模式PATH..." "info"
    local shells=("bash:$HOME/.bashrc" "zsh:$HOME/.zshrc")
    
    for shell_info in "${shells[@]}"; do
        local shell_name="${shell_info%%:*}"
        local config_file="${shell_info#*:}"
        
        if ! command -v "$shell_name" &>/dev/null; then
            continue
        fi
        
        [[ ! -f "$config_file" ]] && touch "$config_file"
        
        # 移除旧的PATH配置
        sed -i '/# Mise PATH priority/,/^$/d' "$config_file" 2>/dev/null || true
        sed -i '/# Mise global mode PATH/,/^$/d' "$config_file" 2>/dev/null || true
        
        # 为全局模式配置不同的PATH（mise优先）
        cat >> "$config_file" << 'EOF'

# Mise global mode PATH - mise Python 优先
export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
        log "✓ 已配置 $shell_name 全局模式PATH" "info"
    done
}

# 显示项目使用指南
show_project_usage_guide() {
    echo
    log "📝 项目级使用指南:" "info"
    log "  • 系统级: 自动使用系统Python ($(python3 --version 2>/dev/null || echo '获取失败'))" "info"
    log "  • 项目级: cd your_project && mise use python@3.12.11" "info"
    log "  • 临时使用: mise exec python@3.12.11 -- python script.py" "info"
    log "  • 查看当前: mise current python" "info"
    log "  • 全局设置: mise use -g python@3.12.11" "info"
}

# 确认全局替换
confirm_global_replacement() {
    echo
    log "⚠️  警告: 即将进行全局Python替换！" "warn"
    log "这会影响所有系统工具，包括apt、dpkg、apt-listchanges等" "warn"
    log "如果系统工具报错，你需要手动修复或重新运行此脚本" "warn"
    echo
    read -p "确认要继续吗? 强烈建议选择'N' [y/N]: " -r confirm_choice
    
    if [[ "$confirm_choice" =~ ^[Yy]$ ]]; then
        log "执行全局替换..." "info"
        link_python_globally_original "allow_global"
        configure_path_for_global_mode
        echo
        log "⚠️  重要提醒:" "warn"
        log "  如遇系统工具报错，重新运行此脚本选择'修复系统配置'" "warn"
    else
        log "✓ 明智的选择！改为使用项目级模式" "info"
        fix_python_system_priority
        show_project_usage_guide
    fi
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

# 原创建系统Python链接函数（重命名，仅在用户选择时调用）
link_python_globally_original() {
    log "创建系统Python链接..." "info"
    
    local python_path
    python_path=$("$MISE_PATH" which python 2>/dev/null || echo "")
    
    if [[ -x "$python_path" ]]; then
        # 备份现有系统Python链接
        if [[ -L /usr/bin/python3 ]]; then
            log "备份现有系统Python链接..." "info"
            sudo cp -L /usr/bin/python3 /usr/bin/python3.backup 2>/dev/null || true
        fi
        if [[ -e /usr/bin/python ]]; then
            sudo cp -L /usr/bin/python /usr/bin/python.backup 2>/dev/null || true
        fi
        
        log "创建 /usr/bin/python 链接..." "info"
        sudo ln -sf "$python_path" /usr/bin/python
        
        log "创建 /usr/bin/python3 链接..." "info"
        sudo ln -sf "$python_path" /usr/bin/python3
        
        log "✓ Python链接已创建" "info"
        log "  /usr/bin/python -> $python_path" "info"
        log "  /usr/bin/python3 -> $python_path" "info"
        
        # 如果有备份，提醒用户
        if [[ -f /usr/bin/python3.backup ]]; then
            log "💡 原系统Python已备份为 python3.backup" "info"
        fi
    else
        log "✗ 无法找到Mise管理的Python，跳过链接创建" "warn"
    fi
}

# 配置Python使用方式（改进版，包含智能检测和修复）
setup_python_usage() {
    log "配置 Python 使用方式..." "info"
    
    # 首先检测当前状态
    echo
    detect_python_status > /dev/null 2>&1 || true  # 静默运行避免错误
    local needs_fix=$?
    
    # 再次显示状态（这次显示输出）
    detect_python_status > /dev/null 2>&1 && echo "✓ 系统状态正常" || echo "⚠️ 检测到系统配置问题"
    
    echo
    echo "Python使用方式选择:"
    echo "  1) 仅项目级使用 (推荐)"
    echo "     - 系统工具使用系统Python，开发项目使用mise Python"
    echo "     - 自动修复PATH和链接问题，确保系统工具正常运行"
    echo
    echo "  2) 全局替换系统Python"
    echo "     - ⚠️  mise Python成为系统默认，可能影响apt等系统工具"
    echo "     - 适合高级用户，需要自行处理兼容性问题"
    echo
    
    if [[ $needs_fix -eq 0 ]]; then
        echo "  3) 修复系统Python配置"
        echo "     - 🔧 检测到系统被劫持，推荐选择此项立即修复"
        echo "     - 恢复系统工具的正常运行"
        echo
    fi
    
    local usage_choice
    local default_choice=1
    [[ $needs_fix -eq 0 ]] && default_choice=3
    
    local max_choice=2
    [[ $needs_fix -eq 0 ]] && max_choice=3
    
    read -p "请选择 [1-$max_choice] (默认: $default_choice): " -r usage_choice
    usage_choice=${usage_choice:-$default_choice}
    
    case "$usage_choice" in
        1)
            log "✓ 配置为项目级使用模式（推荐）" "info"
            fix_python_system_priority
            show_project_usage_guide
            ;;
        2)
            confirm_global_replacement
            ;;
        3)
            if [[ $needs_fix -eq 0 ]]; then
                log "🔧 执行系统修复..." "info"
                fix_python_system_priority
                log "✓ 系统Python配置已修复" "info"
                show_project_usage_guide
            else
                log "无效选择，使用项目级模式" "warn"
                fix_python_system_priority
                show_project_usage_guide
            fi
            ;;
        *)
            log "无效选择，使用项目级模式" "warn"
            fix_python_system_priority
            show_project_usage_guide
            ;;
    esac
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
            log "  ✓ Mise Python: $python_version (当前: $current_version)" "info"
        else
            log "  ✗ Mise Python: 未配置" "info"
        fi
        
        # 系统Python状态
        local system_python_version=$(/usr/bin/python3 --version 2>/dev/null || echo "无法获取")
        log "  ✓ 系统Python: $system_python_version" "info"
        
        # 检查系统链接状态
        if [[ -L /usr/bin/python3 ]]; then
            local python3_target=$(readlink /usr/bin/python3)
            if [[ "$python3_target" == *"mise"* ]]; then
                log "  🔗 系统链接: 链接到mise Python (全局模式)" "info"
            else
                log "  🔗 系统链接: 使用系统Python (推荐)" "info"
            fi
        fi
        
        # 检查PATH优先级
        local which_python=$(which python3 2>/dev/null)
        if [[ "$which_python" == *"mise"* ]]; then
            log "  🛤️  PATH优先: mise Python" "info"
        else
            log "  🛤️  PATH优先: 系统Python (推荐)" "info"
        fi
        
        # 全局工具列表
        local tools_count=$("$MISE_PATH" list 2>/dev/null | wc -l || echo "0")
        log "  📦 已安装工具: $tools_count 个" "info"
        
        # 系统模块状态
        if /usr/bin/python3 -c "import apt_pkg" &>/dev/null; then
            log "  🧩 系统模块: 正常可用 ✓" "info"
        else
            log "  🧩 系统模块: 可能有问题 ⚠️" "warn"
        fi
        
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
    
    # 显示当前状态（如果mise已安装）
    echo
    if [[ -f "$MISE_PATH" ]]; then
        log "检测到现有mise安装，正在分析系统状态..." "info"
        detect_python_status > /dev/null 2>&1 || true
    fi
    
    echo
    install_mise
    
    echo
    setup_python
    
    echo
    setup_python_usage  # 改进的函数，包含状态检测和修复
    
    echo
    configure_shell_integration
    
    show_mise_summary
    
    echo
    log "🎉 Mise 配置完成!" "info"
    log "💡 提示: 运行 'source ~/.bashrc' 或重新登录以激活配置" "info"
    
    # 显示有用的命令
    if [[ -f "$MISE_PATH" ]]; then
        echo
        log "常用命令:" "info"
        log "  查看工具: $MISE_PATH list" "info"
        log "  项目使用: $MISE_PATH use python@3.12.11" "info"
        log "  全局设置: $MISE_PATH use -g python@3.12.11" "info"
        log "  查看当前: $MISE_PATH current" "info"
        log "  查看帮助: $MISE_PATH --help" "info"
    fi
    
    # 显示重要提醒
    echo
    log "⚠️  重要提醒:" "warn"
    log "  • 如遇apt工具报错，重新运行此脚本选择'修复系统配置'" "info"
    log "  • 推荐使用项目级模式，避免影响系统工具" "info"
    log "  • 手动修复命令: export PATH=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$HOME/.local/bin\"" "info"
}

main "$@"
