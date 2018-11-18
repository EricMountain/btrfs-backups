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

