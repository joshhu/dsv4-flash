#!/usr/bin/env bash
# Quick API check + one chat completion with tok/s.  HOST=192.168.1.112 scripts/smoke.sh  works from the Mac too.
set -euo pipefail
HOST=${HOST:-127.0.0.1}; PORT=${PORT:-8888}; MODEL=${MODEL:-deepseek-v4-flash}
AUTH=(); [[ -n ${VLLM_API_KEY:-} ]] && AUTH=(-H "Authorization: Bearer $VLLM_API_KEY")
curl -fsS ${AUTH[@]+"${AUTH[@]}"} "http://$HOST:$PORT/v1/models" | python3 -m json.tool | head -20
start=$(date +%s.%N)
resp=$(curl -fsS ${AUTH[@]+"${AUTH[@]}"} "http://$HOST:$PORT/v1/chat/completions" -H 'Content-Type: application/json' -d "{
  \"model\": \"$MODEL\", \"max_tokens\": 400,
  \"messages\": [{\"role\": \"user\", \"content\": \"用繁體中文解釋 tensor parallelism，約 200 字。\"}]}")
end=$(date +%s.%N)
python3 - "$resp" "$start" "$end" <<'PY'
import json, sys
r = json.loads(sys.argv[1]); dt = float(sys.argv[3]) - float(sys.argv[2])
print(r["choices"][0]["message"]["content"])
n = r["usage"]["completion_tokens"]
print(f"\n--- {n} tokens in {dt:.1f}s  ≈ {n/dt:.1f} tok/s (includes prefill)")
PY
