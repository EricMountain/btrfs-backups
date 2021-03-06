#!/bin/bash

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

. ${dir}/common.sh

usage() {
    cat - <<EOF
Usage: $0 [args]

--target       Target btrfs pool
EOF

    false
}


## Main ##############################################################

getopt=$(getopt -n $0 -o h -l target:,target-shell:,help -- "$@")
eval set -- "$getopt"

declare -A config=( [source_root]="" [target_root]="" [target_shell]="" )

while true ; do
    case "$1" in
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

[ -z ${config[target_root]} ] && echo Need --target. && false

config[target_active_dir]=__active
config[target_active_path]="${config[target_root]}/${config[target_active_dir]}"

cd ${config[target_active_path]}

current=
for bkp_pool in $(ls -rd1 __metadata*-*) ; do
    # Chop off the date for grouping same-source/target entries
    tmp=${bkp_pool:0:(-16)}
    if [ -z "${current}" -o "${current}" != "${tmp}" ] ; then
        current="${tmp}"
        for bkp_meta in ${bkp_pool}/* ; do
            declare -A metadata
            while IFS== read key value ; do
                #echo DEBUG: $key --  $value
                if [ -z "${key}" -o -z "${value}" ] ; then continue ; fi
                metadata[${key}]=$value
            done < ${bkp_meta}

            echo ${metadata[timestamp]} ${metadata[source_uuid]} "-->" ${metadata[target_uuid]} \
                 = ${metadata[target_uuid_label]} "<--" ${metadata[source_hostname]}/${metadata[source_volume_name]}
        done
    fi
done | sort
