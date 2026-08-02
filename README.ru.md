# deploy-kit

[English](README.md) · Русский

[![CI](https://github.com/tr0llex/deploy-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/tr0llex/deploy-kit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![nginx 1.24](https://img.shields.io/badge/nginx-1.24-009639)

Единый релизный пайплайн всех проектов samoy.love: статические сайты,
Go-сервисы и десктопный установщик едут на прод по одному и тому же конвейеру.

## Зачем

Раньше каждый проект изобретал деплой заново. Откат был только у Snakes —
остальные откатывались повторной выкаткой. Лаунчер прогонял `go test` в
workflow, никак не связанном с деплоем, который шёл следом. Один общий файл
nginx описывал два сайта разом, и выкатка одного роняла соседний. Несколько
репозиториев катят на **один** хост, но мьютекс у каждого был свой — два
пайплайна могли одновременно перезагружать nginx. Имена секретов различались
от репозитория к репозиторию.

Здесь всё это сведено к одному контракту: одно описание цели, один
`release.sh` на сервере, одна очередь на хост. В репозитории проекта остаются
вызов workflow на двадцать строк и файл `.env`.

## Конвейер

Один и тот же для всех архетипов, различается только шаг сборки.

```
1. Гейты         линт, типы, тесты (go test -race для Go), сборка
2. Артефакт      версия из тега либо release-<дата>-<коммит>, упаковка в tar.gz
3. Предусловия   на хосте: место на диске, nginx -t, состояние юнитов, владелец
3a. Шлюз         версия задана и строго новее той, что на проде
4. Загрузка      в releases/<версия>, права и владелец
5. Бэкап         снимок конфига nginx до замены
6. Переключение  атомарная смена симлинка current
7. Применение    nginx -t && reload либо systemctl restart
8. Проверка      /healthz, /version.json = ожидаемая версия, соседние сайты
9. Откат         любой провал после шага 6 возвращает current на прежний релиз
10. Уведомление  сообщение в Telegram с результатом
```

Шаг 8 сверяет **версию**, а не только код ответа: именно это ловит «деплой
прошёл зелёным, а файлы остались старые». Шаг 3a отказывает версиям-заглушкам
(`dev`, `unknown`, пусто) и всему, что не новее прода, — выход с кодом 3 при
нетронутом симлинке.

## Как устроено

**Прод собирается один раз.** Артефакт собирается на раннере и едет как есть.
На сервере ничего не компилируется, поэтому работает ровно то, что проверили.

**Выкатка атомарна.** Файлы кладутся в новый каталог `releases/<версия>`, и
только потом переключается `current` — через временный симлинк и `mv -T`.
Между `rm` и `ln` было бы окно, когда пути не существует; так его нет, и
половинчатое состояние наблюдать нечем.

**Каждая выкатка проверяет себя, а провал откатывается сам.** После
переключения пайплайн ждёт `/healthz`, сверяет `/version.json` с выкаченной
версией и проверяет соседние домены. Любой провал возвращает `current` на
предыдущий релиз и перезапускает юнит: раз каждый мерж в `main` уезжает на
прод, выкатка без человека обязана уметь отменить себя.

**Хост один — очередь одна.** Мьютекс — `flock` на
`/var/lock/deploy-kit.lock`, на весь хост, а не на репозиторий. Concurrency в
GitHub Actions разводит запуски только внутри одного репозитория, а проекты,
делящие этот сервер, лежат в разных.

**Чужое не трогаем.** Проект пишет ровно один файл в `sites-available` (или
`conf.d`), `nginx-apply.sh` снимает состояние всей конфигурации **до** правки,
чтобы чужую поломку не приняли за нашу, и откатывает релиз из бэкапа, если
после установки `nginx -t` не проходит.

**Скрипты на сервере — тоже релиз.** `install-server` сверяет контрольные
суммы репозитория и `/opt/deploy-kit`, отказывается выкладывать то, что
расходится с `origin/main`, заливает файлы во временный каталог и проверяет их
там через `bash -n`: сломанный `release.sh`, установленный на место, означал
бы, что выкатываться и откатываться уже нечем.

## Стек

Bash (строгий режим, чистый shellcheck), переиспользуемые workflow GitHub
Actions, systemd, nginx 1.24, `flock`, `tar` и `scp` поверх SSH. Сторонних
action для ssh и передачи файлов нет: двадцать строк своего кода вместо
внешней зависимости в цепочке поставки.

## Быстрый старт

`dk` — одна команда на всё хозяйство. Цели обнаруживаются сами: каждый
`.deploy-kit/*.env` в соседних репозиториях становится целью, регистрировать
ничего не нужно.

```bash
echo 'export PATH="$PATH:/путь/к/deploy-kit/bin"' >> ~/.bashrc
mkdir -p ~/.config/deploy-kit && cp dk.conf.example ~/.config/deploy-kit/dk.conf
# в dk.conf — хост, пользователь и путь к ключу; значения с пробелами в кавычках
```

```bash
dk                          # что сейчас на проде: коды ответов и версии
dk list                     # все цели
dk deploy                   # все цели проекта, в котором стоите
dk deploy snakes metro      # выборочно
dk deploy --all --dry-run   # показать план, ничего не трогая
dk rollback snakes --list   # какие релизы лежат на сервере
dk rollback snakes          # откатить на предыдущий
dk help
```

Локальная выкатка идёт **тем же путём, что и CI**: одно описание цели и один
`release.sh` на сервере. Расхождения «локально работает, в CI нет» исключены
по построению.

Обновление серверной части:

```bash
install-server              # показать расхождения репозитория и /opt/deploy-kit
install-server --apply      # выложить (только то, что влито в main)
```

## Структура

| Путь | Назначение |
|---|---|
| `.github/workflows/static-site.yml` | переиспользуемый пайплайн статических сайтов |
| `.github/workflows/go-service.yml` | переиспользуемый пайплайн Go-сервисов с systemd |
| `.github/workflows/desktop-artifact.yml` | переиспользуемый пайплайн установщика под Windows |
| `.github/workflows/ci.yml` | свой CI: синтаксис, shellcheck, настоящий nginx, actionlint |
| `bin/dk` | CLI: состояние прода, выкатка, откат |
| `bin/deploy` | одна локальная выкатка тем же путём, что и CI |
| `bin/install-server` | выкладывает `server/*.sh` в `/opt/deploy-kit` |
| `server/release.sh` | распаковать → бэкап → переключить → проверить → откатить |
| `server/rollback.sh` | ручной откат на предыдущий или названный релиз |
| `server/preflight.sh` | место на диске, `nginx -t`, состояние юнитов, владелец |
| `server/nginx-apply.sh` | дифф → бэкап → установка → `nginx -t` → откат |
| `server/lib.sh` | мьютекс хоста, версионный шлюз, проверки, чистка релизов |
| `ci/nginx-check.sh` | проверка конфига сайта настоящим nginx 1.24 в контейнере |
| `nginx/sites` | по файлу на домен, ровно то, что подключено на сервере |
| `nginx/snippets` | общие куски, включаются из `sites/` |
| `nginx/conf.d` | то, что обязано жить на уровне `http` (форматы журналов) |
| `dk.conf.example` | образец `~/.config/deploy-kit/dk.conf` |

`nginx/` — единственный источник правды по конфигурации nginx всей экосистемы:
правила см. в [`nginx/README.md`](nginx/README.md), про сжатие — в
[`nginx/gzip.md`](nginx/gzip.md).

## Что гарантируется и чем проверяется

| Гарантия | Чем обеспечена |
|---|---|
| Красный гейт не доезжает до прода | вход `gates` — обязательный шаг каждого переиспользуемого workflow |
| Релиз без версии не едет | `version_gate` в `server/lib.sh`, код возврата 3 |
| Старая сборка не уедет под видом новой | `compare_versions`: таймштамповая и семверная схемы, без смешивания |
| Прод не бывает переключён наполовину | `switch_symlink`: временный линк и `mv -T` |
| «Зелёный деплой со старыми файлами» ловится | `check_version` по `/version.json` либо имя релиза в `current` |
| Провалившаяся выкатка не остаётся на проде | `rollback` при провале health, версии или соседей |
| Выкатка одного сайта не роняет другой | `check_neighbours` и один файл на проект в `nginx-apply.sh` |
| Два репозитория не катятся одновременно | `flock` на `/var/lock/deploy-kit.lock`, на весь хост |
| Валидный локально, но невалидный на проде конфиг не проходит | `ci/nginx-check.sh` запускает настоящий nginx 1.24 |
| Скрипты на сервере совпадают с репозиторием | сверка контрольных сумм в `install-server`, выкладка только из `main` |

Собственный CI проверяет синтаксис скриптов отдельно от shellcheck
(разобранный скрипт с претензиями починить можно, неразбираемый — уже нет),
прогоняет каждый конфиг сайта через контейнер с nginx 1.24, линтует workflow
через actionlint и убеждается, что `dk help` не падает.

## Как пользуются другие проекты

В репозитории проекта остаётся вызов workflow:

```yaml
jobs:
  deploy:
    uses: tr0llex/deploy-kit/.github/workflows/static-site.yml@main
    with:
      config: .deploy-kit/prod.env
      gates: npm ci && npm run test:coverage && npm run build
    secrets: inherit
```

и описание цели `.deploy-kit/prod.env`:

```bash
APP=samoylove                       # имя цели и каталога на хосте
BUILD_CMD="npm ci && npm run build"
ARTIFACT_DIR=dist                   # что паковать
ROOT=/var/www/samoy.love            # тут лежат releases/ и current
OWNER=ubuntu:ubuntu
NGINX_RELOAD=1                      # статика: reload nginx после переключения
UNIT=                               # сервисы: systemd-юнит вместо reload
HEALTH=https://samoy.love/
VERSION_URL=https://samoy.love/version.json
NEIGHBOURS=metro.samoy.love,snakes.samoy.love
```

Этот же файл читает `dk deploy`. Цели, которые не раздают `version.json`,
ставят `WRITE_VERSION_FILE=0` — тогда шлюз и проверка после выкатки читают имя
релиза из симлинка `current`.

Что проект обязан предоставить, чтобы попасть в пайплайн: `/healthz` с кодом
200 и телом `ok` без авторизации, `/version.json` с полями `version`, `commit`
и `builtAt` и единую раскладку `<корень>/releases/<версия>` с симлинками
`current` и `previous` (хранятся пять последних релизов). Имена секретов везде
одинаковы: `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY`, `SSH_HOST_KEY`,
`TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`. `SSH_HOST_KEY` берётся из секрета, а
не из `ssh-keyscan`: keyscan доверяет первому ответу и принимает подмену молча.

Текущие цели:

| Цель | Архетип | Репозиторий |
|---|---|---|
| samoy.love | static-site | [samoy.love](https://github.com/tr0llex/samoy.love) |
| metro.samoy.love | static-site | [metro-map](https://github.com/tr0llex/metro-map) |
| launcher.samoy.love, морда админки | static-site | [chillhub](https://github.com/tr0llex/chillhub) |
| Серверы лаунчера и админки | go-service | [chillhub](https://github.com/tr0llex/chillhub) |
| Установщик ChillHub | desktop-artifact | [chillhub](https://github.com/tr0llex/chillhub) |
| Сервер и клиент Snakes | go-service | [snakes](https://github.com/tr0llex/snakes) |
| status.samoy.love | static-site + агент | [status.samoy.love](https://github.com/tr0llex/status.samoy.love) |

Клиент Snakes едет **одним артефактом** с сервером: у них общий бинарный
протокол, и разъехавшиеся версии ломают разбор пакетов.

## Часть samoy.love

Один домен, один сервер, один пайплайн, одна статус-страница, один мониторинг.

| Проект | Что это |
|---|---|
| [samoy.love](https://github.com/tr0llex/samoy.love) | Личная страница и витрина проектов: Astro, 3D-фон на WebGL, ноль трекеров |
| [chillhub](https://github.com/tr0llex/chillhub) | ChillHub — лаунчер игр для Windows: обновления по диффу, хеш-контроль, админка на Go |
| [snakes](https://github.com/tr0llex/snakes) | Мультиплеерный захват территории в браузере: Go, WebSocket, бинарный протокол |
| [metro-map](https://github.com/tr0llex/metro-map) | Офлайн-PWA со схемой московского метро: маршруты на клиенте, Canvas 2D |
| [status.samoy.love](https://github.com/tr0llex/status.samoy.love) | Статус-страница: аптайм, версии, инциденты; агент на Go и внешний сторож |
| [metrics.samoy.love](https://github.com/tr0llex/metrics.samoy.love) | Мониторинг и продуктовая аналитика: Prometheus, Grafana, посещаемость из журналов nginx |
| [deploy-kit](https://github.com/tr0llex/deploy-kit) | Этот репозиторий: общий релизный пайплайн |

## Контакты

Алексей Самойлов — [alex@samoy.love](mailto:alex@samoy.love) ·
[t.me/tr0llex](https://t.me/tr0llex) ·
[github.com/tr0llex](https://github.com/tr0llex)

## Лицензия

[MIT](LICENSE).
