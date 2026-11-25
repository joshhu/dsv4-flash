# Sourced by the other scripts. Run everything on the HEAD node (JoshDGX).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER=10.20.0.12          # JoshDGX2 over the CX7 fabric
REMOTE_ROOT="$ROOT"        # same path on the worker

set -a; source "$ROOT/config/common.env"; set +a

compose() {  # compose <head|worker> <args...>   (runs locally)
  local role=$1; shift
  local files=(--env-file "$ROOT/config/common.env" --env-file "$ROOT/config/$role.env")
  [[ -f "$ROOT/config/secret.env" ]] && files+=(--env-file "$ROOT/config/secret.env")
  COMPOSE_DISABLE_ENV_FILE=1 docker compose -p dsv4-flash "${files[@]}" -f "$ROOT/docker-compose.yml" "$@"
}

on_worker() { ssh -o BatchMode=yes "$WORKER" "$@"; }

sync_worker() {
  on_worker "mkdir -p '$REMOTE_ROOT'"
  rsync -a --delete --exclude logs/ "$ROOT/" "$WORKER:$REMOTE_ROOT/"
}

log() { printf '\033[1;36m[dsv4]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[dsv4] %s\033[0m\n' "$*" >&2; exit 1; }
