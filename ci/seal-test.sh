#!/usr/bin/env bash
# Прогон seal_release (server/lib.sh) и того, где её зовут release.sh и
# rollback.sh.
#
#   ci/seal-test.sh
#
# ЗАЧЕМ ЭТОТ ФАЙЛ. Каталог релиза раскладывается от root и отдаётся группе
# службы (OWNER=root:www-data). Режимы при этом приезжают из архива, а на своих
# раннерах umask 002 — без seal_release релиз ложится с правами 775/664, и
# служба может переписать собственный код. Отказ молчаливый: всё работает, пока
# дырой не воспользуются. Проверено на живом cs2 19.09.2026 — бинарь
# /opt/cs2-api/current/cs2-api лежал с правами 775.
#
# Функция берётся НАСТОЯЩАЯ, через `source server/lib.sh`: копия в тесте
# проверяла бы копию. Вторая половина — места вызова, читаются из исходников:
# печать после переключения симлинка оставляла бы окно, в котором живой релиз
# доступен группе на запись, а печать до chown снималась бы им же, если бы
# chown когда-нибудь стал выставлять режимы.

set -uo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$KIT/server/lib.sh"
REL="$KIT/server/release.sh"
RB="$KIT/server/rollback.sh"
for f in "$LIB" "$REL" "$RB"; do
    [[ -f "$f" ]] || { echo "не найден: $f" >&2; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0; skipped=0
t_ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$(( pass + 1 )); }
t_bad()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; fail=$(( fail + 1 )); }
t_skip() { printf '  \033[33m—\033[0m %s\n' "$*"; skipped=$(( skipped + 1 )); }
t_case() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# shellcheck source=/dev/null
source "$LIB"
set +e   # lib.sh включает errexit для себя; тесту он мешает считать провалы

mode() { stat -c %a "$1"; }

# Режимы есть не везде: на NTFS под Git Bash chmod ничего не меняет, и проверка
# режимов теряет смысл. Тогда первая половина пропускается ВСЛУХ.
MODES=0
: >"$TMP/.probe"; chmod 0664 "$TMP/.probe" 2>/dev/null
[[ "$(mode "$TMP/.probe")" == 664 ]] && MODES=1
rm -f "$TMP/.probe"

# Релиз ровно такой, каким его собирает раннер с umask 002.
make_release() {
    local d="$1"
    mkdir -p "$d/static/css"
    printf 'bin' >"$d/app";              chmod 0775 "$d/app"
    printf '{}'  >"$d/version.json";     chmod 0664 "$d/version.json"
    printf 'css' >"$d/static/css/a.css"; chmod 0666 "$d/static/css/a.css"
    chmod 0775 "$d/static"; chmod 0777 "$d/static/css"; chmod 0775 "$d"
}

if (( MODES )); then
    t_case "1. Релиз со сборки под umask 002"
    R="$TMP/rel1"; make_release "$R"
    seal_release "$R"; rc=$?
    (( rc == 0 )) && t_ok "код возврата 0" || t_bad "код возврата $rc"
    got="$(mode "$R") $(mode "$R/app") $(mode "$R/version.json") $(mode "$R/static") $(mode "$R/static/css") $(mode "$R/static/css/a.css")"
    [[ "$got" == "755 755 644 755 755 644" ]] \
        && t_ok "запись для группы и остальных снята везде: $got" \
        || t_bad "режимы после печати: $got (ждали 755 755 644 755 755 644)"

    t_case "2. Бит запуска и запись владельца не тронуты"
    [[ -x "$R/app" && -w "$R/version.json" ]] \
        && t_ok "бинарь исполняемый, владелец пишет" \
        || t_bad "печать отняла лишнее"

    t_case "3. Печать не выходит за каталог релиза по симлинку"
    OUT="$TMP/outside"; printf 'x' >"$OUT"; chmod 0666 "$OUT"
    R="$TMP/rel3"; make_release "$R"
    if ln -s "$OUT" "$R/link" 2>/dev/null && [[ -L "$R/link" ]]; then
        seal_release "$R"
        [[ "$(mode "$OUT")" == 666 ]] \
            && t_ok "файл вне релиза остался 666" \
            || t_bad "chmod прошёл по симлинку наружу: $(mode "$OUT")"
    else
        t_skip "симлинки здесь не создаются"
    fi

    t_case "4. Повторная печать — пустая операция"
    seal_release "$TMP/rel1" && [[ "$(mode "$TMP/rel1/app")" == 755 ]] \
        && t_ok "повтор проходит и ничего не меняет" \
        || t_bad "повторная печать упала или изменила режимы"
else
    t_skip "файловая система не хранит режимы — поведение chmod не проверить"
fi

t_case "5. Отсутствующий каталог — ошибка, а не тишина"
seal_release "$TMP/нет-такого" 2>/dev/null \
    && t_bad "печать несуществующего каталога прошла успешно" \
    || t_ok "ненулевой код"

# Первая строка вхождения шаблона в файле, 0 — если нет.
line_of() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }

t_case "6. release.sh: печать после chown и до переключения current"
L_CHOWN="$(line_of "$REL" 'chown -R "$OWNER" "$NEW_DIR"')"
L_SEAL="$(line_of "$REL" 'seal_release "$NEW_DIR"')"
L_SWITCH="$(line_of "$REL" 'switch_symlink "$CURRENT" "$NEW_DIR"')"
if [[ -n "$L_CHOWN" && -n "$L_SEAL" && -n "$L_SWITCH" ]] \
   && (( L_CHOWN < L_SEAL && L_SEAL < L_SWITCH )); then
    t_ok "chown:$L_CHOWN < seal:$L_SEAL < switch:$L_SWITCH"
else
    t_bad "порядок нарушен или вызова нет: chown=${L_CHOWN:-нет} seal=${L_SEAL:-нет} switch=${L_SWITCH:-нет}"
fi

t_case "7. rollback.sh: старый релиз печатается до того, как станет живым"
L_SEAL="$(line_of "$RB" 'seal_release "$TARGET"')"
L_SWITCH="$(line_of "$RB" 'switch_symlink "$CURRENT" "$TARGET"')"
if [[ -n "$L_SEAL" && -n "$L_SWITCH" ]] && (( L_SEAL < L_SWITCH )); then
    t_ok "seal:$L_SEAL < switch:$L_SWITCH"
else
    t_bad "порядок нарушен или вызова нет: seal=${L_SEAL:-нет} switch=${L_SWITCH:-нет}"
fi

printf '\nитого: \033[32m%d\033[0m прошло, \033[31m%d\033[0m провалено, \033[33m%d\033[0m пропущено\n' \
    "$pass" "$fail" "$skipped"
(( skipped )) && printf 'Пропущенные проверки — это НЕ зелёный прогон: на раннере они обязаны пройти.\n'
(( fail == 0 ))
