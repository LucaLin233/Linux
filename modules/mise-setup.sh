#!/bin/bash  
# Mise 版本管理器配置模块 v6.1 - 优化版 (集成每周mise自动更新)
# 功能: 安装Mise、智能选择Python版本、Shell集成、系统修复  
  
set -euo pipefail  
  
# === 常量定义 ===  
readonly MISE_PATH="$HOME/.local/bin/mise"  
readonly MISE_BIN_DIR="$HOME/.local/bin"  
readonly MISE_CRON_COMMENT="# Mise Weekly Auto Update" # 新增Cron注释常量 
  
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
  
# 动态获取mise可执行路径  
get_mise_executable() {  
    local mise_candidates=(  
        "$(command -v mise 2>/dev/null || echo '')"  
        "$MISE_PATH"  
        "$HOME/.local/share/mise/bin/mise"  
        "/usr/local/bin/mise"  
    )  
      
    for path in "${mise_candidates[@]}"; do  
        if [[ -n "$path" && -x "$path" ]]; then  
            debug_log "找到可用mise: $path"  
            echo "$path"  
            return 0  
        fi  
    done  
      
    debug_log "未找到可用mise"  
    return 1  
}  
  
# 重新加载环境  
reload_environment() {  
    debug_log "重新加载环境"  
    export PATH="$MISE_BIN_DIR:$PATH"  
    hash -r 2>/dev/null || true  
      
    # 验证mise是否可以正常执行  
    local mise_cmd=""  
    if mise_cmd=$(get_mise_executable); then  
        if "$mise_cmd" --version >/dev/null 2>&1; then  
            debug_log "环境重新加载成功"  
            return 0  
        fi  
    fi  
    debug_log "环境重新加载失败"  
    return 1  
}  
  
# 诊断系统包管理状态  
diagnose_apt_system() {  
    debug_log "诊断APT系统状态"  
    local broken_packages=$(dpkg -l | grep -E '^[hi] [^i]|^.[^i]' | wc -l 2>/dev/null || echo "0")  
      
    if [[ "$broken_packages" -gt 0 ]]; then  
        debug_log "发现 $broken_packages 个损坏包"  
        return 1  
    fi  
      
    if [[ -f "/var/lib/dpkg/lock-frontend" ]] || [[ -f "/var/lib/apt/lists/lock" ]]; then  
        if lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || lsof /var/lib/apt/lists/lock >/dev/null 2>&1; then  
            debug_log "APT锁定文件被占用"  
            return 1  
        fi  
    fi  
      
    if ! which python3 &>/dev/null || [[ ! -x /usr/bin/python3 ]]; then  
        debug_log "系统Python3不可用"  
        return 1  
    fi  
      
    debug_log "APT系统状态正常"  
    return 0  
}  
  
# 修复dpkg状态  
fix_dpkg_state() {  
    debug_log "修复dpkg状态"  
    if timeout 30 sudo dpkg --configure -a >/dev/null 2>&1; then  
        debug_log "dpkg配置修复成功"  
        return 0  
    fi  
      
    if timeout 45 sudo DEBIAN_FRONTEND=noninteractive apt-get -f install -y >/dev/null 2>&1; then  
        debug_log "APT强制安装修复成功"  
        return 0  
    fi  
      
    debug_log "dpkg状态修复失败"  
    return 1  
}  
  
# 检测系统Python状态  
detect_system_python() {  
    debug_log "检测系统Python"  
    local system_python_paths=("/usr/bin/python3" "/usr/bin/python3.11" "/usr/bin/python3.10" "/usr/bin/python3.9" "/usr/bin/python3.12")  
      
    for python_path in "${system_python_paths[@]}"; do  
        if [[ -x "$python_path" ]]; then  
            debug_log "找到系统Python: $python_path"  
            echo "$python_path"  
            return 0  
        fi  
    done  
      
    debug_log "未找到可用的系统Python"  
    return 1  
}  
  
# 确保系统Python可用  
ensure_system_python() {  
    debug_log "确保系统Python可用"  
    local system_python=""  
    if system_python=$(detect_system_python); then  
        if [[ ! -e "/usr/bin/python3" ]] && [[ "$system_python" != "/usr/bin/python3" ]]; then  
            debug_log "创建系统Python链接: $system_python -> /usr/bin/python3"  
            sudo ln -sf "$system_python" /usr/bin/python3 2>/dev/null || {  
                debug_log "创建Python链接失败"  
                return 1  
            }  
        fi  
        debug_log "系统Python已确保可用"  
        return 0  
    else  
        debug_log "安装系统Python"  
        if command -v apt &>/dev/null; then  
            if timeout 120 sudo DEBIAN_FRONTEND=noninteractive apt update -qq && timeout 120 sudo DEBIAN_FRONTEND=noninteractive apt install -y python3 python3-apt python3-debconf >/dev/null 2>&1; then  
                debug_log "系统Python安装成功"  
                return 0  
            fi  
        fi  
        debug_log "系统Python安装失败"  
        return 1  
    fi  
}  
  
# 检测当前Python链接状态    
detect_python_status() {    
    debug_log "检测Python状态"    
    ensure_system_python || { debug_log "系统Python不可用"; return 1; }    
        
    local link_status="正常" path_priority="正常" is_hijacked=false    
    local needs_shell_fix=false # 引入一个标志来标记shell配置需要修复    
        
    # 检查系统链接是否被直接劫持    
    if [[ -L /usr/bin/python3 ]]; then    
        local python3_target=$(readlink /usr/bin/python3 2>/dev/null || echo "")    
        if [[ -n "$python3_target" && "$python3_target" == *"mise"* ]]; then    
            link_status="劫持"    
            is_hijacked=true    
            debug_log "检测到系统Python链接被劫持: $python3_target"    
        fi    
    fi    
  
    # 检查PATH优先级 (更保守地只检查启动文件)  
    local check_files=("$HOME/.bashrc" "$HOME/.zshrc")  
      
    for config_file in "${check_files[@]}"; do  
        if [[ -f "$config_file" ]]; then  
            # 查找是否有非 mise activate 导致的 PATH 劫持...  
            if grep -E 'export PATH="?([^"]*mise[^"]*):([^"]*)"?|mise use -g' "$config_file" /dev/null 2>&1; then  
                 # 排除安全的 PATH 配置行  
                if ! grep -q 'export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin"' "$config_file" 2>/dev/null; then  
                    path_priority="高优先级mise"  
                    needs_shell_fix=true  
                    debug_log "检测到启动文件 $config_file 中存在高优先级 mise 相关的 PATH 配置"  
                    break # 找到一处就足够了  
                fi  
            fi  
        fi  
    done  
      
    if $needs_shell_fix; then  
        is_hijacked=true  
    fi  
        
    # 核心修改点 1：将状态输出到 STDERR，保证在函数被重定向时依然显示
    echo "Python状态: 链接($link_status) PATH($path_priority)" >&2    
        
    # 只要检测到持久性劫持就返回0（需要修复）    
    if $is_hijacked; then    
        debug_log "Python状态需要修复"    
        return 0  # 需要修复  
    else    
        debug_log "Python状态正常"    
        return 1  # 状态正常    
    fi    
}
  
# 智能的系统模块修复  
fix_system_modules() {  
    debug_log "修复系统模块"  
    if /usr/bin/python3 -c "import apt_pkg; import debconf" >/dev/null 2>&1; then  
        debug_log "系统模块正常，无需修复"  
        return 0  
    fi  
      
    # 尝试修复系统状态  
    if ! diagnose_apt_system; then  
        debug_log "尝试修复dpkg状态"  
        fix_dpkg_state || true  
        /usr/bin/python3 -c "import apt_pkg; import debconf" >/dev/null 2>&1 && { debug_log "系统模块修复成功"; return 0; }  
    fi  
      
    # 重装系统模块  
    debug_log "重装系统模块"  
    sudo apt clean >/dev/null 2>&1 || true  
    if timeout 60 sudo DEBIAN_FRONTEND=noninteractive apt update >/dev/null 2>&1; then  
        timeout 60 sudo DEBIAN_FRONTEND=noninteractive apt install --reinstall -y python3-apt python3-debconf >/dev/null 2>&1 || {  
            debug_log "重装系统模块失败"  
            true  
        }  
    fi  
      
    # 强制重装python3包  
    debug_log "强制重装Python3包"  
    local python_packages=("python3-minimal" "python3" "python3-apt" "python3-debconf")  
    for pkg in "${python_packages[@]}"; do  
        timeout 30 sudo DEBIAN_FRONTEND=noninteractive apt install --reinstall -y "$pkg" >/dev/null 2>&1 || {  
            debug_log "重装 $pkg 失败"  
            true  
        }  
    done  
      
    if /usr/bin/python3 -c "import apt_pkg; import debconf" >/dev/null 2>&1; then  
        debug_log "系统模块完全修复成功"  
        return 0  
    else  
        echo "系统模块修复: 部分成功，不影响mise正常使用"  
        debug_log "系统模块部分修复成功"  
        return 1  
    fi  
}  
  
# 修复系统Python链接和PATH  
fix_python_system_priority() {  
    debug_log "修复系统Python优先级"  
    ensure_system_python || { log "✗ 无法确保系统Python可用" "error"; return 1; }  
      
    # 修复系统链接  
    if [[ -L /usr/bin/python3 ]]; then  
        local python3_target=$(readlink /usr/bin/python3 2>/dev/null || echo "")  
        if [[ -n "$python3_target" && "$python3_target" == *"mise"* ]]; then  
            debug_log "修复被劫持的系统Python链接"  
            sudo cp -L /usr/bin/python3 /usr/bin/python3.mise.backup 2>/dev/null || true  
            sudo rm /usr/bin/python3 2>/dev/null || true  
            local system_python=""  
            if system_python=$(detect_system_python); then  
                sudo ln -sf "$system_python" /usr/bin/python3 || {  
                    debug_log "重建Python链接失败"  
                    return 1  
                }  
            fi  
        fi  
    fi  
      
    # 修复PATH配置  
    debug_log "配置安全PATH优先级"  
    configure_safe_path_priority  
      
    # 立即应用修复  
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin"  
    hash -r 2>/dev/null || true  
      
    # 修复系统模块  
    fix_system_modules >/dev/null 2>&1 || true  
      
    echo "系统Python优先级: 已修复"  
    debug_log "系统Python优先级修复完成"  
}  
  
# 安全的PATH配置  
configure_safe_path_priority() {  
    debug_log "配置安全PATH优先级"  
    local shells=("bash:$HOME/.bashrc" "zsh:$HOME/.zshrc")  
      
    for shell_info in "${shells[@]}"; do  
        local shell_name="${shell_info%%:*}"  
        local config_file="${shell_info#*:}"  
          
        command -v "$shell_name" &>/dev/null || { debug_log "$shell_name 不存在，跳过配置"; continue; }  
          
        [[ ! -f "$config_file" ]] && touch "$config_file"  
        cp "$config_file" "${config_file}.mise.backup" 2>/dev/null || true  
          
        # 移除旧的PATH配置  
        sed -i '/# Mise PATH priority/,+1d' "$config_file" 2>/dev/null || true  
        sed -i '/# Mise global mode PATH/,+1d' "$config_file" 2>/dev/null || true  
          
        debug_log "为 $shell_name 配置安全PATH"  
        cat >> "$config_file" << 'EOF'  
# Mise PATH priority - 确保系统工具使用系统Python  
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin:$PATH" # $HOME/.local/bin 放在 PATH 末尾是安全的

EOF
    done  
}  
  
# 获取Mise版本  
get_mise_version() {  
    debug_log "获取Mise版本"  
    local mise_cmd=""  
    if ! mise_cmd=$(get_mise_executable); then  
        debug_log "无法找到mise可执行文件"  
        echo "未知"  
        return 1  
    fi  
      
    local version_output=$("$mise_cmd" --version 2>/dev/null || echo "")  
    if [[ "$version_output" =~ v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then  
        debug_log "Mise版本: ${BASH_REMATCH[1]}"  
        echo "${BASH_REMATCH[1]}"  
    else  
        debug_log "无法获取Mise版本"  
        echo "未知"  
    fi  
}  
  
# 获取已安装的Python版本列表  
get_installed_python_versions() {  
    debug_log "获取已安装Python版本"  
    local mise_cmd=""  
    mise_cmd=$(get_mise_executable) || { debug_log "无法找到mise，返回空版本列表"; return 0; }  
    "$mise_cmd" ls python 2>/dev/null | awk '/^python/ {print $2}' | grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" 2>/dev/null || true  
}  
  
# === 核心功能函数 (安装/配置) ===  
  
# 安装或更新Mise  
install_mise() {  
    debug_log "开始安装或更新Mise"  
    mkdir -p "$MISE_BIN_DIR" || { log "创建Mise目录失败" "error"; return 1; }  
      
    if [[ -f "$MISE_PATH" ]] || command -v mise &>/dev/null; then  
        local old_version=$(get_mise_version)  
        echo "Mise状态: 已安装 v$old_version"  
          
        read -p "是否更新到最新版本? [y/N]: " -r update_choice  
        if [[ "$update_choice" =~ ^[Yy]$ ]]; then  
            debug_log "更新Mise到最新版本"  
            if curl -fsSL https://mise.run | sh >/dev/null 2>&1; then  
                reload_environment  
                local new_version=$(get_mise_version)  
                if [[ "$new_version" != "$old_version" ]]; then  
                    echo "Mise更新: 成功 v$old_version -> v$new_version"  
                    debug_log "Mise更新成功: $old_version -> $new_version"  
                else  
                    echo "Mise更新: 已是最新版本 v$new_version"  
                    debug_log "Mise已是最新版本"  
                fi  
            else  
                echo "Mise更新: 失败，继续使用现有版本 v$old_version"  
                debug_log "Mise更新失败"  
            fi  
        else  
            debug_log "用户选择不更新Mise"  
        fi  
    else  
        echo "安装Mise中..."  
        debug_log "首次安装Mise"  
        if curl -fsSL https://mise.run | sh >/dev/null 2>&1; then  
            reload_environment  
            local version=$(get_mise_version)  
            echo "Mise安装: 成功 v$version"  
            debug_log "Mise安装成功"  
        else  
            log "✗ Mise安装失败" "error"  
            debug_log "Mise安装失败"  
            exit 1  
        fi  
    fi  
      
    # 验证安装  
    debug_log "验证Mise安装"  
    local actual_mise_path=""  
    if actual_mise_path=$(get_mise_executable); then  
        echo "Mise验证: 成功 (路径: $actual_mise_path)"  
        debug_log "Mise验证成功，路径: $actual_mise_path"  
    else  
        log "✗ 安装验证失败" "error"  
        debug_log "验证失败"  
        return 1  
    fi  
      
    debug_log "Mise安装验证完成"  
    return 0  
}  
  
# 简化的Python版本选择  
choose_python_version() {  
    debug_log "Python版本选择"  
      
    local mise_cmd=""  
    if ! mise_cmd=$(get_mise_executable); then  
        echo "3.12.4"  # fallback  
        return  
    fi  
      
    local latest_version=$("$mise_cmd" latest python 2>/dev/null || echo "3.12.4")  
      
    echo >&2  
    echo "Python版本选择:" >&2  
    echo "  1) 安装最新版本 (Python $latest_version)" >&2  
    echo "  2) 手动输入版本号" >&2  
    echo "  3) 保持当前配置 - 推荐" >&2  
    echo >&2  
      
    local choice=""  
    read -p "请选择 [1-3] (默认: 3): " choice >&2  
    choice=${choice:-3}  
      
    case "$choice" in  
        1)   
            debug_log "选择最新版本: $latest_version"  
            echo "$latest_version"  
            ;;  
        2)  
            local custom_version=""  
            read -p "请输入Python版本号 (如 3.11.9): " custom_version >&2  
            if [[ "$custom_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then  
                debug_log "用户输入版本: $custom_version"  
                echo "$custom_version"  
            else  
                echo "版本号格式错误，使用最新版本: $latest_version" >&2  
                debug_log "版本号格式错误，使用最新版本"  
                echo "$latest_version"  
            fi  
            ;;  
        3)   
            debug_log "保持当前配置"  
            echo "current"  
            ;;  
        *)   
            debug_log "无效选择，保持当前配置"  
            echo "current"  
            ;;  
    esac  
}  
  
# 清理旧版本Python  
cleanup_old_python_versions() {  
    local current_version="$1"  
    debug_log "清理旧Python版本，当前版本: $current_version"  
    local installed_versions=$(get_installed_python_versions)  
    [[ -n "$installed_versions" ]] && installed_versions=$(echo "$installed_versions" | grep -v "^$current_version$" || true)  
      
    if [[ -n "$installed_versions" ]]; then  
        echo  
        echo "检测到其他Python版本:"  
        echo "$installed_versions" | sed 's/^/  - Python /'  
          
        read -p "是否删除其他版本? [y/N]: " -r cleanup_choice  
        if [[ "$cleanup_choice" =~ ^[Yy]$ ]]; then  
            debug_log "用户选择删除其他Python版本"  
            local mise_cmd=""  
            if mise_cmd=$(get_mise_executable); then  
                while IFS= read -r version; do  
                    if [[ -n "$version" ]]; then  
                        debug_log "删除Python版本: $version"  
                        if "$mise_cmd" uninstall "python@$version" >/dev/null 2>&1; then  
                            echo "Python $version: 已删除"  
                            debug_log "Python $version 删除成功"  
                        else  
                            echo "Python $version: 删除失败"  
                            debug_log "Python $version 删除失败"  
                        fi  
                    fi  
                done <<< "$installed_versions"  
            fi  
        else  
            debug_log "用户选择保留其他Python版本"  
        fi  
    else  
        debug_log "未发现其他Python版本"  
    fi  
}  
  
# 配置Python  
setup_python() {  
    debug_log "开始配置Python"  
    local mise_cmd=""  
    mise_cmd=$(get_mise_executable) || { log "✗ 找不到mise可执行文件" "error"; return 1; }  
      
    # 检查并显示当前Python版本（只显示一次）  
    local current_version=$("$mise_cmd" current python 2>/dev/null || echo "")  
    if [[ -n "$current_version" ]]; then  
        echo "当前Python: $current_version"  
    else  
        echo "当前Python: 未配置"  
    fi  
      
    local selected_version=$(choose_python_version)  
      
    # 正确处理"current"选择  
    if [[ "$selected_version" == "current" ]]; then  
        echo "Python配置: 保持当前"  
        debug_log "保持当前Python配置"  
        return 0  
    fi  
      
    echo "安装Python $selected_version..."  
    debug_log "安装Python版本: $selected_version"  
    if "$mise_cmd" use -g "python@$selected_version" >/dev/null 2>&1; then  
        echo "Python $selected_version: 安装成功"  
        debug_log "Python $selected_version 安装成功"  
        cleanup_old_python_versions "$selected_version"  
        return 0  
    else  
        log "✗ Python $selected_version 安装失败" "error"  
        debug_log "Python $selected_version 安装失败"  
        return 1  
    fi  
}  
  
# 简化的项目级使用配置  
setup_python_usage() {  
    debug_log "配置项目级Python使用"  
      
    # 直接配置为项目级使用  
    configure_safe_path_priority  
      
    # 核心修改点 2：在检测前刷新环境，确保 which 识别最新的 PATH/mise 配置
    export PATH="$MISE_BIN_DIR:$PATH"
    hash -r 2>/dev/null || true
      
    # 检测是否需要修复  
    # 移除非必要的 >/dev/null 2>&1，让 detect_python_status 的诊断信息正常显示 (因为它也是输出到 STDERR 的)
    if detect_python_status; then  
        echo  
        log "⚠️ 检测到系统Python被劫持" "warn"  
        read -p "是否立即修复系统配置? [Y/n]: " -r fix_choice  
          
        if [[ "$fix_choice" =~ ^[Nn]$ ]]; then  
            log "跳过修复，可能影响系统工具正常使用" "warn"  
        else  
            echo "修复系统配置中..."  
            fix_python_system_priority  
        fi  
    fi  
      
    # 动态生成使用指南  
    local mise_cmd=""  
    local example_version="3.12.4"  # 默认示例版本  
      
    if mise_cmd=$(get_mise_executable); then  
        local current_version=$("$mise_cmd" current python 2>/dev/null || echo "")  
        if [[ -n "$current_version" && "$current_version" != "未配置" ]]; then  
            example_version="$current_version"  
        else  
            local latest_version=$("$mise_cmd" latest python 2>/dev/null || echo "")  
            [[ -n "$latest_version" && "$latest_version" != "未知" ]] && example_version="$latest_version"  
        fi  
    fi  
      
    echo  
    echo "使用指南:"  
    echo "  • 系统级: 自动使用系统Python"  
    echo "  • 项目级: cd project && mise use python@$example_version"  
    echo "  • 临时使用: mise exec python@$example_version -- python script.py"  
      
    return 0  
}  
  
# 配置Shell集成  
configure_shell_integration() {  
    debug_log "配置Shell集成"  
    local mise_cmd=""
    mise_cmd=$(get_mise_executable) || { debug_log "找不到mise可执行文件，跳过Shell集成"; return 1; }  
    
    # 使用 mise full-path 来确保路径是准确的，特别是对于 Zsh
    local mise_activate_path="$mise_cmd" 
    local shells=("bash:$HOME/.bashrc:$mise_activate_path activate bash" "zsh:$HOME/.zshrc:$mise_activate_path activate zsh") 
    local integration_success=true  
      
    for shell_info in "${shells[@]}"; do  
        local shell_name="${shell_info%%:*}"  
        local config_file_cmd="${shell_info#*:}"
        local config_file="${config_file_cmd%%:*}"
        local activate_cmd="eval \"\$($config_file_cmd)\""
          
        command -v "$shell_name" &>/dev/null || { debug_log "$shell_name 不存在，跳过配置"; continue; }  
          
        [[ ! -f "$config_file" ]] && touch "$config_file"  
          
        # 检查集成是否已存在  
        if grep -q "mise activate $shell_name" "$config_file" 2>/dev/null; then  
            echo "$shell_name集成: 已存在"  
            debug_log "$shell_name 集成已存在"  
        else  
            debug_log "为 $shell_name 配置集成"  
            local append_content="\n# Mise version manager\n$activate_cmd"

            # 尝试找到第一个 export PATH 语句后插入，如果找不到则追加
            if grep -q "export PATH" "$config_file" 2>/dev/null; then
                # 在第一个 export PATH 后新增
                sed -i "/export PATH/a $append_content" "$config_file" 2>/dev/null || \
                echo -e "$append_content" >> "$config_file"
            else
                echo -e "$append_content" >> "$config_file"
            fi

            if [[ $? -eq 0 ]]; then
                echo "$shell_name集成: 已配置"  
                debug_log "$shell_name 集成配置完成"  
            else
                echo "$shell_name集成: 配置失败"
                integration_success=false
            fi
        fi  
    done  
      
    if $integration_success; then  
        debug_log "Shell集成配置完成"  
        return 0  
    else  
        debug_log "Shell集成配置部分失败"  
        return 1  
    fi  
}  

# 新增的函数：配置 mise 每周自动更新的 Crontab 任务
configure_mise_cron() {
    debug_log "配置Mise每周日凌晨1点自动更新"
    
    if ! command -v crontab &>/dev/null; then
        log "✗ 找不到 'crontab' 命令，跳过自动更新配置" "warn"
        return 1
    fi

    # 每周日 (0) 凌晨 1 点 (1) 执行更新命令
    local cron_schedule="0 1 * * 0"
    # 使用绝对路径的 curl 和 sh，并加 -y 参数确保静默更新
    local update_command="/usr/bin/curl -fsSL https://mise.run | /bin/sh -s -- -y >/dev/null 2>&1"
    local job_entry="$cron_schedule $update_command $MISE_CRON_COMMENT"

    # 临时文件来操作 crontab
    local temp_cron
    if ! temp_cron=$(mktemp); then
        debug_log "无法创建临时Cron文件"
        log "✗ Crontab配置失败 (无法创建临时文件)" "error"
        return 1
    fi
    
    # 清理旧的 mise 自动更新任务行，然后添加新的
    (crontab -l 2>/dev/null | grep -v 'Mise Weekly Auto Update' || true; echo "$job_entry") > "$temp_cron"

    if crontab "$temp_cron"; then
        echo "Mise定时更新: 已配置 (每周日 1:00 AM)"
        debug_log "Crontab配置成功: $job_entry"
        rm -f "$temp_cron"
        return 0
    else
        log "✗ Crontab配置失败 (crontab命令失败)" "error"
        rm -f "$temp_cron"
        return 1
    fi
}
  
# 显示配置摘要  
show_mise_summary() {  
    debug_log "显示配置摘要"  
    echo  
    log "🎯 Mise配置摘要:" "info"  
      
    local mise_cmd=""  
    if mise_cmd=$(get_mise_executable); then  
        local mise_version=$(get_mise_version)  
        echo "  Mise: v$mise_version"  
          
        if "$mise_cmd" which python &>/dev/null; then  
            local current_version=$("$mise_cmd" current python 2>/dev/null || echo "未知")  
            echo "  Mise Python: $current_version"  
        else  
            echo "  Mise Python: 未配置"  
        fi  
          
        # 使用系统Python检查版本  
        # 刷新环境，以防其他函数依赖旧的 PATH/hash
        export PATH="$MISE_BIN_DIR:$PATH"
        hash -r 2>/dev/null || true
        local system_python_version=$(/usr/bin/python3 --version 2>/dev/null || echo "无法获取")  
        echo "  系统Python: $system_python_version"  
          
        # 检查当前优先级  
        local which_python=$(which python3 2>/dev/null || echo "")  
        local system_python_path=$(PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" which python3 2>/dev/null || echo "")  
          
        if [[ "$which_python" == *"mise"* ]]; then  
            if [[ "$which_python" != "$system_python_path" ]]; then  
                echo "  当前优先: mise Python (需要修复)"  
            else  
                echo "  当前优先: mise Python"  
            fi  
        elif [[ "$which_python" == "/usr/bin/python3" ]] || [[ "$which_python" == "$system_python_path" ]]; then  
            echo "  当前优先: 系统Python"  
        else  
            echo "  当前优先: 异常状态 ($which_python)"  
        fi  
          
        # 使用系统Python检查系统模块  
        local apt_pkg_ok=false debconf_ok=false  
        /usr/bin/python3 -c "import apt_pkg" &>/dev/null 2>&1 && apt_pkg_ok=true  
        /usr/bin/python3 -c "import debconf" &>/dev/null 2>&1 && debconf_ok=true  
          
        if $apt_pkg_ok && $debconf_ok; then  
            echo "  系统模块: 正常"  
        else  
            echo "  系统模块: 部分异常 (不影响mise使用)"  
            debug_log "系统模块检查失败: apt_pkg=$apt_pkg_ok, debconf=$debconf_ok"  
        fi  
    else  
        echo "  Mise: 未安装"  
    fi  
      
    grep -q "mise activate" "$HOME/.bashrc" 2>/dev/null && echo "  Bash集成: 已配置"  
    [[ -f "$HOME/.zshrc" ]] && grep -q "mise activate" "$HOME/.zshrc" 2>/dev/null && echo "  Zsh集成: 已配置"  
    
    # 检查Crontab摘要
    if command -v crontab &>/dev/null && crontab -l 2>/dev/null | grep -q "$MISE_CRON_COMMENT"; then
        echo "  自动更新: 已配置 (每周日 1:00 AM)"
    else
        echo "  自动更新: 未配置"
    fi
    
    return 0  
}  
  
# === 主流程 ===  
main() {  
    log "🔧 配置Mise版本管理器..." "info"  
      
    echo  
    # 核心修改点 3：移除冗余且带重定向的调用
    # get_mise_executable >/dev/null 2>&1 && detect_python_status >/dev/null 2>&1 || true 
      
    install_mise || exit 1  
      
    echo  
    setup_python || { echo "Python配置失败，但继续执行..."; debug_log "Python配置失败，继续执行" || echo "debug_log失败但继续" >&2; }  
      
    setup_python_usage || { echo "Python使用方式配置失败，使用默认配置"; debug_log "setup_python_usage失败" || true; }  
      
    echo  
    configure_shell_integration || { echo "Shell集成配置失败"; debug_log "configure_shell_integration失败"; }  
    
    # 新增的 Mise Crontab 自动更新配置
    echo
    configure_mise_cron || { echo "Mise定时更新配置失败"; debug_log "configure_mise_cron失败"; } 
      
    show_mise_summary || { echo "显示摘要失败"; debug_log "show_mise_summary失败"; }  
      
    echo  
    log "✅ Mise配置完成!" "info"  
    log "提示: 运行 'source ~/.bashrc' 或重新登录激活" "info"  
      
    return 0  
}  
  
# 错误处理  
trap 'log "脚本执行出错，行号: $LINENO" "error"; exit 1' ERR  
  
main "$@"
