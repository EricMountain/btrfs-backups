# Backups using btrfs snapshot feature

## Intro

Assumes you have at least 2 btrfs pools:

* one with your active filesystems (those you want backed up)
* one where you will back up to (currently has to be locally attached, ssh coming soon)

The pool containing your active filesystems is expected to be laid out as follows:

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
      +--- snapshots of volumes in __snapshots that have been btrfs-sent to backup devices
```
