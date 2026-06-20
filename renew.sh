#!/usr/bin/env bash

#===============================================================
#        Komari Dashboard Auto-Renew Scripts
#
# 此脚本用于自动更新 komari_bak.sh、restore.sh 和 sub_link.sh
# ---------------------------------------------------------------
# 功能:
#   - 每天定时从 GitHub 获取最新的备份、还原和订阅脚本
#   - 比对哈希值，如果有变化则自动替换
#   - 无需重新构建镜像即可获得最新的脚本
#===============================================================

#---------------------------------------------------------------
# 配置
#---------------------------------------------------------------
WORK_DIR="${WORK_DIR:-/app}"
TEMP_DIR="/tmp/renew_scripts"
SOURCE_REPOSITORY="${KOMARI_SOURCE_REPOSITORY:-hynize/komari}"
SOURCE_BRANCH="${KOMARI_SOURCE_BRANCH:-main}"

#---------------------------------------------------------------
# 脚本核心逻辑
#---------------------------------------------------------------

# 颜色定义
info() { echo -e "\033[32m\033[01m$*\033[0m"; }     # 绿色
error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; } # 红色
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
download_script() {
    local script_name="$1"
    local output_path="$TEMP_DIR/$script_name"
    local url="https://raw.githubusercontent.com/$SOURCE_REPOSITORY/$SOURCE_BRANCH/$script_name"

    hint "正在下载 $script_name..."

    if ! wget -q -O "$output_path" "$url" 2>/dev/null; then
        error "下载 $script_name 失败"
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
    local target_path="$WORK_DIR/$script_name"

    local source_hash=$(get_file_hash "$source_path")
    local target_hash=$(get_file_hash "$target_path")

    if [ "$source_hash" != "$target_hash" ]; then
        hint "检测到 $script_name 有更新，正在替换..."
        cp "$source_path" "$target_path"
        chmod +x "$target_path"
        info "$script_name 已更新"
        return 0
    else
        hint "$script_name 无更新"
        return 1
    fi
}

# --- 主逻辑 ---
main() {
    info "============== 开始更新备份、还原和订阅脚本 =============="

    init_temp_dir
    trap cleanup_temp_dir EXIT

    local updated=0

    # 下载脚本
    download_script "komari_bak.sh"
    download_script "restore.sh"
    download_script "sub_link.sh"

    # 更新脚本
    if update_script "komari_bak.sh"; then
        ((updated++))
    fi

    if update_script "restore.sh"; then
        ((updated++))
    fi

    if update_script "sub_link.sh"; then
        ((updated++))
    fi

    if [ $updated -gt 0 ]; then
        info "已更新 $updated 个脚本"
    else
        info "所有脚本都是最新的"
    fi

    info "============== 脚本更新完毕 =============="
}

main
