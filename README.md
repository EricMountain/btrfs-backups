# Backups using btrfs snapshot feature

## Intro

Assumes you have at least 2 btrfs pools:

* one with your active filesystems (those you want backed up)
* one where you will back up to (currently has to be locally attached,
  ssh coming soon)

The pool containing your active filesystems is expected to be laid out
as follows:

```
/pool
 |
 +--- __active
 |    |
 |    +--- volumes that will be snapshotted and backed up
 |
 +--- __snapshots
 |    |
 |    +--- snapshots of volumes in __active
 |
 +--- __backups
      |
      +--- snapshots that have been btrfs-sent to backup devices
```

Snapshots of volumes in `__active` are created in the same pool under
`__snapshots` as `name/timestamp`.

Backups are performed by creating a snapshot from the latest volume in
__snapshots for a given `name` and `btrfs-send`ing this snapshot to
another pool.  The previous matching snapshot in __backups for the
target device and name is used as parent for the `btrfs send` operation.
The previous parent is discarded if the backup operation succeeds.


## Hacks

### Recursive subvolume deletion

```
for x in $(btrfs subvol list $(pwd)  | sort -r --key=9 | awk '{print $9}' | grep ^__backups | sed -e 's/^__backups\///') ; do btrfs subvolume delete $x ; done
for x in $(btrfs subvol list $(pwd)  | sort -r --key=9 | awk '{print $9}' | grep ^__snapshots | sed -e 's/^__snapshots\///') ; do btrfs subvolume delete $x ; done
```
