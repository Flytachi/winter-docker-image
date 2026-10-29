# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
# (The versions below have no default on purpose — versions.json is the one place they
# live, and build.sh / the workflow always pass them. The check above would ask for one.)
# =============================================================================
# flytachi/winter — the runtime image for Winter applications.
# -----------------------------------------------------------------------------
# Swoole, the PHP extensions the framework and its packages use, a non-root user
# and the entrypoint that starts the application as PID 1. No application code and
# no winter-kernel: those belong to the project, which builds FROM this image.
# =============================================================================

# The versions come from versions.json, through build.sh or the publish workflow — this
# file only says how to build. An exact Swoole release, never a floating tag:
# `phpswoole/swoole:php8.5-alpine` follows the newest build, release candidates included.
ARG PHP_VERSION
ARG SWOOLE_VERSION
FROM phpswoole/swoole:${SWOOLE_VERSION}-php${PHP_VERSION}-alpine

LABEL org.opencontainers.image.title="winter" \
      org.opencontainers.image.description="Runtime image for Winter applications: Swoole, pcntl, bcmath, pgsql, mysql, redis" \
      org.opencontainers.image.source="https://github.com/Flytachi/winter-docker-image" \
      org.opencontainers.image.licenses="MIT"

WORKDIR /app

# The user everything runs as: the application, and every console opened into the
# container — `docker exec`, Portainer, `kubectl exec`. A process started from a root
# console belonged to root: the application could not stop it, nor read the records it
# wrote. A fixed uid, because Kubernetes' runAsNonRoot checks a number, not a name.
RUN apk add --no-cache procps \
    && rm -rf /var/cache/apk/* \
    && addgroup -g 1000 winter \
    && adduser -D -H -s /sbin/nologin -u 1000 -G winter winter \
    && mkdir -p /app \
    && chown winter:winter /app

# The application supervises its components with pcntl.
RUN docker-php-ext-install -j"$(nproc)" pcntl

# One self-contained script per extension, run in filename order. `|| exit 1` fails the
# build on a broken script: without it the loop goes on and RUN reports the status of
# the last one, so an image could come out green with an extension missing.
COPY extensions/ /tmp/extensions/
RUN for f in /tmp/extensions/*.sh; do \
        [ -e "$f" ] || continue; \
        echo "→ extension: $f"; sh "$f" || exit 1; \
    done \
    && rm -rf /tmp/extensions /var/cache/apk/* /tmp/pear

# Opcache, switched by WINTER_OPCACHE: on by default, off with DEV=true (the entrypoint
# sets it) — no rebuild to switch, and no root needed to do it.
COPY php/php-opcache.ini /usr/local/etc/php/conf.d/10-opcache.ini
ENV WINTER_OPCACHE=1

# Memory ceiling per worker, active in both modes. PHP's 128M default is invisible
# until a worker dies of it; the box must hold worker_num × this value.
COPY php/php-memory.ini /usr/local/etc/php/conf.d/20-memory.ini

COPY entrypoint.sh /usr/local/bin/winter-entrypoint
RUN chmod +x /usr/local/bin/winter-entrypoint

USER 1000:1000

# No EXPOSE: the port is declared in the application's code (#[EnableHttp(port:)]) and
# published by the project's compose file.
ENTRYPOINT ["winter-entrypoint"]
