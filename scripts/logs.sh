#!/usr/bin/env bash
# scripts/logs.sh [worker]   — follow container logs
source "$(dirname "$0")/common.sh"
if [[ ${1:-head} == worker ]]; then on_worker "docker logs -f --tail 200 dsv4-flash"; else docker logs -f --tail 200 dsv4-flash; fi
