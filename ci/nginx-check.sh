#!/usr/bin/env bash
# Проверка nginx-конфига проекта ДО выкатки, на раннере.
#
#   ci/nginx-check.sh deploy/nginx/samoy.love.conf
#
# Проверяет два разных класса проблем.
#
# СИНТАКСИС — реальным nginx той же версии, что на проде. Именно «той же»:
# конфиг с `http2 on;` проходит проверку на 1.25+ и роняет 1.24. Версия
# задаётся NGINX_VERSION и должна совпадать с боевой.
#
# СТАТИКА — то, что nginx -t считает валидным, но что ломает соседей:
# второй default_server, дубль server_name, отсутствие include общих
# сниппетов. В изоляции конфликт с чужим сайтом не воспроизвести
# принципиально, поэтому здесь ловим хотя бы формальные признаки.

set -Eeuo pipefail

NGINX_VERSION="${NGINX_VERSION:-1.24.0}"
CONF="${1:?использование: nginx-check.sh <путь к конфигу>}"
[[ -f "$CONF" ]] || { echo "нет файла: $CONF" >&2; exit 1; }

fail=0
note() { printf '  %s\n' "$*"; }
bad()  { printf '✗ %s\n' "$*" >&2; fail=1; }
good() { printf '✓ %s\n' "$*"; }

echo "== статические проверки =="

# 1. Директива http2 в новой форме на старом nginx.
if grep -qE '^\s*http2\s+on\s*;' "$CONF"; then
    if [[ "$(printf '%s\n1.25.1\n' "$NGINX_VERSION" | sort -V | head -1)" == "$NGINX_VERSION" && "$NGINX_VERSION" != "1.25.1" ]]; then
        bad "'http2 on;' не поддерживается nginx $NGINX_VERSION — используйте 'listen 443 ssl http2;'"
    fi
else
    good "директива http2 в совместимой форме"
fi

# 2. default_server. Он должен быть ровно один на весь хост и жить в
#    общем catch-all, а не в конфиге проекта: иначе чужой домен, направленный
#    на этот IP, начнёт отдавать наш сайт.
if grep -qE 'listen[^;]*default_server' "$CONF" && ! grep -q '000-default' <<<"$CONF"; then
    bad "конфиг проекта объявляет default_server — это дело общего catch-all"
else
    good "default_server не перехватывается"
fi

# 3. server_name должен быть задан явно.
if ! grep -qE '^\s*server_name\s+\S' "$CONF"; then
    bad "нет server_name — сервер станет безымянным и начнёт ловить чужие запросы"
else
    good "server_name задан: $(grep -hoE '^\s*server_name\s+[^;]+' "$CONF" | head -3 | tr -s ' ' | paste -sd' ' -)"
fi

# 4. Заголовки безопасности. Их подключают include'ом, и он обязан быть в
#    КАЖДОМ location со своим add_header: nginx не складывает наборы, а
#    заменяет их — location со своим Cache-Control молча теряет CSP и HSTS.
# Это эвристика, а не доказательство: проекты подключают заголовки
# по-разному — общим сниппетом или инлайном. Поэтому здесь только
# предупреждение, а настоящая проверка — эмпирическая, по ответу живого
# сервера после выкатки (release.sh, шаг проверки заголовков).
if grep -qE '^\s*add_header' "$CONF"; then
    srv_hdr=$(awk '/^\s*location\s/{inloc=1} /^\s*}/{inloc=0} !inloc && /^\s*add_header/{n++} END{print n+0}' "$CONF")
    loc_hdr=$(awk '/^\s*location\s/{inloc=1} /^\s*}/{inloc=0} inloc && /^\s*add_header/{n++} END{print n+0}' "$CONF")
    incs=$(grep -cE 'include .*(security-headers|headers)' "$CONF" || true)
    if (( srv_hdr > 0 && loc_hdr > 0 && incs == 0 )); then
        note "предупреждение: add_header есть и на уровне server ($srv_hdr), и внутри location ($loc_hdr)."
        note "nginx не складывает наборы, а заменяет их — location со своим add_header теряет серверные."
        note "Проверьте ответ сервера: curl -sI https://<домен>/ | grep -i 'strict-transport\\|content-security'"
    else
        good "заголовки не теряются в location (server=$srv_hdr, location=$loc_hdr, include=$incs)"
    fi
fi

echo "== проверка синтаксиса реальным nginx $NGINX_VERSION =="

if ! command -v docker >/dev/null 2>&1; then
    note "docker недоступен — синтаксическая проверка пропущена"
else
    # Конфиг уезжает в контейнер потоком, а не монтированием тома.
    # Монтирование ломается о трансляцию путей (Windows/MSYS): каталог
    # монтируется пустым, nginx проверяет пустоту и рапортует успех —
    # ложный зелёный, который опаснее отсутствия проверки.
    conf_b64="$(base64 -w0 "$CONF" 2>/dev/null || base64 "$CONF" | tr -d '\n')"

    # Сниппеты берём НАСТОЯЩИЕ, из этого же репозитория: раньше здесь лежали
    # две пустышки с прибитыми именами, и конфиг, подключающий любой другой
    # сниппет, падал не по своей вине. Заодно так проверяется и содержимое
    # сниппетов, а не только то, что файл существует.
    snippets_dir="$(cd "$(dirname "$0")/../nginx/snippets" 2>/dev/null && pwd || true)"
    snippet_cmds=""
    if [[ -n "$snippets_dir" ]]; then
        for s in "$snippets_dir"/*.conf; do
            [[ -f "$s" ]] || continue
            s_b64="$(base64 -w0 "$s" 2>/dev/null || base64 "$s" | tr -d '\n')"
            snippet_cmds="${snippet_cmds}echo '${s_b64}' | base64 -d > /etc/nginx/snippets/$(basename "$s")
"
        done
    fi
    # Сниппеты, которых в репозитории нет (например, чужие или ещё не
    # написанные), заменяем пустышками — иначе проверка упрётся не в тот конфиг,
    # который проверяет.
    for want in $(grep -hoE 'include[[:space:]]+/etc/nginx/snippets/[^;]+' "$CONF" | awk '{print $2}' | xargs -r -n1 basename | sort -u); do
        [[ -f "$snippets_dir/$want" ]] && continue
        snippet_cmds="${snippet_cmds}: > /etc/nginx/snippets/$want
"
    done

    confd_cmds=""
    confd_dir="$(cd "$(dirname "$0")/../nginx/conf.d" 2>/dev/null && pwd || true)"
    if [[ -n "$confd_dir" ]]; then
        for c in "$confd_dir"/*.conf; do
            [[ -f "$c" ]] || continue
            c_b64="$(base64 -w0 "$c" 2>/dev/null || base64 "$c" | tr -d '
')"
            confd_cmds="${confd_cmds}echo '${c_b64}' | base64 -d > /etc/nginx/conf.d/$(basename "$c")
"
        done
    fi

    if docker run --rm -i --entrypoint sh "nginx:${NGINX_VERSION}-alpine" -s <<SCRIPT
set -e
mkdir -p /etc/nginx/sites-enabled /etc/nginx/snippets /etc/nginx/conf.d
$confd_cmds
$snippet_cmds
# Файлы, которые certbot кладёт на боевой хост. На раннере их нет, и без
# заглушек nginx падает по причине, не связанной с проверяемым конфигом.
# openssl нужен и здесь (dhparam), и ниже (сертификаты) — ставим один раз
# до первого использования.
apk add --no-cache openssl >/dev/null 2>&1
mkdir -p /etc/letsencrypt
: > /etc/letsencrypt/options-ssl-nginx.conf
# nginx разбирает содержимое ssl_dhparam, пустышка его не устроит.
# 1024 бит достаточно: файл нужен только для проверки синтаксиса.
openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 1024 >/dev/null 2>&1
echo '$conf_b64' | base64 -d > /etc/nginx/sites-enabled/site.conf

# Пустой конфиг обязан быть замечен: иначе проверка снова станет
# бессмысленной, если файл вдруг не доедет.
test -s /etc/nginx/sites-enabled/site.conf || { echo "конфиг не доехал в контейнер"; exit 1; }
grep -q 'server' /etc/nginx/sites-enabled/site.conf || { echo "в конфиге нет ни одного server"; exit 1; }

cat > /etc/nginx/nginx.conf <<'WRAP'
events {}
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    # conf.d идёт ПЕРЕД сайтами: log_format допустим только на уровне http,
    # и конфиг сайта, ссылающийся на формат, обязан видеть его объявление.
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*.conf;
}
WRAP

# Самоподписанные сертификаты по путям из конфига: проверяем синтаксис,
# а не наличие боевых ключей.
for crt in \$(grep -hoE 'ssl_certificate[[:space:]]+[^;]+' /etc/nginx/sites-enabled/site.conf | awk '{print \$2}' | sort -u); do
    key=\$(echo "\$crt" | sed 's/fullchain/privkey/')
    mkdir -p "\$(dirname "\$crt")" "\$(dirname "\$key")"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "\$key" -out "\$crt" -days 1 -subj '/CN=test' >/dev/null 2>&1
    # chain.pem нужен для OCSP stapling (ssl_trusted_certificate).
    cp "\$crt" "\$(dirname "\$crt")/chain.pem" 2>/dev/null || true
done

nginx -t
SCRIPT
    then
        good "синтаксис принят nginx $NGINX_VERSION"
    else
        bad "nginx $NGINX_VERSION не принял конфиг"
    fi
fi

exit $fail
