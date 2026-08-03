#!/usr/bin/env bash
# Прогон install_units (server/lib.sh) по поддельному /etc/systemd/system.
#
#   ci/units-test.sh
#
# ЗАЧЕМ ЭТОТ ФАЙЛ. install_units — единственное место, где выкатка пишет в
# /etc/systemd/system, и работает оно от root. Ошибка здесь не роняет деплой
# зелёным цветом вниз, она оставляет службу без запуска: не тот путь, не тот
# режим, не созданный каталог, не сделанный daemon-reload. Прочитать такую
# функцию глазами недостаточно — половина её поведения это поведение glob'ов,
# cmp и install на файловой системе, которой в момент чтения нет.
#
# Функция берётся НАСТОЯЩАЯ, через `source server/lib.sh`. Копия кода в тесте
# проверяла бы копию: разъехаться с оригиналом она может ровно так же тихо,
# как разъезжались юнит в git и юнит на машине — то есть ровно тот дефект,
# ради которого install_units и написана.
#
# Подменяются только две вещи:
#   * каталог назначения — переменная SYSTEMD_DIR переопределяется ПОСЛЕ
#     source (в самой lib.sh присваивание безусловное, из окружения значение
#     не подхватывается — так и задумано, см. комментарий там);
#   * systemctl — стабом в PATH, который пишет свои аргументы в файл. Настоящий
#     systemctl на раннере не запустишь, а проверять надо в том числе то, чего
#     он НЕ должен получить: `enable` для дополнения и daemon-reload на
#     выкатке, в которой ничего не изменилось.
# Всё остальное — install, cmp, создание каталогов, раскрытие глобов — идёт
# по-настоящему.
#
# Вызов воспроизводит боевой контекст дословно: `set -Eeuo pipefail`, как в
# release.sh, и функция в списке с `||`, как `install_units … || rollback`. В
# таком контексте errexit внутри функции НЕ действует, и провал install без
# явного `|| return 1` прошёл бы молча — случай «провал установки» ниже
# проверяет именно это.

set -uo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$KIT/server/lib.sh"
[[ -f "$LIB" ]] || { echo "не найден: $LIB" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0; skipped=0
# Имена с префиксом: lib.sh приносит свои ok/log/warn, и подменять их нельзя —
# именно их вывод здесь и проверяется.
t_ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$(( pass + 1 )); }
t_bad()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; fail=$(( fail + 1 )); }
t_skip() { printf '  \033[33m—\033[0m %s\n' "$*"; skipped=$(( skipped + 1 )); }
t_case() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# --------------------------------------------------------------------------
# Стаб systemctl. Пишет вызов строкой в $SYSTEMCTL_LOG; `cat <юнит>` отвечает
# как настоящий — успехом только для юнита, который на «хосте» есть.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
if [[ "${1-}" == cat ]]; then
    u="${2-}"; [[ "$u" == "--" ]] && u="${3-}"
    [[ -e "$FAKE_ETC/$u" || " ${KNOWN_UNITS-} " == *" $u "* ]] || exit 1
fi
exit 0
STUB
chmod +x "$TMP/bin/systemctl"
PATH="$TMP/bin:$PATH"
export PATH

# Настоящий /etc/systemd/system прогон не трогает вовсе. Проверяется это не
# обещанием, а слепком до и после.
REAL_ETC=/etc/systemd/system
REAL_BEFORE=""
[[ -d "$REAL_ETC" ]] && REAL_BEFORE="$(ls -A "$REAL_ETC" 2>/dev/null | sort)"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../server/lib.sh
source "$LIB"
set +e   # lib.sh включает errexit для себя; тесту он мешает считать провалы

export SYSTEMCTL_LOG="" FAKE_ETC="" KNOWN_UNITS=""
OUT="$TMP/out"
RC=0
CASE_N=0
REL=""

# Готовит пару «каталог релиза + поддельный /etc/systemd/system» под очередной
# случай и возвращает их через REL/FAKE_ETC.
new_case() {
    CASE_N=$(( CASE_N + 1 ))
    REL="$TMP/case$CASE_N/release"
    FAKE_ETC="$TMP/case$CASE_N/etc"
    SYSTEMD_DIR="$FAKE_ETC"
    SYSTEMCTL_LOG="$TMP/case$CASE_N/systemctl.log"
    mkdir -p "$REL" "$FAKE_ETC"
    : >"$SYSTEMCTL_LOG"
    UNIT=""
    KNOWN_UNITS=""
}

# Боевой контекст: errexit включён снаружи, функция вызвана через `||`.
run_units() {
    RC=0
    ( set -Eeuo pipefail; install_units "$REL" || exit $? ) >"$OUT" 2>&1 || RC=$?
}

mkunit() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" >"$1"; }

has()    { grep -qF -- "$2" "$OUT" && t_ok "$1" || t_bad "$1 (нет «$2» в выводе)"; }
hasnt()  { grep -qF -- "$2" "$OUT" && t_bad "$1 (в выводе есть «$2»)" || t_ok "$1"; }
sysctl_count() { grep -cF -- "$1" "$SYSTEMCTL_LOG"; }
same()   { [[ "$2" == "$3" ]] && t_ok "$1" || t_bad "$1: ожидали «$3», получили «$2»"; }
isfile() { [[ -f "$1" ]] && t_ok "$2" || t_bad "$2 (нет файла $1)"; }
nofile() { [[ -e "$1" ]] && t_bad "$3 (файл $1 существует)" || t_ok "$3"; }
content(){ same "$1" "$(cat "$2" 2>/dev/null)" "$3"; }

SVC='[Unit]
Description=snakes
[Service]
ExecStart=/opt/snakes/current/snakes'
TIMER='[Timer]
OnCalendar=daily'
DROPIN='[Service]
Environment=METRICS_SCRAPE=1'

# --------------------------------------------------------------------------
t_case '1. в релизе нет systemd/ вовсе'
new_case
mkdir -p "$REL/public"
run_units
same "код возврата 0" "$RC" "0"
same "systemctl не звали ни разу" "$(wc -l <"$SYSTEMCTL_LOG" | tr -d ' ')" "0"
same "в /etc ничего не появилось" "$(ls -A "$FAKE_ETC" | wc -l | tr -d ' ')" "0"

# --------------------------------------------------------------------------
t_case '2. только плоские юниты'
new_case
mkunit "$REL/systemd/snakes-backup-profiles.service" "$SVC"
mkunit "$REL/systemd/snakes-backup-profiles.timer" "$TIMER"
run_units
same "код возврата 0" "$RC" "0"
isfile "$FAKE_ETC/snakes-backup-profiles.service" "юнит .service поставлен"
isfile "$FAKE_ETC/snakes-backup-profiles.timer" "юнит .timer поставлен"
has "об изменении сказано" "юнит обновлён: snakes-backup-profiles.service"
same "daemon-reload ровно один" "$(sysctl_count 'daemon-reload')" "1"
same "таймер включён и запущен" "$(sysctl_count 'enable --now snakes-backup-profiles.timer')" "1"
same "служба включена без запуска" "$(sysctl_count 'enable snakes-backup-profiles.service')" "1"

# --------------------------------------------------------------------------
t_case '3. только дополнение, каталога <юнит>.d на хосте нет'
new_case
KNOWN_UNITS="snakes.service"   # сам юнит живёт на сервере, в репозитории его нет
UNIT="snakes.service"
mkunit "$REL/systemd/snakes.service.d/10-metrics-scrape.conf" "$DROPIN"
[[ -d "$FAKE_ETC/snakes.service.d" ]] && t_bad "каталога быть не должно" || t_ok "каталога <юнит>.d на хосте изначально нет"
run_units
same "код возврата 0" "$RC" "0"
isfile "$FAKE_ETC/snakes.service.d/10-metrics-scrape.conf" "дополнение легло по пути <юнит>.d/<имя>.conf"
content "содержимое дословно то же" "$FAKE_ETC/snakes.service.d/10-metrics-scrape.conf" "$DROPIN"
has "об изменении сказано" "дополнение юнита обновлено: snakes.service.d/10-metrics-scrape.conf"
same "daemon-reload ровно один" "$(sysctl_count 'daemon-reload')" "1"
same "дополнение не включают" "$(sysctl_count 'enable')" "0"
same "дополнение не запускают" "$(sysctl_count 'start')" "0"
hasnt "про ручной перезапуск не предупреждаем: юнит перезапустит сама выкатка" \
    "примените вручную"
if [[ "$(uname -s)" == Linux ]]; then
    same "режим файла 0644" "$(stat -c %a "$FAKE_ETC/snakes.service.d/10-metrics-scrape.conf")" "644"
    same "режим каталога 0755" "$(stat -c %a "$FAKE_ETC/snakes.service.d")" "755"
else
    t_skip "режимы файлов проверяются только на Linux (здесь $(uname -s))"
fi

# --------------------------------------------------------------------------
t_case '4. и плоские юниты, и дополнение — три файла Snakes'
new_case
KNOWN_UNITS="snakes.service"
UNIT="snakes.service"
mkunit "$REL/systemd/snakes-backup-profiles.service" "$SVC"
mkunit "$REL/systemd/snakes-backup-profiles.timer" "$TIMER"
mkunit "$REL/systemd/snakes.service.d/10-metrics-scrape.conf" "$DROPIN"
run_units
same "код возврата 0" "$RC" "0"
isfile "$FAKE_ETC/snakes-backup-profiles.service" "юнит .service поставлен"
isfile "$FAKE_ETC/snakes-backup-profiles.timer" "юнит .timer поставлен"
isfile "$FAKE_ETC/snakes.service.d/10-metrics-scrape.conf" "дополнение поставлено"
same "daemon-reload один на все три файла" "$(sysctl_count 'daemon-reload')" "1"
same "включён только таймер" "$(sysctl_count 'enable --now')" "1"
hasnt "дополнение не пытались включить" "enable snakes.service.d"

# --------------------------------------------------------------------------
t_case '5. повторный прогон без изменений — ничего не делаем'
# Тот же релиз и тот же /etc, что остались от случая 4.
: >"$SYSTEMCTL_LOG"
run_units
same "код возврата 0" "$RC" "0"
same "systemctl не звали ни разу" "$(wc -l <"$SYSTEMCTL_LOG" | tr -d ' ')" "0"
hasnt "про юниты не сказано ни слова" "юнит обновлён"
hasnt "про дополнения не сказано ни слова" "дополнение юнита обновлено"
hasnt "и об успехе тоже: применять было нечего" "юниты systemd применены"

# --------------------------------------------------------------------------
t_case '6. дополнение изменилось, каталог на хосте уже есть'
mkunit "$REL/systemd/snakes.service.d/10-metrics-scrape.conf" "$DROPIN
Environment=METRICS_PORT=9101"
: >"$SYSTEMCTL_LOG"
run_units
same "код возврата 0" "$RC" "0"
content "на хосте новое содержимое" "$FAKE_ETC/snakes.service.d/10-metrics-scrape.conf" \
    "$DROPIN
Environment=METRICS_PORT=9101"
same "daemon-reload ровно один" "$(sysctl_count 'daemon-reload')" "1"
hasnt "плоские юниты не трогали — они не менялись" "юнит обновлён"

# --------------------------------------------------------------------------
t_case '7. провал установки — функция обязана вернуть не ноль'
new_case
mkunit "$REL/systemd/snakes.service.d/10-metrics-scrape.conf" "$DROPIN"
# На месте каталога <юнит>.d лежит обычный файл: install -d так не может.
printf 'не каталог\n' >"$FAKE_ETC/snakes.service.d"
run_units
[[ "$RC" -ne 0 ]] && t_ok "код возврата не ноль ($RC)" || t_bad "провал install ушёл незамеченным (код 0)"
same "daemon-reload не делали" "$(sysctl_count 'daemon-reload')" "0"
hasnt "об успехе не отчитались" "юниты systemd применены"

new_case
mkunit "$REL/systemd/snakes-backup-profiles.service" "$SVC"
SYSTEMD_DIR="$TMP/case$CASE_N/нет-такого-каталога/systemd/system"
run_units
[[ "$RC" -ne 0 ]] && t_ok "плоский юнит: код возврата не ноль ($RC)" || t_bad "провал install ушёл незамеченным (код 0)"
same "daemon-reload не делали" "$(sysctl_count 'daemon-reload')" "0"

# Третий случай проверяет именно проверку КОПИРОВАНИЯ: каталог <юнит>.d на
# месте (install -d такой устраивает), а писать в него нельзя. Двумя случаями
# выше эта ветка закрыта не была — там раньше падал install -d, и `|| return 1`
# у копирования можно было убрать незаметно.
if [[ "$(uname -s)" == Linux && "$(id -u)" != "0" ]]; then
    new_case
    mkunit "$REL/systemd/snakes.service.d/10-metrics-scrape.conf" "$DROPIN"
    mkdir -p "$FAKE_ETC/snakes.service.d"
    chmod 500 "$FAKE_ETC/snakes.service.d"
    run_units
    chmod 700 "$FAKE_ETC/snakes.service.d"   # иначе каталог не убрать
    [[ "$RC" -ne 0 ]] && t_ok "каталог только на чтение: код возврата не ноль ($RC)" \
        || t_bad "провал копирования дополнения ушёл незамеченным (код 0)"
    same "daemon-reload не делали" "$(sysctl_count 'daemon-reload')" "0"
else
    t_skip "каталог только на чтение проверяется на Linux и не от root (здесь $(uname -s), uid $(id -u))"
fi

# --------------------------------------------------------------------------
t_case '8. дополнение убрали из релиза — файл на хосте называют, но не удаляют'
new_case
KNOWN_UNITS="snakes.service"
UNIT="snakes.service"
mkunit "$REL/systemd/snakes.service.d/10-metrics-scrape.conf" "$DROPIN"
mkunit "$FAKE_ETC/snakes.service.d/10-metrics-scrape.conf" "$DROPIN"
mkunit "$FAKE_ETC/snakes.service.d/99-старое.conf" "[Service]
Environment=OLD=1"
run_units
same "код возврата 0" "$RC" "0"
has "лишнее названо" "snakes.service.d/99-старое.conf"
isfile "$FAKE_ETC/snakes.service.d/99-старое.conf" "и оставлено на месте — от root такое не удаляют"
same "менять было нечего: daemon-reload не делали" "$(sysctl_count 'daemon-reload')" "0"

# --------------------------------------------------------------------------
t_case '9. дополнение к юниту, которого на хосте нет'
new_case
UNIT="snakes.service"
KNOWN_UNITS=""   # юнит ставили руками и он пропал — дополнение ни на что не влияет
mkunit "$REL/systemd/snakes.service.d/10-metrics-scrape.conf" "$DROPIN"
run_units
same "код возврата 0 — это предупреждение, а не отказ выкатки" "$RC" "0"
isfile "$FAKE_ETC/snakes.service.d/10-metrics-scrape.conf" "файл всё равно поставлен"
has "о бесполезном файле сказано" "юнита snakes.service на хосте не видно"

# --------------------------------------------------------------------------
t_case '9a. опечатка в имени каталога — файл не ставится, но и не проглатывается'
# Первый прогон этого набора показал дыру: snakes.serivce.d под глоб не
# подходит, файл не ставился И об этом никто не говорил — молчаливый пропуск,
# то есть ровно тот дефект, который здесь и убирают.
new_case
UNIT="snakes.service"
mkunit "$REL/systemd/snakes.serivce.d/10-metrics-scrape.conf" "$DROPIN"
mkunit "$REL/systemd/README.md" "не юнит"
mkunit "$REL/systemd/snakes.service.d/заметка.txt" "и это не юнит"
run_units
same "код возврата 0" "$RC" "0"
nofile "$FAKE_ETC/snakes.serivce.d/10-metrics-scrape.conf" x "опечатанное имя на хост не уезжает"
has "опечатка названа" "snakes.serivce.d"
has "посторонний файл назван" "README.md"
has "мусор внутри <юнит>.d назван" "snakes.service.d/заметка.txt"

# --------------------------------------------------------------------------
t_case '10. дополнение к чужому юниту — его никто не перезапустит'
new_case
UNIT="snakes.service"           # выкатка перезапускает snakes.service
KNOWN_UNITS="nginx.service"
mkunit "$REL/systemd/nginx.service.d/10-limits.conf" "[Service]
LimitNOFILE=65535"
run_units
same "код возврата 0" "$RC" "0"
has "сказано, что нужен ручной перезапуск" "systemctl restart nginx.service"
hasnt "и это не выдано за отсутствие юнита" "на хосте не видно"

# --------------------------------------------------------------------------
t_case '11. UNIT без суффикса — тот же юнит, лишнего предупреждения нет'
new_case
UNIT="snakes"                   # systemd принимает и так
KNOWN_UNITS="snakes.service"
mkunit "$REL/systemd/snakes.service.d/10-metrics-scrape.conf" "$DROPIN"
run_units
same "код возврата 0" "$RC" "0"
hasnt "про ручной перезапуск не предупреждаем" "примените вручную"

# --------------------------------------------------------------------------
t_case '12. каталог назначения в lib.sh — настоящий'
# Единственное, чего поддельный /etc проверить не может: что боевое значение
# SYSTEMD_DIR именно /etc/systemd/system и что оно не берётся из окружения.
if grep -q '^SYSTEMD_DIR=/etc/systemd/system$' "$LIB"; then
    t_ok "SYSTEMD_DIR=/etc/systemd/system, присваивание безусловное"
else
    t_bad "в lib.sh нет строки «SYSTEMD_DIR=/etc/systemd/system» — прогон проверяет не тот путь"
fi
if [[ -n "$REAL_BEFORE" || -d "$REAL_ETC" ]]; then
    same "настоящий $REAL_ETC не тронут" "$(ls -A "$REAL_ETC" 2>/dev/null | sort)" "$REAL_BEFORE"
else
    t_skip "настоящего $REAL_ETC на этой машине нет — трогать было нечего"
fi

# --------------------------------------------------------------------------
printf '\nитого: \033[32m%d\033[0m успешно, \033[31m%d\033[0m провалено' "$pass" "$fail"
(( skipped )) && printf ', \033[33m%d\033[0m пропущено' "$skipped"
printf '\n'
(( fail == 0 ))
