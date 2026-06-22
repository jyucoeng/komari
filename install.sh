#!/usr/bin/env bash
#===============================================================================
#  Komari Dashboard - Install / Reinstall / Uninstall Script
#  Supports BOTH Docker and Native (VPS) installation modes.
#===============================================================================

set -o errexit
set -o pipefail
set -o nounset

# ---- Color & helpers ---------------------------------------------------------
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'
BOLD='\033[01m'

info()  { echo -e "${GREEN}${BOLD}$*${NC}"; }
error() { echo -e "${RED}${BOLD}$*${NC}" >&2; }
hint()  { echo -e "${YELLOW}${BOLD}$*${NC}"; }
cyan()  { echo -e "${CYAN}${BOLD}$*${NC}"; }

fatal() { error "$@"; exit 1; }

ok()    { echo -e "${GREEN}${BOLD}[OK]${NC} $*"; }
fail()  { echo -e "${RED}${BOLD}[FAIL]${NC} $*"; }
skip()  { echo -e "${YELLOW}${BOLD}[SKIP]${NC} $*"; }

confirm() {
    local prompt="${1:-Continue?} [y/N] "
    local ans
    read -r -p "$(echo -e "${YELLOW}${BOLD}${prompt}${NC}")" ans
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

# ---- Root check --------------------------------------------------------------
if [ "$(id -u)" -ne 0 ] && [ "${EUID:-}" -ne 0 ]; then
    fatal "This script must be run as root. Please use sudo or run as root."
fi

# ---- Paths -------------------------------------------------------------------
WORK_DIR="/opt/komari"
DATA_DIR="/opt/komari/data"
LOG_DIR="/opt/komari/logs"
SCRIPT_DIR="/opt/komari/scripts"
CONF_DIR="/opt/komari/conf"
BIN_DIR="/opt/komari/bin"
CLI_HELPER="/usr/local/bin/komari-cli"

SCRIPT_SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---- Source repo.conf (fallback to jyucoeng/komari) --------------------------
REPO_CONF_SOURCE="${SCRIPT_SOURCE_DIR}/repo.conf"
if [ -f "$REPO_CONF_SOURCE" ]; then
    . "$REPO_CONF_SOURCE"
fi
KOMARI_PROJECT_OWNER="${KOMARI_PROJECT_OWNER:-jyucoeng}"
KOMARI_PROJECT_NAME="${KOMARI_PROJECT_NAME:-komari}"
KOMARI_SOURCE_BRANCH="${KOMARI_SOURCE_BRANCH:-main}"
KOMARI_SOURCE_REPOSITORY="${KOMARI_SOURCE_REPOSITORY:-${KOMARI_PROJECT_OWNER}/${KOMARI_PROJECT_NAME}}"

# ---- Utility functions -------------------------------------------------------

platform_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv7)  echo "arm" ;;
        *) fatal "Unsupported architecture: $arch" ;;
    esac
}

os_family() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian)   echo "debian" ;;
            centos|rhel|fedora|rocky|almalinux) echo "rhel" ;;
            alpine)          echo "alpine" ;;
            *)               echo "$ID" ;;
        esac
    elif command -v apk >/dev/null 2>&1; then
        echo "alpine"
    elif command -v apt-get >/dev/null 2>&1; then
        echo "debian"
    elif command -v yum >/dev/null 2>&1; then
        echo "rhel"
    else
        echo "unknown"
    fi
}

pkg_install() {
    local family
    family="$(os_family)"
    case "$family" in
        debian)
            apt-get update -qq && apt-get install -y -qq "$@"
            ;;
        rhel)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y -q "$@"
            else
                yum install -y -q "$@"
            fi
            ;;
        alpine)
            apk add --no-cache "$@"
            ;;
        *)
            fatal "Unsupported OS family: $family. Please install dependencies manually: $*"
            ;;
    esac
}

service_exists() {
    systemctl list-unit-files 2>/dev/null | grep -q "^$1\.service"
}

service_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

enable_cron_service() {
    if command -v systemctl >/dev/null 2>&1; then
        for svc in cron crond; do
            if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
                systemctl enable "$svc" >/dev/null 2>&1 || true
                systemctl start "$svc" >/dev/null 2>&1 || true
                return 0
            fi
        done
    fi
    if command -v service >/dev/null 2>&1; then
        service cron start >/dev/null 2>&1 || service crond start >/dev/null 2>&1 || true
    fi
    if command -v rc-service >/dev/null 2>&1; then
        rc-update add crond default >/dev/null 2>&1 || true
        rc-service crond start >/dev/null 2>&1 || true
    fi
}

vps_require_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        fatal "Native VPS install requires systemd. Please use Docker mode on this system."
    fi
}

shell_quote() {
    printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\''/g")"
}

docker_compose_available() {
    docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1
}

docker_compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose "$@"
    else
        return 127
    fi
}

docker_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        printf 'docker compose'
    else
        printf 'docker-compose'
    fi
}

valid_cron_expr() {
    local expr="$1" field_count
    [ -n "$expr" ] || return 1
    printf "%s" "$expr" | grep -q '[[:cntrl:]]' && return 1
    field_count=$(printf "%s\n" "$expr" | awk '{print NF; exit}')
    [ "$field_count" = "5" ]
}

# ---- Detection ---------------------------------------------------------------
detect_installed() {
    if [ -d "$WORK_DIR" ]; then
        return 0
    fi
    if command -v docker >/dev/null 2>&1; then
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "komari"; then
            return 0
        fi
    fi
    if service_exists "komari"; then
        return 0
    fi
    return 1
}

# ==============================================================================
#  UNINSTALL
# ==============================================================================
uninstall_cleanup() {
    echo ""
    hint "========================================="
    hint "  Uninstall Komari"
    hint "========================================="
    echo ""

    if ! confirm "Are you sure you want to uninstall Komari? This will remove all data."; then
        info "Uninstall cancelled."
        return 1
    fi

    for svc in komari caddy cloudflared xray; do
        if service_exists "$svc"; then
            info "Stopping and disabling ${svc}.service..."
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            rm -f "/etc/systemd/system/${svc}.service"
        fi
    done
    systemctl daemon-reload 2>/dev/null || true

    info "Removing cron jobs..."
    crontab -l 2>/dev/null | grep -v "/opt/komari" | crontab - 2>/dev/null || true

    if command -v docker >/dev/null 2>&1; then
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "komari"; then
            info "Stopping and removing docker container 'komari'..."
            docker stop komari 2>/dev/null || true
            docker rm komari 2>/dev/null || true
        fi
        docker network rm komari-network 2>/dev/null || true
    fi

    if id "komari" >/dev/null 2>&1; then
        info "Removing komari user..."
        userdel -r komari 2>/dev/null || true
    fi
    if getent group "komari" >/dev/null 2>&1; then
        groupdel komari 2>/dev/null || true
    fi

    if [ -f "$CLI_HELPER" ]; then
        info "Removing komari-cli helper..."
        rm -f "$CLI_HELPER"
    fi

    echo ""
    if confirm "Remove all data in ${WORK_DIR} (including configs, databases, logs)?"; then
        info "Removing ${WORK_DIR}..."
        rm -rf "$WORK_DIR"
        info "All data removed."
    else
        info "Keeping ${WORK_DIR} in place."
    fi
    info "Komari has been uninstalled."
    return 0
}

# ==============================================================================
#  DOCKER INSTALL
# ==============================================================================
docker_install() {
    echo ""
    cyan "========================================="
    cyan "  Docker Installation Mode"
    cyan "========================================="
    echo ""

    if ! command -v docker >/dev/null 2>&1; then
        fatal "Docker is not installed. Please install Docker first: https://docs.docker.com/engine/install/"
    fi
    if ! docker_compose_available; then
        fatal "Docker Compose is not installed. Please install Docker Compose first."
    fi
    local compose_cmd
    compose_cmd="$(docker_compose_cmd)"

    if [ ! -f "${SCRIPT_SOURCE_DIR}/docker-compose.yml" ]; then
        fatal "docker-compose.yml not found in ${SCRIPT_SOURCE_DIR}. Please ensure the repository is cloned."
    fi

    if [ ! -f "${SCRIPT_SOURCE_DIR}/.env" ]; then
        info "Creating .env file from template..."
        if [ -f "${SCRIPT_SOURCE_DIR}/.env.example" ]; then
            cp "${SCRIPT_SOURCE_DIR}/.env.example" "${SCRIPT_SOURCE_DIR}/.env"
        else
            fatal ".env.example not found in ${SCRIPT_SOURCE_DIR}."
        fi
        echo ""
        hint "IMPORTANT: Please edit ${SCRIPT_SOURCE_DIR}/.env with your actual configuration values."
        hint "Required fields: GH_BACKUP_USER, GH_REPO, GH_PAT, GH_EMAIL, ADMIN_USERNAME,"
        hint "ADMIN_PASSWORD, ARGO_DOMAIN, KOMARI_CLOUDFLARED_TOKEN"
        echo ""
        if confirm "Open the .env file for editing now?"; then
            ${EDITOR:-vi} "${SCRIPT_SOURCE_DIR}/.env"
        else
            hint "Please edit ${SCRIPT_SOURCE_DIR}/.env manually before running '${compose_cmd} up -d'."
        fi
    else
        ok ".env already exists at ${SCRIPT_SOURCE_DIR}/.env"
    fi

    echo ""
    info "Pulling Docker images..."
    (cd "$SCRIPT_SOURCE_DIR" && docker_compose pull)

    echo ""
    info "Starting komari containers..."
    (cd "$SCRIPT_SOURCE_DIR" && docker_compose up -d)

    echo ""
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "komari"; then
        ok "Komari (Docker) is now running."
        echo ""
        info "Useful commands:"
        info "  View logs: ${compose_cmd} -f ${SCRIPT_SOURCE_DIR}/docker-compose.yml logs -f"
        info "  Restart:   ${compose_cmd} -f ${SCRIPT_SOURCE_DIR}/docker-compose.yml restart"
        info "  Stop:      ${compose_cmd} -f ${SCRIPT_SOURCE_DIR}/docker-compose.yml stop"
        info "  Update:    ${compose_cmd} pull && ${compose_cmd} up -d"
    else
        fail "Komari container failed to start. Check logs with: ${compose_cmd} logs"
    fi
}

# ==============================================================================
#  NATIVE VPS INSTALL
# ==============================================================================

vps_detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        info "Detected OS: $PRETTY_NAME"
        case "$ID" in
            ubuntu|debian|centos|rhel|fedora|rocky|almalinux|alpine) return 0 ;;
            *) hint "Unrecognized OS: $ID. Will attempt to proceed anyway."; return 0 ;;
        esac
    elif command -v apk >/dev/null 2>&1; then
        info "Detected OS: Alpine Linux"
        return 0
    else
        fatal "Cannot detect OS. /etc/os-release not found."
    fi
}

vps_install_deps() {
    info "Installing dependencies: curl wget git sqlite jq tar unzip cron..."
    case "$(os_family)" in
        debian)
            pkg_install curl wget git sqlite3 jq tar unzip cron
            ;;
        rhel)
            pkg_install curl wget git sqlite jq tar unzip cronie
            ;;
        alpine)
            pkg_install curl wget git sqlite jq tar unzip dcron
            ;;
        *)
            pkg_install curl wget git sqlite jq tar unzip
            ;;
    esac
}

vps_create_dirs() {
    info "Creating directory structure..."
    mkdir -p "$BIN_DIR" "$DATA_DIR" "$LOG_DIR" "$SCRIPT_DIR" "$CONF_DIR"
    ok "Directories created under $WORK_DIR"
}

vps_create_user() {
    if id "komari" >/dev/null 2>&1; then
        skip "User 'komari' already exists."
    else
        info "Creating 'komari' user and group..."
        if ! getent group "komari" >/dev/null 2>&1; then
            groupadd -r komari
        fi
        useradd -r -g komari -s /sbin/nologin -d "$WORK_DIR" -c "Komari Dashboard" komari
        ok "User 'komari' created."
    fi
    chown -R komari:komari "$WORK_DIR" 2>/dev/null || true
}

vps_download_komari() {
    local arch
    arch="$(platform_arch)"
    local bin_path="${BIN_DIR}/komari"
    local version="${KOMARI_VERSION:-latest}"

    if [ -x "$bin_path" ]; then
        skip "Komari binary already exists at ${bin_path}."
        return 0
    fi

    info "Downloading Komari binary..."
    local gh_releases_url tmp_bin
    tmp_bin="/tmp/komari-linux-${arch}.$$"
    for repo in "komari-monitor/komari" "$KOMARI_SOURCE_REPOSITORY"; do
        if [ -z "$repo" ]; then
            continue
        fi
        if [ -z "$version" ] || [ "$version" = "latest" ]; then
            gh_releases_url="https://github.com/${repo}/releases/latest/download/komari-linux-${arch}"
            info "Trying: ${gh_releases_url}"
            if wget -q --timeout=10 --tries=2 -O "$tmp_bin" "$gh_releases_url" 2>/dev/null && [ -s "$tmp_bin" ]; then
                info "Downloaded from GitHub releases (${repo})."
                mv "$tmp_bin" "$bin_path"
                chmod +x "$bin_path"
                ok "Komari binary installed at ${bin_path}"
                return 0
            fi
            rm -f "$tmp_bin"
        else
            local tag
            for tag in "$version" "v${version#v}"; do
                gh_releases_url="https://github.com/${repo}/releases/download/${tag}/komari-linux-${arch}"
                info "Trying: ${gh_releases_url}"
                if wget -q --timeout=10 --tries=2 -O "$tmp_bin" "$gh_releases_url" 2>/dev/null && [ -s "$tmp_bin" ]; then
                    info "Downloaded ${tag} from GitHub releases (${repo})."
                    mv "$tmp_bin" "$bin_path"
                    chmod +x "$bin_path"
                    ok "Komari binary installed at ${bin_path}"
                    return 0
                fi
                rm -f "$tmp_bin"
            done
        fi
    done

    if command -v docker >/dev/null 2>&1; then
        info "GitHub releases failed. Attempting to extract komari binary from GHCR image..."
        local ghcr_image="ghcr.io/komari-monitor/komari:${version:-latest}"
        info "Pulling ${ghcr_image}..."
        if docker pull "$ghcr_image" 2>/dev/null; then
            local tmp_container
            tmp_container="komari-extract-$$"
            docker create --name "$tmp_container" "$ghcr_image" 2>/dev/null || true
            if docker cp "$tmp_container:/app/komari" "$bin_path" 2>/dev/null; then
                chmod +x "$bin_path"
                docker rm "$tmp_container" >/dev/null 2>&1 || true
                ok "Komari binary extracted from GHCR image."
                return 0
            fi
            docker rm "$tmp_container" >/dev/null 2>&1 || true
        fi
    fi
    fatal "Failed to download komari binary. Please download manually and place at ${bin_path}"
}

vps_download_caddy() {
    local arch
    arch="$(platform_arch)"
    local caddy_version="${CADDY_VERSION:-2.9.1}"
    local bin_path="${BIN_DIR}/caddy"

    if [ -x "$bin_path" ] && "$bin_path" version 2>/dev/null | grep -q "v$caddy_version"; then
        skip "Caddy v${caddy_version} already installed."
        return 0
    fi

    info "Downloading Caddy v${caddy_version}..."
    case "$arch" in
        amd64) caddy_arch="amd64" ;;
        arm64) caddy_arch="arm64" ;;
        arm)   caddy_arch="armv7" ;;
        *)     fatal "Unsupported arch for caddy: $arch" ;;
    esac

    local url="https://github.com/caddyserver/caddy/releases/download/v${caddy_version}/caddy_${caddy_version}_linux_${caddy_arch}.tar.gz"
    wget -q --show-progress "$url" -O /tmp/caddy.tar.gz || fatal "Caddy download failed."
    tar xzf /tmp/caddy.tar.gz -C "$BIN_DIR" caddy || fatal "Caddy extraction failed."
    rm -f /tmp/caddy.tar.gz
    chmod +x "$bin_path"
    ok "Caddy v${caddy_version} installed at ${bin_path}"
}

vps_download_cloudflared() {
    local arch
    arch="$(platform_arch)"
    local bin_path="${BIN_DIR}/cloudflared"

    if [ -x "$bin_path" ]; then
        skip "Cloudflared already installed."
        return 0
    fi

    info "Downloading Cloudflared..."
    case "$arch" in
        amd64) cf_arch="amd64" ;;
        arm64) cf_arch="arm64" ;;
        arm)   cf_arch="arm" ;;
        *)     fatal "Unsupported arch for cloudflared: $arch" ;;
    esac

    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"
    wget -q --show-progress "$url" -O "$bin_path" || fatal "Cloudflared download failed."
    chmod +x "$bin_path"
    ok "Cloudflared installed at ${bin_path}"
}

vps_download_xray() {
    local arch
    arch="$(platform_arch)"
    local bin_path="${BIN_DIR}/xray"

    if [ -x "$bin_path" ]; then
        skip "Xray already installed."
        return 0
    fi

    info "Downloading Xray..."
    case "$arch" in
        amd64) xray_asset="Xray-linux-64.zip" ;;
        arm64) xray_asset="Xray-linux-arm64-v8a.zip" ;;
        arm)   xray_asset="Xray-linux-arm32-v7a.zip" ;;
        *)     fatal "Unsupported arch for xray: $arch" ;;
    esac

    local url="https://github.com/XTLS/Xray-core/releases/latest/download/${xray_asset}"
    wget -q --show-progress "$url" -O /tmp/xray.zip || fatal "Xray download failed."
    unzip -qo /tmp/xray.zip -d "$BIN_DIR" xray || fatal "Xray extraction failed."
    chmod +x "$bin_path"
    rm -f /tmp/xray.zip
    ok "Xray installed at ${bin_path}"
}

vps_copy_scripts() {
    info "Copying scripts..."

    local scripts=(backup.sh restore.sh renew.sh sub_link.sh)
    for script in "${scripts[@]}"; do
        local src="${SCRIPT_SOURCE_DIR}/${script}"
        local dst="${SCRIPT_DIR}/${script}"
        if [ -f "$src" ]; then
            cp "$src" "$dst"
            chmod +x "$dst"
            ok "Copied ${script}"
        else
            fail "Source script not found: ${src}"
        fi
    done

    if [ -f "$REPO_CONF_SOURCE" ]; then
        cp "$REPO_CONF_SOURCE" "${CONF_DIR}/repo.conf"
        ok "Copied repo.conf"
    fi

    # --- Create setup-config.sh ---
    info "Creating setup-config.sh..."
    cat > "${SCRIPT_DIR}/setup-config.sh" << 'SETUPSCRIPT'
#!/usr/bin/env bash
#===============================================================================
#  Komari Configuration Generator (Native VPS)
#===============================================================================
set -o errexit
CONF_DIR="/opt/komari/conf"
BIN_DIR="/opt/komari/bin"
LOG_DIR="/opt/komari/logs"

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; NC='\033[0m'; BOLD='\033[01m'
info()  { echo -e "${GREEN}${BOLD}$*${NC}"; }
error() { echo -e "${RED}${BOLD}$*${NC}" >&2; }
hint()  { echo -e "${YELLOW}${BOLD}$*${NC}"; }

if [ -f "${CONF_DIR}/.env" ]; then
    set -o allexport
    . "${CONF_DIR}/.env"
    set +o allexport
else
    error ".env not found at ${CONF_DIR}/.env"
    exit 1
fi

missing=0
for var in ADMIN_USERNAME ADMIN_PASSWORD ARGO_DOMAIN KOMARI_CLOUDFLARED_TOKEN; do
    if [ -z "${!var:-}" ]; then
        error "Missing required env var: $var"
        missing=1
    fi
done
[ "$missing" -eq 1 ] && exit 1

CADDY_PROXY_PORT="${CADDY_PROXY_PORT:-8001}"
XRAY_VLESS_PORT="${XRAY_VLESS_PORT:-8002}"
XRAY_VMESS_PORT="${XRAY_VMESS_PORT:-8003}"

info "Generating Caddyfile..."
CADDYFILE="${CONF_DIR}/Caddyfile"
cat > "$CADDYFILE" << CADDYEOF
:${CADDY_PROXY_PORT} {
CADDYEOF

if [ -n "${UUID:-}" ] && [ "${UUID}" != "0" ]; then
    cat >> "$CADDYFILE" << CADDYEOF
    handle /${UUID} {
        rewrite * /list.log
        file_server { root /tmp }
    }
    reverse_proxy /vls* 127.0.0.1:${XRAY_VLESS_PORT}
    reverse_proxy /vms* 127.0.0.1:${XRAY_VMESS_PORT}
CADDYEOF
fi

if [ "${KOMARI_DISABLE_WEB_SSH:-1}" = "1" ] || [ "${KOMARI_DISABLE_WEB_SSH:-1}" = "true" ] || \
   [ "${KOMARI_DISABLE_REMOTE:-1}" = "1" ] || [ "${KOMARI_DISABLE_REMOTE:-1}" = "true" ]; then
    cat >> "$CADDYFILE" << 'CADDYEOF'
    @blockedRemote path_regexp blockedRemote ^/(api/clients/terminal|api/admin/client/[^/]+/terminal|api/admin/task/exec|terminal)(/.*)?$
    respond @blockedRemote 403
CADDYEOF
fi

cat >> "$CADDYFILE" << CADDYEOF
    handle {
        reverse_proxy 127.0.0.1:25774
    }
}
CADDYEOF
info "Caddyfile generated at ${CADDYFILE}"

if [ -n "${UUID:-}" ] && [ "${UUID}" != "0" ]; then
    info "Generating xray.json..."
    XRAY_CONF="${CONF_DIR}/xray.json"
    cat > "$XRAY_CONF" << XRAYEOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${XRAY_VLESS_PORT},
      "protocol": "vless",
      "settings": { "clients": [{ "id": "${UUID}" }], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vls" } }
    },
    {
      "listen": "127.0.0.1",
      "port": ${XRAY_VMESS_PORT},
      "protocol": "vmess",
      "settings": { "clients": [{ "id": "${UUID}", "alterId": 0 }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vms" } }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
XRAYEOF
    info "xray.json generated at ${XRAY_CONF}"
    if [ -x "/opt/komari/scripts/sub_link.sh" ]; then
        info "Generating subscription links..."
        export UUID CADDY_PROXY_PORT ARGO_DOMAIN CF_IP="${CF_IP:-ip.sb}" SUB_NAME="${SUB_NAME:-komari}"
        bash "/opt/komari/scripts/sub_link.sh" || hint "Subscription link generation failed."
    fi
else
    hint "UUID not set; skipping xray config."
fi
info "Configuration generation complete."
SETUPSCRIPT
    chmod +x "${SCRIPT_DIR}/setup-config.sh"
    ok "Created setup-config.sh"

    # --- Create start.sh ---
    info "Creating start.sh..."
    cat > "${SCRIPT_DIR}/start.sh" << 'STARTSCRIPT'
#!/usr/bin/env bash
set -o errexit
CONF_DIR="/opt/komari/conf"
LOG_DIR="/opt/komari/logs"
GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; NC='\033[0m'; BOLD='\033[01m'
info()  { echo -e "${GREEN}${BOLD}$*${NC}"; }
error() { echo -e "${RED}${BOLD}$*${NC}" >&2; }
hint()  { echo -e "${YELLOW}${BOLD}$*${NC}"; }
if [ -f "${CONF_DIR}/.env" ]; then
    set -o allexport
    . "${CONF_DIR}/.env"
    set +o allexport
fi
bash "/opt/komari/scripts/setup-config.sh" || hint "setup-config.sh issues."
info "Starting Komari services..."
systemctl start komari 2>/dev/null || error "Failed to start komari.service"
systemctl start caddy 2>/dev/null || error "Failed to start caddy.service"
systemctl start cloudflared 2>/dev/null || error "Failed to start cloudflared.service"
if [ -n "${UUID:-}" ] && [ "${UUID}" != "0" ]; then
    systemctl start xray 2>/dev/null || hint "xray.service not found."
fi
info "All services started."
STARTSCRIPT
    chmod +x "${SCRIPT_DIR}/start.sh"
    ok "Created start.sh"

    # --- Create komari-start wrapper ---
    info "Creating komari-start wrapper..."
    cat > "${SCRIPT_DIR}/komari-start.sh" << 'KOMARISTART'
#!/usr/bin/env bash
set -o errexit
CONF_DIR="/opt/komari/conf"
BIN_DIR="/opt/komari/bin"
DATA_DIR="/opt/komari/data"
if [ -f "${CONF_DIR}/.env" ]; then
    set -o allexport
    . "${CONF_DIR}/.env"
    set +o allexport
fi
truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}
disable_remote_features() {
    local db="${KOMARI_DB_FILE:-${DATA_DIR}/komari.db}"
    [ -f "$db" ] || return 0
    command -v sqlite3 >/dev/null 2>&1 || command -v sqlite >/dev/null 2>&1 || return 0
    local sqlite_bin
    sqlite_bin="$(command -v sqlite3 2>/dev/null || command -v sqlite 2>/dev/null)"
    "$sqlite_bin" "$db" "INSERT INTO configs(key, value) VALUES ('terminal_enabled','false'),('web_ssh_enabled','false'),('remote_terminal_enabled','false'),('remote_execute_enabled','false'),('remote_command_enabled','false'),('command_execute_enabled','false'),('disable_web_ssh','true'),('disable_remote','true'),('disable_command_execute','true'),('disable_terminal','true') ON CONFLICT(key) DO UPDATE SET value=excluded.value;" >/dev/null 2>&1 || true
    "$sqlite_bin" "$db" "UPDATE configs SET terminal_enabled=0, web_ssh_enabled=0, remote_terminal_enabled=0, remote_execute_enabled=0, remote_command_enabled=0, command_execute_enabled=0 WHERE id IS NOT NULL;" >/dev/null 2>&1 || true
}
KOMARI_LISTEN_ADDR="${KOMARI_LISTEN_ADDR:-0.0.0.0:25774}"
KOMARI_DISABLE_WEB_SSH="${KOMARI_DISABLE_WEB_SSH:-${DISABLE_WEB_SSH:-1}}"
KOMARI_DISABLE_REMOTE="${KOMARI_DISABLE_REMOTE:-${DISABLE_REMOTE:-1}}"
if truthy "$KOMARI_DISABLE_WEB_SSH" || truthy "$KOMARI_DISABLE_REMOTE"; then
    disable_remote_features
fi
args=(server -l "$KOMARI_LISTEN_ADDR")
if truthy "$KOMARI_DISABLE_WEB_SSH" && "$BIN_DIR/komari" server --help 2>&1 | grep -q -- '--disable-web-ssh'; then
    args+=(--disable-web-ssh)
fi
exec "$BIN_DIR/komari" "${args[@]}"
KOMARISTART
    chmod +x "${SCRIPT_DIR}/komari-start.sh"
    ok "Created komari-start wrapper"

    # --- Create stop.sh ---
    cat > "${SCRIPT_DIR}/stop.sh" << 'STOPSCRIPT'
#!/usr/bin/env bash
GREEN='\033[32m'; RED='\033[31m'; NC='\033[0m'; BOLD='\033[01m'
info()  { echo -e "${GREEN}${BOLD}$*${NC}"; }
info "Stopping Komari services..."
for svc in komari cloudflared caddy xray; do
    systemctl stop "$svc" 2>/dev/null || true
done
info "All services stopped."
STOPSCRIPT
    chmod +x "${SCRIPT_DIR}/stop.sh"
    ok "Created stop.sh"
}

vps_create_env() {
    local env_file="${CONF_DIR}/.env"

    if [ -f "$env_file" ]; then
        skip ".env already exists at ${env_file}"
        if confirm "Edit existing .env?"; then
            ${EDITOR:-vi} "$env_file"
        fi
        return 0
    fi

    info "Creating .env configuration file..."
    echo ""

    if [ -f "${SCRIPT_SOURCE_DIR}/.env.example" ]; then
        cp "${SCRIPT_SOURCE_DIR}/.env.example" "$env_file"
        hint "Template copied from .env.example."
    else
        cat > "$env_file" << 'ENVEOF'
#===============================================================================
#  Komari Configuration (Native VPS)
#===============================================================================

# GitHub backup repository
GH_BACKUP_USER=your_github_username
GH_REPO=your_private_repo_name
GH_BACKUP_BRANCH=main
GH_PAT=your_github_personal_access_token
GH_EMAIL=your_github_email@example.com

# Komari admin account
ADMIN_USERNAME=yourusername
ADMIN_PASSWORD=yourpassword

# Cloudflare tunnel
ARGO_DOMAIN=your-argo-domain.com
KOMARI_CLOUDFLARED_TOKEN=eyJxxxxx

# Backup schedule (UTC cron format)
BACKUP_TIME="0 20 * * *"
BACKUP_DAYS=10
KOMARI_LOCK_TIMEOUT_SECONDS=60

# Script auto update (set to 1 to disable)
NO_AUTO_RENEW=

# Caddy reverse proxy ports
CADDY_PROXY_PORT=8001
XRAY_VLESS_PORT=8002
XRAY_VMESS_PORT=8003

# Disable web SSH/remote features (set to 0 to enable)
KOMARI_DISABLE_WEB_SSH=1
KOMARI_DISABLE_REMOTE=1

# Optional subscription UUID (leave empty to disable)
UUID=
CF_IP=ip.sb
SUB_NAME=komari

# Komari listen address
KOMARI_LISTEN_ADDR=0.0.0.0:25774
ENVEOF
        hint "Created default .env file."
    fi

    chown komari:komari "$env_file"
    chmod 600 "$env_file"

    echo ""
    hint "============================================"
    hint "  IMPORTANT: Edit ${env_file}"
    hint "  Required: GH_BACKUP_USER, GH_REPO, GH_PAT, GH_EMAIL"
    hint "  Required: ADMIN_USERNAME, ADMIN_PASSWORD"
    hint "  Required: ARGO_DOMAIN, KOMARI_CLOUDFLARED_TOKEN"
    hint "============================================"
    echo ""

    if confirm "Open the .env file for editing now?"; then
        ${EDITOR:-vi} "$env_file"
    else
        hint "Please edit ${env_file} manually before starting services."
    fi
}

vps_create_systemd_services() {
    info "Creating systemd service files..."

    local env_file="${CONF_DIR}/.env"
    local CADDY_PROXY_PORT="8001"
    local XRAY_VLESS_PORT="8002"
    local XRAY_VMESS_PORT="8003"
    local KOMARI_LISTEN_ADDR="0.0.0.0:25774"
    local UUID=""

    if [ -f "$env_file" ]; then
        . "$env_file"
    fi

    # komari.service
    info "Creating komari.service..."
    cat > /etc/systemd/system/komari.service << KOMSVC
[Unit]
Description=Komari Dashboard
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=komari
Group=komari
WorkingDirectory=${WORK_DIR}
EnvironmentFile=${CONF_DIR}/.env
ExecStart=${SCRIPT_DIR}/komari-start.sh
Restart=always
RestartSec=5
LimitNOFILE=65535
StandardOutput=append:${LOG_DIR}/komari.log
StandardError=append:${LOG_DIR}/komari-error.log

[Install]
WantedBy=multi-user.target
KOMSVC

    # caddy.service
    info "Creating caddy.service..."
    cat > /etc/systemd/system/caddy.service << CADDYSVC
[Unit]
Description=Caddy Reverse Proxy
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=komari
Group=komari
WorkingDirectory=${WORK_DIR}
EnvironmentFile=${CONF_DIR}/.env
ExecStart=${BIN_DIR}/caddy run --config ${CONF_DIR}/Caddyfile --watch
ExecReload=${BIN_DIR}/caddy reload --config ${CONF_DIR}/Caddyfile
Restart=always
RestartSec=5
LimitNOFILE=65535
StandardOutput=append:${LOG_DIR}/caddy.log
StandardError=append:${LOG_DIR}/caddy-error.log

[Install]
WantedBy=multi-user.target
CADDYSVC

    # cloudflared.service
    info "Creating cloudflared.service..."
    cat > /etc/systemd/system/cloudflared.service << CFSVC
[Unit]
Description=Cloudflare Tunnel
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=komari
Group=komari
EnvironmentFile=${CONF_DIR}/.env
ExecStart=${BIN_DIR}/cloudflared tunnel --edge-ip-version auto --protocol http2 run --token \${KOMARI_CLOUDFLARED_TOKEN}
Restart=always
RestartSec=5
StandardOutput=append:${LOG_DIR}/cloudflared.log
StandardError=append:${LOG_DIR}/cloudflared-error.log

[Install]
WantedBy=multi-user.target
CFSVC

    # xray.service
    info "Creating xray.service..."
    cat > /etc/systemd/system/xray.service << XRAYSVC
[Unit]
Description=Xray VLESS/VMESS Backend
After=network.target
ConditionPathExists=${CONF_DIR}/xray.json

[Service]
Type=simple
User=komari
Group=komari
EnvironmentFile=${CONF_DIR}/.env
ExecStart=${BIN_DIR}/xray run -config ${CONF_DIR}/xray.json
Restart=always
RestartSec=5
StandardOutput=append:${LOG_DIR}/xray.log
StandardError=append:${LOG_DIR}/xray-error.log

[Install]
WantedBy=multi-user.target
XRAYSVC

    systemctl daemon-reload
    ok "Systemd services created."

    info "Enabling services..."
    systemctl enable komari || hint "Failed to enable komari.service"
    systemctl enable caddy || hint "Failed to enable caddy.service"
    systemctl enable cloudflared || hint "Failed to enable cloudflared.service"
    if [ -n "${UUID:-}" ] && [ "${UUID}" != "0" ]; then
        systemctl enable xray 2>/dev/null || true
    fi
    ok "Services enabled."
}

vps_setup_cron() {
    info "Setting up cron jobs..."

    local env_file="${CONF_DIR}/.env"
    local BACKUP_TIME="0 20 * * *"
    local NO_AUTO_RENEW=""
    if [ -f "$env_file" ]; then
        . "$env_file"
    fi
    if ! valid_cron_expr "$BACKUP_TIME"; then
        fatal "BACKUP_TIME must be a 5-field cron expression, for example: 0 */1 * * *"
    fi

    crontab -l 2>/dev/null | grep -v "/opt/komari" | crontab - 2>/dev/null || true

    local cron_file
    cron_file=$(mktemp)
    crontab -l 2>/dev/null | grep -v "/opt/komari" > "$cron_file" || true

    local cron_env="${CONF_DIR}/cron_env.sh"
    cat > "$cron_env" << CRONENV
#!/usr/bin/env bash
export GH_BACKUP_USER="${GH_BACKUP_USER:-}"
export GH_REPO="${GH_REPO:-}"
export GH_BACKUP_BRANCH="${GH_BACKUP_BRANCH:-main}"
export GH_PAT="${GH_PAT:-}"
export GH_EMAIL="${GH_EMAIL:-}"
export BACKUP_DAYS="${BACKUP_DAYS:-10}"
export KOMARI_LOCK_TIMEOUT_SECONDS="${KOMARI_LOCK_TIMEOUT_SECONDS:-60}"
export KOMARI_HOME="/opt/komari"
export KOMARI_ENV_FILE="/opt/komari/conf/.env"
export BACKUP_SCRIPT="/opt/komari/scripts/backup.sh"
export RESTORE_LOG="/opt/komari/logs/restore.log"
export RENEW_LOG="/opt/komari/logs/renew.log"
export UUID="${UUID:-}"
export ARGO_DOMAIN="${ARGO_DOMAIN:-}"
export CF_IP="${CF_IP:-ip.sb}"
export SUB_NAME="${SUB_NAME:-komari}"
export CADDY_PROXY_PORT="${CADDY_PROXY_PORT:-8001}"
export XRAY_VLESS_PORT="${XRAY_VLESS_PORT:-8002}"
export XRAY_VMESS_PORT="${XRAY_VMESS_PORT:-8003}"
export WORK_DIR="/opt/komari"
export DATA_DIR="/opt/komari/data"
export SCRIPT_DIR="/opt/komari/scripts"
export CONF_DIR="/opt/komari/conf"
export REPO_CONF="/opt/komari/conf/repo.conf"
CRONENV
    chmod 600 "$cron_env"

    {
        echo "# Komari backup"
        echo "${BACKUP_TIME} . $(shell_quote "$cron_env") && bash $(shell_quote "${SCRIPT_DIR}/backup.sh") >> $(shell_quote "${LOG_DIR}/backup.log") 2>&1"
        echo "# Komari auto-restore"
        echo "* * * * * . $(shell_quote "$cron_env") && bash $(shell_quote "${SCRIPT_DIR}/restore.sh") a >> $(shell_quote "${LOG_DIR}/restore-cron.log") 2>&1"
    } >> "$cron_file"

    if [ -z "${NO_AUTO_RENEW:-}" ]; then
        echo "# Komari auto-renew" >> "$cron_file"
        echo "30 3 * * * . $(shell_quote "$cron_env") && bash $(shell_quote "${SCRIPT_DIR}/renew.sh") >> $(shell_quote "${LOG_DIR}/renew.log") 2>&1" >> "$cron_file"
    fi

    crontab "$cron_file"
    rm -f "$cron_file"
    enable_cron_service
    ok "Cron jobs installed."
}

vps_generate_initial_configs() {
    info "Generating initial configurations..."
    if [ -x "${SCRIPT_DIR}/setup-config.sh" ]; then
        bash "${SCRIPT_DIR}/setup-config.sh" || hint "setup-config.sh encountered issues (can be re-run later)."
    fi
    if [ ! -f "${CONF_DIR}/Caddyfile" ]; then
        local CADDY_PROXY_PORT="${CADDY_PROXY_PORT:-8001}"
        cat > "${CONF_DIR}/Caddyfile" << CADDYEOF
:${CADDY_PROXY_PORT} {
    handle {
        reverse_proxy 127.0.0.1:25774
    }
}
CADDYEOF
        ok "Created minimal fallback Caddyfile."
    fi
    chown -R komari:komari "$CONF_DIR"
}

vps_create_komari_cli() {
    info "Creating komari-cli helper..."

    cat > "$CLI_HELPER" << 'CLIEOF'
#!/usr/bin/env bash
set -o errexit
WORK_DIR="/opt/komari"
BIN_DIR="/opt/komari/bin"
SCRIPT_DIR="/opt/komari/scripts"
CONF_DIR="/opt/komari/conf"
LOG_DIR="/opt/komari/logs"
DATA_DIR="/opt/komari/data"
export KOMARI_HOME="$WORK_DIR"
export KOMARI_ENV_FILE="${CONF_DIR}/.env"
export WORK_DIR DATA_DIR SCRIPT_DIR CONF_DIR
export BACKUP_SCRIPT="${SCRIPT_DIR}/backup.sh"
export REPO_CONF="${CONF_DIR}/repo.conf"

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; CYAN='\033[36m'; NC='\033[0m'; BOLD='\033[01m'
info()  { echo -e "${GREEN}${BOLD}$*${NC}"; }
error() { echo -e "${RED}${BOLD}$*${NC}" >&2; }
hint()  { echo -e "${YELLOW}${BOLD}$*${NC}"; }
cyan()  { echo -e "${CYAN}${BOLD}$*${NC}"; }

usage() {
    cat << USAGE
$(cyan "komari-cli - Komari Dashboard Command Helper")

Usage: komari-cli <command> [options]

Commands:
  start           Start all komari services
  stop            Stop all komari services
  restart         Restart all komari services
  status          Show status of all komari services
  logs [svc]      View logs (svc: komari, caddy, cloudflared, xray)
  config          Generate/re-generate Caddyfile and xray.json from .env
  backup          Run backup immediately
  restore [args]  Run restore (interactive or with args)
  update          Update scripts from GitHub
  subscription    Generate subscription links
  edit-config     Edit .env configuration
  shell           Open a shell in the komari working directory
  version         Show version information
  help            Show this help message
USAGE
}

case "${1:-help}" in
    start)
        info "Starting all komari services..."
        sudo systemctl start komari caddy cloudflared
        if [ -f "${CONF_DIR}/xray.json" ]; then
            sudo systemctl start xray 2>/dev/null || true
        fi
        info "Done." ;;
    stop)
        info "Stopping all komari services..."
        for svc in komari cloudflared caddy xray; do
            sudo systemctl stop "$svc" 2>/dev/null || true
        done
        info "Done." ;;
    restart)
        info "Restarting all komari services..."
        sudo systemctl restart komari caddy cloudflared
        if [ -f "${CONF_DIR}/xray.json" ]; then
            sudo systemctl restart xray 2>/dev/null || true
        fi
        info "Done." ;;
    status)
        echo ""
        for svc in komari caddy cloudflared xray; do
            if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
                systemctl status "$svc" --no-pager 2>&1 | head -5
                echo ""
            fi
        done ;;
    logs)
        svc="${2:-all}"
        if [ "$svc" = "all" ]; then
            tail -f "${LOG_DIR}/komari.log" "${LOG_DIR}/caddy.log" "${LOG_DIR}/cloudflared.log" "${LOG_DIR}/xray.log" 2>/dev/null || \
            hint "No log files found in ${LOG_DIR}"
        else
            log_file="${LOG_DIR}/${svc}.log"
            if [ -f "$log_file" ]; then
                tail -f "$log_file"
            else
                journalctl -u "${svc}.service" -f --no-pager 2>/dev/null || \
                error "Log file not found: ${log_file}"
            fi
        fi ;;
    config)
        info "Regenerating configuration files..."
        sudo bash "${SCRIPT_DIR}/setup-config.sh" ;;
    backup)
        info "Running backup..."
        sudo bash "${SCRIPT_DIR}/backup.sh" ;;
    restore)
        shift
        sudo bash "${SCRIPT_DIR}/restore.sh" "$@" ;;
    update)
        info "Updating scripts from GitHub..."
        sudo bash "${SCRIPT_DIR}/renew.sh" ;;
    subscription|sub)
        info "Generating subscription links..."
        if [ -f "${CONF_DIR}/.env" ]; then
            set -o allexport
            . "${CONF_DIR}/.env"
            set +o allexport
            export UUID CADDY_PROXY_PORT ARGO_DOMAIN CF_IP SUB_NAME
        fi
        sudo bash "${SCRIPT_DIR}/sub_link.sh" ;;
    edit-config|env)
        ${EDITOR:-vi} "${CONF_DIR}/.env" ;;
    shell)
        cd "$WORK_DIR" && exec "${SHELL:-/bin/bash}" ;;
    version)
        echo ""
        echo "Komari Dashboard - Native VPS"
        echo "Work Dir: ${WORK_DIR}"
        if [ -x "${BIN_DIR}/komari" ]; then
            "${BIN_DIR}/komari" version 2>/dev/null || echo "Komari binary: present"
        fi
        echo "Source: $(grep KOMARI_SOURCE_REPOSITORY "${CONF_DIR}/repo.conf" 2>/dev/null || echo "N/A")" ;;
    help|--help|-h|*)
        usage ;;
esac
CLIEOF

    chmod +x "$CLI_HELPER"
    ok "komari-cli installed at ${CLI_HELPER}"
}

# ==============================================================================
#  NATIVE VPS MAIN
# ==============================================================================
vps_install() {
    echo ""
    cyan "========================================="
    cyan "  Native VPS Installation Mode"
    cyan "========================================="
    echo ""

    vps_detect_os
    vps_require_systemd
    vps_install_deps
    vps_create_dirs
    vps_create_user
    vps_download_komari
    vps_download_caddy
    vps_download_cloudflared
    vps_download_xray
    vps_copy_scripts
    vps_create_env
    vps_create_systemd_services
    vps_generate_initial_configs
    vps_setup_cron
    vps_create_komari_cli

    chown -R komari:komari "$WORK_DIR" 2>/dev/null || true

    echo ""
    cyan "========================================="
    cyan "  Native VPS Installation Complete!"
    cyan "========================================="
    echo ""
    info "Installation path: ${WORK_DIR}"
    echo ""
    info "Next steps:"
    info "  1. Edit ${CONF_DIR}/.env with your actual values."
    info "     Run: komari-cli edit-config"
    info "  2. Regenerate config files: komari-cli config"
    info "  3. Start services:          komari-cli start"
    info "     or: systemctl start komari caddy cloudflared"
    echo ""
    info "Useful commands:"
    info "  komari-cli status         - Check service status"
    info "  komari-cli logs caddy     - View Caddy logs"
    info "  komari-cli backup         - Run backup immediately"
    info "  komari-cli help           - Show all commands"
    echo ""

    if confirm "Start komari services now?"; then
        bash "${SCRIPT_DIR}/setup-config.sh" 2>/dev/null || true
        systemctl start komari caddy cloudflared 2>/dev/null || \
        hint "Some services failed to start. Check status with: komari-cli status"
        if [ -f "${CONF_DIR}/xray.json" ]; then
            systemctl start xray 2>/dev/null || true
        fi
        info "Services started."
    fi
}

# ==============================================================================
#  REINSTALL (keep config)
# ==============================================================================
reinstall_keep_config() {
    echo ""
    cyan "========================================="
    cyan "  Re-install (Keep Configuration)"
    cyan "========================================="
    echo ""
    hint "This will re-install binaries and scripts but keep your existing config."
    hint "Configuration in ${CONF_DIR} will be preserved."
    echo ""

    if ! confirm "Proceed with re-install?"; then
        info "Re-install cancelled."
        return 1
    fi

    if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "komari"; then
        info "Docker mode detected. Re-pulling and restarting..."
        if [ -f "${SCRIPT_SOURCE_DIR}/docker-compose.yml" ]; then
            if ! docker_compose_available; then
                fatal "Docker Compose is not installed. Please install Docker Compose first."
            fi
            (cd "$SCRIPT_SOURCE_DIR" && docker_compose pull && docker_compose up -d) || \
            fatal "Docker compose failed."
        else
            local image
            image=$(docker inspect komari --format '{{.Config.Image}}' 2>/dev/null || echo "ghcr.io/hynize/komari:latest")
            docker pull "$image"
            docker stop komari 2>/dev/null || true
            docker rm komari 2>/dev/null || true
            if ! docker_compose_available; then
                fatal "Docker Compose is not installed. Please restart the container manually."
            fi
            (cd "$SCRIPT_SOURCE_DIR" && docker_compose up -d) 2>/dev/null || \
            fatal "Please restart the container manually."
        fi
        ok "Docker container re-installed and restarted."
    elif [ -d "$WORK_DIR" ] || service_exists "komari"; then
        info "Native VPS mode detected. Re-installing binaries and scripts..."
        local backup_conf=""
        local backup_data=""

        if [ -d "$CONF_DIR" ]; then
            backup_conf=$(mktemp -d "/tmp/komari-conf-backup-XXXXXX")
            cp -r "$CONF_DIR"/* "$backup_conf/" 2>/dev/null || true
            info "Configuration backed up."
        fi
        if [ -d "$DATA_DIR" ]; then
            backup_data=$(mktemp -d "/tmp/komari-data-backup-XXXXXX")
            cp -r "$DATA_DIR"/* "$backup_data/" 2>/dev/null || true
            info "Data backed up."
        fi

        for svc in komari caddy cloudflared xray; do
            systemctl stop "$svc" 2>/dev/null || true
        done

        rm -rf "$BIN_DIR" "$SCRIPT_DIR" 2>/dev/null || true
        mkdir -p "$BIN_DIR" "$SCRIPT_DIR"

        vps_download_komari
        vps_download_caddy
        vps_download_cloudflared
        vps_download_xray
        vps_copy_scripts

        if [ -n "$backup_conf" ] && [ -d "$backup_conf" ]; then
            cp -r "$backup_conf"/* "$CONF_DIR/" 2>/dev/null || true
            rm -rf "$backup_conf"
            ok "Configuration restored."
        fi
        if [ -n "$backup_data" ] && [ -d "$backup_data" ]; then
            cp -r "$backup_data"/* "$DATA_DIR/" 2>/dev/null || true
            rm -rf "$backup_data"
            ok "Data restored."
        fi

        vps_create_komari_cli

        if [ -x "${SCRIPT_DIR}/setup-config.sh" ]; then
            bash "${SCRIPT_DIR}/setup-config.sh" 2>/dev/null || true
        fi

        chown -R komari:komari "$WORK_DIR" 2>/dev/null || true
        systemctl daemon-reload
        systemctl start komari caddy cloudflared 2>/dev/null || true
        if [ -f "${CONF_DIR}/xray.json" ]; then
            systemctl start xray 2>/dev/null || true
        fi
        ok "Re-install complete. Services restarted."
    else
        error "No existing installation found. Nothing to re-install."
        return 1
    fi
}

# ==============================================================================
#  MAIN MENU
# ==============================================================================
main_menu() {
    clear 2>/dev/null || true

    cyan "+--------------------------------------------------+"
    cyan "|          Komari Dashboard Installer             |"
    cyan "+--------------------------------------------------+"
    echo ""

    if detect_installed; then
        info "Komari is already installed."
        echo ""
        echo "  [1] Re-install (keep configuration)"
        echo "  [2] Uninstall"
        echo "  [3] Exit"
        echo ""
        read -r -p "$(echo -e "${YELLOW}${BOLD}Please select an option [1-3]: ${NC}")" choice
        case "$choice" in
            1) reinstall_keep_config ;;
            2) uninstall_cleanup ;;
            3) info "Exiting."; exit 0 ;;
            *) hint "Invalid option. Exiting."; exit 1 ;;
        esac
    else
        info "Komari is not installed."
        echo ""
        echo "  [1] Docker install"
        echo "  [2] Native VPS install"
        echo "  [3] Exit"
        echo ""
        read -r -p "$(echo -e "${YELLOW}${BOLD}Please select an option [1-3]: ${NC}")" choice
        case "$choice" in
            1) docker_install ;;
            2) vps_install ;;
            3) info "Exiting."; exit 0 ;;
            *) hint "Invalid option. Exiting."; exit 1 ;;
        esac
    fi
}

# ---- Entry point -------------------------------------------------------------
main_menu
