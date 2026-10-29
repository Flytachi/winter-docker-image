#!/bin/sh
# Builds the image here, on this machine, and says what is in it. Pushes nothing.
#
#   ./build.sh               every build listed in versions.json
#   ./build.sh 8.5 6.4.0     one build — listed or not, to try a version before adding it
#
# Each image gets the tags the publish workflow would give it, so ./test.sh finds it.

set -eu
cd "$(dirname "$0")"

IMAGE=flytachi/winter

# versions.json, one build per line → "php swoole major(yes|no) latest(yes|no)"
versions() {
    awk -F'"' '/"php"/ {
        php = ""; swoole = ""
        for (i = 1; i <= NF; i++) {
            if ($i == "php") php = $(i + 2)
            if ($i == "swoole") swoole = $(i + 2)
        }
        print php, swoole, ($0 ~ /"major"[ ]*:[ ]*true/ ? "yes" : "no"), ($0 ~ /"latest"[ ]*:[ ]*true/ ? "yes" : "no")
    }' versions.json
}

# Two lines claiming one tag would both push it, and whichever build finished last would
# win: `major` once per PHP version, `latest` once in the file. The workflow checks the same.
check_versions() {
    dup="$(versions | awk '$3 == "yes" { n[$1]++ } END { for (p in n) if (n[p] > 1) print p }')"
    if [ -n "$dup" ]; then
        echo "versions.json: more than one \"major\": true for PHP $dup — one line per PHP version" >&2
        exit 1
    fi
    if [ "$(versions | awk '$4 == "yes"' | wc -l)" -gt 1 ]; then
        echo "versions.json: more than one \"latest\": true — one line in the file" >&2
        exit 1
    fi
}

# Sizes in MB as `docker image ls` prints them (10^6 bytes), so the numbers agree.
mb() { awk -v b="$1" 'BEGIN { printf (b < 10000000 ? "%.1f MB" : "%.0f MB"), b / 1000000 }'; }

build() {
    php="$1"; swoole="$2"; major="$3"; latest="$4"
    minor="$(echo "$swoole" | cut -d. -f1,2)"
    base="phpswoole/swoole:$swoole-php$php-alpine"
    tag="$IMAGE:$php-swoole$minor"

    set -- -t "$tag"
    [ "$major" = yes ] && set -- "$@" -t "$IMAGE:$php"
    [ "$latest" = yes ] && set -- "$@" -t "$IMAGE:latest"

    echo "== building $tag  (from $base)"
    start=$(date +%s)
    docker build --build-arg PHP_VERSION="$php" --build-arg SWOOLE_VERSION="$swoole" "$@" .
    took=$(( $(date +%s) - start ))

    real_php="$(docker run --rm "$tag" php -r 'echo PHP_VERSION;')"
    real_swoole="$(docker run --rm "$tag" php -r 'echo SWOOLE_VERSION;')"
    disk="$(docker image inspect "$tag" --format '{{.Size}}')"
    base_disk="$(docker image inspect "$base" --format '{{.Size}}' 2>/dev/null || echo 0)"
    # What `docker pull` downloads: `docker image ls` shows it as CONTENT SIZE with the
    # containerd image store; otherwise it is measured by compressing the image.
    pull="$(docker image ls "$tag" | awk 'NR == 1 { c = index($0, "CONTENT SIZE") } NR == 2 && c { print substr($0, c); exit }' | awk '{ print $1 }' | sed 's/\([0-9]\)\([kMG]B\)$/\1 \2/')"
    [ -n "$pull" ] || pull="$(mb "$(docker save "$tag" | gzip -c | wc -c | tr -d ' ')") (estimated)"

    echo
    echo "  PHP     $real_php"
    echo "  Swoole  $real_swoole"
    case "$real_swoole" in
        *[a-zA-Z]*) echo "  !       Swoole $real_swoole is not a release — do not publish it" ;;
    esac
    echo "  disk    $(mb "$disk")    once pulled or built"
    echo "  pull    $pull    downloaded by docker pull (compressed)"
    [ "$base_disk" -gt 0 ] && echo "  ours    $(mb $((disk - base_disk)))    on top of $base ($(mb "$base_disk"))"
    echo "  built   ${took}s"
    echo "  tags    $tag"
    [ "$major" = yes ] && echo "          $IMAGE:$php    (major: the build for PHP $php)"
    [ "$latest" = yes ] && echo "          $IMAGE:latest    (latest: the image's default)"
    echo "          + $tag-$(date -u +%Y%m%d) when published"
    echo
}

check_versions

if [ "$#" -eq 2 ]; then
    flags="$(versions | awk -v p="$1" -v s="$2" '$1 == p && $2 == s { print $3, $4 }')"
    build "$1" "$2" ${flags:-no no}
elif [ "$#" -eq 0 ]; then
    versions | while read -r php swoole major latest; do
        build "$php" "$swoole" "$major" "$latest"
    done
else
    echo "usage: ./build.sh              every build in versions.json" >&2
    echo "       ./build.sh <php> <swoole>  one build, e.g. ./build.sh 8.5 6.4.0" >&2
    exit 2
fi

echo "next: ./test.sh${*:+ $*} --app ../winter-demo"
