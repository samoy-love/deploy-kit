#!/usr/bin/env bash
# Общие функции серверных скриптов deploy-kit.
# Подключается через `source`, самостоятельно не запускается.

set -Eeuo pipefail

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
[[ -t 1 ]] || { RED=''; GRN=''; YEL=''; DIM=''; RST=''; }

log()  { printf '%s[%s]%s %s\n' "$DIM" "$(date -u '+%H:%M:%S')" "$RST" "$*"; }
ok()   { printf '%s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s!%s %s\n' "$YEL" "$RST" "$*" >&2; }
die()  { printf '%s✗%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

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
    [[ -z "$got" ]] && { warn "$url не отдал version — пропускаю сверку"; return 0; }
    [[ "$got" == "$want" ]] && { ok "версия совпала: $got"; return 0; }
    warn "версия НЕ совпала: ожидали $want, получили $got"
    return 1
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
