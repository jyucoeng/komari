FROM ghcr.io/komari-monitor/komari:latest

ARG KOMARI_SOURCE_REPOSITORY="hynize/komari"
ARG KOMARI_SOURCE_BRANCH="main"
ARG CADDY_VERSION="2.9.1"
ARG TARGETARCH
ARG TARGETVARIANT
ENV KOMARI_SOURCE_REPOSITORY="$KOMARI_SOURCE_REPOSITORY" \
    KOMARI_SOURCE_BRANCH="$KOMARI_SOURCE_BRANCH"

RUN apk add --no-cache bash curl wget git sqlite jq tar supervisor coreutils

RUN set -eux; \
    case "${TARGETARCH:-$(apk --print-arch)}${TARGETVARIANT:-}" in \
        amd64|x86_64) arch="amd64" ;; \
        arm64|aarch64) arch="arm64" ;; \
        armv7|arm/v7|armhf|armv7l) arch="arm" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH:-$(apk --print-arch)}${TARGETVARIANT:-}" >&2; exit 1 ;; \
    esac; \
    mkdir -p /usr/local/bin /app/bin; \
    wget -q "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${arch}.tar.gz" -O /tmp/caddy.tar.gz; \
    tar xzf /tmp/caddy.tar.gz -C /usr/local/bin caddy; \
    chmod +x /usr/local/bin/caddy; \
    wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" -O /app/bin/cloudflared; \
    chmod +x /app/bin/cloudflared; \
    rm -f /tmp/caddy.tar.gz /usr/local/bin/cloudflared /usr/bin/cloudflared

COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

COPY komari_bak.sh /app/komari_bak.sh
RUN chmod +x /app/komari_bak.sh

COPY restore.sh /app/restore.sh
RUN chmod +x /app/restore.sh

COPY renew.sh /app/renew.sh
RUN chmod +x /app/renew.sh

COPY sub_link.sh /app/sub_link.sh
RUN chmod +x /app/sub_link.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
