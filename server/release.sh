#!/usr/bin/env bash
# Выкатка релиза: разложить → бэкап → переключить → проверить → откатить при провале.
#
# Один скрипт на все проекты. Отличия архетипов сведены к двум флагам:
# статике нужен reload nginx, сервису — restart юнита.
#
#   release.sh --app snakes --version v1.2.3 --archive /tmp/snakes.tar.gz \
#              --root /opt/snakes --unit snakes.service \
#              --health https://snakes.samoy.love/healthz \
#              --version-url https://snakes.samoy.love/version.json \
#              --neighbours samoy.love,metro.samoy.love
#
# --dry-run печатает план и ничего не меняет.
#
# Версионный шлюз (см. lib.sh) отрабатывает до распаковки: версия обязана
# быть задана и строго новее той, что на проде. Отказ шлюза — выход с кодом 3,
# симлинк при этом не тронут вообще.
#   --no-version-file      цель не раздаёт version.json (WRITE_VERSION_FILE=0),
#                          сверять по имени релиза в симлинке
#   --allow-same-version   осознанно разрешить повтор/несравнимую версию

set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APP=""; VERSION=""; ARCHIVE=""; ROOT=""; UNIT=""; HEALTH=""; VERSION_URL=""
NEIGHBOURS=""; NGINX_RELOAD=0; KEEP=5; OWNER=""; DRY=0
ALLOW_SAME=0; NO_VERSION_FILE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)         APP="$2"; shift 2 ;;
        --version)     VERSION="$2"; shift 2 ;;
        --archive)     ARCHIVE="$2"; shift 2 ;;
        --root)        ROOT="$2"; shift 2 ;;
        --unit)        UNIT="$2"; shift 2 ;;
        --health)      HEALTH="$2"; shift 2 ;;
        --version-url) VERSION_URL="$2"; shift 2 ;;
        --neighbours)  NEIGHBOURS="$2"; shift 2 ;;
        --owner)       OWNER="$2"; shift 2 ;;
        --keep)        KEEP="$2"; shift 2 ;;
        --nginx-reload) NGINX_RELOAD=1; shift ;;
        --no-version-file)    NO_VERSION_FILE=1; shift ;;
        --allow-same-version) ALLOW_SAME=1; shift ;;
        --dry-run)     DRY=1; shift ;;
        *) die "неизвестный аргумент: $1" ;;
    esac
done

[[ -n "$APP" ]]     || die "нужен --app"
[[ -n "$VERSION" ]] || die "нужен --version"
[[ -n "$ARCHIVE" ]] || die "нужен --archive"
ROOT="${ROOT:-/opt/$APP}"

# Цель с WRITE_VERSION_FILE=0 (например, морда админки) version.json не
# раздаёт. Сверять по HTTP нечего — и шлюз, и проверка после выкатки
# опираются на имя релиза в симлинке.
if (( NO_VERSION_FILE )) && [[ -n "$VERSION_URL" ]]; then
    log "--no-version-file: сверка по $VERSION_URL отключена, сверяю по симлинку"
    VERSION_URL=""
fi

need_cmd tar; need_cmd curl; need_cmd flock

RELEASES="$ROOT/releases"
CURRENT="$ROOT/current"
PREVIOUS="$ROOT/previous"
NEW_DIR="$RELEASES/$VERSION"

if (( DRY )); then
    LIVE="$(current_live_version "$VERSION_URL" "$CURRENT")"
    echo "--- план выкатки (--dry-run, ничего не меняется) ---"
    echo "приложение:     $APP"
    echo "версия:         $VERSION"
    if version_is_placeholder "$VERSION"; then
        echo "шлюз:           ОТКАЗ — версия не задана"
    elif [[ -z "$LIVE" ]]; then
        echo "шлюз:           пропустит (на проде релизов нет)"
    else
        echo "на проде:       $LIVE"
        case "$(compare_versions "$VERSION" "$LIVE")" in
            newer) echo "шлюз:           пропустит (версия новее)" ;;
            same)  echo "шлюз:           ОТКАЗ — эта версия уже на проде" ;;
            older) echo "шлюз:           ОТКАЗ — версия старше прода" ;;
            *)     echo "шлюз:           ОТКАЗ — версии несравнимы" ;;
        esac
        (( ALLOW_SAME )) && echo "                (--allow-same-version снимет отказ)"
    fi
    echo "архив:          $ARCHIVE ($(du -h "$ARCHIVE" 2>/dev/null | cut -f1))"
    echo "каталог:        $NEW_DIR"
    echo "текущий релиз:  $([[ -L $CURRENT ]] && basename "$(readlink -f "$CURRENT")" || echo 'нет')"
    [[ -n "$UNIT" ]]       && echo "перезапуск:     $UNIT"
    (( NGINX_RELOAD ))     && echo "nginx:          reload после переключения"
    [[ -n "$HEALTH" ]]     && echo "healthcheck:    $HEALTH"
    [[ -n "$VERSION_URL" ]] && echo "сверка версии:  $VERSION_URL"
    [[ -n "$NEIGHBOURS" ]] && echo "соседи:         $NEIGHBOURS"
    echo "хранить релизов: $KEEP"
    exit 0
fi

acquire_lock

PREV_TARGET=""
[[ -L "$CURRENT" ]] && PREV_TARGET="$(readlink -f "$CURRENT")"

# --- 0. Версионный шлюз ---------------------------------------------------
# Под замком (иначе параллельная выкатка успеет сменить прод между проверкой
# и переключением) и до распаковки: незачем разбирать архив, который не
# поедет. При отказе не тронуто вообще ничего.
LIVE="$(current_live_version "$VERSION_URL" "$CURRENT")"
version_gate "$VERSION" "$LIVE" "$ALLOW_SAME" "${LIVE_VERSION_SOURCE:+, по $LIVE_VERSION_SOURCE}"

# --- 1. Разложить новый релиз рядом, не трогая текущий -------------------
log "распаковываю $VERSION в $NEW_DIR"
# Перевыкатка поверх текущего релиза (только через --allow-same-version):
# каталог, на который указывает current, на время распаковки исчезает, и
# прод в эти секунды отдаёт 404. Дешевле сказать об этом вслух, чем городить
# распаковку во временный каталог ради сценария «чиню то, что уже сломано».
if [[ -n "$PREV_TARGET" && "$PREV_TARGET" == "$NEW_DIR" ]]; then
    warn "перевыкатка поверх текущего релиза: $VERSION пересобирается под работающим current"
fi
rm -rf "$NEW_DIR"
mkdir -p "$NEW_DIR"
tar -xzf "$ARCHIVE" -C "$NEW_DIR"
[[ -n "$OWNER" ]] && chown -R "$OWNER" "$NEW_DIR"

# Бит запуска у бинаря сервиса.
#
# Windows его не хранит: артефакт, собранный локально, приезжает с правами
# 0644, systemd падает с 203/EXEC, и выкатка откатывается — верно, но
# каждый раз. В CI на Linux бит есть, и разница между «локально» и «в CI»
# ровно такого рода ошибок и не должна существовать.
if [[ -n "$UNIT" && -f "$NEW_DIR/$APP" && ! -x "$NEW_DIR/$APP" ]]; then
    chmod +x "$NEW_DIR/$APP"
    log "восстановлен бит запуска у $APP (артефакт собран там, где его нет)"
fi
ok "релиз распакован"

# --- 2. Переключить -------------------------------------------------------
# До этой строки прод работает на старом релизе и ничего не замечает.
[[ -n "$PREV_TARGET" ]] && switch_symlink "$PREVIOUS" "$PREV_TARGET"
switch_symlink "$CURRENT" "$NEW_DIR"
ok "current -> $VERSION"

rollback() {
    warn "откатываюсь на предыдущий релиз"
    if [[ -z "$PREV_TARGET" ]]; then
        die "откатываться некуда: это была первая выкатка $APP. Релиз оставлен как есть, разбирайтесь вручную"
    fi
    switch_symlink "$CURRENT" "$PREV_TARGET"
    [[ -n "$UNIT" ]] && systemctl restart "$UNIT" || true
    (( NGINX_RELOAD )) && { nginx -t >/dev/null 2>&1 && systemctl reload nginx; } || true
    warn "откат выполнен: current -> $(basename "$PREV_TARGET")"
    die "выкатка $APP $VERSION провалена и откачена"
}

# --- 3. Применить ---------------------------------------------------------
if (( NGINX_RELOAD )); then
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx
        ok "nginx перезагружен"
    else
        nginx -t || true
        rollback
    fi
fi

if [[ -n "$UNIT" ]]; then
    systemctl restart "$UNIT" || rollback
    ok "$UNIT перезапущен"
fi

# --- 4. Проверить ---------------------------------------------------------
if [[ -n "$HEALTH" ]]; then
    wait_http "$HEALTH" 10 3 || rollback
fi

if [[ -n "$VERSION_URL" ]]; then
    check_version "$VERSION_URL" "$VERSION" || rollback
else
    # Цель version.json не раздаёт: подтверждение — имя релиза, на который
    # реально указывает симлинк. Проверка слабее HTTP-сверки (о содержимом
    # каталога она не говорит ничего), но отличает «переключилось» от
    # «переключение не доехало» — а это ровно то, что здесь можно узнать.
    LIVE_NOW="$(basename "$(readlink -f "$CURRENT")")"
    if [[ "$LIVE_NOW" == "$VERSION" ]]; then
        ok "current указывает на $VERSION"
    else
        warn "current указывает на $LIVE_NOW, а выкатывали $VERSION"
        rollback
    fi
fi

if [[ -n "$NEIGHBOURS" ]]; then
    check_neighbours ${NEIGHBOURS//,/ } || rollback
fi

# --- 5. Прибраться --------------------------------------------------------
prune_releases "$RELEASES" "$KEEP"

ok "выкатка $APP $VERSION завершена"
