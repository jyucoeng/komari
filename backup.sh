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
# 分卷阈值，同时是单卷大小（MB）。
# GitHub 对仓库内单个文件有 100MB 硬限制，超出后 git push 直接被拒。
# 压缩后体积超过该值时，自动切成 komari-<时间>.tar.gz.part-NN-of-MM 多卷上传。
#   0        = 禁用分卷（回到「超过 100MB 直接报错」的原行为）
#   1 - 99   = 启用分卷（默认 95，给硬限留 5MB 余量）
BACKUP_SPLIT_SIZE_MB="${BACKUP_SPLIT_SIZE_MB:-95}"
# 是否在压缩前先估算体积（1 开启 / 0 关闭）。
# 估算只用于选择「单文件」还是「流式分卷」，最终产出由压缩后的实测大小决定，
# 所以估算偏差不会导致错误结果：估低会就地切分，估高会退回单文件。
BACKUP_SPLIT_PRE_ESTIMATE="${BACKUP_SPLIT_PRE_ESTIMATE:-1}"
# 估算安全系数（百分比）。估算值再乘该系数，宁可高估提前分卷，不可低估。
BACKUP_ESTIMATE_SAFETY_PCT="${BACKUP_ESTIMATE_SAFETY_PCT:-115}"
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
BACKUP_SPLIT_PREFIX=""
ASKPASS_SCRIPT=""
LOCK_ACQUIRED="0"

cleanup() {
    [ -n "$ASKPASS_SCRIPT" ] && rm -f "$ASKPASS_SCRIPT"
    [ -n "$BACKUP_STAGE_DIR" ] && [ -d "$BACKUP_STAGE_DIR" ] && rm -rf "$BACKUP_STAGE_DIR"
    [ -n "$BACKUP_ARCHIVE_PATH" ] && [ -f "$BACKUP_ARCHIVE_PATH" ] && rm -f "$BACKUP_ARCHIVE_PATH"
    # 分卷临时文件：前缀带时间戳，且只在本次运行内使用，可安全按前缀清理
    if [ -n "$BACKUP_SPLIT_PREFIX" ]; then
        rm -f "$BACKUP_SPLIT_PREFIX"* 2>/dev/null || true
    fi
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
    if ! echo "$BACKUP_SPLIT_SIZE_MB" | grep -Eq '^[0-9]+$'; then
        error "BACKUP_SPLIT_SIZE_MB 必须是非负整数（0 表示禁用分卷）。"
    fi
    if [ "$BACKUP_SPLIT_SIZE_MB" -gt 99 ]; then
        error "BACKUP_SPLIT_SIZE_MB 不能大于 99，否则单卷会逼近 GitHub 单文件 100MB 限制。"
    fi
    if [ "$BACKUP_SPLIT_PRE_ESTIMATE" != "0" ] && [ "$BACKUP_SPLIT_PRE_ESTIMATE" != "1" ]; then
        error "BACKUP_SPLIT_PRE_ESTIMATE 只能是 0 或 1。"
    fi
    # 估算只用于选择路径，不影响正确性，因此非法值回退到默认而不是中断备份
    if ! echo "$BACKUP_ESTIMATE_SAFETY_PCT" | grep -Eq '^[0-9]+$' || [ "$BACKUP_ESTIMATE_SAFETY_PCT" -lt 100 ]; then
        hint "BACKUP_ESTIMATE_SAFETY_PCT 不是有效的百分比（当前: $BACKUP_ESTIMATE_SAFETY_PCT），已回退为 115。"
        BACKUP_ESTIMATE_SAFETY_PCT=115
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
    local cutoff_seconds cutoff_stamp backup file file_stamp file_num cutoff_num
    local total=0 deleted=0 removed_files=0

    cutoff_seconds=$(($(date -u +%s) - BACKUP_DAYS * 86400))
    cutoff_stamp=$(date -u -d "@$cutoff_seconds" "+%Y-%m-%d-%H%M%S" 2>/dev/null || date -u -r "$cutoff_seconds" "+%Y-%m-%d-%H%M%S" 2>/dev/null || true)
    if [ -z "$cutoff_stamp" ]; then
        hint "无法计算旧备份清理时间，本次跳过清理。"
        return 0
    fi
    cutoff_num="${cutoff_stamp//-/}"

    # 用进程替换而不是管道：管道会让循环跑在子 shell 里，计数器拿不出来。
    # 遍历的是【逻辑名】（分卷已归并成一条），删除时再展开成该次备份的全部文件。
    while IFS= read -r backup; do
        [ -n "$backup" ] || continue
        total=$((total + 1))
        file_stamp=$(basename "$backup" | sed -n 's/^komari-\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{6\}\)\.tar\.gz$/\1/p')
        file_num="${file_stamp//-/}"
        if [ -n "$file_stamp" ] && [ "$file_num" -lt "$cutoff_num" ] 2>/dev/null; then
            # 整包或全部分卷一起删除，避免留下孤儿分卷
            while IFS= read -r file; do
                [ -n "$file" ] || continue
                git rm -f --ignore-unmatch --sparse -- "$file" >/dev/null 2>&1 || \
                    git rm -f --cached --ignore-unmatch -- "$file" >/dev/null 2>&1 || \
                    git update-index --force-remove -- "$file" >/dev/null 2>&1 || true
                rm -f "$file" 2>/dev/null || true
                removed_files=$((removed_files + 1))
            done < <(repo_files_for_backup "$backup")
            deleted=$((deleted + 1))
            log "已删除过期远程备份: $backup"
        fi
    done < <(list_repo_backup_files)

    if [ "$deleted" -gt 0 ]; then
        if [ "$removed_files" -gt "$deleted" ]; then
            hint "远程备份已清理：删除 $deleted 个过期包（共 $removed_files 个文件，含分卷），保留 $((total - deleted)) 个（保留天数 $BACKUP_DAYS）。"
        else
            hint "远程备份已清理：删除 $deleted 个过期包，保留 $((total - deleted)) 个（保留天数 $BACKUP_DAYS）。"
        fi
    else
        hint "远程备份无需清理：当前 $total 个，均在 $BACKUP_DAYS 天内。"
    fi
}

# 仓库里与备份相关的全部文件名（整包或分卷），未归并
list_repo_backup_raw_files() {
    if git rev-parse --verify HEAD >/dev/null 2>&1; then
        git ls-tree -r --name-only HEAD 2>/dev/null \
            | grep -E '^komari-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\.tar\.gz(\.part-[0-9]{2}-of-[0-9]{2})?$' || true
    else
        find . -maxdepth 1 \( -name 'komari-*.tar.gz' -o -name 'komari-*.tar.gz.part-*' \) -type f -exec basename {} \; 2>/dev/null || true
    fi
}

# 列出备份的【逻辑名】集合：同一次备份的分卷归并成一条，供过期判断使用
list_repo_backup_files() {
    list_repo_backup_raw_files | sed -E 's/\.part-[0-9]{2}-of-[0-9]{2}$//' | sort -u
}

# 列出某个逻辑名对应的全部文件（整包或全部分卷），供成组删除使用。
# 用 case 做字面量匹配而不是正则，避免逻辑名里的 . 被当成通配符。
repo_files_for_backup() {
    local logical="$1" f
    list_repo_backup_raw_files | while IFS= read -r f; do
        case "$f" in
            "$logical"|"$logical".part-*) printf '%s\n' "$f" ;;
        esac
    done
}

path_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

path_size() {
    stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || echo 0
}

# 把字节数格式化成一位小数的 MB（估算值要靠它校准，整数 MB 太粗）
format_mb() {
    local bytes="$1"
    printf '%s.%sMB' "$((bytes / 1048576))" "$(( (bytes % 1048576) * 10 / 1048576 ))"
}

# 估算结果提示语。两种结果都要打出来：估算虽然只决定走哪条压缩路径（最终产出由
# 压缩后的实测大小决定），但用户要靠这个数字校准 BACKUP_ESTIMATE_SAFETY_PCT，
# 只在「超阈值」时显示的话就无从校准了。
describe_estimate() {
    local estimated="$1" threshold_bytes="$2"
    if [ "$estimated" -gt "$threshold_bytes" ]; then
        printf '预估压缩后约 %s，超过阈值 %sMB → 启用分卷压缩' \
            "$(format_mb "$estimated")" "$BACKUP_SPLIT_SIZE_MB"
    else
        printf '预估压缩后约 %s，未超过阈值 %sMB → 按单文件压缩' \
            "$(format_mb "$estimated")" "$BACKUP_SPLIT_SIZE_MB"
    fi
}

# 估算偏差大到值得提示校准时给出建议，否则无输出。
#   估低了 → 会上报大安全系数，免得走完单文件压缩才发现要切分（白多一次 I/O）；
#   估高了 → 可下调安全系数，免得明明很小却去走流式切分。
# 阈值取 ±50%：默认配置下正常偏差在 +15%~+30%（安全系数叠加保守压缩率所致），不该刷屏。
describe_estimate_drift() {
    local estimated="$1" actual="$2"
    [ "$estimated" -gt 0 ] || return 0
    if [ "$actual" -gt $((estimated * 3 / 2)) ]; then
        printf '注意：预估 %s 明显低于实际 %s，如频繁出现可上调 BACKUP_ESTIMATE_SAFETY_PCT（当前 %s）。' \
            "$(format_mb "$estimated")" "$(format_mb "$actual")" "$BACKUP_ESTIMATE_SAFETY_PCT"
    elif [ "$estimated" -gt $((actual * 3 / 2)) ]; then
        printf '注意：预估 %s 明显高于实际 %s，如频繁出现可下调 BACKUP_ESTIMATE_SAFETY_PCT（当前 %s）。' \
            "$(format_mb "$estimated")" "$(format_mb "$actual")" "$BACKUP_ESTIMATE_SAFETY_PCT"
    fi
}

# 批量求文件【表观大小】之和。
# 不用 du：du 统计的是磁盘占用（按块对齐），theme 这类大量小文件会被严重高估；
# 也不用 find -printf：busybox 对它支持不全。stat -c %s 在 busybox 与 GNU 上都可用。
stat_bytes() {
    local root="$1"; shift
    find "$root" -type f "$@" -exec stat -c %s {} + 2>/dev/null \
        | awk '{ s += $1 } END { print s + 0 }'
}

# 压缩前估算压缩后体积。
# 按扩展名分四类加权，只读文件大小、不做压缩，因此在低配容器上耗时可忽略。
# 估算只用于选择「单文件」还是「流式分卷」，最终产出由实测大小决定，
# 所以允许不精确 —— 见 do_backup() 里的实测复检。
estimate_compressed_size() {
    local root="$1"
    local comp db text total other est

    comp=$(stat_bytes "$root" \( \
        -iname '*.zip' -o -iname '*.gz' -o -iname '*.tgz' -o -iname '*.bz2' -o -iname '*.xz' \
        -o -iname '*.zst' -o -iname '*.7z' -o -iname '*.rar' -o -iname '*.jar' \
        -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' \
        -o -iname '*.webp' -o -iname '*.avif' -o -iname '*.heic' -o -iname '*.ico' \
        -o -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.ogg' -o -iname '*.opus' \
        -o -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.webm' \
        -o -iname '*.pdf' -o -iname '*.woff' -o -iname '*.woff2' -o -iname '*.br' \))
    db=$(stat_bytes "$root" \( -iname '*.db' -o -iname '*.sqlite' -o -iname '*.sqlite3' \))
    text=$(stat_bytes "$root" \( \
        -iname '*.txt' -o -iname '*.md' -o -iname '*.json' -o -iname '*.yaml' \
        -o -iname '*.yml' -o -iname '*.toml' -o -iname '*.csv' -o -iname '*.log' \
        -o -iname '*.html' -o -iname '*.htm' -o -iname '*.css' -o -iname '*.js' \
        -o -iname '*.mjs' -o -iname '*.ts' -o -iname '*.xml' -o -iname '*.svg' \
        -o -iname '*.map' -o -iname '*.conf' -o -iname '*.ini' -o -iname '*.sh' \))
    total=$(stat_bytes "$root")

    other=$((total - comp - db - text))
    [ "$other" -lt 0 ] && other=0

    # 压缩率：已压缩 1.00 / 数据库 0.50 / 文本与前端 0.35 / 其他 0.75（保守取值）
    est=$(( (comp * 100 + db * 50 + text * 35 + other * 75) / 100 ))
    est=$(( est * BACKUP_ESTIMATE_SAFETY_PCT / 100 ))
    printf '%s\n' "$est"
}

# 从标准输入流式切分：每卷最多 chunk_mb 个 MiB，先写成 <dir>/<prefix>NN。
# 流式阶段总卷数未知，因此由 finalize_parts() 在结束时统一重命名。
# 输出实际写出的卷数。
# 只用 head -c 与「纯数字」的参数，避免 busybox 对 split -d、dd iflag 支持不一致的问题。
split_stream() {
    local dir="$1" prefix="$2" chunk_mb="$3"
    local n=0 out bytes chunk_bytes
    chunk_bytes=$((chunk_mb * 1048576))
    while :; do
        out=$(printf '%s/%s%02d' "$dir" "$prefix" "$n")
        # 用 head -c 而不是 dd：dd 的 bs/count 在管道上遇到短读就会提前结束，
        # 要凑满一整块需要 GNU 专有的 iflag=fullblock，busybox 不支持。
        head -c "$chunk_bytes" > "$out"
        bytes=$(path_size "$out")
        if [ "$bytes" -le 0 ]; then
            rm -f "$out" 2>/dev/null || true
            break
        fi
        n=$((n + 1))
        [ "$bytes" -lt "$chunk_bytes" ] && break
    done
    printf '%s\n' "$n"
}

# 把 <prefix>NN 按实际卷数重命名成 <logical>.part-NN-of-MM。
# 只有一卷时直接改回 <logical>：这就是「估算偏大也没有代价」的落点 ——
# 估高走流式切分，实际只出一卷，最终产出与单文件完全一致。
finalize_parts() {
    local dir="$1" prefix="$2" logical="$3" count="$4"
    local n src dst

    if [ "$count" -le 0 ]; then
        error "分卷结果为空，压缩可能失败。"
    fi
    if [ "$count" -gt 99 ]; then
        error "分卷数 $count 超过 99，请调大 BACKUP_SPLIT_SIZE_MB。"
    fi
    if [ "$count" -eq 1 ]; then
        mv -f "$dir/${prefix}00" "$dir/$logical" || error "重命名备份文件失败。"
        return 0
    fi

    n=0
    while [ "$n" -lt "$count" ]; do
        src=$(printf '%s/%s%02d' "$dir" "$prefix" "$n")
        dst=$(printf '%s/%s.part-%02d-of-%02d' "$dir" "$logical" "$n" "$count")
        mv -f "$src" "$dst" || error "重命名分卷失败: $src"
        n=$((n + 1))
    done
}

# 对已经存在的单文件归档就地切分（纯 I/O，不重新压缩）。输出卷数。
split_archive_file() {
    local archive="$1" dir="$2" logical="$3"
    local size chunk_mb chunk_bytes total n part

    size=$(path_size "$archive")
    chunk_mb="$BACKUP_SPLIT_SIZE_MB"
    chunk_bytes=$((chunk_mb * 1048576))
    total=$(( (size + chunk_bytes - 1) / chunk_bytes ))
    if [ "$total" -gt 99 ]; then
        error "分卷数 $total 超过 99，请调大 BACKUP_SPLIT_SIZE_MB。"
    fi

    n=0
    while [ "$n" -lt "$total" ]; do
        part=$(printf '%s.part-%02d-of-%02d' "$logical" "$n" "$total")
        # skip 对普通文件走 lseek，因此 N 次切分的总 I/O 约等于一次完整读取
        dd if="$archive" of="$dir/$part" bs=1048576 skip=$((n * chunk_mb)) count="$chunk_mb" 2>/dev/null \
            || error "切分备份文件失败（第 $((n + 1)) 卷）。"
        n=$((n + 1))
    done
    printf '%s\n' "$total"
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

    split_dir="${KOMARI_BACKUP_TMP_DIR:-/tmp}"
    split_prefix="${BACKUP_FILE}.part-"
    split_threshold_bytes=$((BACKUP_SPLIT_SIZE_MB * 1048576))
    split_enabled=0
    [ "$BACKUP_SPLIT_SIZE_MB" -gt 0 ] && split_enabled=1
    part_count=0
    estimated=0

    # ---- [B1] 压缩前估算：只用于选择压缩方式，不决定最终产出 ----
    if [ "$split_enabled" = "1" ] && [ "$BACKUP_SPLIT_PRE_ESTIMATE" = "1" ]; then
        hint "正在估算压缩后体积..."
        estimated=$(estimate_compressed_size "$BACKUP_STAGE_DIR/data")
        log "压缩前估算: ${estimated} 字节，分卷阈值 ${split_threshold_bytes} 字节"
        hint "$(describe_estimate "$estimated" "$split_threshold_bytes")"
    fi

    hint "正在压缩数据快照..."
    log "压缩数据快照 -> $BACKUP_FILE"

    if [ "$split_enabled" = "1" ] && [ "$estimated" -gt "$split_threshold_bytes" ]; then
        # ---- 路径②：流式切分，不落地完整归档，峰值磁盘占用减半 ----
        part_count=$(tar czf - -C "$BACKUP_STAGE_DIR" data/ \
            | split_stream "$split_dir" "$split_prefix" "$BACKUP_SPLIT_SIZE_MB") \
            || error "流式分卷压缩失败。"
        BACKUP_SPLIT_PREFIX="$split_dir/$split_prefix"
        finalize_parts "$split_dir" "$split_prefix" "$BACKUP_FILE" "$part_count"
        rm -f "$BACKUP_ARCHIVE_PATH" 2>/dev/null || true
        BACKUP_ARCHIVE_PATH=""
        if [ "$part_count" -eq 1 ]; then
            hint "实际只需 1 卷，已回退为普通单文件备份。"
            BACKUP_SPLIT_PREFIX=""
            BACKUP_ARCHIVE_PATH="$split_dir/$BACKUP_FILE"
        fi
    else
        # ---- 路径①：普通单文件压缩 ----
        tar czf "$BACKUP_ARCHIVE_PATH" -C "$BACKUP_STAGE_DIR" data/ || error "压缩数据目录失败。"
        if [ ! -s "$BACKUP_ARCHIVE_PATH" ]; then
            error "压缩文件失败或文件为空。"
        fi
        if ! tar -tzf "$BACKUP_ARCHIVE_PATH" >/dev/null 2>&1; then
            error "备份文件已损坏，无法验证 tar 文件完整性。"
        fi
    fi

    # ---- [B2] 实测复检：无论估算怎么说，都以实际大小为准 ----
    if [ "$part_count" -le 1 ] && [ "$split_enabled" = "1" ] \
        && [ "$(path_size "$BACKUP_ARCHIVE_PATH")" -gt "$split_threshold_bytes" ]; then
        hint "实际大小 $(( $(path_size "$BACKUP_ARCHIVE_PATH") / 1048576 ))MB 超过阈值 ${BACKUP_SPLIT_SIZE_MB}MB → 就地切分"
        part_count=$(split_archive_file "$BACKUP_ARCHIVE_PATH" "$split_dir" "$BACKUP_FILE") \
            || error "切分备份文件失败。"
        rm -f "$BACKUP_ARCHIVE_PATH" 2>/dev/null || true
        BACKUP_ARCHIVE_PATH=""
        BACKUP_SPLIT_PREFIX="$split_dir/$split_prefix"
    fi

    # ---- 汇总大小与 sha256（分卷时按序拼接后计算，与还原侧的校验方式一致）----
    if [ "$part_count" -gt 1 ]; then
        BACKUP_SIZE=0
        max_part_bytes=0
        n=0
        while [ "$n" -lt "$part_count" ]; do
            part=$(printf '%s.part-%02d-of-%02d' "$BACKUP_FILE" "$n" "$part_count")
            psize=$(path_size "$split_dir/$part")
            BACKUP_SIZE=$((BACKUP_SIZE + psize))
            [ "$psize" -gt "$max_part_bytes" ] && max_part_bytes=$psize
            n=$((n + 1))
        done
        BACKUP_SHA256=$(cat "$split_dir/$BACKUP_FILE.part-"* | sha256sum | awk '{print $1}')
        info "文件已压缩为: $BACKUP_FILE（分 $part_count 卷，共 $((BACKUP_SIZE / 1048576))MB，最大单卷 $((max_part_bytes / 1048576))MB）"
    else
        part_count=1
        BACKUP_SIZE=$(path_size "$BACKUP_ARCHIVE_PATH")
        max_part_bytes=$BACKUP_SIZE
        BACKUP_SHA256=$(sha256sum "$BACKUP_ARCHIVE_PATH" | awk '{print $1}')
        info "文件已压缩为: $BACKUP_FILE ($((BACKUP_SIZE / 1048576))MB)"
    fi
    log "备份文件: $BACKUP_FILE sha256=$BACKUP_SHA256 size=$BACKUP_SIZE parts=$part_count"

    drift=$(describe_estimate_drift "$estimated" "$BACKUP_SIZE")
    [ -n "$drift" ] && hint "$drift"

    # GitHub 单个文件上限 100MB，超限后 git push 必定被拒绝。
    # 与其在推送阶段把内存耗尽、被 OOM 杀死（终端只看到连接中断），
    # 不如提前失败并给出可操作的提示。
    if [ "$max_part_bytes" -ge 104857600 ]; then
        error "存在超过 GitHub 单文件 100MB 限制的备份文件（最大 $((max_part_bytes / 1048576))MB）。请检查 BACKUP_EXCLUDE_PATHS 是否已排除 data 目录下的大文件（当前排除: ${BACKUP_EXCLUDE_PATHS:-无}），或调小 BACKUP_SPLIT_SIZE_MB。"
    elif [ "$part_count" -eq 1 ] && [ "$max_part_bytes" -ge 52428800 ]; then
        hint "警告：备份包已达 $((max_part_bytes / 1048576))MB，接近 GitHub 单文件 100MB 限制。可调小 BACKUP_SPLIT_SIZE_MB 让它在超限前自动分卷。"
    fi

    prepare_backup_repo
    cd "$BACKUP_TEMP_DIR" || error "进入临时仓库目录失败。"

    if [ "$part_count" -gt 1 ]; then
        n=0
        while [ "$n" -lt "$part_count" ]; do
            part=$(printf '%s.part-%02d-of-%02d' "$BACKUP_FILE" "$n" "$part_count")
            mv "$split_dir/$part" "$part" || error "移动分卷到仓库工作区失败: $part"
            n=$((n + 1))
        done
        BACKUP_SPLIT_PREFIX=""
    else
        mv "$BACKUP_ARCHIVE_PATH" "$BACKUP_FILE" || error "移动备份文件到仓库工作区失败。"
        rm -f "$BACKUP_ARCHIVE_PATH"
        BACKUP_ARCHIVE_PATH=""
    fi
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
