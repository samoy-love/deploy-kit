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
if grep -qE '^\s*add_header' "$CONF"; then
    locs=$(grep -cE '^\s*location\s' "$CONF" || true)
    incs=$(grep -cE 'include .*security-headers' "$CONF" || true)
    if (( locs > 0 && incs <= 1 )); then
        bad "в конфиге $locs location, но include заголовков встречается $incs раз — add_header в location затирает серверные заголовки"
    else
        good "заголовки подключены в каждом location ($incs включений)"
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

    if docker run --rm -i --entrypoint sh "nginx:${NGINX_VERSION}-alpine" -s <<SCRIPT
set -e
mkdir -p /etc/nginx/sites-enabled /etc/nginx/snippets
# Общие сниппеты на раннере недоступны — подкладываем пустышки, чтобы
# include не падал по причине, не связанной с проверяемым конфигом.
: > /etc/nginx/snippets/samoy-security-headers.conf
: > /etc/nginx/snippets/cache.conf
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
    include /etc/nginx/sites-enabled/*.conf;
}
WRAP

# Самоподписанные сертификаты по путям из конфига: проверяем синтаксис,
# а не наличие боевых ключей.
apk add --no-cache openssl >/dev/null 2>&1
for crt in \$(grep -hoE 'ssl_certificate[[:space:]]+[^;]+' /etc/nginx/sites-enabled/site.conf | awk '{print \$2}' | sort -u); do
    key=\$(echo "\$crt" | sed 's/fullchain/privkey/')
    mkdir -p "\$(dirname "\$crt")" "\$(dirname "\$key")"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "\$key" -out "\$crt" -days 1 -subj '/CN=test' >/dev/null 2>&1
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
