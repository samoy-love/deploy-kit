# deploy-kit

[Русский](README.md) · English

[![CI](https://github.com/tr0llex/deploy-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/tr0llex/deploy-kit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![nginx 1.24](https://img.shields.io/badge/nginx-1.24-009639)

The single release pipeline behind every samoy.love project: static sites, Go
services and a desktop installer all reach production through the same
conveyor.

<img src="docs/img/dk-list.svg" alt="dk list output: eleven deployment targets" width="100%">

## Why

Every project used to reinvent deployment. Only Snakes could roll back — the
rest "rolled back" by deploying again. The launcher ran `go test` in a workflow
that had nothing to do with the deploy that followed it. One shared nginx file
described two sites at once, so deploying one of them took the neighbour down.
Several repositories deploy to **one** host, yet each held its own mutex, so
two pipelines could reload nginx at the same moment. Secret names differed from
repository to repository.

All of that is reduced here to one contract: one target description, one
`release.sh` on the server, one queue on the host. A project repository keeps a
twenty-line workflow call and an `.env` file.

## The conveyor

Identical for every archetype; only the build step differs.

```
1. Gates          lint, types, tests (go test -race for Go), build
2. Artifact       version from tag or release-<date>-<commit>, packed as tar.gz
3. Preconditions  on the host: disk space, nginx -t, unit state, release owner
3a. Version gate  version must be set and strictly newer than production
4. Upload         into releases/<version>, ownership applied
5. Backup         snapshot of the nginx config before it is replaced
6. Switch         atomic flip of the current symlink
7. Apply          nginx -t && reload, or systemctl restart
8. Verify         /healthz, /version.json equals the expected version, neighbours
9. Rollback       any failure after step 6 returns current to the previous release
10. Notify        Telegram message: the outcome and the changes
```

Step 8 compares the **version**, not just the status code — that is what
catches "the deploy was green but the files are still old". Step 3a refuses
placeholder versions (`dev`, `unknown`, empty) and anything not newer than what
production reports, and exits with code 3 while the symlink is untouched.

## How it works

**Production is built once.** The artifact is produced on the runner and
shipped as is. Nothing is compiled on the server, so what was tested is exactly
what runs.

**Deployment is atomic.** Files land in a new `releases/<version>` directory
and only then does `current` flip, through a temporary symlink and `mv -T`.
Between `rm` and `ln` there would be a window where the path does not exist —
this way there is none, and a half-applied state cannot be observed.

**Every deploy verifies itself and failure rolls back on its own.** After the
switch the pipeline waits for `/healthz`, compares `/version.json` with the
version it shipped, and probes the neighbouring domains. Any of those failing
returns `current` to the previous release and restarts the unit — because
`main` goes to production on every merge, an unattended deploy has to be able
to undo itself.

**One host, one queue.** The mutex is a `flock` on `/var/lock/deploy-kit.lock`,
held for the whole host rather than per repository. GitHub concurrency groups
only serialise runs inside a single repository, and the projects that share
this server live in different ones.

**Nobody touches anyone else's file.** A project may write exactly one file in
`sites-available` (or `conf.d`), `nginx-apply.sh` records the state of the
whole configuration *before* the change so a pre-existing breakage is not
mistaken for ours, and the release is reverted from the backup if `nginx -t`
fails afterwards.

**The scripts on the server are themselves a release.** `install-server`
compares checksums between the repository and `/opt/deploy-kit`, refuses to
upload anything that differs from `origin/main`, stages the files in a temp
directory and runs `bash -n` there — a broken `release.sh` installed in place
would leave nothing to deploy or roll back with.

## Stack

Bash (strict mode, shellcheck-clean), GitHub Actions reusable workflows,
systemd, nginx 1.24, `flock`, `tar` + `scp` over SSH. No third-party actions
for SSH or file transfer: twenty lines of local code instead of an external
dependency in the supply chain.

## Quick start

`dk` is one command for the whole estate. Targets discover themselves — every
`.deploy-kit/*.env` in a neighbouring repository becomes a target, nothing has
to be registered.

```bash
echo 'export PATH="$PATH:/path/to/deploy-kit/bin"' >> ~/.bashrc
mkdir -p ~/.config/deploy-kit && cp dk.conf.example ~/.config/deploy-kit/dk.conf
# dk.conf holds host, user, key path and — if you want notifications — the
# Telegram token and chat; quote values that contain spaces
```

```bash
dk                          # what is live right now: status codes and versions
dk list                     # all targets
dk deploy                   # every target of the project you are standing in
dk deploy snakes metro      # selected targets
dk deploy --all --dry-run   # show the plan, change nothing
dk rollback snakes --list   # which releases are on the server
dk rollback snakes          # back to the previous one
dk help
```

A local deploy takes **the same path as CI**: the same target description and
the same `release.sh` on the server. "Works locally, fails in CI" cannot happen
by construction.

## Running locally

`dk run` is the same target registry, on your own machine. It answers "what
runs here, and how" — an answer that used to live only in someone's head.

```bash
dk run --list               # what runs locally and on which ports
dk run                      # the services of the project you are standing in
dk run metro die-game       # selected targets
dk run --dry-run            # directories, ports, variables — starting nothing
dk run --branch main        # the same, from another branch
```

`Ctrl-C` stops everything the command started — **by port, not by the parent
PID**: `go run` compiles a binary and runs it as a separate process, so the
port is held by a grandchild, and killing the parent would leave an orphan.

Running is described where deploying is, by `RUN_*` keys in
`.deploy-kit/*.env`. There is deliberately no separate registry: two lists of
targets drift apart eventually, and "add a file — get a target" stops being
true. The keys are documented in [docs/run.md](docs/run.md) (Russian).

There are no containers here and none are planned: production is systemd plus
`release.sh` on arm64, Docker reproduces neither the architecture nor the unit
sandbox nor nginx, and the flagship client is WPF on Windows. The full
reasoning is at the top of [docs/run.md](docs/run.md).

Updating the server-side scripts:

```bash
install-server              # show drift between repository and /opt/deploy-kit
install-server --apply      # upload (only what is merged into main)
```

## Notifications

One voice tells the chat how a deploy went — the status-page bot, not the
pipeline or `bin/deploy` directly. Every deployment path — both workflows and
a local deploy — announces its outcome as an **event**: it drops a JSON file
into a journal on the server (`lib/notify.sh`, the contract is
[docs/events.md](docs/events.md)), and only the bot reads that journal and
posts to Telegram. Sending to Telegram used to be a separate copy at each call
site, and the release feed read differently depending on which path the deploy
took; now there is one format, because there is exactly one place that writes
to chat. The Windows installer is published through the same event, as kind
`published`.

`bin/deploy` needs no Telegram token at all: the event travels over the same
SSH connection and the same key the deploy itself uses, opening no new access.
A local deploy still takes the host and the key from
`~/.config/deploy-kit/dk.conf` (`DK_CONF` overrides the path), the
environment, or the target description, with the same precedence as before:
the target description beats the environment, the environment beats
`dk.conf`.

**An undelivered event is never mistaken for success.** If the journal on the
server is unreachable, `bin/deploy` prints a warning with the reason, but the
deploy itself does not fail because of it: the event is a report about the
deploy, not part of it.

How loud the notification is comes from `NOTIFY` in the target description:

| `NOTIFY` | What reaches the chat |
|---|---|
| `all` — the default | both success and failure |
| `fail` | failure only |
| `never` | nothing; an unconfigured chat is not asked about either |

Staying silent on success is sometimes right: a project may have its own release
channel, and then the message from here is a second voice about one event.
Staying silent on failure is not: something that did not ship, and was not
reported, looks exactly like something that did.

## The list of changes

The release message carries a list of the most recent commits, built by one
shared `bin/changelog` — the same across every deployment path. Its output is
reduced to plain text for the event (`docs/events.md`) and reused verbatim for
`version.json` by their respective writers, following shared rules. The
generator's internals — range selection, Telegram limits, `version.json`
escaping, PR links and the tests that check all of it — are documented in
[docs/changelog.md](docs/changelog.md) (Russian).

Running it by hand:

```bash
bash bin/changelog --repo .                       # what has been going on lately
bash bin/changelog --repo . --since v1.4.0 --max 6
bash bin/changelog --repo . --max 0 --budget 0    # the whole release, as in version.json
bash bin/changelog --repo . --link-base https://github.com/tr0llex/deploy-kit
```

Through `bash` rather than by executing the file: this repository has
`core.filemode=false`, so on a fresh clone under Linux `bin/*` are not
executable.

## Structure

| Path | Purpose |
|---|---|
| `.github/workflows/static-site.yml` | reusable pipeline for static sites |
| `.github/workflows/go-service.yml` | reusable pipeline for Go services with systemd |
| `.github/workflows/desktop-artifact.yml` | reusable pipeline for the Windows installer |
| `.github/workflows/ci.yml` | own CI: shell syntax, shellcheck, real nginx, actionlint |
| `bin/dk` | CLI: production state, deploy, rollback |
| `bin/deploy` | one local deploy, the same path CI takes |
| `bin/changelog` | the list of changes for a release message — one for every deployment path |
| `bin/install-server` | ships `server/*.sh` to `/opt/deploy-kit` and the ownerless parts of `nginx/` |
| `bin/selfupdate-upload` | launcher self-update build — into the admin panel, never touches `latest` |
| `server/release.sh` | unpack → backup → switch → verify → roll back |
| `server/rollback.sh` | manual rollback to the previous or a named release |
| `server/preflight.sh` | disk space, `nginx -t`, unit state, release owner |
| `server/nginx-apply.sh` | diff → backup → install → `nginx -t` → revert |
| `server/publish-file.sh` | atomic single-file replacement (installer), `.prev` for rollback |
| `server/lib.sh` | host mutex, version gate, healthchecks, release pruning |
| `ci/nginx-check.sh` | validates a site config in a real nginx 1.24 container |
| `ci/changelog-test.sh` | validates `bin/changelog` against throwaway git repositories |
| `ci/contract-test.sh` | the seam between the generator and the three `version.json` writers |
| `ci/units-test.sh` | installing systemd units and drop-ins against a fake `/etc` |
| `nginx/sites` | one file per domain, exactly what is enabled on the server |
| `nginx/snippets` | shared fragments included from `sites/` |
| `nginx/conf.d` | what must live at `http` level (log formats) |
| `dk.conf.example` | template for `~/.config/deploy-kit/dk.conf` |

`nginx/` is the single source of truth for the whole ecosystem's nginx
configuration; see [`nginx/README.md`](nginx/README.md) for the rules that
apply there and [`nginx/gzip.md`](nginx/gzip.md) for compression.

## What is guaranteed, and what checks it

| Guarantee | Enforced by |
|---|---|
| A red gate never reaches production | `gates` input is a required step of every reusable workflow |
| A release without a version never ships | `version_gate` in `server/lib.sh`, exit code 3 |
| An older build never ships as a new one | `compare_versions`: timestamp and semver schemes, never mixed |
| Production is never half-switched | `switch_symlink`: temporary link plus `mv -T` |
| A green deploy with stale files is caught | `check_version` against `/version.json`, or the release name in `current` |
| A failed deploy does not stay on production | `rollback` on health, version or neighbour failure |
| Deploying one site never breaks another | `check_neighbours` plus one file per project in `nginx-apply.sh` |
| Two repositories never deploy at once | `flock` on `/var/lock/deploy-kit.lock`, host-wide |
| A config valid locally but invalid on prod is rejected | `ci/nginx-check.sh` runs the real nginx 1.24 |
| The scripts on the server match the repository | checksum comparison in `install-server`, upload only from `main` |
| A systemd unit on the server matches the repository | `install_units`: both flat units and `<unit>.d/*.conf` drop-ins travel inside the artifact and are installed on every deploy |
| A file under `systemd/` that landed nowhere never disappears quietly | `install_units` names everything it did not recognise: a typo in `<unit>.d`, a stray file, a drop-in for a unit that does not exist |
| Unit installation is checked by running it, not by reading it | `ci/units-test.sh`: the real `install_units` from `lib.sh` against a fake `/etc/systemd/system` |
| A target that HTTP cannot check is still verified | an executable `verify` in the artifact runs after the switch, rollback on failure |
| A local deploy never goes quiet unnoticed | `bin/deploy` announces its outcome as an event through `lib/notify.sh`; an undelivered event warns instead of staying silent |
| The list of changes never breaks a deploy | `bin/changelog` always exits 0, empty output means "nothing to show"; in CI the step carries `continue-on-error` |
| The list of changes never corrupts `version.json` | the JSON is built by `jq` (workflows) or a character-by-character `json_escape` (`bin/deploy`); on any failure the previous object is written without the `changelog` key |
| The generator is checked, not merely read | `ci/changelog-test.sh` in the "Скрипты" job of our own CI, against throwaway repositories |
| The seam with `version.json` is checked separately | `ci/contract-test.sh` in the same job: all three writers are cut out of the sources and run as they are — both ends of the chain were once green at the same time as a break in the middle |
| No commit disappears from a release | the generator is called without limits, the full list travels into `version.json`; Telegram's limit is met by splitting into several messages, not by truncating |
| A long message never turns into silence | the 4096 limit is hard: Telegram rejects the whole message rather than cutting it; the cut follows line boundaries, the API response is parsed, the part number goes into the log |
| A PR link cannot corrupt the markup | the base is accepted only as `http(s)`, from a safe character set and no longer than 200 bytes; an unusable one gives a line on stderr and an item without the tag |

The repository's own CI runs shell syntax checks separately from shellcheck (a
parsed script with complaints can be fixed, an unparsable one cannot), validates
every site config in an nginx 1.24 container, lints the workflows with
actionlint, runs both changelog suites against throwaway repositories, drives
unit installation against a fake `/etc` and asserts that `dk help` still runs. The shell job carries its own
`timeout-minutes`: an infinite loop in argument parsing has already happened
once, and it must not hold a runner up to the six-hour default. Each of the two
test steps carries a limit of its own as well — a hung generator is exactly the
defect they exist to catch, and such a run should hit the step that names it
rather than the job limit, which names only the job.

## How other projects use it

A project repository keeps a workflow call:

```yaml
jobs:
  deploy:
    uses: tr0llex/deploy-kit/.github/workflows/static-site.yml@main
    with:
      config: .deploy-kit/prod.env
      gates: npm ci && npm run test:coverage && npm run build
    secrets: inherit
```

and a target description, `.deploy-kit/prod.env`:

```bash
APP=samoylove                       # name of the target and of the directory on the host
BUILD_CMD="npm ci && npm run build"
ARTIFACT_DIR=dist                   # what gets packed
ROOT=/var/www/samoy.love            # holds releases/ and current
OWNER=ubuntu:ubuntu
NGINX_CONF=nginx/sites/samoy.love.conf   # site config — a path inside deploy-kit
NGINX_DEST=/etc/nginx/sites-available/samoy.love.conf   # where to install it
NGINX_RELOAD=1                      # static: reload nginx after the switch
UNIT=                               # services: systemd unit to restart instead
HEALTH=https://samoy.love/
VERSION_URL=https://samoy.love/version.json
NEIGHBOURS=metro.samoy.love,snakes.samoy.love
NOTIFY=all                          # all (the default) | fail | never
```

The nginx config is described by the pair `NGINX_CONF` + `NGINX_DEST`, where
`NGINX_CONF` is a path **inside deploy-kit**: nginx configuration lives in one
repository, projects keep no copies. Both deployment paths ship it — `dk deploy`
and the pipeline alike — and `nginx-apply.sh` installs it on the server with a
backup, `nginx -t` and a rollback on failure. Half of the pair without the other
is a broken description rather than a partial setup: a silently skipped step
looks exactly like an applied config.

The same file drives `dk deploy`. Targets that do not serve `version.json` set
`WRITE_VERSION_FILE=0`; the gate and the post-deploy check then read the release
name from the `current` symlink instead.

A file target is an installer published by atomically replacing a single file
rather than a release directory. The `PUBLISH_DEST` key switches both
`dk deploy` and `desktop-artifact.yml` (its `config` input) to
`publish-file.sh`:

```bash
APP=chillhub-installer
BUILD_CMD="powershell -NoProfile -ExecutionPolicy Bypass -Command '…'"
ARTIFACT_FILE=scripts/generated_downloads/ChillHub-Setup.exe
VERSION_CMD="sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' …/App.csproj"
PUBLISH_DEST=/var/www/site-downloads/ChillHub-Setup.exe
VERIFY_URL=https://launcher.samoy.love/downloads/ChillHub-Setup.exe.sha256
```

`BUILD_CMD` here is a bash string on both paths (PowerShell is invoked
explicitly inside it), and the version is declared by `VERSION_CMD` — the same
source the build validates against. After publishing, the checksum served by
production is compared via `VERIFY_URL`; the previous file stays next to the
new one as a `.prev` hard link for instant rollback.

The `SELFUPDATE_URL` + `SELFUPDATE_ZIP` pair adds a third channel to a file
target: the payload ZIP goes to the launcher admin panel
(`bin/selfupdate-upload`, credentials come from the `ADMIN_USER` /
`ADMIN_PASSWORD` secrets or `dk.conf`), and the server builds the version
manifest. `latest.json` is never switched by automation: a human makes the
version active in the admin panel — that is the boundary by design.

What a project must provide to enter the pipeline: `/healthz` returning 200 and
the body `ok` without authentication, `/version.json` with `version`, `commit`
and `builtAt`, and the standard layout
`<root>/releases/<version>` with `current` and `previous` symlinks (the last
five releases are kept). Secret names are the same everywhere: `DEPLOY_HOST`,
`DEPLOY_USER`, `DEPLOY_SSH_KEY`, `SSH_HOST_KEY`, `TELEGRAM_BOT_TOKEN`,
`TELEGRAM_CHAT_ID`. `SSH_HOST_KEY` comes from a secret rather than
`ssh-keyscan`, which trusts the first answer and accepts a substitution
silently.

**systemd units travel inside the artifact.** Whatever lies in its `systemd/`
directory is installed into `/etc/systemd/system` by `release.sh` on every
deploy: flat `*.service`, `*.timer`, `*.socket` as files, and `<unit>.d/*.conf`
drop-ins into the `<unit>.d` directory, which is created when missing. Only what
actually changed is copied, and `daemon-reload` runs once and only when
something changed. A unit arriving for the first time is enabled; timers and
sockets are started right away. A drop-in is neither enabled nor started: it is
not a unit but an overlay on an existing one, with no `[Install]` and no state
of its own. For it to take effect the unit itself must be restarted — the
target's own unit is restarted by the deploy (`UNIT=`), for anyone else's you
get a warning.

Putting the units into the artifact is the target's `BUILD_CMD` job; they do not
get there by themselves. A unit that stays only in git lives its own life: an
`ExecStart` edit lands in `main`, the deploy is green, and the service keeps
starting with the old arguments. The reverse holds too: a file deleted from git
will not vanish from `/etc` by itself — a leftover drop-in is named out loud,
but never deleted as root.

Current targets:

| Target | Archetype | Repository |
|---|---|---|
| samoy.love | static-site | [samoy.love](https://github.com/tr0llex/samoy.love) |
| metro.samoy.love | static-site | [metro-map](https://github.com/tr0llex/metro-map) |
| launcher.samoy.love, admin UI | static-site | [chillhub](https://github.com/tr0llex/chillhub) |
| launcher and admin servers | go-service | [chillhub](https://github.com/tr0llex/chillhub) |
| ChillHub installer | desktop-artifact | [chillhub](https://github.com/tr0llex/chillhub) |
| Snakes server and client | go-service | [snakes](https://github.com/tr0llex/snakes) |
| status.samoy.love, its agent and status Telegram bot | static-site + go-service | [status.samoy.love](https://github.com/tr0llex/status.samoy.love) |
| die.samoy.love                     | static-site | [double-or-die](https://github.com/tr0llex/double-or-die) |
| Monitoring stack (Prometheus, Grafana) | compose stack via systemd unit | [metrics.samoy.love](https://github.com/tr0llex/metrics.samoy.love) |

The Snakes client ships in **one artifact** with its server: they share a
binary protocol, and versions drifting apart break packet parsing.

**A change to a reusable workflow cannot be verified by re-running a job.**
`gh run rerun`, `--failed` included, replays the run against the workflow
revision that was current when the run first started — even though the call
goes through `@main` and `main` has been fixed since. The "Re-run jobs" button
in the UI does the same. You need a **new** run:

```bash
gh workflow run deploy.yml --ref main                 # targets expose workflow_dispatch
gh workflow run deploy.yml --ref main -f dry-run=true # no effect on production
```

A dry run still reaches `nginx-apply.sh` and `release.sh` with `--dry-run`: the
config delivery path is exercised end to end, production is left alone.

This is not a convenience note. On 2026-08-04 the race over the shared
`/tmp/site.conf` was fixed, merged into `main` and installed on the server —
and re-running five failed deploys through `gh run rerun` reproduced it word
for word: `status.samoy.love`'s config landed in `metrics.samoy.love.conf` and
monitoring went down a second time. It looked like "the fix does not work",
while the fix simply **was not running** — the old workflow revision knew
nothing about it.

## Part of samoy.love

One domain, one server, one pipeline, one status page, one monitoring stack.

| Project | What it is |
|---|---|
| [samoy.love](https://github.com/tr0llex/samoy.love) | Homepage and project showcase: Astro, WebGL background, zero trackers |
| [chillhub](https://github.com/tr0llex/chillhub) | ChillHub — Windows game launcher: diff updates, hash control, Go admin panel |
| [snakes](https://github.com/tr0llex/snakes) | Browser territory-capture multiplayer: Go, WebSocket, binary protocol |
| [metro-map](https://github.com/tr0llex/metro-map) | Offline PWA with the Moscow metro map: routing on the client, Canvas 2D |
| [status.samoy.love](https://github.com/tr0llex/status.samoy.love) | Status page: uptime, versions, incidents; Go agent plus an external watchdog |
| [metrics.samoy.love](https://github.com/tr0llex/metrics.samoy.love) | Monitoring and product analytics: Prometheus, Grafana, traffic from nginx logs |
| [deploy-kit](https://github.com/tr0llex/deploy-kit) | This repository: the shared release pipeline |

## Contacts

Alexey Samoylov — [alex@samoy.love](mailto:alex@samoy.love) ·
[t.me/tr0llex](https://t.me/tr0llex) ·
[github.com/tr0llex](https://github.com/tr0llex)

## License

[MIT](LICENSE).
