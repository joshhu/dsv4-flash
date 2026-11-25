#!/usr/bin/env bash
# Verify the CX7 link: jumbo frames, RoCE v2 GID, and raw RDMA bandwidth.
source "$(dirname "$0")/common.sh"
HCA=${NCCL_IB_HCA#=}; HCA=${HCA%%,*}

roce_gid() {  # prints first RoCE v2 IPv4-mapped GID index of $1
  local d=/sys/class/infiniband/$1/ports/1 i
  for i in $(ls "$d/gids" | sort -n); do
    [[ $(cat "$d/gid_attrs/types/$i" 2>/dev/null) == "RoCE v2" ]] || continue
    [[ $(cat "$d/gids/$i") == 0000:0000:0000:0000:0000:ffff:* ]] && { echo "$i"; return; }
  done
}

log "MTU 9000 path (no fragmentation) -> $WORKER"
ping -c3 -M do -s 8972 "$WORKER" >/dev/null && log "  OK" || die "jumbo frames fail; set MTU 9000 on $FABRIC_IF on both nodes"

gl=$(roce_gid "$HCA")
gw=$(on_worker bash -s <<<"$(declare -f roce_gid); roce_gid $HCA")
[[ -n $gl && -n $gw ]] || die "missing RoCE v2 IPv4 GID (local='$gl' worker='$gw')"
log "  RoCE v2 IPv4 GID index: local=$gl worker=$gw"

log "ib_write_bw on $HCA (worker = server, 5 s)"
on_worker "pkill -x ib_write_bw; nohup ib_write_bw -d $HCA -x $gw -F --report_gbits -D 5 >/tmp/ibbw.log 2>&1 &"
sleep 2
ib_write_bw -d "$HCA" -x "$gl" -F --report_gbits -D 5 "$WORKER" | tail -3
log "One PCIe half of the GB10 CX7 typically shows ~100-110 Gb/s; far lower => check cable / MTU."
