ARG KOMARI_VERSION=latest

FROM debian:bookworm-slim AS base

ARG KOMARI_VERSION
ARG TARGETARCH
ARG TARGETVARIANT

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash curl wget git sqlite3 jq tar supervisor coreutils unzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    \
    # Map buildx TARGETARCH to komari binary suffix
    case "${TARGETARCH:-$(uname -m)}${TARGETVARIANT:-}" in \
        amd64|x86_64|"") arch="amd64" ;; \
        arm64|aarch64) arch="arm64" ;; \
        arm*|armv7*|armhf) arch="arm" ;; \
        386|i386|i686|x86) arch="386" ;; \
        riscv64) arch="riscv64" ;; \
        loong64) arch="loong64" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH:-$(uname -m)}${TARGETVARIANT:-}" >&2; exit 1 ;; \
    esac; \
    \
    mkdir -p /usr/local/bin /app/bin; \
    \
    # Download komari binary from upstream GitHub releases
    KOMARI_URL="https://github.com/komari-monitor/komari/releases/download/${KOMARI_VERSION}/komari-linux-${arch}"; \
    echo "Downloading komari from ${KOMARI_URL}"; \
    wget -q "${KOMARI_URL}" -O /app/komari; \
    chmod +x /app/komari; \
    \
    # Pre-download caddy and cloudflared (entrypoint.sh falls back at runtime)
    wget -q "https://github.com/caddyserver/caddy/releases/download/v2.9.1/caddy_2.9.1_linux_${arch}.tar.gz" -O /tmp/caddy.tar.gz || true; \
    tar xzf /tmp/caddy.tar.gz -C /usr/local/bin caddy 2>/dev/null || true; \
    chmod +x /usr/local/bin/caddy 2>/dev/null || true; \
    \
    wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" -O /app/bin/cloudflared || true; \
    chmod +x /app/bin/cloudflared 2>/dev/null || true; \
    rm -f /tmp/caddy.tar.gz /usr/local/bin/cloudflared /usr/bin/cloudflared

COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

COPY repo.conf /app/repo.conf

COPY backup.sh /app/backup.sh
RUN chmod +x /app/backup.sh

COPY restore.sh /app/restore.sh
RUN chmod +x /app/restore.sh

COPY renew.sh /app/renew.sh
RUN chmod +x /app/renew.sh

COPY sub_link.sh /app/sub_link.sh
RUN chmod +x /app/sub_link.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
