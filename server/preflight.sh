#!/usr/bin/env bash
# Проверка предусловий ПЕРЕД выкаткой.
#
# Смысл в том, чтобы не начинать выкатку на уже нездоровом хосте: иначе
# непонятно, что сломалось — наш релиз или то, что лежало до него. И чтобы
# не обнаружить нехватку места на середине копирования.
#
#   preflight.sh --app snakes --need-mb 500 [--units snakes.service]
#
# Код возврата: 0 — можно катить, 1 — нельзя.

set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APP=""; NEED_MB=300; UNITS=""; ROOT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)     APP="$2"; shift 2 ;;
        --root)    ROOT="$2"; shift 2 ;;
        --need-mb) NEED_MB="$2"; shift 2 ;;
        --units)   UNITS="$2"; shift 2 ;;
        *) die "неизвестный аргумент: $1" ;;
    esac
done
[[ -n "$APP" ]] || die "нужен --app"
ROOT="${ROOT:-/opt/$APP}"

fail=0

log "проверяю предусловия для $APP"

# 1. Конфигурация nginx исправна ДО нас.
#
# Если она уже сломана, наш деплой либо не сможет перезагрузить nginx, либо
# получит чужую поломку в свой откат и «починит» её нашим бэкапом.
if command -v nginx >/dev/null 2>&1; then
    if sudo nginx -t >/dev/null 2>&1; then
        ok "nginx -t проходит"
    else
        warn "nginx -t падает ДО выкатки — разберитесь с этим раньше, чем катить"
        fail=1
    fi
fi

# 2. Место на диске. Релизы и бэкапы копятся, и «кончился диск» посреди
# копирования оставляет каталог релиза недописанным.
avail=$(free_mb "$(dirname "$ROOT")")
if (( avail >= NEED_MB )); then
    ok "свободно ${avail}MB (нужно ${NEED_MB}MB)"
else
    warn "мало места: ${avail}MB, нужно ${NEED_MB}MB"
    fail=1
fi

# 3. Юниты, которые мы собираемся трогать, сейчас в порядке.
if [[ -n "$UNITS" ]]; then
    for u in ${UNITS//,/ }; do
        state=$(systemctl is-active "$u" 2>/dev/null || true)
        if [[ "$state" == "active" ]]; then
            ok "$u: active"
        else
            warn "$u: $state (до выкатки)"
        fi
    done
fi

# 4. Предыдущий релиз на месте — значит, будет куда откатываться.
if [[ -L "$ROOT/current" ]]; then
    ok "текущий релиз: $(basename "$(readlink -f "$ROOT/current")")"
else
    log "current отсутствует — это первая выкатка $APP"
fi

(( fail == 0 )) || die "предусловия не выполнены"
ok "предусловия в порядке"
