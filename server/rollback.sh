#!/usr/bin/env bash
# Ручной откат на предыдущий или произвольный релиз — без пересборки.
#
#   rollback.sh --app snakes                       # на предыдущий
#   rollback.sh --app snakes --to 20260801-2250    # на конкретный
#   rollback.sh --app snakes --list                # что вообще есть
#
# Пересборка не нужна: релизы лежат на диске рядом, переключается симлинк.

set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APP=""; ROOT=""; TO=""; UNIT=""; HEALTH=""; NGINX_RELOAD=0; LIST=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)    APP="$2"; shift 2 ;;
        --root)   ROOT="$2"; shift 2 ;;
        --to)     TO="$2"; shift 2 ;;
        --unit)   UNIT="$2"; shift 2 ;;
        --health) HEALTH="$2"; shift 2 ;;
        --nginx-reload) NGINX_RELOAD=1; shift ;;
        --list)   LIST=1; shift ;;
        *) die "неизвестный аргумент: $1" ;;
    esac
done
[[ -n "$APP" ]] || die "нужен --app"
ROOT="${ROOT:-/opt/$APP}"
RELEASES="$ROOT/releases"
CURRENT="$ROOT/current"

if (( LIST )); then
    echo "релизы $APP (текущий помечен ->):"
    cur="$(readlink -f "$CURRENT" 2>/dev/null || true)"
    find "$RELEASES" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
        | sort -rn | cut -d' ' -f2- | while read -r d; do
            mark="  "; [[ "$d" == "$cur" ]] && mark="->"
            printf '%s %-32s %s\n' "$mark" "$(basename "$d")" \
                "$(date -u -d "@$(stat -c %Y "$d")" '+%Y-%m-%d %H:%M UTC')"
        done
    exit 0
fi

acquire_lock

if [[ -n "$TO" ]]; then
    TARGET="$RELEASES/$TO"
    [[ -d "$TARGET" ]] || die "релиза $TO нет в $RELEASES (посмотрите --list)"
else
    TARGET="$(readlink -f "$ROOT/previous" 2>/dev/null || true)"
    [[ -n "$TARGET" && -d "$TARGET" ]] || die "предыдущий релиз не найден — укажите --to (посмотрите --list)"
fi

CUR="$(readlink -f "$CURRENT" 2>/dev/null || true)"
[[ "$TARGET" == "$CUR" ]] && die "уже на этом релизе: $(basename "$TARGET")"

log "откат $APP: $(basename "$CUR") -> $(basename "$TARGET")"
[[ -n "$CUR" ]] && switch_symlink "$ROOT/previous" "$CUR"
switch_symlink "$CURRENT" "$TARGET"

if (( NGINX_RELOAD )); then
    nginx -t >/dev/null 2>&1 && systemctl reload nginx && ok "nginx перезагружен"
fi
[[ -n "$UNIT" ]] && { systemctl restart "$UNIT"; ok "$UNIT перезапущен"; }

if [[ -n "$HEALTH" ]]; then
    wait_http "$HEALTH" 10 3 || warn "healthcheck не прошёл ПОСЛЕ отката — состояние требует ручного разбора"
fi

ok "откат выполнен: $APP на $(basename "$TARGET")"
