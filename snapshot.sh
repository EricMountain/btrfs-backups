#!/bin/bash

set -euo pipefail
#set -x

# Config
keep_last_x=20
pool_root=/mnt/btrfs_pool_2_main
active_dir=__active
snapshot_dir=__snapshots

catch() {
    errormsg="${1:-}"
    trap '' ERR
    echo $errormsg
}

trap 'catch "Error caught (line $LINENO, exit code $?)"' ERR

ionice -c 3 -p $$
renice -n 20 $$ > /dev/null 2>&1

active_path="${pool_root}/${active_dir}"
snapshot_path="${pool_root}/${snapshot_dir}"
timestamp=$(date -u +%Y%m%d-%H%M%S)

[[ -d "${snapshot_path}" ]] || sudo mkdir -p "${snapshot_path}"

cd "${active_path}"
for x in * ; do
    [[ -d "$x" ]] || continue
    [[ -d "${snapshot_path}/$x" ]] || sudo btrfs subvolume create "${snapshot_path}/$x"
    sudo btrfs subvolume snapshot -r $x "${snapshot_path}/$x/$timestamp"
done

cd "${snapshot_path}"
for x in * ; do
    for expired in $(ls -1 "$x" | head -n -${keep_last_x}) ; do
        sudo btrfs subvolume delete "$x/$expired"
    done
done
