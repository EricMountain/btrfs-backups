#!/bin/bash

# e.g:
# ./bin/backup.sh --source=/mnt/btrfs_pool_3_ssd --target=/mnt --target-shell "ssh -x eric@crucible.local"
# ./bin/backup.sh --source=/mnt/btrfs_pool_2_main --target=/mnt --target-shell "ssh -x eric@crucible.local"
# ./bin/backup.sh --source=/mnt/btrfs_pool_3_ssd --target=/mnt/btrfs_pool_1
# ./bin/backup.sh --source=/mnt/btrfs_pool_2_main --target=/mnt/btrfs_pool_1

# for x in __metadata* ; do echo -------- $x ; grep -hE 'hostname|volume_name|timestamp' $x/* | sed -e 's/^\(timestamp=....-..-..\).*$/\1/' | sort -u ; done

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

[ -z ${source_root} ] && echo Need --source. && false
[ -z ${target_root} ] && echo Need --target. && false

ionice -c 3 -p $$
renice -n 20 $$ > /dev/null 2>&1

source_active_dir=__active
source_backup_dir=__backups
source_active_path="${source_root}/${source_active_dir}"
source_backup_path="${source_root}/${source_backup_dir}"

target_active_dir=__active
target_active_path="${target_root}/${target_active_dir}"

[ -d "${source_backup_path}" ] || sudo mkdir -p "${source_backup_path}"
${target_shell} [ -d "${target_active_path}" ] || ${target_shell} sudo mkdir -p "${target_active_path}"

# Whether sending locally or over ssh, wherever the destination device
# is plugged, we will recognise it and update the last backup if
# present, or send a full stream. Including the active directory in the
# ID allows for multiple such directories on the destination.
target_uuid_label=$(${target_shell} sudo btrfs fi show "${target_root}" | grep uuid | sed -e "s/^.*'\(.*\)'.*\$/\1/")
target_uuid_devid=$(${target_shell} sudo btrfs fi show "${target_root}" | grep uuid | sed -E -e "s/^.*uuid: ([^ ]+).*\$/\1/")
target_uuid_dir="${target_active_dir}"
target_uuid=$(echo $target_uuid_label $target_uuid_devid $target_uuid_dir | sha1sum | awk '{print $1}')

# Avoid conflicts with identical source names coming from other pools
# when backing up
source_uuid_label=$(sudo btrfs fi show "${source_root}" | grep uuid | sed -e "s/^.*'\(.*\)'.*\$/\1/")
source_uuid_devid=$(sudo btrfs fi show "${source_root}" | grep uuid | sed -E -e "s/^.*uuid: ([^ ]+).*\$/\1/")
source_uuid_dir="${source_active_dir}"
source_uuid=$(echo $source_uuid_label $source_uuid_devid $source_uuid_dir | sha1sum | awk '{print $1}')

uuid=${source_uuid}_${target_uuid}

cd "${source_active_path}"
[ -d "${source_active_path}/__metadata" ] || sudo btrfs subvolume create "${source_active_path}/__metadata"
let doMetadata=0 || true
for x in * __metadata ; do
    [ -d "$x" ] || continue

    # Ensure __metadata is backed up last
    if [ $doMetadata -eq 0 -a "${x}" == "__metadata" ]  ; then
        let doMetadata=1
        continue
    fi

    if [ -e "$x/.no_backup" ] ; then
        echo -- $x: skipping due to .no_backup flag
        continue
    fi

    echo -- $x: saving metadata
    sudo /bin/bash -c  "cat - > __metadata/${x}_${uuid}.btrfs-backups.metadata" <<EOF
# Backup of ${x} for device pair ${uuid}
timestamp=$(date -u "+%Y-%m-%d_%H:%M:%S_%Z")

source_hostname=$(hostname)
source_mountpath=${source_active_path}
source_volume_name=${x}
source_uuid_label=$source_uuid_label
source_uuid_devid=$source_uuid_devid
source_uuid_dir=$source_uuid_dir
source_uuid=$source_uuid

target_uuid_label=$target_uuid_label
target_uuid_devid=$target_uuid_devid
target_uuid_dir=$target_uuid_dir
target_uuid=$target_uuid
EOF

    echo -- $x: starting backup

    # Snapshot active directory to serve as reference next time round
    source_backup="${source_backup_path}/${x}_${uuid}"
    source_backup_new="${source_backup_path}/.${x}_${uuid}_new"
    parent_opt=""
    latest_backup_path=""
    if [ -d "${source_backup}" ] ; then
        parent_opt="-p"
        latest_backup_path="${source_backup}"
    fi

    [ -d "${source_backup_new}" ] && sudo btrfs subvolume delete "${source_backup_new}"

    if ! sudo btrfs subvolume snapshot -r "$x" "${source_backup_new}" ; then
        sudo btrfs subvolume delete "${source_backup_new}" || true
        echo -- $x: error creating snapshot, bailing
        exit 1
    fi

    destination_active="${target_active_path}/${x}_${uuid}"
    destination_active_new="${target_active_path}/.${x}_${uuid}_new"
    ${target_shell} [ -d "${destination_active_new}" ] && ${target_shell} sudo btrfs subvolume delete "${destination_active_new}"

    # Send snapshot to target.
    if sudo btrfs send ${parent_opt} ${latest_backup_path} "${source_backup_new}" | \
            ${target_shell} sudo btrfs receive "${target_active_path}" ; then

        [ -d "${source_backup}" ] && sudo btrfs subvolume delete "${source_backup}"
        sudo mv "${source_backup_new}" "${source_backup}"

        ${target_shell} [ -d "${destination_active}" ] && ${target_shell} sudo btrfs subvolume delete "${destination_active}"
        ${target_shell} sudo mv "${destination_active_new}" "${destination_active}"

        echo -- $x: backed up
    else
        sudo btrfs subvolume delete "${source_backup_new}" || true
        ${target_shell} sudo btrfs subvolume delete "${destination_active_new}" || true

        echo -- $x: error sending snapshot, bailing
    fi
done
