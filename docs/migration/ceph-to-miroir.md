# Plan: gradual Ceph → miroir migration

**Status:** proposed, 2026-10-29. Documentation only; no deployment or disk
operation has been performed. Commit/push and execution are separate steps.

Use Exikle's Artemis approach: rebuild one whole-disk Ceph OSD at a time onto
a smaller partition, provision miroir on a separate partition of that same
drive, then migrate workloads individually while both storage systems run.
Keep the OS drives and the Kubernetes cluster intact.

## Proposed target

| Setting | Proposal |
| --- | --- |
| Backend | LVM-thin on each existing data NVMe |
| Pool | `default`, on `/dev/disk/by-partlabel/r-miroir` |
| Local StorageClass | `miroir-local`, replicas `1`, for CNPG and disposable caches |
| Replicated StorageClass | `miroir-replicated`, replicas `3`, quorum `freeze` |
| Filesystem | ext4, matching the existing application volumes |
| Binding / expansion | `WaitForFirstConsumer` / enabled for both classes |
| SnapshotClass | `miroir-snap`, driver `miroir.home-operations.com` |
| Default class | Keep `ceph-block` during migration; change after the last cutover |
| Backup staging | `miroir-local` in the same pool as the source |
| Automatic replica movement | Leave auto-diskful and auto-eviction disabled initially |

Three replicated copies are the proposed starting policy because that preserves
the current Ceph copy count. Two copies plus a diskless witness is a valid
alternative, but choose it before creating production PVCs; do not silently
reduce redundancy as part of the migration. The two classes share the same thin
pool, so local and replicated volumes share its capacity and disk failure domain.

Keep CNPG's final instance count at two. Temporarily use three instances during
its storage migration to avoid deliberately running a single PostgreSQL instance
while a standby is rebuilt. PostgreSQL replication is currently asynchronous;
the local-storage target therefore does not promise zero transaction loss after
an abrupt primary-disk failure. Any change to synchronous replication is a
separate availability/RPO decision.

## Baseline and capacity

Read-only observations on 2026-10-29, to be refreshed before execution:

- Three schedulable control-plane nodes, Talos 1.14.5 / Kubernetes 1.37.2.
- Ceph `HEALTH_OK`, 81 PGs `active+clean`, three OSDs `up` and `in`.
- Pools use three copies; the observed `min_size` is two.
- Approximately 38 GiB logical RBD data and 111 GiB total raw Ceph usage.
- All 34 application PVCs use `ceph-block`, requesting about 249 GiB in total;
  there are no CephFS PVCs.
- CNPG 1.30.1 manages `database/postgres`, two healthy instances with required
  hostname anti-affinity, Barman backups and WAL archiving to the NAS.
- Twenty-five PVCs have Kopiur policies. Two CNPG PVCs use database-native
  protection; two caches and five observability PVCs have no Kopiur policy.

Proposed layout on **each data drive**, in this physical order:

| Partition | Size during coexistence | Purpose |
| --- | --- | --- |
| `r-miroir` | 640 GiB, bounded, non-growing | Permanent miroir LVM-thin pool |
| `r-rook` | Up to 256 GiB, growing | Temporary replacement Ceph OSD |
| Unallocated tail | Remainder | Alignment/headroom; reclaimed with Ceph later |

The combined 896 GiB fits the currently reported approximately 931+ GiB data
devices, subject to checking exact usable capacity and partition overhead on
each drive. At current usage a 256 GiB Ceph OSD has substantial headroom, but
the smallest OSD limits every three-copy pool. Check actual per-OSD usage,
snapshots, expected growth and Ceph fullness thresholds before each rebuild;
requested PVC size alone is neither current usage nor a capacity reservation.

The miroir pool is much larger than the current application requests even with
three copies. Budget temporary restores, snapshots, a third CNPG instance and
thin-pool metadata as well. Start with conservative admission settings, preferably
`overcommitRatio: 1` and `freeSpaceRatio: 1`, and monitor physical data and metadata
usage; these settings do not prevent existing thin volumes from growing.

`r-miroir` must be first so it can later grow forward into the retired Ceph
partition. Use the partition name **`rook`, not `ceph`**: ceph-volume can reject
partition labels containing `ceph`. The proposed Talos documents are:

```yaml
apiVersion: v1alpha1
kind: RawVolumeConfig
name: miroir
provisioning:
  diskSelector:
    match: <verified per-node data-disk selector excluding system_disk>
  minSize: 640GiB
  maxSize: 640GiB
---
apiVersion: v1alpha1
kind: RawVolumeConfig
name: rook
provisioning:
  diskSelector:
    match: <same verified selector>
  grow: true
  minSize: 256GiB
  maxSize: 256GiB
```

This is a design sketch, not an apply-ready patch. Validate allocation order
against the installed Talos version and verify the first converted disk's GPT
before touching another. Existing BlueStore space cannot be shrunk in place.

## Invariants and rollback boundaries

- Exactly one data-drive conversion at a time. Start and finish every node
  conversion with all Ceph PGs `active+clean`, three OSDs `up/in`, and `HEALTH_OK`.
- With one OSD removed, Ceph remains at two copies and normally serves I/O at
  `min_size=2`. It cannot place a third host copy until the replacement exists.
  Do **not** wait for `active+clean` between removal and replacement: it cannot
  occur in that interval. Another OSD failure stops I/O; do not treat survival
  of the remaining copy as a guarantee against data loss.
- Do not lower pool size or `min_size` to make a health/safety check pass. Rook's
  automatic drain/replacement path may wait for full replication or
  `safe-to-destroy`, which may not succeed in this topology. Use a reviewed
  single-OSD rebuild procedure rather than an unattended purge job or a generic
  drain-and-rebalance recipe.
- Preserve monitors, etcd, `/var/lib/rook`, OS disks, and all other nodes.
  A data-drive conversion is not a Talos reset or cluster bootstrap.
- **OSD purge/wipe is the first irreversible step for that OSD.** Recovery is
  then rebuilding a Ceph OSD from the surviving copies, with verified external
  backups as the independent fallback. A Git revert does not restore a disk.
- Patch each source PV to `Retain` before deleting its claim for a cutover.
  A stopped retained Ceph PV is a rollback source only until its underlying
  storage is retired. Keep a fresh external backup independently.
- Once an application accepts writes on miroir, its old Ceph copy is stale.
  Rollback requires stopping writers and transferring the new state back, or
  explicitly accepting rollback to the recorded earlier restore point.
- Observability history is disposable by user decision. Recreate all five
  observability volumes empty; no new backup coverage is required for them.

## Phase 0 — prepare and prove recovery

1. Refresh the live inventory and disk map. Record node → OSD ID → stable data
   device → size → partitions, plus OS-disk identity. Keep detailed recovery
   bundles and credentials outside the tracked/public repository. Current OSD
   IDs below are evidence, not future command arguments:

   | Proposed order | Node | Observed OSD | Data drive |
   | --- | --- | --- | --- |
   | 1 | flandre | 2 | Crucial P310 1 TB |
   | 2 | remilia | 1 | Crucial P310 1 TB |
   | 3 | sakuya | 0 | Phison 1 TB |

2. Confirm fresh successful NAS uploads for all 25 preserved Kopiur sources,
   and a fresh completed Barman base backup with continuous WAL archiving.
   Verify backup identities and recoverability, not just the presence of policy
   objects. Rehearse one app restore and one isolated CNPG restore using the
   [volume recovery](../../.agents/skills/cluster-recovery/references/volumes.md)
   and [CNPG recovery](../../.agents/skills/cluster-recovery/references/cnpg.md)
   guidance. Scratch CNPG must not archive into the production archive.
3. Export the PVC/PV bindings, controllers, replica counts, snapshot policies,
   selected backup IDs and necessary manifests into a private recovery bundle.
   Confirm NAS access and recovery credentials do not depend on Forgejo's PVC.
4. Arrange manual maintenance control: pause automated node upgrades and storage
   dependency upgrades for the window. Record how each controller/reconciliation
   was paused and how it will resume; suspending a Flux child alone can be
   reverted by its parent. Do not run two storage operations concurrently.
5. Prepare staged Git changes. Keep unconverted nodes' raw-volume documents and
   miroir membership inactive. Do not apply partition declarations to a live
   whole-disk OSD and rely on Talos rejecting them.
6. Validate future manifest changes with the repository's actual checks in
   [cluster-validation](../../.agents/skills/cluster-validation/SKILL.md).
   Before each deployment, compare Forgejo HEAD, GitHub mirror HEAD and Flux's
   artifact revision. Pushes can deploy; do not publish all phases together.

**Gate:** backups/drills verified, exact disk targets recorded, capacity checked,
and the first node's patch and operational procedure reviewed before any purge.

## Phase 1 — Talos prerequisites and inert miroir scaffolding

1. Pin the miroir chart/images and review the chosen release and bundled DRBD
   compatibility. Research baseline: miroir 0.12.9. Add `siderolabs/drbd` to the
   existing Image Factory schematic without dropping other extensions.
2. Configure `drbd` with `usermode_helper=disabled` and load
   `drbd_transport_tcp`; verify `dm_thin_pool` is available. Set kubelet shutdown
   grace to at least 120 seconds with a 60-second critical-pod window, matching
   miroir's agent grace. Use Talos 1.14's supported config document forms.
3. Audit the actual Talos upgrade path before using it. The current
   `talos/mod.just` `machine-image` helper reads `.machine.install.image`, while
   the template now sets `UnattendedInstallConfig.installer.image`; correct and
   validate that lookup as part of implementation, rather than invoking the
   stale recipe. Update the intended schematic/image references consistently.
4. Install the extension/config one node at a time, without partition changes.
   Drain normally, respect PDBs, and wait for Ceph/CNPG recovery before the next
   node. Verify the loaded DRBD version and shutdown configuration on every node.
5. Add `kubernetes/apps/miroir-system/miroir` using neighboring app conventions:
   privileged namespace, OCIRepository/HelmRelease, separate configuration Flux
   Kustomization after the driver and existing snapshot-controller, storage
   classes, snapshot class, monitoring, and a label-selected MiroirNodeGroup.
   Initially select no nodes; the chart/config must not initialize any disk.
6. Use a dedicated membership label such as
   `storage.miroir.home-operations.com/enabled=true`, added in each node's Git
   config only after its partition is verified. The node-group template names
   the `default` LVM-thin pool on `r-miroir`.
7. Move DRBD's port base away from the host-network Ceph dashboard, provisionally
   `7800`, after checking the complete allocated range and existing listeners.
   Confirm host ephemeral ports cannot collide. Check agent metrics ports too.
   Current volumes retain allocated ports if the base later changes.
8. Review the open DRBD teardown issue and Artemis's Talos LVM-scan incident
   against the exact selected Talos/DRBD versions. If an LVM scan filter is
   needed, validate its supported installation and preserve visibility of the
   real PVs and dm-thin devices; do not copy an old host configuration blindly.
   Resolve this before replicated production volumes are created.

Keep `ceph-block` default, all existing app dependencies intact, and RWX disabled.

**Gate:** prerequisites work on all three nodes; Ceph and CNPG are healthy;
driver is deployed but no data drive has changed ownership.

## Phase 2 — convert flandre, then prove the first pool

Repeat this procedure only for the selected node. Keep Kubernetes API/etcd and
the other two Ceph OSDs available throughout.

1. Recheck all health, backup and identity gates. Make the selected node's
   durable Rook device selection point only to `/dev/disk/by-partlabel/r-rook`.
   Other nodes must continue selecting their original whole disks. Prefer
   explicit per-node devices over broad regexes; never match miroir's partition
   or an OS device. Prepare this change before wiping so Rook cannot reclaim
   the freshly blank whole disk.
2. Pause the owning Flux Kustomizations/HelmReleases as needed so temporary
   maintenance changes persist. Keep the Rook operator available for the drain
   so it can manage Ceph disruption budgets; pause it afterward for OSD teardown
   and disk handover. Ceph daemons/CSI on surviving nodes must stay running.
3. Cordon/drain the selected node, handling singleton workload disruption and
   PDBs deliberately. Do not bypass a blocked CNPG drain by forcing pod deletion.
   Once the drain is complete, pause the Rook operator, verify the selected OSD
   is stopped, and confirm no process holds the data device.
4. Remove the selected OSD using the reviewed host-based rebuild procedure:
   mark out/purge that exact OSD and remove its old deployment as appropriate.
   Expect the known two-copy degraded state. Check that every PG remains active
   and no second OSD, monitor quorum or control-plane failure appears.
5. Wipe **only the verified data disk**. Before this first partitioning it is a
   whole-disk OSD; once miroir exists there, future whole-disk wipes are forbidden.
6. Apply only this node's two RawVolumeConfig documents. Wait for ready volumes;
   verify `r-miroir` is physically first, both partitions have the planned sizes,
   and the system disk is unchanged. Fix allocation problems before restarting
   provisioning; do not let either CSI guess the intended partition.
7. Restore the Rook operator with the reviewed device selection active. Allow
   Rook to build a new OSD on `r-rook`; discover its actual new ID. Verify its
   backing path, then wait for all recovery/backfill to finish and `HEALTH_OK`.
   Restore reconciliation only against the correct Git revision.
8. Persist the node's miroir membership label in Git, apply it, and verify its
   MiroirNode/pool status and LVM backing path. Uncordon when the node and storage
   are healthy, restoring any temporary workload/controller settings.
9. Run disposable **local** PVC tests: write/read a marker, restart the consumer,
   expand, snapshot/restore, verify contents and delete test resources normally.
   Use a consumer on this node to satisfy `WaitForFirstConsumer`. Also exercise
   a Kopiur round trip before the first valuable app cutover.

**Gate:** three healthy Ceph OSDs, clean PGs, healthy first miroir pool, successful
local tests, and no unexplained errors. Keep production app PVCs on Ceph here.

If conversion fails after the wipe, repair or recreate `r-rook` and rebuild the
third OSD before resuming migration. Do not proceed to another node. Once the
first miroir volume exists, recovery must preserve that partition even if the
Ceph OSD needs another rebuild.

## Phase 3 — convert remilia and sakuya; test replication

Repeat Phase 2's disk conversion for remilia, then sakuya. Before each drain,
also require every existing miroir volume to be Ready; after each return, wait
for all affected DRBD legs to become UpToDate. Membership must follow verified
partition creation, never precede it.

After all three pools are ready, test `miroir-replicated` with three replicas:

- Provision, write/read, consumer rescheduling, expansion and snapshot/restore.
- Perform a Kopiur backup to the NAS and restore into a new miroir PVC. Check
  permissions and contents, not merely Bound/Ready status.
- Configure snapshot backup staging on `miroir-local` in the same pool and
  confirm it does not create a second replicated application-sized volume.
- Exercise one planned node drain/reboot with a disposable replicated workload.
  Confirm remaining nodes serve data and recovery finishes before touching any
  other node. Local test volumes on that node may be unavailable while it is down.
- Confirm no stuck LVM scans, DRBD teardown/resync errors or pool-space alarms.

Add miroir readiness/resync health gates to **both** tuppr upgrade resources
before returning automated upgrades to service. Retain the Ceph health gate
throughout coexistence. Node-group readiness alone does not prove every volume's
replicas are synchronized; gate on current volume state as well.

**Gate:** all three nodes support local and replicated volumes, backup/restore
and planned maintenance pass, and Ceph remains healthy alongside miroir.

## Phase 4 — migrate workloads in small batches

Use per-app storage/snapshot substitutions while shared defaults remain Ceph.
Keep operators, HPAs, Helm and Flux from recreating an old claim or restarting
writers during a cutover. Resume only controllers belonging to that cutover.

Suggested order: disposable caches → one low-impact Kopiur app such as recyclarr
→ other preserved app volumes → CNPG → identity and Forgejo → observability.
Adjust app order for shared dependencies and actual controller ownership.

### Preserved application PVCs

1. Record the source PVC/PV and policy identity; change the PV reclaim policy to
   `Retain`. Stop every writer, including operator-managed pods and jobs, then
   take a final backup **using the old Ceph snapshot class** and wait for the
   NAS upload to complete. Embedded databases/WAL must be captured consistently.
2. Record the exact Kopiur snapshot ID and create a fresh Restore pinned to it.
   Require failure if the snapshot is absent; the component's current
   `onMissingSnapshot: Continue` is inappropriate for a preserved-data migration.
   Do not reuse an old Restore on the assumption that `offset: 0` resolves again.
3. Create a new claim on `miroir-replicated`, preferably with a distinct migration
   name to preserve the old binding. Where generated names require replacement
   in place, retain/export the old PV binding before deleting only the old PVC.
   Editing `storageClassName` on a bound PVC is not a migration.
4. Supply a controlled consumer to trigger `WaitForFirstConsumer`; a workload at
   zero replicas can leave the populator waiting indefinitely. Avoid starting
   the real writer until restoration and ownership checks have passed.
5. Switch the workload, its Flux dependency and its backup configuration together:
   `KOPIUR_STORAGECLASS=miroir-replicated`,
   `KOPIUR_SNAPSHOTCLASS=miroir-snap`, and same-pool local staging. Preserve the
   repository identity and `sourcePathOverride: /data` for snapshot history.
6. Verify ownership, representative files/timestamps, application reads/writes
   and database integrity where applicable. Check SQLite on an offline restored
   copy. Take and verify a new miroir-backed NAS backup before the next batch.
7. Keep the stopped retained Ceph source and recorded backup until the rollback
   checkpoint is accepted. Never permit old and new application copies to write
   to the same external database concurrently.

StatefulSet `volumeClaimTemplates` are immutable. Plan controller recreation with
claim retention where needed; changing Helm values alone does not update an
existing template. Inspect each StatefulSet's PVC retention policy first.
`IfNotPresent` SSA handling likewise requires an explicit claim lifecycle.

### CNPG

Use CNPG instance recreation and PostgreSQL streaming, not Kopiur copies of
PGDATA. Follow the installed operator's
[storage recreation procedure](https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.1/docs/src/storage.md#re-creating-storage).

1. Confirm a fresh Barman backup, healthy WAL archiving and two caught-up
   instances. Temporarily scale to three on Ceph and wait for the third to catch
   up on the remaining node; validate resources/PDBs before continuing.
2. Change desired storage to `miroir-local` with `WaitForFirstConsumer`, retaining
   required hostname anti-affinity. Follow the version's guidance on
   `resizeInUseVolumes` during storage recreation.
3. Recreate one **standby's** pod/PVC group at a time using the supported CNPG
   operation. Identify the current primary live before every operation. Wait for
   the replacement's streaming catch-up, local placement and cluster readiness
   before recreating the next standby. Retain the old PVs where feasible.
4. Switch primary deliberately to a caught-up local-storage standby. Expect
   connection retries/brief interruption. Then recreate the former primary on
   local storage and wait for it to catch up.
5. Confirm every remaining instance uses local storage on a distinct node,
   application databases and Pooler work, WAL archiving continues, and a fresh
   base backup completes. Restore the intended two-instance count and normal
   resize settings; verify which PVCs CNPG retains/removes on scale-down.

Keep the existing Cluster identity and Barman archive for this rolling migration;
it does not bootstrap a new database system. If recovery instead requires a new
Cluster, use the separate recovery procedure and archive safeguards. Never
reactivate an old primary PVC directly after a switchover as a rollback shortcut.

### Disposition of the current 34 PVCs

`Preserve` means the final stopped-writer Kopiur backup/restore workflow above.
Observability data loss is accepted; the Git-managed configuration remains.

| Namespace | PVC | Target | Method |
| --- | --- | --- | --- |
| ai-system | open-webui | replicated | Preserve |
| ai-system | sillytavern | replicated | Preserve |
| comms | matrix | replicated | Preserve |
| comms | thelounge | replicated | Preserve |
| database | postgres-1 | local | CNPG streaming recreation |
| database | postgres-2 | local | CNPG streaming recreation |
| forgejo-system | forgejo | replicated | Preserve; migrate after other GitOps dependencies are proven |
| game-system | gtnh | replicated | Preserve; stop server cleanly first |
| home-system | bambuddy | replicated | Preserve |
| image | cache-autotagger-0 | local | Recreate empty |
| image | iqdb | replicated | Preserve |
| media | autobrr | replicated | Preserve |
| media | bazarr | replicated | Preserve |
| media | cache-navidrome-0 | local | Recreate empty; keep navidrome's main PVC |
| media | jellyfin | replicated | Preserve |
| media | jellyseerr | replicated | Preserve |
| media | kavita | replicated | Preserve |
| media | maintainerr | replicated | Preserve |
| media | navidrome | replicated | Preserve |
| media | prowlarr | replicated | Preserve |
| media | qbittorrent | replicated | Preserve |
| media | qui | replicated | Preserve |
| media | radarr | replicated | Preserve |
| media | recyclarr | replicated | Preserve; suggested first preserved app |
| media | slskd | replicated | Preserve |
| media | sonarr | replicated | Preserve |
| observability | config-gatus-0 | replicated | Recreate empty |
| observability | grafana-pvc | replicated | Recreate empty |
| observability | vlsingle-victoria-metrics | replicated | Recreate empty |
| observability | vmalertmanager-victoria-metrics-db-vmalertmanager-victoria-metrics-0 | replicated | Recreate empty |
| observability | vmsingle-victoria-metrics | replicated | Recreate empty |
| personal | paperless | replicated | Preserve |
| security | pocket-id-operator | replicated | Preserve; verify SSO before Forgejo cutover |
| security | vaultwarden | replicated | Preserve |

For empty recreation, stop the owner, replace the claim/controller template and
restart on the target class. Do not add backup policies solely for this
migration. Keep monitoring available during disk conversions; reset observability
volumes individually near the end and confirm dashboards, targets, alerts and
log/metric ingestion recover after each change.

**Gate:** every active PVC is on miroir, all preserved data/app checks pass,
fresh backups succeed, and no generated PVC template still refers to Ceph.

## Phase 5 — retire Ceph, keeping its partition initially

1. Audit live and Git references: PVCs including Pending/transient backup claims,
   retained PVs, attachments, snapshots/contents, RBD images, StorageClasses,
   Helm/StatefulSet/operator templates, Flux dependencies, Kopiur staging,
   monitoring and both tuppr health checks. No active consumer may depend on
   Ceph. Verify every retained rollback source's final external backup.
2. Keep the stopped Ceph sources through a proposed seven-day observation period
   with successful scheduled backups, application use and one planned miroir
   maintenance cycle. This is a rollback observation period, not an automatic
   change to NAS retention. Do not reclaim disks simply because seven days passed.
3. Switch the default class and shared Kopiur defaults to miroir, retaining
   explicit `miroir-local` for CNPG/caches. Replace remaining Ceph dependencies
   and upgrade gates with miroir ones. Verify the deployed Git revision.
4. Deliberately release retained Ceph rollback volumes when the observation gate
   passes. Let Ceph CSI delete approved volumes/snapshots while Ceph is still
   available. Inspect finalizers instead of stripping them indiscriminately.
5. Perform the installed Rook version's ordered teardown: CephFS/pools and
   CephCluster while the operator/tools can still complete cleanup, then CSI
   and operator. Remove obsolete charts/CRDs only after their resources are gone.
   Keep only partition-scoped cleanup, or explicit manual cleanup: **never run
   whole-device Rook cleanup on a drive now containing miroir**. Inspect any
   cleanup job's actual device targets before allowing it to run.
6. Remove obsolete Ceph monitoring/silences/routes and document completion.
   Remove Rook from Git in controlled stages so Flux pruning follows this order.
   For now, leave `r-rook` reserved; this separates retirement from disk growth.

**Gate:** no active Ceph resources or block-device holders remain, miroir and
backups are healthy, and external backups are the recovery path for retired data.

## Phase 6 — reclaim the former Ceph partition

Optional separate maintenance phase; 640 GiB per-node miroir capacity is already
sufficient for the present workloads. Perform one node at a time.

1. Export the current GPT and LVM metadata privately; identify the exact
   `r-miroir` partition start and `r-rook` partition number. Confirm no remaining
   Ceph process opens that partition. Stop new backup/restore operations while
   changing the pool backing.
2. Drain/cordon the node and wait for clean miroir teardown as required by the
   installed versions. Preserve both other nodes and all local-volume contents.
3. Remove only that node's `RawVolumeConfig` for `rook`, then use the supported
   Talos operation to release/remove **only its trailing partition**. Removing
   the config alone does not prove the GPT entry was removed. Never wipe the
   whole NVMe or change miroir's start sector; check GPT again before continuing.
4. Set miroir's RawVolumeConfig to grow with its cap removed. Verify Talos extends
   the existing first partition in place. If a tool refuses the operation,
   investigate rather than recreating miroir's partition or LVM PV.
5. Extend the existing LVM PV and thin pool using commands reviewed against the
   actual VG/LV names and metadata layout. miroir does not automatically extend
   an existing thin pool just because its backing partition grew. Leave suitable
   VG/metadata headroom; do not create a replacement VG or pool.
6. Verify larger partition/PV/pool capacity, metadata health, unchanged volume
   identities and data, all DRBD replicas UpToDate, and local CNPG health. Resume
   and uncordon, then wait for full readiness before repeating on another node.

No application PVC needs expansion merely because the backing pool grew.

## Completion and execution records

Keep the implementation split into reviewable changes: prerequisites/scaffolding,
one-node layouts and membership, health gates, app batches, CNPG, default switch,
Ceph retirement, and optional pool growth. Avoid unrelated version updates.

Maintain a private execution ledger with each node's old/new OSD/device mapping,
partition checks, exact backup IDs, claim/PV identities, held reconciliation,
health evidence and rollback disposition. Do not publish credentials or recovery
bundles. Update this document with the final choices and completion status.

Completion requires local CNPG/caches, replicated app storage, working scheduled
NAS backups and restores, healthy planned node maintenance, Git/live agreement,
and no residual Ceph storage dependency. Observability history is intentionally
reset. The future implementation must refresh versions and state; this plan is
not evidence that the disk operations have already been tested on this cluster.

## References

- Artemis: [coexistence partition layout](https://github.com/Exikle/Artemis-Cluster/commit/ffdaaa27b03fe6918d44d59e7b40a8668f72afb0),
  [first app restore](https://github.com/Exikle/Artemis-Cluster/commit/7caf3c342df909472bd227617cfc3089885a77c0),
  [Ceph retirement](https://github.com/Exikle/Artemis-Cluster/commit/b9008ac55e3ad13e33a74a6c55dfff108f89c3c9).
- Artemis: [LVM scan incident](https://github.com/Exikle/Artemis-Cluster/commit/93cbd606850d524653696f74b475c08832298306),
  [ephemeral ports and CNPG migration](https://github.com/Exikle/Artemis-Cluster/commit/3753c1c46f6efea45416fc870bb9c33e56f9773a).
- miroir: [requirements](https://github.com/home-operations/miroir/blob/main/docs/src/content/docs/requirements.mdx),
  [quickstart and local backup staging](https://github.com/home-operations/miroir/blob/main/docs/src/content/docs/quickstart.mdx),
  [replication](https://github.com/home-operations/miroir/blob/main/docs/src/content/docs/replication.md),
  [maintenance](https://github.com/home-operations/miroir/blob/main/docs/src/content/docs/maintenance.md),
  [open DRBD teardown tracking](https://github.com/home-operations/miroir/issues/262).
- Rook: [OSD management](https://rook.io/docs/rook/latest/Storage-Configuration/Advanced/ceph-osd-mgmt/).
  Its drain-until-clean replacement instructions need adaptation to three hosts
  with three copies; use the explicit degraded-window gates above.
- Local history: [three-node Ceph migration](3-node-ceph.md),
  [Kopiur migration and snapshot identity](volsync-to-kopiur.md),
  [restored-volume corruption incident](../incidents/ext4-directory-checksum-corruption.md).
