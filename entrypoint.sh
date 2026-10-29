#!/bin/sh
# Winter entrypoint. It exec-replaces itself with the application, which becomes PID 1:
# it starts every declared component — the HTTP server among them — watches over them,
# and on SIGTERM (`docker stop`) stops them cleanly before it exits. Logs go to stdout,
# so `docker logs` shows them without any syslog relay.
#
# Runs as the image's user, `winter` — no root needed, so none is used.
#
# Needs winter-kernel with `call application start`.

APP=/app

# A command given to the container runs instead of the application:
#   docker run --rm flytachi/winter:8.5 php -m
if [ "$#" -gt 0 ]; then
    exec "$@"
fi

if [ ! -f "$APP/call" ]; then
    echo "winter-entrypoint: no $APP/call — copy or mount the project into $APP" >&2
    exit 1
fi

if [ "${DEV:-false}" = "true" ]; then
    # Development: opcache off (mounted code always live) + hot reload.
    export WINTER_OPCACHE=0
    exec php "$APP/call" application start dev
fi

# Warm the class-list cache before the server exists: without it the first boot walks
# the whole tree in the master, which every worker is forked from. A failed build is a
# broken application, not a slow one — refusing to start turns a crash loop into one
# clear line in `docker logs`.
if ! php "$APP/call" di build; then
    echo "winter-entrypoint: 'call di build' failed — refusing to start" >&2
    exit 1
fi

exec php "$APP/call" application start
