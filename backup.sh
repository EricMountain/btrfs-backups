#!/bin/bash

set -euo pipefail
#set -x

# Config
keep_last_x=20
source_root=/mnt/btrfs_pool_2_main
source_snapshot_dir=__snapshots
source_backup_dir=__backups
source_snapshot_path="${source_root}/${source_snapshot_dir}"
source_backup_path="${source_root}/${source_backup_dir}"

target_root=/mnt/btrfs_pool_1
target_snapshot_dir=__snapshots
target_snapshot_path="${target_root}/${target_snapshot_dir}"

catch() {
    errormsg="${1:-}"
    trap '' ERR
    echo $errormsg
}

trap 'catch "Error caught (line $LINENO, exit code $?)"' ERR

ionice -c 3 -p $$
renice -n 20 $$ > /dev/null 2>&1

timestamp=$(date -u +%Y%m%d-%H%M%S)

[[ -d "${source_snapshot_path}" ]] || sudo mkdir -p "${source_snapshot_path}"
[[ -d "${source_backup_path}" ]] || sudo mkdir -p "${source_backup_path}"
[[ -d "${target_snapshot_path}" ]] || sudo mkdir -p "${target_snapshot_path}"

# Build target device unique ID: UUID + directory on device
# Whether sending locally or over ssh, wherever this device is plugged,
# we will recognise it and use the snapshots it has
target_uuid=$(sudo btrfs fi show "${target_root}" | grep uuid | awk '{print $2, $4}' | sed -e "s/'//g" -e "s/ /+/")+"${target_snapshot_dir}"

cd "${source_snapshot_path}"
for x in * ; do
    [[ "$x" == "test_1" || "$x" == "test_2" ]] || continue
    [[ -d "$x" ]] || continue
    [[ -d "${source_backup_path}/$x" ]] || sudo btrfs subvolume create "${source_backup_path}/$x"
    [[ -d "${target_snapshot_path}/$x" ]] || sudo btrfs subvolume create "${target_snapshot_path}/$x"

    # Duplicate the latest snapshot to serve as send parent next time round for current target device
    latest_snapshot=$(ls -1 "$x" | tail -1)
    if ! sudo btrfs subvolume snapshot -r "$x/$latest_snapshot" "${source_backup_path}/$x/${timestamp}_${target_uuid}" ; then
        sudo btrfs subvolume delete "${source_backup_path}/$x/${timestamp}_${target_uuid}"
        echo Error creating snapshot, bailing
        exit 1
    fi

    # Send snapshot to target.  On success, remove previous local parent
    # snapshots for current target device as they are no longer needed.
    # Expiring backups on the target is its responsibility, hence not
    # handled here.  On failure, clean up to ensure future backups don't
    # try to use invalid snapshots.
    if sudo btrfs send "${source_backup_path}/$x/${timestamp}_${target_uuid}" | \
            sudo btrfs receive "${target_snapshot_path}/$x" ; then
        for obsolete in $(ls -1d "${source_backup_path}/$x/"*"_${target_uuid}" | grep -v ${timestamp}) ; do
            sudo btrfs subvolume delete "$obsolete"
        done
    else
        sudo btrfs subvolume delete "${target_snapshot_path}/$x/${timestamp}_${target_uuid}" || true
        sudo btrfs subvolume delete "${source_backup_path}/$x/${timestamp}_${target_uuid}"
        echo Error sending snapshot, bailing
    fi
done
