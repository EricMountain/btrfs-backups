#!/usr/bin/env python3

from os import listdir
from os.path import isdir, join
import re
import subprocess
import sys


base = '.'

# Prefix includes backup name + source device UUID
r = r"^(.+_[0-9a-f]+)_[0-9a-f]+_\d{8}-\d{6}$"
p = re.compile(r)

uuid_matcher = re.compile(r"\s\sUUID:[\s\\t]+([0-9a-f-]+)")
parent_uuid_matcher = re.compile(r"Parent UUID:[\s\\t]+([0-9a-f-]+)", re.M)

backups = {}
parent_uuids = {}
uuids = {}
chains = {}
first = {}

# Build map of backup groups (prefixes) to snapshots
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

for b in backups.keys():
    backups[b].sort()

    for snapshot in backups[b]:
        output = subprocess.run(["btrfs", "subvol", "show", join(base, snapshot)], text=True, capture_output=True)
        uuid_matches = uuid_matcher.search(output.stdout)
        parent_uuid_matches = parent_uuid_matcher.search(output.stdout)

        if not uuid_matches:
            print(f"{snapshot} has no uuid, this can't be right")
            sys.exit(1)
        uuid = uuid_matches.group(1)
        uuids[uuid] = snapshot

        if not parent_uuid_matches:
            print(f"{snapshot} has no parent field specified, this can't be right")
            sys.exit(1)
        parent_uuid = parent_uuid_matches.group(1)
        if parent_uuid == "-":
            print(f"{snapshot} has no parent, is first in chain")
            chains[uuid] = ''
            if b not in first:
                first[b] = []
            first[b].append(snapshot)
        else:
            parent_uuids[parent_uuid] = snapshot
            chains[uuid] = parent_uuid

for parent_uuid in chains.values():
    if parent_uuid != '' and parent_uuid not in chains:
        print(f"{parent_uuid} not present, {parent_uuids[parent_uuid]} is first in chain")
        if b not in first:
            first[b] = []
        first[b].append(snapshot)

print("First snapshots in each chain:")
for b in first:
    print(f"{b}")
    for snapshot in first[b]:
        print(f"  {snapshot}")

print("Latest snapshots per backup group:")
for b in backups.keys():
    print(f"{b}")
    print(f"  {backups[b][-1:]}")

