#!/bin/bash

set -euo pipefail

# Config
source_root=/mnt/btrfs_pool_2_main
source_active_dir=__active
source_backup_dir=__backups
source_active_path="${source_root}/${source_active_dir}"
source_backup_path="${source_root}/${source_backup_dir}"

target_root=/mnt/btrfs_pool_1
target_active_dir=__actives
target_active_path="${target_root}/${target_active_dir}"

catch() {
    errormsg="${1:-}"
    trap '' ERR
    echo $errormsg
}

trap 'catch "Error caught (line $LINENO, exit code $?)"' ERR

ionice -c 3 -p $$
renice -n 20 $$ > /dev/null 2>&1

[[ -d "${source_backup_path}" ]] || sudo mkdir -p "${source_backup_path}"
[[ -d "${target_active_path}" ]] || sudo mkdir -p "${target_active_path}"

# Whether sending locally or over ssh, wherever the destination device
# is plugged, we will recognise it and update the last backup if
# present, or send a full stream. Including the active directory in the
# ID allows for multiple such directories on the destination.
target_uuid="("$(sudo btrfs fi show "${target_root}" | grep uuid | awk '{print $2, $4}' | sed -e "s/'//g" -e "s/ /+/")+"${target_active_dir}"")"

# Avoid conflicts with identical source names coming from other pools
# when backing up
source_uuid="("$(sudo btrfs fi show "${source_root}" | grep uuid | awk '{print $2, $4}' | sed -e "s/'//g" -e "s/ /+/")")+${source_active_dir}"

cd "${source_active_path}"
for x in * ; do
    #[[ "$x" == "test_1"* ]] || continue
    #[[ "$x" == "test_1"* || "$x" == "test_2"* ]] || continue
    [[ "$x" == "media1"* ]] || continue
    #[[ "$x" == "media1"* || "$x" == "music"* ]] || continue
    [[ -d "$x" ]] || continue
    [[ -d "${source_backup_path}/${x}_${source_uuid}" ]] || sudo btrfs subvolume create "${source_backup_path}/${x}_${source_uuid}"
    [[ -d "${target_active_path}/${x}_${source_uuid}" ]] || sudo btrfs subvolume create "${target_active_path}/${x}_${source_uuid}"

    # Snapshot active directory to serve as reference next time round
    source_backup="${source_backup_path}/${x}_${source_uuid}/${target_uuid}"
    parent_opt=""
    latest_backup_path=""
    if [[ -d "${source_backup}" ]] ; then
        parent_opt="-p"
        latest_backup_path="${source_backup}"
    fi

    if ! sudo btrfs subvolume snapshot -r "$x" "${source_backup}_new" ; then
        sudo btrfs subvolume delete "${source_backup}_new"
        echo $x: error creating snapshot, bailing
        exit 1
    fi

    # Send snapshot to target.
    destination_active="${target_active_path}/${x}_${source_uuid}/${target_uuid}"
    if sudo btrfs send ${parent_opt} ${latest_backup_path} "${source_backup}_new" | \
            sudo btrfs receive "${target_active_path}/${x}_${source_uuid}" ; then
        [[ -d "${source_backup}" ]] && sudo btrfs subvolume delete "${source_backup}"
        sudo mv "${source_backup}_new" "${source_backup}"
        [[ -d "${destination_active}" ]] && sudo btrfs subvolume delete "${destination_active}"
        sudo mv "${destination_active}_new" "${destination_active}"
    else
        sudo btrfs subvolume delete "${source_backup}" || true
        sudo btrfs subvolume delete "${destination_active}_new" || true
        echo $x: error sending snapshot, bailing
    fi
done
