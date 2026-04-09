FROM alpine:3.21

ARG SUPERCRONIC_VERSION="0.2.33"
ARG SUPERCRONIC_SHA256="3d2facbd558e80e74fe25028481765dbc66edd5cce9ed3a01bca32da7da1d1a5"

RUN apk add --no-cache \
    postgresql-client \
    aws-cli \
    curl \
    gzip

# supercronic: a cron daemon built for containers (no root, no syslog)
RUN curl -fsSL \
    "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
    -o /usr/local/bin/supercronic \
    && echo "${SUPERCRONIC_SHA256}  /usr/local/bin/supercronic" | sha256sum -c - \
    && chmod +x /usr/local/bin/supercronic

COPY backup.sh /usr/local/bin/backup.sh
COPY crontab /etc/supercronic/crontab

RUN chmod +x /usr/local/bin/backup.sh

CMD ["supercronic", "/etc/supercronic/crontab"]
