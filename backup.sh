#!/usr/bin/env bash

#===============================================================
#               Komari Dashboard Backup Script
#
# 此脚本专为 Docker 版 Komari 面板数据备份设计。
# ---------------------------------------------------------------
# 功能:
#   - 将 Komari 面板的数据目录打包到私有 GitHub 仓库。
#   - 生成 latest.json，供还原脚本按文件名 + sha256 对比。
#   - 备份成功后记录本机已同步状态，避免自动还原重复覆盖自己。
#
# 使用方法:
#   - 立即备份: bash backup.sh
#===============================================================

set -o pipefail

#---------------------------------------------------------------
# GITHUB 仓库配置 (建议通过环境变量传递)
#---------------------------------------------------------------
GH_BACKUP_USER="${GH_BACKUP_USER:-your_github_username}"
GH_REPO="${GH_REPO:-your_private_repo_name}"
GH_BACKUP_BRANCH="${GH_BACKUP_BRANCH:-main}"
GH_PAT="${GH_PAT:-your_github_personal_access_token}"
GH_EMAIL="${GH_EMAIL:-your_github_email@example.com}"

#---------------------------------------------------------------
# 备份相关配置
#---------------------------------------------------------------
BACKUP_DAYS="${BACKUP_DAYS:-10}"
RESTORE_STATE_FILE="${RESTORE_STATE_FILE:-${RESTORE_FLAG_FILE:-/tmp/last_restore}}"
LOCK_DIR="${KOMARI_BACKUP_LOCK_DIR:-/tmp/komari-backup-restore.lock}"
LOCK_TIMEOUT_SECONDS="${KOMARI_LOCK_TIMEOUT_SECONDS:-60}"

#---------------------------------------------------------------
# 面板工作目录配置 (默认与 Dockerfile 中 Komari 的工作路径保持一致)
#---------------------------------------------------------------
WORK_DIR="${WORK_DIR:-/app}"
DATA_DIR="${DATA_DIR:-${WORK_DIR}/data}"

#---------------------------------------------------------------
# 脚本核心逻辑
#---------------------------------------------------------------
info() { echo -e "\033[32m\033[01m$*\033[0m"; }
error() { echo -e "\033[31m\033[01m$*\033[0m"; exit 1; }
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }

BACKUP_TEMP_DIR=""
BACKUP_STAGE_DIR=""
ASKPASS_SCRIPT=""
LOCK_ACQUIRED="0"

cleanup() {
    [ -n "$ASKPASS_SCRIPT" ] && rm -f "$ASKPASS_SCRIPT"
    [ -n "$BACKUP_STAGE_DIR" ] && [ -d "$BACKUP_STAGE_DIR" ] && rm -rf "$BACKUP_STAGE_DIR"
    [ -n "$BACKUP_TEMP_DIR" ] && [ -d "$BACKUP_TEMP_DIR" ] && rm -rf "$BACKUP_TEMP_DIR"
    if [ "$LOCK_ACQUIRED" = "1" ]; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

require_command() {
    command -v "$1" >/dev/null 2>&1 || error "缺少必需命令: $1"
}

validate_config() {
    if [ "$GH_PAT" = "your_github_personal_access_token" ] || [ -z "$GH_PAT" ]; then
        error "GitHub PAT 未正确设置。请确保在运行容器时使用 -e GH_PAT=... 正确设置。"
    fi
    if [ "$GH_BACKUP_USER" = "your_github_username" ] || [ -z "$GH_BACKUP_USER" ]; then
        error "GH_BACKUP_USER 未正确设置。"
    fi
    if ! printf "%s" "$GH_BACKUP_USER" | grep -Eq '^[A-Za-z0-9_.-]+$'; then
        error "GH_BACKUP_USER 只能包含字母、数字、下划线、点和短横线。"
    fi
    if [ "$GH_REPO" = "your_private_repo_name" ] || [ -z "$GH_REPO" ]; then
        error "GH_REPO 未正确设置。"
    fi
    if ! printf "%s" "$GH_REPO" | grep -Eq '^[A-Za-z0-9_.-]+$'; then
        error "GH_REPO 只能包含字母、数字、下划线、点和短横线。"
    fi
    if ! printf "%s" "$GH_BACKUP_BRANCH" | grep -Eq '^[A-Za-z0-9._/-]+$' ||
        printf "%s" "$GH_BACKUP_BRANCH" | grep -Eq '(^-|^/|/$|\.\.|//|@\{|\.lock$)'; then
        error "GH_BACKUP_BRANCH 不合法。"
    fi
    if ! echo "$BACKUP_DAYS" | grep -Eq '^[0-9]+$'; then
        error "BACKUP_DAYS 必须是正整数。"
    fi
    if [ "$BACKUP_DAYS" -lt 1 ]; then
        error "BACKUP_DAYS 必须大于等于 1。"
    fi
    if ! echo "$LOCK_TIMEOUT_SECONDS" | grep -Eq '^[0-9]+$'; then
        error "KOMARI_LOCK_TIMEOUT_SECONDS 必须是非负整数。"
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
            hint "已有备份或还原任务正在运行，本次备份跳过。"
            exit 0
        fi
        now=$(date +%s)
        mtime=$(lock_mtime)
        if [ -z "$mtime" ] || [ "$mtime" -le 0 ] || [ $((now - mtime)) -ge "$LOCK_TIMEOUT_SECONDS" ]; then
            hint "检测到过期任务锁，正在清理。"
            rm -rf "$LOCK_DIR"
        fi
    fi

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        LOCK_ACQUIRED="1"
        write_lock_owner
    else
        hint "已有备份或还原任务正在运行，本次备份跳过。"
        exit 0
    fi
}

setup_git_auth() {
    ASKPASS_SCRIPT=$(mktemp /tmp/komari_git_askpass.XXXXXX) || error "无法创建 Git 认证临时文件。"
    cat > "$ASKPASS_SCRIPT" <<'EOF'
#!/usr/bin/env sh
case "$1" in
    *Username*) printf '%s\n' "${GH_BACKUP_USER}" ;;
    *Password*) printf '%s\n' "${GH_PAT}" ;;
    *) printf '\n' ;;
esac
EOF
    chmod 700 "$ASKPASS_SCRIPT"
    export GIT_ASKPASS="$ASKPASS_SCRIPT"
    export GIT_TERMINAL_PROMPT=0
}

sqlite_quote() {
    printf "%s" "$1" | sed "s/'/''/g"
}

snapshot_sqlite_files() {
    if ! command -v sqlite3 >/dev/null 2>&1; then
        hint "未找到 sqlite3，数据库文件将使用普通文件快照。"
        return 0
    fi

    while IFS= read -r db_file; do
        [ -f "$db_file" ] || continue
        rel_path="${db_file#$DATA_DIR/}"
        staged_db="$BACKUP_STAGE_DIR/data/$rel_path"
        tmp_db="${staged_db}.snapshot"
        check_file="${tmp_db}.check"

        if ! sqlite3 "$db_file" "PRAGMA quick_check;" > "$check_file" 2>/dev/null; then
            rm -f "$check_file"
            hint "跳过非 SQLite 或暂不可读数据库: $rel_path"
            continue
        fi
        if ! grep -qx "ok" "$check_file"; then
            rm -f "$check_file"
            error "SQLite 数据库校验失败，已停止备份: $rel_path"
        fi
        rm -f "$check_file" "$tmp_db"

        quoted_tmp=$(sqlite_quote "$tmp_db")
        if sqlite3 "$db_file" "VACUUM INTO '$quoted_tmp';" >/dev/null 2>&1; then
            mv -f "$tmp_db" "$staged_db"
            rm -f "${staged_db}-wal" "${staged_db}-shm" "${staged_db}-journal"
            hint "已生成 SQLite 一致性快照: $rel_path"
        else
            rm -f "$tmp_db"
            error "SQLite 数据库快照失败，已停止备份: $rel_path"
        fi
    done < <(find "$DATA_DIR" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print)
}

validate_snapshot_types() {
    unsupported=$(find "$BACKUP_STAGE_DIR/data" ! -type f ! -type d -print -quit)
    if [ -n "$unsupported" ]; then
        error "数据目录包含不支持的文件类型，拒绝备份: $unsupported"
    fi
}

create_data_snapshot() {
    [ -d "$DATA_DIR" ] || error "备份数据目录不存在: $DATA_DIR"

    BACKUP_STAGE_DIR=$(mktemp -d /tmp/komari_backup_stage.XXXXXX) || error "无法创建备份临时目录。"
    mkdir -p "$BACKUP_STAGE_DIR/data"

    hint "正在创建数据快照: $DATA_DIR"
    cp -a "$DATA_DIR"/. "$BACKUP_STAGE_DIR/data"/ || error "复制数据目录失败。"
    snapshot_sqlite_files
    validate_snapshot_types
}

cleanup_old_backups() {
    hint "正在清理旧备份，保留最近 $BACKUP_DAYS 天的数据..."
    local cutoff_seconds cutoff_stamp file file_stamp

    cutoff_seconds=$(($(date -u +%s) - BACKUP_DAYS * 86400))
    cutoff_stamp=$(date -u -d "@$cutoff_seconds" "+%Y-%m-%d-%H%M%S" 2>/dev/null || date -u -r "$cutoff_seconds" "+%Y-%m-%d-%H%M%S" 2>/dev/null || true)
    if [ -z "$cutoff_stamp" ]; then
        hint "无法计算旧备份清理时间，本次跳过清理。"
        return 0
    fi

    find . -maxdepth 1 -name 'komari-*.tar.gz' -type f -print | while IFS= read -r file; do
        file_stamp=$(basename "$file" | sed -n 's/^komari-\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{6\}\)\.tar\.gz$/\1/p')
        if [ -n "$file_stamp" ] && [ "$file_stamp" \< "$cutoff_stamp" ]; then
            rm -f "$file"
        fi
    done
}

write_latest_metadata() {
    local backup_file="$1"
    local backup_sha256="$2"
    local backup_size="$3"
    local created_at="$4"

    cat > latest.json <<EOF
{
  "version": 1,
  "filename": "$backup_file",
  "sha256": "$backup_sha256",
  "size": $backup_size,
  "created_at_utc": "$created_at"
}
EOF

    cat > README.md <<EOF
# Komari Backups

Latest backup: \`$backup_file\`

- Created at (UTC): $created_at
- SHA256: \`$backup_sha256\`
- Size: $backup_size bytes

This repository is used by the Komari backup/restore scripts. Keep it private.
EOF
}

mark_local_restore_state() {
    local backup_file="$1"
    local backup_sha256="$2"
    mkdir -p "$(dirname "$RESTORE_STATE_FILE")" 2>/dev/null || true
    printf '%s %s\n' "$backup_file" "$backup_sha256" > "$RESTORE_STATE_FILE" 2>/dev/null || true
}

prepare_backup_repo() {
    setup_git_auth
    BACKUP_TEMP_DIR=$(mktemp -d /tmp/komari_backup_repo.XXXXXX) || error "无法创建临时仓库目录。"
    repo_url="https://github.com/$GH_BACKUP_USER/$GH_REPO.git"

    hint "正在克隆备份仓库..."
    if ! git clone --depth 1 "$repo_url" "$BACKUP_TEMP_DIR"; then
        error "克隆 GitHub 仓库失败。请检查 GH_PAT、仓库名或网络连接。"
    fi

    cd "$BACKUP_TEMP_DIR" || error "进入临时仓库目录失败。"
    git remote set-url origin "$repo_url"

    if git ls-remote --exit-code --heads origin "$GH_BACKUP_BRANCH" >/dev/null 2>&1; then
        git fetch --depth 1 origin "$GH_BACKUP_BRANCH" || error "拉取备份分支失败。"
        git checkout -B "$GH_BACKUP_BRANCH" FETCH_HEAD >/dev/null 2>&1 || error "切换到备份分支失败。"
    elif git rev-parse --verify HEAD >/dev/null 2>&1; then
        git checkout -B "$GH_BACKUP_BRANCH" >/dev/null 2>&1 || error "创建备份分支失败。"
    else
        git symbolic-ref HEAD "refs/heads/$GH_BACKUP_BRANCH"
    fi
}

do_backup() {
    info "============== 开始执行 Komari 备份任务 =============="

    require_command git
    require_command tar
    require_command sha256sum
    require_command mktemp
    require_command cp
    validate_config
    acquire_lock

    cd "$WORK_DIR" || error "无法进入工作目录: $WORK_DIR"
    create_data_snapshot
    prepare_backup_repo

    TIME=$(date -u "+%Y-%m-%d-%H%M%S")
    CREATED_AT=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
    BACKUP_FILE="komari-$TIME.tar.gz"

    hint "正在压缩数据快照..."
    tar czf "$BACKUP_TEMP_DIR/$BACKUP_FILE" -C "$BACKUP_STAGE_DIR" data/ || error "压缩数据目录失败。"

    if [ ! -s "$BACKUP_TEMP_DIR/$BACKUP_FILE" ]; then
        error "压缩文件失败或文件为空。"
    fi
    if ! tar -tzf "$BACKUP_TEMP_DIR/$BACKUP_FILE" >/dev/null 2>&1; then
        error "备份文件已损坏，无法验证 tar 文件完整性。"
    fi

    BACKUP_SHA256=$(sha256sum "$BACKUP_TEMP_DIR/$BACKUP_FILE" | awk '{print $1}')
    BACKUP_SIZE=$(wc -c < "$BACKUP_TEMP_DIR/$BACKUP_FILE" | tr -d ' ')
    info "文件已压缩为: $BACKUP_FILE"

    cd "$BACKUP_TEMP_DIR" || error "进入临时仓库目录失败。"
    cleanup_old_backups
    write_latest_metadata "$BACKUP_FILE" "$BACKUP_SHA256" "$BACKUP_SIZE" "$CREATED_AT"

    git config user.name "$GH_BACKUP_USER"
    git config user.email "$GH_EMAIL"
    git add --all

    if git status --porcelain | grep -q .; then
        git commit -m "Backup at $TIME" || error "创建备份提交失败。"
    else
        info "无新文件或变更需要提交。"
        return
    fi

    if git ls-remote --exit-code --heads origin "$GH_BACKUP_BRANCH" >/dev/null 2>&1; then
        git pull --rebase origin "$GH_BACKUP_BRANCH" || error "同步远程备份仓库失败。"
    fi

    if git push -u origin "$GH_BACKUP_BRANCH"; then
        mark_local_restore_state "$BACKUP_FILE" "$BACKUP_SHA256"
        info "备份文件、latest.json 和 README.md 已成功上传至 GitHub。"
    else
        error "上传失败。请检查网络或 GitHub PAT 权限。"
    fi

    info "============== 备份任务执行完毕 =============="
}

case "${1:-}" in
    ""|bak|backup|now|a)
        do_backup
        ;;
    *)
        echo "使用方法:"
        echo "  $0       - 立即执行备份"
        echo ""
        echo "注意：还原功能请使用 restore.sh"
        exit 1
        ;;
esac
