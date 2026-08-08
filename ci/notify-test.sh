#!/usr/bin/env bash
# Прогон lib/notify.sh по поддельному журналу и поддельному серверу.
#
#   ci/notify-test.sh [путь к lib/notify.sh]
#
# ЗАЧЕМ ЭТОТ ФАЙЛ. Событие выкатки — единственный канал, по которому владелец
# узнаёт о провале. Форма события описана в docs/events.md и разбирается вторым
# концом на Go: разъехаться эти два конца могут молча и полностью, потому что
# зелёные тесты есть у каждого по отдельности, а стык не проверяет никто —
# ровно та история, ради которой написан ci/contract-test.sh.
#
# Проверяется поэтому не «функция работает», а четыре обещания транспорта:
#
#   1. собранное событие — валидный JSON и совпадает с golden-образцом по
#      набору полей, а `id` и `group` — настоящие sha256 от прообразов §5 и §6
#      (тест ИХ ПЕРЕСЧИТЫВАЕТ, а не сверяет с константой в своём коде: константа
#      разъедется с контрактом так же тихо, как разъехались бы обе стороны);
#   2. недоставленное не выглядит доставленным: недоступный приёмник — это
#      ненулевой код, `::error::` и внятная причина, а не молчаливый ноль;
#   3. потолок — отказ, а не запись: событие сверх предела не появляется в
#      каталоге ВООБЩЕ, потому что читатель крупный файл не открывает и такое
#      событие не существовало бы, но выглядело бы записанным;
#   4. имя файла соответствует шаблону и сортируется хронологически — на этом
#      держится курсор читателя, и три выкатки в одну миллисекунду обязаны дать
#      три разных возрастающих имени.
#
# СЕРВЕРА НЕТ. Режим local пишет прямо в каталог, режим ssh идёт через стаб ssh
# в PATH: настоящий хост в тест не приезжает никогда, ни адресом, ни ключом.
# Часы тоже подменяются стабом `date` — иначе столкновение по миллисекунде
# воспроизводится только удачей, а именно оно и опасно.
#
# Тест обязан работать в Git Bash под Windows: там нет ни jq, ни настоящих прав
# на файлы. Отсутствие jq/node/python НЕ повод молча зазеленеть — такие случаи
# считаются отдельно и печатаются с объяснением; на раннере они есть.

set -uo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTIFY="${1:-$KIT/lib/notify.sh}"
GOLDEN="$KIT/docs/events"

for f in "$NOTIFY" "$GOLDEN/example-success.json" "$GOLDEN/example-failure.json" \
         "$GOLDEN/example-rolled-back.json"; do
    [[ -f "$f" ]] || { echo "не найден: $f" >&2; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0; skipped=0
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$(( pass + 1 )); }
bad()   { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; fail=$(( fail + 1 )); }
skip()  { printf '  \033[33m—\033[0m %s\n' "$*"; skipped=$(( skipped + 1 )); }
case_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

same()  { [[ "$2" == "$3" ]] && ok "$1" || bad "$1: ожидали «$3», получили «$2»"; }
has()   { grep -qF -- "$2" "$OUT" && ok "$1" || bad "$1 (нет «$2» в выводе)"; }
hasnt() { grep -qF -- "$2" "$OUT" && bad "$1 (в выводе есть «$2»)" || ok "$1"; }

# --------------------------------------------------------------------------
# СТАБЫ. Оба лежат в PATH перед настоящими: notify.sh зовёт `ssh` и `date` по
# имени, и подменять их изнутри скрипта переменной значило бы проверять не тот
# код, который поедет на раннер.
mkdir -p "$TMP/bin"

# ssh: пишет свои аргументы в лог, при желании сохраняет права ключа и выходит
# заданным кодом. 255 — то, чем настоящий ssh отвечает на недоступный хост.
cat >"$TMP/bin/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SSH_LOG"
key=""
while (( $# )); do [[ "$1" == -i ]] && { key="$2"; shift; }; shift; done
if [[ -n "$key" && -n "${KEY_REPORT:-}" ]]; then
    printf '%s %s\n' "$key" "$(stat -c %a "$key" 2>/dev/null || echo '?')" >>"$KEY_REPORT"
fi
cat >/dev/null
exit "${SSH_RC:-255}"
STUB
chmod +x "$TMP/bin/ssh"

# date: подменяются ТОЛЬКО миллисекунды события (`-u +%s%3N`), всё остальное
# уходит настоящей date. Так воспроизводится столкновение по миллисекунде —
# случай, который иначе ловится раз в год и на проде.
REAL_DATE="$(command -v date)"
cat >"$TMP/bin/date" <<STUB
#!/usr/bin/env bash
if [[ -n "\${DK_TEST_FIXED_MS:-}" && "\$*" == "-u +%s%3N" ]]; then
    printf '%s\n' "\$DK_TEST_FIXED_MS"
    exit 0
fi
exec "$REAL_DATE" "\$@"
STUB
chmod +x "$TMP/bin/date"

PATH="$TMP/bin:$PATH"
export PATH SSH_LOG="$TMP/ssh.log" SSH_RC=255 KEY_REPORT=""
: >"$SSH_LOG"

OUT="$TMP/out"
RC=0
DIR=""

# Каждый случай получает свой каталог журнала: остаток от предыдущего случая
# иначе считается суточным пределом и «объясняет» чужой отказ.
new_dir() { DIR="$TMP/events.$1"; rm -rf "$DIR"; mkdir -p "$DIR"; }

# Один вызов транспорта. Паузы между попытками обнулены: проверяется их число,
# а не длительность, и тест не должен стоять семь секунд на каждом отказе.
run() {
    RC=0
    env DK_NOTIFY_SLEEPS="0 0" "$@" >"$OUT" 2>&1 || RC=$?
}

# Вызов в режиме local, как его делает release.sh с самого хоста.
run_local() { run bash "$NOTIFY" --mode local --events-dir "$DIR" "$@"; }

# Вызов из пайплайна: source=ci берётся из окружения GitHub, как в настоящем job'е.
run_ci() {
    run env GITHUB_ACTIONS=true \
        GITHUB_REPOSITORY="${REPO:-tr0llex/snakes}" \
        GITHUB_RUN_ID="${RUN_ID:-16542330981}" \
        GITHUB_RUN_ATTEMPT="${RUN_ATTEMPT:-1}" \
        bash "$NOTIFY" --mode local --events-dir "$DIR" "$@"
}

# Единственное событие в каталоге — иначе утверждения ниже проверяли бы то,
# что случайно оказалось первым по алфавиту.
only_event() {
    local -a f
    shopt -s nullglob
    f=("$DIR"/[0-9]*.json)
    shopt -u nullglob
    (( ${#f[@]} == 1 )) || { printf ''; return 1; }
    printf '%s' "${f[0]}"
}

keys_of() { sed -n 's/^  "\([A-Za-z]*\)".*/\1/p' "$1" | sort | tr '\n' ' '; }

sha_of() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

field() { sed -n "s/^  \"$2\": \"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}\$/\1/p" "$1" | head -1; }

# Валидность JSON проверяется чужим разборщиком, а не глазами: событие читает
# encoding/json на той стороне, и «выглядит как JSON» там не считается.
JSON_TOOL=""
if command -v jq >/dev/null 2>&1; then JSON_TOOL=jq
elif command -v node >/dev/null 2>&1; then JSON_TOOL=node
elif command -v python3 >/dev/null 2>&1 && python3 -c '' 2>/dev/null; then JSON_TOOL=python3
fi
json_valid() {
    case "$JSON_TOOL" in
        jq)      jq -e . "$1" >/dev/null 2>&1 ;;
        node)    node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$1" 2>/dev/null ;;
        python3) python3 -c 'import json,sys;json.load(open(sys.argv[1],encoding="utf-8"))' "$1" 2>/dev/null ;;
        *)       return 2 ;;
    esac
}
check_json() { # check_json <файл> <подпись>
    json_valid "$1"
    case $? in
        0) ok "$2: валидный JSON" ;;
        2) skip "$2: валидность JSON не проверена — нет ни jq, ни node, ни python3" ;;
        *) bad "$2: разборщик не принял файл" ;;
    esac
}

# Список изменений передаётся ОБЫЧНЫМ файлом, а не подстановкой процесса:
# notify.sh требует именно файл (`[[ -f ]]`), и это осознанно — читать канал он
# не станет, потому что канал нельзя перечитать при повторе.
CL_SUCCESS="$TMP/cl-success"
printf '%s\n' \
    'Не выдавать недоставленное уведомление за успех' \
    'Считать пропавший файл ошибкой обновления' \
    'Починить обрыв скачивания больших файлов #21' >"$CL_SUCCESS"
CL_ROLLED="$TMP/cl-rolled"
printf '%s\n' 'Показывать пересадки в ночном расписании' >"$CL_ROLLED"

# --------------------------------------------------------------------------
case_ "Событие из пайплайна совпадает с образцом docs/events/example-success.json"

new_dir success
REPO=tr0llex/snakes RUN_ID=16542330981 RUN_ATTEMPT=1 run_ci \
    --kind success --app snakes \
    --version release-20260805-130115-1a2b3c4 \
    --previous release-20260804-221407-9f8e7d6 \
    --commit-url 'https://github.com/tr0llex/snakes/commit/1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d' \
    --run-url 'https://github.com/tr0llex/snakes/actions/runs/16542330981/attempts/1' \
    --changelog-file "$CL_SUCCESS"

same "код возврата" "$RC" "0"
EV="$(only_event)"
if [[ -n "$EV" ]]; then
    ok "событие записано: ${EV##*/}"
    check_json "$EV" "success"
    same "набор полей как в образце" "$(keys_of "$EV")" "$(keys_of "$GOLDEN/example-success.json")"
    # sha256 пересчитывается ЗДЕСЬ по прообразу из §5/§6 — не сверяется с
    # константой и не берётся из образца готовым.
    same "id = sha256(repo|run_id|attempt|app|kind)" \
        "$(field "$EV" id)" "$(sha_of 'tr0llex/snakes|16542330981|1|snakes|success')"
    same "group = sha256(repo|run_id|attempt)" \
        "$(field "$EV" group)" "$(sha_of 'tr0llex/snakes|16542330981|1')"
    same "v" "$(field "$EV" v)" "1"
    same "source" "$(field "$EV" source)" "ci"
    same "groupSeq первого события группы" "$(field "$EV" groupSeq)" "1"
    same "пунктов changelog" "$(grep -c '^    "' "$EV")" "3"
else
    bad "событие не записано (rc=$RC): $(head -2 "$OUT")"
fi

# --------------------------------------------------------------------------
case_ "Провал на гейтах: версии ещё нет, стадия обязательна"

new_dir failure
REPO=tr0llex/chillhub RUN_ID=16542331744 RUN_ATTEMPT=2 run_ci \
    --kind failure --app chillhub-site --stage gates \
    --commit-url 'https://github.com/tr0llex/chillhub/commit/7f8e9d0c1b2a394857661a2b3c4d5e6f708192a3' \
    --run-url 'https://github.com/tr0llex/chillhub/actions/runs/16542331744/attempts/2'

same "код возврата" "$RC" "0"
EV="$(only_event)"
if [[ -n "$EV" ]]; then
    check_json "$EV" "failure"
    same "набор полей как в образце" "$(keys_of "$EV")" "$(keys_of "$GOLDEN/example-failure.json")"
    same "id = sha256(repo|run_id|attempt|app|kind)" \
        "$(field "$EV" id)" "$(sha_of 'tr0llex/chillhub|16542331744|2|chillhub-site|failure')"
else
    bad "событие не записано (rc=$RC): $(head -2 "$OUT")"
fi

# stage у failure обязателен, и без него событие не пишется вовсе: показывать
# провал нечем, а «провалилось непонятно где» — это тот же дефект, что молчание.
new_dir failure-nostage
run_ci --kind failure --app chillhub-site
same "без stage у failure — отказ" "$(( RC != 0 ))" "1"
same "и ничего не записано" "$(ls -A "$DIR"/[0-9]*.json 2>/dev/null | wc -l)" "0"
has "названа причина отказа" "stage"

# --------------------------------------------------------------------------
case_ "Автооткат с машины: локальные id и group считаются от прогона, а не от события"

new_dir rolled
MS_EVENT=1785925215123
MS_RUN=1785925180000
HOSTN="$(hostname 2>/dev/null || echo unknown)"
run env DK_TEST_FIXED_MS="$MS_EVENT" DK_RUN_STARTED_MS="$MS_RUN" DK_RUN_PID=31415 \
    DK_NOTIFY_SLEEPS="0 0" \
    bash "$NOTIFY" --mode local --events-dir "$DIR" --source local \
    --kind rolled_back --app metro \
    --version manual-20260805-131944-c4d5e6f \
    --previous manual-20260803-201155-b1a2c3d \
    --stage health --reason health_failed \
    --commit-url 'https://github.com/tr0llex/metro-map/commit/c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7' \
    --changelog-file "$CL_ROLLED"

same "код возврата" "$RC" "0"
EV="$(only_event)"
if [[ -n "$EV" ]]; then
    check_json "$EV" "rolled_back"
    same "набор полей как в образце" "$(keys_of "$EV")" "$(keys_of "$GOLDEN/example-rolled-back.json")"
    # Прообразы РАЗНЫЕ по миллисекундам: id считан от момента события, group —
    # от момента запуска dk deploy. Тест, подставивший одно число в оба, сошёлся
    # бы с контрактом только случайно.
    same "id = sha256(ms события|host|pid|app|kind)" \
        "$(field "$EV" id)" "$(sha_of "$MS_EVENT|$HOSTN|31415|metro|rolled_back")"
    same "group = sha256(ms запуска|host|pid)" \
        "$(field "$EV" group)" "$(sha_of "$MS_RUN|$HOSTN|31415")"
    same "source" "$(field "$EV" source)" "local"
    # Имя хоста и pid участвуют в прообразе id и group, но в файл не попадают:
    # событие уезжает в чат и кормит публичную страницу, а внутренние имена —
    # ровно то, чего там быть не должно.
    grep -qF "$HOSTN" "$EV" && bad "имя хоста уехало в событие" || ok "имени хоста в событии нет"
else
    bad "событие не записано (rc=$RC): $(head -2 "$OUT")"
fi

# --------------------------------------------------------------------------
case_ "Имя файла: шаблон, 13 цифр и хронологический порядок"

new_dir names
NAME_RE='^[0-9]{13}-[a-z0-9][a-z0-9._-]{0,63}-(started|success|failure|rolled_back|rollback|published)\.json$'

# Три события в одну миллисекунду — сценарий приёмки. Часы у всех трёх
# одинаковые, и разойтись они обязаны сами, под замком писателя.
#
# Прогоны РАЗНЫЕ (разный pid — разная группа), и это существенно: одна и та же
# цель, тот же вид, та же миллисекунда и тот же прогон — это не три выкатки, а
# одно событие, доставленное трижды, и писатель обязан узнать в нём собственный
# повтор (случай ниже). Здесь же три настоящих прогона, и файлов обязано стать
# три.
for i in 1 2 3; do
    run env DK_TEST_FIXED_MS=1785924102123 DK_NOTIFY_SLEEPS="0 0" \
        DK_RUN_STARTED_MS=1785924100000 DK_RUN_PID="77$i" \
        bash "$NOTIFY" --mode local --events-dir "$DIR" --source local \
        --kind success --app snakes --version "manual-2026080$i-101502-1a2b3c4"
    (( RC == 0 )) || bad "событие $i не записано: $(head -2 "$OUT")"
done

mapfile -t NAMES < <(cd "$DIR" && ls [0-9]*.json 2>/dev/null)
same "три события в одну миллисекунду — три файла" "${#NAMES[@]}" "3"
BADNAME=0
for n in "${NAMES[@]}"; do [[ "$n" =~ $NAME_RE ]] || BADNAME=1; done
same "все имена по шаблону читателя" "$BADNAME" "0"

# Лексикографический порядок обязан совпасть с хронологическим: на нём и только
# на нём держится курсор приёмника.
SORTED="$(printf '%s\n' "${NAMES[@]}" | LC_ALL=C sort | tr '\n' ' ')"
LISTED="$(cd "$DIR" && LC_ALL=C ls [0-9]*.json | tr '\n' ' ')"
same "порядок в каталоге совпадает с лексикографическим" "$LISTED" "$SORTED"
same "имена не повторяются" "$(printf '%s\n' "${NAMES[@]}" | sort -u | wc -l)" "3"
same "миллисекунды разошлись на единицу" \
    "$(printf '%s\n' "${NAMES[@]}" | LC_ALL=C sort | sed -n '3p' | cut -c1-13)" "1785924102125"

# Тот же прогон, тот же вид, та же миллисекунда — это ПОВТОР доставки, а не
# четвёртая выкатка: транспорт делает три попытки, и оборваться связь могла
# после записи. Второе сообщение об одной выкатке хуже отсутствующего: чат —
# летопись прода, и по ней считают, сколько раз сегодня катились.
run env DK_TEST_FIXED_MS=1785924102123 DK_NOTIFY_SLEEPS="0 0" \
    DK_RUN_STARTED_MS=1785924100000 DK_RUN_PID=771 \
    bash "$NOTIFY" --mode local --events-dir "$DIR" --source local \
    --kind success --app snakes --version manual-20260801-101502-1a2b3c4
same "повтор доставки принят" "$RC" "0"
same "и второго файла не завёл" "$(ls -A "$DIR"/[0-9]*.json 2>/dev/null | wc -l)" "3"

# Номер внутри группы растёт: второе событие того же прогона — groupSeq 2.
new_dir seq
GRP=(DK_RUN_STARTED_MS=1785924100000 DK_RUN_PID=778 DK_NOTIFY_SLEEPS="0 0")
run env "${GRP[@]}" bash "$NOTIFY" --mode local --events-dir "$DIR" --source local \
    --kind started --app snakes
run env "${GRP[@]}" bash "$NOTIFY" --mode local --events-dir "$DIR" --source local \
    --kind success --app snakes --version manual-20260805-101502-1a2b3c4
same "groupSeq второго события группы" \
    "$(sed -n 's/^  "groupSeq": \([0-9]*\).*/\1/p' "$DIR"/[0-9]*-success.json)" "2"
same "счётчик группы один на прогон" "$(ls -A "$DIR"/.groups 2>/dev/null | wc -l)" "1"

# --------------------------------------------------------------------------
case_ "Недоступный приёмник: ненулевой код, ::error:: и три попытки"

new_dir unreachable
: >"$SSH_LOG"
run env SSH_RC=255 SSH_LOG="$SSH_LOG" DK_NOTIFY_SLEEPS="0 0" \
    bash "$NOTIFY" --mode ssh --host samoy.love --user deploy --key /dev/null \
    --events-dir "$DIR" --source local --kind success --app snakes \
    --version manual-20260805-101502-1a2b3c4

same "код возврата ненулевой" "$(( RC != 0 ))" "1"
has "аннотация для CI" "::error::"
has "сказано, что событие не доставлено" "не доставлено"
has "названы вид и цель" "success/snakes"
same "попыток ровно три" "$(wc -l <"$SSH_LOG")" "3"

# Тот же вопрос с другой стороны: писать некуда локально — тоже провал, а не
# тихий ноль. Каталога журнала может не быть, если install-server не отработал.
run env DK_NOTIFY_SLEEPS="0 0" bash "$NOTIFY" --mode local --events-dir "$TMP/no-such-dir" \
    --source local --kind success --app snakes --version manual-20260805-101502-1a2b3c4
same "нет каталога журнала — ненулевой код" "$(( RC != 0 ))" "1"
has "названа причина" "каталог"

# --------------------------------------------------------------------------
case_ "Ключ: временный файл на 600 и уборка за собой"

new_dir key
: >"$SSH_LOG"
KEY_LOG="$TMP/key.log"; : >"$KEY_LOG"
run env SSH_RC=255 SSH_LOG="$SSH_LOG" KEY_REPORT="$KEY_LOG" DK_NOTIFY_SLEEPS="0 0" \
    DK_SSH_KEY="$(printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nподделка\n-----END OPENSSH PRIVATE KEY-----')" \
    bash "$NOTIFY" --mode ssh --host samoy.love --user deploy \
    --events-dir "$DIR" --source local --kind success --app snakes \
    --version manual-20260805-101502-1a2b3c4

KEYPATH="$(head -1 "$KEY_LOG" | cut -d' ' -f1)"
KEYMODE="$(head -1 "$KEY_LOG" | cut -d' ' -f2)"
if [[ -n "$KEYPATH" ]]; then
    ok "ключ передан ssh как файл"
    case "$KEYMODE" in
        600) ok "права на файле ключа 600" ;;
        '?') skip "права на файле ключа не проверены — stat на этой машине не отвечает" ;;
        *)
            # На NTFS через msys права — фикция, и красный тест здесь означал бы
            # только «мы на Windows». На раннере это Linux и настоящие 600.
            if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]; then
                skip "права на файле ключа ($KEYMODE) не проверяются под Windows"
            else
                bad "права на файле ключа $KEYMODE, ожидались 600"
            fi ;;
    esac
    [[ -e "$KEYPATH" ]] && bad "временный файл ключа остался: следы ключа переживают выкатку" \
                        || ok "временный файл ключа убран после провала доставки"
else
    bad "ssh не получил ключ из DK_SSH_KEY"
fi
hasnt "путь к ключу в вывод не попал" "dk-notify-key"
hasnt "содержимое ключа в вывод не попало" "BEGIN OPENSSH PRIVATE KEY"

# --------------------------------------------------------------------------
case_ "Потолки: отказ, а не запись"

new_dir caps
LONG_VERSION="release-$(printf 'a%.0s' $(seq 1 200))"
run_local --source local --kind success --app snakes --version "$LONG_VERSION"
same "версия сверх 128 байт — ненулевой код" "$(( RC != 0 ))" "1"
same "и ничего не записано" "$(ls -A "$DIR"/[0-9]*.json 2>/dev/null | wc -l)" "0"
has "сказано про потолок" "128"

new_dir caps-day
# Суточный предел на цель. Настоящий — 200; тест снижает его до двух, потому
# что двести выкаток в тесте проверяли бы терпение, а не поведение.
for i in 1 2 3; do
    run env DK_MAX_DAY_EVENTS=2 DK_NOTIFY_SLEEPS="0 0" bash "$NOTIFY" \
        --mode local --events-dir "$DIR" --source local --kind success --app snakes \
        --version "manual-2026080$i-101502-1a2b3c4"
    LAST_RC=$RC
done
same "третье событие за сутки отвергнуто" "$(( LAST_RC != 0 ))" "1"
same "в каталоге осталось ровно два" "$(ls -A "$DIR"/[0-9]*.json 2>/dev/null | wc -l)" "2"
has "аннотация для CI" "::error::"

new_dir caps-dir
run env DK_MAX_DIR_KIB=0 DK_NOTIFY_SLEEPS="0 0" bash "$NOTIFY" \
    --mode local --events-dir "$DIR" --source local --kind success --app snakes \
    --version manual-20260805-101502-1a2b3c4
same "переполненный каталог — отказ" "$(( RC != 0 ))" "1"
same "и ничего не записано" "$(ls -A "$DIR"/[0-9]*.json 2>/dev/null | wc -l)" "0"

# Событие не влезает в 8 КиБ — теряется список изменений, но не событие:
# список украшение поверх выкатки, а сама выкатка — нет.
new_dir caps-size
CL="$TMP/big-changelog"
: >"$CL"
for i in $(seq 1 20); do printf '%s\n' "$(printf 'п%.0s' $(seq 1 120))" >>"$CL"; done
run_local --source local --kind success --app snakes \
    --version manual-20260805-101502-1a2b3c4 --changelog-file "$CL"
same "код возврата" "$RC" "0"
EV="$(only_event)"
if [[ -n "$EV" ]]; then
    same "событие уложилось в 8 КиБ" "$(( $(wc -c <"$EV") <= 8192 ))" "1"
    check_json "$EV" "усечённое событие"
else
    bad "событие потеряно из-за длинного списка изменений (rc=$RC)"
fi

# --------------------------------------------------------------------------
case_ "Проверки полей: враньё не пишется, мусор не едет"

new_dir fields
run_local --source local --kind success --app snakes
same "success без версии — отказ" "$(( RC != 0 ))" "1"

run_local --source local --kind rolled_back --app snakes --version manual-20260805-101502-1a2b3c4 --stage health
same "rolled_back без reason — отказ" "$(( RC != 0 ))" "1"

run_local --source local --kind success --app "../etc/passwd" --version manual-20260805-101502-1a2b3c4
same "app с «..» — отказ" "$(( RC != 0 ))" "1"
same "и ничего не записано" "$(ls -A "$DIR"/[0-9]*.json 2>/dev/null | wc -l)" "0"

run_local --source local --kind failure --app snakes --stage "rm -rf /"
same "stage вне перечисления — отказ" "$(( RC != 0 ))" "1"

# Ссылка чужой схемы — не повод потерять событие: поле выбрасывается, версия в
# сообщении остаётся текстом. Ровно так же, как при отсутствии commitURL.
new_dir url
run_local --source local --kind success --app snakes --version manual-20260805-101502-1a2b3c4 \
    --commit-url 'javascript:alert(1)' --run-url 'https://github.com/tr0llex/snakes/actions/runs/1'
same "код возврата" "$RC" "0"
EV="$(only_event)"
if [[ -n "$EV" ]]; then
    grep -q 'javascript' "$EV" && bad "ссылка javascript: уехала в событие" || ok "ссылка чужой схемы выброшена"
    grep -q 'runURL' "$EV" && bad "runURL при source=local уехал в событие" || ok "runURL при source=local выброшен"
    check_json "$EV" "событие с выброшенными полями"
else
    bad "событие потеряно из-за кривой ссылки (rc=$RC)"
fi

# Управляющие символы и U+202E вырезаются писателем, хотя вырезает их и
# читатель: CR/LF подделывают строки journald, а U+202E показывает в чате не то,
# что написано.
new_dir sanitize
printf 'Починить \033[31mцвет\r\n' >"$TMP/cl-evil"
printf 'Обычный пункт\n' >>"$TMP/cl-evil"
run_local --source local --kind success --app snakes --version manual-20260805-101502-1a2b3c4 \
    --changelog-file "$TMP/cl-evil"
EV="$(only_event)"
if [[ -n "$EV" ]]; then
    LC_ALL=C grep -qP '[\x00-\x08\x0b\x0c\x0e-\x1f]' "$EV" 2>/dev/null \
        && bad "управляющие символы уехали в событие" \
        || ok "управляющие символы вырезаны"
    check_json "$EV" "событие с почищенными полями"
else
    bad "событие потеряно из-за управляющих символов (rc=$RC)"
fi

# --------------------------------------------------------------------------
case_ "Список изменений из bin/changelog приводится к простому тексту"

new_dir changelog
cat >"$TMP/cl-html" <<'HTML'
<b>Изменения</b>
• Не выдавать недоставленное уведомление за успех
• Починить обрыв скачивания больших файлов <a href="https://github.com/tr0llex/snakes/pull/21">#21</a>
• Убрать &lt;script&gt; из шаблона &amp; заодно лишний вызов
…и ещё 12 коммитов
HTML
run_local --source local --kind success --app snakes --version manual-20260805-101502-1a2b3c4 \
    --changelog-html "$TMP/cl-html"
EV="$(only_event)"
if [[ -n "$EV" ]]; then
    check_json "$EV" "событие со списком изменений"
    same "пунктов" "$(grep -c '^    "' "$EV")" "3"
    grep -q '<a href' "$EV" && bad "разметка уехала в событие" || ok "теги ссылок сняты, текст остался"
    grep -q '#21' "$EV" && ok "номер PR остался видимым текстом" || bad "номер PR потерян"
    grep -q '<b>Изменения' "$EV" && bad "шапка генератора уехала в событие" || ok "шапка снята"
    grep -q 'и ещё 12' "$EV" && bad "хвост «…и ещё N коммитов» уехал в событие" || ok "хвост снят"
    grep -q '&lt;' "$EV" && bad "HTML-мнемоники не развёрнуты" || ok "мнемоники развёрнуты в текст"
    grep -q '\\u003cscript' "$EV" || grep -q '<script>' "$EV" && ok "текст пункта сохранён дословно" \
        || bad "текст пункта потерян при развёртывании мнемоник"
else
    bad "событие со списком изменений не записано (rc=$RC)"
fi

# --------------------------------------------------------------------------
printf '\n\033[1mИтог\033[0m: %d удачно, %d провалено' "$pass" "$fail"
(( skipped )) && printf ', %d пропущено' "$skipped"
printf '\n'
(( fail == 0 )) || exit 1
(( skipped == 0 )) || printf 'Пропущенные проверки — это НЕ зелёный прогон: на раннере они обязаны пройти.\n'
exit 0
