# flytachi/winter

The runtime image for [Winter](https://winterframe.net) applications: Swoole and the PHP
extensions the framework and its packages use, a non-root user, and an entrypoint that
starts the application as PID 1.

| In the image | Not in the image |
| --- | --- |
| PHP + Swoole (`phpswoole/swoole:<swoole>-php<version>-alpine`, exact Swoole release) | your code |
| `pcntl`, `bcmath`, `pdo_pgsql` + `pgsql`, `pdo_mysql`, `redis`, opcache | `vendor/` with winter-kernel |
| user `winter` (uid 1000) — everything runs as it, `procps` | `.env` |
| `bash` with tab completion for `./call` | |
| opcache settings for production, `memory_limit = 256M` | |

The entrypoint runs `call application start` — it needs a winter-kernel that has it.

## Tags

| Tag | Moves? |
| --- | --- |
| `8.5` | the build marked latest for PHP 8.5 |
| `8.5-swoole6.2` | the newest build of that PHP and Swoole line |
| `8.5-swoole6.2-20261029` | never — pin this in production |

The builds are listed in `versions.json`. Rebuilt every Monday, so the base image's
security fixes reach them.

## Using it

```dockerfile
FROM composer:2 AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --optimize-autoloader --ignore-platform-reqs

FROM flytachi/winter:8.5
COPY --from=vendor --chown=winter:winter /app/vendor ./vendor
COPY --chown=winter:winter . .

# Starts the application as PID 1: `call application start` (`… dev` with DEV=true),
# after `call di build` in production. Inherited from the image — repeated to be seen.
ENTRYPOINT ["winter-entrypoint"]
```

The `ENTRYPOINT` line changes nothing — the image declares it already — but whoever opens
the project's Dockerfile sees how the container starts, and which line to change to start
it otherwise.

`--chown=winter:winter` matters: the image runs as `winter`, not root, so the application
writes its `.winter/` folder (and logs) only into files that are `winter`'s. A
`RUN chown` would not work here — it needs root.

```bash
docker compose up             # production: opcache on, `call di build` before the start
DEV=true docker compose up    # development: opcache off, hot reload
docker run --rm flytachi/winter:8.5 php -m    # any command runs instead of the application
```

An extension the image lacks is added in the project's Dockerfile, as in
`extensions/*.sh` here.

## How it starts

`winter-entrypoint` decides, in this order:

| Situation | What runs |
| --- | --- |
| a command is given — `docker run … php -m` | that command, instead of the application |
| no `/app/call` | nothing: it says the project is missing and exits 1 |
| `DEV=true` | opcache off, then `call application start dev` — hot reload |
| otherwise | opcache on, `call di build`, then `call application start` |

Everything runs as `winter` (uid 1000), never root — the application, and every console
opened into the container: `docker exec`, Portainer, `kubectl exec`. A process started from
a console is then one the application can stop and whose records it can read. Root, when
really needed: `docker exec -u root …`. The uid is a number so Kubernetes' `runAsNonRoot`
accepts it.

A console with completion: `docker exec -it <container> bash` (in Portainer, `/bin/bash`),
then `./call <Tab>`. The completion asks the project's own `call complete`, so it offers
what the project's winter-kernel has; `call cfg completion -i` is for a developer's machine
and is not needed here.

The application is PID 1: `docker stop` sends it SIGTERM, and it stops every component
cleanly before it exits. A failed `di build` stops the start with one
line in `docker logs` rather than a crash loop.

## Your own PHP settings

PHP reads `/usr/local/etc/php/conf.d/` in alphabetical order, a later file overriding an
earlier one.

```dockerfile
FROM flytachi/winter:8.5
# memory: replace the image's file, or add one that sorts after it
COPY docker/php-memory.ini /usr/local/etc/php/conf.d/20-memory.ini
# opcache: replace the image's file
COPY docker/php-opcache.ini /usr/local/etc/php/conf.d/10-opcache.ini
```

Opcache is switched by the `WINTER_OPCACHE` variable — `1` in the image, `0` with `DEV=true`
— through two lines of the image's file:

```ini
opcache.enable=${WINTER_OPCACHE}
opcache.enable_cli=${WINTER_OPCACHE}
```

Keep them in a file of your own, or development runs with opcache on and code edits stop
showing until a restart.

Only the HTTP workers' memory needs no image change at all: `SERVER_MEMORY_LIMIT=512M` in
the environment sets it per worker.

## Building and checking it locally

```bash
./build.sh                                  # every build in versions.json
./build.sh 8.5 6.4.0                        # one build, listed or not
./test.sh --app ../winter-demo              # check them, plus a real start of a project
```

How to add a Swoole or PHP version, what the scripts print and what to do when a check
fails: [HOWTO.md](HOWTO.md).

## Publishing

`.github/workflows/publish.yml` builds every line of `versions.json`, runs `./test.sh` on it,
and pushes `linux/amd64` + `linux/arm64` to Docker Hub — on a push to `main`, every Monday,
and by hand (Actions → publish → Run workflow).
