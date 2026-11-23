# Как с этим работать

```
versions.json   ← ЧТО собирать. Единственное, что ты обычно правишь
Dockerfile      ← КАК собирать. Трогаешь, только если меняешь сам образ
build.sh        ← собрать у себя
test.sh         ← проверить у себя
shell/winter.sh ← автодополнение ./call в bash — копия completion_bash из winter-kernel
```

Всё запускается из папки репозитория:

```bash
cd ~/Documents/Workspace/winter-docker-image
```

---

## versions.json — что собирать

```json
[
  { "php": "8.5", "swoole": "6.2.6", "major": true, "latest": true },
  { "php": "8.5", "swoole": "6.2.3" },
  { "php": "8.4", "swoole": "6.2.3", "major": true }
]
```

**Добавить версию = дописать строку и сделать `git push` в `main`.** Всё. Одна строка —
один образ. **Каждую сборку пиши на отдельной строке** (скрипты читают
файл построчно).

| Поле | Что значит |
| --- | --- |
| `php` | версия PHP: `8.5`, `8.4` |
| `swoole` | точная версия Swoole: `6.2.3`. Не `6.2`. RC Swoole (`6.3.0-RC1`) — только в строке с `"rc": true` |
| `major` | `true` — основная сборка своей версии PHP: она ещё и под коротким тегом `8.5`. **Одна строка на версию PHP**: у 8.5 и у 8.4 — по своей |
| `latest` | `true` — эта сборка ещё и под тегом `latest` (`docker pull flytachi/winter` без тега). **Одна строка на весь файл** — обычно основная сборка самой новой PHP |
| `rc` | `true` — тестовая сборка: публикуется только под `-rc` тегами, стабильные не трогает. **Одна на версию PHP**, без `major` и `latest` |

`build.sh` и CI откажут до сборки, если две строки претендуют на один тег: одна и та же
версия дважды, два `major` для одной PHP, два `latest`, два `rc` для одной PHP, `rc`
вместе с `major`/`latest`. Проверить файл без сборки: `./build.sh --check`.

Какие теги получит каждая строка файла выше (посмотреть самому:
`./build.sh --tags 8.5 6.2.6`):

| Строка | Теги |
| --- | --- |
| 8.5 / 6.2.6 `major` `latest` | `8.5-swoole6.2.6`, `8.5-swoole6.2`, `8.5-swoole6.2-20261123`, `8.5`, `latest` |
| 8.5 / 6.2.3 | `8.5-swoole6.2.3` |
| 8.4 / 6.2.3 `major` | `8.4-swoole6.2.3`, `8.4-swoole6.2`, `8.4-swoole6.2-20261123`, `8.4` |

- `8.5-swoole6.2.6` — точная версия: есть у **каждой** строки.
- `8.5-swoole6.2` — самая новая 6.2.x из файла для PHP 8.5. Его же датированная копия
  (`…-20261123`) не меняется никогда — на неё закрепляются в продакшене.
- `8.5` / `latest` — только с `major` / `latest`.

Строка `{ "php": "8.5", "swoole": "6.2.6", "rc": true }` получает только:

| Тег | Что это |
| --- | --- |
| `flytachi/winter:8.5-swoole6.2.6-rc` | эта тестовая сборка |
| `flytachi/winter:8.5-rc` | rc для PHP 8.5 — что сейчас пробуется |

Ни `8.5`, ни `latest`, ни `8.5-swoole6.2`, ни датированного тега.

Версии Swoole, какие бывают: https://hub.docker.com/r/phpswoole/swoole/tags — нужен
тег вида `6.4.0-php8.5-alpine`.

---

## Тестовая сборка (rc)

Новую версию можно выкатить сначала как rc — на Docker Hub, но мимо стабильных тегов:

1. Строка с `"rc": true` (стабильная остаётся как есть):
   ```json
   [
     { "php": "8.5", "swoole": "6.2.3", "major": true, "latest": true },
     { "php": "8.5", "swoole": "6.2.6", "rc": true }
   ]
   ```
2. PR в `main` — CI соберёт и проверит все строки, ничего не публикуя. Смёрджил —
   опубликует, rc под `8.5-swoole6.2.6-rc` и `8.5-rc`.
3. Пробуешь в проекте: `FROM flytachi/winter:8.5-rc`.
4. Всё хорошо — выпустить: убрать `"rc": true` (и, если она теперь основная, перенести
   на неё `major`/`latest`). Старую строку можно оставить — у неё останется свой тег
   `8.5-swoole6.2.3`.

Опубликованные `-rc` теги остаются на Docker Hub, пока их не удалить там руками.

## Добавить Swoole 6.4

1. Попробовать, ничего не меняя в файлах:
   ```bash
   ./build.sh 8.5 6.4.0
   ./test.sh 8.5 6.4.0 --app ../winter-demo
   ```
2. Всё зелёное — дописать строку в `versions.json`:
   ```json
   [
     { "php": "8.5", "swoole": "6.2.6", "major": true, "latest": true },
     { "php": "8.5", "swoole": "6.4.0" }
   ]
   ```
3. `git push` в `main` — CI соберёт и опубликует обе. Хочешь сначала потестить на
   Docker Hub, не трогая стабильные теги, — добавь строке `"rc": true` (см. выше).

**Сделать 6.4 основной** — перенести `"major": true` (и `"latest": true`, если он там) на её строку.
**Убрать старую** — удалить её строку (уже опубликованные теги на Docker Hub останутся).

## Добавить версию PHP (например, 8.6)

То же самое: `./build.sh 8.6 6.2.3`, `./test.sh 8.6 6.2.3 --app ../winter-demo`, затем
строка `{ "php": "8.6", "swoole": "6.2.3", "major": true }` — без `major` тега `8.6` не
будет. Стала самой новой — перенести на неё `"latest": true`.

## Обновить Swoole (6.2.3 → 6.2.6)

`./build.sh 8.5 6.2.6`, `./test.sh 8.5 6.2.6 --app ../winter-demo`, затем либо поменять
`"swoole"` в строке, либо дописать новую строку рядом со старой — тогда опубликуются обе,
а `8.5-swoole6.2` перейдёт на 6.2.6.

---

## build.sh — собрать у себя

```bash
./build.sh               # все строки versions.json
./build.sh 8.5 6.4.0     # одну сборку — есть она в versions.json или нет
```

Ничего не публикует. Для каждой сборки выведет:

```
== building flytachi/winter:8.5-swoole6.2.3  (from phpswoole/swoole:6.2.3-php8.5-alpine)

  PHP     8.5.12
  Swoole  6.2.3
  disk    204 MB    once pulled or built
  pull    54.2 MB    downloaded by docker pull (compressed)
  ours    3.8 MB    on top of phpswoole/swoole:6.2.3-php8.5-alpine (200 MB)
  built   6s
  tags    flytachi/winter:8.5-swoole6.2.3
          flytachi/winter:8.5-swoole6.2
          flytachi/winter:8.5
          flytachi/winter:latest
          + flytachi/winter:8.5-swoole6.2-20261029 when published
```

- `disk` — сколько займёт на диске; `pull` — сколько скачивать при `docker pull`;
  `ours` — сколько добавляем мы поверх `phpswoole/swoole`.
- Если Swoole не релиз — строка `! … not a release — do not publish it`.
- Первая сборка — пара минут (компилируются расширения), повторные — секунды.

## test.sh — проверить у себя

```bash
./test.sh                                   # все строки versions.json
./test.sh 8.5 6.4.0                         # одну сборку
./test.sh --app ../winter-demo              # + настоящий запуск проекта
SMOKE_PORT=19000 ./test.sh --app ../winter-demo   # если порт 18080 занят
```

Сначала образ нужно собрать (`./build.sh`). Проверяет:

| Блок | Что |
| --- | --- |
| extensions | `swoole`, `pcntl`, `posix`, `bcmath`, `pdo_pgsql`, `pgsql`, `pdo_mysql`, `redis`, opcache |
| runtime | версии PHP и Swoole совпадают с `versions.json`, Swoole — релиз, всё работает от `winter` (uid 1000), opcache включён и выключается `WINTER_OPCACHE=0`, `memory_limit 256M`, есть `bash` и автодополнение `./call` |
| application (`--app`) | проект стартует, отвечает по HTTP или HTTPS (если в его `.env` есть `SERVER_TLS_*`), PID 1 — приложение и работает от `winter`, консоль в контейнере тоже `winter`, `./call ap<Tab>` подсказывает команды проекта, `winter` может писать в `/app`, `docker stop` завершает с кодом 0 |

В конце `OK`, или `FAILED: <образы>` с кодом выхода 1 — тогда рядом с проверкой `✗` и
лог контейнера. Проект копируется во временную папку: оригинал не меняется. Ему нужен
свой `vendor/`.

---

## Публикация

Делает GitHub, сам `build.sh` ничего не публикует.

**Когда:** каждый `push` в `main`, каждый понедельник (пересборка с обновлениями
безопасности базового образа) и вручную — GitHub → Actions → publish → Run workflow.

**PR в `main`:** тот же workflow собирает и прогоняет `test.sh` на каждой строке, но
ничего не публикует — видно, зелёное ли, до мерджа.

**Что делает:** для каждой строки `versions.json` собирает образ, прогоняет `test.sh`
(упал — эта строка не публикуется), публикует `amd64` + `arm64` с тегами из таблицы выше.

## Если что-то не так

| Симптом | Что смотреть |
| --- | --- |
| `versions.json: …` до сборки | две строки делят тег — см. таблицу полей; `./build.sh --check` |
| `build.sh`: `not found` на `FROM` | такой версии `phpswoole/swoole` нет — проверь теги на Docker Hub |
| `test.sh`: `not built` | сначала `./build.sh` с теми же версиями |
| `test.sh`: `✗ redis missing` и т.п. | скрипт в `extensions/` не отработал — смотри вывод `build.sh` |
| `test.sh`: `✗ HTTP(S) did not answer` | лог контейнера в конце; часто нет `vendor/` в проекте или занят порт (`SMOKE_PORT`) |
| `test.sh`: `✗ docker stop: exit 137` | приложение не уложилось в 30 секунд и было убито |
| заглянуть внутрь | `docker run --rm -it flytachi/winter:8.5 bash` |
| `test.sh`: `✗ no completion for call` | нет `/etc/bash/winter.sh` в образе — смотри `COPY shell/` в `Dockerfile` |
| удалить локальный образ | `docker rmi flytachi/winter:8.5-swoole6.2.3` |
