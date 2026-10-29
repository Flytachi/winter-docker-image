#!/bin/sh
# Checks images built by ./build.sh — the same check the publish workflow runs before it
# publishes: an image that fails it is not pushed.
#
#   ./test.sh                            every build listed in versions.json
#   ./test.sh 8.5 6.4.0                  one build
#   ./test.sh --app ../winter-demo       ...plus a real start of a Winter project
#   ./test.sh 8.5 6.4.0 --app ../winter-demo
#
# --app: the project (with its vendor/) is copied to a temporary directory, started in the
# image on port 18080 (SMOKE_PORT changes it), asked over HTTP, and stopped. The original
# is not touched.

set -u
cd "$(dirname "$0")"

IMAGE=flytachi/winter
PORT="${SMOKE_PORT:-18080}"
APP=""
ARGS=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --app) APP="${2:?--app needs a directory}"; shift 2 ;;
        *) ARGS="$ARGS $1"; shift ;;
    esac
done
set -- $ARGS

versions() {
    awk -F'"' '/"php"/ {
        php = ""; swoole = ""
        for (i = 1; i <= NF; i++) {
            if ($i == "php") php = $(i + 2)
            if ($i == "swoole") swoole = $(i + 2)
        }
        print php, swoole
    }' versions.json
}

FAILED_IMAGES=""

check() {
    php="$1"; swoole="$2"
    tag="$IMAGE:$php-swoole$(echo "$swoole" | cut -d. -f1,2)"
    failed=0
    pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
    fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; failed=1; }

    echo "== $tag"
    if ! docker image inspect "$tag" >/dev/null 2>&1; then
        fail "not built — run ./build.sh $php $swoole first"
        FAILED_IMAGES="$FAILED_IMAGES $tag"
        return
    fi

    echo "-- extensions"
    modules="$(docker run --rm "$tag" php -m)"
    for ext in swoole pcntl posix bcmath pdo_pgsql pgsql pdo_mysql redis "Zend OPcache"; do
        if printf '%s\n' "$modules" | grep -qix "$ext"; then pass "$ext"; else fail "$ext missing"; fi
    done

    echo "-- runtime"
    real_php="$(docker run --rm "$tag" php -r 'echo PHP_VERSION;')"
    real_swoole="$(docker run --rm "$tag" php -r 'echo SWOOLE_VERSION;')"
    case "$real_php" in "$php".*) pass "PHP $real_php" ;; *) fail "PHP $real_php, expected $php" ;; esac
    if [ "$real_swoole" = "$swoole" ]; then pass "Swoole $real_swoole"; else fail "Swoole $real_swoole, expected $swoole"; fi
    # A release candidate is not published: the floating base tags pick them up.
    if echo "$real_swoole" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then pass "Swoole is a release"; else fail "Swoole $real_swoole is not a release"; fi
    # Everything runs as winter — consoles opened into the container too: a process a
    # root console started could be neither stopped by the application nor read by it.
    who="$(docker run --rm "$tag" id -un):$(docker run --rm "$tag" id -u)"
    if [ "$who" = "winter:1000" ]; then pass "runs as winter (uid 1000)"; else fail "runs as $who, expected winter:1000"; fi
    if docker run --rm "$tag" php -r 'exit(ini_get("opcache.enable_cli") ? 0 : 1);'; then pass "opcache on"; else fail "opcache is off"; fi
    if docker run --rm -e WINTER_OPCACHE=0 "$tag" php -r 'exit(ini_get("opcache.enable_cli") ? 1 : 0);'; then pass "opcache off with WINTER_OPCACHE=0"; else fail "WINTER_OPCACHE=0 left opcache on"; fi
    if docker run --rm "$tag" php -r 'exit(ini_get("memory_limit") === "256M" ? 0 : 1);'; then pass "memory_limit 256M"; else fail "memory_limit is not 256M"; fi
    if docker run --rm "$tag" 2>&1 | grep -q "no /app/call"; then pass "without a project it says so"; else fail "entrypoint did not explain the missing project"; fi
    if docker run --rm "$tag" bash -c 'exit 0' 2>/dev/null; then pass "bash"; else fail "bash missing"; fi
    if docker run --rm "$tag" bash -ic 'complete -p call' 2>/dev/null | grep -q _php_winter_call; then
        pass "bash completes ./call"
    else
        fail "no completion for call in an interactive bash (/etc/bash/winter.sh)"
    fi

    if [ -n "$APP" ]; then
        echo "-- application ($APP)"
        work="$(mktemp -d)"
        name="winter-test-$$"
        cp -R "$APP"/. "$work"/
        rm -rf "$work/.winter" "$work/logs"
        docker run -d --name "$name" -p "$PORT:8000" -v "$work":/app "$tag" >/dev/null

        # A project with SERVER_TLS_* in its .env speaks only HTTPS: once a plain request
        # gets no answer, HTTPS is asked as well (self-signed is fine here).
        code=000
        scheme=http
        for _ in $(seq 1 60); do
            for scheme in http https; do
                code="$(curl -sk -o /dev/null -w '%{http_code}' "$scheme://127.0.0.1:$PORT/" || true)"
                [ "$code" != "000" ] && break 2
            done
            sleep 0.5
        done
        if [ "$code" = "000" ]; then fail "HTTP(S) did not answer on :$PORT"; else pass "$scheme answers on :$PORT ($code)"; fi
        if docker exec "$name" sh -c 'tr "\0" " " < /proc/1/cmdline' | grep -q "application start"; then
            pass "PID 1 is the application"
        else
            fail "PID 1 is not the application"
        fi
        pid1_user="$(docker exec "$name" ps -o user= -p 1 | tr -d ' ')"
        if [ "$pid1_user" = "winter" ]; then pass "the application runs as winter"; else fail "the application runs as $pid1_user"; fi
        if [ "$(docker exec "$name" id -un)" = "winter" ]; then pass "a console opened into it is winter"; else fail "docker exec is not winter"; fi
        # What <TAB> after `./call ap` would offer in a console opened into the container.
        # shellcheck disable=SC2016
        offered="$(docker exec "$name" bash -ic 'cd /app; COMP_LINE="./call ap"; COMP_POINT=${#COMP_LINE}
            COMP_WORDS=(./call ap); COMP_CWORD=1; _php_winter_call; echo "${COMPREPLY[*]}"' 2>/dev/null)"
        case " $offered " in
            *" app "*) pass "./call <TAB> suggests the project's commands" ;;
            *) fail "./call ap<TAB> offered: '$offered'" ;;
        esac
        if docker exec "$name" sh -c 'touch /app/.winter-write-test && rm /app/.winter-write-test'; then
            pass "winter can write in /app"
        else
            fail "winter cannot write in /app — the project's files are not winter's (COPY --chown=winter:winter)"
        fi
        start=$(date +%s)
        docker stop -t 30 "$name" >/dev/null
        status="$(docker inspect -f '{{.State.ExitCode}}' "$name")"
        if [ "$status" = "0" ]; then pass "docker stop: exit 0 in $(( $(date +%s) - start ))s"; else fail "docker stop: exit $status"; fi
        if [ "$failed" -ne 0 ]; then
            echo "-- container log"
            docker logs "$name" 2>&1 | tail -30
        fi
        docker rm "$name" >/dev/null
        rm -rf "$work"
    fi

    [ "$failed" -ne 0 ] && FAILED_IMAGES="$FAILED_IMAGES $tag"
    echo
}

if [ "$#" -eq 2 ]; then
    check "$1" "$2"
elif [ "$#" -eq 0 ]; then
    for line in $(versions | tr ' ' ':'); do
        check "${line%%:*}" "${line#*:}"
    done
else
    echo "usage: ./test.sh [<php> <swoole>] [--app <project-dir>]" >&2
    exit 2
fi

if [ -n "$FAILED_IMAGES" ]; then
    echo "FAILED:$FAILED_IMAGES"
    exit 1
fi
echo "OK"
