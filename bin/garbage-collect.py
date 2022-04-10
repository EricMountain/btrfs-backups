#!/usr/bin/env python3

from os import listdir
from os.path import isdir, join
import re
import subprocess
import sys
import argparse


def list_backups(base):
    # Prefix includes backup name + source device UUID + target device UUID
    r = r"^(.+_[0-9a-f]+_[0-9a-f]+)_\d{8}-\d{6}$"
    p = re.compile(r)

    backups = {}
    # Build map of backup groups (prefixes) to sorted snapshots
    for d in listdir(base):
        if not isdir(join(base, d)):
            continue

        if d.endswith("_latest"):
            continue

        if d.startswith("."):
            # Skip in-progress backup
            continue

        matches = p.match(d)
        if not matches:
            continue

        backup = matches.group(1)
        if backup not in backups:
            backups[backup] = []

        backups[backup].append(d)
    
    for b in backups:
        backups[b].sort()

    return backups

def trim_lists(backups, keep):
    """Strips lists of snapshots for each group of the x most recent ones so they will be kept"""
    for b in backups:
        backups[b] = (backups[b])[0:-keep]
    return backups

def print_backups(backups):
    for b in backups:
        print(f"Group: {b}")
        for s in backups[b]:
            print(f"  {s}")
        break

def delete_backups(base, backups):
    for b in backups:
        for snapshot in backups[b]:
            output = subprocess.run(["echo", "btrfs", "subvol", "del", "-C", join(base, snapshot)], text=True, capture_output=True)
            print(f"{output.stdout}")

def main(args):
    if args.work_on_active:
        base = join(args.target, "__active")
    else:
        base = join(args.target, "__backups")

    backups = list_backups(base)
    print("Full list of backups:")
    print_backups(backups)

    backups = trim_lists(backups, args.keep)
    print("Trimmed list:")
    print_backups(backups)

    delete_backups(base, backups)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Purge backups')
    parser.add_argument("--target",
                        help="Top-level btrfs pool mount",
                        type=str,
                        required=True)
    parser.add_argument("--work-on-active",
                        help="Work on __active (on backup server), default is __backups",
                        type=bool,
                        default=False)
    parser.add_argument("--keep",
                        help="Number of backups to keep per group",
                        type=int,
                        default=10)
    args = parser.parse_args()

    main(args)
