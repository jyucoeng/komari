#!/usr/bin/env bash
set -o pipefail
RED='\033[31m\033[01m'; GREEN='\033[32m\033[01m'; YELLOW='\033[33m\033[01m'; NC='\033[0m'
info()  { echo -e "${GREEN}$*${NC}"; }
error() { echo -e "${RED}$*${NC}" >&2; exit 1; }
hint()  { echo -e "${YELLOW}$*${NC}"; }

KOMARI_HOME="${KOMARI_HOME:-/opt/komari}"
KOMARI_BIN_DIR="$KOMARI_HOME/bin"
KOMARI_DATA_DIR="$KOMARI_HOME/data"
KOMARI_LOG_DIR="$KOMARI_HOME/logs"
KOMARI_SCRIPT_DIR="$KOMARI_HOME/scripts"
KOMARI_CONF_DIR="$KOMARI_HOME/conf"
KOMARI_SERVICE_USER="komari"
SCRIPT_BASE_URL="https://raw.githubusercontent.com/jyucoeng/komari/main"

[ "$(id -u)" -ne 0 ] && error "Please run as root."

detect_installed() {
    local found=0
    [ -d "$KOMARI_HOME" ] && { hint "Found dir: $KOMARI_HOME"; found=1; }
    systemctl is-active --quiet komari 2>/dev/null && { hint "Found service: komari.service (active)"; found=1; }
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'komari' && { hint "Found Docker container: komari"; found=1; }
    [ "$found" -eq 1 ] && return 0 || return 1
}

do_uninstall() {
    echo ""
    hint "This will uninstall komari. This cannot be undone!"
    printf "Type YES to confirm: "
    read -r confirm
    [ "$confirm" != "YES" ] && { info "Cancelled."; exit 0; }
    info "=== Uninstalling komari ==="
    for svc in komari caddy cloudflared xray; do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}.service"
    done
    systemctl daemon-reload 2>/dev/null || true
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'komari'; then
        docker stop komari 2>/dev/null || true
        docker rm komari 2>/dev/null || true
    fi
    if id "$KOMARI_SERVICE_USER" >/dev/null 2>&1; then
        crontab -u "$KOMARI_SERVICE_USER" -r 2>/dev/null || true
    fi
    rm -rf "$KOMARI_HOME"
    rm -f /usr/local/bin/komari-cli
    userdel "$KOMARI_SERVICE_USER" 2>/dev/null || true
    info "komari has been uninstalled."
    exit 0
}

do_docker_install() {
    info "=== Docker Installation ==="
    if ! command -v docker >/dev/null 2>&1; then
        hint "Docker not found. Installing Docker..."
        curl -fsSL https://get.docker.com | sh || error "Docker installation failed."
    fi
    mkdir -p "$KOMARI_HOME"/{data,logs}
    mkdir -p "$KOMARI_CONF_DIR"
    cd "$KOMARI_HOME" || error "Cannot enter $KOMARI_HOME"
    for f in docker-compose.yml .env.example; do
        curl -fsSL "${SCRIPT_BASE_URL}/${f}" -o "${KOMARI_CONF_DIR}/${f}" 2>/dev/null || true
    done
    if [ ! -f "$KOMARI_CONF_DIR/.env" ]; then
        cp "$KOMARI_CONF_DIR/.env.example" "$KOMARI_CONF_DIR/.env" 2>/dev/null || true
        hint "Edit $KOMARI_CONF_DIR/.env then run:"
        echo "  cd $KOMARI_HOME && docker compose up -d"
    else
        info "Config already exists."
    fi
    info "Docker installation done."
    exit 0
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/alpine-release ]; then
        echo "alpine"
    else
        echo "unknown"
    fi
}

install_deps() {
    local os="$1"
    info "Installing dependencies..."
    case "$os" in
        ubuntu|debian)
            apt-get update -qq
            apt-get install -y -qq curl wget git sqlite3 jq tar unzip xz-utils cron
            ;;
        centos|rhel|fedora|rocky|almalinux)
            yum install -y -q curl wget git sqlite jq tar unzip xz cronie 2>/dev/null || \
                dnf install -y -q curl wget git sqlite jq tar unzip xz cronie
            ;;
        alpine)
            apk add --no-cache curl wget git sqlite jq tar unzip xz dcron bash
            ;;
        *)
            hint "Unknown OS. Trying apk then apt..."
            if command -v apk >/dev/null 2>&1; then
                apk add --no-cache curl wget git sqlite jq tar unzip xz dcron bash
            elif command -v apt-get >/dev/null 2>&1; then
                apt-get update -qq && apt-get install -y -qq curl wget git sqlite3 jq tar unzip xz-utils cron
            else
                error "Cannot determine package manager. Install manually: curl wget git sqlite jq tar unzip"
            fi
            ;;
    esac
    info "Dependencies installed."
}

detect_arch() {
    case "$(uname -m)" in
        aarch64|arm64) echo "arm64" ;;
        x86_64|amd64)  echo "amd64" ;;
        armv7*)         echo "arm" ;;
        *)              error "Unsupported architecture: $(uname -m)" ;;
    esac
}

create_dirs() {
    mkdir -p "$KOMARI_BIN_DIR" "$KOMARI_DATA_DIR" "$KOMARI_LOG_DIR" \
             "$KOMARI_SCRIPT_DIR" "$KOMARI_CONF_DIR"
    info "Directories created."
}

create_user() {
    if ! id "$KOMARI_SERVICE_USER" >/dev/null 2>&1; then
        useradd -r -s /usr/sbin/nologin -d "$KOMARI_HOME" "$KOMARI_SERVICE_USER" 2>/dev/null || \
        adduser -S -D -h "$KOMARI_HOME" "$KOMARI_SERVICE_USER" 2>/dev/null || true
        info "Service user created: $KOMARI_SERVICE_USER"
    fi
    chown -R "$KOMARI_SERVICE_USER:$KOMARI_SERVICE_USER" "$KOMARI_HOME" 2>/dev/null || true
}

download_binaries() {
    local arch="$1"
    info "Downloading runtime binaries..."

    local caddy_ver="${CADDY_VERSION:-2.9.1}"
    if [ ! -x "$KOMARI_BIN_DIR/caddy" ]; then
        hint "Downloading Caddy v${caddy_ver}..."
        wget -q "https://github.com/caddyserver/caddy/releases/download/v${caddy_ver}/caddy_${caddy_ver}_linux_${arch}.tar.gz" -O /tmp/caddy.tar.gz && \
        tar xzf /tmp/caddy.tar.gz -C "$KOMARI_BIN_DIR" caddy && \
        chmod +x "$KOMARI_BIN_DIR/caddy" && rm -f /tmp/caddy.tar.gz
        info "Caddy installed."
    else
        info "Caddy already exists, skip."
    fi

    if [ ! -x "$KOMARI_BIN_DIR/cloudflared" ]; then
        hint "Downloading Cloudflared..."
        wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" -O "$KOMARI_BIN_DIR/cloudflared" && \
        chmod +x "$KOMARI_BIN_DIR/cloudflared"
        info "Cloudflared installed."
    else
        info "Cloudflared already exists, skip."
    fi

    chown -R "$KOMARI_SERVICE_USER:$KOMARI_SERVICE_USER" "$KOMARI_BIN_DIR" 2>/dev/null || true
}

download_scripts() {
    info "Downloading management scripts..."
    for script in backup.sh restore.sh renew.sh sub_link.sh repo.conf; do
        curl -fsSL "${SCRIPT_BASE_URL}/${script}" -o "$KOMARI_SCRIPT_DIR/${script}" 2>/dev/null && \
        chmod +x "$KOMARI_SCRIPT_DIR/${script}" 2>/dev/null || true
    done
    cp "$KOMARI_SCRIPT_DIR/repo.conf" "$KOMARI_CONF_DIR/repo.conf" 2>/dev/null || true
    info "Scripts downloaded."
}

setup_env() {
    if [ ! -f "$KOMARI_CONF_DIR/.env" ]; then
        cat > "$KOMARI_CONF_DIR/.env" << ENVEOF
# komari config
GH_BACKUP_USER=your_github_username
GH_REPO=your_private_repo_name
GH_BACKUP_BRANCH=main
GH_PAT=your_github_personal_access_token
GH_EMAIL=your_github_email@example.com
ADMIN_USERNAME=admin
ADMIN_PASSWORD=changeme
ARGO_DOMAIN=your-argo-domain.com
KOMARI_CLOUDFLARED_TOKEN=eyJxxxxx
BACKUP_TIME="0 20 * * *"
BACKUP_DAYS=10
KOMARI_LOCK_TIMEOUT_SECONDS=60
NO_AUTO_RENEW=
CADDY_PROXY_PORT=8001
CADDY_VERSION=2.9.1
KOMARI_DISABLE_WEB_SSH=1
KOMARI_DISABLE_REMOTE=1
UUID=
CF_IP=ip.sb
SUB_NAME=komari
ENVEOF
        chmod 600 "$KOMARI_CONF_DIR/.env"
        hint "Edit $KOMARI_CONF_DIR/.env with real values."
    else
        info ".env already exists, skip."
    fi
}

setup_systemd() {
    info "Setting up systemd services..."
    cat > /etc/systemd/system/komari.service << SERVEOF
[Unit]
Description=Komari Dashboard
After=network.target

[Service]
Type=simple
User=$KOMARI_SERVICE_USER
Group=$KOMARI_SERVICE_USER
WorkingDirectory=$KOMARI_HOME
EnvironmentFile=-$KOMARI_CONF_DIR/.env
ExecStart=$KOMARI_BIN_DIR/komari server -l 0.0.0.0:25774
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SERVEOF

    cat > /etc/systemd/system/caddy.service << SERVEOF
[Unit]
Description=Caddy for Komari
After=network.target komari.service

[Service]
Type=simple
User=$KOMARI_SERVICE_USER
Group=$KOMARI_SERVICE_USER
WorkingDirectory=$KOMARI_HOME
EnvironmentFile=-$KOMARI_CONF_DIR/.env
ExecStart=$KOMARI_BIN_DIR/caddy run --config $KOMARI_HOME/Caddyfile --watch
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SERVEOF

    cat > /etc/systemd/system/cloudflared.service << SERVEOF
[Unit]
Description=Cloudflare Tunnel for Komari
After=network.target caddy.service

[Service]
Type=simple
User=$KOMARI_SERVICE_USER
Group=$KOMARI_SERVICE_USER
WorkingDirectory=$KOMARI_HOME
EnvironmentFile=-$KOMARI_CONF_DIR/.env
ExecStart=$KOMARI_BIN_DIR/cloudflared tunnel --edge-ip-version auto --protocol http2 run --token \${KOMARI_CLOUDFLARED_TOKEN}
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SERVEOF

    systemctl daemon-reload
    info "systemd services created."
}

setup_cron_vps() {
    info "Setting up cron jobs..."
    local cron_env="$KOMARI_CONF_DIR/cron_env.sh"
    cat > "$cron_env" << CRONENV
#!/usr/bin/env bash
KOMARI_HOME="\${KOMARI_HOME:-/opt/komari}"
[ -f "\$KOMARI_HOME/conf/.env" ] && . "\$KOMARI_HOME/conf/.env"
export KOMARI_HOME
export WORK_DIR="\$KOMARI_HOME"
export DATA_DIR="\$KOMARI_HOME/data"
export KOMARI_SOURCE_REPOSITORY="\${KOMARI_SOURCE_REPOSITORY:-jyucoeng/komari}"
export KOMARI_SOURCE_BRANCH="\${KOMARI_SOURCE_BRANCH:-main}"
export RESTORE_LOG="\$KOMARI_HOME/logs/restore.log"
export BACKUP_SCRIPT="\$KOMARI_HOME/scripts/backup.sh"
export RESTORE_STATE_FILE="/tmp/last_restore"
export KOMARI_LOCK_TIMEOUT_SECONDS="\${KOMARI_LOCK_TIMEOUT_SECONDS:-60}"
CRONENV
    chmod 600 "$cron_env"

    local tmpcron="/tmp/komari-crontab-$$"
    {
        echo "${BACKUP_TIME:-0 20 * * *} . $cron_env && bash $KOMARI_SCRIPT_DIR/backup.sh >> $KOMARI_LOG_DIR/backup.log 2>&1"
        echo "* * * * * . $cron_env && bash $KOMARI_SCRIPT_DIR/restore.sh a >> $KOMARI_LOG_DIR/restore-cron.log 2>&1"
        if [ -z "${NO_AUTO_RENEW:-}" ]; then
            echo "30 3 * * * . $cron_env && bash $KOMARI_SCRIPT_DIR/renew.sh >> $KOMARI_LOG_DIR/renew.log 2>&1"
        fi
    } > "$tmpcron"
    crontab -u "$KOMARI_SERVICE_USER" "$tmpcron" 2>/dev/null || crontab "$tmpcron"
    rm -f "$tmpcron"
    info "Cron jobs configured."
}

create_cli() {
    cat > /usr/local/bin/komari-cli << CLIEOF
#!/usr/bin/env bash
KOMARI_HOME="\${KOMARI_HOME:-/opt/komari}"
export WORK_DIR="\$KOMARI_HOME"
export DATA_DIR="\$KOMARI_HOME/data"
SCRIPT_DIR="\$KOMARI_HOME/scripts"
[ -f "\$KOMARI_HOME/conf/.env" ] && . "\$KOMARI_HOME/conf/.env"

case "\${1:-}" in
    backup)   [ -x "\$SCRIPT_DIR/backup.sh" ] && bash "\$SCRIPT_DIR/backup.sh" || echo "backup.sh not found" ;;
    restore)  shift; [ -x "\$SCRIPT_DIR/restore.sh" ] && bash "\$SCRIPT_DIR/restore.sh" "\$@" || echo "restore.sh not found" ;;
    renew)    [ -x "\$SCRIPT_DIR/renew.sh" ] && bash "\$SCRIPT_DIR/renew.sh" || echo "renew.sh not found" ;;
    status)   systemctl is-active komari 2>/dev/null; systemctl is-active caddy 2>/dev/null; systemctl is-active cloudflared 2>/dev/null ;;
    logs)     tail -n 50 "\$KOMARI_HOME/logs/backup.log" 2>/dev/null ;;
    *)        echo "Usage: komari-cli {backup|restore [file]|renew|status|logs}" ;;
esac
CLIEOF
    chmod +x /usr/local/bin/komari-cli
    info "CLI tool installed: /usr/local/bin/komari-cli"
}

generate_configs() {
    info "Generating runtime configs..."
    if [ ! -f "$KOMARI_HOME/Caddyfile" ]; then
        cat > "$KOMARI_HOME/Caddyfile" << CADDYEOF
:8001 {
    handle {
        reverse_proxy localhost:25774
    }
}
CADDYEOF
        hint "Default Caddyfile created."
    fi
    chown -R "$KOMARI_SERVICE_USER:$KOMARI_SERVICE_USER" "$KOMARI_HOME" 2>/dev/null || true
}

do_native_install() {
    info "=== Native VPS Installation ==="
    local os arch
    os=$(detect_os)
    arch=$(detect_arch)
    info "Detected OS: $os / Arch: $arch"

    install_deps "$os"
    create_dirs
    create_user
    download_binaries "$arch"
    download_scripts
    setup_env
    generate_configs
    setup_systemd
    setup_cron_vps
    create_cli

    info ""
    info "========================================"
    info "Native VPS installation complete!"
    hint "Next steps:"
    echo "  1. Edit config: vim $KOMARI_CONF_DIR/.env"
    echo "  2. Install komari binary to $KOMARI_BIN_DIR/komari"
    echo "  3. Start services: systemctl start komari caddy cloudflared"
    echo "  4. Enable auto-start: systemctl enable komari caddy cloudflared"
    echo "  5. Manage: komari-cli {backup|restore|renew|status|logs}"
    info "========================================"
}

echo ""
info "==================================="
info "   Komari Universal Installer"
info "==================================="

if detect_installed; then
    echo ""
    hint "Existing installation detected. Choose:"
    echo "  [1] Re-install (keep config)"
    echo "  [2] Uninstall komari"
    echo "  [3] Exit"
    printf "Enter [1-3]: "
    read -r choice
    case "${choice:-3}" in
        1) hint "Re-installing..." ;;
        2) do_uninstall ;;
        *) info "Exited."; exit 0 ;;
    esac
fi

echo ""
echo "Select install mode:"
echo "  [1] Docker"
echo "  [2] Native VPS"
echo "  [3] Exit"
printf "Enter [1-3]: "
read -r mode
case "${mode:-3}" in
    1) do_docker_install ;;
    2) do_native_install ;;
    *) info "Exited." ;;
esac
