#!/bin/sh
# Builds the image here, on this machine, and says what is in it. Pushes nothing.
#
#   ./build.sh               every build listed in versions.json
#   ./build.sh 8.5 6.4.0     one build — listed or not, to try a version before adding it
#   ./build.sh --check       only check versions.json (the publish workflow runs this)
#   ./build.sh --tags 8.5 6.2.6   the tags the publish workflow pushes for that line
#
# Each image gets the tags the publish workflow would give it (all but the dated one), so
# ./test.sh finds it.

set -eu
cd "$(dirname "$0")"

IMAGE=flytachi/winter

# versions.json, one build per line →
#   "php swoole major latest rc newest" — each yes|no; newest: the newest stable Swoole of
#   its line (8.5 + 6.2.x), the one that gets 8.5-swoole6.2.
versions() {
    awk -F'"' '/"php"/ {
        php = ""; swoole = ""
        for (i = 1; i <= NF; i++) {
            if ($i == "php") php = $(i + 2)
            if ($i == "swoole") swoole = $(i + 2)
        }
        print php, swoole, ($0 ~ /"major"[ ]*:[ ]*true/ ? "yes" : "no"), ($0 ~ /"latest"[ ]*:[ ]*true/ ? "yes" : "no"), ($0 ~ /"rc"[ ]*:[ ]*true/ ? "yes" : "no")
    }' versions.json | awk '
        { line[NR] = $0; split($2, v, "."); key[NR] = $1 " " v[1] "." v[2]; patch[NR] = v[3] + 0
          if ($5 == "no" && (!(key[NR] in best) || patch[NR] > best[key[NR]])) best[key[NR]] = patch[NR] }
        END { for (i = 1; i <= NR; i++) {
            split(line[i], f, " ")
            print line[i], (f[5] == "no" && patch[i] == best[key[i]] ? "yes" : "no")
        } }'
}

# A Swoole release: 6.2.3. Anything else (6.3.0-RC1) may only be built as an rc.
is_release() { echo "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; }

# The tags of one build, one per line; the first is the one ./test.sh looks for.
#   tags <php> <swoole> <major> <latest> <rc> <newest> [<date>]
# With a date: the publish workflow's list, the dated tag included.
#
#   8.5-swoole6.2.6          every stable build: its exact versions
#   8.5-swoole6.2            the newest stable 6.2.x of PHP 8.5 — moves to 6.2.7 when listed
#   8.5-swoole6.2-<date>     ...and its dated copy: never moves
#   8.5 / latest             "major" / "latest"
#   8.5-swoole6.2.6-rc, 8.5-rc   an rc: nothing else (8.5-swoole6.3.0-rc2 for a Swoole RC)
tags() {
    php="$1"; swoole="$2"; minor="$(echo "$2" | cut -d. -f1,2)"
    if [ "$5" = yes ]; then
        # 6.2.6 → 8.5-swoole6.2.6-rc; 6.3.0-rc2 already says so → 8.5-swoole6.3.0-rc2
        if is_release "$swoole"; then echo "$IMAGE:$php-swoole$swoole-rc"; else echo "$IMAGE:$php-swoole$swoole"; fi
        echo "$IMAGE:$php-rc"
        return
    fi
    echo "$IMAGE:$php-swoole$swoole"
    if [ "$6" = yes ]; then
        echo "$IMAGE:$php-swoole$minor"
        [ -n "${7:-}" ] && echo "$IMAGE:$php-swoole$minor-$7"
    fi
    [ "$3" = yes ] && echo "$IMAGE:$php"
    [ "$4" = yes ] && echo "$IMAGE:latest"
    return 0
}

# The flags of a line as versions() prints them. Not listed (trying a version): no tag
# but its own — a Swoole pre-release only as an rc.
flags_of() {
    f="$(versions | awk -v p="$1" -v s="$2" '$1 == p && $2 == s { print $3, $4, $5, $6 }')"
    if [ -n "$f" ]; then echo "$f"; elif is_release "$2"; then echo "no no no no"; else echo "no no yes no"; fi
}

# Two lines claiming one tag would both push it, and whichever build finished last would
# win. So: a build listed once, `major` once per PHP version, `latest` once in the file,
# one rc per PHP version (8.5-rc). An rc never takes `major` or `latest`: it is not
# published under a stable tag. The workflow runs this.
check_versions() {
    err=0
    bad() { echo "versions.json: $1" >&2; err=1; }

    for p in $(versions | awk '$3 == "yes" { n[$1]++ } END { for (p in n) if (n[p] > 1) print p }'); do
        bad "more than one \"major\": true for PHP $p — one line per PHP version"
    done
    [ "$(versions | awk '$4 == "yes"' | wc -l)" -gt 1 ] && bad "more than one \"latest\": true — one line in the file"
    for l in $(versions | awk '{ k = $1 "/" $2; n[k]++ } END { for (k in n) if (n[k] > 1) print k }'); do
        bad "PHP / Swoole $l is listed more than once"
    done
    for p in $(versions | awk '$5 == "yes" { n[$1]++ } END { for (p in n) if (n[p] > 1) print p }'); do
        bad "more than one \"rc\": true for PHP $p — they would share the tag $p-rc"
    done
    versions | awk '$5 == "yes" && ($3 == "yes" || $4 == "yes") { print $1, $2 }' | while read -r p sw; do
        echo "versions.json: $p / $sw is \"rc\" and also \"major\" or \"latest\" — an rc gets only -rc tags" >&2
        echo x
    done | grep -q x && err=1
    versions | awk '$5 == "no" { print $1, $2 }' | while read -r p sw; do
        is_release "$sw" || { echo "versions.json: $p / $sw: Swoole $sw is not a release — only an \"rc\": true line may use it" >&2; echo x; }
    done | grep -q x && err=1

    [ "$err" -eq 0 ] || exit 1
}

# Sizes in MB as `docker image ls` prints them (10^6 bytes), so the numbers agree.
mb() { awk -v b="$1" 'BEGIN { printf (b < 10000000 ? "%.1f MB" : "%.0f MB"), b / 1000000 }'; }

build() {
    php="$1"; swoole="$2"; rc="$5"; newest="$6"
    base="phpswoole/swoole:$swoole-php$php-alpine"
    all="$(tags "$@")"
    tag="$(echo "$all" | head -1)"

    set --
    for t in $all; do set -- "$@" -t "$t"; done

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
        *[a-zA-Z]*) [ "$rc" = yes ] || echo "  !       Swoole $real_swoole is not a release — do not publish it" ;;
    esac
    echo "  disk    $(mb "$disk")    once pulled or built"
    echo "  pull    $pull    downloaded by docker pull (compressed)"
    [ "$base_disk" -gt 0 ] && echo "  ours    $(mb $((disk - base_disk)))    on top of $base ($(mb "$base_disk"))"
    echo "  built   ${took}s"
    echo "$all" | awk '{ printf (NR == 1 ? "  tags    %s\n" : "          %s\n"), $0 }'
    [ "$newest" = yes ] && echo "          + $IMAGE:$php-swoole$(echo "$swoole" | cut -d. -f1,2)-$(date -u +%Y%m%d) when published"
    echo
}

check_versions

if [ "$#" -eq 1 ] && [ "$1" = --check ]; then
    echo "versions.json: OK"
    exit 0
elif [ "$#" -eq 3 ] && [ "$1" = --tags ]; then
    # shellcheck disable=SC2046
    tags "$2" "$3" $(flags_of "$2" "$3") "$(date -u +%Y%m%d)"
    exit 0
elif [ "$#" -eq 2 ]; then
    # shellcheck disable=SC2046
    build "$1" "$2" $(flags_of "$1" "$2")
elif [ "$#" -eq 0 ]; then
    versions | while read -r php swoole major latest rc newest; do
        build "$php" "$swoole" "$major" "$latest" "$rc" "$newest"
    done
else
    echo "usage: ./build.sh              every build in versions.json" >&2
    echo "       ./build.sh <php> <swoole>  one build, e.g. ./build.sh 8.5 6.4.0" >&2
    echo "       ./build.sh --check         only check versions.json" >&2
    echo "       ./build.sh --tags <php> <swoole>  the tags CI publishes for it" >&2
    exit 2
fi

echo "next: ./test.sh${*:+ $*} --app ../winter-demo"
