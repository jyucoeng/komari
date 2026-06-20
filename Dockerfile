FROM ghcr.io/komari-monitor/komari:latest

ARG KOMARI_SOURCE_REPOSITORY="hynize/komari"
ARG KOMARI_SOURCE_BRANCH="main"
ENV KOMARI_SOURCE_REPOSITORY="$KOMARI_SOURCE_REPOSITORY" \
    KOMARI_SOURCE_BRANCH="$KOMARI_SOURCE_BRANCH"

RUN apk add --no-cache bash curl wget git sqlite jq tar dcron supervisor

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

CMD ["/app/komari", "server"]
