#!/usr/bin/env bash

#===============================================================
#           Komari Dashboard Auto-Restore Script
#
# 此脚本用于自动检测和还原 Komari 面板备份数据。
# ---------------------------------------------------------------
# 功能:
#   - 每分钟读取 GitHub 备份库中的 latest.json 或 README.md。
#   - 使用文件名 + sha256 比对，避免同名覆盖或坏包误判。
#   - 下载、校验、解包到临时目录后再替换 data，避免还原失败时删库。
#   - 支持手动指定备份文件、不带参数选择备份文件、README.md 触发立即备份。
#
# 使用方法:
#   - 自动还原（Supervisor/Cron 调用）: bash restore.sh a
#   - 手动还原（指定文件）: bash restore.sh {filename}
#   - 强制还原（忽略本地记录）: bash restore.sh f
#   - 交互选择备份: bash restore.sh
#===============================================================

set -o pipefail

#---------------------------------------------------------------
# GitHub 仓库配置
#---------------------------------------------------------------
GH_BACKUP_USER="${GH_BACKUP_USER:-}"
GH_REPO="${GH_REPO:-}"
GH_BACKUP_BRANCH="${GH_BACKUP_BRANCH:-main}"
GH_PAT="${GH_PAT:-}"
GH_EMAIL="${GH_EMAIL:-}"

#---------------------------------------------------------------
# 面板工作目录配置
#---------------------------------------------------------------
WORK_DIR="${WORK_DIR:-/app}"
DATA_DIR="${DATA_DIR:-${WORK_DIR}/data}"
RESTORE_STATE_FILE="${RESTORE_STATE_FILE:-${RESTORE_FLAG_FILE:-/tmp/last_restore}}"
RESTORE_LOG="${RESTORE_LOG:-/tmp/restore.log}"
LOCK_DIR="${KOMARI_BACKUP_LOCK_DIR:-/tmp/komari-backup-restore.lock}"
LOCK_TIMEOUT_SECONDS="${KOMARI_LOCK_TIMEOUT_SECONDS:-60}"
BACKUP_SCRIPT="${BACKUP_SCRIPT:-${WORK_DIR}/backup.sh}"
NO_ACTION_FLAG="${KOMARI_NO_ACTION_FLAG:-/tmp/komari-no-action}"

#---------------------------------------------------------------
# 脚本核心逻辑
#---------------------------------------------------------------
info() { echo -e "\033[32m\033[01m$*\033[0m"; }
error() { echo -e "\033[31m\033[01m$*\033[0m" >&2; exit 1; }
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }

DOWNLOAD_PATH=""
EXTRACT_DIR=""
OLD_DATA_DIR=""
LOCK_ACQUIRED="0"

cleanup() {
    [ -n "$DOWNLOAD_PATH" ] && rm -f "$DOWNLOAD_PATH"
    [ -n "$EXTRACT_DIR" ] && [ -d "$EXTRACT_DIR" ] && rm -rf "$EXTRACT_DIR"
    if [ -n "$OLD_DATA_DIR" ] && [ -d "$OLD_DATA_DIR" ]; then
        rm -rf "$DATA_DIR"
        mv "$OLD_DATA_DIR" "$DATA_DIR" 2>/dev/null || rm -rf "$OLD_DATA_DIR"
    fi
    if [ "$LOCK_ACQUIRED" = "1" ]; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

log() {
    mkdir -p "$(dirname "$RESTORE_LOG")" 2>/dev/null || true
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*" >> "$RESTORE_LOG"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || error "缺少必需命令: $1"
}

check_env() {
    if [ -z "$GH_BACKUP_USER" ] || [ -z "$GH_REPO" ] || [ -z "$GH_PAT" ]; then
        log "错误：备份相关环境变量未全部设置 (GH_BACKUP_USER, GH_REPO, GH_PAT)"
        error "备份相关环境变量未全部设置 (GH_BACKUP_USER, GH_REPO, GH_PAT)。"
    fi
    if ! printf "%s" "$GH_BACKUP_USER" | grep -Eq '^[A-Za-z0-9_.-]+$'; then
        error "GH_BACKUP_USER 只能包含字母、数字、下划线、点和短横线。"
    fi
    if ! printf "%s" "$GH_REPO" | grep -Eq '^[A-Za-z0-9_.-]+$'; then
        error "GH_REPO 只能包含字母、数字、下划线、点和短横线。"
    fi
    if ! printf "%s" "$GH_BACKUP_BRANCH" | grep -Eq '^[A-Za-z0-9._/-]+$' ||
        printf "%s" "$GH_BACKUP_BRANCH" | grep -Eq '(^-|^/|/$|\.\.|//|@\{|\.lock$)'; then
        error "GH_BACKUP_BRANCH 不合法。"
    fi
}

lock_mtime() {
    local mtime
    mtime=$(stat -c %Y "$LOCK_DIR" 2>/dev/null || stat -f %m "$LOCK_DIR" 2>/dev/null || ls -ldn --time-style=+%s "$LOCK_DIR" 2>/dev/null | awk '{print $6}' || true)
    if printf "%s" "$mtime" | grep -Eq '^[0-9]+$'; then
        printf '%s\n' "$mtime"
    fi
}

lock_owner_pid() {
    [ -f "$LOCK_DIR/owner" ] || return 1
    sed -n 's/^pid=//p' "$LOCK_DIR/owner" 2>/dev/null | sed -n '1p'
}

lock_owner_alive() {
    local pid cmd
    pid=$(lock_owner_pid || true)
    if ! printf "%s" "$pid" | grep -Eq '^[0-9]+$'; then
        return 1
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
        return 1
    fi
    if [ -r "/proc/$pid/cmdline" ]; then
        cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
        case "$cmd" in
            *backup.sh*|*restore.sh*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

write_lock_owner() {
    {
        printf 'pid=%s\n' "$$"
        printf 'script=%s\n' "$(basename "$0")"
        printf 'created_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } > "$LOCK_DIR/owner" 2>/dev/null || true
}

acquire_lock() {
    local now mtime
    if [ -d "$LOCK_DIR" ]; then
        if lock_owner_alive; then
            log "已有备份或还原任务正在运行，本次还原跳过"
            exit 0
        fi
        now=$(date +%s)
        mtime=$(lock_mtime)
        if [ -z "$mtime" ] || [ "$mtime" -le 0 ] || [ $((now - mtime)) -ge "$LOCK_TIMEOUT_SECONDS" ]; then
            log "检测到过期任务锁，正在清理"
            rm -rf "$LOCK_DIR"
        fi
    fi

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        LOCK_ACQUIRED="1"
        write_lock_owner
    else
        log "已有备份或还原任务正在运行，本次还原跳过"
        exit 0
    fi
}

api_get() {
    local url="$1"
    curl -fsSL \
        -H "Authorization: Bearer $GH_PAT" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$url"
}

api_get_raw() {
    local url="$1"
    curl -fsSL \
        -H "Authorization: Bearer $GH_PAT" \
        -H "Accept: application/vnd.github.raw" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$url"
}

raw_download() {
    local url="$1"
    local output="$2"
    curl -fsSL \
        -H "Authorization: Bearer $GH_PAT" \
        -H "Accept: application/vnd.github.raw" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$url" \
        -o "$output"
}

json_value() {
    local key="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r ".$key // empty"
    else
        sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p; s/.*\"$key\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -n 1
    fi
}

valid_backup_filename() {
    printf "%s" "$1" | grep -Eq '^komari-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\.tar\.gz$'
}

valid_sha256() {
    printf "%s" "$1" | grep -Eq '^[a-fA-F0-9]{64}$'
}

valid_size() {
    printf "%s" "$1" | grep -Eq '^[1-9][0-9]*$'
}

contents_url() {
    local path="$1"
    printf 'https://api.github.com/repos/%s/%s/contents/%s?ref=%s\n' "$GH_BACKUP_USER" "$GH_REPO" "$path" "$GH_BACKUP_BRANCH"
}

read_backup_readme() {
    api_get_raw "$(contents_url README.md)" 2>/dev/null || true
}

readme_command_or_file() {
    read_backup_readme | sed '/^[[:space:]]*$/d' | head -n 1 | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

metadata_from_readme() {
    local readme filename sha256 size
    readme=$(read_backup_readme)
    [ -n "$readme" ] || return 1
    filename=$(printf "%s\n" "$readme" | grep -Eo 'komari-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\.tar\.gz' | head -n 1)
    sha256=$(printf "%s\n" "$readme" | grep -Eio '[a-f0-9]{64}' | head -n 1)
    size=$(printf "%s\n" "$readme" | sed -n 's/.*Size:[^0-9]*\([0-9][0-9]*\).*/\1/ip' | head -n 1)
    if valid_backup_filename "$filename"; then
        printf '%s %s %s\n' "$filename" "${sha256:-unknown}" "${size:-0}"
        return 0
    fi
    return 1
}

maybe_trigger_backup_from_readme() {
    local command
    command=$(readme_command_or_file)
    if printf "%s" "$command" | grep -Eiq '^backup$|^backup[[:space:]]+now$|^now$|^立即备份$'; then
        log "README.md 请求立即备份，开始执行 backup.sh"
        mkdir -p /tmp 2>/dev/null || true
        : > "${NO_ACTION_FLAG}.0" 2>/dev/null || true
        if [ -x "$BACKUP_SCRIPT" ] || [ -f "$BACKUP_SCRIPT" ]; then
            bash "$BACKUP_SCRIPT"
        else
            error "README.md 请求备份，但找不到备份脚本: $BACKUP_SCRIPT"
        fi
        exit 0
    fi
}

read_index_metadata() {
    local metadata filename sha256 size
    if metadata=$(api_get_raw "$(contents_url latest.json)" 2>/dev/null); then
        filename=$(printf "%s" "$metadata" | json_value filename)
        sha256=$(printf "%s" "$metadata" | json_value sha256)
        size=$(printf "%s" "$metadata" | json_value size)
        if valid_backup_filename "$filename" && valid_sha256 "$sha256" && valid_size "$size"; then
            printf '%s %s %s\n' "$filename" "$sha256" "$size"
            return 0
        fi
        log "latest.json 存在但格式无效，尝试读取 README.md。"
    fi

    metadata_from_readme
}

read_latest_metadata() {
    if read_index_metadata; then
        return 0
    fi
    get_latest_backup_from_listing
}

get_latest_backup_from_listing() {
    local contents filename file_meta sha256 size
    contents=$(api_get "$(contents_url '')" 2>/dev/null || true)
    if command -v jq >/dev/null 2>&1; then
        filename=$(printf "%s" "$contents" | jq -r '.[].name // empty' 2>/dev/null | grep -E '^komari-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\.tar\.gz$' | sort -r | head -n 1)
    else
        filename=$(printf "%s" "$contents" | grep -oE 'komari-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\.tar\.gz' | sort -r | head -n 1)
    fi
    if [ -z "$filename" ]; then
        printf '\n'
        return 0
    fi

    file_meta=$(get_file_metadata_direct "$filename") || return 0
    sha256=$(printf "%s" "$file_meta" | awk '{print $2}')
    size=$(printf "%s" "$file_meta" | awk '{print $3}')
    printf '%s %s %s\n' "$filename" "$sha256" "$size"
}

get_file_metadata_direct() {
    local filename="$1"
    local metadata api_size

    valid_backup_filename "$filename" || error "备份文件名非法: $filename"

    metadata=$(api_get "$(contents_url "$filename")" 2>/dev/null || true)
    if [ -z "$metadata" ]; then
        return 1
    fi

    api_size=$(printf "%s" "$metadata" | json_value size)
    valid_size "$api_size" || return 1

    # GitHub contents API 的 sha 是 blob sha，不是文件 sha256。sha256 会在下载后计算。
    printf '%s %s %s\n' "$filename" "unknown" "$api_size"
}

get_file_metadata() {
    local filename="$1"
    local latest_state latest_file latest_sha256 latest_size

    valid_backup_filename "$filename" || error "备份文件名非法: $filename"

    if latest_state=$(read_index_metadata 2>/dev/null); then
        latest_file=$(printf "%s" "$latest_state" | awk '{print $1}')
        latest_sha256=$(printf "%s" "$latest_state" | awk '{print $2}')
        latest_size=$(printf "%s" "$latest_state" | awk '{print $3}')
        if [ "$filename" = "$latest_file" ]; then
            printf '%s %s %s\n' "$filename" "${latest_sha256:-unknown}" "${latest_size:-0}"
            return 0
        fi
    fi

    get_file_metadata_direct "$filename"
}

get_last_restore_state() {
    if [ -f "$RESTORE_STATE_FILE" ]; then
        awk 'NF >= 2 {print $1 " " $2; exit} NF == 1 {print $1 " legacy"; exit}' "$RESTORE_STATE_FILE"
    else
        printf '\n'
    fi
}

save_restore_state() {
    local backup_file="$1"
    local backup_sha256="$2"
    mkdir -p "$(dirname "$RESTORE_STATE_FILE")" 2>/dev/null || true
    printf '%s %s\n' "$backup_file" "$backup_sha256" > "$RESTORE_STATE_FILE"
}

validate_tar_members() {
    local archive="$1"
    local invalid unsupported

    invalid=$(tar -tzf "$archive" 2>/dev/null | awk '
        $0 == "data" || $0 == "data/" { next }
        $0 ~ /^data\// && $0 !~ /(^|\/)\.\.($|\/)/ { next }
        { print; exit }
    ')
    if [ -n "$invalid" ]; then
        error "备份包包含非法路径，拒绝还原: $invalid"
    fi

    unsupported=$(tar -tvzf "$archive" 2>/dev/null | awk '
        /^[d-]/ { next }
        { print; exit }
    ')
    if [ -n "$unsupported" ]; then
        error "备份包包含非常规文件类型，拒绝还原: $unsupported"
    fi
}

verify_download() {
    local archive="$1"
    local expected_sha256="$2"
    local expected_size="$3"
    local actual_sha256 actual_size

    [ -s "$archive" ] || error "下载的备份文件为空。"
    actual_size=$(wc -c < "$archive" | tr -d ' ')
    if valid_size "$expected_size" && [ "$expected_size" != "0" ] && [ "$actual_size" != "$expected_size" ]; then
        error "备份文件大小不匹配，拒绝还原。期望 $expected_size，实际 $actual_size。"
    fi

    actual_sha256=$(sha256sum "$archive" | awk '{print $1}')
    if valid_sha256 "$expected_sha256" && [ "$actual_sha256" != "$expected_sha256" ]; then
        error "备份文件 sha256 不匹配，拒绝还原。"
    elif ! valid_sha256 "$expected_sha256"; then
        log "未提供可信 sha256 期望值，仅记录实际 sha256=$actual_sha256"
    fi

    if ! tar -tzf "$archive" >/dev/null 2>&1; then
        error "备份文件不是有效的 tar.gz，拒绝还原。"
    fi
    validate_tar_members "$archive"

    printf '%s\n' "$actual_sha256"
}

download_backup_file() {
    local backup_file="$1"
    local output="$2"

    raw_download "$(contents_url "$backup_file")" "$output" || error "下载备份文件失败: $backup_file"
}

replace_data_dir() {
    local new_data="$1"
    local data_parent old_dir

    [ -d "$new_data" ] || error "备份包中没有 data 目录，拒绝还原。"
    cd "$WORK_DIR" || error "无法进入工作目录: $WORK_DIR"

    data_parent=$(dirname "$DATA_DIR")
    mkdir -p "$data_parent" || error "无法创建数据目录父目录: $data_parent"
    old_dir=$(mktemp -d "$data_parent/.komari-data-old.XXXXXX") || error "无法创建旧数据临时目录。"
    rmdir "$old_dir" || error "无法初始化旧数据临时目录。"

    if [ -d "$DATA_DIR" ]; then
        mv "$DATA_DIR" "$old_dir" || error "移动旧数据目录失败。"
        OLD_DATA_DIR="$old_dir"
    fi

    # Komari may recreate DATA_DIR between the old-dir move and the restore move.
    # Remove that fresh placeholder so the backup directory lands at DATA_DIR itself.
    if [ -e "$DATA_DIR" ]; then
        rm -rf "$DATA_DIR" || error "清理新建数据目录失败，已停止还原。"
    fi

    if mv "$new_data" "$DATA_DIR"; then
        [ -n "$OLD_DATA_DIR" ] && rm -rf "$OLD_DATA_DIR"
        OLD_DATA_DIR=""
    else
        if [ -n "$OLD_DATA_DIR" ] && [ -d "$OLD_DATA_DIR" ]; then
            mv "$OLD_DATA_DIR" "$DATA_DIR" 2>/dev/null || true
        fi
        OLD_DATA_DIR=""
        error "替换数据目录失败，已尝试恢复旧数据。"
    fi
}

restart_komari_if_possible() {
    local pid

    if [ "${KOMARI_RESTORE_SKIP_RESTART:-}" = "1" ]; then
        log "启动前还原已完成，跳过 Komari 进程重启。"
        return 0
    fi

    if command -v supervisorctl >/dev/null 2>&1; then
        if supervisorctl -c /etc/supervisor.d/damon.conf restart komari >/dev/null 2>&1; then
            log "已通过 Supervisor 重启 Komari 进程以加载还原数据"
            return 0
        fi
        log "Supervisor 重启 Komari 失败，尝试发送 TERM 让 Supervisor 自动拉起。"
    fi

    if command -v pidof >/dev/null 2>&1; then
        pid=$(pidof komari 2>/dev/null || true)
    else
        pid=$(pgrep -x komari 2>/dev/null || true)
    fi

    if [ -n "$pid" ]; then
        kill -TERM $pid >/dev/null 2>&1 && {
            log "已向 Komari 进程发送 TERM，等待 Supervisor 自动重启。"
            return 0
        }
    fi

    log "未能自动重启 Komari；如果面板未立即生效，请重启容器。"
}

do_restore() {
    local backup_file="$1"
    local expected_sha256="${2:-}"
    local expected_size="${3:-}"
    local actual_sha256

    info "开始还原备份: $backup_file"
    log "开始还原备份: $backup_file"

    valid_backup_filename "$backup_file" || error "备份文件名非法: $backup_file"

    DOWNLOAD_PATH=$(mktemp /tmp/komari_restore.XXXXXX.tar.gz) || error "无法创建下载临时文件。"
    EXTRACT_DIR=$(mktemp -d /tmp/komari_restore_extract.XXXXXX) || error "无法创建解压临时目录。"

    hint "正在下载备份文件..."
    download_backup_file "$backup_file" "$DOWNLOAD_PATH"

    hint "正在校验备份文件..."
    if ! actual_sha256=$(verify_download "$DOWNLOAD_PATH" "$expected_sha256" "$expected_size"); then
        error "备份文件校验失败，拒绝还原。"
    fi

    hint "正在解压备份文件..."
    tar xzf "$DOWNLOAD_PATH" -C "$EXTRACT_DIR" || error "解压备份文件失败。"

    hint "正在替换数据目录..."
    replace_data_dir "$EXTRACT_DIR/data"

    save_restore_state "$backup_file" "$actual_sha256"
    restart_komari_if_possible

    info "备份文件已成功还原: $backup_file"
    log "备份文件已成功还原: $backup_file sha256=$actual_sha256"
}

auto_restore() {
    local latest_state latest_file latest_sha256 latest_size last_state last_file last_sha256 is_new_backup

    check_env
    maybe_trigger_backup_from_readme
    acquire_lock

    if ! latest_state=$(read_latest_metadata); then
        error "无法读取可信的最新备份索引，拒绝还原。"
    fi
    if [ -z "$latest_state" ]; then
        log "未找到任何备份文件"
        exit 0
    fi

    latest_file=$(printf "%s" "$latest_state" | awk '{print $1}')
    latest_sha256=$(printf "%s" "$latest_state" | awk '{print $2}')
    latest_size=$(printf "%s" "$latest_state" | awk '{print $3}')

    last_state=$(get_last_restore_state)
    last_file=$(printf "%s" "$last_state" | awk '{print $1}')
    last_sha256=$(printf "%s" "$last_state" | awk '{print $2}')

    if valid_sha256 "$latest_sha256"; then
        is_new_backup=false
        if [ "$latest_file" != "$last_file" ] || [ "$latest_sha256" != "$last_sha256" ]; then
            is_new_backup=true
        fi
    else
        is_new_backup=false
        if [ "$latest_file" != "$last_file" ]; then
            is_new_backup=true
        fi
        latest_sha256=""
    fi

    if [ "$is_new_backup" = "true" ]; then
        info "检测到新的备份文件: $latest_file"
        log "检测到新的备份文件: $latest_file sha256=$latest_sha256"
        do_restore "$latest_file" "$latest_sha256" "$latest_size"
    else
        log "本地与远程备份状态一致，无需还原"
    fi
}

manual_restore() {
    local backup_file="$1"
    local file_state file_size latest_state latest_file latest_sha256 latest_size expected_sha256 expected_size

    if [ -z "$backup_file" ]; then
        select_backup_file
        return
    fi
    backup_file=$(basename "$backup_file")

    check_env
    acquire_lock

    file_state=$(get_file_metadata "$backup_file") || error "无法获取备份文件信息: $backup_file"
    file_size=$(printf "%s" "$file_state" | awk '{print $3}')
    expected_sha256=""
    expected_size="$file_size"
    if latest_state=$(read_index_metadata 2>/dev/null); then
        latest_file=$(printf "%s" "$latest_state" | awk '{print $1}')
        latest_sha256=$(printf "%s" "$latest_state" | awk '{print $2}')
        latest_size=$(printf "%s" "$latest_state" | awk '{print $3}')
        if [ "$backup_file" = "$latest_file" ] && valid_sha256 "$latest_sha256"; then
            expected_sha256="$latest_sha256"
            valid_size "$latest_size" && expected_size="$latest_size"
        fi
    fi
    do_restore "$backup_file" "$expected_sha256" "$expected_size"
}

list_backup_files() {
    local contents
    contents=$(api_get "$(contents_url '')" 2>/dev/null || true)
    if command -v jq >/dev/null 2>&1; then
        printf "%s" "$contents" | jq -r '.[].name // empty' 2>/dev/null | grep -E '^komari-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\.tar\.gz$' | sort -r
    else
        printf "%s" "$contents" | grep -oE 'komari-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\.tar\.gz' | sort -r | uniq
    fi
}

select_backup_file() {
    local files count choice selected
    check_env
    files=$(list_backup_files)
    count=$(printf "%s\n" "$files" | sed '/^$/d' | wc -l | tr -d ' ')
    [ "$count" -gt 0 ] || error "备份仓库中没有找到 komari-*.tar.gz"
    printf "%s\n" "$files" | awk '{printf "%d. %s\n", NR, $0}'
    printf "请选择要还原的备份文件 [1-%s]: " "$count"
    read -r choice
    if ! printf "%s" "$choice" | grep -Eq '^[0-9]+$' || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        error "选择无效。"
    fi
    selected=$(printf "%s\n" "$files" | sed -n "${choice}p")
    manual_restore "$selected"
}

force_restore() {
    local latest_state latest_file latest_sha256 latest_size

    check_env
    maybe_trigger_backup_from_readme
    acquire_lock

    if ! latest_state=$(read_latest_metadata); then
        error "无法读取可信的最新备份索引，拒绝还原。"
    fi
    if [ -z "$latest_state" ]; then
        error "未找到任何备份文件"
    fi

    latest_file=$(printf "%s" "$latest_state" | awk '{print $1}')
    latest_sha256=$(printf "%s" "$latest_state" | awk '{print $2}')
    latest_size=$(printf "%s" "$latest_state" | awk '{print $3}')

    info "执行强制还原: $latest_file"
    log "执行强制还原: $latest_file sha256=$latest_sha256"
    do_restore "$latest_file" "$latest_sha256" "$latest_size"
}

case "${1:-}" in
    a)
        require_command curl
        require_command tar
        require_command sha256sum
        auto_restore
        ;;
    bak|backup|now)
        check_env
        if [ -x "$BACKUP_SCRIPT" ] || [ -f "$BACKUP_SCRIPT" ]; then
            bash "$BACKUP_SCRIPT"
        else
            error "找不到备份脚本: $BACKUP_SCRIPT"
        fi
        ;;
    f)
        require_command curl
        require_command tar
        require_command sha256sum
        force_restore
        ;;
    "")
        require_command curl
        require_command tar
        require_command sha256sum
        select_backup_file
        ;;
    *)
        require_command curl
        require_command tar
        require_command sha256sum
        manual_restore "$1"
        ;;
esac
