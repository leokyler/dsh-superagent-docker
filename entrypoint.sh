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
GH_TOKEN_FILE="${GH_TOKEN_FILE:-/run/secrets/gh-token}"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
STATE_DIR="${DSH_SUPERAGENT_STATE_DIR:-$DSH_HOME/state/superagent}"

export TMUX_TMPDIR="${TMUX_TMPDIR:-$HOME/.tmux}"
mkdir -p "$TMUX_TMPDIR"

cd /opt/dsh-superagent
log() { printf '[superagent] %s\n' "$*"; }

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
if [ ! -f "$PROFILE_DIR/cordis.patch.yml" ]; then
  log "writing $PROFILE_DIR/cordis.patch.yml (stateDir=$STATE_DIR)"
  mkdir -p "$STATE_DIR"
  cat > "$PROFILE_DIR/cordis.patch.yml" <<YAML
# Written by the container entrypoint. Replace it to change machine settings.
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

# --- 3. reach the loopback-only panel ---------------------------------------
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

# --- 4. start --------------------------------------------------------------
status_code() {
  local code=0
  scripts/dsh-superagent --profile "$PROFILE" --url "http://127.0.0.1:$PORT" \
    status > /dev/null 2>&1 || code=$?
  return "$code"
}

if ! status_code; then
  log "starting dsh-superagent (tmux session dsh-$PROFILE)"
  scripts/dsh-superagent --profile "$PROFILE" --url "http://127.0.0.1:$PORT" start || true
fi

# Same rule as the upstream hourly check: only exit 1 (not running) is fixed by
# a restart. 2 (a part errors) and 3 (setup waits) need a person.
if [ "$SUPERVISE" = "1" ]; then
  (
    while true; do
      sleep 60
      code=0
      status_code || code=$?
      if [ "$code" -ne 0 ] && [ "$code" -ne 2 ] && [ "$code" -ne 3 ]; then
        log "status exited $code; restarting"
        scripts/dsh-superagent --profile "$PROFILE" --url "http://127.0.0.1:$PORT" \
          --respect-stop restart > /dev/null 2>&1 || true
      fi
    done
  ) &
fi

# --- 5. tell the operator where to look -------------------------------------
LOG_FILE=$(ls -t .artifacts/dsh-superagent-*.log 2>/dev/null | head -1 || true)
TOKEN=""
for _ in $(seq 1 30); do
  if [ -n "$LOG_FILE" ]; then
    TOKEN=$(grep -o 'token=[A-Za-z0-9_-]*' "$LOG_FILE" 2>/dev/null | head -1 | cut -d= -f2 || true)
  fi
  [ -n "$TOKEN" ] && break
  sleep 2
  LOG_FILE=$(ls -t .artifacts/dsh-superagent-*.log 2>/dev/null | head -1 || true)
done

sleep 2
code=0
status_code || code=$?
case "$code" in
  0) log "ready" ;;
  1) log "not running; see the newest .artifacts/dsh-superagent-$PROFILE-*.log" ;;
  2) log "running, but a part reports an error; scripts/dsh-superagent status lists 'errors'" ;;
  3) log "running, but setup waits: open the panel Overview and configure a model, the GitHub Source and the Policy" ;;
esac

if [ -n "$TOKEN" ]; then
  log "panel: http://localhost:$PUBLISHED_PORT/?token=$TOKEN"
else
  log "panel: http://localhost:$PUBLISHED_PORT/ (token not found in $LOG_FILE)"
fi

exec tail -f /dev/null
