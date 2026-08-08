#!/usr/bin/env bash
# Стык между генератором списка изменений и тремя писателями version.json.
#
#   ci/contract-test.sh [путь к bin/changelog]
#
# ЗАЧЕМ ЭТОТ ФАЙЛ. Список изменений однажды сломался, и не заметил никто:
# у bin/changelog были свои зелёные тесты (ci/changelog-test.sh), у агента
# статус-страницы — свои Go-суиты, а СТЫК между ними не проверял никто. Оба
# конца были зелёными одновременно с поломкой посередине — это и есть тот
# дефект, который ловится только контрактным прогоном.
#
# Стык здесь физический, а не умозрительный: текст генератора уезжает внутрь
# JSON-строки в version.json, а этот же файл читает версионный шлюз в
# server/lib.sh — до распаковки релиза и до переключения симлинка. То есть
# украшение поверх выкатки лежит в одном файле с полем, по которому выкатка
# себя подтверждает. Одна неэкранированная кавычка из темы коммита ломает не
# «красивый список», а сверку версии: релиз либо откатывается, либо (хуже)
# уезжает зелёным со старыми файлами — ровно тот случай, ради которого шлюз
# и заведён.
#
# ПИСАТЕЛЕЙ ТРИ, И В ЭТОМ ГЛАВНАЯ ОПАСНОСТЬ. Один и тот же файл собирают
# bin/deploy (посимвольный json_escape на чистом bash) и два переиспользуемых
# workflow (jq). Три независимые реализации одного формата расходятся молча:
# починили в одном месте — забыли в двух. Поэтому все три здесь не
# переписываются заново, а ВЫРЕЗАЮТСЯ ИЗ ИСХОДНИКОВ и запускаются как есть.
# Копия кода в тесте проверяла бы копию, а не выкатку: разъехаться она могла
# бы ровно так же тихо.
#
# ЧТО ПРОВЕРЯЕТСЯ:
#   1. враждебный репозиторий (кавычки, слэши, переводы строк, табы,
#      управляющие символы, юникод, HTML и тема, буквально изображающая
#      фрагмент JSON) → все три писателя дают валидный JSON, и версия из него
#      читается шлюзом ДОСЛОВНО;
#   2. сквош-мерж — норма этого хозяйства: ветка схлопывается в один коммит с
#      темой-заголовком PR, и хвост «(#42)» от GitHub из пункта убирается;
#   3. цепочка целиком: stdout генератора → version.json → обратно, без
#      двойного экранирования.
#
# Всё, что зовёт генератор, идёт через сторожа с таймаутом (run_t) — по той же
# причине, что и в ci/changelog-test.sh: зависание вместо красного теста
# ведёт себя как та самая ошибка, которую тест обязан ловить.
#
# jq на машине разработчика бывает не всегда. Его отсутствие здесь НЕ повод
# молча зазеленеть: пропущенные случаи считаются отдельно и печатаются с
# объяснением, а на раннере jq есть всегда.

set -uo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CL="${1:-$KIT/bin/changelog}"
DEPLOY="$KIT/bin/deploy"
WF_GO="$KIT/.github/workflows/go-service.yml"
WF_STATIC="$KIT/.github/workflows/static-site.yml"
LIB="$KIT/server/lib.sh"

for f in "$CL" "$DEPLOY" "$WF_GO" "$WF_STATIC" "$LIB"; do
    [[ -f "$f" ]] || { echo "не найден: $f" >&2; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0; skipped=0
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$(( pass + 1 )); }
bad()   { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; fail=$(( fail + 1 )); }
skip()  { printf '  \033[33m—\033[0m %s\n' "$*"; skipped=$(( skipped + 1 )); }
case_() { printf '\n\033[1m%s\033[0m\n' "$*"; PREP_SAID=0; }

# --------------------------------------------------------------------------
# ПОДГОТОВКА ДАННЫХ, КОТОРАЯ НЕ МОЛЧИТ. Всё как в ci/changelog-test.sh, и по
# той же причине: там неудачная сборка одноразового репозитория однажды уехала
# на раннер под видом провала утверждения о выводе генератора. Код возврата git
# здесь не игнорируется, а stderr не выбрасывается — иначе «репозиторий не
# построился» неотличимо от «проверяемый код сработал неверно», а чинить это
# надо в разных файлах.
PREP_SAID=0
PREP_ERR="$TMP/prep-err"
gitp() { # gitp <репозиторий> <аргументы git…>
    local d="$1" rc; shift
    git -C "$d" "$@" >/dev/null 2>"$PREP_ERR"; rc=$?
    (( rc == 0 )) && return 0
    # Говорим один раз на случай: сломанная подготовка ломается на каждом витке
    # цикла, и сорок одинаковых строк со справкой git прячут всё остальное.
    (( PREP_SAID )) && return "$rc"
    PREP_SAID=1
    bad "подготовка не удалась: git $* — код $rc"$'\n'"    $(head -3 "$PREP_ERR")"
    return "$rc"
}

# --------------------------------------------------------------------------
# Одноразовые репозитории. Всё как в ci/changelog-test.sh: ни глобальных
# настроек, ни хуков, ни подписи — тест обязан вести себя одинаково на
# раннере и на машине, где всё это настроено.
#
# Само тело — на голом git, а не на gitp: mkrepo зовут из подстановки, то есть
# в подоболочке, откуда счётчик провалов не вернётся. Неудачный init на этом не
# потеряется — на нём споткнётся первый же gitp в самом случае.
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
commit() { # commit <репозиторий> <тема>
    local d="$1" s="$2"
    N=$(( N + 1 ))
    # Каждый коммит трогает свой файл: иначе сквош-мерж ветки в случае 2
    # упёрся бы в конфликт, и сквоша, ради которого случай написан, не вышло бы.
    printf '%s\n' "$N" > "$d/f$N.txt"
    gitp "$d" add -A
    gitp "$d" commit -q -F - <<< "$s"
}

# Ветка с несколькими коммитами и возврат на main — заготовка для сквоша.
branch_work() { # branch_work <репозиторий> <ветка> <тема…>
    local d="$1" br="$2" s
    shift 2
    gitp "$d" checkout -q -b "$br"
    for s in "$@"; do commit "$d" "$s"; done
    gitp "$d" checkout -q main
}

# Настоящий сквош-мерж: `git merge --squash` + коммит с темой-заголовком PR.
# Именно так GitHub кладёт PR в main при «Squash and merge», и именно так
# выглядит история, по которой считается список изменений релиза.
squash_pr() { # squash_pr <репозиторий> <ветка> <заголовок PR>
    local d="$1" br="$2" title="$3"
    # Раньше здесь стояло `>/dev/null 2>&1`, то есть сквош мог не состояться
    # молча, и случай проверял бы историю, которой не построил.
    gitp "$d" merge -q --squash "$br"
    gitp "$d" commit -q -F - <<< "$title"
}

# --------------------------------------------------------------------------
# Сторож. gtimeout — для macOS с coreutils из brew; нет ни того ни другого —
# сторожем работает фоновой процесс с опросом.
TIMEOUT_BIN=""
for c in timeout gtimeout; do
    command -v "$c" >/dev/null 2>&1 && { TIMEOUT_BIN="$c"; break; }
done
[[ -n "$TIMEOUT_BIN" ]] || printf 'внимание: timeout(1) не найден, сторож на чистом bash\n' >&2

OUT=""; ERR=""; RC=0; TIMED_OUT=0
# stdout всегда уходит в файл, а не только в переменную: подстановка $(…)
# срезает хвостовой перевод строки, а он здесь ЗНАЧИМ — workflow кладёт в
# version.json именно файл, дословно, вместе с этим переводом строки.
run_t() { # run_t <секунд> [аргументы changelog…]
    local secs="$1"; shift
    TIMED_OUT=0
    if [[ -n "$TIMEOUT_BIN" ]]; then
        "$TIMEOUT_BIN" -k 1 "$secs" "$BASH" "$CL" "$@" >"$TMP/out" 2>"$TMP/err"; RC=$?
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
    fi
    OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"
    (( TIMED_OUT )) && bad "ЗАВИСАНИЕ генератора на: $*"
    return 0
}
gen() { # gen <репозиторий> [аргументы…] — вывод остаётся в $TMP/out и в $OUT
    local d="$1"; shift
    run_t 20 --repo "$d" "$@"
}

expect_rc0()   { [[ "$RC" == 0 ]] && ok "код возврата 0" || bad "код возврата $RC, ожидался 0"; }
expect_has()   { [[ "$OUT" == *"$1"* ]] && ok "есть «$1»" || bad "нет «$1» в:"$'\n'"$OUT"; }
expect_hasnt() { [[ "$OUT" != *"$1"* ]] && ok "нет «$1»" || bad "не должно быть «$1» в:"$'\n'"$OUT"; }
expect_lines() { # expect_lines <n>
    local n; n="$(printf '%s\n' "$OUT" | grep -c '^• ')"
    [[ "$n" == "$1" ]] && ok "пунктов: $n" || bad "пунктов $n, ожидалось $1, вывод:"$'\n'"$OUT"
}
# Пункт целиком, а не подстрока: так одинаково ловятся и «хвост не срезали»,
# и «срезали лишнего».
expect_line() { # expect_line <строка>
    printf '%s\n' "$OUT" | grep -qxF "$1" \
        && ok "пункт ровно «$1»" || bad "нет пункта ровно «$1», вывод:"$'\n'"$OUT"
}

# --------------------------------------------------------------------------
# Чем разбирать JSON. jq — первый выбор, python — запасной (он же нужен там,
# где проверяется ветка БЕЗ jq). Питон проверяется не наличием файла, а
# ответом: в Windows PATH лежит заглушка из Microsoft Store, которая
# существует, отвечает кодом 0 и не выполняет ничего.
PY_BIN=""
for c in python3 python; do
    command -v "$c" >/dev/null 2>&1 || continue
    [[ "$("$c" -c 'print("DK-PY-OK")' 2>/dev/null)" == "DK-PY-OK" ]] || continue
    PY_BIN="$c"; break
done
HAVE_JQ=0
command -v jq >/dev/null 2>&1 && printf '{"a":"б"}' | jq -e . >/dev/null 2>&1 && HAVE_JQ=1

JSON_KIND=""; JSON_BIN=""
if (( HAVE_JQ )); then
    JSON_KIND=jq; JSON_BIN=jq
elif [[ -n "$PY_BIN" ]]; then
    JSON_KIND=py; JSON_BIN="$PY_BIN"
fi
(( HAVE_JQ )) || printf 'внимание: jq не найден — jq-ветка обоих workflow пропущена\n' >&2
[[ -n "$JSON_KIND" ]] || printf 'внимание: нет ни jq, ни python — обратный разбор version.json пропущен\n' >&2

cat > "$TMP/get.py" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    d = json.load(fh)
v = d.get(sys.argv[2])
with open(sys.argv[3], 'wb') as out:
    out.write(v.encode('utf-8') if isinstance(v, str) else b'')
PY
cat > "$TMP/haskey.py" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    d = json.load(fh)
sys.exit(0 if sys.argv[2] in d else 1)
PY
cat > "$TMP/valid.py" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    json.load(fh)
PY

json_valid() { # json_valid <файл>
    case "$JSON_KIND" in
        jq) jq -e . "$1" >/dev/null 2>&1 ;;
        py) "$JSON_BIN" "$TMP/valid.py" "$1" >/dev/null 2>&1 ;;
        *)  return 2 ;;
    esac
}
json_has() { # json_has <файл> <ключ>
    case "$JSON_KIND" in
        jq) jq -e --arg k "$2" 'has($k)' "$1" >/dev/null 2>&1 ;;
        py) "$JSON_BIN" "$TMP/haskey.py" "$1" "$2" >/dev/null 2>&1 ;;
        *)  return 2 ;;
    esac
}
# Значение кладётся в файл, а не в переменную: сравнивать придётся побайтно,
# вместе с хвостовым переводом строки. jq зовётся с -j именно поэтому — -r
# дописал бы свой перевод строки и подделал бы сравнение.
json_get() { # json_get <файл> <ключ> <куда>
    case "$JSON_KIND" in
        jq) jq -j --arg k "$2" '.[$k] // empty' "$1" > "$3" 2>/dev/null ;;
        py) "$JSON_BIN" "$TMP/get.py" "$1" "$2" "$3" >/dev/null 2>&1 ;;
        *)  return 2 ;;
    esac
}

# Так версию читает выкатка — тем же самым sed, что стоит в check_version и
# current_live_version (server/lib.sh) и в таблице bin/dk. Разбора JSON там
# нет и не будет: на сервере не гарантирован даже jq. Значит и проверять надо
# ровно этим, а не «ну, файл же валидный».
gate_version() { # gate_version <файл>
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1
}

# --------------------------------------------------------------------------
case_ "0. Писатели version.json вырезаны из исходников, а не переписаны здесь"

# Если якорь уехал — вырезка вернёт пустоту, и весь набор ниже начнёт
# проверять воздух. Поэтому каждая вырезка проверяется отдельно и громко.
awk '/^json_escape\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}' "$DEPLOY" > "$TMP/json_escape.sh"
awk '/^    VDIR="\$ARTIFACT_DIR"/{f=1} f{print} f&&/version\.json"$/{exit}' "$DEPLOY" > "$TMP/vwrite.sh"
awk '/^ +OK=0$/{f=1} f{print} f&&/^ +cat "\$(T|ARTIFACT_DIR)\/version\.json"$/{exit}' "$WF_GO" > "$TMP/wf-go.sh"
awk '/^ +OK=0$/{f=1} f{print} f&&/^ +cat "\$(T|ARTIFACT_DIR)\/version\.json"$/{exit}' "$WF_STATIC" > "$TMP/wf-static.sh"

# -e перед образцом обязателен: искомое начинается с двух минусов, и без него
# grep разбирает его как свой аргумент.
check_cut() { # check_cut <файл> <что должно быть внутри> <имя для сообщения>
    if [[ -s "$1" ]] && grep -qF -e "$2" "$1"; then
        ok "вырезан писатель: $3"
    else
        bad "НЕ ВЫРЕЗАН писатель: $3 — якорь в исходнике уехал, набор проверяет пустоту"
    fi
}
check_cut "$TMP/json_escape.sh" 'out+="\\u$hex"'      "bin/deploy: json_escape"
check_cut "$TMP/vwrite.sh"      'changelog\":\"'      "bin/deploy: запись version.json"
check_cut "$TMP/wf-go.sh"       '--rawfile changelog' "go-service.yml: шаг «Отметить версию»"
check_cut "$TMP/wf-static.sh"   '--rawfile changelog' "static-site.yml: шаг «Отметить версию»"

# Оба workflow обязаны собирать файл ОДНИМ И ТЕМ ЖЕ кодом. Расходятся они не
# в теории: правку, сделанную в одном, во втором забывают, и половина целей
# хозяйства месяцами живёт со старым поведением. Единственная разрешённая
# разница — имя переменной каталога (у go-сервиса артефакт с public/).
sed 's/\$ARTIFACT_DIR\//$T\//g' "$TMP/wf-static.sh" > "$TMP/wf-static.norm"
sed 's/\$ARTIFACT_DIR\//$T\//g' "$TMP/wf-go.sh"     > "$TMP/wf-go.norm"
if cmp -s "$TMP/wf-go.norm" "$TMP/wf-static.norm"; then
    ok "go-service.yml и static-site.yml пишут version.json одинаково"
else
    bad "workflow разъехались:"$'\n'"$(diff "$TMP/wf-go.norm" "$TMP/wf-static.norm" || true)"
fi

# Читатель версии на сервере — не абстракция, а конкретный sed. Если он в
# lib.sh изменится, здешние проверки «версия читается» станут проверять чужой
# разбор, и это надо заметить.
if grep -qF 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$LIB"; then
    ok "sed версионного шлюза в server/lib.sh совпадает с тем, чем проверяем"
else
    bad "sed в server/lib.sh изменился — обновите gate_version в этом файле"
fi

# --------------------------------------------------------------------------
case_ "0a. Флаги, которыми зовут генератор все три пути выкатки, ему известны"

# ЭТОТ СЛУЧАЙ ЗАВЕДЁН ПО НАСТОЯЩЕЙ ПОЛОМКЕ, А НЕ НА ВСЯКИЙ СЛУЧАЙ.
#
# Оба переиспользуемых workflow звали генератор с «--all», а такого аргумента у
# него не было: пределы там снимались парой «--max 0 --budget 0». На неизвестный
# аргумент генератор отвечает строкой в stderr, ПУСТЫМ stdout и кодом 0 —
# гарантия «не может уронить выкатку» работает здесь против нас. Поэтому каждый
# релиз из CI (то есть основной путь выкатки всего хозяйства) уезжал вообще без
# списка изменений: пустой блок неотличим от «изменений не было», и заметить это
# было неоткуда — ни красного шага, ни строки в логе деплоя.
#
# Оба конца при этом были зелёными: у генератора свои тесты, у писателей свои, а
# СТЫК «чем именно его зовут» не проверял никто. Ровно тот дефект, ради которого
# заведён этот файл.
#
# Флаги вырезаются из вызывающих, а не перечисляются здесь: список, написанный
# руками, разъедется с кодом ровно так же тихо.
{
    # bin/deploy собирает вызов в массив CL_ARGS.
    grep -E 'CL_ARGS(\+)?=\(' "$DEPLOY"
    # Оба workflow зовут скачанный генератор одной командой в две строки.
    grep -A1 -F 'bash /tmp/changelog' "$WF_GO"
    grep -A1 -F 'bash /tmp/changelog' "$WF_STATIC"
} | grep -o -- '--[a-z][a-z-]*' | sort -u > "$TMP/cl-flags"

# Пустая вырезка обязана быть провалом, а не молчаливым «все ноль флагов
# известны»: якорь в исходнике уезжает так же легко, как и всё остальное.
if grep -qx -- '--repo' "$TMP/cl-flags"; then
    ok "вызовы генератора вырезаны из всех трёх писателей ($(wc -l < "$TMP/cl-flags" | tr -d ' ') флагов)"
else
    bad "вызовы генератора НЕ вырезаны — набор проверяет пустоту"
fi

# Проверка поведением, а не чтением разбора аргументов: спрашиваем сам скрипт
# ровно так, как это делает bin/deploy (cl_knows). Значение «x» подставляется
# всегда — флагу без значения оно достанется отдельным неизвестным аргументом,
# и поэтому в stderr ищется имя КОНКРЕТНОГО флага, а не подстрока вообще.
while IFS= read -r flag; do
    [[ -n "$flag" ]] || continue
    run_t 20 "$flag" x --quiet --repo "$TMP/.not-a-repo"
    if [[ "$ERR" == *"неизвестный аргумент: $flag"* ]]; then
        bad "генератор не знает $flag — а им его зовут: релиз уедет БЕЗ списка изменений, молча"
    else
        ok "генератор знает $flag"
    fi
done < "$TMP/cl-flags"

# --- обёртки над вырезанным кодом ------------------------------------------
#
# bin/deploy: посимвольный json_escape и printf одной строкой. Заглушки
# минимальны — msk скопирован по смыслу (время в файле никого здесь не
# интересует), git настоящий, поэтому обёртка работает из каталога репозитория.
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# Сгенерировано ci/contract-test.sh: код вырезан из bin/deploy как есть.'
    printf '%s\n' 'set -uo pipefail'
    printf '%s\n' 'cd "$DK_T_REPO" || exit 1'
    printf '%s\n' 'ARTIFACT_DIR="$DK_T_ARTIFACT"'
    printf '%s\n' 'VERSION="$DK_T_VERSION"'
    printf '%s\n' 'CHANGELOG="$DK_T_CHANGELOG"'
    printf '%s\n' "msk() { date -u -d '+3 hours' \"+\$1\" 2>/dev/null || date -u -v+3H \"+\$1\"; }"
    cat "$TMP/json_escape.sh"
    cat "$TMP/vwrite.sh"
} > "$TMP/w-deploy.sh"

# workflow: GitHub запускает шаг `run:` как `bash -e {0}` — здесь так же.
# Вырезка начинается с OK=0, а не с вычисления T/COMMIT/BUILT_AT: контракт —
# это сборка файла, а не то, откуда взялась дата. Обе переменные каталога
# выставлены на один и тот же путь, чтобы обёртка годилась обоим workflow.
mk_wf_wrapper() { # mk_wf_wrapper <вырезка> <куда>
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' '# Сгенерировано ci/contract-test.sh: шаг вырезан из workflow как есть.'
        printf '%s\n' 'set -e'
        printf '%s\n' 'VERSION="$DK_T_VERSION"'
        printf '%s\n' 'COMMIT="$DK_T_COMMIT"'
        printf '%s\n' 'BUILT_AT="$DK_T_BUILT_AT"'
        printf '%s\n' 'CHANGELOG_FILE="$DK_T_CHANGELOG_FILE"'
        printf '%s\n' 'T="$DK_T_ARTIFACT"; ARTIFACT_DIR="$DK_T_ARTIFACT"'
        cat "$1"
    } > "$2"
}
mk_wf_wrapper "$TMP/wf-go.sh"     "$TMP/w-go.sh"
mk_wf_wrapper "$TMP/wf-static.sh" "$TMP/w-static.sh"

for w in w-deploy w-go w-static; do
    if bash -n "$TMP/$w.sh" 2>"$TMP/synerr"; then
        ok "обёртка $w разбирается"
    else
        bad "обёртка $w не разбирается: $(cat "$TMP/synerr")"
    fi
done

VER="release-20260803-120000-1a2b3c4"

write_deploy() { # write_deploy <репозиторий> <текст> <каталог> <локаль>
    mkdir -p "$3"
    LC_ALL="$4" DK_T_REPO="$1" DK_T_VERSION="$VER" DK_T_CHANGELOG="$2" DK_T_ARTIFACT="$3" \
        "$BASH" "$TMP/w-deploy.sh" >"$TMP/w.out" 2>"$TMP/w.err"
    WRC=$?
}
write_wf() { # write_wf <обёртка> <файл со списком> <каталог> [каталог с фальшивым jq]
    mkdir -p "$3"
    local p="$PATH"
    [[ -n "${4:-}" ]] && p="$4:$PATH"
    PATH="$p" DK_T_VERSION="$VER" DK_T_COMMIT="1a2b3c4" \
        DK_T_BUILT_AT="2026-08-03T12:00:00+03:00" \
        DK_T_CHANGELOG_FILE="$2" DK_T_ARTIFACT="$3" \
        "$BASH" "$1" >"$TMP/w.out" 2>"$TMP/w.err"
    WRC=$?
}

# Общая проверка одного получившегося файла. Порядок утверждений — по цене
# ошибки: сначала «версия читается шлюзом» (без неё релиз не едет), потом
# «JSON валиден» (без этого не работает агент статуса), и только потом список.
check_version_file() { # check_version_file <файл> <имя писателя>
    local f="$1" who="$2" got
    if [[ ! -s "$f" ]]; then bad "$who: version.json не создан или пуст"; return; fi
    got="$(gate_version "$f")"
    [[ "$got" == "$VER" ]] \
        && ok "$who: версия читается шлюзом дословно" \
        || bad "$who: шлюз прочитал «$got», а записано «$VER» — выкатка не подтвердит себя"
    if [[ -z "$JSON_KIND" ]]; then
        skip "$who: нет ни jq, ни python — валидность JSON не проверить"
        return
    fi
    json_valid "$f" \
        && ok "$who: JSON валиден" \
        || bad "$who: JSON невалиден:"$'\n'"$(cat "$f")"
}

# --------------------------------------------------------------------------
case_ "1. Враждебный репозиторий: чужой текст в теме коммита"

# Каждая тема ниже — не фантазия, а класс поломки, который уже видели в
# истории хозяйства либо который ломает формат по построению.
R_HOSTILE="$(mkrepo hostile)"
commit "$R_HOSTILE" 'убрать "лишний" вызов из шаблона'
commit "$R_HOSTILE" 'поправить путь C:\Users\x\обновление'
commit "$R_HOSTILE" 'подделать "version": "PWNED" в ответе шлюза'
commit "$R_HOSTILE" "$(printf 'починить\tотступ\tтабами в шапке')"
commit "$R_HOSTILE" "$(printf 'убрать \x1b[31mкрасный\x1b[0m и \x01 из вывода')"
commit "$R_HOSTILE" 'обновить emoji 🚀 и ёлку ✨ в шапке'
commit "$R_HOSTILE" 'убрать <b>жирный</b> из шаблона & прочее'
commit "$R_HOSTILE" 'экранировать хвостовой слэш \'
printf 'тема первой строкой\nи её продолжение второй\n\nтело коммита\n' > "$TMP/msg"
gitp "$R_HOSTILE" commit -q --allow-empty -F "$TMP/msg"

# --width/--budget заданы с запасом намеренно: здесь проверяется экранирование,
# а не обрезка (её проверяет ci/changelog-test.sh). Обрезанная посередине тема
# спрятала бы половину враждебных символов от писателей.
gen "$R_HOSTILE" --depth 30 --max 20 --width 200 --budget 4000
expect_rc0
expect_has 'убрать "лишний" вызов'
expect_has 'C:\Users\x\обновление'
expect_has '"version": "PWNED"'
expect_has '&lt;b&gt;жирный&lt;/b&gt;'
expect_has '🚀'
cp "$TMP/out" "$TMP/cl.txt"
CHANGELOG_TEXT="$OUT"
# Файл — ровно то, что уходит в CHANGELOG_FILE обоих workflow, вместе с
# хвостовым переводом строки. Переменная — ровно то, что получает bin/deploy
# через $(…), то есть БЕЗ него. Это единственная законная разница между
# писателями, и ниже она проверяется явно.
printf '%s' "$CHANGELOG_TEXT" > "$TMP/cl-nonl.txt"

case_ "1a. json_escape в отрыве: то, что обязано быть экранировано"
esc_probe() { # esc_probe <локаль> <строка> <что ждём в выводе> <как называется>
    local got
    got="$(LC_ALL="$1" DK_T_S="$2" "$BASH" -c \
        'set -uo pipefail; . "$0"; json_escape "$DK_T_S"' "$TMP/json_escape.sh" 2>/dev/null)"
    [[ "$got" == *"$3"* ]] \
        && ok "$4 → $3 (LC_ALL=$1)" \
        || bad "$4: ждали «$3», получили «$got» (LC_ALL=$1)"
}
for loc in C C.utf8; do
    esc_probe "$loc" 'убрать "лишний" вызов'   '\"лишний\"'  'двойная кавычка'
    esc_probe "$loc" 'путь C:\Users\x'         'C:\\Users\\x' 'обратный слэш'
    esc_probe "$loc" 'хвостовой слэш \'        'слэш \\'      'хвостовой слэш'
    esc_probe "$loc" "$(printf 'а\nб')"        'а\nб'         'перевод строки'
    esc_probe "$loc" "$(printf 'а\tб')"        'а\tб'         'табуляция'
    esc_probe "$loc" "$(printf 'а\rб')"        'а\rб'         'возврат каретки'
    esc_probe "$loc" "$(printf 'а\x01б')"      'а\u0001б'     'управляющий символ'
    esc_probe "$loc" "$(printf 'цвет \x1b[31m')" '\u001b[31m' 'ANSI-последовательность'
    esc_probe "$loc" 'ёлка 🚀 и текст'          'ёлка 🚀 и'   'юникод проходит насквозь'
done

# Одна и та же строка обязана экранироваться одинаково в любой локали.
# bin/deploy, в отличие от bin/changelog, LC_ALL не выставляет: он работает в
# том, что дала машина. Раннер — UTF-8, Git Bash на машине разработчика —
# что угодно. Файл, который на одной машине валиден, а на другой нет, — это
# отладка длиной в день на ровном месте.
E1="$(LC_ALL=C      DK_T_S="$CHANGELOG_TEXT" "$BASH" -c 'set -uo pipefail; . "$0"; json_escape "$DK_T_S"' "$TMP/json_escape.sh" 2>/dev/null)"
E2="$(LC_ALL=C.utf8 DK_T_S="$CHANGELOG_TEXT" "$BASH" -c 'set -uo pipefail; . "$0"; json_escape "$DK_T_S"' "$TMP/json_escape.sh" 2>/dev/null)"
[[ -n "$E1" && "$E1" == "$E2" ]] \
    && ok "экранирование не зависит от локали" \
    || bad "экранирование разъехалось по локалям: C даёт ${#E1} байт, C.utf8 — ${#E2}"

case_ "1b. Писатель bin/deploy"
write_deploy "$R_HOSTILE" "$CHANGELOG_TEXT" "$TMP/out-deploy" C.utf8
(( WRC == 0 )) && ok "писатель отработал без ошибки" || bad "писатель вышел с кодом $WRC: $(cat "$TMP/w.err")"
check_version_file "$TMP/out-deploy/version.json" "bin/deploy"

# public/ — не косметика: статику сервис раздаёт именно оттуда, и только так
# файл виден по /version.json. Промахнувшийся каталог = «релиз не подтверждает
# себя» на каждой выкатке.
mkdir -p "$TMP/out-deploy-pub/public"
write_deploy "$R_HOSTILE" "$CHANGELOG_TEXT" "$TMP/out-deploy-pub" C.utf8
[[ -s "$TMP/out-deploy-pub/public/version.json" ]] \
    && ok "bin/deploy: при наличии public/ файл кладётся туда" \
    || bad "bin/deploy: public/ есть, а version.json лёг мимо"

case_ "1c. Писатель go-service.yml (шаг «Отметить версию»)"
if (( HAVE_JQ )); then
    write_wf "$TMP/w-go.sh" "$TMP/cl.txt" "$TMP/out-go"
    (( WRC == 0 )) && ok "шаг отработал без ошибки" || bad "шаг вышел с кодом $WRC: $(cat "$TMP/w.err")"
    check_version_file "$TMP/out-go/version.json" "go-service.yml"
else
    skip "jq не найден — jq-ветку go-service.yml проверить нечем (на раннере jq есть всегда)"
fi

case_ "1d. Писатель static-site.yml (шаг «Отметить версию в сборке»)"
if (( HAVE_JQ )); then
    write_wf "$TMP/w-static.sh" "$TMP/cl.txt" "$TMP/out-static"
    (( WRC == 0 )) && ok "шаг отработал без ошибки" || bad "шаг вышел с кодом $WRC: $(cat "$TMP/w.err")"
    check_version_file "$TMP/out-static/version.json" "static-site.yml"
else
    skip "jq не найден — jq-ветку static-site.yml проверить нечем (на раннере jq есть всегда)"
fi

case_ "1e. Тема, изображающая фрагмент JSON, не подменяет версию для шлюза"
# Отдельный случай, потому что читает файл не разборщик JSON, а жадный sed с
# `head -1`. Тема «подделать "version": "PWNED"» проверяет ровно это: если
# кавычка из темы уедет в файл неэкранированной, шлюз прочитает PWNED и
# сверка версии либо провалится, либо (страшнее) сойдётся не с тем.
for f in "$TMP/out-deploy/version.json" "$TMP/out-go/version.json" "$TMP/out-static/version.json"; do
    [[ -s "$f" ]] || continue
    got="$(gate_version "$f")"
    [[ "$got" == "PWNED" ]] && bad "$(basename "$(dirname "$f")"): шлюз прочитал PWNED из темы коммита"
    [[ "$got" == "$VER" ]] \
        && ok "$(basename "$(dirname "$f")"): шлюз прочитал настоящую версию" \
        || bad "$(basename "$(dirname "$f")"): шлюз прочитал «$got»"
done
# И то же самое дословно: подделка обязана лежать в файле как значение поля
# changelog, а не как второе поле version.
if [[ -n "$JSON_KIND" && -s "$TMP/out-deploy/version.json" ]]; then
    json_get "$TMP/out-deploy/version.json" changelog "$TMP/back.txt"
    grep -qF '"version": "PWNED"' "$TMP/back.txt" \
        && ok "подделка сохранилась внутри changelog, а не стала полем" \
        || bad "подделка не доехала до changelog — текст потерялся по дороге"
fi

case_ "1f. Управляющие символы экранированы ОБОИМИ писателями одинаково"
# \u001b и \u0001 — единственное место, где посимвольный bash и jq обязаны
# сойтись байт в байт. Разойдись они, и один и тот же релиз выглядел бы на
# статус-странице по-разному в зависимости от того, каким путём его выкатили.
for f in "$TMP/out-deploy/version.json" "$TMP/out-go/version.json" "$TMP/out-static/version.json"; do
    [[ -s "$f" ]] || continue
    who="$(basename "$(dirname "$f")")"
    # Отдельная ветка, чтобы красный тест называл настоящую причину: если
    # писатель ушёл в запасную ветку, ключа changelog нет вовсе, и «сырой
    # управляющий символ» был бы неправдой про то, что случилось.
    if [[ -n "$JSON_KIND" ]] && ! json_has "$f" changelog; then
        bad "$who: ключа changelog нет вовсе — список пропал по дороге"
        continue
    fi
    grep -qF '\u001b' "$f" && grep -qF '\u0001' "$f" \
        && ok "$who: управляющие символы ушли в \\uXXXX" \
        || bad "$who: сырой управляющий символ в JSON-строке — файл отвергнет любой разборщик"
done

case_ "1g. Пустой список — ключа changelog нет вовсе"
# Пустое "changelog":"" читается агентом как «изменений нет», а не «список не
# считался», и на статус-странице появляется пустой блок «Изменения».
write_deploy "$R_HOSTILE" "" "$TMP/out-empty" C.utf8
check_version_file "$TMP/out-empty/version.json" "bin/deploy (пустой список)"
if [[ -n "$JSON_KIND" ]]; then
    json_has "$TMP/out-empty/version.json" changelog \
        && bad "bin/deploy: ключ changelog появился при пустом списке" \
        || ok "bin/deploy: ключа changelog нет"
fi
: > "$TMP/cl-empty.txt"
if (( HAVE_JQ )); then
    write_wf "$TMP/w-go.sh" "$TMP/cl-empty.txt" "$TMP/out-go-empty"
    check_version_file "$TMP/out-go-empty/version.json" "go-service.yml (пустой список)"
    if [[ -n "$JSON_KIND" ]]; then
        json_has "$TMP/out-go-empty/version.json" changelog \
            && bad "go-service.yml: ключ changelog появился при пустом файле" \
            || ok "go-service.yml: ключа changelog нет"
    fi
else
    skip "jq не найден — пустой список в workflow не проверить"
fi

case_ "1h. jq сломан или отсутствует — версия уезжает всё равно"
# Запасная ветка шага. Список изменений — украшение, версия — обязательство:
# release.sh без неё не пустит релиз. Фальшивый jq, падающий с ненулевым
# кодом, ведёт в ту же ветку, что и отсутствие jq (command -v не находит).
mkdir -p "$TMP/fakejq"
{
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' '# Заглушка: jq в PATH есть, но собрать файл не может.'
    printf '%s\n' 'exit 1'
} > "$TMP/fakejq/jq"
chmod +x "$TMP/fakejq/jq"
for pair in "w-go.sh:out-go-nojq" "w-static.sh:out-static-nojq"; do
    wrap="${pair%%:*}"; dir="${pair##*:}"
    write_wf "$TMP/$wrap" "$TMP/cl.txt" "$TMP/$dir" "$TMP/fakejq"
    (( WRC == 0 )) \
        && ok "$wrap: шаг не свалился без рабочего jq" \
        || bad "$wrap: шаг вышел с кодом $WRC — сломанный jq уронил выкатку"
    grep -qF '::warning::' "$TMP/w.out" \
        && ok "$wrap: причина объявлена в логе шага" \
        || bad "$wrap: молчаливый откат на запасную ветку"
    check_version_file "$TMP/$dir/version.json" "$wrap (без jq)"
    if [[ -n "$JSON_KIND" ]]; then
        json_has "$TMP/$dir/version.json" changelog \
            && bad "$wrap: запасная ветка не обещала списка, а он есть" \
            || ok "$wrap: запасная ветка отдала версию без списка"
    fi
done

# --------------------------------------------------------------------------
case_ "2. Сквош-мерж — норма этого хозяйства"

# На «Squash and merge» вся ветка схлопывается в ОДИН коммит на main, тема
# которого — заголовок PR. Значит список изменений релиза — это, как правило,
# ровно заголовки PR, а «(#42)», который GitHub дописывает сам, — служебный
# шум: в чате и на статус-странице номер PR не кликается и ничего не говорит.
#
# Проверяется именно тот диапазон, который CI берёт на самом деле:
# github.event.before → HEAD, то есть предыдущий HEAD ветки.
R_SQ="$(mkrepo squash)"
commit "$R_SQ" "завести проект"
BEFORE="$(git -C "$R_SQ" rev-parse HEAD)"
branch_work "$R_SQ" feat/interface "черновик разметки" "поправить отступы" "дописать тест"
squash_pr "$R_SQ" feat/interface "Название изменения (#42)"
AFTER="$(git -C "$R_SQ" rev-parse HEAD)"

case_ "2a. Сквош действительно сквош, а не слияние"
[[ "$(git -C "$R_SQ" log -1 --format='%p')" == *' '* ]] \
    && bad "получилось слияние, а не сквош — случай ничего не проверяет" \
    || ok "у коммита один родитель"
[[ "$(git -C "$R_SQ" rev-list --count "$BEFORE..$AFTER")" == 1 ]] \
    && ok "в диапазоне ровно один коммит — ветка схлопнута" \
    || bad "в диапазоне $(git -C "$R_SQ" rev-list --count "$BEFORE..$AFTER") коммитов, ожидался 1"

case_ "2b. Диапазон пуша даёт ровно заголовок PR, без «(#42)»"
gen "$R_SQ" --since "$BEFORE" --width 200
expect_rc0
expect_lines 1
expect_line "• Название изменения"
expect_hasnt "(#42)"
expect_hasnt "черновик разметки"
expect_hasnt "дописать тест"
# Лог шага «Собрать список изменений» — единственное место, где потом ищут,
# по какому диапазону посчитан релиз. stderr генератора там не глушится
# намеренно, и одна строка в нём — часть договора, а не отладка.
[[ "$ERR" == *"от переданной ревизии"* ]] \
    && ok "выбранный диапазон назван в stderr" \
    || bad "stderr не объяснил диапазон: $ERR"

case_ "2c. Явный --to: диапазон previous-sha..new-sha целиком"
gen "$R_SQ" --since "$BEFORE" --to "$AFTER" --width 200
expect_rc0; expect_lines 1; expect_line "• Название изменения"

case_ "2d. Dependabot-сквош отсеивается, обычный PR — нет"
R_MIX="$(mkrepo squash-mixed)"
commit "$R_MIX" "завести проект"
BEFORE_MIX="$(git -C "$R_MIX" rev-parse HEAD)"
branch_work "$R_MIX" feat/one   "правка один"  "правка два"
squash_pr  "$R_MIX" feat/one   "Не выдавать недоставленное уведомление за успех (#41)"
branch_work "$R_MIX" dependabot/gha "поднять action"
squash_pr  "$R_MIX" dependabot/gha "deps: bump x from 1 to 2 (#43)"
branch_work "$R_MIX" dependabot/gha2 "поднять ещё один action"
squash_pr  "$R_MIX" dependabot/gha2 "Bump actions/checkout from 4 to 5 (#44)"
branch_work "$R_MIX" feat/two   "правка три"
squash_pr  "$R_MIX" feat/two   "Считать пропавший файл ошибкой обновления (#42)"
gen "$R_MIX" --since "$BEFORE_MIX" --depth 30 --max 20 --width 200
expect_rc0
expect_line "• Не выдавать недоставленное уведомление за успех"
expect_line "• Считать пропавший файл ошибкой обновления"
expect_hasnt "bump"
expect_hasnt "Bump"
expect_hasnt "(#43)"
expect_hasnt "(#44)"
expect_lines 2

case_ "2e. Несколько сквошей подряд с прошлого релиза"
# Обычный релиз этого хозяйства: с прошлого тега прилетело три PR и один
# dependabot. Диапазон здесь выбирает сам генератор (по тегу), а не CI —
# так работает выкатка руками и выкатка по тегу.
R_REL="$(mkrepo squash-release)"
commit "$R_REL" "завести проект"
gitp "$R_REL" tag v1.0.0
branch_work "$R_REL" pr/one   "шаг один"  "шаг два"
squash_pr  "$R_REL" pr/one   "Починить обрыв скачивания больших файлов (#101)"
branch_work "$R_REL" pr/bot   "бот"
squash_pr  "$R_REL" pr/bot   "deps: bump actions/setup-go from 5 to 7 (#102)"
branch_work "$R_REL" pr/two   "шаг три" "шаг четыре"
squash_pr  "$R_REL" pr/two   "Возить конфиг nginx на прод обоими путями выкатки (#103)"
branch_work "$R_REL" pr/three "шаг пять"
squash_pr  "$R_REL" pr/three "Запрет упоминаний ИИ проверять машиной (#104)"
gen "$R_REL" --depth 30 --max 20 --width 200
expect_rc0
expect_lines 3
expect_line "• Запрет упоминаний ИИ проверять машиной"
expect_line "• Возить конфиг nginx на прод обоими путями выкатки"
expect_line "• Починить обрыв скачивания больших файлов"
expect_hasnt "#10"
# Порядок — новое сверху: читатель релиза смотрит первую строку.
[[ "$(printf '%s\n' "$OUT" | grep -n 'Запрет упоминаний' | cut -d: -f1)" \
   -lt "$(printf '%s\n' "$OUT" | grep -n 'Починить обрыв' | cut -d: -f1)" ]] \
    && ok "порядок пунктов: новое сверху" || bad "порядок пунктов перевёрнут:"$'\n'"$OUT"

case_ "2f. Перефильтровать хуже, чем недофильтровать: «(#NN)» не везде шум"
# Хвост «(#42)» дописывает GitHub в КОНЕЦ темы, и срезается только он.
# Номер посреди фразы написал человек, он часть предложения. Тот же принцип,
# что и у списка шума в bin/changelog: лишний пункт видно, пропавший — нет.
R_HASH="$(mkrepo hash)"
commit "$R_HASH" "поправить кодировку (см. #42)"
commit "$R_HASH" "Track tools manifest, bump jsdom to 30 (#45)"
commit "$R_HASH" "убрать (#42) из середины строки в шаблоне"
commit "$R_HASH" "рефакторинг (без номера)"
commit "$R_HASH" "Обновить README (#7)"
gen "$R_HASH" --depth 30 --max 20 --width 200
expect_rc0
expect_lines 5
expect_line "• поправить кодировку (см. #42)"
expect_line "• Track tools manifest, bump jsdom to 30"
expect_line "• убрать (#42) из середины строки в шаблоне"
expect_line "• рефакторинг (без номера)"
expect_line "• Обновить README"

# --------------------------------------------------------------------------
case_ "3. Цепочка целиком: stdout генератора → version.json → обратно"

# Половина цепочки на Go (агент статус-страницы, бот) проверена своими
# суитами. Здесь — граница: то, что shell отдаёт и принимает обратно. Текст
# обязан вернуться ДОСЛОВНО. Двойное экранирование — самый вероятный дефект
# на этой границе: заметить его глазами в логе почти невозможно, а в чате он
# выглядит как «бот сошёл с ума».
if [[ -z "$JSON_KIND" ]]; then
    skip "нет ни jq, ни python — обратный разбор version.json не проверить"
else
    # bin/deploy получает текст через $(…), то есть без хвостового перевода
    # строки. Оба workflow кладут в файл вывод генератора ЦЕЛИКОМ, вместе с
    # ним, и --rawfile сохраняет его дословно. Разница ровно в одном байте,
    # она известна и намеренна: значение поля всё равно нормализует читатель.
    if [[ -s "$TMP/out-deploy/version.json" ]]; then
        json_get "$TMP/out-deploy/version.json" changelog "$TMP/back-deploy.txt"
        cmp -s "$TMP/back-deploy.txt" "$TMP/cl-nonl.txt" \
            && ok "bin/deploy: текст вернулся байт в байт" \
            || bad "bin/deploy: текст изменился по дороге:"$'\n'"$(diff "$TMP/cl-nonl.txt" "$TMP/back-deploy.txt" || true)"
    fi
    if (( HAVE_JQ )) && [[ -s "$TMP/out-go/version.json" ]]; then
        json_get "$TMP/out-go/version.json" changelog "$TMP/back-go.txt"
        cmp -s "$TMP/back-go.txt" "$TMP/cl.txt" \
            && ok "go-service.yml: текст вернулся байт в байт, вместе с хвостовым \\n" \
            || bad "go-service.yml: текст изменился по дороге:"$'\n'"$(diff "$TMP/cl.txt" "$TMP/back-go.txt" || true)"
    fi
    if (( HAVE_JQ )) && [[ -s "$TMP/out-static/version.json" ]]; then
        json_get "$TMP/out-static/version.json" changelog "$TMP/back-static.txt"
        cmp -s "$TMP/back-static.txt" "$TMP/cl.txt" \
            && ok "static-site.yml: текст вернулся байт в байт" \
            || bad "static-site.yml: текст изменился по дороге"
    fi

    case_ "3a. Двойного экранирования нет ни на одной стороне"
    for b in back-deploy back-go back-static; do
        [[ -s "$TMP/$b.txt" ]] || continue
        # Кавычка вернулась кавычкой, а не \" — иначе в чате появится
        # «убрать \"лишний\" вызов».
        grep -qF '"лишний"' "$TMP/$b.txt" && ! grep -qF '\"лишний\"' "$TMP/$b.txt" \
            && ok "$b: кавычки не задвоились" || bad "$b: кавычки задвоились"
        # Слэш вернулся одиночным.
        grep -qF 'C:\Users\x\обновление' "$TMP/$b.txt" \
            && ok "$b: обратные слэши не задвоились" || bad "$b: обратные слэши задвоились"
        # HTML экранирован РОВНО ОДИН раз — тем самым esc_html в генераторе.
        # &amp;lt; означает, что кто-то экранировал уже экранированное, и
        # Telegram покажет «&lt;b&gt;» текстом.
        grep -qF '&lt;b&gt;' "$TMP/$b.txt" && ! grep -qF '&amp;lt;' "$TMP/$b.txt" \
            && ok "$b: HTML экранирован один раз" || bad "$b: HTML экранирован дважды"
        # Переводы строк между пунктами вернулись настоящими переводами
        # строк, а не парой символов \ и n.
        nb="$(grep -c '^• ' "$TMP/$b.txt")"
        ng="$(grep -c '^• ' "$TMP/cl.txt")"
        [[ "$nb" == "$ng" ]] \
            && ok "$b: пунктов после круга столько же ($nb)" \
            || bad "$b: пунктов было $ng, стало $nb — переводы строк не пережили круг"
    done

    case_ "3b. Юникод и HTML-сущности целы, UTF-8 не порван"
    for b in back-deploy back-go back-static; do
        [[ -s "$TMP/$b.txt" ]] || continue
        iconv -f UTF-8 -t UTF-8 < "$TMP/$b.txt" >/dev/null 2>&1 \
            && ok "$b: валидный UTF-8" || bad "$b: битый UTF-8"
        grep -qF '🚀' "$TMP/$b.txt" && ok "$b: эмодзи на месте" || bad "$b: эмодзи потерялось"
    done
fi

case_ "3c. Сквош-релиз проходит цепочку целиком"
# Самый частый настоящий вход: релиз из трёх сквошей. Проверяется не
# экранирование, а то, что осмысленный список доезжает до version.json и
# читается обратно ровно тем же составом.
gen "$R_REL" --depth 30 --max 20 --width 200
cp "$TMP/out" "$TMP/cl-rel.txt"
write_deploy "$R_REL" "$OUT" "$TMP/out-rel" C.utf8
check_version_file "$TMP/out-rel/version.json" "bin/deploy (сквош-релиз)"
if [[ -n "$JSON_KIND" && -s "$TMP/out-rel/version.json" ]]; then
    json_get "$TMP/out-rel/version.json" changelog "$TMP/back-rel.txt"
    grep -qF "Запрет упоминаний ИИ проверять машиной" "$TMP/back-rel.txt" \
        && ok "заголовок PR доехал до version.json" || bad "заголовок PR потерялся"
    grep -qF "(#104)" "$TMP/back-rel.txt" \
        && bad "хвост «(#104)» доехал до version.json" || ok "хвоста «(#NN)» в файле нет"
    [[ "$(grep -c '^• ' "$TMP/back-rel.txt")" == 3 ]] \
        && ok "в файле те же три пункта" || bad "в файле не три пункта"
fi

case_ "3d. Всё сообщение о релизе укладывается в лимит Telegram"
# Потолок темы — 120 символов (CLAUDE.md), восемь пунктов кириллицей — это
# около 960 единиц UTF-16, плюс шапка и хвост. Считается по-честному в
# UTF-16, потому что Telegram считает именно так, а не в байтах.
R_TG="$(mkrepo telegram)"
for i in {1..12}; do
    commit "$R_TG" "Не выдавать недоставленное уведомление за успех в цели номер $i, а разбирать ответ"
done
gen "$R_TG" --depth 20 --max 8
PREFIX="🚀 <b>samoylove</b> выкачен
<code>release-20260803-120000-1a2b3c4</code>
<a href=\"https://example.invalid/\">открыть</a>"
FULL="$PREFIX
$OUT"
U16=""
[[ -n "$PY_BIN" ]] && U16="$(DK_T_S="$FULL" "$PY_BIN" -c \
    'import os; print(len(os.environ["DK_T_S"].encode("utf-16-le"))//2)' 2>/dev/null)"
if [[ "$U16" =~ ^[0-9]+$ ]]; then
    (( U16 <= 4096 )) && ok "сообщение $U16 единиц UTF-16 ≤ 4096" \
                      || bad "сообщение $U16 единиц UTF-16 > 4096"
else
    # Без питона считаем байтами: для кириллицы байт вдвое больше единицы
    # UTF-16, то есть оценка заведомо в запас — но именно в запас, а не в
    # обратную сторону, поэтому «уложились» здесь остаётся правдой.
    n="$(printf '%s' "$FULL" | LC_ALL=C wc -c | tr -d ' ')"
    (( n <= 4096 )) && ok "сообщение $n байт ≤ 4096 (оценка сверху)" \
                    || bad "сообщение $n байт > 4096"
fi

# --------------------------------------------------------------------------
# Стык действия и доставки: каждый флаг, которым action.yml зовёт notify.sh,
# должен быть тому известен.
#
# Половины писали порознь, и разъехались они молча: действие передавало
# --repo/--run-id/--run-attempt/--ssh-key/--ssh-host/--ssh-user, а notify.sh
# знает --key/--host/--user и берёт репозиторий с прогоном из GITHUB_*. Ни
# один тест этого не ловил — сквозной проверяет notify.sh напрямую, минуя
# действие, — и первая же выкатка после мержа упала на «неизвестный аргумент
# «--repo»», не сказав в чат ни слова.
ACT="$KIT/.github/actions/notify/action.yml"
NSH="$KIT/lib/notify.sh"
if [[ -f "$ACT" && -f "$NSH" ]]; then
    unknown=""
    # Флаги в ARGS=( ... ) действия: строки вида `--имя "$ПЕРЕМЕННАЯ"` и
    # `ARGS+=(--имя ...)`.
    for f in $(grep -oE '(^|\()[[:space:]]*--[a-z][a-z-]*' "$ACT" \
               | grep -oE -- '--[a-z][a-z-]*' | sort -u); do
        grep -qE "^[[:space:]]*$f\)" "$NSH" || unknown="$unknown $f"
    done
    if [[ -z "$unknown" ]]; then
        ok "все флаги действия известны notify.sh"
    else
        bad "действие зовёт notify.sh флагами, которых у него нет:$unknown"
    fi
else
    bad "нет action.yml или lib/notify.sh — стык нечем проверить"
fi

# --------------------------------------------------------------------------
# Список изменений доезжает до карточки в чате.
#
# Он не доезжал месяц, и молча: генератор считал его исправно, version.json
# получал, а событие — нет, потому что у действия просто не было входа для
# готового HTML. В чате это выглядело как «бот пишет, но changelog никогда не
# показывает», и отличить это от «изменений не было» на глаз нельзя.
for WF in "$KIT/.github/workflows/static-site.yml" "$KIT/.github/workflows/go-service.yml"           "$KIT/.github/workflows/desktop-artifact.yml"; do
    NAME="$(basename "$WF")"
    if grep -q 'changelog-html:' "$WF"; then
        ok "$NAME передаёт список изменений в событие"
    else
        bad "$NAME не передаёт changelog-html — карточка уедет без изменений"
    fi
done
if grep -q 'changelog-html:' "$KIT/.github/actions/notify/action.yml"; then
    ok "у действия есть вход changelog-html"
else
    bad "у действия нет входа changelog-html — передавать некуда"
fi

# --------------------------------------------------------------------------
printf '\n\033[1mитого: %d прошло, %d провалено, %d пропущено\033[0m\n' "$pass" "$fail" "$skipped"
(( skipped > 0 )) && printf 'пропуски — это не «прошло»: на раннере jq и python есть.\n'
(( fail == 0 )) || exit 1
exit 0
