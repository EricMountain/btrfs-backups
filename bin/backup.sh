#!/bin/bash

# e.g:
# ./bin/backup.sh --source=/mnt/btrfs_pool_3_ssd --target=/mnt --target-shell "ssh -x eric@crucible.local"
# ./bin/backup.sh --source=/mnt/btrfs_pool_2_main --target=/mnt --target-shell "ssh -x eric@crucible.local"
# ./bin/backup.sh --source=/mnt/btrfs_pool_3_ssd --target=/mnt/btrfs_pool_1
# ./bin/backup.sh --source=/mnt/btrfs_pool_2_main --target=/mnt/btrfs_pool_1

set -euo pipefail

catch() {
    errormsg="${1:-}"
    trap '' ERR
    echo $errormsg
}

trap 'catch "Error caught (line $LINENO, exit code $?)"' ERR

usage() {
    cat - <<EOF
Usage: $0 [args]

--source       Source btrfs pool
--target       Target btrfs pool
EOF

    false
}

getopt=$(getopt -n $0 -o h -l source:,target:,target-shell:,help -- "$@")
eval set -- "$getopt"

declare source_root=""
declare target_root=""
declare target_shell=""

while true ; do
    case "$1" in
        --source)
            source_root=$2
            shift 2
            ;;
        --target)
            target_root=$2
            shift 2
            ;;
        --target-shell)
            target_shell="$2"
            shift 2
            ;;
        --help|h)
            usage
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Internal error processing options: $*"
            false
            ;;
    esac
done

[[ -z ${source_root} ]] && echo Need --source. && false
[[ -z ${target_root} ]] && echo Need --target. && false

ionice -c 3 -p $$
renice -n 20 $$ > /dev/null 2>&1

source_active_dir=__active
source_backup_dir=__backups
source_active_path="${source_root}/${source_active_dir}"
source_backup_path="${source_root}/${source_backup_dir}"

target_active_dir=__active
target_active_path="${target_root}/${target_active_dir}"

[[ -d "${source_backup_path}" ]] || sudo mkdir -p "${source_backup_path}"
${target_shell} [[ -d "${target_active_path}" ]] || ${target_shell} sudo mkdir -p "${target_active_path}"

# Whether sending locally or over ssh, wherever the destination device
# is plugged, we will recognise it and update the last backup if
# present, or send a full stream. Including the active directory in the
# ID allows for multiple such directories on the destination.
target_uuid=$(${target_shell} sudo btrfs fi show "${target_root}" | grep uuid | awk '{print $2, $4}' | sed -e "s/'//g" -e "s/ /+/")+"${target_active_dir}"

# Avoid conflicts with identical source names coming from other pools
# when backing up
source_uuid=$(sudo btrfs fi show "${source_root}" | grep uuid | awk '{print $2, $4}' | sed -e "s/'//g" -e "s/ /+/")"+${source_active_dir}"

cd "${source_active_path}"
for x in * ; do
    [[ -d "$x" ]] || continue

    if [[ -e "$x/.no_backup" ]] ; then
        echo $x: skipping due to .no_backup flag
        continue
    fi

    echo $x: starting backup

    [[ -d "${source_backup_path}/${x}_${source_uuid}" ]] || sudo btrfs subvolume create "${source_backup_path}/${x}_${source_uuid}"
    ${target_shell} [[ -d "${target_active_path}/${x}_${source_uuid}" ]] || ${target_shell} sudo btrfs subvolume create "${target_active_path}/${x}_${source_uuid}"

    # Snapshot active directory to serve as reference next time round
    source_backup="${source_backup_path}/${x}_${source_uuid}/${target_uuid}"
    parent_opt=""
    latest_backup_path=""
    if [[ -d "${source_backup}" ]] ; then
        parent_opt="-p"
        latest_backup_path="${source_backup}"
    fi

    if ! sudo btrfs subvolume snapshot -r "$x" "${source_backup}_new" ; then
        sudo btrfs subvolume delete "${source_backup}_new" || true
        echo $x: error creating snapshot, bailing
        exit 1
    fi

    # Send snapshot to target.
    destination_active="${target_active_path}/${x}_${source_uuid}/${target_uuid}"
    if sudo btrfs send ${parent_opt} ${latest_backup_path} "${source_backup}_new" | \
            ${target_shell} sudo btrfs receive "${target_active_path}/${x}_${source_uuid}" ; then
        [[ -d "${source_backup}" ]] && sudo btrfs subvolume delete "${source_backup}"
        sudo mv "${source_backup}_new" "${source_backup}"
        ${target_shell} [[ -d "${destination_active}" ]] && ${target_shell} sudo btrfs subvolume delete "${destination_active}"
        ${target_shell} sudo mv "${destination_active}_new" "${destination_active}"
        echo $x: backed up
    else
        sudo btrfs subvolume delete "${source_backup}" || true
        ${target_shell} sudo btrfs subvolume delete "${destination_active}_new" || true
        echo $x: error sending snapshot, bailing
    fi
done
