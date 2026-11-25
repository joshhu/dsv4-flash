#!/usr/bin/env bash
# Run on the Mac: copy this folder to the head node (start.sh then syncs it to the worker).
set -euo pipefail
cd "$(dirname "$0")"
rsync -a --delete --exclude logs/ ./ joshdgx:/home/joshhu/dsv4-flash/
echo "Deployed to joshdgx:/home/joshhu/dsv4-flash"
