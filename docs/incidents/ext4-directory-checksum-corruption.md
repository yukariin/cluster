# ext4 checksum errors on RBD-backed VolSync clones (EBADMSG)

Recurring filesystem fault affecting `ceph-block` volumes restored or
provisioned through VolSync's snapshot-and-clone workflow. Applications fail
with `Bad message` (`EBADMSG`, errno `-74`) during directory operations while
Ceph reports healthy placement groups and OSDs.

The original theory blamed ext4 or `mkfs.ext4` for creating directories without
checksum-tail space. Raw inspection of the preserved source snapshot disproved
that theory. The best-supported explanation is now a transient client-side RBD
mapping/read problem during rapid cache-volume teardown and layered-clone
mapping. The exact failing component has not yet been proven.

## Symptoms

Application-level errors include:

```
Error: Unknown system error -74: Unknown system error -74, mkdir '/config/thelounge/logs'
  errno: -74, code: 'Unknown system error -74', syscall: 'mkdir'
```

```
java.nio.file.FileSystemException: /data/libraries/net/java/dev: Bad message
```

Kernel-level errors on the affected node include:

```
EXT4-fs error (device rbd6): ext4_validate_block_bitmap:423: comm ext4lazyinit: bg 32: bad block bitmap checksum
EXT4-fs warning (device rbd6): ext4_dirblock_csum_verify:375: inode #2: comm node: No space for directory leaf checksum. Please run e2fsck -D.
EXT4-fs error (device rbd6): __ext4_find_entry:1626: inode #2: comm node: checksumming directory block 0
```

The directory error can be latent until an application walks or modifies the
affected directory. A pod can therefore appear `Running` before encountering
`EBADMSG`.

`No space for directory leaf checksum` does **not** prove that mkfs failed to
reserve a checksum tail. It means the bytes read for that directory block do
not contain a valid ext4 directory-tail layout. A wrong, stale, or zeroed block
can produce the same message.

## Incidents

### 2026-07-04/05 — three-node migration

Every application volume was destroyed and restored from Kopia through
VolSync. Several restored applications subsequently returned `EBADMSG`,
including autobrr, jellyseerr, pinchflat, jellyfin, vaultwarden, kavita,
forgejo, matrix-synapse media, and the paper Minecraft server.

Surviving application logs placed read-side failures on multiple nodes:

| When (UTC) | Node | Pod | Error |
|---|---|---|---|
| 2026-07-04 16:52 | flandre | vaultwarden | `message: "Bad message"` |
| 2026-07-05 06:06 | sakuya | paper | `FileSystemException: /data/libraries/net/java/dev: Bad message` |

The cluster ran Talos v1.13.5 with Linux 6.18.36. Kernel logs were not retained.
Affected volumes were repaired with offline `e2fsck -fD` and did not regress in
steady-state use.

### 2026-07-15 — thelounge, empty restore

The first thelounge deployment failed on remilia while running Talos v1.13.6
and Linux 6.18.38. The Kopia repository contained no thelounge snapshot, so the
mover restored zero application bytes:

1. VolSync provisioned a fresh 5 GiB destination RBD image.
2. Ceph CSI formatted it as ext4.
3. The mover completed without restoring files.
4. VolSync created a VolumeSnapshot.
5. The application PVC was cloned from that snapshot.
6. The application's first `mkdir` under the root directory returned
   `EBADMSG`.

This rules out restored application data as a requirement, but it does not
implicate mkfs: the snapshot taken from the formatted destination was preserved
and its raw filesystem metadata is valid.

## Forensic findings from the thelounge incident

### RBD device-reuse timeline

The node log shows the same kernel RBD device ID being reused within seconds:

| Node time | Event |
|---|---|
| 07:29:46 | `/dev/rbd6` mapped as a 4 GiB VolSync cache image and mounted |
| 07:30:01 | Cache filesystem cleanly unmounted |
| 07:30:06 | `/dev/rbd6` reused for the 5 GiB layered thelounge application clone |
| 07:30:11 | `ext4lazyinit` rejected block-group 32's bitmap checksum |
| 07:30:18 | Application reads of inode 2 began returning directory-tail errors |

Block group 32 starts at filesystem block `1,048,576`, which at a 4 KiB block
size is byte `4,294,967,296`: exactly the 4 GiB boundary of the previous cache
device. This alignment is the strongest evidence connecting the error to RBD
device teardown/reuse rather than ordinary ext4 directory creation.

### The preserved parent snapshot is valid

The application image retained its 5 GiB snapshot parent after repair. The
parent was inspected read-only through userspace `librbd`, avoiding the kernel
RBD mapping involved in the incident.

- The ext4 superblock was clean and did not have `needs_recovery` set.
- Root inode 2 logical block 0 mapped to physical filesystem block 8,865.
- Its final 12 bytes contained a valid ext4 directory checksum tail.
- The stored and independently calculated checksum both equaled `0xd95e7074`.
- Group 32's block bitmap was at physical block `1,048,576`.
- Its stored and calculated checksum both equaled `0x75dd2315`.
- The snapshot had been cleanly unmounted before the VolumeSnapshot was taken.

The `e2fsck` free-block correction is independently explained by the first
kernel error. Group 32 contained 28,656 free blocks. When ext4 marks a block
group's bitmap corrupt, it removes that group's free blocks from its usable
counter:

```
1,268,642 - 28,656 = 1,239,986
```

Those are exactly the counted and recorded values printed by `e2fsck`:

```
Free blocks count wrong (1239986, counted=1268642).
```

The directory-tail warning was therefore not the first detected fault; it was
preceded by a bad bitmap read at the former device-size boundary.

### ext4 and e2fsprogs behavior

The Ceph CSI image used e2fsprogs 1.46.5. Its directory-creation code explicitly
reserves and initializes the checksum tail when `metadata_csum` is enabled; see
[`newdir.c`](https://github.com/tytso/e2fsprogs/blob/v1.46.5/lib/ext2fs/newdir.c#L29-L91).
The Linux warning is emitted when the block being verified lacks the expected
tail structure; see the ext4 directory verification path in
[`namei.c`](https://github.com/torvalds/linux/blob/master/fs/ext4/namei.c#L2743-L2867).

Together with the valid parent bytes, this rules out the previous theory that
mkfs created the source directory without checksum-tail space.

## Current root-cause assessment

### High-confidence conclusions

- Kopia did not introduce the thelounge corruption; it restored zero bytes.
- The source filesystem and root directory created by mkfs were structurally
  valid in the preserved parent snapshot.
- The source snapshot was cleanly unmounted, so this was not an ordinary
  crash-consistency snapshot.
- Ceph has no evidence of at-rest OSD corruption. BlueStore and placement-group
  health remained clean.
- `e2fsck -fD` repairs the observed metadata and repaired volumes remain stable
  during ordinary application use.

### Best-supported hypothesis

A rapid kernel-RBD (`krbd`) teardown/remap sequence, Ceph CSI lifecycle race,
or interaction with a layered RBD clone caused the newly mapped application
device to return incoherent blocks. The relevant sequence included:

- a short-lived 4 GiB Ceph-backed Kopia cache PVC;
- cache cleanup and RBD unmap;
- reuse of the same `/dev/rbd6` ID for a 5 GiB clone five seconds later;
- a first invalid metadata read exactly at the old 4 GiB boundary;
- a snapshot child using `layering`, `exclusive-lock`, `object-map`,
  `fast-diff`, and `deep-flatten` image features.

`HEALTH_OK` only establishes that Ceph's servers can read their stored objects
correctly. It cannot rule out a client reading the wrong image, parent, offset,
or stale block state.

### Remaining uncertainty

The affected child was repaired before a pre-fsck snapshot was preserved. It is
therefore impossible to distinguish conclusively between:

1. incorrect bytes stored in child COW objects during clone/first mount; and
2. correct RBD data presented incorrectly by the kernel mapping.

No exact upstream fix has been tied to this incident. Treat the client-mapping
explanation as strongly supported, not proven.

## Why similar homelabs may not reproduce it

The compared configurations do not exercise the same temporary-volume path:

- [`deedee-ops/home-ops`](https://github.com/deedee-ops/home-ops/blob/951a8ce0ce399f58a64ff8502e8ac97895a97399/kubernetes/components/volsync/replicationdestination.yaml)
  uses OpenEBS hostpath for its VolSync cache. Its history also used
  `emptyDir`; it did not put the short-lived cache on Ceph RBD.
- [`Exikle/Artemis-Cluster`](https://github.com/Exikle/Artemis-Cluster/blob/918b8a73462efe39c79c84910647376f40413d1e/kubernetes/components/volsync/replicationdestination.yaml)
  omits cache-PVC configuration, producing `emptyDir`, and currently uses XFS
  for its block StorageClass.
- Artemis also dropped the expanded RBD feature set after three separate krbd
  I/O failures; see its
  [2026-07-09 change](https://github.com/Exikle/Artemis-Cluster/commit/021b6fe81d43d4bb2530aca6a6387c69786de5e9).

Even identical declarative configuration would not guarantee reproduction of a
timing-sensitive lifecycle fault. Restore concurrency, pod placement, device-ID
reuse, OSD events, and teardown timing are runtime variables not visible in a
Git repository.

## Mitigation applied on 2026-07-15

The shared VolSync ReplicationSource and ReplicationDestination components now
retain only:

```yaml
cacheCapacity: 4Gi
```

Both `cacheAccessModes` and `cacheStorageClassName` were removed. In the pinned
`ghcr.io/perfectra1n/volsync:v0.17.11` build, capacity-only configuration uses a
4 GiB disk-backed `emptyDir` rather than a PVC. With no cache fields at all, the
same build defaults to an 8 GiB `emptyDir`. If either cache access modes or a
cache StorageClass is specified, it takes the PVC path; see the exact image
revision's
[`ensureCache` implementation](https://github.com/perfectra1n/volsync/blob/0b08a4874576188255523833c9569c5f252064d0/internal/controller/mover/kopia/mover.go#L300-L390).

This removes the disposable cache RBD map/unmap immediately preceding the
destination snapshot and application-clone mount. It is the mitigation most
directly supported by the incident timeline.

Existing live ReplicationDestinations intentionally retain their old fields.
They carry:

```yaml
labels:
  kustomize.toolkit.fluxcd.io/ssa: IfNotPresent
```

Flux creates these bootstrap objects when absent but does not reconcile their
specs afterward. This preserves their one-shot restore state. A dormant
ReplicationDestination does not create or map a cache merely by existing, so
old fields on an unused object are harmless. The new capacity-only component
applies when a ReplicationDestination is newly created. Before manually
retriggering an existing destination, either recreate it from the current
component or remove its cache PVC fields explicitly.

## Recovery procedure

### Preserve evidence first if the fault recurs

Do not run fsck immediately; it overwrites the evidence needed to isolate the
fault.

1. Suspend the application's Flux Kustomization and HelmRelease and scale the
   workload to zero.
2. Confirm detachment with `rbd status`; the affected image must show no
   watchers.
3. Capture the affected node's complete dmesg and Ceph CSI RBD node-plugin logs.
4. Record the PV, VolumeAttachment, image name, parent, image features, size,
   snapshots, and VolSync mover/job events.
5. Create a read-only forensic RBD snapshot of the affected child before any
   repair, for example `@pre-fsck-<timestamp>`.
6. Compare the same metadata blocks through:
   - userspace `librbd` from the preserved child snapshot;
   - a fresh read-only `krbd` mapping;
   - `rbd-nbd`, if available;
   - the parent snapshot.

If userspace reads are valid while krbd reads are not, the kernel/client path is
proven. If all clients read the same bad child bytes while the parent is valid,
the clone/COW write path is implicated.

### Repair after preservation

1. Keep the workload stopped and verify that the image has no watchers.
2. Map the affected image from a privileged maintenance pod.
3. Run offline `e2fsck -fD` and review its proposed changes. Use `-y` only when
   non-interactive repair is deliberately required.
4. Run a second `e2fsck -f` pass and require a clean result.
5. Unmap the image, start the workload, and watch node logs during its first
   directory operations.

A VolumeSnapshot created from a genuinely corrupt child will preserve that
state, so recloning it is not a repair.

## Post-change observation plan

Before the next backup or restore:

1. Confirm scheduled ReplicationSources do not request a cache StorageClass or
   cache access modes. For ReplicationDestinations, inspect the specific object
   that will be used for a bootstrap; older dormant objects are expected to
   retain their original spec because of `ssa: IfNotPresent`:

   ```sh
   kubectl get replicationdestination,replicationsource -A -o json \
     | jq -r '.items[] | [.kind, .metadata.namespace, .metadata.name,
       (.spec.kopia.cacheCapacity // "<unset>"),
       (.spec.kopia.cacheStorageClassName // "<unset>"),
       ((.spec.kopia.cacheAccessModes // []) | join(","))] | @tsv'
   ```

2. Before triggering an older ReplicationDestination, recreate it from the
   current component or patch out both `cacheAccessModes` and
   `cacheStorageClassName`. Do not expect a normal Flux reconciliation to change
   it.
3. During one source backup and one destination restore, inspect the mover pod.
   Its volume named `cache` should contain:

   ```yaml
   emptyDir:
     sizeLimit: 4Gi
   ```

4. Confirm that no `volsync-src-*-cache` or `volsync-dst-*-cache` PVC is created.
5. Capture the affected node's RBD map/unmap and ext4 messages through the
   mover cleanup and first application mount.
6. Exercise a disposable test restore through the complete
   provision -> populate -> snapshot -> clone -> first-mount workflow before a
   future mass restore.
7. Retain kernel logs across node reboots. The migration incidents could not be
   reconstructed fully because only container logs were shipped.

Alert on at least `EXT4-fs error`, `EXT4-fs warning`, `Bad message`, RBD I/O
errors, and CSI map/unmap failures. Application readiness alone is insufficient
because the directory error can remain latent.

## Additional mitigations to test if it recurs

- Create a separate StorageClass using only `imageFeatures: layering` for new
  restored volumes. RBD image features are fixed when an image is created, so
  changing a StorageClass does not alter existing images.
- A/B test Ceph CSI's `rbd-nbd` mounter to bypass krbd for affected workflows.
- Flatten restored clones before their first application mount to remove parent
  lookups from the steady-state read path.
- Test the workflow after Talos/kernel and Ceph CSI upgrades, one variable at a
  time.

XFS avoids this specific ext4 directory-tail error but cannot make incorrect
block reads safe. Disabling ext4 `metadata_csum` is not recommended: it removes
the detector and may turn a loud metadata error into silent corruption.
