#!/usr/bin/env bash
# Cloudflare Tunnel manager for Debian/Ubuntu.
# Uses Cloudflare's official stable APT repository and service command.

# Sourcing exposes no legacy global function API. Internal tests opt in explicitly.
if [[ "${BASH_SOURCE[0]:-$0}" != "$0" && "${CLOUDFLARED_TEST_INTERNALS:-}" != 1 ]]; then
    return 0
fi

init_runtime_config() {
    KEYRING="${CLOUDFLARED_KEYRING:-/usr/share/keyrings/cloudflare-main.gpg}"
    SOURCE_FILE="${CLOUDFLARED_SOURCE_FILE:-/etc/apt/sources.list.d/cloudflared.list}"
    STATE_DIR="${CLOUDFLARED_STATE_DIR:-/var/lib/cloudflared-wrapper}"
    KEY_URL="https://pkg.cloudflare.com/cloudflare-main.gpg"
    REPOSITORY="https://pkg.cloudflare.com/cloudflare-main.gpg"
    KEY_FINGERPRINT="CC94B39C77AE7342A68B89628A682D308D4E5E73"
    KEY_UID="CloudFlare Software Packaging 2025 <help@cloudflare.com>"
    REPOSITORY_STATE_DIR="${CLOUDFLARED_REPOSITORY_STATE_DIR:-$STATE_DIR/repository}"
    REPOSITORY_LOCK_DIR="${CLOUDFLARED_REPOSITORY_LOCK_DIR:-$STATE_DIR.lock}"
    TRUST_ANCHOR="${CLOUDFLARED_TRUST_ANCHOR:-/}"
    APT_SOURCE_ROOT="${CLOUDFLARED_APT_SOURCE_ROOT:-/etc/apt}"
    LEGACY_BIN="${CLOUDFLARED_LEGACY_BIN:-/usr/local/bin/cloudflared}"
    APT_BIN="${CLOUDFLARED_APT_BIN:-/usr/bin/cloudflared}"
    LEGACY_UPDATER="${CLOUDFLARED_LEGACY_UPDATER:-/usr/local/bin/cloudflared-update}"
    LEGACY_SERVICE="${CLOUDFLARED_LEGACY_SERVICE:-/etc/systemd/system/cloudflared-updater.service}"
    LEGACY_TIMER="${CLOUDFLARED_LEGACY_TIMER:-/etc/systemd/system/cloudflared-updater.timer}"
    AUTO_UPDATE_SCRIPT="${CLOUDFLARED_AUTO_UPDATE_SCRIPT:-/usr/local/libexec/cloudflared-apt-update}"
    AUTO_UPDATE_SERVICE="${CLOUDFLARED_AUTO_UPDATE_SERVICE:-/etc/systemd/system/cloudflared-apt-update.service}"
    AUTO_UPDATE_TIMER="${CLOUDFLARED_AUTO_UPDATE_TIMER:-/etc/systemd/system/cloudflared-apt-update.timer}"
    SERVICE_FILE="${CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}"
    BINARY_UPDATE_SERVICE="${CLOUDFLARED_BINARY_UPDATE_SERVICE:-/etc/systemd/system/cloudflared-update.service}"
    BINARY_UPDATE_TIMER="${CLOUDFLARED_BINARY_UPDATE_TIMER:-/etc/systemd/system/cloudflared-update.timer}"
    PRESERVE_AUTO_UPDATE=false
}

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
error() { printf '[ERROR] %s\n' "$*" >&2; }

require_root() {
    (( EUID == 0 )) || { error "需要 root 权限"; exit 1; }
}

check_platform() {
    [[ -r /etc/os-release ]] || { error "无法读取 /etc/os-release"; return 1; }
    . /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) ;;
        *) error "仅支持 Debian/Ubuntu，当前系统: ${PRETTY_NAME:-unknown}"; return 1 ;;
    esac
    [[ -d /run/systemd/system ]] || { error "当前环境未运行 systemd"; return 1; }
    command -v apt-get >/dev/null || { error "缺少 apt-get"; return 1; }
    command -v systemctl >/dev/null || { error "缺少 systemctl"; return 1; }
}

confirm() {
    local prompt="$1" answer
    [[ -t 0 ]] || return 1
    read -r -p "$prompt [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

backup_path() {
    local path="$1" backup_dir="$2"
    [[ -e "$path" || -L "$path" ]] || return 0
    install -d -m 0700 "$backup_dir"
    cp -a "$path" "$backup_dir/$(basename "$path")"
}


repository_source_content() {
    init_runtime_config
    printf 'deb [signed-by=%s] %s any main\n' "$KEYRING" "$REPOSITORY"
}

repository_legacy_source_content() {
    init_runtime_config
    cat <<EOF
# Managed by tools/cloudflare_tunnel.sh
# Cloudflare stable repository for Debian-based distributions.
deb [signed-by=$KEYRING] https://pkg.cloudflare.com/cloudflared any main
EOF
}

path_is_beneath_anchor() {
    init_runtime_config
    local path anchor
    path=$(realpath -ms -- "$1") || return 1
    anchor=$(realpath -ms -- "$TRUST_ANCHOR") || return 1
    [[ "$path" == "$anchor" || "$path" == "$anchor"/* ]]
}

validate_directory_chain() {
    init_runtime_config
    local path="$1" current anchor mode owner group
    path_is_beneath_anchor "$path" || { error "路径越过信任根: $path"; return 1; }
    current=$(realpath -ms -- "$path") || return 1
    anchor=$(realpath -ms -- "$TRUST_ANCHOR") || return 1
    while :; do
        [[ -d "$current" && ! -L "$current" ]] || {
            error "目录祖先不是非符号链接目录: $current"
            return 1
        }
        read -r owner group mode < <(stat -Lc '%u %g %a' -- "$current") || return 1
        [[ "$owner" == 0 && "$group" == 0 ]] || {
            error "目录祖先 owner/GID 非 0:0: $current"
            return 1
        }
        (( (8#$mode & 0022) == 0 )) || {
            error "目录祖先可被 group/other 写入: $current ($mode)"
            return 1
        }
        [[ "$current" == "$anchor" ]] && break
        current=$(dirname -- "$current")
    done
}

validate_secure_directory() {
    init_runtime_config
    local path="$1" expected_mode="$2" metadata
    [[ -d "$path" && ! -L "$path" ]] || {
        error "要求非符号链接目录: $path"
        return 1
    }
    metadata=$(stat -Lc '%u:%g:%a' -- "$path") || return 1
    [[ "$metadata" == "0:0:$expected_mode" ]] || {
        error "目录元数据错误: $path ($metadata，期望 0:0:$expected_mode)"
        return 1
    }
}

validate_secure_file() {
    init_runtime_config
    local path="$1" expected_mode="$2" metadata
    [[ -f "$path" && ! -L "$path" ]] || {
        error "要求非符号链接普通文件: $path"
        return 1
    }
    metadata=$(stat -Lc '%u:%g:%a' -- "$path") || return 1
    [[ "$metadata" == "0:0:$expected_mode" ]] || {
        error "文件元数据错误: $path ($metadata，期望 0:0:$expected_mode)"
        return 1
    }
}

validate_existing_repository_file() {
    init_runtime_config
    local path="$1"
    [[ -e "$path" || -L "$path" ]] || return 0
    validate_secure_file "$path" 644
}

validate_existing_source() {
    init_runtime_config
    local expected legacy candidate
    [[ -d "$APT_SOURCE_ROOT" && ! -L "$APT_SOURCE_ROOT" ]] || {
        error "APT source 根必须是非符号链接目录: $APT_SOURCE_ROOT"
        return 1
    }
    path_is_beneath_anchor "$APT_SOURCE_ROOT" || {
        error "APT source 根越过信任根: $APT_SOURCE_ROOT"
        return 1
    }
    path_is_beneath_anchor "$SOURCE_FILE" || return 1
    [[ "$(realpath -ms -- "$SOURCE_FILE")" == "$(realpath -ms -- "$APT_SOURCE_ROOT")"/* ]] || {
        error "Cloudflare source 文件不在 APT source 根内"
        return 1
    }
    validate_directory_chain "$APT_SOURCE_ROOT" || return 1
    while IFS= read -r -d '' candidate; do
        [[ "$candidate" == "$SOURCE_FILE" ]] && continue
        validate_secure_file "$candidate" 644 || {
            error "额外 APT source 类型或元数据不可信: $candidate"
            return 1
        }
        if grep -Eqs 'pkg\.cloudflare\.com/(cloudflare-main\.gpg|cloudflared)([[:space:]/]|$)' -- "$candidate"; then
            error "发现额外或重复 Cloudflare APT source: $candidate"
            return 1
        fi
    done < <(find "$APT_SOURCE_ROOT" -maxdepth 2 \
        \( -path "$APT_SOURCE_ROOT/sources.list" -o -path "$APT_SOURCE_ROOT/sources.list.d/*.list" -o -path "$APT_SOURCE_ROOT/sources.list.d/*.sources" \) \
        \( -type f -o -type l \) -print0 2>/dev/null)
    [[ -e "$SOURCE_FILE" || -L "$SOURCE_FILE" ]] || return 0
    validate_secure_file "$SOURCE_FILE" 644 || return 1
    expected=$(repository_source_content)
    legacy=$(repository_legacy_source_content)
    if [[ "$(cat -- "$SOURCE_FILE")" != "$expected" && "$(cat -- "$SOURCE_FILE")" != "$legacy" ]]; then
        error "现有软件源不是精确官方配置或受支持旧配置，拒绝覆盖: $SOURCE_FILE"
        return 1
    fi
}

validate_repository_state_entries() {
    init_runtime_config
    local entry base
    shopt -s nullglob
    for entry in "$REPOSITORY_STATE_DIR"/*; do
        base=$(basename -- "$entry")
        case "$base" in
            current)
                validate_secure_file "$entry" 600 || return 1
                ;;
            history-*|failure-*)
                validate_secure_directory "$entry" 700 || return 1
                find "$entry" -mindepth 1 -type l -print -quit | grep -q . && {
                    error "事务证据目录包含符号链接: $entry"
                    return 1
                }
                while IFS= read -r -d '' evidence; do
                    validate_secure_file "$evidence" 600 || return 1
                done < <(find "$entry" -mindepth 1 -maxdepth 1 -type f -print0)
                find "$entry" -mindepth 1 -maxdepth 1 ! -type f -print -quit | grep -q . && {
                    error "事务证据目录包含未知类型: $entry"
                    return 1
                }
                ;;
            lock)
                error "另一个 Cloudflare 仓库事务正在运行，或存在待人工审查的锁: $entry"
                return 1
                ;;
            *)
                error "Cloudflare 仓库状态目录包含陌生残留: $entry"
                return 1
                ;;
        esac
    done
    shopt -u nullglob
}

prepare_repository_state() {
    init_runtime_config
    local state_parent repository_parent
    state_parent=$(dirname -- "$STATE_DIR")
    repository_parent=$(dirname -- "$REPOSITORY_STATE_DIR")
    validate_directory_chain "$state_parent" || return 1
    if [[ ! -e "$STATE_DIR" && ! -L "$STATE_DIR" ]]; then
        install -d -o 0 -g 0 -m 0700 -- "$STATE_DIR" || return 1
    fi
    validate_secure_directory "$STATE_DIR" 700 || return 1
    [[ "$repository_parent" == "$STATE_DIR" ]] || {
        error "仓库状态目录必须直接位于状态目录内"
        return 1
    }
    if [[ ! -e "$REPOSITORY_STATE_DIR" && ! -L "$REPOSITORY_STATE_DIR" ]]; then
        install -d -o 0 -g 0 -m 0700 -- "$REPOSITORY_STATE_DIR" || return 1
    fi
    validate_secure_directory "$REPOSITORY_STATE_DIR" 700 || return 1
    validate_repository_state_entries
}

acquire_repository_lock() {
    init_runtime_config
    validate_directory_chain "$(dirname -- "$REPOSITORY_LOCK_DIR")" || return 1
    if ! mkdir -m 0700 -- "$REPOSITORY_LOCK_DIR" 2>/dev/null; then
        error "无法取得 Cloudflare 仓库事务锁: $REPOSITORY_LOCK_DIR"
        return 1
    fi
    if ! validate_secure_directory "$REPOSITORY_LOCK_DIR" 700; then
        rmdir -- "$REPOSITORY_LOCK_DIR" 2>/dev/null || true
        return 1
    fi
}

save_repository_traps() {
    REPOSITORY_PREVIOUS_HUP_TRAP=$(trap -p HUP || true)
    REPOSITORY_PREVIOUS_INT_TRAP=$(trap -p INT || true)
    REPOSITORY_PREVIOUS_TERM_TRAP=$(trap -p TERM || true)
    REPOSITORY_PREVIOUS_EXIT_TRAP=$(trap -p EXIT || true)
    trap 'repository_signal_handler 129 HUP' HUP
    trap 'repository_signal_handler 130 INT' INT
    trap 'repository_signal_handler 143 TERM' TERM
    trap 'repository_exit_handler $?' EXIT
}

restore_one_trap() {
    local signal="$1" saved="$2"
    trap - "$signal"
    if [[ -n "$saved" ]]; then
        eval "$saved"
    fi
}

restore_repository_traps() {
    restore_one_trap HUP "$REPOSITORY_PREVIOUS_HUP_TRAP"
    restore_one_trap INT "$REPOSITORY_PREVIOUS_INT_TRAP"
    restore_one_trap TERM "$REPOSITORY_PREVIOUS_TERM_TRAP"
    restore_one_trap EXIT "$REPOSITORY_PREVIOUS_EXIT_TRAP"
}

release_repository_lock() {
    init_runtime_config
    [[ -n "$REPOSITORY_LOCK_DIR" ]] || return 0
    if [[ -d "$REPOSITORY_LOCK_DIR" && ! -L "$REPOSITORY_LOCK_DIR" ]]; then
        rmdir -- "$REPOSITORY_LOCK_DIR" || return 1
    elif [[ -e "$REPOSITORY_LOCK_DIR" || -L "$REPOSITORY_LOCK_DIR" ]]; then
        error "事务锁类型在运行中发生变化: $REPOSITORY_LOCK_DIR"
        return 1
    fi
    REPOSITORY_LOCK_DIR=""
}

repository_copy_file() {
    init_runtime_config
    cp --no-dereference --preserve=mode,ownership,timestamps -- "$1" "$2"
}

repository_install_file() {
    init_runtime_config
    install -o 0 -g 0 -m "$1" -- "$2" "$3"
}

repository_rename() {
    init_runtime_config
    mv -fT -- "$1" "$2"
}

repository_download_key() {
    init_runtime_config
    curl -fsSL --connect-timeout 10 --max-time 60 "$KEY_URL" -o "$1"
}

repository_transaction_hook() {
    :
}

repository_key_records() {
    init_runtime_config
    LC_ALL=C gpg --batch --no-options --no-default-keyring \
        --show-keys --with-colons --with-fingerprint --with-fingerprint -- "$1"
}

validate_downloaded_key() {
    init_runtime_config
    local key="$1" expected_mode="${2:-600}" records primary_count fingerprint uid_count uid
    validate_secure_file "$key" "$expected_mode" || return 1
    [[ -s "$key" ]] || { error "Cloudflare 签名密钥为空"; return 1; }
    if ! records=$(repository_key_records "$key"); then
        error "gpg 无法解析 Cloudflare 签名密钥"
        return 1
    fi
    primary_count=$(awk -F: '$1 == "pub" {count++} END {print count+0}' <<< "$records")
    [[ "$primary_count" == 1 ]] || {
        error "Cloudflare keyring 必须且只能包含一个主公钥"
        return 1
    }
    fingerprint=$(awk -F: '
        $1 == "pub" {in_primary=1; next}
        in_primary && $1 == "fpr" {print $10; exit}
    ' <<< "$records")
    [[ "$fingerprint" == "$KEY_FINGERPRINT" ]] || {
        error "Cloudflare 主公钥 fingerprint 不匹配"
        return 1
    }
    uid_count=$(awk -F: '
        $1 == "pub" {in_primary=1; next}
        $1 == "sub" {in_primary=0}
        in_primary && $1 == "uid" {count++}
        END {print count+0}
    ' <<< "$records")
    uid=$(awk -F: '
        $1 == "pub" {in_primary=1; next}
        $1 == "sub" {in_primary=0}
        in_primary && $1 == "uid" {print $10; exit}
    ' <<< "$records")
    [[ "$uid_count" == 1 && "$uid" == "$KEY_UID" ]] || {
        error "Cloudflare 主公钥 UID/主身份不匹配"
        return 1
    }
}

write_transaction_status() {
    init_runtime_config
    local text="$1"
    printf '%s\n' "$text" > "$REPOSITORY_TRANSACTION_DIR/status"
    chmod 0600 "$REPOSITORY_TRANSACTION_DIR/status"
}

backup_repository_generation() {
    init_runtime_config
    if [[ -e "$KEYRING" || -L "$KEYRING" ]]; then
        repository_copy_file "$KEYRING" "$REPOSITORY_TRANSACTION_DIR/old-key" || return 1
        chmod 0600 "$REPOSITORY_TRANSACTION_DIR/old-key" || return 1
        REPOSITORY_OLD_KEY=true
    fi
    if [[ -e "$SOURCE_FILE" || -L "$SOURCE_FILE" ]]; then
        repository_copy_file "$SOURCE_FILE" "$REPOSITORY_TRANSACTION_DIR/old-source" || return 1
        chmod 0600 "$REPOSITORY_TRANSACTION_DIR/old-source" || return 1
        REPOSITORY_OLD_SOURCE=true
    fi
    if [[ -f "$REPOSITORY_STATE_DIR/current" ]]; then
        repository_copy_file "$REPOSITORY_STATE_DIR/current" "$REPOSITORY_TRANSACTION_DIR/old-current" || return 1
        chmod 0600 "$REPOSITORY_TRANSACTION_DIR/old-current" || return 1
        REPOSITORY_OLD_STATE=true
    fi
}

restore_repository_file() {
    init_runtime_config
    local had_old="$1" backup="$2" target="$3" restore_stage
    if [[ "$had_old" == true ]]; then
        restore_stage=$(mktemp "$(dirname -- "$target")/.cloudflared-rollback.XXXXXX") || return 1
        if ! repository_install_file 0644 "$backup" "$restore_stage" ||
            ! validate_secure_file "$restore_stage" 644 ||
            ! repository_rename "$restore_stage" "$target"; then
            rm -f -- "$restore_stage" 2>/dev/null || true
            return 1
        fi
    else
        if [[ -e "$target" || -L "$target" ]]; then
            [[ -f "$target" && ! -L "$target" ]] || return 1
            rm -f -- "$target" || return 1
        fi
    fi
}

archive_failed_transaction() {
    init_runtime_config
    local failed_dir="$REPOSITORY_STATE_DIR/failure-$REPOSITORY_GENERATION"
    [[ -d "$REPOSITORY_TRANSACTION_DIR" ]] || return 0
    if repository_rename "$REPOSITORY_TRANSACTION_DIR" "$failed_dir"; then
        REPOSITORY_TRANSACTION_DIR="$failed_dir"
        return 0
    fi
    return 1
}

rollback_repository_transaction() {
    init_runtime_config
    local reason="$1" rollback_failed=false
    [[ "$REPOSITORY_TRANSACTION_ACTIVE" == true ]] || return 0
    REPOSITORY_TRANSACTION_ACTIVE=false
    trap - HUP INT TERM EXIT
    printf '%s\n' "$reason" >> "$REPOSITORY_TRANSACTION_DIR/rollback.log" 2>/dev/null || rollback_failed=true
    chmod 0600 "$REPOSITORY_TRANSACTION_DIR/rollback.log" 2>/dev/null || rollback_failed=true
    restore_repository_file "$REPOSITORY_OLD_SOURCE" "$REPOSITORY_TRANSACTION_DIR/old-source" "$SOURCE_FILE" || rollback_failed=true
    restore_repository_file "$REPOSITORY_OLD_KEY" "$REPOSITORY_TRANSACTION_DIR/old-key" "$KEYRING" || rollback_failed=true
    if [[ "$REPOSITORY_OLD_STATE" == true ]]; then
        repository_install_file 0600 "$REPOSITORY_TRANSACTION_DIR/old-current" "$REPOSITORY_STATE_DIR/current.rollback" || rollback_failed=true
        if [[ -f "$REPOSITORY_STATE_DIR/current.rollback" ]]; then
            repository_rename "$REPOSITORY_STATE_DIR/current.rollback" "$REPOSITORY_STATE_DIR/current" || rollback_failed=true
        fi
    else
        rm -f -- "$REPOSITORY_STATE_DIR/current" 2>/dev/null || rollback_failed=true
    fi
    rm -f -- "$REPOSITORY_KEY_STAGE" "$REPOSITORY_SOURCE_STAGE" 2>/dev/null || rollback_failed=true
    archive_failed_transaction || rollback_failed=true
    release_repository_lock || rollback_failed=true
    restore_repository_traps
    if [[ "$rollback_failed" == true ]]; then
        error "Cloudflare 仓库事务回滚不完整；失败证据已尽量保留: $REPOSITORY_TRANSACTION_DIR"
        return 1
    fi
    error "Cloudflare 仓库事务失败，旧 key/source 已恢复；证据: $REPOSITORY_TRANSACTION_DIR"
    return 0
}

repository_transaction_fail() {
    init_runtime_config
    local reason="$1"
    error "$reason"
    rollback_repository_transaction "$reason" || true
    return 1
}

repository_signal_handler() {
    init_runtime_config
    local code="$1" signal="$2"
    rollback_repository_transaction "收到 $signal 信号" || true
    exit "$code"
}

repository_exit_handler() {
    init_runtime_config
    local status="$1"
    if [[ "$REPOSITORY_TRANSACTION_ACTIVE" == true ]]; then
        rollback_repository_transaction "进程异常退出，状态 $status" || true
    fi
    exit "$status"
}

validate_committed_repository() {
    init_runtime_config
    local expected
    validate_secure_file "$KEYRING" 644 || return 1
    validate_secure_file "$SOURCE_FILE" 644 || return 1
    expected=$(repository_source_content)
    [[ "$(cat -- "$SOURCE_FILE")" == "$expected" ]] || {
        error "正式 source 内容不精确"
        return 1
    }
    validate_downloaded_key "$KEYRING" 644
}

begin_repository_transaction() {
    init_runtime_config
    local key_parent source_parent downloaded marker_stage key_hash source_hash
    REPOSITORY_TRANSACTION_ACTIVE=false
    REPOSITORY_TRANSACTION_DIR=""
    REPOSITORY_KEY_STAGE=""
    REPOSITORY_SOURCE_STAGE=""
    REPOSITORY_LOCK_DIR="${CLOUDFLARED_REPOSITORY_LOCK_DIR:-$STATE_DIR.lock}"
    REPOSITORY_GENERATION=""
    REPOSITORY_OLD_KEY=false
    REPOSITORY_OLD_SOURCE=false
    REPOSITORY_OLD_STATE=false
    REPOSITORY_PREVIOUS_HUP_TRAP=""
    REPOSITORY_PREVIOUS_INT_TRAP=""
    REPOSITORY_PREVIOUS_TERM_TRAP=""
    REPOSITORY_PREVIOUS_EXIT_TRAP=""
    command -v curl >/dev/null || { error "缺少 curl；正式仓库提交前不会通过 APT 安装依赖"; return 1; }
    command -v gpg >/dev/null || { error "缺少 gpg；无法校验 OpenPGP 主身份"; return 1; }
    command -v realpath >/dev/null || { error "缺少 realpath"; return 1; }
    key_parent=$(dirname -- "$KEYRING")
    source_parent=$(dirname -- "$SOURCE_FILE")
    validate_directory_chain "$key_parent" || return 1
    validate_directory_chain "$source_parent" || return 1
    validate_directory_chain "$APT_SOURCE_ROOT" || return 1
    acquire_repository_lock || return 1
    if ! prepare_repository_state; then
        release_repository_lock || true
        return 1
    fi

    REPOSITORY_GENERATION="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
    REPOSITORY_TRANSACTION_DIR="$REPOSITORY_STATE_DIR/transaction-$REPOSITORY_GENERATION"
    if ! mkdir -m 0700 -- "$REPOSITORY_TRANSACTION_DIR" ||
        ! validate_secure_directory "$REPOSITORY_TRANSACTION_DIR" 700; then
        release_repository_lock || true
        return 1
    fi
    REPOSITORY_TRANSACTION_ACTIVE=true
    save_repository_traps

    validate_existing_repository_file "$KEYRING" || repository_transaction_fail "现有 keyring 类型或元数据不可信"
    [[ "$REPOSITORY_TRANSACTION_ACTIVE" == true ]] || return 1
    validate_existing_source || repository_transaction_fail "现有 source 类型、元数据或内容不可信"
    [[ "$REPOSITORY_TRANSACTION_ACTIVE" == true ]] || return 1
    backup_repository_generation || repository_transaction_fail "备份旧 key/source 失败"
    [[ "$REPOSITORY_TRANSACTION_ACTIVE" == true ]] || return 1

    downloaded="$REPOSITORY_TRANSACTION_DIR/downloaded-key"
    repository_transaction_hook download
    if ! : > "$downloaded" || ! chmod 0600 "$downloaded" ||
        ! repository_download_key "$downloaded"; then
        repository_transaction_fail "Cloudflare key URL 下载失败"
        return 1
    fi
    repository_transaction_hook validate
    validate_downloaded_key "$downloaded" || {
        repository_transaction_fail "Cloudflare 下载密钥校验失败"
        return 1
    }

    repository_transaction_hook stage
    REPOSITORY_KEY_STAGE=$(mktemp "$key_parent/.cloudflare-main.gpg.stage.XXXXXX") || {
        repository_transaction_fail "创建 key stage 失败"
        return 1
    }
    REPOSITORY_SOURCE_STAGE=$(mktemp "$source_parent/.cloudflared.list.stage.XXXXXX") || {
        repository_transaction_fail "创建 source stage 失败"
        return 1
    }
    if ! repository_install_file 0644 "$downloaded" "$REPOSITORY_KEY_STAGE" ||
        ! validate_secure_file "$REPOSITORY_KEY_STAGE" 644; then
        repository_transaction_fail "写入或校验 key stage 失败"
        return 1
    fi
    if ! repository_source_content > "$REPOSITORY_TRANSACTION_DIR/source" ||
        ! chmod 0600 "$REPOSITORY_TRANSACTION_DIR/source" ||
        ! repository_install_file 0644 "$REPOSITORY_TRANSACTION_DIR/source" "$REPOSITORY_SOURCE_STAGE" ||
        ! validate_secure_file "$REPOSITORY_SOURCE_STAGE" 644; then
        repository_transaction_fail "写入或校验 source stage 失败"
        return 1
    fi

    write_transaction_status "generation=$REPOSITORY_GENERATION staged" || {
        repository_transaction_fail "写入事务状态失败"
        return 1
    }
    repository_transaction_hook key-commit
    if ! repository_rename "$REPOSITORY_KEY_STAGE" "$KEYRING"; then
        repository_transaction_fail "提交正式 keyring 失败"
        return 1
    fi
    REPOSITORY_KEY_STAGE=""
    validate_secure_file "$KEYRING" 644 || {
        repository_transaction_fail "正式 keyring 提交后校验失败"
        return 1
    }
    repository_transaction_hook source-commit
    if ! repository_rename "$REPOSITORY_SOURCE_STAGE" "$SOURCE_FILE"; then
        repository_transaction_fail "提交正式 source 失败"
        return 1
    fi
    REPOSITORY_SOURCE_STAGE=""
    repository_transaction_hook committed
    validate_committed_repository || {
        repository_transaction_fail "正式 key/source 同世代校验失败"
        return 1
    }

    key_hash=$(sha256sum -- "$KEYRING" | awk '{print $1}') || {
        repository_transaction_fail "计算 keyring 世代摘要失败"
        return 1
    }
    source_hash=$(sha256sum -- "$SOURCE_FILE" | awk '{print $1}') || {
        repository_transaction_fail "计算 source 世代摘要失败"
        return 1
    }
    marker_stage="$REPOSITORY_STATE_DIR/current.stage-$REPOSITORY_GENERATION"
    if ! printf 'generation=%s\nkey_sha256=%s\nsource_sha256=%s\n' \
        "$REPOSITORY_GENERATION" "$key_hash" "$source_hash" > "$marker_stage" ||
        ! chmod 0600 "$marker_stage" ||
        ! validate_secure_file "$marker_stage" 600 ||
        ! repository_rename "$marker_stage" "$REPOSITORY_STATE_DIR/current"; then
        rm -f -- "$marker_stage" 2>/dev/null || true
        repository_transaction_fail "提交 key/source 世代状态失败"
        return 1
    fi
    write_transaction_status "generation=$REPOSITORY_GENERATION committed" || {
        repository_transaction_fail "记录事务提交状态失败"
        return 1
    }
}

finish_repository_transaction() {
    init_runtime_config
    local history_dir="$REPOSITORY_STATE_DIR/history-$REPOSITORY_GENERATION"
    [[ "$REPOSITORY_TRANSACTION_ACTIVE" == true ]] || return 1
    if ! repository_rename "$REPOSITORY_TRANSACTION_DIR" "$history_dir"; then
        repository_transaction_fail "归档成功事务失败"
        return 1
    fi
    REPOSITORY_TRANSACTION_DIR="$history_dir"
    REPOSITORY_TRANSACTION_ACTIVE=false
    trap - HUP INT TERM EXIT
    if ! release_repository_lock; then
        restore_repository_traps
        error "仓库提交成功，但事务锁释放失败: $REPOSITORY_LOCK_DIR"
        return 1
    fi
    restore_repository_traps
}

configure_repository() {
    init_runtime_config
    begin_repository_transaction || return 1
    finish_repository_transaction
}

run_repository_apt_transaction() {
    init_runtime_config
    local operation="$1"
    begin_repository_transaction || return 1
    repository_transaction_hook apt-probe
    if ! apt-get update; then
        repository_transaction_fail "Cloudflare APT probe 失败"
        return 1
    fi
    repository_transaction_hook apt-install
    case "$operation" in
        install)
            if ! DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflared; then
                repository_transaction_fail "cloudflared APT 安装失败"
                return 1
            fi
            ;;
        upgrade)
            if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade cloudflared; then
                repository_transaction_fail "cloudflared APT 升级失败"
                return 1
            fi
            ;;
        *)
            repository_transaction_fail "未知 APT 仓库事务: $operation"
            return 1
            ;;
    esac
    finish_repository_transaction
}

legacy_updater_is_managed() {
    local path="$1"
    case "$path" in
        "$LEGACY_UPDATER") grep -Fq 'cloudflared 自动更新脚本 (由安装脚本生成)' "$path" ;;
        "$LEGACY_SERVICE") grep -Fq 'Description=Cloudflared Auto Updater' "$path" && grep -Fq "ExecStart=$LEGACY_UPDATER" "$path" ;;
        "$LEGACY_TIMER") grep -Fq 'Description=Cloudflared Auto Updater Timer' "$path" ;;
        *) return 1 ;;
    esac
}

cleanup_legacy_updater() {
    local path backup_dir
    backup_dir="$STATE_DIR/legacy-$(date +%Y%m%d_%H%M%S)"
    local -a paths=("$LEGACY_UPDATER" "$LEGACY_SERVICE" "$LEGACY_TIMER")

    for path in "${paths[@]}"; do
        [[ -e "$path" ]] || continue
        if ! legacy_updater_is_managed "$path"; then
            warn "发现无法确认归属的旧文件，保留: $path"
            return 1
        fi
    done

    systemctl disable --now cloudflared-updater.timer >/dev/null 2>&1 || true
    systemctl stop cloudflared-updater.service >/dev/null 2>&1 || true
    for path in "${paths[@]}"; do
        [[ -e "$path" ]] || continue
        backup_path "$path" "$backup_dir" || return 1
        rm -f "$path" || return 1
    done
    systemctl daemon-reload
    for path in "${paths[@]}"; do
        [[ ! -e "$path" ]] || return 1
    done
}

binary_updater_is_managed() {
    local path="$1"
    case "$path" in
        "$BINARY_UPDATE_SERVICE")
            grep -Fq 'Description=Update cloudflared' "$path" &&
                grep -Fq ' update; code=$?' "$path"
            ;;
        "$BINARY_UPDATE_TIMER")
            grep -Fq 'Description=Update cloudflared' "$path" &&
                grep -Fq 'OnCalendar=daily' "$path"
            ;;
        *) return 1 ;;
    esac
}

cleanup_binary_updater() {
    local path backup_dir
    local -a paths=("$BINARY_UPDATE_SERVICE" "$BINARY_UPDATE_TIMER")
    for path in "${paths[@]}"; do
        [[ -e "$path" ]] || continue
        binary_updater_is_managed "$path" || {
            warn "发现无法确认归属的 cloudflared 二进制更新单元，保留: $path"
            return 1
        }
    done
    backup_dir="$STATE_DIR/binary-updater-$(date +%Y%m%d_%H%M%S)"
    systemctl disable --now cloudflared-update.timer >/dev/null 2>&1 || true
    systemctl stop cloudflared-update.service >/dev/null 2>&1 || true
    for path in "${paths[@]}"; do
        [[ -e "$path" ]] || continue
        backup_path "$path" "$backup_dir" || return 1
        rm -f "$path" || return 1
    done
    systemctl daemon-reload
    for path in "${paths[@]}"; do
        [[ ! -e "$path" ]] || return 1
    done
}

legacy_auto_update_present() {
    if [[ -f "$LEGACY_TIMER" ]] && legacy_updater_is_managed "$LEGACY_TIMER" &&
        { systemctl is-enabled --quiet cloudflared-updater.timer 2>/dev/null ||
          systemctl is-active --quiet cloudflared-updater.timer 2>/dev/null; }; then
        return 0
    fi
    if [[ -f "$BINARY_UPDATE_TIMER" ]] && binary_updater_is_managed "$BINARY_UPDATE_TIMER" &&
        { systemctl is-enabled --quiet cloudflared-update.timer 2>/dev/null ||
          systemctl is-active --quiet cloudflared-update.timer 2>/dev/null; }; then
        return 0
    fi
    return 1
}

legacy_binary_is_apt_compat_symlink() {
    [[ -L "$LEGACY_BIN" ]] &&
        [[ "$(readlink -f "$LEGACY_BIN")" == "$APT_BIN" ]] &&
        dpkg-query -S "$APT_BIN" >/dev/null 2>&1
}

legacy_binary_is_safe_to_migrate() {
    [[ -x "$LEGACY_BIN" ]] || return 1

    # Cloudflare DEB postinst creates this unowned compatibility symlink.
    # Keep it; dpkg-query cannot report /usr/local/bin/cloudflared as owned.
    if legacy_binary_is_apt_compat_symlink; then
        return 0
    fi

    [[ -f "$SERVICE_FILE" ]] || return 1

    if [[ -L "$LEGACY_BIN" ]] &&
        [[ "$(readlink -f "$LEGACY_BIN")" == "$APT_BIN" ]] &&
        dpkg-query -S "$APT_BIN" >/dev/null 2>&1 &&
        grep -Fq "ExecStart=$APT_BIN " "$SERVICE_FILE"; then
        return 0
    fi

    grep -Fq "ExecStart=$LEGACY_BIN " "$SERVICE_FILE" || return 1
    "$LEGACY_BIN" version 2>/dev/null | grep -Eiq '^cloudflared version[[:space:]]'
}

migrate_legacy_service_path() {
    [[ -f "$SERVICE_FILE" ]] || return 0
    grep -Fq "ExecStart=$LEGACY_BIN " "$SERVICE_FILE" || return 0

    local backup_dir service_temp was_active=false
    backup_dir="$STATE_DIR/legacy-service-$(date +%Y%m%d_%H%M%S)"
    backup_path "$SERVICE_FILE" "$backup_dir"
    service_temp=$(mktemp)
    sed "s#^ExecStart=$LEGACY_BIN #ExecStart=$APT_BIN #" "$SERVICE_FILE" > "$service_temp"
    grep -Fq "ExecStart=$APT_BIN " "$service_temp" || {
        rm -f "$service_temp"
        error "旧服务路径迁移验证失败"
        return 1
    }
    systemctl is-active --quiet cloudflared.service && was_active=true || true
    install -m 0644 "$service_temp" "$SERVICE_FILE"
    rm -f "$service_temp"
    systemctl daemon-reload
    if [[ "$was_active" == true ]]; then
        if ! systemctl restart cloudflared.service || ! systemctl is-active --quiet cloudflared.service; then
            cp -a "$backup_dir/$(basename "$SERVICE_FILE")" "$SERVICE_FILE"
            systemctl daemon-reload
            systemctl restart cloudflared.service >/dev/null 2>&1 || true
            error "新 APT 二进制启动失败，已恢复旧服务路径"
            return 1
        fi
    fi
    info "cloudflared.service 已迁移到 $APT_BIN；原 unit 已备份。"
}

migrate_legacy_binary() {
    [[ -e "$LEGACY_BIN" || -L "$LEGACY_BIN" ]] || return 0
    if dpkg-query -S "$LEGACY_BIN" >/dev/null 2>&1 ||
        legacy_binary_is_apt_compat_symlink; then
        return 0
    fi

    if ! legacy_binary_is_safe_to_migrate; then
        error "无法确认 $LEGACY_BIN 属于旧版受管安装，已保留并停止迁移"
        return 1
    fi

    info "检测到可安全迁移的旧版 cloudflared 安装"
    migrate_legacy_service_path

    local backup_dir
    backup_dir="$STATE_DIR/legacy-$(date +%Y%m%d_%H%M%S)"
    backup_path "$LEGACY_BIN" "$backup_dir"
    rm -f "$LEGACY_BIN"
    info "旧二进制已自动备份并移除: $backup_dir"
}

write_auto_update_files() {
    install -d -m 0755 "$(dirname "$AUTO_UPDATE_SCRIPT")" "$(dirname "$AUTO_UPDATE_SERVICE")"

    cat > "$AUTO_UPDATE_SCRIPT" <<'UPDATER'
#!/usr/bin/env bash
# Managed by tools/cloudflare_tunnel.sh
set -euo pipefail

exec 9>/run/lock/cloudflared-apt-update.lock
if ! flock -n 9; then
    echo "另一项 cloudflared APT 更新正在运行，跳过"
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive
installed=$(dpkg-query -W -f='${Version}' cloudflared 2>/dev/null) || {
    echo "cloudflared APT 包未安装" >&2
    exit 1
}

apt-get -o DPkg::Lock::Timeout=300 update -qq
candidate=$(LC_ALL=C apt-cache policy cloudflared | awk '/Candidate:/ {print $2; exit}')
if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
    echo "无法取得 cloudflared 候选版本" >&2
    exit 1
fi
if ! dpkg --compare-versions "$candidate" gt "$installed"; then
    echo "cloudflared 已是最新版本: $installed"
    exit 0
fi

was_active=false
systemctl is-active --quiet cloudflared.service && was_active=true || true
echo "升级 cloudflared: $installed -> $candidate"
apt-get -o DPkg::Lock::Timeout=300 install -y --only-upgrade cloudflared

if [[ "$was_active" == true ]]; then
    systemctl restart cloudflared.service
    systemctl is-active --quiet cloudflared.service
fi
/usr/bin/cloudflared version
UPDATER
    chmod 0755 "$AUTO_UPDATE_SCRIPT"

    cat > "$AUTO_UPDATE_SERVICE" <<EOF
# Managed by tools/cloudflare_tunnel.sh
[Unit]
Description=Check and install cloudflared APT updates
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$AUTO_UPDATE_SCRIPT
EOF

    cat > "$AUTO_UPDATE_TIMER" <<'EOF'
# Managed by tools/cloudflare_tunnel.sh
[Unit]
Description=Daily cloudflared APT update check

[Timer]
OnCalendar=daily
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    chmod 0644 "$AUTO_UPDATE_SERVICE" "$AUTO_UPDATE_TIMER"
}

auto_update_file_is_managed() {
    grep -Fq '# Managed by tools/cloudflare_tunnel.sh' "$1"
}

enable_auto_update() {
    local path backup_dir
    require_root
    check_platform
    dpkg-query -W -f='${db:Status-Status}' cloudflared 2>/dev/null | grep -qx installed || {
        error "请先安装 cloudflared APT 包"
        return 1
    }
    configure_repository
    command -v flock >/dev/null || {
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y util-linux
    }
    for path in "$AUTO_UPDATE_SCRIPT" "$AUTO_UPDATE_SERVICE" "$AUTO_UPDATE_TIMER"; do
        [[ -e "$path" ]] || continue
        auto_update_file_is_managed "$path" || {
            error "现有自动更新文件不受本脚本管理，拒绝覆盖: $path"
            return 1
        }
    done
    backup_dir="$STATE_DIR/auto-update-previous-$(date +%Y%m%d_%H%M%S)"
    for path in "$AUTO_UPDATE_SCRIPT" "$AUTO_UPDATE_SERVICE" "$AUTO_UPDATE_TIMER"; do
        backup_path "$path" "$backup_dir"
    done
    write_auto_update_files
    systemctl daemon-reload
    systemctl enable --now cloudflared-apt-update.timer
    info "已启用每日 APT 更新检查；更新时仅重启原本正在运行的 cloudflared 服务。"
}

disable_auto_update_locked() {
    local confirmed="${1:-}" path backup_dir
    require_root
    check_platform
    for path in "$AUTO_UPDATE_SCRIPT" "$AUTO_UPDATE_SERVICE" "$AUTO_UPDATE_TIMER"; do
        [[ -e "$path" ]] || continue
        auto_update_file_is_managed "$path" || {
            error "自动更新文件不受本脚本管理，拒绝删除: $path"
            return 1
        }
    done
    if [[ "$confirmed" != --confirmed ]]; then
        confirm "禁用并删除 cloudflared APT 自动更新组件？" || { info "已取消"; return 0; }
    fi
    backup_dir="$STATE_DIR/auto-update-$(date +%Y%m%d_%H%M%S)"
    systemctl disable --now cloudflared-apt-update.timer >/dev/null 2>&1 || true
    systemctl stop cloudflared-apt-update.service >/dev/null 2>&1 || true
    for path in "$AUTO_UPDATE_SCRIPT" "$AUTO_UPDATE_SERVICE" "$AUTO_UPDATE_TIMER"; do
        [[ -e "$path" ]] || continue
        backup_path "$path" "$backup_dir" || return 1
        rm -f "$path" || return 1
    done
    systemctl daemon-reload
    info "APT 自动更新组件已禁用；备份目录: $backup_dir"
}

disable_auto_update() {
    init_runtime_config
    validate_directory_chain "$(dirname -- "$REPOSITORY_LOCK_DIR")" || return 1
    acquire_repository_lock || return 1
    if ! prepare_repository_state || ! disable_auto_update_locked "$@"; then
        release_repository_lock || return 1
        return 1
    fi
    release_repository_lock
}

show_auto_update_status() {
    if command -v systemctl >/dev/null && systemctl is-enabled --quiet cloudflared-apt-update.timer 2>/dev/null; then
        echo "APT 自动更新: 已启用"
        systemctl list-timers cloudflared-apt-update.timer --no-pager 2>/dev/null || true
    else
        echo "APT 自动更新: 未启用"
    fi
}

validate_migration_inputs() {
    local path
    if [[ -e "$LEGACY_BIN" || -L "$LEGACY_BIN" ]] &&
        ! dpkg-query -S "$LEGACY_BIN" >/dev/null 2>&1 &&
        ! legacy_binary_is_safe_to_migrate; then
        error "无法确认 $LEGACY_BIN 属于旧版受管安装，拒绝自动迁移"
        return 1
    fi
    for path in "$LEGACY_UPDATER" "$LEGACY_SERVICE" "$LEGACY_TIMER"; do
        [[ -e "$path" ]] || continue
        legacy_updater_is_managed "$path" || {
            error "旧更新文件归属不明，拒绝自动迁移: $path"
            return 1
        }
    done
    for path in "$BINARY_UPDATE_SERVICE" "$BINARY_UPDATE_TIMER"; do
        [[ -e "$path" ]] || continue
        binary_updater_is_managed "$path" || {
            error "二进制更新单元归属不明，拒绝自动迁移: $path"
            return 1
        }
    done
}

install_package() {
    validate_migration_inputs
    PRESERVE_AUTO_UPDATE=false
    legacy_auto_update_present && PRESERVE_AUTO_UPDATE=true || true
    run_repository_apt_transaction install
    migrate_legacy_binary
    cleanup_legacy_updater || { error "旧自定义更新组件清理失败"; return 1; }
    cleanup_binary_updater || { error "二进制更新单元清理失败"; return 1; }
    if [[ "$PRESERVE_AUTO_UPDATE" == true ]]; then
        enable_auto_update
        info "检测到旧版每日更新配置，已自动迁移为 APT timer。"
    fi

    [[ -x "$APT_BIN" ]] || { error "APT cloudflared 安装后不可用"; return 1; }
    "$APT_BIN" version
}

install_service() {
    if systemctl cat cloudflared.service >/dev/null 2>&1; then
        info "cloudflared.service 已存在，不重复写入 Token"
        systemctl enable --now cloudflared.service
        return 0
    fi

    local token
    read -r -s -p "粘贴 Cloudflare Tunnel Token: " token
    printf '\n'
    [[ -n "$token" ]] || { error "Token 不能为空"; return 1; }
    if ! cloudflared service install --no-update-service "$token"; then
        unset token
        error "官方 service install 执行失败"
        return 1
    fi
    unset token
    systemctl enable --now cloudflared.service
    systemctl is-active --quiet cloudflared.service || {
        error "服务未处于运行状态"
        return 1
    }
}

install_cloudflared() {
    require_root
    check_platform
    install_package
    install_service
    info "安装完成。版本由 APT 管理。"
    if [[ "$PRESERVE_AUTO_UPDATE" == true ]]; then
        info "旧版自动更新行为已保留，无需再次确认。"
    else
        warn "自动更新安装新版时会重启正在运行的 cloudflared，单实例 Tunnel 会短暂中断。"
        if confirm "是否启用每日 APT 更新检测与安装？"; then
            enable_auto_update
        else
            info "自动更新未启用；稍后可运行: sudo $(basename "$0") enable-auto-update"
        fi
    fi
}

upgrade_cloudflared() {
    require_root
    check_platform
    validate_migration_inputs
    PRESERVE_AUTO_UPDATE=false
    legacy_auto_update_present && PRESERVE_AUTO_UPDATE=true || true
    run_repository_apt_transaction upgrade
    migrate_legacy_binary
    cleanup_legacy_updater || { error "旧自定义更新组件清理失败"; return 1; }
    cleanup_binary_updater || { error "二进制更新单元清理失败"; return 1; }
    if [[ "$PRESERVE_AUTO_UPDATE" == true ]]; then
        enable_auto_update
        info "检测到旧版每日更新配置，已自动迁移为 APT timer。"
    fi
    if systemctl cat cloudflared.service >/dev/null 2>&1; then
        systemctl restart cloudflared.service
        systemctl is-active --quiet cloudflared.service || {
            error "升级后服务未运行"
            return 1
        }
    fi
    "$APT_BIN" version
}

show_status() {
    if dpkg-query -W -f='${db:Status-Status}' cloudflared 2>/dev/null | grep -qx installed; then
        echo "APT 包: 已安装"
        "$APT_BIN" version 2>/dev/null || true
    else
        echo "APT 包: 未安装"
    fi
    [[ -f "$SOURCE_FILE" ]] && echo "官方源: 已配置 ($SOURCE_FILE)" || echo "官方源: 未配置"
    if command -v systemctl >/dev/null && systemctl is-active --quiet cloudflared.service; then
        echo "服务: 运行中"
    else
        echo "服务: 未运行"
    fi
    [[ -e "$LEGACY_BIN" ]] && warn "旧二进制仍存在: $LEGACY_BIN"
    [[ -e "$LEGACY_TIMER" || -e "$LEGACY_SERVICE" || -e "$LEGACY_UPDATER" ]] &&
        warn "旧自定义更新组件仍存在"
    [[ -e "$BINARY_UPDATE_SERVICE" || -e "$BINARY_UPDATE_TIMER" ]] &&
        warn "不适用于 APT 安装的 cloudflared 二进制更新单元仍存在"
    show_auto_update_status
}

validate_current_repository_manifest() {
    init_runtime_config
    local current="$REPOSITORY_STATE_DIR/current" generation key_hash source_hash expected_key_hash expected_source_hash
    validate_secure_file "$current" 600 || return 1
    awk -F= '
        NF != 2 || ($1 != "generation" && $1 != "key_sha256" && $1 != "source_sha256") || seen[$1]++ {bad=1}
        END {if (bad || seen["generation"] != 1 || seen["key_sha256"] != 1 || seen["source_sha256"] != 1) exit 1}
    ' "$current" || return 1
    generation=$(awk -F= '$1 == "generation" {print $2}' "$current")
    [[ "$generation" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]] || return 1
    key_hash=$(awk -F= '$1 == "key_sha256" {print $2}' "$current")
    source_hash=$(awk -F= '$1 == "source_sha256" {print $2}' "$current")
    [[ "$key_hash" =~ ^[[:xdigit:]]{64}$ && "$source_hash" =~ ^[[:xdigit:]]{64}$ ]] || return 1
    validate_secure_file "$KEYRING" 644 || return 1
    validate_secure_file "$SOURCE_FILE" 644 || return 1
    expected_key_hash=$(sha256sum -- "$KEYRING" | awk '{print $1}') || return 1
    expected_source_hash=$(sha256sum -- "$SOURCE_FILE" | awk '{print $1}') || return 1
    [[ "$key_hash" == "$expected_key_hash" && "$source_hash" == "$expected_source_hash" ]] || return 1
    [[ "$(cat -- "$SOURCE_FILE")" == "$(repository_source_content)" ]] || return 1
}

remove_managed_repository_locked() {
    init_runtime_config
    local backup_dir managed=false
    validate_directory_chain "$(dirname -- "$SOURCE_FILE")" || return 1
    if [[ -f "$REPOSITORY_STATE_DIR/current" ]] && validate_current_repository_manifest; then
        managed=true
    fi
    if [[ "$managed" != true && -f "$STATE_DIR/repository-managed" ]] &&
        validate_secure_file "$STATE_DIR/repository-managed" 600 &&
        [[ "$(cat -- "$STATE_DIR/repository-managed")" == managed ]]; then
        validate_secure_file "$SOURCE_FILE" 644 || return 1
        [[ "$(cat -- "$SOURCE_FILE")" == "$(repository_legacy_source_content)" ]] || return 1
        managed=true
    fi
    [[ "$managed" == true ]] || { error "无法验证 Cloudflare source 管理归属，拒绝删除"; return 1; }
    backup_dir="$STATE_DIR/uninstall-$(date +%Y%m%d_%H%M%S)"
    backup_path "$SOURCE_FILE" "$backup_dir" || return 1
    rm -f -- "$SOURCE_FILE" "$STATE_DIR/repository-managed" || return 1
    rm -f -- "$REPOSITORY_STATE_DIR/current" || return 1
    unset REPOSITORY_STATE_DIR
}

remove_managed_repository() {
    init_runtime_config
    validate_directory_chain "$(dirname -- "$REPOSITORY_LOCK_DIR")" || return 1
    acquire_repository_lock || return 1
    if ! prepare_repository_state || ! remove_managed_repository_locked; then
        release_repository_lock || return 1
        return 1
    fi
    release_repository_lock
}

uninstall_transaction_hook() {
    :
}

uninstall_snapshot_targets() {
    printf '%s\t%s\n' \
        "$AUTO_UPDATE_SCRIPT" 755 \
        "$AUTO_UPDATE_SERVICE" 644 \
        "$AUTO_UPDATE_TIMER" 644 \
        "$SOURCE_FILE" 644 \
        "$REPOSITORY_STATE_DIR/current" 600 \
        "$STATE_DIR/repository-managed" 600
}

uninstall_cleanup() {
    init_runtime_config
    local reason="$1" failed=false evidence path mode state
    state="${UNINSTALL_TRANSACTION_STATE:-NONE}"
    [[ "$state" == BUILDING || "$state" == ACTIVE ]] || return 0
    UNINSTALL_TRANSACTION_STATE=NONE
    trap - HUP INT TERM EXIT
    evidence="$REPOSITORY_STATE_DIR/failure-uninstall-${UNINSTALL_GENERATION:-unknown}"
    mkdir -m 0700 -- "$evidence" 2>/dev/null || failed=true
    printf '%s\n' "$reason" > "$evidence/rollback.log" 2>/dev/null || failed=true
    chmod 0600 "$evidence/rollback.log" 2>/dev/null || failed=true
    if [[ "$state" == ACTIVE && -f "$UNINSTALL_SNAPSHOT_DIR/manifest" ]]; then
        while IFS=$'\t' read -r path mode; do
            case "$mode" in
                absent)
                    [[ ! -e "$path" && ! -L "$path" ]] || rm -f -- "$path" || failed=true
                    ;;
                600|644|755)
                    repository_install_file "$mode" "$UNINSTALL_SNAPSHOT_DIR/files/$(printf '%s' "$path" | sha256sum | awk '{print $1}')" "$path" || failed=true
                    ;;
                *) failed=true ;;
            esac
        done < "$UNINSTALL_SNAPSHOT_DIR/manifest"
    fi
    rm -rf -- "${UNINSTALL_SNAPSHOT_DIR:-}" 2>/dev/null || failed=true
    release_repository_lock || failed=true
    restore_repository_traps
    [[ "$failed" == false ]] || { error "卸载事务清理不完整；失败证据: $evidence"; return 1; }
    error "Cloudflare 卸载事务失败；可恢复文件已恢复；证据: $evidence"
}

uninstall_signal_handler() {
    local code="$1" signal="$2"
    uninstall_cleanup "收到 $signal 信号" || code=1
    exit "$code"
}

uninstall_exit_handler() {
    local status="$1"
    if [[ "${UNINSTALL_TRANSACTION_STATE:-NONE}" == BUILDING || "${UNINSTALL_TRANSACTION_STATE:-NONE}" == ACTIVE ]]; then
        uninstall_cleanup "活动卸载事务异常退出，原状态 $status" || status=1
        (( status == 0 )) && status=1
    fi
    exit "$status"
}

begin_uninstall_transaction() {
    init_runtime_config
    local path mode digest
    UNINSTALL_GENERATION="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
    UNINSTALL_SNAPSHOT_DIR="$REPOSITORY_STATE_DIR/uninstall-$UNINSTALL_GENERATION"
    UNINSTALL_TRANSACTION_STATE=BUILDING
    save_repository_traps
    trap 'uninstall_signal_handler 129 HUP' HUP
    trap 'uninstall_signal_handler 130 INT' INT
    trap 'uninstall_signal_handler 143 TERM' TERM
    trap 'uninstall_exit_handler $?' EXIT
    uninstall_transaction_hook before-snapshot-create
    mkdir -m 0700 -- "$UNINSTALL_SNAPSHOT_DIR" || return 1
    mkdir -m 0700 -- "$UNINSTALL_SNAPSHOT_DIR/files" || return 1
    : > "$UNINSTALL_SNAPSHOT_DIR/manifest" || return 1
    chmod 0600 "$UNINSTALL_SNAPSHOT_DIR/manifest" || return 1
    while IFS=$'\t' read -r path mode; do
        if [[ -e "$path" || -L "$path" ]]; then
            validate_secure_file "$path" "$mode" || return 1
            digest=$(printf '%s' "$path" | sha256sum | awk '{print $1}') || return 1
            repository_copy_file "$path" "$UNINSTALL_SNAPSHOT_DIR/files/$digest" || return 1
            chmod 0600 "$UNINSTALL_SNAPSHOT_DIR/files/$digest" || return 1
        else
            mode=absent
        fi
        printf '%s\t%s\n' "$path" "$mode" >> "$UNINSTALL_SNAPSHOT_DIR/manifest" || return 1
    done < <(uninstall_snapshot_targets)
    validate_secure_file "$UNINSTALL_SNAPSHOT_DIR/manifest" 600 || return 1
    [[ "$(wc -l < "$UNINSTALL_SNAPSHOT_DIR/manifest")" == 6 ]] || return 1
    UNINSTALL_TRANSACTION_STATE=ACTIVE
    uninstall_transaction_hook after-snapshot-active
}

finish_uninstall_transaction() {
    local lock_path="$REPOSITORY_LOCK_DIR" failed=false
    UNINSTALL_TRANSACTION_STATE=NONE
    trap - HUP INT TERM EXIT
    rm -rf -- "$UNINSTALL_SNAPSHOT_DIR" || failed=true
    release_repository_lock || failed=true
    restore_repository_traps
    if [[ "$failed" == true ]]; then
        error "卸载收尾失败；可能残留锁或 snapshot: $lock_path $UNINSTALL_SNAPSHOT_DIR"
        return 1
    fi
}

uninstall_cloudflared() {
    local confirmed="${1:-}" uninstall_status=0 irreversible=false
    require_root
    check_platform
    warn "将删除 cloudflared 服务和 APT 包；Tunnel 配置与凭据默认保留。"
    if [[ "$confirmed" != --confirmed ]]; then
        confirm "继续卸载？" || { info "已取消"; return 0; }
    fi

    init_runtime_config
    validate_directory_chain "$(dirname -- "$REPOSITORY_LOCK_DIR")" || return 1
    acquire_repository_lock || return 1
    if ! prepare_repository_state; then
        release_repository_lock || return 1
        return 1
    fi
    if [[ -f "$REPOSITORY_STATE_DIR/current" ]]; then
        validate_current_repository_manifest || {
            release_repository_lock || return 1
            return 1
        }
    elif [[ ! -f "$STATE_DIR/repository-managed" ]]; then
        error "无法验证 Cloudflare source 管理归属，拒绝卸载"
        release_repository_lock || return 1
        return 1
    fi
    begin_uninstall_transaction || {
        release_repository_lock || return 1
        return 1
    }

    uninstall_transaction_hook lock-acquired
    uninstall_transaction_hook before-disable-auto-update
    disable_auto_update_locked --confirmed || uninstall_status=$?
    uninstall_transaction_hook after-disable-auto-update
    if (( uninstall_status == 0 )); then
        if command -v cloudflared >/dev/null 2>&1; then
            cloudflared service uninstall >/dev/null 2>&1 || true
        fi
        systemctl disable --now cloudflared.service >/dev/null 2>&1 || true
        uninstall_transaction_hook before-apt-remove
        irreversible=true
        DEBIAN_FRONTEND=noninteractive apt-get remove -y cloudflared || uninstall_status=$?
        uninstall_transaction_hook after-apt-remove
    fi
    if (( uninstall_status == 0 )); then
        uninstall_transaction_hook before-source-remove
        remove_managed_repository_locked || uninstall_status=$?
        uninstall_transaction_hook after-source-remove
    fi
    if (( uninstall_status == 0 )); then
        uninstall_transaction_hook final-apt-update
        apt-get update || uninstall_status=$?
    fi

    if (( uninstall_status != 0 )); then
        uninstall_cleanup "卸载步骤失败，状态 $uninstall_status" || true
        [[ "$irreversible" == true ]] && error "APT 包状态可能已部分改变；未尝试自动重新安装 cloudflared"
        return "$uninstall_status"
    fi
    uninstall_transaction_hook before-lock-release
    finish_uninstall_transaction || return 1
    info "卸载完成；/etc/cloudflared 与用户 .cloudflared 目录未删除。"
}

purge_config() {
    require_root
    check_platform
    warn "此操作会永久删除 /etc/cloudflared、/root/.cloudflared 和当前用户配置。"
    [[ -t 0 ]] || { error "彻底清理必须在交互终端执行"; return 1; }
    local answer
    read -r -p "请输入 PURGE 确认: " answer
    [[ "$answer" == PURGE ]] || { info "已取消"; return 0; }
    uninstall_cloudflared --confirmed
    rm -rf /etc/cloudflared /root/.cloudflared
    if [[ "${HOME:-/root}" != /root ]]; then
        rm -rf "$HOME/.cloudflared"
    fi
    info "Tunnel 本地配置已删除"
}

show_help() {
    cat <<'EOF'
用法：
  cloudflare_tunnel.sh install          配置官方 APT 源、安装包并安装 Tunnel 服务
  cloudflare_tunnel.sh upgrade          通过 APT 升级并重启服务
  cloudflare_tunnel.sh status                查看包、服务、自动更新和旧版残留
  cloudflare_tunnel.sh enable-auto-update    启用每日 APT 更新检测与安装
  cloudflare_tunnel.sh disable-auto-update   禁用并备份自动更新组件
  cloudflare_tunnel.sh migrate-legacy   备份并清理旧二进制和自定义更新器
  cloudflare_tunnel.sh uninstall        删除服务、APT 包和本工具管理的软件源，保留配置
  cloudflare_tunnel.sh purge            二次确认后彻底删除本地 Tunnel 配置
  cloudflare_tunnel.sh help             显示帮助

APT 包会随系统 apt upgrade/full-upgrade 更新。enable-auto-update 会每日运行 apt-get update，
仅在候选版本较新时升级；原服务正在运行时会重启并造成短暂流量中断。
EOF
}

main() {
    local action="${1:-help}"
    case "$action" in
        install) install_cloudflared ;;
        upgrade) upgrade_cloudflared ;;
        status) show_status ;;
        enable-auto-update) enable_auto_update ;;
        disable-auto-update) disable_auto_update "${2:-}" ;;
        migrate-legacy)
            require_root
            check_platform
            install_package
            ;;
        uninstall) uninstall_cloudflared ;;
        purge) purge_config ;;
        help|-h|--help) show_help ;;
        *) error "未知参数: $action"; show_help; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    init_runtime_config
    set -euo pipefail
    main "$@"
fi
