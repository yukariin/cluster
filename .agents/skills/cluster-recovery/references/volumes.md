# Volume and SQLite recovery

Canonical procedures:

- [Volsync to Kopiur migration](../../../../docs/migration/volsync-to-kopiur.md)
- [RBD/ext4 corruption incident](../../../../docs/incidents/ext4-directory-checksum-corruption.md)
- [Three-node Ceph migration](../../../../docs/migration/3-node-ceph.md)

## Snapshot selection and PVCs

Inspect `kubernetes/components/kopiur`, the app's substitutions, and current
SnapshotPolicy/Restore status. The component currently sets
`sourcePathOverride: /data` for snapshot lineage continuity and uses
`csi-ceph-blockpool` snapshots with `ceph-block` storage by default. Preserve
identity unless an identity change is intentional and understood.

`Restore.spec.policy.onMissingSnapshot: Continue` can populate an empty volume
when no matching snapshot exists. Confirm a backup is actually selected before
treating a newly populated PVC as recovered.

The July migration found that populator Restores pinned their snapshot at
admission. An existing Restore may select an older backup even when its source
specification says latest. Verify current status/version behavior and plan any
Restore replacement together with the PVC lifecycle. Do not delete either object
as a diagnostic shortcut.

Existing PVCs use `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent` to avoid immutable
`dataSourceRef` changes. Do not force-replace them to resolve an apply failure.
Requested capacity edits may require an explicit expansion of existing claims.

## Ownership

The recorded Kopiur 0.9.0 restore preserved snapshot file ownership/modes.
Mover `fsGroup` affected the mount root; it did not rewrite all restored files.
Check both the volume root and representative restored files before diagnosing
permissions. The current component supplies app-specific mover user, group, and
pod `fsGroup`; inspect overrides and repository moverDefaults too.

## SQLite consistency

The older hostpath migration captured live SQLite files without an atomic
snapshot and restored malformed databases. Distinguish that failure from the
separate RBD directory-metadata incident in the canonical document.

For live SQLite, choose a database-native online backup, application quiescing,
or a verified atomic snapshot covering the database and WAL together. A loose
file copy or checkpoint alone is not a consistency guarantee while writers run.
Verify the actual backend and copy method even though this repository now uses
Ceph snapshots. Check integrity on a disposable restored copy and then verify the
application's data; do not perform repairs on the only source copy.
