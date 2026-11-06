#!/usr/bin/env bash
# Boot dsh-superagent inside the container.
#
# Every step is idempotent: the first run performs the one-time setup, later runs
# only start what is missing. This follows step 4 ("Install and start") of the
# upstream SETUP.md, made non-interactive, because an image cannot ask the
# operator questions.
set -euo pipefail

PROFILE="${DSH_SUPERAGENT_PROFILE:-superagent}"
PORT="${DSH_SUPERAGENT_PORT:-3082}"
PROXY_PORT="${DSH_SUPERAGENT_PROXY_PORT:-13082}"
PUBLISHED_PORT="${DSH_SUPERAGENT_PUBLISHED_PORT:-3082}"
ACCESS="${DSH_SUPERAGENT_ACCESS:-proxy}"   # proxy | host
SUPERVISE="${DSH_SUPERAGENT_SUPERVISE:-1}"
BOOT_GRACE="${DSH_SUPERAGENT_BOOT_GRACE:-120}"
GH_TOKEN_FILE="${GH_TOKEN_FILE:-/run/secrets/gh-token}"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
STATE_DIR="${DSH_SUPERAGENT_STATE_DIR:-$DSH_HOME/state/superagent}"
API="http://127.0.0.1:$PORT/orchestrator/api/state"

export TMUX_TMPDIR="${TMUX_TMPDIR:-$HOME/.tmux}"
mkdir -p "$TMUX_TMPDIR"

cd /opt/dsh-superagent
log() { printf '[superagent] %s\n' "$*"; }

service() { scripts/dsh-superagent --profile "$PROFILE" --url "http://127.0.0.1:$PORT" "$@"; }
status_code() {
  local code=0
  service status > /dev/null 2>&1 || code=$?
  return "$code"
}
api_ready() { curl -sf -o /dev/null --max-time 5 -H 'x-orchestrator-request: 1' "$API"; }

# --- 1. profile + bundle, once -----------------------------------------------
# `--from-default-profile` replaces an existing profile and deletes its
# cordis.patch.yml, so it must never run a second time.
if [ ! -d "$DSH_HOME/profiles/$PROFILE" ]; then
  log "creating profile '$PROFILE' from the web template"
  dsh superagent --from-default-profile web --dump-config > /dev/null
  log "installing the bundle as a link to this checkout"
  dsh plugin --profile "$PROFILE" add "link:$PWD"
fi

PROFILE_DIR="$DSH_HOME/profiles/$PROFILE"
PATCH_FILE="$PROFILE_DIR/cordis.patch.yml"
# The template already ships an empty cordis.patch.yml, so "the file is missing"
# is the wrong test: without this marker the machine settings below never apply,
# the webserver stays on its default port and stateDir is reported missing.
if ! grep -q 'managed-by: dsh-superagent-docker' "$PATCH_FILE" 2>/dev/null; then
  log "writing $PATCH_FILE (stateDir=$STATE_DIR, port=$PORT)"
  [ -f "$PATCH_FILE" ] && cp "$PATCH_FILE" "$PATCH_FILE.before-docker-$(date +%s)"
  mkdir -p "$STATE_DIR"
  cat > "$PATCH_FILE" <<YAML
# managed-by: dsh-superagent-docker
# Replace or edit this file to change machine settings.
- id: webserver
  config:
    host: 127.0.0.1
    port: ${PORT}
- id: dsh-superagent
  config:
    stateDir: ${STATE_DIR}
# Feishu is optional; enabling it also needs a bot-only lark-cli wrapper.
# - id: dsh-superagent-feishu
#   disabled: false
YAML
fi

# --- 2. the agent's own gh, never the operator's -----------------------------
cat > "$HOME/.local/bin/gh-agent" <<'WRAPPER'
#!/bin/sh
GH_CONFIG_DIR="$HOME/.config/gh-agent" exec gh "$@"
WRAPPER
chmod 0755 "$HOME/.local/bin/gh-agent"

if [ -f "$GH_TOKEN_FILE" ] && [ -s "$GH_TOKEN_FILE" ]; then
  log "signing gh-agent in from $GH_TOKEN_FILE"
  if ! "$HOME/.local/bin/gh-agent" auth login --with-token < "$GH_TOKEN_FILE"; then
    log "gh-agent login failed; run: docker compose exec superagent gh-agent auth login --web"
  fi
fi

# --- 3. packages declared at run time ---------------------------------------
# Lets the published image serve a repository's toolchain without a rebuild:
#   docker run -e DSH_SUPERAGENT_APT_PACKAGES="golang-go default-jdk" ...
# The package list and the image revision form a marker, so restarting the same
# image does not hit the network, while a new image installs again. Declaring
# packages here rather than letting an agent install them mid-ticket keeps the
# toolchain identical for every ticket that runs on this container.
install_declared_packages() {
  local list="$1"
  [ -n "$list" ] || return 0
  local marker="$DSH_HOME/.apt-packages" wanted
  wanted=$(printf '%s|%s' "$list" "${DSH_IMAGE_REVISION:-dev}" | sha256sum | cut -d' ' -f1)
  if [ -f "$marker" ] && [ "$(cat "$marker")" = "$wanted" ]; then
    log "declared packages already present: $list"
    return 0
  fi
  log "installing declared packages: $list"
  local attempt
  for attempt in 1 2 3; do
    # Word splitting is intended: the value is a package list.
    # shellcheck disable=SC2086
    if sudo -n apt-get update -qq && sudo -n apt-get install -y --no-install-recommends $list; then
      printf '%s' "$wanted" > "$marker"
      log "declared packages installed: $list"
      return 0
    fi
    log "apt attempt $attempt/3 failed; retrying in 5s"
    sleep 5
  done
  log "WARNING: could not install '$list'; the service still starts."
  log "         Check the network or the package names, then restart the container."
  return 1
}
install_declared_packages "${DSH_SUPERAGENT_APT_PACKAGES:-}" || true

# --- 4. reach the loopback-only panel ---------------------------------------
# src/app/http.ts refuses to serve unless the webserver binds 127.0.0.1, and it
# rejects requests whose Host header is not 127.0.0.1:<port>/localhost:<port>.
# A published port cannot reach a loopback listener, so proxy mode forwards.
case "$ACCESS" in
  proxy)
    log "proxying 0.0.0.0:$PROXY_PORT -> 127.0.0.1:$PORT"
    socat "TCP-LISTEN:${PROXY_PORT},fork,reuseaddr,bind=0.0.0.0" "TCP:127.0.0.1:${PORT}" &
    ;;
  host)
    log "host network mode"
    ;;
  *)
    log "unknown DSH_SUPERAGENT_ACCESS='$ACCESS' (proxy|host)"
    exit 64
    ;;
esac

# --- 5. start, then wait for the API before judging anything ----------------
if ! status_code; then
  log "starting dsh-superagent (tmux session dsh-$PROFILE)"
  service start || true
fi

ready=0
for _ in $(seq 1 90); do
  if api_ready; then ready=1; break; fi
  sleep 2
done
[ "$ready" = 1 ] && log "management API is answering" || log "management API did not answer within 180s"

# --- 6. self-heal -----------------------------------------------------------
# Same rule as the upstream hourly check: only exit 1 (not running) is fixed by a
# restart. 2 (a part errors) and 3 (setup waits) need a person. A single failure
# is often a slow first boot or a model turn, so two in a row are required, and
# nothing restarts during the boot grace period.
if [ "$SUPERVISE" = "1" ]; then
  (
    sleep "$BOOT_GRACE"
    failures=0
    while true; do
      sleep 60
      code=0
      status_code || code=$?
      if [ "$code" -ne 0 ] && [ "$code" -ne 2 ] && [ "$code" -ne 3 ]; then
        failures=$((failures + 1))
        log "status exited $code ($failures in a row)"
        if [ "$failures" -ge 2 ]; then
          log "restarting"
          service --respect-stop restart > /dev/null 2>&1 || true
          failures=0
          sleep 60
        fi
      else
        failures=0
      fi
    done
  ) &
fi

# --- 7. tell the operator where to look -------------------------------------
LOG_FILE=$(ls -t .artifacts/dsh-superagent-*.log 2>/dev/null | head -1 || true)
TOKEN=""
if [ -n "$LOG_FILE" ]; then
  TOKEN=$(grep -o 'token=[A-Za-z0-9_-]*' "$LOG_FILE" 2>/dev/null | head -1 | cut -d= -f2 || true)
fi

code=0
status_code || code=$?
case "$code" in
  0) log "ready" ;;
  1) log "not running; see $LOG_FILE" ;;
  2) log "running, but a part reports an error; scripts/dsh-superagent status lists 'errors'" ;;
  3) log "running, but setup waits: open the panel Overview and configure a model, the GitHub Source and the Policy" ;;
  *) log "status exited $code" ;;
esac

if [ -n "$TOKEN" ]; then
  log "panel: http://localhost:$PUBLISHED_PORT/?token=$TOKEN"
else
  log "panel: http://localhost:$PUBLISHED_PORT/ (no token in ${LOG_FILE:-<no log>})"
fi

exec tail -f /dev/null
