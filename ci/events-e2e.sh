#!/usr/bin/env bash
# Сквозной тест журнала выкаток: lib/notify.sh → каталог на диске → образцы
# контракта → приёмник бота.
#
#   ci/events-e2e.sh
#
# ЧЕМ ОН ОТЛИЧАЕТСЯ ОТ ci/notify-test.sh. Тот проверяет транспорт: повторы,
# ключ, потолки, коды возврата — то есть обещания одного файла. Здесь
# проверяется СТЫК: событие, собранное настоящим писателем в локальном режиме,
# обязано лечь в каталог ровно тем файлом, который лежит в docs/events/ как
# образец, и обязано разобраться вторым концом конвейера, написанным на Go.
#
# Разъехаться эти концы могут молча и полностью: у каждого свои зелёные тесты,
# а между ними — только текст контракта, который выполняют два разных языка.
# Сверка идёт побайтово с docs/events/*.json, а не «по набору полей»: порядок
# ключей и отсутствие пустых полей — тоже часть контракта (§4), и «почти такой
# же» JSON здесь означает разные события в чате и в истории.
#
# СЕРВЕРА НЕТ. Режим local пишет прямо в каталог, ssh не зовётся вовсе. Часы и
# `hostname` подменяются стабами в PATH: `id` и `group` локального образца
# посчитаны от миллисекунд, имени машины и pid (§5, §6), и без подмены
# воспроизвести образец нельзя в принципе.
#
# ВТОРАЯ ПОЛОВИНА КОНВЕЙЕРА живёт в соседнем репозитории
# (status.samoy.love/bot). Если он лежит рядом и есть go, тест скармливает ему
# только что произведённый каталог: `go test -run TestE2EReadsJournalFromNotifySh`
# с DK_E2E_EVENTS_DIR. Нет рядом — случай пропускается ВСЛУХ, потому что
# молчаливый пропуск выглядит как зелёная проверка, которой не было.

set -uo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTIFY="$KIT/lib/notify.sh"
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

# Шаблон имени из §3 контракта — дословно тот же, что стоит у читателя
# (bot/inbox.go, eventFileRe). Всё, что под него не подходит, для бота не
# существует: недописанный .tmp, замок, счётчики групп.
READER_RE='^[0-9]{13}-[a-z0-9][a-z0-9._-]{0,63}-(started|success|failure|rolled_back|rollback|published)\.json$'

# --------------------------------------------------------------------------
# СТАБЫ. Оба в PATH перед настоящими: notify.sh зовёт `date` и `hostname` по
# имени, и подменять их изнутри значило бы проверять не тот код, который поедет
# на сервер.
mkdir -p "$TMP/bin"

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

# hostname участвует в прообразе id и group локального события, но в само
# событие не попадает (§4): внутренним именам в чате и на публичной странице
# места нет. Подменяется ради образца — в нём машина зовётся samoy-love.
cat >"$TMP/bin/hostname" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${DK_TEST_HOSTNAME:-$(uname -n)}"
STUB
chmod +x "$TMP/bin/hostname"

PATH="$TMP/bin:$PATH"
export PATH

OUT="$TMP/out"
RC=0

# sha — тот же sha256, которым писатель считает id и group. Утилита ищется в
# том же порядке, что и в lib/notify.sh: тест обязан уметь пересчитать прообраз
# везде, где умеет сам писатель, иначе он зазеленеет на машине, где его нечем
# проверить.
sha() {
    if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1;    then printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
    else printf '%s' "$1" | openssl dgst -sha256 | sed 's/.* //'
    fi
}

# Каталог журнала на каждый случай свой: остаток от предыдущего иначе считается
# суточным пределом и «объясняет» чужой отказ.
new_dir() { DIR="$TMP/events.$1"; rm -rf "$DIR"; mkdir -p "$DIR"; }

# Номер в группе считает писатель по счётчику .groups/<group>. Образцы
# контракта сняты с середины прогона (groupSeq: 2 после started этой же цели),
# поэтому счётчик приходится подставить: иначе воспроизвести образец можно было
# бы, только отправив перед ним настоящее событие started — и тест проверял бы
# заодно то, чего в образце нет.
seed_group() { mkdir -p "$DIR/.groups"; printf '%s\n' "$2" >"$DIR/.groups/$1"; }

run() { RC=0; env DK_NOTIFY_SLEEPS="0 0" "$@" >"$OUT" 2>&1 || RC=$?; }

# Имена событий каталога по возрастанию. Через glob, а не `ls`: bash разворачивает
# шаблон уже отсортированным, а разбор вывода `ls` ломается на первом же имени с
# пробелом — и ломается молча, то есть тест зазеленел бы на пустом месте.
shopt -s nullglob
event_names() {
    local f
    for f in "$DIR"/*.json; do printf '%s\n' "${f##*/}"; done
}
event_count() { local -a f=( "$DIR"/*.json ); printf '%s' "${#f[@]}"; }

# Проверка одного произведённого события против образца.
check_against_golden() { # check_against_golden <имя случая> <файл> <образец>
    local what="$1" got="$2" want="$3" name size mode
    if [[ ! -f "$got" ]]; then
        bad "$what: файл события не появился (rc=$RC): $(head -3 "$OUT" | tr '\n' ' ')"
        return
    fi
    name="${got##*/}"
    [[ "$name" =~ $READER_RE ]] \
        && ok "$what: имя подходит под шаблон читателя" \
        || bad "$what: имя «$name» читатель не увидит вовсе"

    if diff -u "$want" "$got" >"$TMP/diff" 2>&1; then
        ok "$what: событие совпадает с образцом побайтово"
    else
        bad "$what: событие разошлось с образцом ${want##*/}"
        sed -n '1,40p' "$TMP/diff" >&2
    fi

    size="$(wc -c <"$got" | tr -d ' ')"
    (( size <= 8192 )) \
        && ok "$what: $size байт при потолке 8 КиБ" \
        || bad "$what: $size байт — читатель такой файл не откроет вовсе (§8)"

    # Права 0640 — часть контракта (§11), но на Windows их не существует, а
    # умирать из-за этого тесту незачем: на раннере проверка настоящая.
    mode="$(stat -c %a "$got" 2>/dev/null || echo '?')"
    case "$mode" in
        640) ok "$what: права 0640" ;;
        '?') skip "$what: права не проверить — нет stat -c" ;;
        *)   if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
                 skip "$what: права $mode — Windows, настоящих прав тут нет"
             else
                 bad "$what: права $mode вместо 640 (§11)"
             fi ;;
    esac
}

# --------------------------------------------------------------------------
case_ "Выкатка из пайплайна ложится в журнал ровно образцом example-success"

new_dir success
GROUP_SUCCESS="$(sha 'tr0llex/snakes|16542330981|1')"
seed_group "$GROUP_SUCCESS" 1
cat >"$TMP/cl-success" <<'CL'
Не выдавать недоставленное уведомление за успех
Считать пропавший файл ошибкой обновления
Починить обрыв скачивания больших файлов #21
CL
run env DK_TEST_FIXED_MS=1785924102123 \
    GITHUB_ACTIONS=true GITHUB_REPOSITORY=tr0llex/snakes \
    GITHUB_RUN_ID=16542330981 GITHUB_RUN_ATTEMPT=1 \
    bash "$NOTIFY" --mode local --events-dir "$DIR" \
    --kind success --app snakes \
    --at 2026-08-05T10:01:42Z \
    --version release-20260805-130115-1a2b3c4 \
    --previous release-20260804-221407-9f8e7d6 \
    --changelog-file "$TMP/cl-success" \
    --commit-url https://github.com/tr0llex/snakes/commit/1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d \
    --run-url https://github.com/tr0llex/snakes/actions/runs/16542330981/attempts/1

same "код возврата" "$RC" "0"
same "имя файла" "$(event_names | head -1)" "1785924102123-snakes-success.json"
check_against_golden "выкатка" "$DIR/1785924102123-snakes-success.json" "$GOLDEN/example-success.json"

# id и group — настоящие sha256 от прообразов §5 и §6. Пересчитываются здесь, а
# не сверяются с константой в теле теста: константа разъедется с контрактом так
# же тихо, как разъехались бы обе стороны конвейера.
grep -qF "\"id\": \"$(sha 'tr0llex/snakes|16542330981|1|snakes|success')\"" \
    "$DIR/1785924102123-snakes-success.json" \
    && ok "id — sha256 от прообраза §5" || bad "id не совпал с пересчитанным прообразом §5"
grep -qF "\"group\": \"$GROUP_SUCCESS\"" "$DIR/1785924102123-snakes-success.json" \
    && ok "group — sha256 от прообраза §6" || bad "group не совпал с пересчитанным прообразом §6"

# --------------------------------------------------------------------------
case_ "Провал на гейтах ложится образцом example-failure (версии ещё нет)"

new_dir failure
run env DK_TEST_FIXED_MS=1785923700456 \
    GITHUB_ACTIONS=true GITHUB_REPOSITORY=tr0llex/chillhub \
    GITHUB_RUN_ID=16542331744 GITHUB_RUN_ATTEMPT=2 \
    bash "$NOTIFY" --mode local --events-dir "$DIR" \
    --kind failure --app chillhub-site --stage gates \
    --at 2026-08-05T09:55:00Z \
    --commit-url https://github.com/tr0llex/chillhub/commit/7f8e9d0c1b2a394857661a2b3c4d5e6f708192a3 \
    --run-url https://github.com/tr0llex/chillhub/actions/runs/16542331744/attempts/2

same "код возврата" "$RC" "0"
check_against_golden "провал" "$DIR/1785923700456-chillhub-site-failure.json" "$GOLDEN/example-failure.json"

# --------------------------------------------------------------------------
case_ "Автооткат с машины разработчика ложится образцом example-rolled-back"

new_dir rolled_back
GROUP_LOCAL="$(sha '1785925180000|samoy-love|31415')"
seed_group "$GROUP_LOCAL" 1
printf '%s\n' 'Показывать пересадки в ночном расписании' >"$TMP/cl-metro"
run env DK_TEST_FIXED_MS=1785925215123 DK_TEST_HOSTNAME=samoy-love \
    DK_RUN_STARTED_MS=1785925180000 DK_RUN_PID=31415 \
    bash "$NOTIFY" --mode local --events-dir "$DIR" \
    --kind rolled_back --app metro \
    --at 2026-08-05T10:20:15Z \
    --version manual-20260805-131944-c4d5e6f \
    --previous manual-20260803-201155-b1a2c3d \
    --stage health --reason health_failed \
    --changelog-file "$TMP/cl-metro" \
    --commit-url https://github.com/tr0llex/metro-map/commit/c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7

same "код возврата" "$RC" "0"
check_against_golden "автооткат" "$DIR/1785925215123-metro-rolled_back.json" "$GOLDEN/example-rolled-back.json"

# Миллисекунды у id и у group РАЗНЫЕ, и это не опечатка образца: id считан от
# момента события, group — от момента запуска `dk deploy` (§6). Тест, который
# подставит в оба прообраза одно число, сойдётся с образцом только случайно.
grep -qF "\"id\": \"$(sha '1785925215123|samoy-love|31415|metro|rolled_back')\"" \
    "$DIR/1785925215123-metro-rolled_back.json" \
    && ok "id локального события — от момента СОБЫТИЯ" || bad "id локального события не совпал"
grep -qF "\"group\": \"$GROUP_LOCAL\"" "$DIR/1785925215123-metro-rolled_back.json" \
    && ok "group локального события — от момента ЗАПУСКА команды" || bad "group локального события не совпал"

# --------------------------------------------------------------------------
case_ "Служебные файлы писателя читателю не видны"

# У писателя в каталоге живут замок и счётчики групп. Попади они под шаблон
# имени — бот попытался бы разобрать их как события и засорил бы журнал
# сообщениями об ошибке на каждом тике.
shown=0
for f in "$DIR"/* "$DIR"/.[!.]*; do
    [[ -e "$f" ]] || continue
    b="${f##*/}"
    [[ "$b" =~ $READER_RE ]] && shown=$(( shown + 1 ))
done
same "видимых читателю файлов" "$shown" "1"
[[ -d "$DIR/.groups" ]] && ok "счётчики групп лежат в .groups и под шаблон не подходят" \
    || bad "каталог счётчиков .groups не заведён — номер в группе считать нечем"

# --------------------------------------------------------------------------
case_ "Три выкатки в одну миллисекунду дают три разных возрастающих имени"

# Сценарий приёмки «три выкатки за минуту» на стороне писателя выглядит так:
# часы отдали одно и то же значение, а курсор читателя держится на порядке имён
# — значит, имена обязаны разойтись и остаться возрастающими.
new_dir burst
for i in 1 2 3; do
    run env DK_TEST_FIXED_MS=1785924102123 DK_TEST_HOSTNAME=samoy-love \
        DK_RUN_STARTED_MS=1785924102000 DK_RUN_PID="$(( 4000 + i ))" \
        bash "$NOTIFY" --mode local --events-dir "$DIR" \
        --kind success --app snakes --version "release-20260805-13011$i-1a2b3c4"
    (( RC == 0 )) || bad "выкатка $i не записана (rc=$RC): $(head -2 "$OUT" | tr '\n' ' ')"
done
mapfile -t names < <(event_names)
same "файлов в журнале" "${#names[@]}" "3"
prev=""
sorted=1
for n in "${names[@]}"; do
    [[ "$n" =~ $READER_RE ]] || bad "имя «$n» читатель не увидит"
    if [[ -n "$prev" ]] && ! [[ "$n" > "$prev" ]]; then sorted=0; fi
    prev="$n"
done
(( sorted )) && ok "имена строго возрастают — курсор читателя не собьётся" \
    || bad "имена не упорядочены: три выкатки за секунду потеряют одну"

# --------------------------------------------------------------------------
case_ "Выкатка и откат одной цели — два события, а не тишина"

# Сегодня это ноль сообщений: версия ушла и вернулась, разницы между снимками
# нет. В журнале обязаны лежать оба события, и оба — с разными видами.
new_dir rollback
run env DK_TEST_FIXED_MS=1785924102123 DK_TEST_HOSTNAME=samoy-love \
    DK_RUN_STARTED_MS=1785924102000 DK_RUN_PID=4100 \
    bash "$NOTIFY" --mode local --events-dir "$DIR" \
    --kind success --app metro --version manual-20260805-131944-c4d5e6f
(( RC == 0 )) || bad "выкатка не записана (rc=$RC)"
run env DK_TEST_FIXED_MS=1785924162123 DK_TEST_HOSTNAME=samoy-love \
    DK_RUN_STARTED_MS=1785924160000 DK_RUN_PID=4101 \
    bash "$NOTIFY" --mode local --events-dir "$DIR" \
    --kind rollback --app metro --version manual-20260803-201155-b1a2c3d
(( RC == 0 )) || bad "откат не записан (rc=$RC)"

same "событий в журнале" "$(event_count)" "2"
[[ -f "$DIR/1785924102123-metro-success.json" ]] \
    && ok "выкатка лежит отдельным событием" || bad "события выкатки нет"
[[ -f "$DIR/1785924162123-metro-rollback.json" ]] \
    && ok "откат лежит отдельным событием" || bad "события отката нет"
grep -q '"reason": "manual"' "$DIR/1785924162123-metro-rollback.json" 2>/dev/null \
    && ok "у ручного отката проставлен reason=manual (§4)" \
    || bad "у ручного отката нет reason=manual — бот не назовёт причину"
# Прогоны разные: две команды владельца — два сообщения, а не правка одного.
g1="$(grep -o '"group": "[0-9a-f]*"' "$DIR/1785924102123-metro-success.json" | head -1)"
g2="$(grep -o '"group": "[0-9a-f]*"' "$DIR/1785924162123-metro-rollback.json" | head -1)"
[[ "$g1" != "$g2" ]] && ok "выкатка и откат — разные прогоны" \
    || bad "откат попал в группу выкатки: правка карточки вместо второго сообщения"

# --------------------------------------------------------------------------
case_ "Журнал разбирается вторым концом конвейера (бот на Go)"

BOT="$KIT/../status.samoy.love/bot"
if [[ ! -d "$BOT" ]]; then
    skip "рядом нет status.samoy.love/bot — стык с читателем не проверен"
elif ! command -v go >/dev/null 2>&1; then
    skip "нет go — стык с читателем не проверен"
else
    # Каталог отдаётся тот, где лежит смесь видов: успех, откат и служебные
    # файлы писателя. Бот обязан разобрать события, промолчать про служебное и
    # не упасть ни на чём.
    if (cd "$BOT" && DK_E2E_EVENTS_DIR="$DIR" go test -count=1 \
            -run TestE2EReadsJournalFromNotifySh ./... ) >"$OUT" 2>&1; then
        ok "бот разобрал журнал, произведённый настоящим писателем"
    else
        bad "бот не разобрал журнал писателя"
        sed -n '1,40p' "$OUT" >&2
    fi
fi

# --------------------------------------------------------------------------
printf '\n\033[1mИтог\033[0m: %d удачно, %d провалено' "$pass" "$fail"
(( skipped )) && printf ', %d пропущено' "$skipped"
printf '\n'
(( fail == 0 )) || exit 1
(( skipped == 0 )) || printf 'Пропущенные проверки — это НЕ зелёный прогон: на раннере они обязаны пройти.\n'
exit 0
