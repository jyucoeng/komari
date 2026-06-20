#!/usr/bin/env bash

# 定义颜色输出函数
error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; }
info() { echo -e "\033[32m\033[01m$*\033[0m"; }
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }

# 定义文件路径
CRON_ENV_FILE="/app/cron_env.sh"
CRONTAB_DIR="/etc/crontabs"
CRONTAB_FILE="$CRONTAB_DIR/root"
BACKUP_SCRIPT="/app/komari_bak.sh"
RESTORE_SCRIPT="/app/restore.sh"
RENEW_SCRIPT="/app/renew.sh"
SUB_LINK_SCRIPT="/app/sub_link.sh"
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
BACKUP_DAYS=${BACKUP_DAYS:-"10"}
if ! echo "$BACKUP_DAYS" | grep -Eq '^[1-9][0-9]*$'; then
    error "错误：BACKUP_DAYS 必须是大于等于 1 的整数"
fi

# 配置 Caddy 端口
CADDY_PROXY_PORT=${CADDY_PROXY_PORT:-'8001'}

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
echo "export UUID=\"$UUID\"" >> "$CRON_ENV_FILE"
echo "export ARGO_DOMAIN=\"$ARGO_DOMAIN\"" >> "$CRON_ENV_FILE"
echo "export CF_IP=\"$CF_IP\"" >> "$CRON_ENV_FILE"
echo "export SUB_NAME=\"$SUB_NAME\"" >> "$CRON_ENV_FILE"
echo "export CADDY_PROXY_PORT=\"$CADDY_PROXY_PORT\"" >> "$CRON_ENV_FILE"
chmod 600 "$CRON_ENV_FILE"

mkdir -p "$CRONTAB_DIR"
# 根据 BACKUP_TIME 环境变量配置备份任务（UTC 时间）
: > "$CRONTAB_FILE"
if [ "$BACKUP_ENABLED" = "1" ]; then
    echo "$BACKUP_TIME . $CRON_ENV_FILE && $BACKUP_SCRIPT bak" >> "$CRONTAB_FILE"
    # 添加自动还原任务（每分钟检测一次）
    echo "* * * * * . $CRON_ENV_FILE && $RESTORE_SCRIPT a" >> "$CRONTAB_FILE"
fi

# 添加脚本更新任务（如果未禁用自动更新，则每天 03:30 UTC 执行）
# 默认自动更新，用户可通过设置 NO_AUTO_RENEW=1 禁用
if [ -z "$NO_AUTO_RENEW" ]; then
    echo "30 3 * * * . $CRON_ENV_FILE && $RENEW_SCRIPT" >> "$CRONTAB_FILE"
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
# 避免 Komari 内置 cloudflared 管理器启动第二份隧道
rm -f /usr/local/bin/cloudflared /usr/bin/cloudflared

# 生成 Caddyfile（如果不存在则创建，否则使用现有配置）
if [ ! -f "$CADDYFILE" ]; then
    hint "生成新的 Caddyfile 配置..."
    cat > "$CADDYFILE" << 'EOF'
:CADDY_PROXY_PORT_PLACEHOLDER {
EOF

# 如果设置了 UUID，配置节点订阅反代
if [ -n "$UUID" ]; then
    cat >> "$CADDYFILE" << 'EOF'
    # 订阅链接访问 (UUID 路径)
    handle /UUID_PLACEHOLDER {
        rewrite * /list.log
        file_server {
            root /tmp
        }
    }

EOF
    hint "检测到 UUID，配置订阅链接..."
    # 导出环境变量供 sub_link.sh 使用
    export UUID CADDY_PROXY_PORT ARGO_DOMAIN CF_IP SUB_NAME
    info "正在生成 VLESS 和 VMESS 订阅链接..."
    bash "$SUB_LINK_SCRIPT" || error "订阅链接生成失败，请检查 UUID、ARGO_DOMAIN 或 CF_IP 配置"
fi

# 添加默认反代到 Komari 面板
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

info "Caddyfile 已生成，准备启动 Caddy..."

else
    hint "Caddyfile 已存在，使用现有配置"
fi

# 赋执行权给所有脚本和应用
chmod +x $BACKUP_SCRIPT $SUB_LINK_SCRIPT $RESTORE_SCRIPT $RENEW_SCRIPT

if [ "$BACKUP_ENABLED" = "1" ]; then
    hint "启动前检查远程备份..."
    if . "$CRON_ENV_FILE" && KOMARI_RESTORE_SKIP_RESTART=1 "$RESTORE_SCRIPT" a; then
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
command=/bin/sh -c 'unset KOMARI_CLOUDFLARED_TOKEN KOMARI_CLOUDFLARED_BIN GH_PAT; exec /app/komari server -l 0.0.0.0:25774'
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

EOF

# 替换占位符
sed -i "s|CADDYFILE_PLACEHOLDER|$CADDYFILE|g" "$SUPERVISOR_CONF"
sed -i "s|CLOUDFLARED_CMD_PLACEHOLDER|$CLOUDFLARED_CMD|g" "$SUPERVISOR_CONF"

fi

# 启动 supervisor 进程守护
info "正在启动 Supervisor 进程管理器..."
exec supervisord -c "$SUPERVISOR_CONF"
