#!/usr/bin/env bash

#===============================================================
#          Komari Dashboard Subscription Link Generator
#
# 此脚本为 Komari 面板生成 VLESS 和 VMESS 节点订阅链接
# ---------------------------------------------------------------
# 功能:
#   - 生成 VLESS 节点链接
#   - 生成 VMESS 节点链接 (Base64 编码)
#   - 生成完整的订阅链接并保存到文件
#
# 工作流程：
#   1. 客户端 -> CF_IP:443
#   2. Cloudflare 隧道识别 SNI 和 Host 为 ARGO_DOMAIN
#   3. 隧道将流量转发到容器内 Caddy
#   4. Caddy 反代到 Komari 面板、订阅文件或 Xray WS 后端
#
# 环境变量说明：
#   - ARGO_DOMAIN: Cloudflare 隧道配置的域名（必需）
#   - UUID: 订阅 UUID（必需）
#   - CF_IP: Cloudflare 等 CDN 的优选 IP 或域名（默认 ip.sb）
#   - CADDY_PROXY_PORT: Caddy 反向代理的内部端口（用于内部通信）
#===============================================================

info() { echo -e "\033[32m\033[01m$*\033[0m"; }
error() { echo -e "\033[31m\033[01m$*\033[0m"; exit 1; }
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }

fetch_url() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --connect-timeout "${HTTP_CONNECT_TIMEOUT:-2}" --max-time "${HTTP_MAX_TIME:-3}" "$url" 2>/dev/null || true
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- -T "${HTTP_MAX_TIME:-3}" "$url" 2>/dev/null || true
    fi
}

get_country_code() {
    local country_code response url
    country_code="UN"
    for url in "http://ipinfo.io/country" "https://ifconfig.co/country" "https://ipapi.co/country"; do
        response=$(fetch_url "$url" | tr -d '\r\n[:space:]' | tr '[:lower:]' '[:upper:]')
        if printf "%s" "$response" | grep -Eq '^[A-Z]{2}$'; then
            country_code="$response"
            break
        fi
    done
    echo "$country_code"
}

valid_uuid() {
    printf "%s" "$1" | grep -Eiq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

valid_endpoint() {
    printf "%s" "$1" | grep -Eq '^([A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\]|[0-9A-Fa-f:.]+)$'
}

UUID="${UUID:-}"
ARGO_DOMAIN="${ARGO_DOMAIN:-}"
CF_IP="${CF_IP:-ip.sb}"
SUB_NAME="${SUB_NAME:-komari}"
OUTPUT_FILE="${OUTPUT_FILE:-/tmp/list.log}"
CADDY_PROXY_PORT="${CADDY_PROXY_PORT:-8001}"

if [ -z "$UUID" ]; then
    hint "UUID 未设置，跳过生成订阅链接"
    exit 0
fi
if ! valid_uuid "$UUID"; then
    error "UUID 格式不正确，无法生成订阅链接"
fi

if [ -z "$ARGO_DOMAIN" ]; then
    hint "ARGO_DOMAIN 未设置，跳过生成订阅链接"
    exit 0
fi
if ! valid_endpoint "$ARGO_DOMAIN"; then
    error "ARGO_DOMAIN 格式不正确，无法生成订阅链接"
fi

if ! valid_endpoint "$CF_IP"; then
    error "CF_IP 格式不正确，无法生成订阅链接"
fi

COUNTRY_CODE=$(get_country_code)
info "检测到国家代码: $COUNTRY_CODE"

XIEYI='vl'
XIEYI2='vm'

VLESS_URL="vless://${UUID}@${CF_IP}:443?path=%2F${XIEYI}s%3Fed%3D2048&security=tls&encryption=none&host=${ARGO_DOMAIN}&type=ws&sni=${ARGO_DOMAIN}#${COUNTRY_CODE}-${SUB_NAME}-${XIEYI}"

VMESS_JSON="{ \"v\": \"2\", \"ps\": \"${COUNTRY_CODE}-${SUB_NAME}-${XIEYI2}\", \"add\": \"${CF_IP}\", \"port\": \"443\", \"id\": \"${UUID}\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${ARGO_DOMAIN}\", \"path\": \"/vms?ed=2048\", \"tls\": \"tls\", \"sni\": \"${ARGO_DOMAIN}\", \"alpn\": \"\", \"fp\": \"randomized\", \"allowInsecure\": \"false\"}"

if ! command -v base64 >/dev/null 2>&1; then
    error "base64 命令不可用，无法生成订阅链接"
fi

if base64 -w 0 </dev/null >/dev/null 2>&1; then
    VMESS_URL="vmess://$(printf "%s" "$VMESS_JSON" | base64 -w 0)"
    FULL_URL="${VLESS_URL}\n${VMESS_URL}"
    ENCODED_URL=$(printf "%b" "$FULL_URL" | base64 -w 0)
else
    VMESS_URL="vmess://$(printf "%s" "$VMESS_JSON" | base64 | tr -d '\n')"
    FULL_URL="${VLESS_URL}\n${VMESS_URL}"
    ENCODED_URL=$(printf "%b" "$FULL_URL" | base64 | tr -d '\n')
fi

mkdir -p "$(dirname "$OUTPUT_FILE")" 2>/dev/null || true
printf "%s" "$ENCODED_URL" > "$OUTPUT_FILE"

info "订阅链接已生成！"
info "VLESS: $VLESS_URL"
info "VMESS: $VMESS_URL"
hint "完整订阅内容已写入: $OUTPUT_FILE"
