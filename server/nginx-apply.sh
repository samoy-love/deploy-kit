#!/usr/bin/env bash
# Применение nginx-конфига проекта: дифф → бэкап → установка → проверка → откат.
#
#   nginx-apply.sh --app samoy-love --conf /tmp/new.conf \
#                  --dest /etc/nginx/sites-available/samoy.love.conf --enable
#   nginx-apply.sh ... --dry-run     # только показать дифф
#
# Почему это отдельный скрипт, а не пара строк внутри выкатки.
#
# 1. nginx -t проверяет ВСЮ конфигурацию хоста сразу. На этом сервере четыре
#    сайта, и падение проверки само по себе не говорит, чей конфиг виноват.
#    Поэтому состояние снимается ДО нашей правки: если было сломано до нас —
#    мы не начинаем и не «чиним» чужую поломку своим бэкапом.
#
# 2. Проект имеет право трогать ТОЛЬКО свой файл. Общий конфиг на два сайта
#    однажды уже привёл к тому, что деплой одного проекта снёс соседний.
#
# 3. Версия nginx на проде (1.24) не понимает директиву `http2 on` —
#    она появилась в 1.25.1. Синтаксис, валидный на машине разработчика,
#    роняет прод. Проверяется здесь же, до установки.

set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APP=""; CONF=""; DEST=""; ENABLE=0; DRY=0; KEEP_BACKUPS=10
BACKUP_DIR=/etc/nginx/.backups

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)     APP="$2"; shift 2 ;;
        --conf)    CONF="$2"; shift 2 ;;
        --dest)    DEST="$2"; shift 2 ;;
        --enable)  ENABLE=1; shift ;;
        --dry-run) DRY=1; shift ;;
        *) die "неизвестный аргумент: $1" ;;
    esac
done
[[ -n "$APP"  ]] || die "нужен --app"
[[ -n "$CONF" ]] || die "нужен --conf"
[[ -f "$CONF" ]] || die "нет файла конфига: $CONF"
[[ -n "$DEST" ]] || die "нужен --dest"

# Граница ответственности: пишем один файл и только в два каталога.
#
# conf.d появился здесь ради log_format: эта директива допустима ИСКЛЮЧИТЕЛЬНО
# на уровне http, а всё, что лежит в sites-available, — это server-блоки. Без
# файла в conf.d формат журнала пришлось бы держать руками в nginx.conf, то
# есть вне репозитория — ровно то состояние, из которого конфиги сюда и
# вытаскивали.
#
# Разрешён каталог, а не свобода: nginx.conf, sites-enabled напрямую и чужие
# snippets по-прежнему недоступны, файл по-прежнему один за запуск.
case "$DEST" in
    /etc/nginx/sites-available/*) ;;
    /etc/nginx/conf.d/*.conf) ;;
    *) die "конфиг можно ставить только в /etc/nginx/sites-available или /etc/nginx/conf.d, получено: $DEST" ;;
esac

# Симлинк в sites-enabled осмыслен только для sites-available: содержимое
# conf.d nginx.conf подключает целиком, включать там нечего.
if (( ENABLE )); then
    case "$DEST" in
        /etc/nginx/conf.d/*) die "--enable неприменим к /etc/nginx/conf.d: каталог подключён из nginx.conf целиком" ;;
    esac
fi

# --- 0. Совместимость с версией nginx на этом хосте -----------------------
ver=$(nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9.]*\).*/\1/p')
if grep -qE '^\s*http2\s+on\s*;' "$CONF"; then
    # Сравнение версий без bc: 1.25.1 — первая, где директива появилась.
    if [[ "$(printf '%s\n1.25.1\n' "$ver" | sort -V | head -1)" == "$ver" && "$ver" != "1.25.1" ]]; then
        die "конфиг использует 'http2 on;', а на хосте nginx $ver — нужна форма 'listen 443 ssl http2;'"
    fi
fi
ok "конфиг совместим с nginx $ver"

# --- 1. Состояние ДО нас --------------------------------------------------
if ! nginx -t >/dev/null 2>&1; then
    nginx -t || true
    die "nginx -t падает ДО правки — на хосте уже что-то сломано, разбираться нужно с этим"
fi
ok "до правки конфигурация исправна"

# --- 2. Что меняется ------------------------------------------------------
if [[ -f "$DEST" ]]; then
    if diff -q "$DEST" "$CONF" >/dev/null 2>&1; then
        ok "конфиг не изменился — ничего делать не нужно"
        (( ENABLE )) && ln -sfn "$DEST" "/etc/nginx/sites-enabled/$(basename "$DEST")"
        exit 0
    fi
    echo "--- дифф конфига $(basename "$DEST") ---"
    diff -u "$DEST" "$CONF" || true
    echo "--- конец диффа ---"
else
    log "файла ещё нет, будет создан: $DEST"
fi

if (( DRY )); then
    log "--dry-run: изменения не применяются"
    exit 0
fi

acquire_lock

# --- 3. Бэкап -------------------------------------------------------------
mkdir -p "$BACKUP_DIR"
BACKUP=""
if [[ -f "$DEST" ]]; then
    BACKUP="$BACKUP_DIR/$(basename "$DEST").$(human_ts)"
    cp -a "$DEST" "$BACKUP"
    ok "бэкап: $BACKUP"
fi

restore() {
    if [[ -n "$BACKUP" ]]; then
        cp -a "$BACKUP" "$DEST"
        log "конфиг восстановлен из бэкапа"
    else
        rm -f "$DEST"
        [[ -L "/etc/nginx/sites-enabled/$(basename "$DEST")" ]] && rm -f "/etc/nginx/sites-enabled/$(basename "$DEST")"
        log "новый конфиг удалён (до нас файла не было)"
    fi
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx || true
        ok "состояние nginx восстановлено"
    else
        # Худший случай: даже возврат не помог. Не пытаемся чинить дальше
        # автоматически — молчаливые попытки тут опаснее явной остановки.
        warn "ВНИМАНИЕ: nginx -t падает даже после отката. Требуется ручной разбор"
    fi
}

# --- 4. Установка и проверка ---------------------------------------------
install -m 0644 "$CONF" "$DEST"
(( ENABLE )) && ln -sfn "$DEST" "/etc/nginx/sites-enabled/$(basename "$DEST")"

if ! nginx -t >/dev/null 2>&1; then
    nginx -t || true
    restore
    die "новый конфиг не прошёл проверку — изменения откачены"
fi
ok "nginx -t прошёл"

if ! systemctl reload nginx; then
    restore
    die "nginx не перезагрузился — изменения откачены"
fi
ok "nginx перезагружен"

# --- 5. Прибраться --------------------------------------------------------
find "$BACKUP_DIR" -name "$(basename "$DEST").*" -type f -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | tail -n +$((KEEP_BACKUPS + 1)) | cut -d' ' -f2- \
    | while read -r old; do rm -f "$old"; done

ok "конфиг $APP применён"
