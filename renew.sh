#!/usr/bin/env bash

#===============================================================
#        Komari Dashboard Auto-Renew Scripts
#
# 此脚本用于自动更新 backup.sh、restore.sh、renew.sh、sub_link.sh 和 repo.conf
# ---------------------------------------------------------------
# 功能:
#   - 每天定时从 GitHub 获取最新的备份、还原和订阅脚本
#   - 比对哈希值，如果有变化则自动替换
#   - 无需重新构建镜像即可获得最新的脚本
#===============================================================

#---------------------------------------------------------------
# 配置
#---------------------------------------------------------------

# 运行模式检测
if [ -f /.dockerenv ] || [ -x /app/komari ]; then
    RUN_MODE="docker"
    WORK_DIR_DEFAULT="/app"
    SCRIPT_DIR_DEFAULT="/app"
    CONF_DIR_DEFAULT="/app"
else
    RUN_MODE="vps"
    WORK_DIR_DEFAULT="${KOMARI_HOME:-/opt/komari}"
    SCRIPT_DIR_DEFAULT="${KOMARI_HOME:-/opt/komari}/scripts"
    CONF_DIR_DEFAULT="${KOMARI_HOME:-/opt/komari}/conf"
fi

# 日志
WORK_DIR="${WORK_DIR:-$WORK_DIR_DEFAULT}"
SCRIPT_DIR="${SCRIPT_DIR:-$SCRIPT_DIR_DEFAULT}"
CONF_DIR="${CONF_DIR:-$CONF_DIR_DEFAULT}"
if [ "$RUN_MODE" = "vps" ]; then
    RENEW_LOG="${RENEW_LOG:-${WORK_DIR}/logs/renew.log}"
else
    RENEW_LOG="${RENEW_LOG:-/tmp/renew.log}"
fi
mkdir -p "$(dirname "$RENEW_LOG")" 2>/dev/null || true
log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*" >> "$RENEW_LOG"; }
log "renew.sh start - mode: $RUN_MODE"
TEMP_DIR="/tmp/renew_scripts"

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
REPO_CONF="${REPO_CONF:-$CONF_DIR/repo.conf}"
if [ -f "$REPO_CONF" ]; then
    . "$REPO_CONF"
fi
if [ -n "${KOMARI_SOURCE_REPOSITORY:-}" ]; then
    SOURCE_REPOSITORY="$KOMARI_SOURCE_REPOSITORY"
elif [ -n "${KOMARI_PROJECT_OWNER:-}" ] && [ -n "${KOMARI_PROJECT_NAME:-}" ]; then
    SOURCE_REPOSITORY="$KOMARI_PROJECT_OWNER/$KOMARI_PROJECT_NAME"
else
    SOURCE_REPOSITORY=""
fi
SOURCE_BRANCH="${KOMARI_SOURCE_BRANCH:-main}"
if [ -z "$SOURCE_REPOSITORY" ]; then
    echo "错误：未配置 KOMARI_SOURCE_REPOSITORY，请检查 $REPO_CONF" >&2
    exit 1
fi

#---------------------------------------------------------------
# 脚本核心逻辑
#---------------------------------------------------------------

# 颜色定义
info() { echo -e "\033[32m\033[01m$*\033[0m"; }     # 绿色
error() { log "ERROR: $*"; echo -e "\033[31m\033[01m$*\033[0m" && exit 1; } # 红色
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }     # 黄色

# 初始化临时目录
init_temp_dir() {
    mkdir -p "$TEMP_DIR"
    chmod 700 "$TEMP_DIR"
}

# 清理临时目录
cleanup_temp_dir() {
    rm -rf "$TEMP_DIR"
}

# 下载脚本
download_file() {
    local url="$1" output_path="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout "${HTTP_CONNECT_TIMEOUT:-10}" --max-time "${HTTP_MAX_TIME:-30}" -o "$output_path" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$output_path" "$url"
    else
        error "缺少下载工具：curl 或 wget"
    fi
}

download_script() {
    local script_name="$1"
    local output_path="$TEMP_DIR/$script_name"
    local cache_bust url
    cache_bust="${RENEW_CACHE_BUST:-$(date -u +%Y%m%d%H%M%S)}"
    url="https://raw.githubusercontent.com/$SOURCE_REPOSITORY/$SOURCE_BRANCH/$script_name?ts=$cache_bust"

    hint "正在下载 $script_name..."
    log "Downloading $script_name"
    log "下载 $script_name <- $SOURCE_REPOSITORY/$SOURCE_BRANCH (cache_bust=$cache_bust)"

    if ! download_file "$url" "$output_path" 2>/dev/null; then
        error "下载 $script_name 失败: $url"
    fi

    if ! bash -n "$output_path" >/dev/null 2>&1; then
        rm -f "$output_path"
        error "下载的 $script_name 语法损坏或不完整，放弃更新"
    fi

    if [ ! -s "$output_path" ]; then
        error "下载的 $script_name 文件为空"
    fi

    chmod +x "$output_path"
    info "已下载 $script_name"
}

# 计算文件哈希值（使用 SHA256 替代 MD5）
get_file_hash() {
    local file="$1"
    if [ -f "$file" ]; then
        # 优先使用 sha256sum，如果不可用则降级到 md5sum
        if command -v sha256sum &>/dev/null; then
            sha256sum "$file" | awk '{print $1}'
        elif command -v md5sum &>/dev/null; then
            md5sum "$file" | awk '{print $1}'
        else
            error "无可用的哈希命令（sha256sum 或 md5sum）"
        fi
    else
        echo ""
    fi
}

# 更新脚本
update_script() {
    local script_name="$1"
    local source_path="$TEMP_DIR/$script_name"
    local target_path
    if [ "$script_name" = "repo.conf" ]; then
        target_path="$REPO_CONF"
    else
        target_path="$SCRIPT_DIR/$script_name"
    fi

    local source_hash=$(get_file_hash "$source_path")
    local target_hash=$(get_file_hash "$target_path")

    if [ "$source_hash" != "$target_hash" ]; then
        hint "检测到 $script_name 有更新，正在替换..."
        log "$script_name 有更新 (old=$target_hash new=$source_hash)"
        mkdir -p "$(dirname "$target_path")"
        local tmp_target
        tmp_target="${target_path}.tmp.$$"
        cp "$source_path" "$tmp_target"
        case "$script_name" in
            *.sh) chmod +x "$tmp_target" ;;
        esac
        mv "$tmp_target" "$target_path"
        info "$script_name 已更新"
        return 0
    else
        hint "$script_name 无更新"
        return 1
    fi
}

# --- 主逻辑 ---
main() {
    log "========== Script update start =========="
    info "============== 开始更新脚本 =============="
    log "========== 脚本更新开始 (repo=$SOURCE_REPOSITORY branch=$SOURCE_BRANCH) =========="

    init_temp_dir
    trap cleanup_temp_dir EXIT

    local updated=0

    # 下载脚本
    # 注意：repo.conf 不再自动更新——它包含 fork 用户需要定制的仓库源
    # (KOMARI_PROJECT_OWNER / KOMARI_PROJECT_NAME / KOMARI_SOURCE_REPOSITORY)，
    # 自动覆盖会把用户改好的 owner 还原成上游默认值，导致脚本自动更新源错乱。
    # repo.conf 由安装时写入，之后由用户自行管理。
    download_script "backup.sh"
    download_script "restore.sh"
    download_script "renew.sh"
    download_script "sub_link.sh"

    # 更新脚本
    if update_script "backup.sh"; then
        ((updated++))
    fi

    if update_script "restore.sh"; then
        ((updated++))
    fi

    if update_script "renew.sh"; then
        ((updated++))
    fi

    if update_script "sub_link.sh"; then
        ((updated++))
    fi

    if [ $updated -gt 0 ]; then
        info "已更新 $updated 个脚本"
        log "Updated $updated scripts"
        log "更新完成: $updated 个脚本已更新。"
    else
        info "所有脚本都是最新的"
        log "All scripts up to date"
        log "所有脚本已是最新。"
    fi

    log "========== 脚本更新结束 =========="
    log "========== Script update end =========="
    info "============== 脚本更新完毕 =============="
}

main
