#!/usr/bin/env bash

# 定义颜色输出函数
error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; }
info() { echo -e "\033[32m\033[01m$*\033[0m"; }
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }

# 定义文件路径
CRON_ENV_FILE="/app/cron_env.sh"
CRONTAB_FILE="/etc/crontabs/root"
BACKUP_SCRIPT="/app/komari_bak.sh"
RESTORE_SCRIPT="/app/restore.sh"
RENEW_SCRIPT="/app/renew.sh"
SUB_LINK_SCRIPT="/app/sub_link.sh"
CLOUDFLARED_BIN="/app/bin/cloudflared"
CADDYFILE="/app/Caddyfile"
SUPERVISOR_CONF="/etc/supervisor/conf.d/damon.conf"
WORK_DIR="/app"

# 首次运行时执行以下流程，再次运行时存在 damon.conf 文件，直接到最后一步
if [ ! -s "$SUPERVISOR_CONF" ]; then

# 设置时区（支持通过环境变量自定义，默认 UTC）
TZ="${TZ:-UTC}"
export TZ

# 设置 DNS（支持通过环境变量自定义）
DNS_SERVERS="${DNS_SERVERS:-127.0.0.11 8.8.4.4 223.5.5.5 2001:4860:4860::8844 2400:3200::1}"
{
    echo "# DNS 配置"
    for dns in $DNS_SERVERS; do
        echo "nameserver $dns"
    done
} > /etc/resolv.conf

# 检查必需的环境变量
if [ -z "$ARGO_DOMAIN" ] || [ -z "$KOMARI_CLOUDFLARED_TOKEN" ]; then
    error "错误：ARGO_DOMAIN 和 KOMARI_CLOUDFLARED_TOKEN 是必需的"
fi

# 设置备份相关的环境变量默认值（使用 UTC 时间）
BACKUP_TIME=${BACKUP_TIME:-"0 20 * * *"}
BACKUP_DAYS=${BACKUP_DAYS:-"10"}

# 配置 Caddy 端口
CADDY_PROXY_PORT=${CADDY_PROXY_PORT:-'8001'}

# Caddy 版本配置
if [[ "$CADDY_VERSION" =~ [0-9]{1}\.[0-9]{1,2}\.[0-9]{1,2}$ ]]; then
    CADDY_LATEST=$(sed 's/[A-Za-z]//' <<< "$CADDY_VERSION")
else
    CADDY_LATEST=2.9.1
fi

echo "#!/usr/bin/env bash" > "$CRON_ENV_FILE"
echo "export GH_BACKUP_USER=\"$GH_BACKUP_USER\"" >> "$CRON_ENV_FILE"
echo "export GH_REPO=\"$GH_REPO\"" >> "$CRON_ENV_FILE"
echo "export GH_PAT=\"$GH_PAT\"" >> "$CRON_ENV_FILE"
echo "export GH_EMAIL=\"$GH_EMAIL\"" >> "$CRON_ENV_FILE"
echo "export BACKUP_DAYS=\"$BACKUP_DAYS\"" >> "$CRON_ENV_FILE"
chmod +x "$CRON_ENV_FILE"

# 根据 BACKUP_TIME 环境变量配置备份任务（UTC 时间）
echo "$BACKUP_TIME . $CRON_ENV_FILE && $BACKUP_SCRIPT bak" > "$CRONTAB_FILE"

# 添加自动还原任务（每分钟检测一次）
echo "* * * * * . $CRON_ENV_FILE && $RESTORE_SCRIPT a" >> "$CRONTAB_FILE"

# 添加脚本更新任务（如果未禁用自动更新，则每天 03:30 UTC 执行）
# 默认自动更新，用户可通过设置 NO_AUTO_RENEW=1 禁用
if [ -z "$NO_AUTO_RENEW" ]; then
    echo "30 3 * * * . $CRON_ENV_FILE && $RENEW_SCRIPT" >> "$CRONTAB_FILE"
fi

# 处理 KOMARI_CLOUDFLARED_TOKEN 格式（JSON 或 Token）
if [[ "$KOMARI_CLOUDFLARED_TOKEN" =~ TunnelSecret ]]; then
    # JSON 格式处理
    KOMARI_CLOUDFLARED_TOKEN_PROCESSED="$KOMARI_CLOUDFLARED_TOKEN"
    
    echo "$KOMARI_CLOUDFLARED_TOKEN_PROCESSED" > $WORK_DIR/argo.json
    
    # 从 JSON 中提取 Tunnel ID（第 12 个双引号之间的内容）
    TUNNEL_ID=$(cut -d '"' -f12 <<< "$KOMARI_CLOUDFLARED_TOKEN_PROCESSED")
    
    # 生成 argo.yml 配置文件
    cat > $WORK_DIR/argo.yml << 'ARGO_EOF'
tunnel: TUNNEL_ID_PLACEHOLDER
credentials-file: /app/argo.json
protocol: http2

ingress:
  - hostname: ARGO_DOMAIN_PLACEHOLDER
    service: http://localhost:CADDY_PROXY_PORT_PLACEHOLDER
  - service: http_status:404
ARGO_EOF
    
    # 替换占位符
    sed -i "s|TUNNEL_ID_PLACEHOLDER|$TUNNEL_ID|g" $WORK_DIR/argo.yml
    sed -i "s|ARGO_DOMAIN_PLACEHOLDER|$ARGO_DOMAIN|g" $WORK_DIR/argo.yml
    sed -i "s|CADDY_PROXY_PORT_PLACEHOLDER|$CADDY_PROXY_PORT|g" $WORK_DIR/argo.yml
    
    CLOUDFLARED_CMD="$CLOUDFLARED_BIN tunnel --edge-ip-version auto --config $WORK_DIR/argo.yml run"
    hint "Cloudflare 隧道配置完成（JSON 格式）"
    
elif [[ "$KOMARI_CLOUDFLARED_TOKEN" =~ ^ey[A-Z0-9a-z=]{120,250}$ ]]; then
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
info "正在下载 Caddy v$CADDY_LATEST..."
wget -q --show-progress https://github.com/caddyserver/caddy/releases/download/v${CADDY_LATEST}/caddy_${CADDY_LATEST}_linux_${ARCH}.tar.gz -O /tmp/caddy.tar.gz && \
tar xzf /tmp/caddy.tar.gz -C /usr/local/bin/ caddy && \
chmod +x /usr/local/bin/caddy && \
rm -f /tmp/caddy.tar.gz && \
info "Caddy v$CADDY_LATEST 安装完成" || error "Caddy 下载失败"

# 下载 Cloudflared 二进制文件
info "正在下载 Cloudflared..."
mkdir -p "$(dirname "$CLOUDFLARED_BIN")" && \
wget -q --show-progress https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH} -O "$CLOUDFLARED_BIN" && \
chmod +x "$CLOUDFLARED_BIN" && \
info "Cloudflared 安装完成" || error "Cloudflared 下载失败"
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
    export UUID CADDY_PROXY_PORT ARGO_DOMAIN
    info "正在生成 VLESS 和 VMESS 订阅链接..."
    bash "$SUB_LINK_SCRIPT"
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

# 生成 supervisor 配置文件
cat > "$SUPERVISOR_CONF" << 'EOF'
[supervisord]
nodaemon=true
logfile=/dev/null
pidfile=/run/supervisord.pid

[program:cron]
command=/usr/sbin/crond -f
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null

[program:komari]
command=/bin/sh -c 'unset KOMARI_CLOUDFLARED_TOKEN KOMARI_CLOUDFLARED_BIN; exec /app/komari server -l 0.0.0.0:25774'
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null

[program:caddy]
command=/usr/local/bin/caddy run --config CADDYFILE_PLACEHOLDER --watch
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null

[program:cloudflared]
command=CLOUDFLARED_CMD_PLACEHOLDER
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null

EOF

# 替换占位符
sed -i "s|CADDYFILE_PLACEHOLDER|$CADDYFILE|g" "$SUPERVISOR_CONF"
sed -i "s|CLOUDFLARED_CMD_PLACEHOLDER|$CLOUDFLARED_CMD|g" "$SUPERVISOR_CONF"

fi

# 启动 supervisor 进程守护
info "正在启动 Supervisor 进程管理器..."
supervisord -c /etc/supervisor/supervisord.conf
