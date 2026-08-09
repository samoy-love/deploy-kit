#!/usr/bin/env bash
# Ручной откат на предыдущий или произвольный релиз — без пересборки.
#
#   rollback.sh --app snakes                       # на предыдущий
#   rollback.sh --app snakes --to 20260801-2250    # на конкретный
#   rollback.sh --app snakes --list                # что вообще есть
#
# Пересборка не нужна: релизы лежат на диске рядом, переключается симлинк.
#
# --allow-older снимает запрет на движение назад по времени сборки
# (monotonic_gate в lib.sh). Для отката он включён и без флага — см. ALLOW_OLDER
# ниже; принимается он потому, что этот флаг называет отказ монотонности в
# release.sh, и напечатанная там команда обязана работать дословно.

set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APP=""; ROOT=""; TO=""; UNIT=""; HEALTH=""; NGINX_RELOAD=0; LIST=0

# Откат — это и есть движение назад, поэтому запрет монотонности здесь снят по
# умолчанию: включить его значило бы запретить единственную операцию, ради
# которой скрипт существует. Флаг --allow-older ставит то же самое явно —
# ровно его печатает отказ монотонности в release.sh, и человек в момент аварии
# копирует ту строку целиком. Неизвестный аргумент уронил бы откат на разборе
# командной строки — то есть уведомление о неверной выкатке стоило бы прода.
ALLOW_OLDER=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)    APP="$2"; shift 2 ;;
        --root)   ROOT="$2"; shift 2 ;;
        --to)     TO="$2"; shift 2 ;;
        --unit)   UNIT="$2"; shift 2 ;;
        --health) HEALTH="$2"; shift 2 ;;
        --nginx-reload) NGINX_RELOAD=1; shift ;;
        --allow-older)  ALLOW_OLDER=1; shift ;;
        --list)   LIST=1; shift ;;
        *) die "неизвестный аргумент: $1" ;;
    esac
done
[[ -n "$APP" ]] || die "нужен --app"

# Проверка аргументов, из которых собираются пути (см. lib.sh). Скрипт
# запускается через sudo с неограниченными аргументами, а ниже из --root и
# --to собирается путь, на который переключается симлинк current. Без этой
# проверки `--to ../../..` проходил бы по единственному условию `[[ -d ... ]]`
# и уводил сайт на произвольный существующий каталог.
assert_path_component "--app" "$APP"
[[ -z "$TO" ]] || assert_path_component "--to" "$TO"
ROOT="$(assert_deploy_root "${ROOT:-/opt/$APP}")" || exit 1
RELEASES="$ROOT/releases"
CURRENT="$ROOT/current"

# Событие отката. Обоснование защиты — в шапке notify_event в release.sh:
# отдельный процесс (замок хоста висит на дескрипторе 9), timeout и гашение
# любого кода возврата. Здесь ставки те же: откат чинит прод, и уведомление не
# имеет права его сорвать.
DK_NOTIFY="${DK_NOTIFY:-}"
if [[ -z "$DK_NOTIFY" ]]; then
    _dk_dir="$(dirname "${BASH_SOURCE[0]}")"
    if   [[ -f "$_dk_dir/notify.sh" ]];        then DK_NOTIFY="$_dk_dir/notify.sh"
    elif [[ -f "$_dk_dir/../lib/notify.sh" ]]; then DK_NOTIFY="$_dk_dir/../lib/notify.sh"
    fi
fi

notify_event() {
    if [[ ! -f "$DK_NOTIFY" ]]; then
        log "notify.sh не найден — событие «$*» не отправлено"
        return 0
    fi
    # Вызов идёт УЖЕ на сервере — доставать себя же по SSH незачем, событие
    # просто дописывается в журнал напрямую. Без --mode notify.sh молча берёт
    # умолчание "ssh" и требует --host, которого здесь никогда не будет.
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 bash "$DK_NOTIFY" --mode local "$@" </dev/null || warn "событие не отправлено (код $?): $*"
    else
        bash "$DK_NOTIFY" --mode local "$@" </dev/null || warn "событие не отправлено (код $?): $*"
    fi
    return 0
}

if (( LIST )); then
    echo "релизы $APP (текущий помечен ->):"
    cur="$(readlink -f "$CURRENT" 2>/dev/null || true)"
    find "$RELEASES" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
        | sort -rn | cut -d' ' -f2- | while read -r d; do
            mark="  "; [[ "$d" == "$cur" ]] && mark="->"
            printf '%s %-32s %s\n' "$mark" "$(basename "$d")" \
                "$(TZ=Europe/Moscow date -d "@$(stat -c %Y "$d")" '+%Y-%m-%d %H:%M МСК')"
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
# Совпадение особенно вероятно сразу после автоотката внутри release.sh:
# previous и current там какое-то время указывали на один каталог. Поэтому
# подсказка про --list здесь обязательна — иначе сообщение выглядит тупиком.
[[ "$TARGET" == "$CUR" ]] && die "уже на этом релизе: $(basename "$TARGET") — выберите другой через --to (посмотрите --list)"

log "откат $APP: $(basename "$CUR") -> $(basename "$TARGET")"

# Тот же барьер, что стоит на пути выкатки (monotonic_gate в lib.sh), но с
# разрешённым движением назад. Зовётся он и здесь не ради запрета, а ради
# симметрии и журнала: направление перехода называется вслух одной и той же
# строкой на обоих путях, и «откат вперёд» (--to на релиз новее живого) виден
# в логе так же, как движение назад.
#
# Живой релиз отдельной переменной: current может не быть вовсе (симлинк снесли
# руками), и пустое имя обязано доехать до проверки пустым, а не собираться
# подстановкой, которая в этом случае падает.
LIVE_RELEASE=""
[[ -n "$CUR" ]] && LIVE_RELEASE="$(basename "$CUR")"
monotonic_gate "$(basename "$TARGET")" "$LIVE_RELEASE" "$ALLOW_OLDER"
[[ -n "$CUR" ]] && switch_symlink "$ROOT/previous" "$CUR"
switch_symlink "$CURRENT" "$TARGET"

# Юниты откатываем вместе с релизом — ровно так же, как это делает
# автоматический откат внутри release.sh. Без этого на старом коде остаётся
# ExecStart от нового релиза: служба запускается со свежими аргументами по
# файлам годовой давности, и ручной откат чинит половину проблемы, отчитавшись
# об успехе. Провал установки юнита не отменяет уже переключённый симлинк —
# говорим об этом вслух и продолжаем.
install_units "$TARGET" || warn "юниты systemd НЕ откачены — проверьте /etc/systemd/system вручную"

# Отдельный if, а не цепочка `nginx -t && reload && ok`: в цепочке errexit не
# срабатывает, и падение nginx -t превращало весь шаг в молчаливый no-op —
# скрипт доходил до «откат выполнен», пока nginx продолжал отдавать ту самую
# конфигурацию, из-за которой откат и понадобился.
NGINX_OK=1
if (( NGINX_RELOAD )); then
    if nginx -t >/dev/null 2>&1; then
        if systemctl reload nginx; then
            ok "nginx перезагружен"
        else
            NGINX_OK=0
            warn "systemctl reload nginx не отработал — конфигурация НЕ перезагружена"
        fi
    else
        NGINX_OK=0
        nginx -t || true
        warn "nginx -t падает — конфигурация НЕ перезагружена, откат неполный"
    fi
fi
[[ -n "$UNIT" ]] && { systemctl restart "$UNIT"; ok "$UNIT перезапущен"; }

if [[ -n "$HEALTH" ]]; then
    wait_http "$HEALTH" 10 3 || warn "healthcheck не прошёл ПОСЛЕ отката — состояние требует ручного разбора"
fi

# Событие уходит независимо от того, полный откат вышел или частичный: симлинк
# уже переключён, прод уже отдаёт другой релиз — сказать об этом обязаны оба
# раза. Тем более во втором: неполный откат — это как раз то, о чём в чате надо
# узнать сразу, а не из графиков.
#
# `version` — релиз, НА который вернулись (docs/events.md, §4), `previous` — с
# которого ушли. Пара читается ровно как строка «была X, стала Y» в сообщении.
PREV_ARG=()
if [[ -n "$CUR" ]]; then
    PREV_ARG=(--previous "$(basename "$CUR")")
fi
notify_event --kind rollback --app "$APP" --version "$(basename "$TARGET")" \
    --reason manual "${PREV_ARG[@]}"

if (( NGINX_OK )); then
    ok "откат выполнен: $APP на $(basename "$TARGET")"
else
    die "откат выполнен ЧАСТИЧНО: $APP на $(basename "$TARGET"), но nginx остался на прежней конфигурации"
fi
