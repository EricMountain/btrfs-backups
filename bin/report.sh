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

for x in __metadata* ; do echo -------- $x ; for y in $x/* ; do grep -hE 'label|hostname|volume_name|timestamp' $y | sed -e 's/^\(timestamp=....-..-..\).*$/\1/' ; done ; done