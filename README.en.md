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

Static sites and Go services announce their deploys in Telegram — from the
pipeline and from a developer machine alike. On success the message says what
shipped and in which version, links to the component and carries the list of
changes; on failure it stays short and about the failure. (The Windows installer
announces nothing: it is published to a GitHub Release rather than deployed.)

A local deploy takes the token and the chat from where it takes the host and the
key: `bin/deploy` reads `~/.config/deploy-kit/dk.conf` **itself** (`DK_CONF`
overrides the path). The file used to reach it only through `dk deploy`, which
exports what it read — so any other invocation, by hand or from a script, left
`TELEGRAM_*` empty and the notification silently never went out.

Precedence: the target description beats the environment, the environment beats
`dk.conf`. The file only fills in what the environment does not already define —
in CI the variables come from secrets and a machine-local file must not override
them, while a specific target's `NOTIFY` or `HEALTH` must not be overridden by a
machine-wide setting.

**An unconfigured chat no longer looks like notifications being off.** Silence
comes in two flavours — "nothing to say" and "we wanted to say it and could not"
(no token, an expired token, `api.telegram.org` not answering) — and the two
used to be indistinguishable. The second one now prints a warning carrying the
reason from Telegram's own answer; only the API's error description makes it
into that warning, never the URL with the token in it. None of this fails the
deploy: a notification is a decoration on top of it.

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

The success message carries a list of the most recent commits, built by one
shared `bin/changelog` rather than by each call site in its own way: there are
three places a release is announced — `static-site.yml`, `go-service.yml` and
`bin/deploy` — and once the format drifts apart, the release feed stops being
readable. The generator emits a finished chunk of the message: its own heading,
HTML already escaped. The caller appends it last and does nothing else to it.

The range is chosen top down, first match wins:

1. `--since <rev>` — the previous release, when the caller knows it; in the
   workflows that is `github.event.before`. A sha, a tag, or a whole version
   name like `release-20260801-1a2b3c4` are all accepted — the trailing commit
   is extracted from it.
2. the latest tag reachable from `HEAD`. If the tag sits exactly on `HEAD` (a
   release is tagged first and announced afterwards) the previous tag is taken,
   otherwise the range would be empty.
3. the last eight commits. That is no longer "changes since the last release",
   but it is always something meaningful and always bounded.

**History is sometimes unavailable, and that is a normal outcome rather than an
error.** An unresolvable revision is not a refusal but a step down the list: on
a shallow clone the object of the previous release simply is not there. No git,
a directory that is not a repository, empty history, everything filtered out as
noise, an unknown argument — all of them produce empty stdout, exit code 0 and
one line of reasoning on stderr. The message then goes out exactly as it went
out before, without a changes block. No input can make the generator break a
deploy.

That is also why the workflows fetch more than one commit: `actions/checkout`
brings exactly one by default, which would leave nothing to tell. Static sites
get the tags as well (`fetch-depth: 50`, `fetch-tags: true`). Go services
deliberately do not: the version step sees tags too, so a push onto a tagged
commit would start producing `v1.2.3` instead of `release-…`, which the version
gate rejects with code 3. A complete list is not worth that — without tags the
generator just takes the last commits.

The shape is changed with arguments; each has a matching `DK_CHANGELOG_*`
variable, and the argument wins over the variable:

| Argument | Default | What it sets |
|---|---|---|
| `--since`, `--to` | unset, `HEAD` | the ends of the range |
| `--repo` | `.` | repository directory |
| `--max` | 8 | items in the list; `0` — no limit (ceiling 200) |
| `--width` | 120 | characters per commit subject |
| `--depth` | 8 | how many commits the fallback takes |
| `--budget` | 1200 | characters for the whole block; `0` — no limit (ceiling 20000) |
| `--all` | — | lift both limits: the same as `--max 0 --budget 0` |
| `--link-base` | unset | base for PR links, e.g. `https://github.com/tr0llex/deploy-kit` |
| `--no-header` | heading present | drop the `<b>Изменения</b>` line |
| `--quiet` | — | do not explain the chosen range on stderr |

Everything is counted in **characters**, not bytes, and it is the same subject
ceiling that CLAUDE.md states — 120. Bytes used to stand here and charged double
for a Russian letter: 100 bytes is 100 Latin letters but only 50 Russian ones,
half of the stated norm. Across 287 real subjects from these repositories the
median is 50 characters (76 bytes) and the maximum 107 characters (145 bytes);
the old limit cut every seventh subject mid-sentence, the current one cuts none
of them. The limit is a guard against an anomaly again, not a routine event.

The locale does not affect the count: the script runs under `LC_ALL=C`, where
`${#s}` counts bytes, so characters are counted by UTF-8 arithmetic instead — how
many bytes are not continuation bytes (`0x80`–`0xBF`). The result is identical on
a GitHub runner and in Git Bash on Windows. Cutting inside a character is never
allowed at any limit: Telegram rejects a broken string outright.

Telegram's limit is 4096 UTF-16 units for the whole message, and at the defaults
the margin stays threefold: eight items of 120 Cyrillic characters is 960 units,
heading and tail about 35, the deploy message itself about 150.

### The full list instead of a tail

`--all` (the same as `--max 0` and `--budget 0`) lifts the limits — but for the
sake of `version.json`, not of chat. There are two cuts on the way to the reader, and **the first one
decides everything**: `version.json` gets exactly what the generator printed, and
neither the bot nor the status page reads the git history — they read the file.
What is not in the file cannot be shown, however they are changed. So all three
deployment paths call the generator without limits: the full list of the release
travels into the file, and the "…и ещё 1 коммит" tail disappears not because it
is hidden but because there is nothing left to cut.

A ceiling remains when the limits are lifted — 200 items and 20000 visible
characters. That is not about a pretty message: `version.json` is served over
HTTP and polled by the agent once a minute. The pathological input here is not "a
hundred commits" but `--since` pointing at the first commit of the repository, or
`--depth 100000` — without a ceiling the whole history would silently travel into
the status file, on every deploy. 20000 Cyrillic characters is about 36 KB, a
tenfold margin over the largest release imaginable here. The ceiling is the only
thing that can still cut the list, and that is exactly why it announces itself
with the tail.

How to fit the full list into 4096 units of one message is decided by **whoever
sends it — by splitting into several consecutive messages, not by truncating.**
The cut may only fall on line boundaries: a line is an item of the list and holds
an `<a href="…">#21</a>`, and a cut inside a line would tear the tag. Telegram
rejects invalid markup outright, so a part of the release would be lost
altogether — and it does not truncate an over-long message either, it rejects
that outright too. When there is more than one chunk each is labelled: "часть 1
из N — продолжение ниже" is appended to the first, and every following one starts
with the target name and the part number. The name is required: there is one chat
for the whole estate, and "часть 2 из 3" has nothing to attach to when four
targets are deploying at once and their messages interleave.

The API response is parsed rather than discarded, and the part number goes into
the log: a rejected message is otherwise indistinguishable from a sent one —
neither by `curl`'s exit code nor in the log — and that is precisely why the
length defect lived unnoticed.

Garbage in a numeric parameter silently falls back to the default — a typo in
`--max` cannot break a deploy.

Merges, `fixup!`, `WIP`, bot dependency bumps and bare version bumps drop out of
the list and repeated subjects collapse: releases get read on a phone, and every
such line displaces a real one.

The `…и ещё N коммитов` tail means exactly "the list was cut by a limit" — and
nothing else. It used to appear when nothing had been cut at all: "in total"
counted every commit in the range, noise and duplicates included, so a release of
two cherry-picks of one change produced "…и ещё 1 коммит" — about a commit hidden
ON PURPOSE and not wanted by the reader. The line took up room and did not say
which commit it was. Now the tail is printed only when an item genuinely did not
fit: `--max`, `--budget`, the ceiling or the history-reading window.

The `(#NN)` suffix GitHub appends on a squash merge is stripped from the text.
PRs here are always squash-merged: the branch collapses into a single commit on
main whose subject is the PR title, and 23% of the subjects in history carry such
a suffix. As bare text in chat it is noise — the brackets and the hash take up
room and lead nowhere. Only the suffix is stripped and only in the `(#digits)`
form: brackets and hashes inside a phrase are left alone.

**But stripping the number outright is a loss too: there is no way back to the
discussion from chat.** So with `--link-base` it returns to the end of the item,
now as a link:

```html
• Завести dependabot одинаково во всех репозиториях <a href="https://github.com/tr0llex/deploy-kit/pull/21">#21</a>
```

The reader sees the same four characters `#21`, but they now lead into the PR.
The address is built as `<base>/pull/<number>`: GitHub redirects `/pull/N` to
`/issues/N` and back, so the link is right even when the number turned out to be
an issue rather than a PR.

Not every caller knows the base, so **without `--link-base` the behaviour is
what it was, to the byte** — the number is simply stripped. `bin/deploy` derives
the base from `git remote get-url origin`, normalising both remote forms that
occur here (`git@github.com:owner/repo.git` and
`https://github.com/owner/repo.git` — the first is what `gh repo clone` sets, the
second what the site's "Clone" button gives). Both workflows take it from
`github.server_url` and `github.repository`: that is the canonical name of the
repository being deployed, no remote parsing is needed there at all, and a
literal `https://github.com` would break on GHES. `LINK_BASE=none` in the target
description turns links off, `LINK_BASE=<url>` sets the base by hand — on mirrors
and forks the remote points at a different repository than the numbers do.

**The base is validated, not substituted as is.** It arrives from outside — the
target description, the remote, the CI environment — and leaves inside the HTML
of a message. Only `http(s)` is accepted, only a safe character set (quotes,
angle brackets and spaces excluded) and no longer than 200 bytes; the address is
escaped as well, because a single quote in `href` breaks the markup exactly as
`<` in a commit subject does. An unusable base is not an error: one line on
stderr, and the item comes out in its previous form, without the tag. In
`bin/deploy` the check also requires a dot in the host name — otherwise a local
remote `C:/src/repo` would parse as host `C` and yield a link to nowhere in every
item, and a wrong link is worse than a missing one: a missing one is visible at
once, a wrong one only on click.

**The link does not eat the length limit, but it does eat Telegram's.**
`--width` and `--budget` count VISIBLE length — the subject plus a space and
`#21`, not the forty characters of markup around them; otherwise the same release
would be cut differently with links and without. Whereas 4096 counts message
units, and tags count in full: at eight items the markup adds about 350 units.

Two suites check all of this; both build throwaway repositories in a temporary
directory and never touch the working tree:

| Suite | What it checks |
|---|---|
| `ci/changelog-test.sh` | the generator itself: ranges, the noise filter, truncation, `(#NN)`, the Telegram limit |
| `ci/contract-test.sh` | the seam with the three `version.json` writers, and squash merges end to end |

Our own CI runs them (the "Скрипты" job, next to `bash -n` and shellcheck): those
check the text of the script, whereas the promise "no input can make it break a
deploy" is only checked by running it — an empty repository, a shallow clone, a
detached HEAD, no git in `PATH`, Cyrillic exactly on the truncation boundary.
Tests are a gate, not decoration (CLAUDE.md).

## The list of changes in version.json

A chat message lives for one screenful and is then lost, while the question is
usually asked a week later and about last Tuesday. So the same list also goes
into the release file, as an optional `changelog` key next to the fields that
were always there:

```json
{
  "version": "release-20260803-120000-1a2b3c4",
  "commit": "1a2b3c4",
  "builtAt": "2026-08-03T12:00:00+03:00",
  "changelog": "<b>Изменения</b>\n• исправить падение на пустом конфиге\n• обновить nginx до 1.24 <a href=\"https://github.com/tr0llex/deploy-kit/pull/21\">#21</a>"
}
```

The list here is **complete**, not the first eight items: the generator is called
with its limits lifted precisely for the sake of this file. The
"…и ещё N коммитов" tail appears in it only when the ceiling is hit (200 items,
20000 characters), which is to say practically never.

The value is the **verbatim stdout of the generator**, as a single JSON string,
heading, bullet markers and link tags included. The reader normalises it, not the
writer:
the file has three writers (`bin/deploy` and the two workflows), and agreeing on
"hand it over as is" is easier than getting three identical normalisations
right. The key is absent entirely when there is nothing to show: `"changelog":""`
would claim "there were no changes", which is a different statement, and the
status page would grow an empty block out of it.

The generator runs **exactly once per deploy**, and both consumers read the same
finished text. There is no other way round it: `version.json` is written before
the artifact is packed, the message goes out after the release is switched, and
the whole deploy — minutes of it — sits between those two moments. A second run
would return a DIFFERENT list (one commit in another window is enough), and then
the file on production would describe one set of changes and the chat another.
The status bot compares exactly these two sources, so the mismatch would read as
"the bot is lying".

**A commit subject inside JSON is a trap, not a formality.** Subjects are
written by anyone with push access: they contain quotes, backslashes from paths
like `C:\Users\x`, and real newlines, which the generator puts between items. A
naive `printf '…"changelog":"%s"…'` on such input produces a file that every
JSON parser rejects — and `version.json` is what the version gate reads to tell
"it shipped" from "it looks like it shipped". A decoration on top of a deploy
would have broken the check of the deploy itself. So the workflows build the
file with `jq` and `bin/deploy` with a character-by-character `json_escape`
(substitutions like `${s//\\/\\\\}` behave differently in bash 5.2+ than in 5.1,
and the same subject would be escaped differently on the runner and on the
developer's machine). If `jq` is unavailable or the file cannot be built, the
plain `{version,commit,builtAt}` object is written exactly as before: the
version must ship no matter what, the list of changes must not.

**Commit subjects thereby become public.** `/version.json` is served over HTTP
by the same server as the service itself — otherwise the deploy would have
nothing to verify itself against — and the status page agent carries the field
onwards into `/data/summary.json` and `/data/releases.json` on
status.samoy.love, which are served to everyone too. Which means the first lines
of commits, and the deployment dates, are readable by anyone who asks. For a
public repository that changes nothing: the same lines are visible in the git
history. For a private one it changes everything — internal system names, ticket
numbers and phrasings like "remove the password from the config" leave the
building along with the release. There is no separate switch for the list right
now; `WRITE_VERSION_FILE=0` in the target description removes the whole file,
but the post-deploy version check goes with it.

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
| A local deploy never goes quiet unnoticed | `bin/deploy` reads `dk.conf` itself; an unconfigured chat and a Telegram refusal both warn instead of staying silent |
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
| status.samoy.love | static-site + agent | [status.samoy.love](https://github.com/tr0llex/status.samoy.love) |
| die.samoy.love, dev.die.samoy.love | static-site | [double-or-die](https://github.com/tr0llex/double-or-die) |

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
