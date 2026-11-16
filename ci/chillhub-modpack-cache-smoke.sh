#!/bin/sh
# Run against nginx started with the Chill Hub site config and a scratch web root.
set -eu

root="${1:?expected a scratch web root}"
base="${2:?expected the nginx address}"
mod="cache-smoke"
version="Pack-1.0"
manifest="/manifests/_mods/$mod/$version.json"
file="/content/_mods/$mod/$version/files/data.bin"
missing="/content/_mods/$mod/$version/files/new.bin"
game="/content/$mod/1.0/files/data.bin"
headers="$(mktemp)"
partial="$(mktemp)"
cleanup() {
    if [ "$?" -ne 0 ]; then cat "$headers" >&2; fi
    rm -f "$headers" "$partial"
}
trap cleanup EXIT

request() {
    wget --no-check-certificate -T 5 -S -O - --header "Host: launcher.samoy.love" "$@" 2>"$headers"
}

mkdir -p "$root${manifest%/*}" "$root${file%/*}" "$root${game%/*}"
printf '%s' '{"hash":"old"}' > "$root$manifest"
printf '%s' 'OLD!' > "$root$file"
printf '%s' 'GAME' > "$root$game"

# Warm open_file_cache past min_uses before atomically replacing both files.
for _ in 1 2 3; do
    test "$(request "$base$manifest")" = '{"hash":"old"}'
    test "$(request "$base$file")" = 'OLD!'
done
test "$(request "$base$manifest")" = '{"hash":"old"}'
previous_date="$(sed -n 's/^[[:space:]]*[Ll]ast-[Mm]odified: //p' "$headers" | tr -d '\r')"
test -n "$previous_date"
if request "$base$missing"; then
    echo "Expected a missing file before publication" >&2
    exit 1
fi
grep -Eq '[[:space:]]404[[:space:]]' "$headers"

printf '%s' '{"hash":"new"}' > "$root$manifest.tmp"
printf '%s' 'NEW!' > "$root$file.tmp"
touch -r "$root$manifest" "$root$manifest.tmp"
touch -r "$root$file" "$root$file.tmp"
mv "$root$manifest.tmp" "$root$manifest"
mv "$root$file.tmp" "$root$file"
printf '%s' 'newly published' > "$root$missing"

test "$(request --header "If-Modified-Since: $previous_date" "$base$manifest")" = '{"hash":"new"}'
grep -qi 'cache-control: no-store' "$headers"
! grep -qi '^[[:space:]]*etag:' "$headers"
printf '%s' 'N' > "$partial"
request -c -O "$partial" --header 'Accept-Encoding: gzip' "$base$file"
test "$(cat "$partial")" = 'NEW!'
grep -Eq '[[:space:]]206[[:space:]]' "$headers"
grep -qi 'content-range: bytes 1-3/4' "$headers"
grep -qi 'cache-control: no-store' "$headers"
grep -qi 'x-content-type-options: nosniff' "$headers"
! grep -qi '^[[:space:]]*content-encoding:' "$headers"
test "$(request "$base$missing")" = 'newly published'
test "$(request "$base$game")" = 'GAME'
grep -qi 'cache-control: .*immutable' "$headers"

echo "Проверены замена модпака по тому же URL, Range и кеширование обычных сборок"
