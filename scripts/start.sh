#!/usr/bin/env bash
# Start worker (rank 1) first, then head (rank 0). Run on the head node.
source "$(dirname "$0")/common.sh"

gpu_busy='n=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader | wc -l); mine=$(docker ps -q -f name=^dsv4-flash$ | wc -l); if [ "$n" -gt 0 ] && [ "$mine" -eq 0 ]; then docker ps --format "  {{.Names}} ({{.Image}})"; exit 1; fi'
bash -c "$gpu_busy" || die "Head GPU is in use by the container(s) above. Stop it first: this model needs ~108 GB per node."
on_worker "$gpu_busy" || die "Worker GPU is in use by the container(s) above. Stop it first."

[[ -f "$MODEL_DIR/config.json" ]] || die "Model missing at $MODEL_DIR. Run scripts/download-model.sh first."
on_worker "test -f '$MODEL_DIR/config.json'" || die "Model missing on worker. Run scripts/download-model.sh."

log "Syncing this folder to worker"
sync_worker
mkdir -p "$JIT_TMP"; on_worker "mkdir -p '$JIT_TMP'"
for side in local worker; do
  if [[ $side == local ]]; then docker image inspect "$VLLM_IMAGE" >/dev/null 2>&1 || docker pull "$VLLM_IMAGE"
  else on_worker "docker image inspect '$VLLM_IMAGE' >/dev/null 2>&1 || docker pull '$VLLM_IMAGE'"; fi
done

log "Starting worker (rank 1)"
on_worker "bash '$REMOTE_ROOT/scripts/compose.sh' worker down --remove-orphans >/dev/null 2>&1; bash '$REMOTE_ROOT/scripts/compose.sh' worker up -d"
sleep 15
on_worker "docker ps -q -f name=^dsv4-flash$ -f status=running | grep -q ." || { on_worker "docker logs --tail 50 dsv4-flash"; die "worker container died"; }

log "Starting head (rank 0)"
compose head down --remove-orphans >/dev/null 2>&1 || true
compose head up -d

log "Waiting for http://127.0.0.1:$API_PORT/health (weights load + cudagraph + autotune, first boot can take 10-20 min)"
for i in $(seq 1 180); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$API_PORT/health"; then
    log "Ready after ~$((i*10))s:  http://192.168.1.112:$API_PORT/v1  (model: $SERVED_MODEL_NAME)"
    exit 0
  fi
  docker ps -q -f name=^dsv4-flash$ -f status=running | grep -q . || { docker logs --tail 80 dsv4-flash; die "head container died"; }
  on_worker "docker ps -q -f name=^dsv4-flash$ -f status=running | grep -q ." || { on_worker "docker logs --tail 80 dsv4-flash"; die "worker container died"; }
  sleep 10
done
die "Timed out. Check: scripts/logs.sh  and  scripts/logs.sh worker"
