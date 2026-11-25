#!/usr/bin/env bash
# Download deepseek-ai/DeepSeek-V4-Flash-0731 (~167 GB) on the head, then copy to the worker over CX7.
source "$(dirname "$0")/common.sh"
REPO=deepseek-ai/DeepSeek-V4-Flash-0731
REV=${REV:-main}

mkdir -p "$MODEL_DIR" "$HF_CACHE"
docker image inspect "$VLLM_IMAGE" >/dev/null 2>&1 || docker pull "$VLLM_IMAGE"

log "Downloading $REPO@$REV -> $MODEL_DIR (resumable; rerun if interrupted)"
docker run --rm --network host -u "$(id -u):$(id -g)" \
  -e HF_HOME=/hf -e HF_HUB_DISABLE_XET=1 -e HF_TOKEN="${HF_TOKEN:-}" \
  -v "$HF_CACHE:/hf" -v "$MODEL_DIR:/out" --entrypoint python3 "$VLLM_IMAGE" -c "
from huggingface_hub import snapshot_download
snapshot_download('$REPO', revision='$REV', local_dir='/out', max_workers=8)
"
du -sh "$MODEL_DIR"

log "Copying weights to worker $WORKER over the CX7 link"
on_worker "mkdir -p '$MODEL_DIR'"
rsync -a --info=progress2 --exclude .cache/ "$MODEL_DIR/" "$WORKER:$MODEL_DIR/"
log "Checksumming file list on both sides"
diff <(cd "$MODEL_DIR" && find . -type f -not -path './.cache/*' -printf '%P %s\n' | sort) \
     <(on_worker "cd '$MODEL_DIR' && find . -type f -not -path './.cache/*' -printf '%P %s\n' | sort") \
  && log "Worker copy matches." || die "Worker copy differs; rerun this script."
