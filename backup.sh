#!/usr/bin/env bash

#===============================================================
#               Komari Dashboard Backup Script
#
# 此脚本支持 Docker 与普通 Linux/VPS 两种运行模式。
# ---------------------------------------------------------------
# 功能:
#   - 将 Komari 面板的数据目录打包到私有 GitHub 仓库。
#   - 将最新备份文件名写入 README.md，供还原脚本读取。
#   - 备份成功后记录本机已同步状态，避免自动还原重复覆盖自己。
#
# 使用方法:
#   - 立即备份: bash backup.sh
#===============================================================

set -o pipefail
#---------------------------------------------------------------
# 运行模式检测（Docker / VPS）
#---------------------------------------------------------------
if [ -f /.dockerenv ] || [ -x /app/komari ]; then
    RUN_MODE="docker"
    WORK_DIR_DEFAULT="/app"
else
    RUN_MODE="vps"
    WORK_DIR_DEFAULT="${KOMARI_HOME:-/opt/komari}"
fi
WORK_DIR="${WORK_DIR:-$WORK_DIR_DEFAULT}"
CONF_DIR="${CONF_DIR:-${WORK_DIR}/conf}"

#---------------------------------------------------------------
# 日志
#---------------------------------------------------------------
if [ "$RUN_MODE" = "vps" ]; then
    LOG_FILE="${LOG_FILE:-${WORK_DIR}/logs/backup.log}"
    RESTORE_STATE_DEFAULT="${WORK_DIR}/logs/last_restore"
else
    LOG_FILE="${LOG_FILE:-/tmp/backup.log}"
    RESTORE_STATE_DEFAULT="/tmp/last_restore"
fi
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
log "backup.sh 启动 — 运行模式: $RUN_MODE | WORK_DIR=$WORK_DIR"

load_env_file() {
    local env_file="${KOMARI_ENV_FILE:-${CONF_DIR}/.env}"
    if [ -f "$env_file" ]; then
        set -o allexport
        # shellcheck disable=SC1090
        . "$env_file"
        set +o allexport
        log "已加载环境配置: $env_file"
    fi
}
load_env_file

#---------------------------------------------------------------
# GITHUB 仓库配置 (建议通过环境变量传递)
#---------------------------------------------------------------
GH_BACKUP_USER="${GH_BACKUP_USER:-your_github_username}"
GH_REPO="${GH_REPO:-your_private_repo_name}"
GH_BACKUP_BRANCH="${GH_BACKUP_BRANCH:-main}"
GH_PAT="${GH_PAT:-your_github_personal_access_token}"
GH_EMAIL="${GH_EMAIL:-}"
if [ -z "$GH_EMAIL" ] || [ "$GH_EMAIL" = "your_github_email@example.com" ]; then
    GH_EMAIL="${GH_BACKUP_USER}@users.noreply.github.com"
fi

#---------------------------------------------------------------
# 备份相关配置
#---------------------------------------------------------------
BACKUP_DAYS="${BACKUP_DAYS:-10}"
# 备份时需要整体排除的目录/文件（相对 DATA_DIR，空格分隔）。
# 默认排除 backup：该目录保存的是面板自身产生的历史备份包，
# 如果一并打包，就成了「把旧备份装进新备份」，每个包都会随运行次数线性膨胀。
# 实测 data/backup 有 91MB，会让每个 tar.gz 达到 94MB：既撑爆小内存容器
# （被 OOM 杀死后容器重启，Web Shell 会直接掉线，看起来像是脚本中断），
# 也会让备份仓库迅速超过 GitHub 限制。
# 若主题/插件可以重新下载，可自行追加，例如：
#   BACKUP_EXCLUDE_PATHS="backup theme plugin-data"
BACKUP_EXCLUDE_PATHS="${BACKUP_EXCLUDE_PATHS:-backup}"
# 本地历史备份保留数量（DATA_DIR/backup 目录）。
# 面板自身会把备份包写到该目录，而它不在本脚本的备份范围内，
# 不清理就会一直堆积占满磁盘。每次备份时按修改时间保留最新的 N 个，
# 更早的自动删除；设为 0 表示不清理、全部保留。
LOCAL_BACKUP_FILE_HISTORY_NUM="${LOCAL_BACKUP_FILE_HISTORY_NUM:-3}"
RESTORE_STATE_FILE="${RESTORE_STATE_FILE:-${RESTORE_FLAG_FILE:-$RESTORE_STATE_DEFAULT}}"
LOCK_DIR="${KOMARI_BACKUP_LOCK_DIR:-/tmp/komari-backup-restore.lock}"
LOCK_TIMEOUT_SECONDS="${KOMARI_LOCK_TIMEOUT_SECONDS:-60}"

#---------------------------------------------------------------
# 面板工作目录配置 (默认与 Dockerfile 中 Komari 的工作路径保持一致)
#---------------------------------------------------------------
DATA_DIR="${DATA_DIR:-${WORK_DIR}/data}"

#---------------------------------------------------------------
# 脚本核心逻辑
#---------------------------------------------------------------
info() { echo -e "\033[32m\033[01m$*\033[0m"; }
error() { log "ERROR: $*"; echo -e "\033[31m\033[01m$*\033[0m"; exit 1; }
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }

BACKUP_TEMP_DIR=""
BACKUP_STAGE_DIR=""
BACKUP_ARCHIVE_PATH=""
ASKPASS_SCRIPT=""
LOCK_ACQUIRED="0"

cleanup() {
    [ -n "$ASKPASS_SCRIPT" ] && rm -f "$ASKPASS_SCRIPT"
    [ -n "$BACKUP_STAGE_DIR" ] && [ -d "$BACKUP_STAGE_DIR" ] && rm -rf "$BACKUP_STAGE_DIR"
    [ -n "$BACKUP_ARCHIVE_PATH" ] && [ -f "$BACKUP_ARCHIVE_PATH" ] && rm -f "$BACKUP_ARCHIVE_PATH"
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
    ASKPASS_SCRIPT=$(mktemp "${KOMARI_BACKUP_TMP_DIR:-/tmp}/komari_git_askpass.XXXXXX") || error "无法创建 Git 认证临时文件。"
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
        snapshot_ok=0
        # komari 运行时可能短暂持有数据库锁，VACUUM INTO 偶发 SQLITE_BUSY，重试几次。
        for _ in 1 2 3 4 5; do
            if sqlite3 "$db_file" "VACUUM INTO '$quoted_tmp';" >/dev/null 2>&1 && [ -f "$tmp_db" ]; then
                snapshot_ok=1
                break
            fi
            rm -f "$tmp_db" 2>/dev/null || true
            sleep 1
        done
        if [ "$snapshot_ok" = "1" ]; then
            mv -f "$tmp_db" "$staged_db"
            rm -f "${staged_db}-wal" "${staged_db}-shm" "${staged_db}-journal"
            hint "已生成 SQLite 一致性快照: $rel_path"
        else
            rm -f "$tmp_db" 2>/dev/null || true
            # VACUUM INTO 失败（通常是数据库被持续占用），退回到已复制的普通文件快照，
            # 避免因单个数据库锁定而中断整次备份。
            hint "SQLite 一致性快照失败，使用普通文件快照: $rel_path"
        fi
    done < <(find "$DATA_DIR" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print)
}

remove_excluded_paths_from_stage() {
    local rel target
    for rel in $BACKUP_EXCLUDE_PATHS; do
        # 去掉前导 ./ 和 /，并拒绝任何可能越出数据目录的路径
        rel="${rel#./}"
        rel="${rel#/}"
        case "$rel" in
            ""|.|..|../*|*/../*|*/..)
                hint "忽略非法的备份排除路径: $rel"
                continue
                ;;
        esac
        target="$BACKUP_STAGE_DIR/data/$rel"
        if [ -e "$target" ]; then
            rm -rf "$target" 2>/dev/null || true
            hint "已从备份中排除: $rel"
        fi
    done
}

validate_snapshot_types() {
    unsupported=$(find "$BACKUP_STAGE_DIR/data" ! -type f ! -type d -print -quit)
    if [ -n "$unsupported" ]; then
        error "数据目录包含不支持的文件类型，拒绝备份: $unsupported"
    fi
}

create_data_snapshot() {
    [ -d "$DATA_DIR" ] || error "备份数据目录不存在: $DATA_DIR"

    mkdir -p "${KOMARI_BACKUP_TMP_DIR:-/tmp}" 2>/dev/null || true
    BACKUP_STAGE_DIR=$(mktemp -d "${KOMARI_BACKUP_TMP_DIR:-/tmp}/komari_backup_stage.XXXXXX") || error "无法创建备份临时目录。"
    mkdir -p "$BACKUP_STAGE_DIR/data"

    hint "正在创建数据快照: $DATA_DIR"
    log "创建数据快照: $DATA_DIR"
    cp -a "$DATA_DIR"/. "$BACKUP_STAGE_DIR/data"/ || error "复制数据目录失败。"
    remove_excluded_paths_from_stage
    snapshot_sqlite_files
    validate_snapshot_types
}

cleanup_old_backups() {
    hint "正在清理旧备份，保留最近 $BACKUP_DAYS 天的数据..."
    local cutoff_seconds cutoff_stamp file file_stamp file_num cutoff_num
    local total=0 deleted=0

    cutoff_seconds=$(($(date -u +%s) - BACKUP_DAYS * 86400))
    cutoff_stamp=$(date -u -d "@$cutoff_seconds" "+%Y-%m-%d-%H%M%S" 2>/dev/null || date -u -r "$cutoff_seconds" "+%Y-%m-%d-%H%M%S" 2>/dev/null || true)
    if [ -z "$cutoff_stamp" ]; then
        hint "无法计算旧备份清理时间，本次跳过清理。"
        return 0
    fi
    cutoff_num="${cutoff_stamp//-/}"

    # 用进程替换而不是管道：管道会让循环跑在子 shell 里，计数器拿不出来。
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        total=$((total + 1))
        file_stamp=$(basename "$file" | sed -n 's/^komari-\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{6\}\)\.tar\.gz$/\1/p')
        file_num="${file_stamp//-/}"
        if [ -n "$file_stamp" ] && [ "$file_num" -lt "$cutoff_num" ] 2>/dev/null; then
            git rm -f --ignore-unmatch --sparse -- "$file" >/dev/null 2>&1 || \
                git rm -f --cached --ignore-unmatch -- "$file" >/dev/null 2>&1 || \
                git update-index --force-remove -- "$file" >/dev/null 2>&1 || true
            rm -f "$file" 2>/dev/null || true
            deleted=$((deleted + 1))
            log "已删除过期远程备份: $file"
        fi
    done < <(list_repo_backup_files)

    if [ "$deleted" -gt 0 ]; then
        hint "远程备份已清理：删除 $deleted 个过期包，保留 $((total - deleted)) 个（保留天数 $BACKUP_DAYS）。"
    else
        hint "远程备份无需清理：当前 $total 个，均在 $BACKUP_DAYS 天内。"
    fi
}

list_repo_backup_files() {
    if git rev-parse --verify HEAD >/dev/null 2>&1; then
        git ls-tree -r --name-only HEAD 2>/dev/null | grep -E '^komari-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\.tar\.gz$' || true
    else
        find . -maxdepth 1 -name 'komari-*.tar.gz' -type f -exec basename {} \; 2>/dev/null || true
    fi
}

path_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# 面板自身产生的备份包会持续堆积在 data/backup 下，而该目录已被
# BACKUP_EXCLUDE_PATHS 排除出备份包，不会随备份上传，因此需要单独的保留策略。
# 每次备份时按修改时间只保留最新的 LOCAL_BACKUP_FILE_HISTORY_NUM 个。
cleanup_local_backup_history() {
    local keep="$LOCAL_BACKUP_FILE_HISTORY_NUM"
    local local_backup_dir="$DATA_DIR/backup"
    local total removed=0 entry target cand

    case "$keep" in
        ''|*[!0-9]*)
            hint "LOCAL_BACKUP_FILE_HISTORY_NUM 不是有效数字（当前: $keep），跳过本地历史备份清理。"
            return 0
            ;;
    esac
    # 0 表示不清理，保留全部
    [ "$keep" -eq 0 ] && return 0
    if [ ! -d "$local_backup_dir" ]; then
        hint "本地备份目录不存在（$local_backup_dir），跳过本地历史备份清理。"
        return 0
    fi

    total=$(find "$local_backup_dir" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$total" -le "$keep" ]; then
        hint "本地历史备份 $total 个，未超过保留数量 $keep，无需清理。"
        return 0
    fi

    hint "正在清理本地历史备份，保留最近 $keep 个（当前共 $total 个）..."
    while IFS= read -r entry; do
        target="${entry#* }"
        [ -n "$target" ] || continue
        [ -f "$target" ] || continue
        if rm -f "$target" 2>/dev/null; then
            removed=$((removed + 1))
            log "已删除本地历史备份: $(basename "$target")"
        fi
    done < <(
        # 按修改时间从新到旧排序，跳过前 keep 个，其余删除；
        # 用 stat 取时间而不用 find -printf，兼顾 busybox 与 GNU find。
        for cand in "$local_backup_dir"/*; do
            [ -f "$cand" ] || continue
            case "${cand##*/}" in .*) continue ;; esac
            printf '%s %s\n' "$(path_mtime "$cand")" "$cand"
        done | sort -rn | tail -n +$((keep + 1))
    )

    if [ "$removed" -gt 0 ]; then
        hint "本地历史备份已保留最近 $keep 个，删除 $removed 个。"
    fi
}

write_latest_metadata() {
    local backup_file="$1"

    # 清理旧版索引文件；README.md 是唯一的自动还原指针。
    rm -f latest.json

    printf '%s\n' "$backup_file" > README.md
}

mark_local_restore_state() {
    local backup_file="$1"
    local backup_sha256="$2"
    mkdir -p "$(dirname "$RESTORE_STATE_FILE")" 2>/dev/null || true
    printf '%s %s\n' "$backup_file" "$backup_sha256" > "$RESTORE_STATE_FILE" 2>/dev/null || true
}

# 备份仓库里存放的是体积较大的二进制快照，而运行容器的内存往往很小
# （实测 512MB 上限，komari/caddy/cloudflared/xray 常驻已占约 267MB）。
# git 打包与增量压缩是备份过程中最吃内存的一步，这里对内存占用设上限，
# 避免在 git add / commit / push 阶段被内核 OOM 杀死。
# core.bigFileThreshold 让大文件不做增量压缩，既省内存也几乎没有体积损失。
configure_git_memory_limits() {
    git config pack.threads 1
    git config pack.windowMemory 32m
    git config pack.deltaCacheSize 16m
    git config core.bigFileThreshold 1m
}

prepare_backup_repo() {
    setup_git_auth
    BACKUP_TEMP_DIR=$(mktemp -d "${KOMARI_BACKUP_TMP_DIR:-/tmp}/komari_backup_repo.XXXXXX") || error "无法创建临时仓库目录。"
    repo_url="https://github.com/$GH_BACKUP_USER/$GH_REPO.git"

    hint "正在轻量克隆备份仓库索引..."
    if git ls-remote --exit-code --heads "$repo_url" "$GH_BACKUP_BRANCH" >/dev/null 2>&1; then
        if git clone --depth 1 --filter=blob:none --no-checkout --branch "$GH_BACKUP_BRANCH" "$repo_url" "$BACKUP_TEMP_DIR" >/dev/null 2>&1; then
            cd "$BACKUP_TEMP_DIR" || error "进入临时仓库目录失败。"
            git sparse-checkout init --no-cone >/dev/null 2>&1 || true
            if ! git sparse-checkout set --no-cone README.md latest.json >/dev/null 2>&1; then
                printf '/README.md\n/latest.json\n' > .git/info/sparse-checkout
            fi
            git checkout "$GH_BACKUP_BRANCH" >/dev/null 2>&1 || true
        else
            error "轻量克隆 GitHub 仓库失败。请检查 GH_PAT、仓库名或网络连接。"
        fi
    else
        cd "$BACKUP_TEMP_DIR" || error "进入临时仓库目录失败。"
        git init -b "$GH_BACKUP_BRANCH" >/dev/null 2>&1 || {
            git init >/dev/null 2>&1 || error "初始化备份仓库失败。"
            git checkout -B "$GH_BACKUP_BRANCH" >/dev/null 2>&1 || error "创建备份分支失败。"
        }
        git remote add origin "$repo_url"
    fi
    git remote set-url origin "$repo_url"
    configure_git_memory_limits
}

do_backup() {
    info "============== 开始执行 Komari 备份任务 =============="
    log "========== 备份任务开始 =========="

    require_command git
    require_command tar
    require_command sha256sum
    require_command mktemp
    require_command cp
    validate_config
    acquire_lock

    cd "$WORK_DIR" || error "无法进入工作目录: $WORK_DIR"
    create_data_snapshot

    TIME=$(date -u "+%Y-%m-%d-%H%M%S")
    CREATED_AT=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
    BACKUP_FILE="komari-$TIME.tar.gz"
    BACKUP_ARCHIVE_PATH=$(mktemp "${KOMARI_BACKUP_TMP_DIR:-/tmp}/komari_archive.XXXXXX.tar.gz") || error "无法创建备份压缩临时文件。"

    hint "正在压缩数据快照..."
    log "压缩数据快照 -> $BACKUP_FILE"
    tar czf "$BACKUP_ARCHIVE_PATH" -C "$BACKUP_STAGE_DIR" data/ || error "压缩数据目录失败。"

    if [ ! -s "$BACKUP_ARCHIVE_PATH" ]; then
        error "压缩文件失败或文件为空。"
    fi
    if ! tar -tzf "$BACKUP_ARCHIVE_PATH" >/dev/null 2>&1; then
        error "备份文件已损坏，无法验证 tar 文件完整性。"
    fi

    BACKUP_SHA256=$(sha256sum "$BACKUP_ARCHIVE_PATH" | awk '{print $1}')
    BACKUP_SIZE=$(wc -c < "$BACKUP_ARCHIVE_PATH" | tr -d ' ')
    BACKUP_SIZE_MB=$((BACKUP_SIZE / 1048576))
    info "文件已压缩为: $BACKUP_FILE (${BACKUP_SIZE_MB}MB)"
    log "备份文件: $BACKUP_FILE sha256=$BACKUP_SHA256 size=$BACKUP_SIZE"

    # GitHub 单个文件上限 100MB，超限后 git push 必定被拒绝。
    # 与其在推送阶段把内存耗尽、被 OOM 杀死（终端只看到连接中断），
    # 不如提前失败并给出可操作的提示。
    if [ "$BACKUP_SIZE" -ge 104857600 ]; then
        error "备份包已达 ${BACKUP_SIZE_MB}MB，超过 GitHub 单文件 100MB 限制，推送必定失败。请检查 BACKUP_EXCLUDE_PATHS 是否已排除 data 目录下的大文件（当前排除: ${BACKUP_EXCLUDE_PATHS:-无}）。"
    elif [ "$BACKUP_SIZE" -ge 52428800 ]; then
        hint "警告：备份包已达 ${BACKUP_SIZE_MB}MB，接近 GitHub 单文件 100MB 限制。"
    fi

    prepare_backup_repo
    cd "$BACKUP_TEMP_DIR" || error "进入临时仓库目录失败。"
    mv "$BACKUP_ARCHIVE_PATH" "$BACKUP_FILE" || error "移动备份文件到仓库工作区失败。"
    rm -f "$BACKUP_ARCHIVE_PATH"
    BACKUP_ARCHIVE_PATH=""
    cleanup_old_backups
    cleanup_local_backup_history
    write_latest_metadata "$BACKUP_FILE"

    # 下面这串 git 操作默认没有任何输出，失败时终端只能看到会话中断，
    # 看不出卡在哪一步，所以这里显式提示进度。
    hint "正在提交并推送备份（仓库较大时耗时较久，请勿关闭页面）..."
    git config user.name "$GH_BACKUP_USER"
    git config user.email "$GH_EMAIL"
    git add --sparse --all 2>/dev/null || git add --all

    if git status --porcelain | grep -q .; then
        git commit -m "Backup at $TIME" || error "创建备份提交失败。"
    else
        info "无新文件或变更需要提交。"
        return
    fi

    if git ls-remote --exit-code --heads origin "$GH_BACKUP_BRANCH" >/dev/null 2>&1; then
        # 多节点共享同一备份仓库时，每次备份都会改写 README.md 第一行，
        # 普通的 pull --rebase 会因 README 冲突而中断备份。
        # 使用 -X theirs 让本次（最新）备份的 README 胜出；
        # 各节点的 tar.gz 文件名含时间戳、互不冲突，会被正常合并保留。
        git fetch --depth 1 --filter=blob:none origin "$GH_BACKUP_BRANCH" || error "拉取远程备份仓库失败。"
        git rebase -X theirs FETCH_HEAD || error "同步远程备份仓库失败。"
    fi

    hint "正在推送到 GitHub..."
    if git push -u origin "$GH_BACKUP_BRANCH"; then
        mark_local_restore_state "$BACKUP_FILE" "$BACKUP_SHA256"
        log "推送成功。"
    info "备份文件和 README.md 已成功上传至 GitHub。"
    else
        error "上传失败。请检查网络或 GitHub PAT 权限。"
    fi

    log "========== 备份任务完成 =========="
    info "============== 备份任务执行完毕 =============="
}

case "${1:-}" in
    "")
        do_backup
        ;;
    *)
        echo "使用方法:"
        echo "  $0       - 立即执行备份"
        echo ""
        echo "注意：立即备份不需要参数；还原功能请使用 restore.sh"
        exit 1
        ;;
esac
