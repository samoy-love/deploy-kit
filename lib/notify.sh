#!/usr/bin/env bash
# Событие выкатки в журнал на сервере — ОДИН транспорт на все пути.
#
#   lib/notify.sh --kind started --app snakes
#   lib/notify.sh --kind success --app snakes --version release-20260805-1a2b3c4 \
#                 --previous release-20260804-9f8e7d6 --changelog-html cl.txt
#   lib/notify.sh --kind failure --app metro --stage gates
#   lib/notify.sh --kind rolled_back --app metro --version … --previous … \
#                 --stage health --reason health_failed --mode local
#
# Контракт события — docs/events.md; всё ниже только его исполняет. Правка
# формы события без правки контракта (и наоборот) — это правка, о которой
# узнают на проде: сторон у формата две, и вторая написана на Go.
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ МОДУЛЬ. Зовут его три места: композитное действие
# .github/actions/notify (выкатка из пайплайна), bin/deploy (выкатка с машины)
# и серверные скрипты release.sh/rollback.sh/publish-file.sh (событие рождается
# прямо на хосте). Ровно так же когда-то было устроено сообщение в Telegram —
# пятью копиями bash, и они разъехались молча. Копия здесь стоила бы дороже:
# разъехавшийся формат события ломает не украшение, а единственный канал, по
# которому владелец узнаёт о провале выкатки.
#
# ГЛАВНОЕ ПРАВИЛО. Недоставленное событие не имеет права выглядеть
# доставленным. При исчерпании попыток модуль печатает `::error::` и выходит
# НЕНУЛЕВЫМ кодом. Вызывающая сторона вольна решить, валить ли из-за этого
# выкатку (release.sh — не валит, см. его комментарий), но узнать об этом она
# обязана: тишина в чате читается как «не катились», и подменять ею «катились,
# но сказать не смогли» — это ровно тот дефект, ради которого всё затевалось.
#
# ------------------------------------------------------------------ ВХОД ---
#
# Каждый флаг имеет двойника в окружении: действие CI удобнее описывать через
# `env:`, а серверным скриптам проще передать аргументы. Флаг сильнее.
#
#   --kind        DK_EVENT_KIND        started|success|failure|rolled_back|
#                                      rollback|published                (обяз.)
#   --app         DK_EVENT_APP         id цели, ^[a-z0-9][a-z0-9._-]{0,63}$
#   --version     DK_EVENT_VERSION     версия, которую выкатывали
#   --previous    DK_EVENT_PREVIOUS    что было до
#   --stage       DK_EVENT_STAGE       перечисление §7 контракта
#   --reason      DK_EVENT_REASON      перечисление §7 контракта
#   --commit-url  DK_EVENT_COMMIT_URL  только https://github.com/…
#   --run-url     DK_EVENT_RUN_URL     то же; при source=local запрещён
#   --at          DK_EVENT_AT          RFC3339 UTC; по умолчанию «сейчас»
#   --source      DK_EVENT_SOURCE      ci|local; по умолчанию ci под GITHUB_ACTIONS
#   --changelog-html <файл>  DK_EVENT_CHANGELOG_HTML  дословный stdout
#                                      bin/changelog — модуль сам приводит его
#                                      к простому тексту по §4 контракта
#   --changelog-file <файл>  DK_EVENT_CHANGELOG_FILE  уже готовый текст,
#                                      по пункту в строке
#
# --------------------------------------------------------------- ТРАНСПОРТ ---
#
#   --mode ssh|local  DK_NOTIFY_MODE   ssh — доставить по SSH (умолчание),
#                                      local — писать прямо в каталог
#   --host        DEPLOY_HOST          куда доставлять (режим ssh)
#   --user        DEPLOY_USER          умолчание ubuntu
#   --key <файл>  DEPLOY_KEY           ключ выкатки; берётся КАК ЕСТЬ
#                 DK_SSH_KEY           СОДЕРЖИМОЕ ключа (для CI): кладётся во
#                                      временный файл 600 и стирается в любом исходе
#                 DK_SSH_KNOWN_HOSTS   содержимое known_hosts, если нужен свой
#   --events-dir  DK_EVENTS_DIR        каталог журнала, умолчание
#                                      /var/lib/deploy-kit/events
#   --print-event                      собрать и напечатать событие, никуда не
#                                      доставляя (отладка и тесты)
#
# Ещё несколько переменных нужны только тесту и отладке; в выкатке их не
# выставляет никто, а значения по умолчанию — те самые потолки §8 контракта:
# DK_NOTIFY_SLEEPS, DK_NOTIFY_QUIET, DK_MAX_EVENT_BYTES (8192),
# DK_MAX_DIR_FILES (5000), DK_MAX_DIR_KIB (32768), DK_MAX_DAY_EVENTS (200),
# DK_EVENT_TTL_DAYS (14).
#
# ------------------------------------------------------------- ГРУППИРОВКА ---
#
# Один пуш катит несколько целей, и в чат должно уйти ОДНО сообщение на прогон
# (§6 контракта). Прогон опознаётся полем `group`:
#
#   ci      — GITHUB_REPOSITORY|GITHUB_RUN_ID|GITHUB_RUN_ATTEMPT, эти три
#             величины в job'е есть всегда, и придумывать ничего не нужно;
#   local   — DK_RUN_STARTED_MS|<hostname>|DK_RUN_PID.
#
# ОБЕ локальные величины обязана выставить ОДИН РАЗ команда, которая начала
# прогон (`dk deploy`, в том числе `dk deploy --all` с одиннадцатью целями):
# `dk` зовёт bin/deploy отдельным процессом на каждую цель, поэтому взять здесь
# `$$` значило бы одиннадцать групп и одиннадцать сообщений на одну команду
# владельца. Если их нет — группой становится один вызов этого модуля, и это
# худший, но честный вариант: лучше лишнее сообщение, чем потерянное.
# Готовую группу можно передать и прямо: --group <64 hex> / DK_GROUP.
#
# `groupSeq` считает писатель на хосте под тем же flock, которым разрешаются
# столкновения имён: только он видит весь журнал.
#
# --------------------------------------------------------------- ПОВТОРЫ ---
#
# Три попытки с нарастающей паузой (DK_NOTIFY_SLEEPS, по умолчанию «2 5»).
# Повторяется только то, что бывает временным: отказ сети, недоступный хост,
# занятый замок. Отказ ПО КОНТРАКТУ (потолок каталога, суточный предел, кривое
# поле) — код 2 и никаких повторов: во второй раз ответ будет тот же, а пауза
# задержит выкатку.
#
# Повтор доставки безопасен по построению: `id` у события не зависит от номера
# попытки (§5 контракта), и бот отбрасывает дубль по `recentIds`. Сверх того,
# писатель узнаёт собственный повтор по совпадению имени, `group` и `at` — и
# тогда не пишет второй файл вовсе.

set -Eeuo pipefail

RED=$'\033[31m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
[[ -t 2 ]] || { RED=''; YEL=''; DIM=''; RST=''; }

warn() { printf '%s!%s notify: %s\n' "$YEL" "$RST" "$*" >&2; }
log()  { (( ${DK_NOTIFY_QUIET:-0} )) || printf '%snotify:%s %s\n' "$DIM" "$RST" "$*" >&2; }

# Провал уезжает ДВУМЯ строками, и это не дублирование. `::error::` в stdout
# читает GitHub Actions — он превращает её в аннотацию и в красную строку в
# сводке прогона; человек читает stderr, где строка не изуродована разметкой.
# На машине разработчика аннотация просто не мешает, зато формат один на оба
# пути, и проверять его достаточно в одном месте.
die_code() {
    local code="$1"; shift
    printf '::error::notify: %s\n' "$*"
    printf '%s✗%s notify: %s\n' "$RED" "$RST" "$*" >&2
    exit "$code"
}
die()        { die_code 1 "$@"; }   # доставка не удалась
die_reject() { die_code 2 "$@"; }   # событие отвергнуто по контракту

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "нет команды $1"; }

# --- разбор входа ---------------------------------------------------------

KIND="${DK_EVENT_KIND:-}"
APP="${DK_EVENT_APP:-}"
VERSION="${DK_EVENT_VERSION:-}"
PREVIOUS="${DK_EVENT_PREVIOUS:-}"
STAGE="${DK_EVENT_STAGE:-}"
REASON="${DK_EVENT_REASON:-}"
COMMIT_URL="${DK_EVENT_COMMIT_URL:-}"
RUN_URL="${DK_EVENT_RUN_URL:-}"
AT="${DK_EVENT_AT:-}"
SOURCE="${DK_EVENT_SOURCE:-}"
CL_HTML="${DK_EVENT_CHANGELOG_HTML:-}"
CL_FILE="${DK_EVENT_CHANGELOG_FILE:-}"
GROUP="${DK_GROUP:-}"

MODE="${DK_NOTIFY_MODE:-ssh}"
HOST="${DEPLOY_HOST:-}"
USER_="${DEPLOY_USER:-ubuntu}"
KEY="${DEPLOY_KEY:-}"
EVENTS_DIR="${DK_EVENTS_DIR:-/var/lib/deploy-kit/events}"
PRINT_ONLY=0

while (( $# )); do
    case "$1" in
        --kind)            KIND="${2-}"; shift 2 ;;
        --app)             APP="${2-}"; shift 2 ;;
        --version)         VERSION="${2-}"; shift 2 ;;
        --previous)        PREVIOUS="${2-}"; shift 2 ;;
        --stage)           STAGE="${2-}"; shift 2 ;;
        --reason)          REASON="${2-}"; shift 2 ;;
        --commit-url)      COMMIT_URL="${2-}"; shift 2 ;;
        --run-url)         RUN_URL="${2-}"; shift 2 ;;
        --at)              AT="${2-}"; shift 2 ;;
        --source)          SOURCE="${2-}"; shift 2 ;;
        --changelog-html)  CL_HTML="${2-}"; shift 2 ;;
        --changelog-file)  CL_FILE="${2-}"; shift 2 ;;
        --group)           GROUP="${2-}"; shift 2 ;;
        --mode)            MODE="${2-}"; shift 2 ;;
        --host)            HOST="${2-}"; shift 2 ;;
        --user)            USER_="${2-}"; shift 2 ;;
        --key)             KEY="${2-}"; shift 2 ;;
        --events-dir)      EVENTS_DIR="${2-}"; shift 2 ;;
        --print-event)     PRINT_ONLY=1; shift ;;
        -h|--help)         sed -n '2,100p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                 die_reject "неизвестный аргумент «$1»" ;;
    esac
done

[[ "$MODE" == ssh || "$MODE" == local ]] \
    || die_reject "--mode принимает ssh или local, получено «$MODE»"

# Источник по умолчанию определяется средой, а не флагом: забыть флаг легко, и
# событие с машины разработчика уехало бы в чат помеченным как пайплайновое —
# то есть соврало бы ровно про то единственное, что в нём есть про
# происхождение.
if [[ -z "$SOURCE" ]]; then
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then SOURCE=ci; else SOURCE=local; fi
fi
[[ "$SOURCE" == ci || "$SOURCE" == local ]] \
    || die_reject "source принимает ci или local, получено «$SOURCE»"

# --- проверки полей по контракту ------------------------------------------
#
# Проверяет ОБЕ стороны (§4 контракта): писатель — чтобы не собрать событие с
# мусором, читатель — потому что файл в каталог может положить кто угодно из
# тех, кто и так катит прод. Здесь отказ громкий: событие с кривым полем не
# доедет до чата ни в каком виде, и молча выбросить его нельзя.

case "$KIND" in
    started|success|failure|rolled_back|rollback|published) ;;
    "") die_reject "не задан --kind" ;;
    *)  die_reject "недопустимый kind «$KIND» (см. §4 docs/events.md)" ;;
esac

[[ -n "$APP" ]] || die_reject "не задан --app"
# Тот же набор, что у имени каталога релиза: `app` попадает в ИМЯ ФАЙЛА, и это
# единственное, что стоит между строкой из описания цели и записью в соседний
# каталог.
[[ "$APP" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] \
    || die_reject "app «$APP» не подходит под ^[a-z0-9][a-z0-9._-]{0,63}\$"

if [[ -n "$STAGE" ]]; then
    case "$STAGE" in
        gates|preflight|upload|switch|units|health|version|neighbours) ;;
        *) die_reject "недопустимый stage «$STAGE» (см. §7 docs/events.md)" ;;
    esac
fi
if [[ -n "$REASON" ]]; then
    case "$REASON" in
        units_failed|nginx_failed|health_failed|verify_failed|version_mismatch|neighbours_failed|manual) ;;
        *) die_reject "недопустимый reason «$REASON» (см. §7 docs/events.md)" ;;
    esac
fi

# Обязательность по видам — таблица §4. Проверяется здесь, а не «как-нибудь у
# читателя»: событие без stage у provала показывать нечем, а stage у success —
# признак того, что вызывающая сторона перепутала вид.
case "$KIND" in
    started)
        [[ -z "$STAGE$REASON" ]] || die_reject "у kind=started не бывает stage и reason" ;;
    success|published)
        [[ -n "$VERSION" ]] || die_reject "у kind=$KIND обязателен --version"
        [[ -z "$STAGE$REASON" ]] || die_reject "у kind=$KIND не бывает stage и reason" ;;
    failure)
        [[ -n "$STAGE" ]] || die_reject "у kind=failure обязателен --stage"
        [[ -z "$REASON" ]] || die_reject "у kind=failure не бывает reason" ;;
    rolled_back)
        [[ -n "$VERSION" ]] || die_reject "у kind=rolled_back обязателен --version"
        [[ -n "$STAGE" ]]   || die_reject "у kind=rolled_back обязателен --stage"
        [[ -n "$REASON" ]]  || die_reject "у kind=rolled_back обязателен --reason" ;;
    rollback)
        [[ -n "$VERSION" ]] || die_reject "у kind=rollback обязателен --version (релиз, НА который откатились)"
        [[ -z "$STAGE" ]]   || die_reject "у kind=rollback не бывает stage"
        REASON=manual ;;
esac

# Длина в символах и в байтах считается отдельно (§8): кириллическая буква —
# один символ и два байта, и потолок «120 символов» без байтового означал бы
# 480 байт на четырёхбайтовых символах.
#
# Символы считаются по байтам с вычетом продолжений UTF-8 (0x80…0xBF), а не
# через ${#s}: длина строки в bash зависит от локали, а в Git Bash её обычно
# нет вовсе — там ${#s} дал бы байты, и кириллица съела бы потолок вдвое.
blen() { local LC_ALL=C; printf '%s' "${#1}"; }
clen() {
    local LC_ALL=C cont
    cont="$(printf '%s' "$1" | tr -dc '\200-\277' | wc -c)"
    printf '%s' $(( ${#1} - cont ))
}

# Управляющие символы и U+202E вырезаются у писателя, хотя вырезает их и
# читатель. Здесь это дешевле и честнее: `CR`/`LF` подделывают строки journald,
# а U+202E переворачивает направление текста и показывает в чате не то, что
# написано. Событие с таким символом внутри — не повод его потерять, поэтому
# отказа тут нет, есть чистка.
sanitize() {
    local LC_ALL=C
    printf '%s' "$1" | tr -d '\000-\037\177' | sed 's/\xe2\x80\xae//g'
}

# Обрезка по обоим потолкам сразу, без разрезания символа UTF-8 пополам.
trim_field() { # trim_field <строка> <макс_символов> <макс_байт>
    local LC_ALL=C s="$1" maxc="$2" maxb="$3" n
    while (( ${#s} > maxb )); do s="${s%?}"; done
    # Хвост мог остаться недописанным символом: снимаем продолжения, а за ними
    # ведущий байт — иначе в JSON уедет обрубок последовательности.
    if (( ${#s} == maxb )); then
        while [[ -n "$s" && "${s: -1}" == [$'\x80'-$'\xbf'] ]]; do s="${s%?}"; done
        [[ -n "$s" && "${s: -1}" == [$'\xc0'-$'\xff'] ]] && s="${s%?}"
    fi
    n="$(clen "$s")"
    while (( n > maxc )); do
        while [[ -n "$s" && "${s: -1}" == [$'\x80'-$'\xbf'] ]]; do s="${s%?}"; done
        s="${s%?}"
        n=$(( n - 1 ))
    done
    printf '%s' "$s"
}

APP="$(sanitize "$APP")"
VERSION="$(sanitize "$VERSION")"
PREVIOUS="$(sanitize "$PREVIOUS")"

for pair in "версия:$VERSION" "предыдущая версия:$PREVIOUS"; do
    v="${pair#*:}"; [[ -n "$v" ]] || continue
    (( $(blen "$v") <= 128 )) || die_reject "${pair%%:*} длиннее 128 байт"
    [[ "$v" =~ ^[A-Za-z0-9._+-]+$ ]] \
        || die_reject "${pair%%:*} «$v»: допустимы только буквы, цифры и «._+-»"
done

# Адрес принимается только https:// и только известного хоста (§4). Не прошедший
# проверку — не повод потерять событие: поле выбрасывается, и версия в сообщении
# остаётся обычным текстом, ровно как при отсутствии ссылки. Иначе выкатка
# кладёт в чат ссылку от имени бота, которому владелец доверяет по определению.
check_url() { # check_url <имя поля> <значение> → печатает принятое или ничего
    local what="$1" u; u="$(sanitize "$2")"
    [[ -n "$u" ]] || return 0
    if (( $(blen "$u") > 300 )); then warn "$what длиннее 300 байт — поле выброшено"; return 0; fi
    if [[ "$u" != https://github.com/* ]]; then
        warn "$what не https://github.com/… — поле выброшено"
        return 0
    fi
    printf '%s' "$u"
}
COMMIT_URL="$(check_url commitURL "$COMMIT_URL")"
RUN_URL="$(check_url runURL "$RUN_URL")"

# runURL при source=local запрещён контрактом: прогона нет, и ссылка «на
# прогон» с машины разработчика может вести только куда-то не туда.
if [[ "$SOURCE" == local && -n "$RUN_URL" ]]; then
    warn "runURL при source=local не бывает — поле выброшено"
    RUN_URL=""
fi

# --- список изменений ------------------------------------------------------
#
# Разметку не возит никто (§4): bin/changelog отдаёт готовый кусок HTML, а в
# событии обязан лежать простой текст. Иначе бот получает недоверенный HTML,
# который ему нельзя ни экранировать (сломается разметка), ни не экранировать
# (это дыра). Приведение живёт ЗДЕСЬ, а не у трёх вызывающих сторон: три
# независимые нормализации одного формата разъедутся молча, как разъехались
# пять копий отправки в Telegram.
CHANGELOG=()
read_changelog() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(sanitize "$line")"
        [[ -n "${line//[[:space:]]/}" ]] || continue
        (( ${#CHANGELOG[@]} < 20 )) || break
        CHANGELOG+=("$(trim_field "$line" 120 512)")
    done
}

if [[ -n "$CL_HTML" ]]; then
    [[ -f "$CL_HTML" ]] || die_reject "не найден файл списка изменений: $CL_HTML"
    # Шаги ровно те, что перечислены в §4 контракта, и в том же порядке.
    # `&amp;` разворачивается последним: сделай наоборот — и «&amp;lt;» из темы
    # коммита превратится в «<», то есть в разметку там, где её не было.
    read_changelog < <(
        sed -e '/<b>Изменения<\/b>/d' \
            -e '/^…и ещё /d' \
            -e 's/^• //' \
            -e 's/<a href="[^"]*">\([^<]*\)<\/a>/\1/g' \
            -e 's/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g' "$CL_HTML"
    )
elif [[ -n "$CL_FILE" ]]; then
    [[ -f "$CL_FILE" ]] || die_reject "не найден файл списка изменений: $CL_FILE"
    read_changelog < "$CL_FILE"
fi

# --- время, id и группа ----------------------------------------------------

# Миллисекунды. `%3N` есть у GNU date (Linux и Git Bash), у BSD его нет — там
# он приезжает буквально, и это ловится проверкой, а не превращается в имя
# файла «1785924102%3N-…».
now_ms() {
    local ms; ms="$(date -u +%s%3N 2>/dev/null || true)"
    [[ "$ms" =~ ^[0-9]{13,}$ ]] || ms="$(( $(date -u +%s) * 1000 ))"
    printf '%s' "$ms"
}

sha256_hex() {
    local out
    if command -v sha256sum >/dev/null 2>&1; then
        out="$(printf '%s' "$1" | sha256sum)"; out="${out%% *}"
    elif command -v shasum >/dev/null 2>&1; then
        out="$(printf '%s' "$1" | shasum -a 256)"; out="${out%% *}"
    elif command -v openssl >/dev/null 2>&1; then
        # openssl печатает «SHA256(stdin)= <хеш>» — здесь нужен последний столбец,
        # а у sha256sum первый: перепутать их значит получить «-» вместо хеша.
        out="$(printf '%s' "$1" | openssl dgst -sha256)"; out="${out##* }"
    else
        die "нет ни sha256sum, ни shasum, ни openssl — id события посчитать нечем"
    fi
    printf '%s' "$out" | tr -d ' \r\n'
}

EVENT_MS="$(now_ms)"
[[ "$EVENT_MS" =~ ^[0-9]{13}$ ]] || die "часы машины дали «$EVENT_MS», а имя файла требует ровно 13 цифр"
AT="${AT:-$(date -u -d "@$(( EVENT_MS / 1000 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)}"
[[ "$AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || die_reject "at «$AT» не RFC3339 UTC вида 2026-08-05T10:01:42Z"

HOSTNAME_="$(hostname 2>/dev/null || echo unknown)"
PID_="${DK_RUN_PID:-$$}"

# `id` считается по-разному, а выглядит одинаково — 64 hex (§5). Для CI он
# известен здесь: repo, run_id и attempt в job'е есть всегда. Для локальной
# выкатки в прообраз входят миллисекунды ИМЕНИ ФАЙЛА, а имя раздаёт писатель
# под замком — поэтому id туда уезжает местом-заготовкой, вместе с прообразом
# без первого поля.
ID_MODE=fixed
ID_SEED=""
EVENT_ID=""
if [[ "$SOURCE" == ci ]]; then
    : "${GITHUB_REPOSITORY:?source=ci, но нет GITHUB_REPOSITORY}"
    : "${GITHUB_RUN_ID:?source=ci, но нет GITHUB_RUN_ID}"
    RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}"
    EVENT_ID="$(sha256_hex "$GITHUB_REPOSITORY|$GITHUB_RUN_ID|$RUN_ATTEMPT|$APP|$KIND")"
    [[ -z "$GROUP" ]] && GROUP="$(sha256_hex "$GITHUB_REPOSITORY|$GITHUB_RUN_ID|$RUN_ATTEMPT")"
else
    ID_MODE=local
    ID_SEED="$HOSTNAME_|$PID_"
    EVENT_ID="__ID__"
    if [[ -z "$GROUP" ]]; then
        # Прогон локально — это ОДИН вызов `dk deploy`, включая `dk deploy
        # --all`. Момент запуска команды и её pid обязана выставить сама
        # команда: `dk` зовёт bin/deploy отдельным процессом на каждую цель, и
        # взятые здесь `$$` с «сейчас» дали бы по группе на цель.
        if [[ -z "${DK_RUN_STARTED_MS:-}" || -z "${DK_RUN_PID:-}" ]]; then
            warn "нет DK_RUN_STARTED_MS/DK_RUN_PID — группой прогона считается этот вызов"
        fi
        GROUP="$(sha256_hex "${DK_RUN_STARTED_MS:-$EVENT_MS}|$HOSTNAME_|$PID_")"
    fi
fi
[[ "$GROUP" =~ ^[0-9a-f]{64}$ ]] || die_reject "group «$GROUP» не 64 hex"

# --- сборка события --------------------------------------------------------
#
# Экранирование посимвольное, без sed и без ${s//…/…}: сюда приезжают темы
# коммитов, то есть чужой текст с кавычками и обратными слэшами, а в bash 5.2+
# `&` в строке замены значит «то, что совпало» — одна и та же строка на раннере
# и на машине разработчика экранировалась бы по-разному. Функция та же, что в
# bin/deploy для version.json, и по той же причине.
json_escape() {
    local s="$1" out="" n i ch code hex
    n=${#s}
    for (( i = 0; i < n; i++ )); do
        ch="${s:i:1}"
        case "$ch" in
            '"')   out+='\"'  ;;
            '\')   out+='\\'  ;;
            $'\n') out+='\n'  ;;
            $'\r') out+='\r'  ;;
            $'\t') out+='\t'  ;;
            $'\b') out+='\b'  ;;
            $'\f') out+='\f'  ;;
            *)
                printf -v code '%d' "'$ch"
                if (( code >= 0 && code < 32 )); then
                    printf -v hex '%04x' "$code"
                    out+="\\u$hex"
                else
                    out+="$ch"
                fi
                ;;
        esac
    done
    printf '%s' "$out"
}

# Порядок ключей — порядок таблицы §4 контракта и образцов docs/events/*.json.
# Необязательное поле ОТСУТСТВУЕТ, а не приходит пустым: «previous»: "" читается
# как «предыдущей версии нет», а это не то же самое, что «не удалось вычислить».
build_event() { # build_event [с_изменениями]
    local with_cl="${1:-1}" i n
    local -a L=()
    L+=('  "v": 1')
    L+=("$(printf '  "id": "%s"' "$EVENT_ID")")
    L+=("$(printf '  "kind": "%s"' "$KIND")")
    L+=("$(printf '  "app": "%s"' "$APP")")
    L+=("$(printf '  "at": "%s"' "$AT")")
    L+=("$(printf '  "source": "%s"' "$SOURCE")")
    L+=("$(printf '  "group": "%s"' "$GROUP")")
    L+=('  "groupSeq": __GROUPSEQ__')
    [[ -n "$VERSION" ]]  && L+=("$(printf '  "version": "%s"' "$(json_escape "$VERSION")")")
    [[ -n "$PREVIOUS" ]] && L+=("$(printf '  "previous": "%s"' "$(json_escape "$PREVIOUS")")")
    [[ -n "$STAGE" ]]    && L+=("$(printf '  "stage": "%s"' "$STAGE")")
    [[ -n "$REASON" ]]   && L+=("$(printf '  "reason": "%s"' "$REASON")")
    if (( with_cl )) && (( ${#CHANGELOG[@]} )); then
        local block='  "changelog": ['
        n=${#CHANGELOG[@]}
        for (( i = 0; i < n; i++ )); do
            block+=$'\n'"$(printf '    "%s"' "$(json_escape "${CHANGELOG[i]}")")"
            (( i + 1 < n )) && block+=','
        done
        block+=$'\n''  ]'
        L+=("$block")
    fi
    [[ -n "$COMMIT_URL" ]] && L+=("$(printf '  "commitURL": "%s"' "$(json_escape "$COMMIT_URL")")")
    [[ -n "$RUN_URL" ]]    && L+=("$(printf '  "runURL": "%s"' "$(json_escape "$RUN_URL")")")

    printf '{\n'
    n=${#L[@]}
    for (( i = 0; i < n; i++ )); do
        printf '%s' "${L[i]}"
        (( i + 1 < n )) && printf ','
        printf '\n'
    done
    printf '}\n'
}

MAX_EVENT_BYTES="${DK_MAX_EVENT_BYTES:-8192}"
BODY="$(build_event 1)"

# Потолок в 8 КиБ жёсткий: читатель делает stat до чтения и файл крупнее не
# открывает вовсе — то есть событие, которое в него не влезло, не существует.
# Из всех полей раздуться может только список изменений, поэтому первым уходит
# он: список — украшение поверх выкатки, а само событие — нет. Оставшийся
# перебор потолка означает, что кто-то обошёл проверки полей выше, и это уже
# отказ, а не обрезка.
if (( $(blen "$BODY") > MAX_EVENT_BYTES )); then
    warn "событие не влезает в $MAX_EVENT_BYTES байт — список изменений выброшен"
    CHANGELOG=()
    BODY="$(build_event 0)"
fi
(( $(blen "$BODY") <= MAX_EVENT_BYTES )) \
    || die_reject "событие $(blen "$BODY") байт при потолке $MAX_EVENT_BYTES — не записано"

if (( PRINT_ONLY )); then
    printf '%s' "$BODY"
    exit 0
fi

# --- писатель на хосте -----------------------------------------------------
#
# Всё, что требует ВИДЕТЬ каталог журнала, живёт здесь и исполняется там, где
# каталог лежит: разрешение столкновений имён, номер в группе, суточный предел,
# потолок каталога, чистка старого и атомарная запись. Один и тот же текст
# уезжает по SSH и запускается локально — иначе у режимов разъехалось бы
# поведение, а проверить локальным тестом можно было бы только один из них.
read -r -d '' WRITER <<'WRITER_EOF' || true
set -uo pipefail
LC_ALL=C

dir="$1"; app="$2"; kind="$3"; ms="$4"; group="$5"; idmode="$6"; idseed="$7"; caps="$8"; b64="$9"
IFS=: read -r MAX_BYTES MAX_FILES MAX_KIB MAX_DAY TTL_DAYS <<<"$caps"

w_fail()   { printf 'писатель: %s\n' "$1" >&2; exit "${2:-1}"; }
w_reject() { w_fail "$1" 2; }

[[ -d "$dir" ]] || w_fail "нет каталога событий $dir — его заводит bin/install-server"
[[ -w "$dir" ]] || w_fail "каталог событий $dir недоступен на запись"

body="$(printf '%s' "$b64" | { base64 -d 2>/dev/null || base64 -D; })" \
    || w_fail "событие не разобралось из base64"

# Замок один на каталог: под ним идут и выбор имени, и номер в группе. Без него
# две выкатки в одну миллисекунду получили бы одно имя, а два события одной
# группы — один номер.
#
# flock есть на любом Linux, но не на любой машине разработчика; запасной замок
# через mkdir работает везде и атомарен на той же файловой системе. Терять
# событие из-за отсутствия утилиты нельзя, а тихо писать без замка — тем более.
locked=0
if command -v flock >/dev/null 2>&1; then
    exec 9>"$dir/.lock" && flock -w 30 9 && locked=1
fi
if (( ! locked )); then
    for _ in $(seq 1 300); do
        if mkdir "$dir/.lock.d" 2>/dev/null; then locked=1; break; fi
        sleep 0.1
    done
    (( locked )) && trap 'rmdir "$dir/.lock.d" 2>/dev/null || true' EXIT
fi
(( locked )) || w_fail "не дождались замка на $dir за 30 с"

shopt -s nullglob

# Чистка перед записью — по ИМЕНИ, а не по mtime (§11): mtime переживает `cp -a`
# и меняется от `touch`, а первые 13 цифр имени — то же время, которое видит
# курсор читателя. Чистит писатель: читателю права на удаление не даются вовсе.
cutoff=$(( ms - TTL_DAYS * 86400000 ))
for f in "$dir"/[0-9]*.json "$dir"/.groups/*; do
    b="${f##*/}"
    if [[ "$f" == */.groups/* ]]; then
        # Счётчики групп живут по тому же сроку, но времени в имени у них нет —
        # тут mtime единственное, что есть, и ошибиться им не страшно: потеря
        # счётчика стоит сбитого номера, а не события.
        [[ -n "$(find "$f" -maxdepth 0 -mtime +"$TTL_DAYS" 2>/dev/null)" ]] && rm -f -- "$f"
        continue
    fi
    [[ "$b" =~ ^[0-9]{13}- ]] || continue
    (( 10#${b:0:13} < cutoff )) && rm -f -- "$f"
done

files=( "$dir"/[0-9]*.json )
(( ${#files[@]} < MAX_FILES )) \
    || w_reject "в каталоге $dir уже ${#files[@]} событий при потолке $MAX_FILES — событие не записано"

kib="$(du -sk "$dir" 2>/dev/null | awk '{print $1; exit}')"
[[ "$kib" =~ ^[0-9]+$ ]] || kib=0
(( kib < MAX_KIB )) \
    || w_reject "каталог $dir занимает ${kib} КиБ при потолке $MAX_KIB — событие не записано"

# Суточный предел — по календарным суткам UTC и по каждой цели отдельно.
# Журнал лежит на разделе с данными агента: цикл, крутящий выкатку в ошибке, не
# должен иметь возможности положить наблюдение за продом.
day=$(( ms / 86400000 ))
today=0
# Имя разбирается ПО ЧАСТЯМ, а не регулярным выражением с подставленным
# именем цели. Регулярка тут была ошибкой дважды: точка в имени разрешена
# (`^[a-z0-9][a-z0-9._-]{0,63}$`) и значит в ней «любой символ», так что цель
# `status.samoy.love` считала бы своими события `status-samoy-love`; а имя
# цели вообще не место подставлять в шаблон, по которому потом решается,
# писать событие или отказать по суточному пределу.
#
# Разбор точный: 13 цифр, дефис, имя цели, дефис, вид, «.json». Лишний дефис
# в остатке значит, что это событие ДРУГОЙ цели с более длинным именем, —
# ровно так `chillhub-admin` считал бы своими события `chillhub-admin-ui`.
for f in "$dir"/[0-9]*-"$app"-*.json; do
    b="${f##*/}"
    [[ "$b" =~ ^[0-9]{13}- ]] || continue
    [[ "$b" == *.json ]] || continue
    mid="${b:14}"; mid="${mid%.json}"
    [[ "$mid" == "$app-"* ]] || continue
    kind_part="${mid#"$app-"}"
    case "$kind_part" in
        ''|*-*|*[!a-z_]*) continue ;;
    esac
    (( 10#${b:0:13} / 86400000 == day )) && today=$(( today + 1 ))
done
(( today < MAX_DAY )) \
    || w_reject "за сутки у цели $app уже $today событий при потолке $MAX_DAY — событие не записано"

sha() {
    if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1;    then printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
    else printf '%s' "$1" | openssl dgst -sha256 | sed 's/.* //'
    fi
}

# Имя занято — сдвигаем миллисекунду вперёд (§2). Настоящее время события лежит
# в поле `at`, а имя — ключ сортировки, и смещение на миллисекунду не искажает
# ничего.
#
# Сначала, впрочем, проверяется другое: не наш ли это собственный повтор.
# Транспорт делает три попытки, и оборваться связь могла ПОСЛЕ записи. Тогда в
# каталоге лежит файл с тем же именем, той же группой и тем же `at` — писать
# рядом второй значит показать выкатку в чате дважды.
at_line="$(printf '%s' "$body" | sed -n 's/^  "at": "\([^"]*\)".*/\1/p' | head -1)"
[[ -n "$at_line" ]] || w_fail "в событии нет поля at — писать такое нельзя"

name="$ms-$app-$kind.json"
while [[ -e "$dir/$name" ]]; do
    if grep -qF "\"group\": \"$group\"" "$dir/$name" 2>/dev/null \
    && grep -qF "\"at\": \"$at_line\"" "$dir/$name" 2>/dev/null; then
        printf '%s\n' "$name"
        exit 0
    fi
    ms=$(( ms + 1 ))
    name="$ms-$app-$kind.json"
done

# Номер в группе. Счётчики лежат в .groups/: точка в начале имени выводит их
# из-под шаблона имени события, поэтому для читателя их не существует.
mkdir -p "$dir/.groups" 2>/dev/null || true
seqfile="$dir/.groups/$group"
seq=0
[[ -r "$seqfile" ]] && read -r seq <"$seqfile" 2>/dev/null
[[ "$seq" =~ ^[0-9]+$ ]] || seq=0
seq=$(( seq + 1 ))
(( seq <= 10000 )) || w_reject "в группе $group уже 10000 событий — событие не записано"
printf '%s\n' "$seq" >"$seqfile" 2>/dev/null || true

if [[ "$idmode" == local ]]; then
    id="$(sha "$ms|$idseed|$app|$kind")"
    body="$(printf '%s' "$body" | sed "s/^\(  \"id\": \"\)__ID__/\1$id/")"
fi
body="$(printf '%s' "$body" | sed "s/^\(  \"groupSeq\": \)__GROUPSEQ__/\1$seq/")"

[[ "$body" != *__GROUPSEQ__* && "$body" != *__ID__* ]] \
    || w_fail "в событии остались незаполненные места — писать такое нельзя"
(( ${#body} <= MAX_BYTES )) \
    || w_reject "событие ${#body} байт при потолке $MAX_BYTES — не записано"

# Атомарная запись (§3). `.tmp` пишется в тот же каталог: rename атомарен
# только внутри одной файловой системы, а через /tmp это уже копирование.
tmp="$dir/$name.tmp"
printf '%s\n' "$body" >"$tmp" || w_fail "не записать $tmp"
# fsync до rename — не педантизм: без него после выключения питания в каталоге
# останется имя, за которым нули. Сообщение о выкатке стоит одного fsync.
sync -d "$tmp" 2>/dev/null || sync 2>/dev/null || true
chmod 0640 "$tmp" 2>/dev/null || true
mv -f -- "$tmp" "$dir/$name" || { rm -f -- "$tmp"; w_fail "не переименовать во что-то видимое читателю"; }

printf '%s\n' "$name"
WRITER_EOF

CAPS="$MAX_EVENT_BYTES:${DK_MAX_DIR_FILES:-5000}:${DK_MAX_DIR_KIB:-32768}:${DK_MAX_DAY_EVENTS:-200}:${DK_EVENT_TTL_DAYS:-14}"
B64="$(printf '%s' "$BODY" | base64 | tr -d '\r\n')"
WRITER_ARGS=("$EVENTS_DIR" "$APP" "$KIND" "$EVENT_MS" "$GROUP" "$ID_MODE" "$ID_SEED" "$CAPS" "$B64")

# --- ключ ------------------------------------------------------------------
#
# Ключ — тот же, которым идёт выкатка: канал уже есть и уже доверен, нового
# доступа событие не открывает. Приехать он может файлом (машина разработчика)
# или содержимым в переменной (CI, где файла нет вовсе). Во втором случае файл
# заводится здесь с правами 600 и стирается в ЛЮБОМ исходе — в том числе при
# die и при Ctrl-C, поэтому уборка висит на ловушке, а не идёт последней
# строкой.
KEY_TMP=""
KNOWN_HOSTS_TMP=""
# `return 0` в конце — не украшение: код возврата ловушки EXIT становится кодом
# возврата скрипта, и уборка, которой нечего убирать, объявила бы удачную
# доставку неудачной.
cleanup() {
    [[ -n "$KEY_TMP" ]] && rm -f -- "$KEY_TMP"
    [[ -n "$KNOWN_HOSTS_TMP" ]] && rm -f -- "$KNOWN_HOSTS_TMP"
    return 0
}
trap cleanup EXIT INT TERM

deliver_local() {
    printf '%s' "$WRITER" | bash -s -- "${WRITER_ARGS[@]}"
}

deliver_ssh() {
    local -a ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10)
    [[ -n "$KEY" ]] && ssh_opts+=(-i "$KEY" -o IdentitiesOnly=yes)
    [[ -n "${KNOWN_HOSTS_TMP:-}" ]] && ssh_opts+=(-o UserKnownHostsFile="$KNOWN_HOSTS_TMP")
    # Писатель уезжает stdin'ом, а его аргументы — командной строкой: событие в
    # них едет base64, поэтому кавычек, переводов строк и юникода в командной
    # строке чужого шелла не оказывается вовсе.
    printf '%s' "$WRITER" \
        | ssh "${ssh_opts[@]}" "$USER_@$HOST" "bash -s -- $(printf '%q ' "${WRITER_ARGS[@]}")"
}

if [[ "$MODE" == ssh ]]; then
    need_cmd ssh
    [[ -n "$HOST" ]] || die_reject "режим ssh, но нет --host/DEPLOY_HOST"
    if [[ -n "${DK_SSH_KEY:-}" ]]; then
        # mktemp создаёт файл сразу с правами 600 — важно, что именно СОЗДАЁТ:
        # `touch` + `chmod` оставили бы окно, в которое ключ выкатки читается
        # любым локальным пользователем (на раннере — любым другим шагом job'а).
        # chmod ниже — страховка на случай экзотического mktemp, а не основной
        # механизм.
        KEY_TMP="$(mktemp -t dk-notify-key-XXXXXXXX)" || die "не создать временный файл под ключ"
        chmod 600 "$KEY_TMP" 2>/dev/null || true
        printf '%s\n' "$DK_SSH_KEY" >"$KEY_TMP" || die "не записать ключ во временный файл"
        KEY="$KEY_TMP"
    fi
    [[ -z "$KEY" || -r "$KEY" ]] || die "ключ выкатки недоступен на чтение"
    if [[ -n "${DK_SSH_KNOWN_HOSTS:-}" ]]; then
        KNOWN_HOSTS_TMP="$(mktemp -t dk-notify-kh-XXXXXXXX)" || die "не создать временный known_hosts"
        printf '%s\n' "$DK_SSH_KNOWN_HOSTS" >"$KNOWN_HOSTS_TMP"
    fi
fi

# --- доставка с повторами ---------------------------------------------------

# Разбиение по пробелам здесь и нужно: паузы задаются одной переменной
# окружения («2 5»), потому что через окружение их передаёт и действие CI, и
# тест, которому пауза в семь секунд на каждый отказ ни к чему.
# shellcheck disable=SC2206
SLEEPS=(${DK_NOTIFY_SLEEPS:-2 5})
ATTEMPTS=$(( ${#SLEEPS[@]} + 1 ))
OUT=""; RC=0
for (( a = 1; a <= ATTEMPTS; a++ )); do
    RC=0
    if [[ "$MODE" == local ]]; then
        OUT="$(deliver_local 2>&1)" || RC=$?
    else
        OUT="$(deliver_ssh 2>&1)" || RC=$?
    fi

    (( RC == 0 )) && break

    # Код 2 — отказ по контракту (потолок, кривое поле). Повторять его значит
    # ждать паузу ради того же ответа: во второй раз каталог не станет меньше.
    if (( RC == 2 )); then
        die_reject "событие $KIND/$APP отвергнуто журналом: ${OUT:-без объяснения}"
    fi

    if (( a < ATTEMPTS )); then
        warn "попытка $a из $ATTEMPTS не удалась (${OUT:-код $RC}) — повтор через ${SLEEPS[a-1]} с"
        sleep "${SLEEPS[a-1]}"
    fi
done

if (( RC != 0 )); then
    # Путь к ключу здесь не печатается ни при каком раскладе: в CI это
    # временный файл, и его имя — единственное, что стоит между чужим шагом
    # того же job'а и ключом выкатки.
    die "событие $KIND/$APP не доставлено за $ATTEMPTS попытки: ${OUT:-код $RC}"
fi

log "событие $KIND/$APP доставлено: ${OUT##*$'\n'}"
