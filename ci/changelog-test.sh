#!/usr/bin/env bash
# Проверка bin/changelog на одноразовых git-репозиториях.
#
#   ci/changelog-test.sh [путь к bin/changelog]
#
# Каждый случай собирает СВОЙ репозиторий во временном каталоге и проверяет
# три вещи разом: код возврата (обязан быть 0 всегда), stdout (обязан быть
# пустым там, где changelog не может работать) и содержимое.
#
# Отдельно проверяется валидность UTF-8: пределы считаются в символах, но
# сама строка режется по байтам, и разрезанный посреди символа результат
# Telegram молча отвергнет.
#
# И отдельно — что предел считается именно в СИМВОЛАХ, а не в байтах. Случаи
# 6b–6d стоят на самой границе (120 и 121 символ) и на чистой кириллице, на
# чистой латинице и на смеси: под LC_ALL=C, с которой работает changelog,
# ${#s} вернул бы байты, русской теме досталась бы половина предела, и
# отличить это от правильного поведения можно только на границе.
#
# Всё, что трогает argv, вызывается ТОЛЬКО через сторожа с таймаутом (run_t).
# Разбор аргументов однажды уже уходил в вечный цикл, и нашлось это не красным
# тестом, а двухминутным зависанием: без сторожа регрессия здесь не валит
# прогон, а вешает его до таймаута job — то есть ведёт себя ровно как та
# ошибка, которую тест обязан ловить.

set -uo pipefail

CL="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/changelog}"
[[ -x "$CL" || -f "$CL" ]] || { echo "не найден changelog: $CL" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$(( pass + 1 )); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; fail=$(( fail + 1 )); }
case_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Одноразовый репозиторий. Никаких глобальных настроек и хуков.
mkrepo() {
    local d="$TMP/$1"; mkdir -p "$d"
    git -C "$d" init -q -b main
    git -C "$d" config user.email dev@example.invalid
    git -C "$d" config user.name  dev
    git -C "$d" config commit.gpgsign false
    git -C "$d" config core.hooksPath "$d/.no-hooks"
    git -C "$d" config core.autocrlf false
    git -C "$d" config core.safecrlf false
    printf '%s' "$d"
}
N=0
commit() { # commit <repo> <subject>
    local d="$1" s="$2"
    N=$(( N + 1 ))
    # Каждый коммит трогает свой файл: иначе слияние веток в случае 5 упрётся
    # в конфликт, и коммита слияния, ради которого случай написан, не будет.
    printf '%s\n' "$N" > "$d/f$N.txt"
    git -C "$d" add -A
    git -C "$d" commit -q -F - <<< "$s"
}

# run <repo> [args…] → stdout в $OUT, stderr в $ERR, код в $RC
run() {
    local d="$1"; shift
    OUT="$("$CL" --repo "$d" "$@" 2>"$TMP/err")"; RC=$?
    ERR="$(cat "$TMP/err")"
}

# run_t <секунд> [аргументы changelog…] → то же, что run(), плюс TIMED_OUT=1,
# если сторож сработал. Аргументы передаются КАК ЕСТЬ, без подстановки --repo:
# случаи ниже проверяют в том числе argv, где --repo вообще нет.
#
# gtimeout — для macOS с coreutils из brew. Если timeout(1) нет совсем,
# сторожем работает фоновой процесс с опросом: медленнее, но прогон всё равно
# не повиснет навсегда, а это здесь главное.
TIMEOUT_BIN=""
for c in timeout gtimeout; do
    command -v "$c" >/dev/null 2>&1 && { TIMEOUT_BIN="$c"; break; }
done
[[ -n "$TIMEOUT_BIN" ]] || printf 'внимание: timeout(1) не найден, сторож на чистом bash\n' >&2

TIMED_OUT=0
run_t() {
    local secs="$1"; shift
    TIMED_OUT=0
    if [[ -n "$TIMEOUT_BIN" ]]; then
        OUT="$("$TIMEOUT_BIN" -k 1 "$secs" "$BASH" "$CL" "$@" 2>"$TMP/err")"; RC=$?
        (( RC == 124 || RC == 137 )) && TIMED_OUT=1
    else
        local pid i=0 lim=$(( secs * 10 ))
        "$BASH" "$CL" "$@" >"$TMP/out" 2>"$TMP/err" &
        pid=$!
        while (( i < lim )) && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$(( i + 1 )); done
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; RC=124; TIMED_OUT=1
        else
            wait "$pid"; RC=$?
        fi
        OUT="$(cat "$TMP/out")"
    fi
    ERR="$(cat "$TMP/err")"
}

# Число НЕПУСТЫХ строк в stderr. Гарантия файла на негодный аргумент — ровно
# одна строка объяснения: молчание («пусто и непонятно почему») и простыня
# одинаково плохи для того, кто читает лог выкатки.
err_lines() { printf '%s\n' "$ERR" | grep -c . ; }

expect_rc0()   { [[ "$RC" == 0 ]] && ok "код возврата 0" || bad "код возврата $RC, ожидался 0"; }
expect_empty() { [[ -z "$OUT" ]] && ok "stdout пуст" || bad "stdout не пуст: $OUT"; }
expect_has()   { [[ "$OUT" == *"$1"* ]] && ok "есть «$1»" || bad "нет «$1» в:"$'\n'"$OUT"; }
expect_hasnt() { [[ "$OUT" != *"$1"* ]] && ok "нет «$1»" || bad "не должно быть «$1» в:"$'\n'"$OUT"; }
expect_utf8()  { printf '%s' "$OUT" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && ok "валидный UTF-8" || bad "битый UTF-8"; }
expect_lines() { # expect_lines <n>
    local n; n="$(printf '%s\n' "$OUT" | grep -c '^• ')"
    [[ "$n" == "$1" ]] && ok "пунктов: $n" || bad "пунктов $n, ожидалось $1"
}
expect_bytes_le() {
    local n; n="$(printf '%s' "$OUT" | LC_ALL=C wc -c | tr -d ' ')"
    (( n <= $1 )) && ok "размер $n ≤ $1 байт" || bad "размер $n > $1 байт"
}

# Длина в СИМВОЛАХ. Считается ВТОРОЙ реализацией, независимой от той, что в
# bin/changelog: там арифметика по байтам в самом bash, здесь — tr, который
# выбрасывает байты-продолжения UTF-8 (0x80–0xBF, они же \200-\277). Проверять
# счёт тем же кодом, который его и делает, смысла нет: обе половины ошиблись бы
# одинаково. Правило то же самое — символов столько, сколько байтов НЕ являются
# продолжением, — но записано другими средствами.
chars() { printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c | tr -d ' '; }

# Длина в единицах UTF-16 — ровно то, чем меряет лимит 4096 сам Telegram.
# Символ вне BMP (эмодзи 🚀 в шапке сообщения о выкатке) стоит ДВЕ единицы,
# всё остальное из нашего текста — одну. В UTF-8 такой символ — это четыре
# байта с ведущим 0xF0–0xF4, поэтому единиц = символов + число четырёхбайтных.
# Байты и символы для этого лимита — не мера: на кириллице байтов вдвое
# больше, чем единиц, а эмодзи, наоборот, дешевле в символах, чем в единицах.
utf16() {
    local c a
    c="$(chars "$1")"
    a="$(printf '%s' "$1" | LC_ALL=C tr -dc '\360-\364' | LC_ALL=C wc -c | tr -d ' ')"
    printf '%s' $(( c + a ))
}

expect_chars_le() {
    local n; n="$(chars "$OUT")"
    (( n <= $1 )) && ok "длина $n ≤ $1 символов" || bad "длина $n > $1 символов"
}
expect_chars_eq() { # expect_chars_eq <n> <пояснение>
    local n; n="$(chars "$OUT")"
    [[ "$n" == "$1" ]] && ok "$2: $n символов" || bad "$2: символов $n, ожидалось $1:"$'\n'"$OUT"
}

# То, что читатель ВИДИТ: разметка ссылки убрана, её текст оставлен. Пределы
# --width и --budget считают именно это, потому что «<a href="…/pull/21">» на
# экране не существует — там стоит «#21». Снимается сторонним средством (sed), а
# не тем же кодом, который разметку строит: иначе обе половины ошиблись бы
# одинаково — по той же причине, по которой длина считается здесь через tr.
visible() { printf '%s' "$1" | sed -e 's/<a href="[^"]*">//g' -e 's|</a>||g'; }

# Сколько тегов <a> в выводе. Ссылка ставится не везде, и «ни одной» и «ровно
# одна» — разные утверждения: номер посреди фразы линковать нельзя.
anchors() { printf '%s' "$1" | grep -o '<a href=' | grep -c . ; }

# Строка из n одинаковых символов. Нужна, чтобы задавать длину темы ТОЧНО:
# «примерно сто двадцать» на границе не проверяет ничего.
rep() { # rep <символ> <сколько>
    local c="$1" n="$2" s="" i
    for (( i = 0; i < n; i++ )); do s="$s$c"; done
    printf '%s' "$s"
}

# --------------------------------------------------------------------------
case_ "1. Репозиторий без тегов — запасной вариант «последние N»"
R="$(mkrepo notags)"
for i in 1 2 3 4 5; do commit "$R" "изменение номер $i"; done
run "$R"
expect_rc0; expect_has "<b>Изменения</b>"; expect_has "• изменение номер 5"; expect_lines 5
expect_hasnt "…и ещё"

case_ "1a. Больше коммитов, чем depth — читается ровно depth, без вранья в хвосте"
R="$(mkrepo notags-many)"
for i in {1..30}; do commit "$R" "изменение номер $i"; done
run "$R" --max 3 --depth 8
expect_rc0; expect_lines 3; expect_has "…и ещё 5 коммитов"
expect_hasnt "…и ещё 27"

case_ "2. Один тег — диапазон от тега"
R="$(mkrepo onetag)"
commit "$R" "старое до тега"
git -C "$R" tag v1.0.0
commit "$R" "новое после тега один"
commit "$R" "новое после тега два"
run "$R"
expect_rc0; expect_has "новое после тега два"; expect_hasnt "старое до тега"; expect_lines 2

case_ "2a. Тег стоит ровно на HEAD — берётся предыдущий тег"
R="$(mkrepo tag-on-head)"
commit "$R" "до первого тега"
git -C "$R" tag v1.0.0
commit "$R" "между тегами"
git -C "$R" tag v1.1.0
run "$R"
expect_rc0; expect_has "между тегами"; expect_hasnt "до первого тега"

case_ "3. Явный --since выигрывает у тега"
R="$(mkrepo since)"
commit "$R" "самый первый"
BASE="$(git -C "$R" rev-parse HEAD)"
commit "$R" "после базы один"
git -C "$R" tag v2.0.0
commit "$R" "после базы два"
run "$R" --since "$BASE"
expect_rc0; expect_has "после базы один"; expect_has "после базы два"; expect_hasnt "самый первый"

case_ "3a. --since как имя версии deploy-kit (release-ДАТА-sha)"
SHORT="$(git -C "$R" rev-parse --short "$BASE")"
run "$R" --since "release-20260801-$SHORT"
expect_rc0; expect_has "после базы один"; expect_hasnt "самый первый"

case_ "3b. --since несуществующей ревизии — откат на тег, не падение"
run "$R" --since "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
expect_rc0; expect_has "после базы два"
[[ "$ERR" == *"нет в этом клоне"* ]] && ok "причина объяснена в stderr" || bad "stderr молчит: $ERR"

case_ "3c. Пустой --since (вызывающий передал незаданную переменную)"
run "$R" --since ""
expect_rc0; expect_has "•"

case_ "3d. --since равен HEAD — честное «нечего показывать», а не выдумка"
run "$R" --since HEAD
expect_rc0; expect_empty
[[ "$ERR" == *"нечего показывать"* ]] && ok "причина объяснена в stderr" || bad "stderr молчит: $ERR"

case_ "4. Экранирование HTML и склейка многострочной темы"
R="$(mkrepo html)"
commit "$R" "поднять go до 1.22 <-- важно & срочно"
commit "$R" "убрать <b>жирный</b> из шаблона"
printf 'тема первой строкой\nи её продолжение второй\n\nтело\n' > "$TMP/msg"
git -C "$R" commit -q --allow-empty -F "$TMP/msg"
run "$R"
expect_rc0
expect_has "&lt;-- важно &amp; срочно"
expect_has "&lt;b&gt;жирный&lt;/b&gt;"
expect_hasnt "<b>жирный"
expect_lines 3
[[ "$(printf '%s' "$OUT" | grep -c 'и её продолжение')" == 1 ]] \
    && ok "многострочная тема склеена в одну строку" || bad "многострочная тема разъехалась:\n$OUT"

case_ "4a. Тема коммита — чужой текст: скобки, кавычки, подстановки, повторы"
R="$(mkrepo hostile)"
commit "$R" 'убрать [x] из списка и $(touch /tmp/dk-changelog-pwned) заодно'
commit "$R" 'кавычки "двойные" и `обратные` и '"'"'одинарные'"'"''
commit "$R" 'повтор темы'
commit "$R" 'повтор темы'
run "$R"
expect_rc0; expect_utf8
expect_has "убрать [x] из списка"
[[ -e /tmp/dk-changelog-pwned ]] && bad "подстановка из темы коммита выполнилась" \
    || ok "подстановка из темы коммита не выполнилась"
[[ "$(printf '%s\n' "$OUT" | grep -c 'повтор темы')" == 1 ]] \
    && ok "повторяющаяся тема показана один раз" || bad "повтор не свернулся:"$'\n'"$OUT"

case_ "5. Слияния и шум отбрасываются"
R="$(mkrepo noise)"
commit "$R" "полезное изменение"
git -C "$R" checkout -q -b side
commit "$R" "изменение в ветке"
git -C "$R" checkout -q main
commit "$R" "ещё полезное"
git -C "$R" merge -q --no-ff -m "Merge branch 'side'" side
git -C "$R" log --oneline -1 --format='%p' | grep -q ' ' \
    && ok "коммит слияния действительно создан" || bad "слияния не вышло — случай ничего не проверяет"
commit "$R" "wip"
commit "$R" "fixup! полезное изменение"
commit "$R" "bump 1.2.3"
commit "$R" "1.2.4"
run "$R" --depth 20
expect_rc0
expect_has "полезное изменение"
expect_hasnt "Merge branch"
expect_hasnt "• wip"
expect_hasnt "fixup!"
expect_hasnt "bump 1.2.3"
expect_hasnt "• 1.2.4"

case_ "5a. Dependabot — темы взяты дословно из истории четырёх репозиториев"
# В захваченном выводе на deploy-kit пять пунктов из восьми были подъёмами
# версий actions: бот вытеснял из сообщения о релизе настоящие изменения.
R="$(mkrepo dependabot)"
commit "$R" "Возить конфиг nginx на прод обоими путями выкатки"
commit "$R" "deps: bump actions/setup-go from 5 to 7 (#22)"
commit "$R" "deps: bump actions/checkout from 4 to 7 (#24)"
commit "$R" "deps: bump codecov/codecov-action from 5.5.5 to 7.0.0 (#11)"
commit "$R" "deps: bump playwright in /tools/visual-qa (#31)"
commit "$R" "build(deps): bump playwright from 1.49.0 to 1.55.1 in /tools/visual-qa (#16)"
commit "$R" "chore(deps): bump jsdom from 29.1.1 to 30.0.1"
commit "$R" "deps-dev: bump vitest from 3.0.0 to 4.0.0"
commit "$R" "Bump actions/checkout from 4 to 5"
commit "$R" "Поднять версию до 1.0.0-rc.2"
commit "$R" "Запрет упоминаний ИИ проверять машиной"
run "$R" --depth 30 --max 8
expect_rc0
expect_has "Возить конфиг nginx"
expect_has "Запрет упоминаний ИИ"
expect_hasnt "bump"
expect_hasnt "Bump"
expect_hasnt "Поднять версию до"
expect_lines 2

case_ "5b. Перефильтровать хуже, чем недофильтровать — эти темы обязаны остаться"
# Каждая строка ниже — настоящий коммит из истории хозяйства. Широкий шаблон
# («что угодно со словом bump», «всё, что начинается на Merge») убил бы их
# молча, а пропавшую строку, в отличие от лишней, никто не заметит.
R="$(mkrepo keep)"
commit "$R" "Track tools manifest, bump jsdom to 30"
commit "$R" "dependabot.yml привести к формату prettier (#16)"
commit "$R" "Завести dependabot одинаково во всех репозиториях (#21)"
commit "$R" "chore: удалить мёртвый код — типы, функции и 22 класса CSS"
commit "$R" "Вернуть прежнее имя service worker как надгробие"
commit "$R" "Не пускать релиз без версии и без роста версии"
commit "$R" "Partial: prod nginx config, CI/Makefile/compose fixes, cosmetics WIP"
commit "$R" "Merge duplicate CSS classes"
commit "$R" "Revert \"Раскрывать шторку коротким движением пальца\""
commit "$R" "data: привести схему к официальной версии 6.1"
run "$R" --depth 30 --max 20 --width 200 --budget 4000
expect_rc0
expect_lines 10
expect_has "bump jsdom to 30"
expect_has "dependabot.yml"
expect_has "Завести dependabot"
expect_has "Вернуть прежнее имя"
expect_has "без роста версии"
expect_has "cosmetics WIP"
expect_has "Merge duplicate CSS classes"
expect_has "Revert \"Раскрывать"
expect_has "официальной версии 6.1"

case_ "5c. Служебные слияния и откаты слияний уходят"
# Это НЕ коммиты слияния: после squash-merge у них один родитель, и --no-merges
# их не трогает. Отсекать такие приходится по теме.
R="$(mkrepo merges)"
commit "$R" "настоящее изменение"
commit "$R" "Merge branch 'main' into feat/interface-events"
commit "$R" "Merge pull request #19 from tr0llex/unify/repo-canon"
commit "$R" "Merge remote-tracking branch 'origin/main' into unify"
commit "$R" "Merge packages into unify"
commit "$R" "Revert \"Merge pull request #19 from tr0llex/unify/repo-canon\""
commit "$R" "Revert \"Revert \"Не пускать релиз без версии\"\""
run "$R" --depth 30 --max 20
expect_rc0
expect_lines 1
expect_has "настоящее изменение"

case_ "6. Длинная тема режется, UTF-8 не рвётся, бюджет соблюдён"
R="$(mkrepo long)"
LONG="переписать обработку конфигурации так чтобы она наконец перестала зависеть от порядка ключей и локали машины разработчика"
for i in 1 2 3 4 5 6 7 8 9 10; do commit "$R" "$LONG $i"; done
run "$R" --max 10 --width 60 --budget 400 --depth 20
expect_rc0; expect_utf8; expect_chars_le 400
expect_has "…"
# Каждый пункт не длиннее --width плюс «• ». Считаем в СИМВОЛАХ: тема здесь
# кириллическая, в байтах она вдвое длиннее, и байтовая проверка провалилась бы
# на правильном выводе. Ровно на этом случай и ловил перевод предела в символы.
BADLINE=0
while IFS= read -r l; do
    [[ "$l" == "• "* ]] || continue
    n="$(chars "$l")"
    (( n > 60 + 2 )) && BADLINE=1
done <<< "$OUT"
(( BADLINE == 0 )) && ok "ни один пункт не длиннее --width" || bad "пункт длиннее --width:"$'\n'"$OUT"

case_ "6a. Кириллица режется по границе символа при любом --width"
R="$(mkrepo utf8)"
commit "$R" "ъъъъъъъъъъъъъъъъъъъъъъъъъъъъъъъъъъъъъъъъ"
for w in 9 10 11 12 13 14 15 20 21 33; do
    run "$R" --width "$w" --no-header
    if ! printf '%s' "$OUT" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
        bad "битый UTF-8 при --width $w"; BADW=1
    fi
done
[[ "${BADW:-0}" == 0 ]] && ok "все ширины дали валидный UTF-8"

# --------------------------------------------------------------------------
# ПРЕДЕЛ СЧИТАЕТСЯ В СИМВОЛАХ. Всё, что ниже, стоит на самой границе, потому
# что отличить счёт в символах от счёта в байтах можно только там. Под
# LC_ALL=C, с которой работает changelog, ${#s} возвращает байты, и русской
# теме досталась бы ровно половина предела — 60 символов вместо 120. Случай
# 6b на это и падает первым: тема из 120 кириллических букв весит 240 байт.
case_ "6b. Кириллица ровно 120 символов проходит целиком — предел не в байтах"
R="$(mkrepo chars-cyr-120)"
CYR120="$(rep 'ъ' 120)"
commit "$R" "$CYR120"
run "$R" --no-header
expect_rc0; expect_utf8
expect_has "$CYR120"
expect_hasnt "…"
expect_chars_eq 122 "пункт целиком — «• » и 120 символов темы"
n="$(printf '%s' "$OUT" | LC_ALL=C wc -c | tr -d ' ')"
(( n > 240 )) \
    && ok "в байтах это $n — вдвое больше предела, и тема всё равно уцелела" \
    || bad "тема весит $n байт: похоже, считаются байты, а не символы"

case_ "6c. Кириллица 121 символ — режется, ровно на один символ и не посреди буквы"
R="$(mkrepo chars-cyr-121)"
CYR121="$(rep 'ъ' 121)"
commit "$R" "$CYR121"
run "$R" --no-header
expect_rc0; expect_utf8
expect_has "…"
expect_hasnt "$CYR121"
# 119 букв плюс многоточие — ровно 120 символов, предел соблюдён вместе с ним.
expect_chars_eq 122 "обрезанный пункт — «• » и ровно 120 символов"
# Пробелов в теме нет, значит и границы слова нет: рез пришёлся туда, куда
# его поставил счёт символов, и обязан лежать на границе буквы. Кириллическая
# «ъ» — два байта, разрез посреди неё дал бы одиночный байт-продолжение,
# который iconv выше и ловит.
[[ "$OUT" == "• "*"ъ…" ]] && ok "строка кончается целой буквой и многоточием" \
    || bad "хвост строки подозрительный:"$'\n'"$OUT"

case_ "6d. Латиница тех же длин — никакой скидки за дешёвые байты"
# Смысл случая: 121 латинский символ — это всего 121 байт, то есть заметно
# МЕНЬШЕ, чем 240 байт уцелевшей кириллической темы из 6b. Если бы предел был
# байтовым, эта тема прошла бы целиком. Она обязана обрезаться: предел в
# символах одинаков для всех алфавитов.
R="$(mkrepo chars-lat)"
LAT120="$(rep 'z' 120)"
commit "$R" "$LAT120"
run "$R" --no-header
expect_rc0; expect_utf8; expect_has "$LAT120"; expect_hasnt "…"
expect_chars_eq 122 "120 латинских символов проходят целиком"

R="$(mkrepo chars-lat-121)"
LAT121="$(rep 'z' 121)"
commit "$R" "$LAT121"
run "$R" --no-header
expect_rc0; expect_utf8; expect_has "…"; expect_hasnt "$LAT121"
expect_chars_eq 122 "121 латинский символ обрезан, как и кириллический"
n="$(printf '%s' "$OUT" | LC_ALL=C wc -c | tr -d ' ')"
(( n < 240 )) \
    && ok "и это при $n байтах — байтам тут веры нет" \
    || bad "неожиданный размер: $n байт"

case_ "6e. Смешанная тема — символы считаются одинаково с обеих сторон"
# «аz» × 61 — это 122 символа, но 183 байта. Ни одна из двух половин строки
# не должна считаться иначе, чем другая, и рез не должен разрезать «а».
R="$(mkrepo chars-mix)"
MIX120="$(rep 'аz' 60)"
commit "$R" "$MIX120"
run "$R" --no-header
expect_rc0; expect_utf8; expect_has "$MIX120"; expect_hasnt "…"
expect_chars_eq 122 "120 символов вперемешку проходят целиком"

R="$(mkrepo chars-mix-122)"
commit "$R" "$(rep 'аz' 61)"
run "$R" --no-header
expect_rc0; expect_utf8; expect_has "…"
expect_chars_eq 122 "смешанная тема обрезана до тех же 120 символов"

case_ "6f. Рез предпочитает границу слова, а не середину"
R="$(mkrepo wordbound)"
PHRASE="переписать обработку конфигурации так чтобы она наконец перестала зависеть от порядка ключей и локали машины разработчика навсегда"
[[ "$(chars "$PHRASE")" -gt 120 ]] \
    && ok "тема случая длиннее предела ($(chars "$PHRASE") символов)" \
    || bad "тема случая короче предела — случай ничего не проверяет"
commit "$R" "$PHRASE"
run "$R" --no-header
expect_rc0; expect_utf8; expect_has "…"
BODY="${OUT#• }"; BODY="${BODY%…}"
[[ "$PHRASE" == "$BODY"* ]] && ok "показанное — начало настоящей темы" \
    || bad "показанное не совпадает с началом темы: «$BODY»"
TAIL="${PHRASE#"$BODY"}"
[[ "$TAIL" == " "* ]] && ok "рез пришёлся на границу слова" \
    || bad "рез посреди слова, дальше шло «${TAIL:0:12}»: «$BODY»"
[[ "$BODY" != *" " ]] && ok "пробел перед многоточием не остался" \
    || bad "перед многоточием висит пробел: «$BODY»"

case_ "6g. Сквош-хвост «(#NN)» срезается — но только хвост и только он"
# Сквош-мерж — норма хозяйства: ветка схлопывается в один коммит main, тема
# которого есть заголовок PR, а номер PR к ней дописывает GitHub. В git это
# ссылка, в чате — шум: 23% настоящих тем несут такой хвост, и в сообщении о
# релизе он не ведёт никуда. Всё остальное со скобками — часть фразы.
R="$(mkrepo squash)"
commit "$R" "Возить конфиг nginx на прод обоими путями выкатки (#42)"
commit "$R" "Убрать (временный) обход бага в разборе конфига"
commit "$R" "Привести схему к официальной версии 6.1 (см. #16)"
commit "$R" "Поправить (#12) в шаблоне письма и ничего больше"
commit "$R" "Не трогать хвост без решётки (2026)"
commit "$R" "Держать очередь задач в памяти (#7)"
commit "$R" "(#12)"
run "$R" --depth 20 --max 10 --no-header
expect_rc0; expect_utf8; expect_lines 7
expect_has "• Возить конфиг nginx на прод обоими путями выкатки"
expect_hasnt "(#42)"
expect_has "• Держать очередь задач в памяти"
expect_hasnt "(#7)"
# А это — не хвост, и трогать это нельзя.
expect_has "Убрать (временный) обход бага"
expect_has "официальной версии 6.1 (см. #16)"
expect_has "Поправить (#12) в шаблоне письма и ничего больше"
expect_has "Не трогать хвост без решётки (2026)"
# Тема, кроме хвоста не содержащая ничего. Срезать нечего — пустой пункт
# списка хуже странного.
expect_has "• (#12)"

case_ "6h. Хвост срезается ДО предела длины, а не после"
# Иначе «(#1234)» съедал бы семь символов из ста двадцати, и тема обрезалась
# бы ради номера, которого в выводе всё равно не будет.
R="$(mkrepo squash-width)"
commit "$R" "$(rep 'ъ' 120) (#1234)"
run "$R" --no-header
expect_rc0; expect_utf8
expect_hasnt "…"
expect_hasnt "#1234"
expect_chars_eq 122 "после срезки хвоста тема уложилась в предел целиком"

case_ "6i. Повтор темы, различающийся только номером PR, сворачивается"
# Черри-пик одного изменения в две ветки даёт два номера PR при одном тексте.
# Читателю это один пункт, и после срезки хвоста он им и становится.
R="$(mkrepo squash-dup)"
commit "$R" "Не пускать релиз без версии (#11)"
commit "$R" "Не пускать релиз без версии (#12)"
run "$R" --no-header
expect_rc0; expect_lines 1
expect_has "• Не пускать релиз без версии"

case_ "6j. --link-base: срезанный номер возвращается ссылкой в конец пункта"
# Срезать номер целиком — потеря: из чата к обсуждению изменения не перейти.
# С базой номер возвращается, но уже как ссылка, а не как текстовый шум.
BASE="https://github.com/tr0llex/deploy-kit"
R="$(mkrepo link)"
commit "$R" "Завести dependabot одинаково во всех репозиториях (#21)"
run "$R" --no-header --link-base "$BASE"
expect_rc0; expect_utf8; expect_lines 1
expect_has "• Завести dependabot одинаково во всех репозиториях <a href=\"$BASE/pull/21\">#21</a>"
# Сырого хвоста быть не должно ни в каком виде: его заменили, а не дополнили.
expect_hasnt "(#21)"
# /pull/N, а не /issues/N: GitHub переводит первый во второй, но не наоборот.
expect_has "/pull/21"
# Хвостовой слэш в базе — та же база, а не «//pull/21».
run "$R" --no-header --link-base "$BASE/"
expect_rc0
expect_has "href=\"$BASE/pull/21\""
expect_hasnt "//pull/21"

case_ "6k. Без --link-base поведение прежнее, до байта"
# Вызывающих у скрипта четверо, и ни один не обязан узнать о ссылках сразу.
# Поэтому «база не передана» обязано означать ровно то же, что и раньше.
run "$R" --no-header
expect_rc0
[[ "$OUT" == "• Завести dependabot одинаково во всех репозиториях" ]] \
    && ok "без базы — прежняя срезанная форма" || bad "без базы вывод изменился: «$OUT»"
(( $(anchors "$OUT") == 0 )) && ok "без базы тегов нет вовсе" || bad "без базы появился тег:"$'\n'"$OUT"
# И то же самое через переменную окружения — оба пути дают одно.
OUT="$(DK_CHANGELOG_LINK_BASE="$BASE" "$CL" --repo "$R" --no-header 2>/dev/null)"
expect_has "href=\"$BASE/pull/21\""

case_ "6l. Ссылка ставится ТОЛЬКО на хвостовой номер"
# Тот же принцип, что и у срезки: номер посреди фразы написал человек, он часть
# предложения. Ссылка на нём — не украшение, а искажение чужого текста.
R="$(mkrepo link-only-tail)"
commit "$R" "Держать очередь задач в памяти (#7)"
commit "$R" "Поправить (#12) в шаблоне письма и ничего больше"
commit "$R" "Привести схему к официальной версии 6.1 (см. #16)"
commit "$R" "Рефакторинг без всякого номера"
commit "$R" "Не трогать хвост без решётки (2026)"
run "$R" --depth 20 --max 10 --no-header --link-base "$BASE"
expect_rc0; expect_utf8; expect_lines 5
(( $(anchors "$OUT") == 1 )) && ok "тег ровно один — на единственном хвосте" \
    || bad "тегов $(anchors "$OUT"), ожидался один:"$'\n'"$OUT"
expect_has "• Держать очередь задач в памяти <a href=\"$BASE/pull/7\">#7</a>"
# Ни одна из этих строк не хвост, и ни одна не должна стать ссылкой.
expect_has "• Поправить (#12) в шаблоне письма и ничего больше"
expect_has "• Привести схему к официальной версии 6.1 (см. #16)"
expect_has "• Рефакторинг без всякого номера"
expect_has "• Не трогать хвост без решётки (2026)"
expect_hasnt "pull/12"
expect_hasnt "pull/16"
expect_hasnt "pull/2026"

case_ "6m. Негодная база — прежняя форма, без тега; выкатка не страдает"
# Тема коммита и сама база приезжают снаружи, а результат уезжает в разметку
# сообщения. Тег строим мы, значит и отвечаем за него мы: что не похоже на
# http(s)-адрес, тегом не становится. Отказ громкий в stderr и незаметный в
# stdout — пункт на месте, выкатка идёт дальше.
R="$(mkrepo link-bad)"
commit "$R" "Завести dependabot одинаково во всех репозиториях (#21)"
BAD_BASES=(
    'javascript:alert(1)'                       # не http(s) вовсе
    'ftp://example.invalid/repo'                # схема есть, но не та
    'HTTPS://EXAMPLE.INVALID/repo'              # верхний регистр схемы
    'https://x" onmouseover="alert(1)'          # выход из атрибута кавычкой
    'https://x><script>alert(1)</script>'       # выход из тега
    'https://x/repo?a=<b>'                      # угловые скобки в пути
    'https://пример.рф/репо'                    # не ASCII — гадать не будем
    'https://x/re po'                           # пробел
    'https://'                                  # схема без хоста
    'https:/example.invalid/repo'               # один слэш
    'example.invalid/repo'                      # без схемы
    'просто мусор'                              # вообще не адрес
    '../../etc/passwd'                          # относительный путь
)
BAD_BASES+=( "$(printf 'https://example.invalid/ok\n<script>alert(1)</script>')" )
BAD_BASES+=( "https://example.invalid/$(rep 'x' 220)" )  # длиннее 200 байт
LINKBAD=0
for b in "${BAD_BASES[@]}"; do
    run "$R" --no-header --link-base "$b"
    [[ "$RC" == 0 ]] || { bad "код $RC на базе «${b:0:40}»"; LINKBAD=1; continue; }
    if [[ "$OUT" != "• Завести dependabot одинаково во всех репозиториях" ]]; then
        bad "негодная база «${b:0:40}» изменила вывод:"$'\n'"$OUT"; LINKBAD=1; continue
    fi
    # Ни тега, ни куска базы, ни угловой скобки: молча деградируем до срезки.
    for probe in '<a' 'href' 'script' 'onmouseover' 'pull/21'; do
        [[ "$OUT" == *"$probe"* ]] && { bad "в выводе оказался «$probe» из базы «${b:0:40}»"; LINKBAD=1; }
    done
    # Молчать при этом нельзя: «пусто и непонятно почему» — тот самый дефект,
    # ради которого в этом файле вообще заведён stderr.
    [[ -n "$ERR" ]] || { bad "негодная база «${b:0:40}» прошла молча"; LINKBAD=1; }
done
(( LINKBAD == 0 )) && ok "все ${#BAD_BASES[@]} негодных баз: код 0, прежняя форма, объяснение в stderr"

case_ "6n. Амперсанд в базе экранируется — иначе разметка невалидна"
# Проверка набора символов и экранирование защищают от разного: первая — от
# «это не адрес», второе — от «адрес, но с амперсандом». Держаться они обязаны
# независимо, поэтому сюда взят годный адрес, который без экранирования дал бы
# битый HTML и молча не пришедшее сообщение.
run "$R" --no-header --link-base 'https://example.invalid/r&d/dk'
expect_rc0; expect_utf8
expect_has 'href="https://example.invalid/r&amp;d/dk/pull/21"'
expect_hasnt 'r&d'

case_ "6o. Разметка ссылки не ест предел в 120 символов"
# Читатель видит «#21» — четыре символа, а не сорок символов разметки вокруг
# них. Если бы предел считался по разметке, тема резалась бы ради того, чего на
# экране нет вовсе. Доказательство прямое: тема ровно предельной длины даёт
# один и тот же текст со ссылкой и без.
R="$(mkrepo link-width)"
commit "$R" "$(rep 'ъ' 120) (#21)"
run "$R" --no-header
NOLINK="$OUT"
expect_rc0; expect_hasnt "…"
expect_chars_eq 122 "без ссылки: «• » плюс 120 символов темы"
run "$R" --no-header --link-base "$BASE"
expect_rc0; expect_utf8
expect_hasnt "…"
VIS="$(visible "$OUT")"
[[ "$VIS" == "$NOLINK #21" ]] \
    && ok "видимый текст — тот же пункт плюс « #21», тема не тронута" \
    || bad "видимый текст разошёлся с вариантом без ссылки:"$'\n'"$VIS"
[[ "$(chars "$VIS")" == 126 ]] \
    && ok "видимых символов 126 = 122 + « #21»" || bad "видимых символов $(chars "$VIS"), ожидалось 126"
# А в разметке тот же пункт заметно длиннее — значит теги действительно есть и
# действительно не посчитаны.
(( $(chars "$OUT") > 126 )) \
    && ok "в разметке $(chars "$OUT") символов — теги на месте и в предел не вошли" \
    || bad "разметки нет вовсе: случай ничего не проверяет"

case_ "6p. Разметка ссылки не ест и бюджет блока"
# Проверка построена так, чтобы отделить ВИДИМОЕ от РАЗМЕТКИ. Видимое «#12»
# место в сообщении занимает по-настоящему, и вычитать его из бюджета честно.
# А вот длина самой базы на экране не видна вовсе — значит от неё не должно
# зависеть НИЧЕГО. Поэтому один и тот же список собирается дважды: с короткой
# базой и с базой в полтораста символов.
R="$(mkrepo link-budget)"
for i in {1..12}; do commit "$R" "$(printf 'достаточно длинная тема коммита номер %02d, как их и пишут' "$i") (#$i)"; done
LONGBASE="https://example.invalid/$(rep 'y' 120)"
run "$R" --depth 20 --max 20 --budget 400 --no-header --link-base "$BASE"
NS="$(printf '%s\n' "$OUT" | grep -c '^• ')"; VIS_S="$(visible "$OUT")"; RAW_S="$(chars "$OUT")"
run "$R" --depth 20 --max 20 --budget 400 --no-header --link-base "$LONGBASE"
NL="$(printf '%s\n' "$OUT" | grep -c '^• ')"; VIS_L="$(visible "$OUT")"; RAW_L="$(chars "$OUT")"
(( NS >= 3 )) && ok "в бюджет 400 вообще что-то вошло ($NS) — случай не вырожден" \
    || bad "в бюджет 400 не вошло почти ничего ($NS): случай ничего не проверяет"
[[ "$NS" == "$NL" ]] && ok "длина базы на состав списка не влияет: $NS пунктов и там, и там" \
    || bad "с короткой базой $NS пунктов, с длинной $NL — разметка съела бюджет"
[[ "$VIS_S" == "$VIS_L" ]] && ok "видимый текст совпал до символа при разной длине базы" \
    || bad "видимый текст разошёлся:"$'\n'"$VIS_S"$'\n'"---"$'\n'"$VIS_L"
(( RAW_L > RAW_S + 300 )) && ok "в разметке разница $(( RAW_L - RAW_S )) символов — базы действительно разной длины" \
    || bad "разметка почти не изменилась ($RAW_S → $RAW_L): случай ничего не проверяет"
(( $(anchors "$OUT") == NL )) && ok "ссылка у каждого из $NL пунктов" \
    || bad "тегов $(anchors "$OUT") при $NL пунктах"
# Видимое в бюджет уложилось, а строка целиком — заведомо нет: ровно это и
# означает «предел считает то, что видно».
(( $(chars "$VIS_L") <= 400 )) && ok "видимых символов $(chars "$VIS_L") ≤ 400" \
    || bad "видимых символов $(chars "$VIS_L") > 400"
(( RAW_L > 400 )) && ok "а с разметкой блок весит $RAW_L — в бюджет она не вошла" \
    || bad "блок с разметкой $RAW_L ≤ 400: разметки нет, случай ничего не проверяет"

case_ "7. Shallow-клон (fetch-depth: 1) — работает, не падает"
R="$(mkrepo deep)"
for i in 1 2 3 4 5 6; do commit "$R" "коммит номер $i"; done
git -C "$R" tag v1.0.0 HEAD~4
git clone -q --depth 1 "file://$(cd "$R" && pwd)" "$TMP/shallow" 2>/dev/null
if [[ -d "$TMP/shallow" ]]; then
    [[ "$(git -C "$TMP/shallow" rev-parse --is-shallow-repository)" == true ]] \
        && ok "клон действительно shallow" || bad "клон не shallow"
    run "$TMP/shallow" --since "deadbeef1234567"
    expect_rc0; expect_utf8
    expect_has "коммит номер 6"
    ok "shallow: stdout=$(printf '%s' "$OUT" | tr '\n' '|')"
else
    bad "не удалось сделать shallow-клон"
fi

case_ "7a. Shallow-клон глубины 1 без --since"
if [[ -d "$TMP/shallow" ]]; then
    run "$TMP/shallow"
    expect_rc0; expect_utf8
fi

case_ "8. Detached HEAD"
R="$(mkrepo detached)"
for i in 1 2 3 4 5; do commit "$R" "правка номер $i"; done
git -C "$R" checkout -q --detach HEAD~1
run "$R"
expect_rc0; expect_has "правка номер 4"; expect_hasnt "правка номер 5"

case_ "9. Не репозиторий вовсе"
mkdir -p "$TMP/plain"
run "$TMP/plain"
expect_rc0; expect_empty

case_ "9a. Пустой репозиторий без коммитов"
R="$(mkrepo empty)"
run "$R"
expect_rc0; expect_empty

case_ "9b. Несуществующий каталог"
run "$TMP/нет-такого"
expect_rc0; expect_empty

case_ "10. Нет git в PATH"
R="$(mkrepo nogit)"
commit "$R" "что-то"
# Запуск интерпретатором по абсолютному пути: иначе на пустом PATH не
# найдётся сам bash из shebang, и 127 приедет не от changelog.
OUT="$(PATH=/nonexistent "$BASH" "$CL" --repo "$R" 2>"$TMP/err")"; RC=$?
ERR="$(cat "$TMP/err")"
expect_rc0; expect_empty

case_ "11. Неизвестный аргумент не роняет вызывающего"
run "$R" --нет-такого-флага
expect_rc0; expect_empty

# --------------------------------------------------------------------------
# РАЗБОР АРГУМЕНТОВ. Инвариант один: на каждом витке цикл либо сдвигает argv
# хотя бы на один аргумент, либо выходит из скрипта. Крутиться на месте он не
# должен НИ ПРИ КАКОМ argv — раньше крутился на хвостовом флаге без значения
# (`shift 2` при одном оставшемся аргументе не сдвигает ничего), и шаг
# уведомления висел до таймаута job.
ARGV="$(mkrepo argv)"
commit "$ARGV" "настоящее изменение в репозитории"
VALUE_FLAGS=(--since --to --repo --max --width --budget --depth)

case_ "11a. Хвостовой флаг без значения — не вечный цикл"
for f in "${VALUE_FLAGS[@]}"; do
    run_t 10 --repo "$ARGV" "$f"
    if (( TIMED_OUT )); then bad "ЗАВИСАНИЕ на хвостовом $f"; continue; fi
    if [[ "$RC" == 0 && -z "$OUT" && "$(err_lines)" == 1 ]]; then
        ok "$f без значения: код 0, stdout пуст, одна строка в stderr"
    else
        bad "$f без значения: код $RC, stdout «$OUT», строк в stderr $(err_lines):"$'\n'"$ERR"
    fi
done

case_ "11b. Флаг без значения и вообще без других аргументов"
for f in "${VALUE_FLAGS[@]}"; do
    run_t 10 "$f"
    if (( TIMED_OUT )); then bad "ЗАВИСАНИЕ на одиноком $f"; continue; fi
    [[ "$RC" == 0 && -z "$OUT" && "$(err_lines)" == 1 ]] \
        && ok "одинокий $f: код 0, stdout пуст, одна строка в stderr" \
        || bad "одинокий $f: код $RC, stdout «$OUT», stderr:"$'\n'"$ERR"
done

case_ "11c. Повторы флагов — выигрывает последний, цикл продвигается"
run_t 10 --repo "$ARGV" --max 9 --max 1 --depth 5 --depth 20 --no-header --no-header
(( TIMED_OUT )) && bad "ЗАВИСАНИЕ на повторах" || ok "повторы: цикл продвинулся"
expect_rc0; expect_lines 1
run_t 10 --repo "$ARGV" --quiet --quiet --quiet
(( TIMED_OUT )) && bad "ЗАВИСАНИЕ на повторе --quiet" || ok "повтор --quiet: цикл продвинулся"
expect_rc0

case_ "11d. Повторяющийся флаг, у которого нет значения у ПОСЛЕДНЕГО"
run_t 10 --repo "$ARGV" --max 3 --max
if (( TIMED_OUT )); then bad "ЗАВИСАНИЕ на «--max 3 --max»"; else
    [[ "$RC" == 0 && -z "$OUT" && "$(err_lines)" == 1 ]] \
        && ok "«--max 3 --max»: код 0, stdout пуст, одна строка в stderr" \
        || bad "«--max 3 --max»: код $RC, stdout «$OUT», stderr:"$'\n'"$ERR"
fi

case_ "11e. «--» и одинокий «-» — разделителя у скрипта нет, но и цикла нет"
for a in -- - --- -x -- ; do
    run_t 10 --repo "$ARGV" "$a"
    if (( TIMED_OUT )); then bad "ЗАВИСАНИЕ на «$a»"; continue; fi
    [[ "$RC" == 0 && -z "$OUT" && "$(err_lines)" == 1 ]] \
        && ok "«$a»: код 0, stdout пуст, одна строка в stderr" \
        || bad "«$a»: код $RC, stdout «$OUT», stderr:"$'\n'"$ERR"
done
run_t 10 -- --repo "$ARGV"
(( TIMED_OUT )) && bad "ЗАВИСАНИЕ на «--» первым аргументом" || ok "«--» первым: цикл продвинулся"
expect_rc0; expect_empty

case_ "11f. Пустые значения — это «вызывающий передал незаданную переменную»"
run_t 10 --repo "$ARGV" --since "" --to "" --max "" --width "" --budget "" --depth ""
(( TIMED_OUT )) && bad "ЗАВИСАНИЕ на пустых значениях" || ok "пустые значения: цикл продвинулся"
expect_rc0; expect_has "• настоящее изменение"
# Пустой --repo означает «.», как и раньше: выкатка вызывает changelog из
# каталога репозитория, и подставлять сюда что-то другое было бы сюрпризом.
run_t 10 --repo "" --depth 1
(( TIMED_OUT )) && bad "ЗАВИСАНИЕ на пустом --repo" || ok "пустой --repo: цикл продвинулся"
expect_rc0
run_t 10 --repo "$ARGV" --since "" --since ""
(( TIMED_OUT )) && bad "ЗАВИСАНИЕ на повторе пустого --since" || ok "повтор пустого --since: цикл продвинулся"
expect_rc0

case_ "11g. Значение, которое само выглядит как флаг — съедается как значение"
run_t 10 --repo "$ARGV" --since --quiet
(( TIMED_OUT )) && bad "ЗАВИСАНИЕ на «--since --quiet»" || ok "«--since --quiet»: цикл продвинулся"
expect_rc0
# --quiet ушёл в значение --since, значит молчания НЕ наступило и ревизия
# «--quiet» не разобралась — обе половины проверяют одно и то же.
[[ "$ERR" == *"--quiet"* ]] && ok "«--quiet» разобран как значение --since, а не как флаг" \
    || bad "«--quiet» повёл себя как флаг: $ERR"
expect_has "• настоящее изменение"
run_t 10 --repo "$ARGV" --repo --max 3
(( TIMED_OUT )) && bad "ЗАВИСАНИЕ на «--repo --max 3»" || ok "«--repo --max 3»: цикл продвинулся"
expect_rc0; expect_empty

case_ "11h. Сторож на длинном списке форм argv: цикл обязан продвигаться на всех"
SHAPES=(
    '--since'
    '--since --since'
    '--to --to --to'
    '--max --max --max --max'
    '--repo ""'
    '--to ""'
    '--since "" --to ""'
    '--'
    '-'
    '-- --'
    '- -'
    '-q --since'
    '--no-header --depth'
    '--since --to --repo --max --width --budget --depth'
    '--width --budget'
    '--quiet --quiet --depth 2 --max'
    '--depth 2 --max'
    '--header --no-header --header --since'
    '"" "" ""'
    '--max "-1" --width "мусор" --budget "" --depth "0"'
    '-h'
    '--help'
)
SHAPE_BAD=0
for s in "${SHAPES[@]}"; do
    eval "SARGS=( $s )"
    run_t 10 --repo "$ARGV" "${SARGS[@]}"
    if (( TIMED_OUT )); then bad "ЗАВИСАНИЕ на argv: changelog --repo … $s"; SHAPE_BAD=1; continue; fi
    [[ "$RC" == 0 ]] || { bad "код $RC на argv: … $s"; SHAPE_BAD=1; }
done
(( SHAPE_BAD == 0 )) && ok "все ${#SHAPES[@]} форм argv: продвижение и код 0"

case_ "12. --no-header и --quiet"
R="$(mkrepo flags)"
commit "$R" "единственное изменение"
run "$R" --no-header
expect_rc0; expect_hasnt "<b>Изменения</b>"; expect_has "• единственное изменение"
run "$R" --quiet
[[ -z "$ERR" ]] && ok "--quiet молчит в stderr" || bad "--quiet что-то сказал: $ERR"

case_ "13. Вызов из-под set -Eeuo pipefail не рвёт вызывающего"
cat > "$TMP/caller.sh" <<'EOF'
set -Eeuo pipefail
CL="$1"; REPO="$2"
TEXT="🚀 <b>app</b> выкачен"
CHANGES="$("$CL" --repo "$REPO" 2>/dev/null)"
[ -n "$CHANGES" ] && TEXT="$TEXT
$CHANGES"
printf '%s\n' "$TEXT"
echo "ВЫЖИЛ"
EOF
for target in "$TMP/plain" "$R" "$TMP/нет-такого"; do
    if bash "$TMP/caller.sh" "$CL" "$target" | grep -q ВЫЖИЛ; then
        ok "вызывающий под set -Eeuo pipefail выжил ($(basename "$target"))"
    else
        bad "вызывающий умер на $target"
    fi
done

case_ "14. Всё сообщение целиком укладывается в лимит Telegram"
R="$(mkrepo telegram)"
for i in {1..40}; do
    commit "$R" "довольно длинная тема коммита номер $i, какие обычно и пишут в этом хозяйстве"
done
run "$R" --depth 40 --max 8
PREFIX="🚀 <b>samoylove</b> выкачен
<code>release-20260803-120000-1a2b3c4</code>
<a href=\"https://example.invalid/\">открыть</a>"
FULL="$PREFIX
$OUT"
n="$(printf '%s' "$FULL" | LC_ALL=C wc -c | tr -d ' ')"
(( n <= 4096 )) && ok "полное сообщение $n байт ≤ 4096" || bad "полное сообщение $n байт > 4096"

case_ "14a. Худший случай: восемь пунктов предельной длины на кириллице"
# Здесь проверяется НОВЫЙ бюджет блока. Раньше он был 1400 БАЙТ, и при темах
# до 120 символов список обрывался бы на четвёртом пункте: кириллический пункт
# предельной длины весит 242 байта. Бюджет переведён в символы (1200), и
# ограничивать список снова обязан --max, а не бюджет.
#
# Меряем тем же, чем меряет Telegram, — единицами UTF-16. Ни байты (их вдвое
# больше), ни символы (эмодзи в шапке стоит две единицы) его лимиту не равны.
R="$(mkrepo telegram-max)"
CYRMAX="$(rep 'ъ' 117)"
# Номер двузначный у всех, иначе длина тем разъедется и «предельная» перестанет
# быть предельной. 117 + пробел + две цифры = ровно 120 символов.
for i in {1..12}; do commit "$R" "$(printf '%s %02d' "$CYRMAX" "$i")"; done
run "$R" --depth 20 --max 8
expect_rc0; expect_utf8; expect_lines 8
# Коммитов 12, показано 8: место под хвост зарезервировано заранее, и хвост
# обязан быть на месте даже в худшем случае.
expect_has "…и ещё 4 коммита"
expect_chars_le 1200
BADMAX=0
while IFS= read -r l; do
    [[ "$l" == "• "* ]] || continue
    (( $(chars "$l") == 122 )) || BADMAX=1
done <<< "$OUT"
(( BADMAX == 0 )) && ok "все восемь пунктов ровно предельной длины (120 символов темы)" \
    || bad "пункты вышли не предельной длины:"$'\n'"$OUT"
FULL="$PREFIX
$OUT"
u="$(utf16 "$FULL")"
(( u <= 4096 )) && ok "полное сообщение $u единиц UTF-16 ≤ 4096" \
    || bad "полное сообщение $u единиц UTF-16 > 4096"
(( u <= 2048 )) && ok "и это с запасом вдвое: $u ≤ 2048" \
    || bad "запаса нет: $u единиц, лимит 4096"
# А в байтах тот же блок — больше прежнего бюджета в 1400. Ровно поэтому
# бюджет и пришлось переводить в символы.
n="$(printf '%s' "$OUT" | LC_ALL=C wc -c | tr -d ' ')"
(( n > 1400 )) && ok "в байтах блок весит $n — прежний бюджет 1400 оборвал бы список" \
    || bad "блок весит $n байт: случай не воспроизводит худший вариант"

case_ "15. --max 0 — весь список целиком, без хвоста «…и ещё»"
# Обрезаний по дороге до читателя два, и ПЕРВОЕ решает всё: в version.json
# попадает ровно то, что напечатано здесь. Значит и «не обрезать» начинается
# здесь. Хвост при этом обязан исчезнуть совсем: если не обрезано ничего, то и
# «ещё» никакого нет.
R="$(mkrepo unlimited)"
commit "$R" "самый первый коммит до тега"
git -C "$R" tag v1.0.0
for i in {1..25}; do commit "$R" "$(printf 'изменение номер %02d в этом релизе' "$i")"; done
run "$R" --since v1.0.0 --max 0 --budget 0 --no-header
expect_rc0; expect_utf8
expect_lines 25
expect_hasnt "…и ещё"
expect_has "• изменение номер 01 в этом релизе"
expect_has "• изменение номер 25 в этом релизе"

case_ "15a. Умолчания не тронуты: без --max список по-прежнему обрезается"
# Снятый предел — это то, о чём просят явно. Вызывающие, которые не просили,
# обязаны получить ровно прежнее сообщение.
run "$R" --since v1.0.0 --no-header
expect_rc0; expect_lines 8; expect_has "…и ещё 17 коммитов"

case_ "15b. --budget 0 — блок перерастает прежние 1200 символов и не рвётся"
# Кириллический пункт предельной длины — 122 символа: сорок таких в прежний
# бюджет не влезали и близко. Лимит Telegram здесь уже НЕ соблюдается, и это
# намеренно: список едет в version.json, а разбивку на сообщения делает тот,
# кто отправляет.
R="$(mkrepo unlimited-big)"
commit "$R" "самый первый коммит до тега"
git -C "$R" tag v1.0.0
CYRMAX="$(rep 'ъ' 117)"
for i in {1..40}; do commit "$R" "$(printf '%s %02d' "$CYRMAX" "$i")"; done
run "$R" --since v1.0.0 --max 0 --budget 0 --no-header
expect_rc0; expect_utf8
expect_lines 40
expect_hasnt "…и ещё"
(( $(chars "$OUT") > 1200 )) && ok "блок $(chars "$OUT") символов — прежний бюджет 1200 оборвал бы его" \
    || bad "блок $(chars "$OUT") символов: случай не воспроизводит то, ради чего снят бюджет"
(( $(utf16 "$OUT") > 4096 )) && ok "и в лимит одного сообщения Telegram он не влезает ($(utf16 "$OUT")) — разбивать обязан отправитель" \
    || ok "блок пока влезает в одно сообщение ($(utf16 "$OUT") единиц)"

case_ "15c. Снятый предел — не бесконечность: потолок остаётся и говорит о себе"
# Патологический вход тут не «сотня коммитов», а «--since на первый коммит
# репозитория»: version.json раздаётся по HTTP и опрашивается раз в минуту, и
# расти без границы ему нельзя. Потолок — 200 пунктов, и, в отличие от
# умолчания, он обязан честно объявить, что список обрезан.
R="$(mkrepo unlimited-ceiling)"
git -C "$R" commit -q --allow-empty -m "самый первый коммит до тега"
git -C "$R" tag v1.0.0
for i in $(seq 1 210); do
    git -C "$R" commit -q --allow-empty -m "$(printf 'изменение номер %03d' "$i")"
done
run "$R" --since v1.0.0 --max 0 --budget 0 --no-header
expect_rc0; expect_utf8
expect_lines 200
expect_has "…и ещё 10 коммитов"

case_ "15d. Снятые пределы и ссылки вместе: полный список, у каждого пункта ссылка"
# Настоящий вход после сквош-мержей: у каждой темы свой номер PR. Ни один
# пункт не должен потеряться, и ни один номер — не осиротеть.
R="$(mkrepo unlimited-links)"
commit "$R" "самый первый коммит до тега"
git -C "$R" tag v1.0.0
for i in {1..30}; do commit "$R" "$(printf 'изменение номер %02d в этом релизе' "$i") (#$(( 100 + i )))"; done
run "$R" --since v1.0.0 --max 0 --budget 0 --no-header --link-base "$BASE"
expect_rc0; expect_utf8
expect_lines 30
expect_hasnt "…и ещё"
(( $(anchors "$OUT") == 30 )) && ok "ссылок ровно 30 — по одной на пункт" \
    || bad "ссылок $(anchors "$OUT"), ожидалось 30"
expect_has "<a href=\"$BASE/pull/101\">#101</a>"
expect_has "<a href=\"$BASE/pull/130\">#130</a>"
expect_hasnt "(#130)"

case_ "15f. --all — то же самое, что --max 0 --budget 0, слово в слово"
# Алиас заведён не ради краткости, а потому, что оба переиспользуемых workflow
# уже звали генератор словом --all, а он такого аргумента не знал: в ответ —
# строка в stderr, ПУСТОЙ stdout и код 0. То есть каждый релиз из CI уезжал без
# списка изменений, молча. Здесь проверяется, что слово и пара чисел дают
# ДОСЛОВНО один и тот же вывод: разойдись они — и у двух путей выкатки снова
# будет два разных списка одного релиза.
R="$(mkrepo all-alias)"
commit "$R" "самый первый коммит до тега"
git -C "$R" tag v1.0.0
for i in {1..30}; do commit "$R" "$(printf 'изменение номер %02d в этом релизе' "$i") (#$(( 100 + i )))"; done
run "$R" --since v1.0.0 --max 0 --budget 0 --no-header --link-base "$BASE"
expect_rc0
ALL_A="$OUT"
run "$R" --since v1.0.0 --all --no-header --link-base "$BASE"
expect_rc0; expect_utf8
expect_lines 30
expect_hasnt "…и ещё"
[[ "$OUT" == "$ALL_A" ]] && ok "--all и «--max 0 --budget 0» дают дословно одно и то же" \
    || bad "--all разошёлся с «--max 0 --budget 0»"
# Последнее слово остаётся за последним аргументом — как у всех остальных
# флагов. Иначе «--all --max 8» тихо значило бы не то, что написано.
run "$R" --since v1.0.0 --all --max 8 --no-header
expect_rc0; expect_lines 8

case_ "15e. Хвост значит «обрезано пределом», а не «что-то отфильтровано»"
# Именно эта строка и вызвала жалобу: «…и ещё 1 коммит» — и не ясно, какой.
# Тот «коммит» был вторым черри-пиком того же изменения: скрыт НАМЕРЕННО,
# читателю не нужен, а строку в сообщении занимал.
R="$(mkrepo tail-meaning)"
commit "$R" "Не пускать релиз без версии (#11)"
commit "$R" "Не пускать релиз без версии (#12)"
run "$R" --no-header
expect_rc0; expect_lines 1
expect_has "• Не пускать релиз без версии"
expect_hasnt "…и ещё"
# То же для отфильтрованного шума: подъёмы версий скрыты намеренно, и обещать
# читателю «ещё три коммита» за ними — врать дважды.
R="$(mkrepo tail-noise)"
commit "$R" "настоящее изменение"
commit "$R" "Bump actions/checkout from 4 to 5"
commit "$R" "deps: bump vitest from 3.0.0 to 4.0.0"
commit "$R" "Поднять версию до 1.0.0-rc.2"
run "$R" --depth 20 --no-header
expect_rc0; expect_lines 1
expect_has "• настоящее изменение"
expect_hasnt "…и ещё"
# А когда обрезал именно предел — хвост на месте и означает ровно это.
commit "$R" "второе настоящее изменение"
run "$R" --depth 20 --max 1 --no-header
expect_rc0; expect_lines 1
expect_has "• второе настоящее изменение"
expect_has "…и ещё"

printf '\n\033[1mитого: %d прошло, %d провалено\033[0m\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
