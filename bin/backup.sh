#!/bin/bash

# e.g:
# ./bin/backup.sh --source=/mnt/btrfs_pool_3_ssd --target=/mnt --target-shell "ssh -x eric@crucible.local"
# ./bin/backup.sh --source=/mnt/btrfs_pool_2_main --target=/mnt --target-shell "ssh -x eric@crucible.local"
# ./bin/backup.sh --source=/mnt/btrfs_pool_3_ssd --target=/mnt/btrfs_pool_1
# ./bin/backup.sh --source=/mnt/btrfs_pool_2_main --target=/mnt/btrfs_pool_1

#set -x

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. ${dir}/common.sh

usage() {
    cat - <<EOF
Usage: $0 [args]

--source       Source btrfs pool
--target       Target btrfs pool
EOF

    false
}

writeMetadata() {
    local x=$1
    local -n configRef=$2
    echo -- ${x}: Saving metadata
    sudo /bin/bash -c  "cat - > __metadata/${x}_${configRef[uuid]}.btrfs-backups.metadata" <<EOF
# Backup of ${x} for device pair ${configRef[uuid]}
timestamp=$(date -u "+%Y-%m-%d_%H:%M:%S_%Z")

source_hostname=$(hostname)
source_mountpath=${configRef[source_active_path]}
source_volume_name=${x}
source_uuid_label=${configRef[source_uuid_label]}
source_uuid_devid=${configRef[source_uuid_devid]}
source_uuid_dir=${configRef[source_uuid_dir]}
source_uuid=${configRef[source_uuid]}

target_uuid_label=${configRef[target_uuid_label]}
target_uuid_devid=${configRef[target_uuid_devid]}
target_uuid_dir=${configRef[target_uuid_dir]}
target_uuid=${configRef[target_uuid]}
EOF
}

## Main ##############################################################

getopt=$(getopt -n $0 -o h -l source:,target:,target-shell:,help -- "$@")
eval set -- "$getopt"

declare -A config=( [source_root]="" [target_root]="" [target_shell]="" )

while true ; do
    case "$1" in
        --source)
            config[source_root]=$2
            shift 2
            ;;
        --target)
            config[target_root]=$2
            shift 2
            ;;
        --target-shell)
            config[target_shell]="$2"
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

[ -z ${config[source_root]} ] && echo Need --source. && false
[ -z ${config[target_root]} ] && echo Need --target. && false

ionice -c 3 -p $$
renice -n 20 $$ > /dev/null 2>&1

echo -- Init: configuring

config[timestamp]=$(date -u +%Y%m%d-%H%M%S)

config[source_active_dir]=__active
config[source_backup_dir]=__backups
config[source_active_path]="${config[source_root]}/${config[source_active_dir]}"
config[source_backup_path]="${config[source_root]}/${config[source_backup_dir]}"

config[target_active_dir]=__active
config[target_active_path]="${config[target_root]}/${config[target_active_dir]}"

[ -d "${config[source_backup_path]}" ] || sudo mkdir -p "${config[source_backup_path]}"
${config[target_shell]} [ -d "${config[target_active_path]}" ] || ${config[target_shell]} sudo mkdir -p "${config[target_active_path]}"

# Whether sending locally or over ssh, wherever the destination device
# is plugged, we will recognise it and update the last backup if
# present, or send a full stream. Including the active directory in the
# ID allows for multiple such directories on the destination.
config[target_uuid_label]=$(${config[target_shell]} sudo btrfs fi show "${config[target_root]}" | grep uuid | sed -e "s/^.*'\(.*\)'.*\$/\1/")
config[target_uuid_devid]=$(${config[target_shell]} sudo btrfs fi show "${config[target_root]}" | grep uuid | sed -E -e "s/^.*uuid: ([^ ]+).*\$/\1/")
config[target_uuid_dir]="${config[target_active_dir]}"
config[target_uuid]=$(echo ${config[target_uuid_label]} ${config[target_uuid_devid]} ${config[target_uuid_dir]} | sha1sum | awk '{print $1}')

# Avoid conflicts with identical source names coming from other pools
# when backing up
config[source_uuid_label]=$(sudo btrfs fi show "${config[source_root]}" | grep uuid | sed -e "s/^.*'\(.*\)'.*\$/\1/")
config[source_uuid_devid]=$(sudo btrfs fi show "${config[source_root]}" | grep uuid | sed -E -e "s/^.*uuid: ([^ ]+).*\$/\1/")
config[source_uuid_dir]="${config[source_active_dir]}"
config[source_uuid]=$(echo ${config[source_uuid_label]} ${config[source_uuid_devid]} ${config[source_uuid_dir]} | sha1sum | awk '{print $1}')

config[uuid]=${config[source_uuid]}_${config[target_uuid]}

cd "${config[source_active_path]}"
[ -d "${config[source_active_path]}/__metadata" ] || sudo btrfs subvolume create "${config[source_active_path]}/__metadata"

declare -A status=([doMetadata]=0 [errorsOccurred]=0)
declare -A bkp
for x in * __metadata ; do
    bkp=([hasError]=0)

    [ -d "${x}" ] || continue

    # Ensure __metadata is backed up last
    if [ ${status[doMetadata]} -eq 0 -a "${x}" == "__metadata" ]  ; then
        status[doMetadata]=1
        continue
    elif [ "${x}" == "__metadata" ] ; then
        writeMetadata ${x} config
    fi

    if [ -e "${x}/.no_backup" ] ; then
        echo -- ${x}: Skipping due to .no_backup flag
        continue
    fi

    echo -- ${x}: Starting backup

    bkp[source_backup_basename]="${config[source_backup_path]}/${x}_${config[uuid]}"
    bkp[source_backup]="${config[source_backup_path]}/${x}_${config[uuid]}_${config[timestamp]}"
    bkp[source_backup_new]="${config[source_backup_path]}/.${x}_${config[uuid]}_${config[timestamp]}"
    
    bkp[parent_opt]=""
    bkp[latest_backup_path]=""

    bkp[destination_active]="${config[target_active_path]}/${x}_${config[uuid]}_${config[timestamp]}"
    bkp[destination_active_basename]="${config[target_active_path]}/${x}_${config[uuid]}"
    bkp[destination_active_new]="${config[target_active_path]}/.${x}_${config[uuid]}_${config[timestamp]}"
    bkp[destination_active_new_basename]="${config[target_active_path]}/.${x}_${config[uuid]}_"
    bkp[destination_active_last_UUID]=""

    echo -- ${x}: Delete stale backups on destination
    for d in $(${config[target_shell]} ls -1d "${bkp[destination_active_new_basename]}"* 2> /dev/null) ; do
        if ! ${config[target_shell]} sudo btrfs subvolume delete "${d}" ; then
            echo -- ${x}: Warning, unable to delete stale backup "${d}" on target, continuing
        else
            echo -- ${x}: Deleted stale backup "${d}" on target
        fi
    done

    echo -- ${x}: Clean out any orphan snapshots
    if [ -n "$(ls -1d ${config[source_backup_path]}/.${x}_${config[uuid]}* 2> /dev/null)" ] ; then 
        if ! sudo btrfs subvolume delete "${config[source_backup_path]}/.${x}_${config[uuid]}"* ; then
            echo -- ${x}: Error, unable to delete orphan snapshots, continuing
        fi
    fi

    echo -- ${x}: Check for an existing backup on the target
    for d in $(${config[target_shell]} ls -dr1 "${bkp[destination_active_basename]}"* 2> /dev/null) ; do
        bkp[destination_active_last_UUID]=$(${config[target_shell]} sudo btrfs subvol show "${d}" | grep "Received UUID" | awk '{print $3}')
        if [ -n "${bkp[destination_active_last_UUID]}" ] ; then
            break
        fi
    done

    # Prior snapshot needs to have UUID == bkp[destination_active_last_UUID]
    echo -- ${x}: Check for prior snapshot that can serve as a reference
    if [ -n "${bkp[destination_active_last_UUID]}" ] ; then
        echo -- ${x}: Existing backup reference: ${bkp[destination_active_last_UUID]}
        tmp=$(sudo btrfs subvol list -u -r ${config[source_backup_path]} | grep "${bkp[destination_active_last_UUID]}" | cut -d / -f 2) || true
        if [ -n "${tmp}" ] ; then
            bkp[latest_backup_path]="${config[source_backup_path]}/${tmp}"
            bkp[parent_opt]="-p"
            echo -- ${x}: Parent backup found: ${bkp[latest_backup_path]}
        else
            echo -- ${x}: No parent backup found
        fi
    fi

    echo -- ${x}: Snapshot active directory
    if ! sudo btrfs subvolume snapshot -r "${x}" "${bkp[source_backup_new]}" ; then
        sudo btrfs subvolume delete "${bkp[source_backup_new]}" || true
        echo -- ${x}: Warning: failed to create snapshot "${bkp[source_backup_new]}"
        status[errorsOccurred]=1
        bkp[hasError]=1
        continue
    fi

    echo -- ${x}: Send snapshot to target
    if sudo btrfs send ${bkp[parent_opt]} ${bkp[latest_backup_path]} "${bkp[source_backup_new]}" | \
            ${config[target_shell]} sudo btrfs receive "${config[target_active_path]}" ; then

        sudo mv "${bkp[source_backup_new]}" "${bkp[source_backup]}"

        ${config[target_shell]} sudo mv ${bkp[destination_active_new]} ${bkp[destination_active]}

        echo -- ${x}: Backed up
    else
        sudo btrfs subvolume delete "${bkp[source_backup_new]}" || true
        ${config[target_shell]} sudo btrfs subvolume delete "${bkp[destination_active_new]}" || true

        echo -- ${x}: error sending snapshot
        status[errorsOccurred]=1
        bkp[hasError]=1
        continue
    fi

    # Only update metadata after a successful backup, except when backing up 
    # metadata itself (in which case, the metadata needs to be updated before
    # backing up else the backup target will hold stale data). Hmpf.
    if [ "${x}" != "__metadata" -a ${bkp[hasError]} -eq 0 ] ; then
        writeMetadata ${x} config
    fi
done    

exit ${status[errorsOccurred]}
