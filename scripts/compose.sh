#!/usr/bin/env bash
# scripts/compose.sh <head|worker> <docker compose args...>
source "$(dirname "$0")/common.sh"
compose "$@"
