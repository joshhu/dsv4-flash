#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
log "Stopping head"; compose head down || true
log "Stopping worker"; on_worker "bash '$REMOTE_ROOT/scripts/compose.sh' worker down" || true
