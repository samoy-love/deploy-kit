# deploy-kit

English · [Русский](README.ru.md)

[![CI](https://github.com/tr0llex/deploy-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/tr0llex/deploy-kit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![nginx 1.24](https://img.shields.io/badge/nginx-1.24-009639)

The single release pipeline behind every samoy.love project: static sites, Go
services and a desktop installer all reach production through the same
conveyor.

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
10. Notify        Telegram message with the outcome
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
# dk.conf holds host, user and key path; quote values that contain spaces
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

Updating the server-side scripts:

```bash
install-server              # show drift between repository and /opt/deploy-kit
install-server --apply      # upload (only what is merged into main)
```

## Structure

| Path | Purpose |
|---|---|
| `.github/workflows/static-site.yml` | reusable pipeline for static sites |
| `.github/workflows/go-service.yml` | reusable pipeline for Go services with systemd |
| `.github/workflows/desktop-artifact.yml` | reusable pipeline for the Windows installer |
| `.github/workflows/ci.yml` | own CI: shell syntax, shellcheck, real nginx, actionlint |
| `bin/dk` | CLI: production state, deploy, rollback |
| `bin/deploy` | one local deploy, the same path CI takes |
| `bin/install-server` | ships `server/*.sh` to `/opt/deploy-kit` |
| `server/release.sh` | unpack → backup → switch → verify → roll back |
| `server/rollback.sh` | manual rollback to the previous or a named release |
| `server/preflight.sh` | disk space, `nginx -t`, unit state, release owner |
| `server/nginx-apply.sh` | diff → backup → install → `nginx -t` → revert |
| `server/lib.sh` | host mutex, version gate, healthchecks, release pruning |
| `ci/nginx-check.sh` | validates a site config in a real nginx 1.24 container |
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
| A systemd unit on the server matches the repository | `install_units`: units travel inside the artifact under `systemd/` |
| A target that HTTP cannot check is still verified | an executable `verify` in the artifact runs after the switch, rollback on failure |

The repository's own CI runs shell syntax checks separately from shellcheck (a
parsed script with complaints can be fixed, an unparsable one cannot), validates
every site config in an nginx 1.24 container, lints the workflows with
actionlint and asserts that `dk help` still runs.

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
NGINX_RELOAD=1                      # static: reload nginx after the switch
UNIT=                               # services: systemd unit to restart instead
HEALTH=https://samoy.love/
VERSION_URL=https://samoy.love/version.json
NEIGHBOURS=metro.samoy.love,snakes.samoy.love
```

The same file drives `dk deploy`. Targets that do not serve `version.json` set
`WRITE_VERSION_FILE=0`; the gate and the post-deploy check then read the release
name from the `current` symlink instead.

What a project must provide to enter the pipeline: `/healthz` returning 200 and
the body `ok` without authentication, `/version.json` with `version`, `commit`
and `builtAt`, and the standard layout
`<root>/releases/<version>` with `current` and `previous` symlinks (the last
five releases are kept). Secret names are the same everywhere: `DEPLOY_HOST`,
`DEPLOY_USER`, `DEPLOY_SSH_KEY`, `SSH_HOST_KEY`, `TELEGRAM_BOT_TOKEN`,
`TELEGRAM_CHAT_ID`. `SSH_HOST_KEY` comes from a secret rather than
`ssh-keyscan`, which trusts the first answer and accepts a substitution
silently.

Current targets:

| Target | Archetype | Repository |
|---|---|---|
| samoy.love | static-site | [samoy.love](https://github.com/tr0llex/samoy.love) |
| metro.samoy.love | static-site | [metro-map](https://github.com/tr0llex/metro-map) |
| launcher.samoy.love, admin UI | static-site | [chillhub](https://github.com/tr0llex/chillhub) |
| launcher and admin servers | go-service | [chillhub](https://github.com/tr0llex/chillhub) |
| ChillHub installer | desktop-artifact | [chillhub](https://github.com/tr0llex/chillhub) |
| Snakes server and client | go-service | [snakes](https://github.com/tr0llex/snakes) |
| status.samoy.love | static-site + agent | [status.samoy.love](https://github.com/tr0llex/status.samoy.love) |

The Snakes client ships in **one artifact** with its server: they share a
binary protocol, and versions drifting apart break packet parsing.

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
