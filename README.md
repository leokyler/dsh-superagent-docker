# dsh-superagent-docker

Run [dsh-superagent](https://github.com/deepseek-ai/dsh-superagent-prototype) — the
DeepSeek Harness research prototype that turns GitHub requests into tickets and
executes them in their own agent sessions — inside a container.

Upstream ships **no image and no Dockerfile**; this repository adds one, plus the
two pieces of glue a container needs: a way to reach a panel that only listens on
loopback, and a non-interactive replacement for the interactive setup.

> Not an official DeepSeek project. `dsh-superagent` itself is MIT-licensed
> research code: read its README before trusting it with a repository, and give it
> a dedicated GitHub account, never your own.

```
docker compose up -d --build     # 1. build and start
docker compose logs -f           # 2. read the panel URL (it prints one with a token)
docker compose exec superagent gh-agent auth login --web   # 3. sign in the agent account
```

Then in the panel: pick a model, set the repository and the agent CLI, add
yourself to the allowed list, and point the worker prepare command at a local
clone. A request arrives as `@<agent-login> <request>` on an Issue.

## Why this is more than `docker run`

**The panel refuses anything but loopback.** `src/app/http.ts` throws unless the
webserver binds `127.0.0.1`, and every management request must carry a `Host`
header of `127.0.0.1:<port>` or `localhost:<port>`. A published port cannot reach
a loopback listener, so the entrypoint runs

```
socat 0.0.0.0:13082 → 127.0.0.1:3082
```

and the compose file publishes `127.0.0.1:3082 → 13082`. The browser still uses
`localhost:3082`, so the Host check passes. On native Linux you can skip the proxy
entirely with `DSH_SUPERAGENT_ACCESS=host` + `--network host`.

**The setup is interactive by design.** Upstream expects an agent to ask one
question at a time and run `dsh superagent --from-default-profile web`,
`dsh plugin add`, `gh auth login` and the panel saves with you. `entrypoint.sh`
does the parts that can be automated, idempotently: create the profile, install
the bundle, write `cordis.patch.yml`, create the `gh-agent` wrapper, start the
service under tmux, and self-heal it every 60 s (only on exit 1 — exit 2 and 3
need a person, matching the upstream hourly check).

## Requirements

- Docker (or Docker Desktop with WSL integration enabled, if you run from WSL)
- ~5 GB of disk and network access to `github.com`, `cli.github.com` and npm
- A model provider reachable from inside the container
- A **dedicated** GitHub account with write access to a test repository, and a
  classic token or browser login for it

## Quickstart

```bash
git clone <this repo> && cd dsh-superagent-docker
mkdir -p repos                       # the agent's working folder, bind-mounted
docker compose up -d --build
docker compose logs -f superagent
```

The log ends with the panel URL including its token:

```
[superagent] ready
[superagent] panel: http://localhost:3082/?token=…
```

Open it, choose **Superagent** in the sidebar, and work through the setup problems
the Overview lists.

### Without compose

The image needs no compose features, so any Docker-compatible CLI works — including
ones that only implement `build`/`run` (for example `wslc` on Windows). The run
flags mirror the compose file:

```bash
docker build -t dsh-superagent:local .
mkdir -p repos
docker run -d --name dsh-superagent --restart unless-stopped \
  -p 127.0.0.1:3082:13082 \
  -e DSH_SUPERAGENT_ACCESS=proxy \
  -e DSH_SUPERAGENT_PUBLISHED_PORT=3082 \
  -v dsh-home:/home/node/.dsh \
  -v "$PWD/repos":/home/node/src \
  dsh-superagent:local
```

On native Linux, drop `-p` and use `--network host -e DSH_SUPERAGENT_ACCESS=host`
instead. Replace `docker` with your CLI; `logs`, `exec` and `rm` follow the same
names.

Behind a registry mirror (Docker Hub is unreachable on some networks), build with
`--build-arg BASE_IMAGE=<mirror>/library/node:24-bookworm`.

### Signing in the agent account

Preferred, interactive but painless — it prints a code you paste in your own
browser:

```bash
docker compose exec superagent gh-agent auth login --web
docker compose exec superagent gh-agent api user --jq .login
```

Non-interactive alternative: put a token in `gh-token` and uncomment the secret
mount in `docker-compose.yml`. The entrypoint signs in on start:

```bash
printf '%s' "$TOKEN" > gh-token && chmod 600 gh-token   # then: docker compose up -d
```

The token needs `repo` (and `read:org` if the repository is in an organisation).

### Settings the panel needs

| Where | What |
|---|---|
| Sources → GitHub | repository `owner/name`, agent CLI `/home/node/.local/bin/gh-agent` |
| Policy → GitHub | your own login(s) on the allowed list — until someone is there, no request can become a ticket |
| Execution | a directory root (e.g. `/home/node/src/agent-work`) and the prepare command below |
| Prompts → Delivery | commit author, and whether the agent may enable auto-merge (default: no) |
| DSH model settings | one model must exist, or the service is up but does nothing |

Prepare command, per `docs/006-deployment.md` (it gives each ticket a worktree
from a clone you keep in the mounted folder):

```bash
git -C /home/node/src/widgets fetch --no-tags \
  "https://github.com/$DSH_SUPERAGENT_GITHUB_REPOSITORY.git" \
  "${DSH_SUPERAGENT_GITHUB_PR_HEAD:-HEAD}:refs/dsh-superagent/$DSH_SUPERAGENT_TICKET" \
  && git -C /home/node/src/widgets worktree add \
  -b "agent/$DSH_SUPERAGENT_NAME" "$DSH_SUPERAGENT_DIR" \
  "refs/dsh-superagent/$DSH_SUPERAGENT_TICKET"
```

Keep `eval` mode at `observe` while you are trying it: proactive work is then
recorded as "would accept" instead of spending worker sessions.

## The patch in `patches/`

`0001-detect-the-service-process-on-node-24.patch` teaches
`scripts/dsh-superagent` that `ps -o ucomm=` reports the **thread** name on
current Node, so the service process shows up as `MainThread` instead of `node`.
Without it, `status` reports no pid, exits 1 forever, and the supervisor loop
would keep trying to restart a healthy service.

The Dockerfile applies the patches right after cloning. Drop the file from
`patches/` once upstream handles this, and the loop still works — it skips
missing patches.

## Verifying

```bash
docker compose exec superagent scripts/dsh-superagent status; echo "exit=$?"
```

| exit | meaning | what to do |
|---|---|---|
| 0 | healthy | try `@<agent-login> <request>` on an Issue |
| 1 | not running, or crashed | newest `.artifacts/dsh-superagent-superagent-*.log` |
| 2 | a part reports an error | `status` prints `errors`; a restart does not fix it |
| 3 | setup waits | the panel Overview links to the setting that fixes it |

The container healthcheck asks the management API for `state`, so it goes healthy
even while setup is pending — that is intended, the panel is how you fix setup.

## Configuration

| Environment | Default | Meaning |
|---|---|---|
| `DSH_SUPERAGENT_ACCESS` | `proxy` | `proxy` publishes through socat; `host` assumes `--network host` |
| `DSH_SUPERAGENT_PORT` | `3082` | DSH webserver port inside the container |
| `DSH_SUPERAGENT_PROXY_PORT` | `13082` | socat's port, the one compose publishes |
| `SUPERAGENT_PORT` | `3082` | host port to open in the browser |
| `DSH_SUPERAGENT_SUPERVISE` | `1` | 60 s self-heal loop |
| `SUPERAGENT_REPOS` | `./repos` | host folder bind-mounted at `/home/node/src` |
| `GH_TOKEN_FILE` | `/run/secrets/gh-token` | optional token file for a non-interactive login |
| `DSH_SUPERAGENT_STATE_DIR` | `$HOME/.dsh/state/superagent` | where the plugin keeps its SQLite, locks and shims |

Build arguments: `DSH_VERSION` (default `0.2.1-rc.3`, must satisfy the bundle's
`engines.dsh`), `SUPERAGENT_REF` (upstream branch or tag), `WITH_GIT_LFS=1` for
repositories that use LFS.

## Data, upgrade, reset

- Everything lives in the `dsh-home` volume: DSH sessions, profiles, credentials
  and `<stateDir>/orchestrator.sqlite`. Back that up before upgrading.
- Upgrade: rebuild with a new `SUPERAGENT_REF`, then
  `docker compose exec superagent scripts/dsh-superagent restart`. A database
  migrated by a newer build cannot be opened by an older one.
- Reset: `docker compose down -v` deletes the team, tickets and sessions. The
  clone under `repos/` is untouched.

## Isolation

This container **is** the isolation. Inside it the worker and router presets run
with `danger-full-access` as the `node` user, so mount only what the agent may
read and push. Upstream's alternative is a dedicated OS account; a container is
that, with a shorter setup. Do not add your home directory as a volume.

## Status of this packaging

- The image is built in CI (`.github/workflows/build.yml`): the Dockerfile, the
  patch application, the entrypoint's prerequisites and the bundle build are all
  exercised there.
- The configuration it produces was verified end to end on a host install of the
  same upstream commit (trigger → eval → ticket → worktree → commit → PR →
  ticket closed on merge).
- Not covered: Feishu (needs a bot-only `lark-cli` wrapper), auto-merge via a
  second account, and GitHub Enterprise Server (unsupported upstream).

## License

MIT for the files in this repository (see `LICENSE`). `dsh-superagent` and
DeepSeek Harness are MIT-licensed projects by the DeepSeek Harness Team, used
here as build inputs; this repository is not affiliated with or endorsed by them.
