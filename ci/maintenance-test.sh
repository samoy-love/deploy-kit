#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=server/lib.sh
source server/lib.sh
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export DK_EVENTS_DIR="$tmp"
APP=cs2-api
dk_maintenance 600
python3 - "$tmp/.maintenance-cs2-api.json" <<'PY'
import json,sys,time
x=json.load(open(sys.argv[1])); assert x['app']=='cs2-api'
assert x['until']-x['written']==600
assert abs(x['written']-time.time())<5
PY
DK_EVENT_NOTIFY=never
notify_event --kind success --app cs2-api
python3 - "$tmp/.maintenance-cs2-api.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); assert x['until']-x['written']==120
PY
notify_event --kind failure --app cs2-api
python3 - "$tmp/.maintenance-cs2-api.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); assert x['until']==x['written']
PY
before=$(cat "$tmp/.maintenance-cs2-api.json")
dk_maintenance 601
[[ "$(cat "$tmp/.maintenance-cs2-api.json")" == "$before" ]]
APP='../escape'; dk_maintenance 600
[[ $(find "$tmp" -type f | wc -l) == 1 ]]
APP=cs2-api
export DK_EVENTS_DIR="$tmp/.maintenance-cs2-api.json/no-directory"
dk_maintenance 600
printf 'maintenance tests passed\n'
