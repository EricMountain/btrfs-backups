#!/bin/bash

set -euo pipefail
#set -x

# Config
keep_last_x=20
snapshot_pool_root=/mnt/btrfs_pool_2_main
backup_pool_root=/mnt/btrfs_pool_1
snapshot_dir=__snapshots
backup_dir=__backup

trap 'catch "Error caught ($jobid: line $LINENO, exit code $?)"' ERR

ionice -c 3 -p $$
renice -n 20 $$ > /dev/null 2>&1

snapshot_path="${pool_root}/${snapshot_dir}"
backup_path="${pool_root}/${backup_dir}"
timestamp=$(date -u +%Y%m%d-%H%M%S)

[[ -d "${snapshot_path}" ]] || sudo mkdir -p "${snapshot_path}"
[[ -d "${backup_path}" ]] || sudo mkdir -p "${backup_path}"
