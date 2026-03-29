#!/bin/bash

# Zsh Shell 环境配置模块 v5.2 - 性能优化版
# 功能: 安装配置Zsh + Oh My Zsh + Powerlevel10k + 常用插件

set -euo pipefail

# === 常量定义 ===
readonly ZSH_DIR="$HOME/.oh-my-zsh"
readonly CUSTOM_DIR="${ZSH_CUSTOM:-$ZSH_DIR/custom}"
readonly THEME_DIR="$CUSTOM_DIR/themes/powerlevel10k"
readonly PLUGINS_DIR="$CUSTOM_DIR/plugins"

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
backup_zshrc() {
  debug_log "备份.zshrc文件"
  if [[ -f "$HOME/.zshrc" ]] && [[ ! -f "$HOME/.zshrc.backup" ]]; then
    if cp "$HOME/.zshrc" "$HOME/.zshrc.backup" 2>/dev/null; then
      debug_log ".zshrc备份完成"
      return 0
    else
      log "备份.zshrc失败" "error"
      return 1
    fi
  fi
  debug_log ".zshrc备份检查完成"
  return 0
}

# === 核心功能函数 ===

install_components() {
  debug_log "开始安装组件"
  local components=()
  local errors=()

  # 检查并安装zsh
  if ! command -v zsh &>/dev/null; then
    debug_log "安装Zsh和Git"
    if apt install -y zsh git >/dev/null 2>&1; then
      components+=("Zsh")
      debug_log "Zsh安装成功"
    else
      errors+=("Zsh安装失败")
      debug_log "Zsh安装失败"
    fi
  else
    debug_log "Zsh已安装，跳过"
  fi

  # 安装Oh My Zsh
  if [[ ! -d "$ZSH_DIR" ]]; then
    debug_log "安装Oh My Zsh"
    if RUNZSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" < /dev/null >/dev/null 2>&1; then
      components+=("Oh-My-Zsh")
      debug_log "Oh My Zsh安装成功"
    else
      errors+=("Oh-My-Zsh安装失败")
      debug_log "Oh My Zsh安装失败"
    fi
  else
    debug_log "Oh My Zsh已安装，跳过"
  fi

  # 安装Powerlevel10k主题
  if [[ ! -d "$THEME_DIR" ]]; then
    debug_log "安装Powerlevel10k主题"
    if git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$THEME_DIR" >/dev/null 2>&1; then
      components+=("Powerlevel10k")
      debug_log "Powerlevel10k安装成功"
    else
      errors+=("Powerlevel10k主题安装失败")
      debug_log "Powerlevel10k安装失败"
    fi
  else
    debug_log "Powerlevel10k已安装，跳过"
  fi

  # 安装插件
  local new_plugins=0
  local failed_plugins=()

  if mkdir -p "$PLUGINS_DIR" 2>/dev/null; then
    debug_log "开始安装插件"

    local plugins=(
      "zsh-autosuggestions|https://github.com/zsh-users/zsh-autosuggestions"
      "zsh-syntax-highlighting|https://github.com/zsh-users/zsh-syntax-highlighting.git"
      "zsh-completions|https://github.com/zsh-users/zsh-completions"
    )

    for plugin_info in "${plugins[@]}"; do
      local plugin_name="${plugin_info%%|*}"
      local plugin_url="${plugin_info##*|}"

      if [[ ! -d "$PLUGINS_DIR/$plugin_name" ]]; then
        debug_log "安装插件: $plugin_name"
        if git clone "$plugin_url" "$PLUGINS_DIR/$plugin_name" >/dev/null 2>&1; then
          ((new_plugins++))
          debug_log "插件安装成功: $plugin_name"
        else
          failed_plugins+=("$plugin_name")
          debug_log "插件安装失败: $plugin_name"
        fi
      else
        debug_log "插件已安装，跳过: $plugin_name"
      fi
    done

    [[ $new_plugins -gt 0 ]] && components+=("${new_plugins}个插件")
    [[ ${#failed_plugins[@]} -gt 0 ]] && errors+=("插件失败: ${failed_plugins[*]}")
  else
    log "创建插件目录失败" "error"
    errors+=("插件目录创建失败")
  fi

  # 输出结果
  if (( ${#components[@]} > 0 )); then
    echo "安装组件: ${components[*]}"
  else
    echo "组件检查: 已是最新状态"
  fi

  if (( ${#errors[@]} > 0 )); then
    for error in "${errors[@]}"; do
      log "⚠️ $error" "warn"
    done
  fi

  return 0
}

# ============================================================
# 【主要改动】configure_zshrc — 更新为性能优化版 .zshrc
# ============================================================
configure_zshrc() {
  debug_log "开始配置.zshrc"

  if ! backup_zshrc; then
    return 1
  fi

  debug_log "写入.zshrc配置文件"
  if ! cat > "$HOME/.zshrc" << 'EOF'
# ============================================================
# 0. p10k Instant Prompt — 必须在最顶部，视觉接近 0 延迟
# ============================================================
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# ============================================================
# 1. Oh My Zsh 基础配置
# ============================================================
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"

# 禁用 compaudit 目录权限扫描（节省 ~19ms，个人服务器无实际风险）
export ZSH_DISABLE_COMPFIX="true"

# ============================================================
# 2. compinit 24h 缓存拦截器
# 必须在 source oh-my-zsh.sh 之前定义。
# OMZ 加载完所有插件（fpath 就绪）后才调用 compinit，届时触发此包装。
# 24h 内复用 .zcompdump，跳过全量扫描（节省 ~8ms/次）
# ============================================================
function compinit() {
  unfunction compinit            # 移除自身，防止递归
  autoload -Uz compinit          # 加载真正的 compinit
  local dump="${ZDOTDIR:-$HOME}/.zcompdump"
  local -a old_dump
  old_dump=($dump(Nmh+24))       # 文件超过 24h 则数组非空
  if [[ ! -f "$dump" ]] || (( ${#old_dump} )); then
    compinit "$@"                # 缓存过期：重新生成
  else
    compinit -C "$@"             # 缓存有效：跳过安全扫描直接加载
  fi
}

# ============================================================
# 3. OMZ 更新配置
# background = 后台检查并更新，不阻塞启动（节省 ~5ms）
# ============================================================
zstyle ':omz:update' mode background
zstyle ':omz:update' frequency 7

# ============================================================
# 4. 插件列表
# 已移除 command-not-found：Debian 原生 handler 足够，OMZ 层多余
# zsh-syntax-highlighting 必须保持最后一位
# ============================================================
plugins=(
  git
  sudo
  docker
  kubectl
  web-search
  history
  colored-man-pages
  zsh-completions
  zsh-autosuggestions
  zsh-syntax-highlighting
)

source $ZSH/oh-my-zsh.sh
# ⚠️ 不要在这里手动调用 compinit，OMZ 已在内部处理

# ============================================================
# 5. kubectl 懒加载
# kubectl completion zsh 每次都 fork 子进程，改为首次调用时才初始化
# ============================================================
function kubectl() {
  unfunction kubectl
  source <(command kubectl completion zsh)
  command kubectl "$@"
}

# ============================================================
# 6. PATH（统一定义，避免重复追加导致污染）
# ============================================================
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin"

# ============================================================
# 7. Mise 激活缓存
# eval "$(mise activate zsh)" 每次启动都 fork 子进程，耗时 ~20ms
# 改为将输出缓存到文件，直接 source（耗时降至 ~2ms）
# 触发重建：缓存不存在，或 mise 二进制比缓存文件更新
# ============================================================
if command -v mise &>/dev/null; then
  _mise_bin="$(command -v mise)"
  _mise_cache="${XDG_CACHE_HOME:-$HOME/.cache}/mise_activate.zsh"
  if [[ ! -f "$_mise_cache" ]] || [[ "$_mise_bin" -nt "$_mise_cache" ]]; then
    mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}"
    "$_mise_bin" activate zsh > "$_mise_cache"
  fi
  source "$_mise_cache"
  unset _mise_bin _mise_cache
fi

# ============================================================
# 8. Powerlevel10k 配置
# ============================================================
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# ============================================================
# 9. 别名
# ============================================================
alias upgrade='apt update && apt full-upgrade -y'
alias update='apt update -y'
alias reproxy='cd /root/proxy && docker compose down && docker compose pull && docker compose up -d --remove-orphans'
alias dlog='docker logs -f'
alias autodel='docker system prune -a -f && apt autoremove -y && apt clean'
alias sstop='systemctl stop'
alias sre='systemctl restart'
alias sst='systemctl status'
alias sdre='systemctl daemon-reload'
EOF
    log ".zshrc配置写入失败" "error"
    return 1
  fi

  # 强制转换为 Unix LF 格式，防止 CRLF 导致的 'n#' 错误
  if command -v sed &>/dev/null; then
    sed -i 's/\r//g' "$HOME/.zshrc" 2>/dev/null || true
    debug_log "强制 zshrc 文件为 Unix LF 格式"
  fi

  chmod 644 "$HOME/.zshrc" 2>/dev/null || true
  debug_log ".zshrc配置完成"
  return 0
}

# === 选择并配置主题 ===
setup_theme() {
  debug_log "开始主题选择"
  echo "主题选择:" >&2
  echo " 1) LucaLin (推荐) - 精心调配的个人主题" >&2
  echo " 2) Rainbow - 彩虹主题，丰富多彩" >&2
  echo " 3) Lean - 精简主题，简洁清爽" >&2
  echo " 4) Classic - 经典主题，传统外观" >&2
  echo " 5) Pure - 纯净主题，极简风格" >&2
  echo " 6) 配置向导 - 交互式配置，功能最全" >&2
  echo >&2

  local choice
  read -t 30 -p "请选择 [1-6] (默认1): " choice >&2 || choice=1
  choice=${choice:-1}

  debug_log "用户选择主题选项: $choice"

  case "$choice" in
    1)
      echo "主题: LucaLin (推荐配置)"
      debug_log "下载LucaLin主题配置"
      if curl -fsSL "https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/p10k-config.zsh" -o "$HOME/.p10k.zsh" 2>/dev/null; then
        debug_log "LucaLin主题下载成功"
      else
        echo "主题: 配置向导 (下载失败，首次启动时配置)"
        debug_log "LucaLin主题下载失败"
      fi
      ;;
    2)
      echo "主题: Rainbow (彩虹风格)"
      if curl -fsSL "https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-rainbow.zsh" -o "$HOME/.p10k.zsh" 2>/dev/null; then
        debug_log "Rainbow主题下载成功"
      else
        echo "主题: 配置向导 (下载失败，首次启动时配置)"
      fi
      ;;
    3)
      echo "主题: Lean (简洁风格)"
      if curl -fsSL "https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-lean.zsh" -o "$HOME/.p10k.zsh" 2>/dev/null; then
        debug_log "Lean主题下载成功"
      else
        echo "主题: 配置向导 (下载失败，首次启动时配置)"
      fi
      ;;
    4)
      echo "主题: Classic (经典风格)"
      if curl -fsSL "https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-classic.zsh" -o "$HOME/.p10k.zsh" 2>/dev/null; then
        debug_log "Classic主题下载成功"
      else
        echo "主题: 配置向导 (下载失败，首次启动时配置)"
      fi
      ;;
    5)
      echo "主题: Pure (极简风格)"
      if curl -fsSL "https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-pure.zsh" -o "$HOME/.p10k.zsh" 2>/dev/null; then
        debug_log "Pure主题下载成功"
      else
        echo "主题: 配置向导 (下载失败，首次启动时配置)"
      fi
      ;;
    6)
      echo "主题: 配置向导 (首次启动时配置)"
      debug_log "用户选择配置向导"
      ;;
    *)
      echo "主题: LucaLin (默认选择)"
      curl -fsSL "https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/p10k-config.zsh" -o "$HOME/.p10k.zsh" 2>/dev/null || {
        debug_log "默认主题下载失败"
      }
      ;;
  esac

  return 0
}

# === 设置默认Shell ===
setup_default_shell() {
  debug_log "设置默认Shell"
  local zsh_path

  if ! zsh_path=$(which zsh 2>/dev/null); then
    log "找不到zsh可执行文件" "error"
    return 1
  fi

  local current_shell=$(getent passwd root 2>/dev/null | cut -d: -f7 || echo "unknown")
  debug_log "当前Shell: $current_shell, Zsh路径: $zsh_path"

  if [[ "$current_shell" != "$zsh_path" ]]; then
    if chsh -s "$zsh_path" root 2>/dev/null; then
      echo "默认Shell: Zsh (重新登录生效)"
      debug_log "默认Shell设置成功"
    else
      log "设置默认Shell失败" "error"
      return 1
    fi
  else
    echo "默认Shell: 已是Zsh"
    debug_log "默认Shell已是Zsh"
  fi

  return 0
}

# === 主流程 ===
main() {
  log "🐚 配置Zsh环境..." "info"

  echo
  install_components || {
    log "组件安装出现问题，但继续执行" "warn"
  }

  echo
  if configure_zshrc; then
    echo "配置文件: .zshrc 已更新"
  else
    log "zshrc配置失败" "error"
    return 1
  fi

  echo
  setup_theme || {
    log "主题设置出现问题，但不影响主要功能" "warn"
  }

  echo
  setup_default_shell || {
    log "默认Shell设置失败" "warn"
  }

  echo
  log "✅ Zsh配置完成，运行 'exec zsh' 体验" "info"

  return 0
}

# 错误处理
trap 'echo "❌ Zsh配置脚本在第 $LINENO 行执行失败" >&2; exit 1' ERR

main "$@"
