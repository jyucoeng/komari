#!/usr/bin/env bash

# 定义颜色输出函数
error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; }
info() { echo -e "\033[32m\033[01m$*\033[0m"; }
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }

# 定义文件路径
CRON_ENV_FILE="/app/cron_env.sh"
CRONTAB_DIR="/etc/crontabs"
CRONTAB_FILE="$CRONTAB_DIR/root"
BACKUP_SCRIPT="/app/backup.sh"
RESTORE_SCRIPT="/app/restore.sh"
RENEW_SCRIPT="/app/renew.sh"
SUB_LINK_SCRIPT="/app/sub_link.sh"
REPO_CONF="/app/repo.conf"
XRAY_BIN="/app/bin/xray"
CLOUDFLARED_BIN="/app/bin/cloudflared"
CADDYFILE="/app/Caddyfile"
SUPERVISOR_CONF="/etc/supervisor.d/damon.conf"
WORK_DIR="/app"

# 首次运行时执行以下流程，再次运行时存在 damon.conf 文件，直接到最后一步
if [ ! -s "$SUPERVISOR_CONF" ]; then

require_env() {
    local name="$1"
    local value="${!name:-}"
    if [ -z "$value" ]; then
        error "错误：$name 是必需的"
    fi
}

reject_placeholder() {
    local name="$1"
    local value="${!name:-}"
    case "$value" in
        your_github_username|your_private_repo_name|your_github_personal_access_token|your_github_email@example.com|yourusername|yourpassword|your-argo-domain.com|eyJxxxxx)
            error "错误：$name 仍是示例占位值，请设置真实值"
            ;;
    esac
}

valid_backup_env() {
    [ -n "${GH_BACKUP_USER:-}" ] && [ -n "${GH_REPO:-}" ] && [ -n "${GH_PAT:-}" ] && [ -n "${GH_EMAIL:-}" ] &&
    [ "${GH_BACKUP_USER:-}" != "your_github_username" ] &&
    [ "${GH_REPO:-}" != "your_private_repo_name" ] &&
    [ "${GH_PAT:-}" != "your_github_personal_access_token" ] &&
    [ "${GH_EMAIL:-}" != "your_github_email@example.com" ]
}

valid_cron_expr() {
    local expr="$1" field_count
    [ -n "$expr" ] || return 1
    printf "%s" "$expr" | grep -q '[[:cntrl:]]' && return 1
    field_count=$(printf "%s\n" "$expr" | awk '{print NF; exit}')
    [ "$field_count" = "5" ]
}

shell_quote() {
    printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\''/g")"
}

append_cron_job() {
    local schedule="$1"
    shift
    printf '%s %s\n' "$schedule" "$*" >> "$CRONTAB_FILE"
}

truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

if [ -f "$REPO_CONF" ]; then
    . "$REPO_CONF"
fi

# 设置时区（支持通过环境变量自定义，默认 UTC）
TZ="${TZ:-UTC}"
export TZ

# 设置 DNS（支持通过环境变量自定义）
DNS_SERVERS="${DNS_SERVERS:-127.0.0.11 8.8.4.4 223.5.5.5 2001:4860:4860::8844 2400:3200::1}"
if [ "${KOMARI_SKIP_DNS_CONFIG:-}" != "1" ]; then
    if [ -w /etc/resolv.conf ]; then
        {
            echo "# DNS 配置"
            for dns in $DNS_SERVERS; do
                echo "nameserver $dns"
            done
        } > /etc/resolv.conf || hint "无法写入 /etc/resolv.conf，继续使用平台默认 DNS"
    else
        hint "/etc/resolv.conf 不可写，继续使用平台默认 DNS"
    fi
fi

# 检查必需的环境变量
for required_var in ADMIN_USERNAME ADMIN_PASSWORD ARGO_DOMAIN KOMARI_CLOUDFLARED_TOKEN; do
    require_env "$required_var"
    reject_placeholder "$required_var"
done

BACKUP_ENABLED=0
if valid_backup_env; then
    BACKUP_ENABLED=1
else
    hint "GitHub 备份变量未完整配置，自动备份和自动还原将不会启用。"
fi

# 设置备份相关的环境变量默认值（使用 UTC 时间）
BACKUP_TIME=${BACKUP_TIME:-"0 20 * * *"}
if ! valid_cron_expr "$BACKUP_TIME"; then
    error "错误：BACKUP_TIME 必须是 5 段 cron 表达式，例如 '0 */1 * * *'"
fi
BACKUP_DAYS=${BACKUP_DAYS:-"10"}
if ! echo "$BACKUP_DAYS" | grep -Eq '^[1-9][0-9]*$'; then
    error "错误：BACKUP_DAYS 必须是大于等于 1 的整数"
fi

# 配置 Caddy 端口
CADDY_PROXY_PORT=${CADDY_PROXY_PORT:-'8001'}
XRAY_VLESS_PORT=${XRAY_VLESS_PORT:-'8002'}
XRAY_VMESS_PORT=${XRAY_VMESS_PORT:-'8003'}
KOMARI_LISTEN_ADDR=${KOMARI_LISTEN_ADDR:-'0.0.0.0:25774'}
KOMARI_DISABLE_WEB_SSH=${KOMARI_DISABLE_WEB_SSH:-${DISABLE_WEB_SSH:-1}}
KOMARI_DISABLE_REMOTE=${KOMARI_DISABLE_REMOTE:-${DISABLE_REMOTE:-1}}

# Caddy 版本配置
if [[ "$CADDY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    CADDY_LATEST="$CADDY_VERSION"
else
    CADDY_LATEST=2.9.1
fi

echo "#!/usr/bin/env bash" > "$CRON_ENV_FILE"
echo "export GH_BACKUP_USER=\"$GH_BACKUP_USER\"" >> "$CRON_ENV_FILE"
echo "export GH_REPO=\"$GH_REPO\"" >> "$CRON_ENV_FILE"
echo "export GH_BACKUP_BRANCH=\"$GH_BACKUP_BRANCH\"" >> "$CRON_ENV_FILE"
echo "export GH_PAT=\"$GH_PAT\"" >> "$CRON_ENV_FILE"
echo "export GH_EMAIL=\"$GH_EMAIL\"" >> "$CRON_ENV_FILE"
echo "export BACKUP_DAYS=\"$BACKUP_DAYS\"" >> "$CRON_ENV_FILE"
echo "export KOMARI_LOCK_TIMEOUT_SECONDS=\"$KOMARI_LOCK_TIMEOUT_SECONDS\"" >> "$CRON_ENV_FILE"
echo "export TZ=\"$TZ\"" >> "$CRON_ENV_FILE"
echo "export KOMARI_SOURCE_REPOSITORY=\"$KOMARI_SOURCE_REPOSITORY\"" >> "$CRON_ENV_FILE"
echo "export KOMARI_SOURCE_BRANCH=\"$KOMARI_SOURCE_BRANCH\"" >> "$CRON_ENV_FILE"
echo "export KOMARI_PROJECT_OWNER=\"$KOMARI_PROJECT_OWNER\"" >> "$CRON_ENV_FILE"
echo "export KOMARI_PROJECT_NAME=\"$KOMARI_PROJECT_NAME\"" >> "$CRON_ENV_FILE"
echo "export UUID=\"$UUID\"" >> "$CRON_ENV_FILE"
echo "export ARGO_DOMAIN=\"$ARGO_DOMAIN\"" >> "$CRON_ENV_FILE"
echo "export CF_IP=\"$CF_IP\"" >> "$CRON_ENV_FILE"
echo "export SUB_NAME=\"$SUB_NAME\"" >> "$CRON_ENV_FILE"
echo "export CADDY_PROXY_PORT=\"$CADDY_PROXY_PORT\"" >> "$CRON_ENV_FILE"
echo "export XRAY_VLESS_PORT=\"$XRAY_VLESS_PORT\"" >> "$CRON_ENV_FILE"
echo "export XRAY_VMESS_PORT=\"$XRAY_VMESS_PORT\"" >> "$CRON_ENV_FILE"
chmod 600 "$CRON_ENV_FILE"

mkdir -p "$CRONTAB_DIR"
# 根据 BACKUP_TIME 环境变量配置备份任务（UTC 时间）
: > "$CRONTAB_FILE"
if [ "$BACKUP_ENABLED" = "1" ]; then
    append_cron_job "$BACKUP_TIME" ". $(shell_quote "$CRON_ENV_FILE") && bash $(shell_quote "$BACKUP_SCRIPT") >> /tmp/backup.log 2>&1"
    # 添加自动还原任务（每分钟检测一次）
    append_cron_job "* * * * *" ". $(shell_quote "$CRON_ENV_FILE") && bash $(shell_quote "$RESTORE_SCRIPT") a >> /tmp/restore-cron.log 2>&1"
fi

# 添加脚本更新任务（如果未禁用自动更新，则每天 03:30 UTC 执行）
# 默认自动更新，用户可通过设置 NO_AUTO_RENEW=1 禁用
if [ -z "$NO_AUTO_RENEW" ]; then
    append_cron_job "30 3 * * *" ". $(shell_quote "$CRON_ENV_FILE") && bash $(shell_quote "$RENEW_SCRIPT") >> /tmp/renew.log 2>&1"
fi

# 处理 KOMARI_CLOUDFLARED_TOKEN 格式（JSON 或 Token）
if [[ "$KOMARI_CLOUDFLARED_TOKEN" =~ TunnelSecret ]]; then
    # JSON 格式处理
    KOMARI_CLOUDFLARED_TOKEN_PROCESSED="$KOMARI_CLOUDFLARED_TOKEN"
    
    echo "$KOMARI_CLOUDFLARED_TOKEN_PROCESSED" > "$WORK_DIR/argo.json"
    chmod 600 "$WORK_DIR/argo.json"

    # 从 JSON 凭据中提取 Tunnel ID
    TUNNEL_ID=$(jq -r '.TunnelID // .TunnelId // .tunnel_id // empty' "$WORK_DIR/argo.json" 2>/dev/null)
    if [ -z "$TUNNEL_ID" ]; then
        error "错误：无法从 KOMARI_CLOUDFLARED_TOKEN JSON 中提取 Tunnel ID"
    fi
    
    # 生成 argo.yml 配置文件
    cat > "$WORK_DIR/argo.yml" << 'ARGO_EOF'
tunnel: TUNNEL_ID_PLACEHOLDER
credentials-file: /app/argo.json
protocol: http2

ingress:
  - hostname: ARGO_DOMAIN_PLACEHOLDER
    service: http://localhost:CADDY_PROXY_PORT_PLACEHOLDER
  - service: http_status:404
ARGO_EOF
    
    # 替换占位符
    sed -i "s|TUNNEL_ID_PLACEHOLDER|$TUNNEL_ID|g" "$WORK_DIR/argo.yml"
    sed -i "s|ARGO_DOMAIN_PLACEHOLDER|$ARGO_DOMAIN|g" "$WORK_DIR/argo.yml"
    sed -i "s|CADDY_PROXY_PORT_PLACEHOLDER|$CADDY_PROXY_PORT|g" "$WORK_DIR/argo.yml"
    
    CLOUDFLARED_CMD="$CLOUDFLARED_BIN tunnel --edge-ip-version auto --config $WORK_DIR/argo.yml run"
    hint "Cloudflare 隧道配置完成（JSON 格式）"
    
elif [[ "$KOMARI_CLOUDFLARED_TOKEN" =~ ^ey[A-Za-z0-9_-]{80,}=*$ ]]; then
    # Token 格式处理
    CLOUDFLARED_CMD="$CLOUDFLARED_BIN tunnel --edge-ip-version auto --protocol http2 run --token ${KOMARI_CLOUDFLARED_TOKEN}"
    hint "Cloudflare 隧道配置完成（Token 格式）"
    
else
    error "错误：KOMARI_CLOUDFLARED_TOKEN 格式不正确（应为 JSON 或 Token）"
fi

# 检测系统架构
case "$(uname -m)" in
    aarch64|arm64)
        ARCH=arm64
        ;;
    x86_64|amd64)
        ARCH=amd64
        ;;
    armv7*)
        ARCH=arm
        ;;
    *)
        error "不支持的系统架构"
        ;;
esac

# 下载 Caddy 二进制文件
if ! command -v caddy >/dev/null 2>&1 || ! caddy version 2>/dev/null | grep -q "v$CADDY_LATEST"; then
    info "正在下载 Caddy v$CADDY_LATEST..."
    wget -q --show-progress https://github.com/caddyserver/caddy/releases/download/v${CADDY_LATEST}/caddy_${CADDY_LATEST}_linux_${ARCH}.tar.gz -O /tmp/caddy.tar.gz && \
    tar xzf /tmp/caddy.tar.gz -C /usr/local/bin/ caddy && \
    chmod +x /usr/local/bin/caddy && \
    rm -f /tmp/caddy.tar.gz && \
    info "Caddy v$CADDY_LATEST 安装完成" || error "Caddy 下载失败"
else
    info "Caddy v$CADDY_LATEST 已安装，跳过下载"
fi

# 下载 Cloudflared 二进制文件
if [ ! -x "$CLOUDFLARED_BIN" ]; then
    info "正在下载 Cloudflared..."
    mkdir -p "$(dirname "$CLOUDFLARED_BIN")" && \
    wget -q --show-progress https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH} -O "$CLOUDFLARED_BIN" && \
    chmod +x "$CLOUDFLARED_BIN" && \
    info "Cloudflared 安装完成" || error "Cloudflared 下载失败"
else
    info "Cloudflared 已安装，跳过下载"
fi

if [ -n "${UUID:-}" ] && [ "$UUID" != "0" ]; then
    if [ ! -x "$XRAY_BIN" ]; then
        info "正在下载 Xray 订阅后端..."
        mkdir -p "$(dirname "$XRAY_BIN")"
        case "$ARCH" in
            amd64) XRAY_ASSET="Xray-linux-64.zip" ;;
            arm64) XRAY_ASSET="Xray-linux-arm64-v8a.zip" ;;
            arm) XRAY_ASSET="Xray-linux-arm32-v7a.zip" ;;
            *) error "不支持的 Xray 架构: $ARCH" ;;
        esac
        wget -q --show-progress "https://github.com/XTLS/Xray-core/releases/latest/download/$XRAY_ASSET" -O /tmp/xray.zip && \
        unzip -qo /tmp/xray.zip xray -d "$(dirname "$XRAY_BIN")" && \
        chmod +x "$XRAY_BIN" && \
        rm -f /tmp/xray.zip && \
        info "Xray 订阅后端安装完成" || error "Xray 下载失败"
    else
        info "Xray 订阅后端已安装，跳过下载"
    fi
fi
# 避免 Komari 内置 cloudflared 管理器启动第二份隧道
rm -f /usr/local/bin/cloudflared /usr/bin/cloudflared

# 生成 Caddyfile（如果不存在则创建，否则使用现有配置）
if [ ! -f "$CADDYFILE" ]; then
    hint "生成新的 Caddyfile 配置..."
    cat > "$CADDYFILE" << 'EOF'
:CADDY_PROXY_PORT_PLACEHOLDER {
EOF

# 如果设置了 UUID，配置节点订阅反代
if [ -n "$UUID" ] && [ "$UUID" != "0" ]; then
    cat > "$WORK_DIR/xray.json" << XRAY_EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": $XRAY_VLESS_PORT,
      "protocol": "vless",
      "settings": { "clients": [{ "id": "$UUID" }], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vls" } }
    },
    {
      "listen": "127.0.0.1",
      "port": $XRAY_VMESS_PORT,
      "protocol": "vmess",
      "settings": { "clients": [{ "id": "$UUID", "alterId": 0 }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vms" } }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
XRAY_EOF

    cat >> "$CADDYFILE" << 'EOF'
    # 订阅链接访问 (UUID 路径)
    handle /UUID_PLACEHOLDER {
        rewrite * /list.log
        file_server {
            root /tmp
        }
    }

    reverse_proxy /vls* 127.0.0.1:XRAY_VLESS_PORT_PLACEHOLDER
    reverse_proxy /vms* 127.0.0.1:XRAY_VMESS_PORT_PLACEHOLDER

EOF
    hint "检测到 UUID，配置订阅链接..."
    # 导出环境变量供 sub_link.sh 使用
    export UUID CADDY_PROXY_PORT ARGO_DOMAIN CF_IP SUB_NAME
    info "正在生成 VLESS 和 VMESS 订阅链接..."
    bash "$SUB_LINK_SCRIPT" || error "订阅链接生成失败，请检查 UUID、ARGO_DOMAIN 或 CF_IP 配置"
fi

# 添加默认反代到 Komari 面板
if truthy "$KOMARI_DISABLE_WEB_SSH" || truthy "$KOMARI_DISABLE_REMOTE"; then
    cat >> "$CADDYFILE" << 'EOF'
    @blockedRemote path_regexp blockedRemote ^/(api/clients/terminal|api/admin/client/[^/]+/terminal|api/admin/task/exec|terminal)(/.*)?$
    respond @blockedRemote 403

EOF
fi

cat >> "$CADDYFILE" << 'EOF'
    # 反代到 Komari 面板（默认路由）
    handle {
        reverse_proxy localhost:25774
    }
}
EOF

# 替换占位符
sed -i "s|CADDY_PROXY_PORT_PLACEHOLDER|$CADDY_PROXY_PORT|g" "$CADDYFILE"
sed -i "s|UUID_PLACEHOLDER|$UUID|g" "$CADDYFILE"
sed -i "s|XRAY_VLESS_PORT_PLACEHOLDER|$XRAY_VLESS_PORT|g" "$CADDYFILE"
sed -i "s|XRAY_VMESS_PORT_PLACEHOLDER|$XRAY_VMESS_PORT|g" "$CADDYFILE"

info "Caddyfile 已生成，准备启动 Caddy..."

else
    hint "Caddyfile 已存在，使用现有配置"
fi

# 赋执行权给所有脚本和应用
chmod +x "$BACKUP_SCRIPT" "$SUB_LINK_SCRIPT" "$RESTORE_SCRIPT" "$RENEW_SCRIPT"

if [ "$BACKUP_ENABLED" = "1" ]; then
    hint "启动前检查远程备份..."
    if . "$CRON_ENV_FILE" && KOMARI_RESTORE_SKIP_RESTART=1 bash "$RESTORE_SCRIPT" a; then
        info "启动前备份检查完成"
    else
        hint "启动前自动还原未完成，容器会继续启动，定时任务稍后重试。"
    fi
fi

# 生成 supervisor 配置文件
mkdir -p "$(dirname "$SUPERVISOR_CONF")" /run
cat > "$SUPERVISOR_CONF" << 'EOF'
[supervisord]
nodaemon=true
logfile=/dev/null
pidfile=/run/supervisord.pid

[unix_http_server]
file=/run/supervisor.sock
chmod=0700

[supervisorctl]
serverurl=unix:///run/supervisor.sock

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[program:cron]
command=/bin/busybox crond -f -c /etc/crontabs
autostart=true
autorestart=true
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0

[program:komari]
command=/bin/sh -c 'unset KOMARI_CLOUDFLARED_TOKEN KOMARI_CLOUDFLARED_BIN GH_PAT; exec /usr/local/bin/komari-start'
autostart=true
autorestart=true
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0

[program:caddy]
command=/usr/local/bin/caddy run --config CADDYFILE_PLACEHOLDER --watch
autostart=true
autorestart=true
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0

[program:cloudflared]
command=CLOUDFLARED_CMD_PLACEHOLDER
autostart=true
autorestart=true
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0

[program:xray]
command=/bin/sh -c '[ -s /app/xray.json ] && exec /app/bin/xray run -config /app/xray.json || sleep infinity'
autostart=XRAY_AUTOSTART_PLACEHOLDER
autorestart=true
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0

EOF

# 替换占位符
cat > /usr/local/bin/komari-start << KOMARI_START_EOF
#!/usr/bin/env sh
set -eu
if [ -x /usr/local/bin/komari-disable-remote ]; then
    /usr/local/bin/komari-disable-remote || true
fi
args="server -l ${KOMARI_LISTEN_ADDR}"
if [ "${KOMARI_DISABLE_WEB_SSH}" = "1" ] || [ "${KOMARI_DISABLE_WEB_SSH}" = "true" ]; then
    if /app/komari server --help 2>&1 | grep -q -- '--disable-web-ssh'; then
        args="\$args --disable-web-ssh"
    fi
fi
exec /app/komari \$args
KOMARI_START_EOF
chmod +x /usr/local/bin/komari-start

if truthy "$KOMARI_DISABLE_WEB_SSH" || truthy "$KOMARI_DISABLE_REMOTE"; then
    cat > /usr/local/bin/komari-disable-remote << 'DISABLE_REMOTE_EOF'
#!/usr/bin/env sh
db="${KOMARI_DB_FILE:-/app/data/komari.db}"
[ -f "$db" ] || exit 0
command -v sqlite3 >/dev/null 2>&1 || exit 0
sqlite3 "$db" "INSERT INTO configs(key, value) VALUES ('terminal_enabled','false'),('web_ssh_enabled','false'),('remote_terminal_enabled','false'),('remote_execute_enabled','false'),('remote_command_enabled','false'),('command_execute_enabled','false'),('disable_web_ssh','true'),('disable_remote','true'),('disable_command_execute','true'),('disable_terminal','true') ON CONFLICT(key) DO UPDATE SET value=excluded.value;" >/dev/null 2>&1 || true
sqlite3 "$db" "UPDATE configs SET terminal_enabled=0, web_ssh_enabled=0, remote_terminal_enabled=0, remote_execute_enabled=0, remote_command_enabled=0, command_execute_enabled=0 WHERE id IS NOT NULL;" >/dev/null 2>&1 || true
DISABLE_REMOTE_EOF
    chmod +x /usr/local/bin/komari-disable-remote
fi

sed -i "s|CADDYFILE_PLACEHOLDER|$CADDYFILE|g" "$SUPERVISOR_CONF"
sed -i "s|CLOUDFLARED_CMD_PLACEHOLDER|$CLOUDFLARED_CMD|g" "$SUPERVISOR_CONF"
if [ -n "${UUID:-}" ] && [ "$UUID" != "0" ]; then
    sed -i "s|XRAY_AUTOSTART_PLACEHOLDER|true|g" "$SUPERVISOR_CONF"
else
    sed -i "s|XRAY_AUTOSTART_PLACEHOLDER|false|g" "$SUPERVISOR_CONF"
fi

fi

# 启动 supervisor 进程守护
info "正在启动 Supervisor 进程管理器..."
exec supervisord -c "$SUPERVISOR_CONF"
