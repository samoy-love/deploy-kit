#!/usr/bin/env bash
# Выкатка релиза: разложить → бэкап → переключить → проверить → откатить при провале.
#
# Один скрипт на все проекты. Отличия архетипов сведены к двум флагам:
# статике нужен reload nginx, сервису — restart юнита.
#
#   release.sh --app snakes --version v1.2.3 --archive /tmp/snakes.tar.gz \
#              --root /opt/snakes --unit snakes.service \
#              --health https://snakes.samoy.love/healthz \
#              --version-url https://snakes.samoy.love/version.json \
#              --neighbours samoy.love,metro.samoy.love
#
# --dry-run печатает план и ничего не меняет.
#
# Версионный шлюз (см. lib.sh) отрабатывает до распаковки: версия обязана
# быть задана и строго новее той, что на проде. Отказ шлюза — выход с кодом 3,
# симлинк при этом не тронут вообще.
#   --no-version-file      цель не раздаёт version.json (WRITE_VERSION_FILE=0),
#                          сверять по имени релиза в симлинке
#   --allow-same-version   осознанно разрешить повтор/несравнимую версию
#
# Проверка монотонности (см. lib.sh) стоит вплотную к переключению симлинка:
# каталог нового релиза сравнивается с живым по времени сборки в имени, и
# выкатка старого релиза поверх нового отвергается — тем же кодом 3 и так же не
# трогая симлинк. Так ловится повторный запуск давнего прогона, workflow_dispatch
# на старом ref и задача, отвисевшая в очереди. Своего «разрешить старее» у
# выкатки нет: осознанное движение назад — это откат (rollback.sh --allow-older).

set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APP=""; VERSION=""; ARCHIVE=""; ROOT=""; UNIT=""; HEALTH=""; VERSION_URL=""
NEIGHBOURS=""; NGINX_RELOAD=0; KEEP=5; OWNER=""; DRY=0
ALLOW_SAME=0; NO_VERSION_FILE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)         APP="$2"; shift 2 ;;
        --version)     VERSION="$2"; shift 2 ;;
        --archive)     ARCHIVE="$2"; shift 2 ;;
        --root)        ROOT="$2"; shift 2 ;;
        --unit)        UNIT="$2"; shift 2 ;;
        --health)      HEALTH="$2"; shift 2 ;;
        --version-url) VERSION_URL="$2"; shift 2 ;;
        --neighbours)  NEIGHBOURS="$2"; shift 2 ;;
        --owner)       OWNER="$2"; shift 2 ;;
        --keep)        KEEP="$2"; shift 2 ;;
        --nginx-reload) NGINX_RELOAD=1; shift ;;
        --no-version-file)    NO_VERSION_FILE=1; shift ;;
        --allow-same-version) ALLOW_SAME=1; shift ;;
        --dry-run)     DRY=1; shift ;;
        *) die "неизвестный аргумент: $1" ;;
    esac
done

[[ -n "$APP" ]]     || die "нужен --app"
[[ -n "$VERSION" ]] || die "нужен --version"
[[ -n "$ARCHIVE" ]] || die "нужен --archive"

# Проверка аргументов, из которых собираются пути. Делается ДО всего
# остального: ниже эти значения превращаются в `rm -rf`, `tar -xzf -C` и
# `chown -R` от root, и одного «..» достаточно, чтобы увести их за пределы
# каталога выкатки. sudoers на аргументы не смотрит принципиально
# (server/sudoers.d/deploy-kit), поэтому граница проходит здесь.
assert_path_component "--app" "$APP"
assert_path_component "--version" "$VERSION"
ROOT="$(assert_deploy_root "${ROOT:-/opt/$APP}")" || exit 1

# Цель с WRITE_VERSION_FILE=0 (например, морда админки) version.json не
# раздаёт. Сверять по HTTP нечего — и шлюз, и проверка после выкатки
# опираются на имя релиза в симлинке.
if (( NO_VERSION_FILE )) && [[ -n "$VERSION_URL" ]]; then
    log "--no-version-file: сверка по $VERSION_URL отключена, сверяю по симлинку"
    VERSION_URL=""
fi

need_cmd tar; need_cmd curl; need_cmd flock

# --- Событие выкатки ------------------------------------------------------
#
# Сборкой и доставкой события занимается notify.sh (docs/events.md); здесь
# только точки, где о выкатке есть что сказать.
#
# ОТПРАВКА СОБЫТИЯ НЕ ИМЕЕТ ПРАВА ВЛИЯТЬ НА ИСХОД. Скрипт идёт под
# `set -Eeuo pipefail` и спасает прод: падение на строке уведомления означало
# бы, что уведомление сломало откат. Отсюда три меры разом, и каждая закрывает
# свой способ этого добиться:
#
#   * ОТДЕЛЬНЫЙ ПРОЦЕСС, а не `source`. Замок хоста висит на дескрипторе 9
#     (acquire_lock в lib.sh), и чужой `exec 9>…`, выполненный в нашем
#     процессе, снял бы его посреди выкатки. Заодно чужой `exit` остаётся
#     чужим, а `set -x`, ловушки и переменные не протекают сюда;
#   * timeout — сеть, недоступный хост журнала или залипший flock не должны
#     держать откат ни секунды сверх положенного;
#   * гашение кода возврата — включая 127 «нет такой команды» и 124 от
#     timeout: несделанное уведомление не превращается в несделанный откат.
#
# Вывод при этом НЕ глушится: уехало событие или нет — часть журнала выкатки,
# и молчание тут читалось бы как «всё хорошо».
#
# Путь: на сервере всё хозяйство лежит одной кучей в /opt/deploy-kit, в
# рабочей копии notify.sh живёт в lib/ — его зовут ещё пайплайн и bin/deploy.
DK_NOTIFY="${DK_NOTIFY:-}"
if [[ -z "$DK_NOTIFY" ]]; then
    _dk_dir="$(dirname "${BASH_SOURCE[0]}")"
    if   [[ -f "$_dk_dir/notify.sh" ]];        then DK_NOTIFY="$_dk_dir/notify.sh"
    elif [[ -f "$_dk_dir/../lib/notify.sh" ]]; then DK_NOTIFY="$_dk_dir/../lib/notify.sh"
    fi
fi

notify_event() {
    if [[ ! -f "$DK_NOTIFY" ]]; then
        log "notify.sh не найден — событие «$*» не отправлено"
        return 0
    fi
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 bash "$DK_NOTIFY" "$@" </dev/null || warn "событие не отправлено (код $?): $*"
    else
        bash "$DK_NOTIFY" "$@" </dev/null || warn "событие не отправлено (код $?): $*"
    fi
    return 0
}

RELEASES="$ROOT/releases"
CURRENT="$ROOT/current"
PREVIOUS="$ROOT/previous"
NEW_DIR="$RELEASES/$VERSION"

if (( DRY )); then
    LIVE="$(current_live_version "$VERSION_URL" "$CURRENT")"
    echo "--- план выкатки (--dry-run, ничего не меняется) ---"
    echo "приложение:     $APP"
    echo "версия:         $VERSION"
    if version_is_placeholder "$VERSION"; then
        echo "шлюз:           ОТКАЗ — версия не задана"
    elif [[ -z "$LIVE" ]]; then
        echo "шлюз:           пропустит (на проде релизов нет)"
    else
        echo "на проде:       $LIVE"
        case "$(compare_versions "$VERSION" "$LIVE")" in
            newer) echo "шлюз:           пропустит (версия новее)" ;;
            same)  echo "шлюз:           ОТКАЗ — эта версия уже на проде" ;;
            older) echo "шлюз:           ОТКАЗ — версия старше прода" ;;
            *)     echo "шлюз:           ОТКАЗ — версии несравнимы" ;;
        esac
        (( ALLOW_SAME )) && echo "                (--allow-same-version снимет отказ)"
    fi
    echo "архив:          $ARCHIVE ($(du -h "$ARCHIVE" 2>/dev/null | cut -f1))"
    echo "каталог:        $NEW_DIR"
    echo "текущий релиз:  $([[ -L $CURRENT ]] && basename "$(readlink -f "$CURRENT")" || echo 'нет')"
    # Монотонность в плане считается по КАТАЛОГАМ релизов, а не по version.json:
    # именно их сравнивает проверка перед переключением симлинка, и план обязан
    # показывать то же решение, что примет настоящая выкатка.
    if [[ -L "$CURRENT" ]]; then
        DRY_LIVE="$(basename "$(readlink -f "$CURRENT")")"
        DRY_NEW_TS="$(version_ts "$VERSION" || true)"
        DRY_LIVE_TS="$(version_ts "$DRY_LIVE" || true)"
        if [[ "$VERSION" == "$DRY_LIVE" ]]; then
            echo "монотонность:   пропустит (тот же каталог релиза)"
        elif [[ -z "$DRY_NEW_TS" || -z "$DRY_LIVE_TS" ]]; then
            echo "монотонность:   предупредит — время сборки в имени релиза не разбирается"
        elif (( 10#$DRY_NEW_TS < 10#$DRY_LIVE_TS )); then
            echo "монотонность:   ОТКАЗ — релиз старше живого $DRY_LIVE"
        else
            echo "монотонность:   пропустит (релиз не старше живого)"
        fi
    fi
    [[ -n "$UNIT" ]]       && echo "перезапуск:     $UNIT"
    # Каталог релиза ещё не распакован — смотрим прямо в архив.
    #
    # Печатаем путь ОТНОСИТЕЛЬНО systemd/, а не basename: дополнение живёт в
    # подкаталоге, и от basename в плане оставалось «snakes.service.d
    # 10-metrics.conf» — два непонятных имени вместо одного понятного
    # «snakes.service.d/10-metrics.conf». Сами каталоги (строки со слэшем на
    # конце) из списка выброшены: ставятся файлы.
    UNITS_IN_ARCHIVE="$(tar -tzf "$ARCHIVE" 2>/dev/null \
        | sed -n 's#^\(\./\)\?systemd/##p' | grep -v '/$' | grep . | tr '\n' ' ' || true)"
    if [[ -n "${UNITS_IN_ARCHIVE// /}" ]]; then
        echo "юниты:          из релиза ($UNITS_IN_ARCHIVE)"
    else
        echo "юниты:          в артефакте нет, ставятся руками"
    fi
    (( NGINX_RELOAD ))     && echo "nginx:          reload после переключения"
    [[ -n "$HEALTH" ]]     && echo "healthcheck:    $HEALTH"
    if tar -tzf "$ARCHIVE" 2>/dev/null | grep -qE '^([.]/)?verify$'; then
        echo "своя проверка:  verify из артефакта"
    else
        echo "своя проверка:  нет"
    fi
    [[ -n "$VERSION_URL" ]] && echo "сверка версии:  $VERSION_URL"
    [[ -n "$NEIGHBOURS" ]] && echo "соседи:         $NEIGHBOURS"
    echo "хранить релизов: $KEEP"
    exit 0
fi

acquire_lock

PREV_TARGET=""
[[ -L "$CURRENT" ]] && PREV_TARGET="$(readlink -f "$CURRENT")"

# --- 0. Версионный шлюз ---------------------------------------------------
# Под замком (иначе параллельная выкатка успеет сменить прод между проверкой
# и переключением) и до распаковки: незачем разбирать архив, который не
# поедет. При отказе не тронуто вообще ничего.
LIVE="$(current_live_version "$VERSION_URL" "$CURRENT")"
version_gate "$VERSION" "$LIVE" "$ALLOW_SAME" "${LIVE_VERSION_SOURCE:+, по $LIVE_VERSION_SOURCE}"

# --- 1. Разложить новый релиз рядом, не трогая текущий -------------------
log "распаковываю $VERSION в $NEW_DIR"
# Перевыкатка поверх текущего релиза (только через --allow-same-version):
# каталог, на который указывает current, на время распаковки исчезает, и
# прод в эти секунды отдаёт 404. Дешевле сказать об этом вслух, чем городить
# распаковку во временный каталог ради сценария «чиню то, что уже сломано».
if [[ -n "$PREV_TARGET" && "$PREV_TARGET" == "$NEW_DIR" ]]; then
    warn "перевыкатка поверх текущего релиза: $VERSION пересобирается под работающим current"
fi
rm -rf "$NEW_DIR"
mkdir -p "$NEW_DIR"
tar -xzf "$ARCHIVE" -C "$NEW_DIR"
[[ -n "$OWNER" ]] && chown -R "$OWNER" "$NEW_DIR"

# Бит запуска у бинаря сервиса.
#
# Windows его не хранит: артефакт, собранный локально, приезжает с правами
# 0644, systemd падает с 203/EXEC, и выкатка откатывается — верно, но
# каждый раз. В CI на Linux бит есть, и разница между «локально» и «в CI»
# ровно такого рода ошибок и не должна существовать.
if [[ -n "$UNIT" && -f "$NEW_DIR/$APP" && ! -x "$NEW_DIR/$APP" ]]; then
    chmod +x "$NEW_DIR/$APP"
    log "восстановлен бит запуска у $APP (артефакт собран там, где его нет)"
fi
ok "релиз распакован"

# --- 2. Переключить -------------------------------------------------------
# До этой строки прод работает на старом релизе и ничего не замечает.
#
# Куда previous указывал ДО нас — чтобы откат мог вернуть и его. Иначе после
# автоотката previous и current показывают на один каталог, и следующий
# `dk rollback <цель>` без --to упирается в «уже на этом релизе»: имя релиза,
# бывшего до текущего, оказывается потеряно ровно в тот момент, когда его
# труднее всего вспомнить.
PREV_PREV="$(readlink -f "$PREVIOUS" 2>/dev/null || true)"

# Монотонность: не уводим прод назад по времени сборки (см. monotonic_gate в
# lib.sh). Живой релиз читается ЗДЕСЬ, а не берётся из PREV_TARGET сверху:
# смысл проверки — правда о проде за строку до его переключения.
#
# Отказ — выход с GATE_REJECT: симлинки не тронуты, прод продолжает работать на
# живом релизе. Распакованный каталог при этом остаётся лежать среди релизов —
# он ни на что не влияет (на него не указывает ни один симлинк) и уйдёт при
# чистке, когда перестанет быть одним из последних KEEP. Стирать его тут же
# ради чистоты значило бы уничтожать единственное, что человеку останется
# посмотреть после отказа.
#
# Флага «разрешить старее» у выкатки нет намеренно: движение назад — это откат,
# и у него свой скрипт со своим флагом (rollback.sh --allow-older). Автооткат
# ниже под запрет не попадает по построению: rollback() зовёт switch_symlink
# напрямую, а проверка стоит здесь, на пути выкатки, а не внутри switch_symlink.
LIVE_RELEASE=""
if [[ -L "$CURRENT" ]]; then
    LIVE_RELEASE="$(basename "$(readlink -f "$CURRENT")")"
fi
monotonic_gate "$VERSION" "$LIVE_RELEASE" 0

[[ -n "$PREV_TARGET" ]] && switch_symlink "$PREVIOUS" "$PREV_TARGET"
switch_symlink "$CURRENT" "$NEW_DIR"
ok "current -> $VERSION"

# Имя релиза, который был на проде до нас, — в готовом виде аргументом
# события. Массив, а не подстановка по месту: пустое значение обязано
# исчезнуть целиком, а не приехать пустой строкой (docs/events.md, §4:
# необязательное поле отсутствует, а не приходит пустым).
PREV_ARG=()
if [[ -n "$PREV_TARGET" ]]; then
    PREV_ARG=(--previous "$(basename "$PREV_TARGET")")
fi

# Автооткат. Аргументы — стадия и причина из закрытых перечислений
# (docs/events.md, §7): без них откат остаётся ровно таким же невидимым, каким
# был всегда, — прод чинится сам, а в чате об этом ни слова.
#
# Умолчание, а не голые $1/$2: необъявленная переменная под `set -u` убивает
# шелл целиком, и вызов rollback без аргументов означал бы НЕСДЕЛАННЫЙ откат.
# Цена ошибки здесь несоизмерима с точностью названия причины.
rollback() {
    local stage="${1:-switch}" reason="${2:-}"
    warn "откатываюсь на предыдущий релиз"
    if [[ -z "$PREV_TARGET" ]]; then
        # Откатываться некуда: прод остался на сломанном релизе. Это failure
        # со стадией, а не rolled_back, — отката не было.
        notify_event --kind failure --app "$APP" --stage "$stage"
        die "откатываться некуда: это была первая выкатка $APP. Релиз оставлен как есть, разбирайтесь вручную"
    fi
    switch_symlink "$CURRENT" "$PREV_TARGET"
    # Возвращаем и previous: состояние симлинков после отката обязано быть
    # тем же, что было до выкатки.
    if [[ -n "$PREV_PREV" && -d "$PREV_PREV" ]]; then
        switch_symlink "$PREVIOUS" "$PREV_PREV"
    else
        rm -f "$PREVIOUS"
    fi
    # Юниты откатываем вместе с релизом: иначе на старом коде остался бы
    # ExecStart от нового, и откат чинил бы половину проблемы.
    install_units "$PREV_TARGET" || true
    [[ -n "$UNIT" ]] && systemctl restart "$UNIT" || true
    (( NGINX_RELOAD )) && { nginx -t >/dev/null 2>&1 && systemctl reload nginx; } || true
    warn "откат выполнен: current -> $(basename "$PREV_TARGET")"
    # Событие уходит ПОСЛЕ того, как прод возвращён на место, и ДО die:
    # сначала чиним, потом рассказываем.
    if [[ -n "$reason" ]]; then
        notify_event --kind rolled_back --app "$APP" --version "$VERSION" \
            --stage "$stage" --reason "$reason" "${PREV_ARG[@]}"
    else
        # Причины нет — сочинить значение закрытого перечисления нельзя, и
        # событие уходит как failure со стадией: рассказ беднее, но не ложный.
        notify_event --kind failure --app "$APP" --stage "$stage"
    fi
    die "выкатка $APP $VERSION провалена и откачена"
}

# --- 2.5. Юниты systemd из релиза ----------------------------------------
# Сама install_units живёт в lib.sh: её обязан вызывать и ручной откат
# (rollback.sh), иначе откат чинит половину проблемы.
install_units "$NEW_DIR" || rollback units units_failed

# --- 3. Применить ---------------------------------------------------------
if (( NGINX_RELOAD )); then
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx
        ok "nginx перезагружен"
    else
        nginx -t || true
        rollback switch nginx_failed
    fi
fi

if [[ -n "$UNIT" ]]; then
    systemctl restart "$UNIT" || rollback units units_failed
    ok "$UNIT перезапущен"
fi

# --- 4. Проверить ---------------------------------------------------------
if [[ -n "$HEALTH" ]]; then
    wait_http "$HEALTH" 10 3 || rollback health health_failed
fi

if [[ -n "$VERSION_URL" ]]; then
    check_version "$VERSION_URL" "$VERSION" || rollback version version_mismatch
else
    # Цель version.json не раздаёт: подтверждение — имя релиза, на который
    # реально указывает симлинк. Проверка слабее HTTP-сверки (о содержимом
    # каталога она не говорит ничего), но отличает «переключилось» от
    # «переключение не доехало» — а это ровно то, что здесь можно узнать.
    LIVE_NOW="$(basename "$(readlink -f "$CURRENT")")"
    if [[ "$LIVE_NOW" == "$VERSION" ]]; then
        ok "current указывает на $VERSION"
    else
        warn "current указывает на $LIVE_NOW, а выкатывали $VERSION"
        rollback version version_mismatch
    fi
fi

# Своя проверка цели.
#
# HTTP-healthcheck отвечает не на все вопросы: телеграм-бот, например, никуда
# не слушает — он сам ходит в Telegram длинным опросом, и «жив ли он» проверить
# запросом с сервера невозможно. Молчащий бот при этом неотличим от рабочего,
# пока что-нибудь не упадёт, — а выяснять это в момент аварии поздно.
#
# Соглашение, а не флаг: цель кладёт в артефакт исполняемый verify, и выкатка
# его запускает. Флаг пришлось бы протаскивать строкой с кавычками через
# описание цели, workflow и ssh — ровно так же, как BUILD_CMD, который по этой
# причине через outputs и не передаётся.
if [[ -f "$NEW_DIR/verify" ]]; then
    chmod +x "$NEW_DIR/verify"
    log "своя проверка цели: verify"
    if timeout 120 "$NEW_DIR/verify"; then
        ok "проверка цели прошла"
    else
        warn "проверка цели не прошла (или не уложилась в 120 с)"
        rollback health verify_failed
    fi
fi

if [[ -n "$NEIGHBOURS" ]]; then
    check_neighbours ${NEIGHBOURS//,/ } || rollback neighbours neighbours_failed
fi

# --- 5. Прибраться --------------------------------------------------------
prune_releases "$RELEASES" "$KEEP"

ok "выкатка $APP $VERSION завершена"

# Событие успеха — последней строкой, после ВСЕХ проверок: до неё выкатка ещё
# может закончиться откатом, и «выкатилось» сказанное раньше времени пришлось
# бы забирать назад. Чистка старых релизов на исход не влияет и потому стоит
# выше, а не между проверками и рассказом о них.
notify_event --kind success --app "$APP" --version "$VERSION" "${PREV_ARG[@]}"
