#!/usr/bin/env bash
# Общие функции серверных скриптов deploy-kit.
# Подключается через `source`, самостоятельно не запускается.

set -Eeuo pipefail

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
[[ -t 1 ]] || { RED=''; GRN=''; YEL=''; DIM=''; RST=''; }

log()  { printf '%s[%s]%s %s\n' "$DIM" "$(date -u '+%H:%M:%S')" "$RST" "$*"; }
ok()   { printf '%s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s!%s %s\n' "$YEL" "$RST" "$*" >&2; }
die_code() { local c="$1"; shift; printf '%s✗%s %s\n' "$RED" "$RST" "$*" >&2; exit "$c"; }
die()  { die_code 1 "$@"; }

# Отдельный код возврата для отказа шлюза. Вызывающая сторона (bin/deploy,
# workflow) по нему отличает «шлюз не пустил, прод цел» от «выкатка сломалась
# посреди процесса» — в логе это два совершенно разных события, а раньше оба
# выглядели как «упало непонятно почему».
GATE_REJECT=3

# --- мьютекс на весь хост -------------------------------------------------
#
# На этом сервере живут четыре проекта из разных репозиториев, и каждый
# катится своим workflow. Concurrency в GitHub Actions разводит выкатки
# только внутри репозитория: две из разных репозиториев спокойно начнутся
# одновременно и станут одновременно перезагружать nginx или двигать
# симлинки. Блокировка одна на хост, а не на приложение.
LOCK_FILE=/var/lock/deploy-kit.lock
LOCK_WAIT=${LOCK_WAIT:-600}

acquire_lock() {
    exec 9>"$LOCK_FILE" || die "не открыть $LOCK_FILE"
    if ! flock -w "$LOCK_WAIT" 9; then
        die "не дождались очереди за ${LOCK_WAIT}s — на хосте идёт другая выкатка"
    fi
    log "очередь на хосте занята нами (pid $$)"
}

# --- вспомогательное ------------------------------------------------------

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "нет команды $1"; }

# Свободное место в мегабайтах для указанного пути.
free_mb() { df -Pm "$1" | awk 'NR==2 {print $4}'; }

human_ts() { date -u '+%Y%m%d-%H%M%S'; }

# Симлинк current -> releases/<версия>; меняется атомарно через временный
# линк и mv -T, иначе между rm и ln есть окно, когда пути не существует.
switch_symlink() {
    local link="$1" target="$2" tmp
    tmp="${link}.new.$$"
    ln -sfn "$target" "$tmp"
    mv -T "$tmp" "$link"
}

# Удаляет старые релизы, оставляя последние KEEP штук.
prune_releases() {
    local dir="$1" keep="${2:-5}" n
    [[ -d "$dir" ]] || return 0
    n=$(find "$dir" -mindepth 1 -maxdepth 1 -type d | wc -l)
    (( n > keep )) || return 0
    find "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
        | sort -n | head -n "$(( n - keep ))" | cut -d' ' -f2- \
        | while read -r old; do
            log "удаляю старый релиз $(basename "$old")"
            rm -rf "$old"
        done
}

# Ждёт HTTP 200 с ретраями. Возвращает 1, если не дождались.
wait_http() {
    local url="$1" tries="${2:-10}" pause="${3:-3}" code
    for ((i = 1; i <= tries; i++)); do
        code=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 15 "$url" || true)
        [[ "$code" == "200" ]] && { ok "$url отвечает 200 (попытка $i)"; return 0; }
        log "попытка $i/$tries: $url -> $code"
        sleep "$pause"
    done
    return 1
}

# Сверяет версию, которую отдаёт сервис, с ожидаемой.
#
# Это главная проверка выкатки: код 200 подтверждает лишь то, что что-то
# отвечает, а расхождение версий ловит случай «деплой прошёл зелёным, а
# файлы остались старые» — самый неприятный, потому что выглядит успехом.
check_version() {
    local url="$1" want="$2" got
    got=$(curl -sL --max-time 15 "$url" 2>/dev/null | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    # Пустой ответ — это провал, а не «нечего сверять». Раньше здесь стоял
    # warn с return 0, и релиз без version.json уезжал зелёным: /version.json
    # отдавал 404 часами, потому что единственный, кто мог это заметить,
    # сам себе это и прощал. Цели, которые version.json не раздают, приходят
    # сюда без VERSION_URL (--no-version-file) и проверяются по симлинку.
    [[ -z "$got" ]] && { warn "$url не отдал version — релиз не подтверждает себя"; return 1; }
    [[ "$got" == "$want" ]] && { ok "версия совпала: $got"; return 0; }
    warn "версия НЕ совпала: ожидали $want, получили $got"
    return 1
}

# --- версионный шлюз ------------------------------------------------------
#
# Два случая из практики, ради которых он существует:
#   1. релиз выложили без version.json — /version.json отдавал 404 часами,
#      и никто этого не заметил, потому что «деплой прошёл зелёным»;
#   2. старая сборка уехала под видом новой — симлинк переключился на релиз
#      старше текущего, и на проде молча откатилась функциональность.
# Оба ловятся до переключения симлинка: прод при отказе остаётся нетронутым.

# Метки, которые не являются версией. Появляются, когда сборка шла мимо
# пайплайна и подстановка версии просто не сработала.
VERSION_PLACEHOLDERS=" dev unknown none null nil latest head local snapshot "

version_is_placeholder() {
    local v="${1,,}"
    [[ -z "${v//[[:space:]]/}" ]] && return 0
    [[ "$VERSION_PLACEHOLDERS" == *" $v "* ]]
}

# Таймштамп из имени релиза (release-20260802-134500-abc1234) как 14 цифр:
# в таком виде лексикографический порядок совпадает с хронологическим.
version_ts() {
    local m
    m=$(grep -oE '[0-9]{8}-[0-9]{6}' <<<"$1" | head -1)
    [[ -n "$m" ]] || return 1
    printf '%s' "${m/-/}"
}

# Разбор семверного тега: «мажор минор патч предрелиз».
version_semver() {
    [[ "$1" =~ ^[vV]?([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9A-Za-z.-]+))?$ ]] || return 1
    printf '%s %s %s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[5]}"
}

# Сравнивает две версии: newer | same | older | incomparable.
#
# Схем ровно две — таймштамповая и семверная, — и сравниваются они только
# сами с собой. Смешивать нельзя: у v1.4.0 нет даты, у release-2026… нет
# номера, и любое «разумное умолчание» здесь означало бы угадывание.
compare_versions() {
    local new="$1" cur="$2" n_ts c_ts n_sv c_sv pair
    [[ "$new" == "$cur" ]] && { echo same; return 0; }

    n_ts=$(version_ts "$new") || n_ts=""
    c_ts=$(version_ts "$cur") || c_ts=""
    if [[ -n "$n_ts" && -n "$c_ts" ]]; then
        if   (( 10#$n_ts > 10#$c_ts )); then echo newer
        elif (( 10#$n_ts < 10#$c_ts )); then echo older
        else echo same    # секунда одна, коммиты разные — считаем повтором
        fi
        return 0
    fi

    n_sv=$(version_semver "$new") || n_sv=""
    c_sv=$(version_semver "$cur") || c_sv=""
    if [[ -n "$n_sv" && -n "$c_sv" ]]; then
        local na nb nc npre ca cb cc cpre
        read -r na nb nc npre <<<"$n_sv"
        read -r ca cb cc cpre <<<"$c_sv"
        for pair in "$na $ca" "$nb $cb" "$nc $cc"; do
            # shellcheck disable=SC2086
            set -- $pair
            (( $1 > $2 )) && { echo newer; return 0; }
            (( $1 < $2 )) && { echo older; return 0; }
        done
        # Триплеты равны — решает предрелизная часть: v1.4.0-rc1 старше
        # самого v1.4.0 быть не может.
        [[ -z "$npre" && -n "$cpre" ]] && { echo newer; return 0; }
        [[ -n "$npre" && -z "$cpre" ]] && { echo older; return 0; }
        [[ "$npre" > "$cpre" ]] && { echo newer; return 0; }
        [[ "$npre" < "$cpre" ]] && { echo older; return 0; }
        echo same; return 0
    fi

    echo incomparable
}

# Что сейчас на проде.
#
# Основной источник — /version.json: он показывает, что сервис реально
# отдаёт наружу, а не что лежит в каталоге. Имя каталога из симлинка —
# запасной источник и единственный для целей с WRITE_VERSION_FILE=0
# (морда админки version.json не раздаёт, и требовать его от неё бессмысленно).
# Откуда взята версия прода — для сообщений шлюза.
LIVE_VERSION_SOURCE=""

current_live_version() {
    local url="$1" link="$2" got=""
    LIVE_VERSION_SOURCE=""
    if [[ -n "$url" ]]; then
        got=$(curl -sL --max-time 15 "$url" 2>/dev/null \
              | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        if [[ -n "$got" ]]; then
            LIVE_VERSION_SOURCE="$url"
        else
            warn "$url не отдал version — беру версию из симлинка current"
        fi
    fi
    if [[ -z "$got" && -L "$link" ]]; then
        got=$(basename "$(readlink -f "$link")")
        LIVE_VERSION_SOURCE="симлинк current"
    fi
    printf '%s' "$got"
}

# Решение шлюза. Отказ = выход с GATE_REJECT, симлинк не тронут.
version_gate() {
    local new="$1" cur="$2" allow="${3:-0}" src="${4:-}"
    local hint="Осознанный повтор (перевыкатка после ручной порчи каталога): --allow-same-version"

    if version_is_placeholder "$new"; then
        die_code "$GATE_REJECT" "версия не задана или бессмысленна: «$new». Релиз без версии не едет"
    fi
    if [[ -z "$cur" ]]; then
        ok "шлюз: на проде релизов нет, выкатываю $new"
        return 0
    fi

    case "$(compare_versions "$new" "$cur")" in
        newer)
            ok "шлюз: $new новее, чем на проде ($cur$src)" ;;
        same)
            (( allow )) && { warn "шлюз: версия $new уже на проде$src, но задан --allow-same-version — продолжаю"; return 0; }
            die_code "$GATE_REJECT" "версия $new уже на проде$src — выкатка отменена, симлинк не тронут. $hint" ;;
        older)
            (( allow )) && { warn "шлюз: $new старше, чем на проде ($cur$src), но задан --allow-same-version — продолжаю"; return 0; }
            die_code "$GATE_REJECT" "версия $new СТАРШЕ той, что на проде ($cur$src) — это уезжающая под видом новой старая сборка. Выкатка отменена, симлинк не тронут. Нужен откат — rollback.sh. $hint" ;;
        *)
            (( allow )) && { warn "шлюз: $new и $cur$src несравнимы, но задан --allow-same-version — продолжаю"; return 0; }
            die_code "$GATE_REJECT" "не могу сравнить $new с тем, что на проде ($cur$src): разные схемы версий. Молча пропустить нельзя — подтвердите явно. $hint" ;;
    esac
}

# Проверяет, что соседние сайты живы. Nginx общий, и ошибка в своём конфиге
# роняет чужие домены — эта проверка ловит именно такие случаи.
check_neighbours() {
    local failed=0 code
    for host in "$@"; do
        code=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 15 "https://$host/" || true)
        if [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]; then
            ok "сосед $host: $code"
        else
            warn "сосед $host: $code"
            failed=1
        fi
    done
    return $failed
}
