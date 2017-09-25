#!/bin/bash

set -euo pipefail

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

[[ -d "${source_snapshot_path}" ]] || sudo mkdir -p "${source_snapshot_path}"
[[ -d "${source_backup_path}" ]] || sudo mkdir -p "${source_backup_path}"
[[ -d "${target_snapshot_path}" ]] || sudo mkdir -p "${target_snapshot_path}"

# Whether sending locally or over ssh, wherever the destination device
# is plugged, we will recognise it and use the snapshots it
# has. Including the snapshot directory in the ID allows for multiple
# such directories on the destination.
target_uuid="("$(sudo btrfs fi show "${target_root}" | grep uuid | awk '{print $2, $4}' | sed -e "s/'//g" -e "s/ /+/")+"${target_snapshot_dir}"")"

cd "${source_snapshot_path}"
for x in * ; do
    [[ "$x" == "test_1"* ]] || continue
    #[[ "$x" == "test_1"* || "$x" == "test_2"* ]] || continue
    #[[ "$x" == "media1" || "$x" == "music" ]] || continue
    [[ -d "$x" ]] || continue
    [[ -d "${source_backup_path}/$x" ]] || sudo btrfs subvolume create "${source_backup_path}/$x"
    [[ -d "${target_snapshot_path}/$x" ]] || sudo btrfs subvolume create "${target_snapshot_path}/$x"

    # Locate latest backup to use as parent and check it exists on the
    # destination, otherwise discard (failed backup)
    parent_opt=""
    latest_backup=$(ls -1 "${source_backup_path}/$x" | tail -1)
    latest_backup_path=""
    while [[ -n "${latest_backup}" ]] ; do
        latest_backup_path="${source_backup_path}/$x/${latest_backup}"
        latest_backup_on_destination="${target_snapshot_path}/$x/${latest_backup}"
        if [[ ! -d "${latest_backup_on_destination}" ]] ; then
            echo $x: found failed backup, deleting snapshot
            sudo btrfs subvolume delete "${latest_backup_path}"
            latest_backup=$(ls -1 "${source_backup_path}/$x" | tail -1)
            latest_backup_path=""
        else
            parent_opt="-p"
            break
        fi
    done

    # Duplicate the latest snapshot to serve as send parent next time
    # round for current target device
    latest_snapshot=$(ls -1 "$x" | tail -1)
    source_snapshot="${source_backup_path}/$x/${latest_snapshot}_${target_uuid}"
    if [[ ! -d "${source_snapshot}" ]] ; then
        if ! sudo btrfs subvolume snapshot -r "$x/${latest_snapshot}" "${source_snapshot}" ; then
            sudo btrfs subvolume delete "${source_snapshot}"
            echo $x: error creating snapshot, bailing
            exit 1
        fi
    fi

    # Send snapshot to target.  On success, remove previous local parent
    # snapshots for current target device as they are no longer needed.
    # Expiring backups on the target is its responsibility, hence not
    # handled here.  On failure, clean up to ensure future backups don't
    # try to use invalid snapshots.
    destination_snapshot="${target_snapshot_path}/$x/${latest_snapshot}_${target_uuid}"
    if [[ ! -d "${destination_snapshot}" ]] ; then
        if sudo btrfs send ${parent_opt} ${latest_backup_path} "${source_snapshot}" | \
                sudo btrfs receive "${target_snapshot_path}/$x" ; then
            for obsolete in $(ls -1d "${source_backup_path}/$x/"*"_${target_uuid}" | grep -v "${latest_backup_path}") ; do
                sudo btrfs subvolume delete "$obsolete"
            done
        else
            sudo btrfs subvolume delete "${destination_snapshot}" || true
            sudo btrfs subvolume delete "${source_snapshot}" || true
            echo $x: error sending snapshot, bailing
        fi
    else
        # Delete this snapshot otherwise parent will be missing on next
        # run
        sudo btrfs subvolume delete "${source_snapshot}"
        echo $x: no new snapshot to backup
    fi
done
