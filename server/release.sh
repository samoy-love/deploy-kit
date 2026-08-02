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

set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APP=""; VERSION=""; ARCHIVE=""; ROOT=""; UNIT=""; HEALTH=""; VERSION_URL=""
NEIGHBOURS=""; NGINX_RELOAD=0; KEEP=5; OWNER=""; DRY=0

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
        --dry-run)     DRY=1; shift ;;
        *) die "неизвестный аргумент: $1" ;;
    esac
done

[[ -n "$APP" ]]     || die "нужен --app"
[[ -n "$VERSION" ]] || die "нужен --version"
[[ -n "$ARCHIVE" ]] || die "нужен --archive"
ROOT="${ROOT:-/opt/$APP}"

need_cmd tar; need_cmd curl; need_cmd flock

RELEASES="$ROOT/releases"
CURRENT="$ROOT/current"
PREVIOUS="$ROOT/previous"
NEW_DIR="$RELEASES/$VERSION"

if (( DRY )); then
    echo "--- план выкатки (--dry-run, ничего не меняется) ---"
    echo "приложение:     $APP"
    echo "версия:         $VERSION"
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

# --- 1. Разложить новый релиз рядом, не трогая текущий -------------------
log "распаковываю $VERSION в $NEW_DIR"
rm -rf "$NEW_DIR"
mkdir -p "$NEW_DIR"
tar -xzf "$ARCHIVE" -C "$NEW_DIR"
[[ -n "$OWNER" ]] && chown -R "$OWNER" "$NEW_DIR"
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
fi

if [[ -n "$NEIGHBOURS" ]]; then
    check_neighbours ${NEIGHBOURS//,/ } || rollback
fi

# --- 5. Прибраться --------------------------------------------------------
prune_releases "$RELEASES" "$KEEP"

ok "выкатка $APP $VERSION завершена"
