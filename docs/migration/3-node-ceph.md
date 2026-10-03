# Retrospective: single-node → 3-node Rook-Ceph cluster

**Status:** completed 2026-07-04 (`new-cluster`, #97). The step-by-step plan
was removed after the cutover (`8ccee146`); this is the record of what actually
happened.

## What was done

A full destroy-and-restore, not an in-place node addition. The single-node
cluster ran democratic-csi `local-hostpath` (XFS) on `sakuya`'s Phison disk,
which was repurposed as a Ceph OSD, so there was no in-place path. All three
nodes were bootstrapped together as a fresh cluster and every volume was
restored from backups on the NAS.

| Node | IP | OS disk | Ceph OSD disk |
|---|---|---|---|
| sakuya | 192.168.90.100 | Micron MTFDKCD256TFK | Phison 1TB ESR01TBTCCZ-27J-2MS |
| remilia | 192.168.90.110 | SAMSUNG MZALQ256HAJD-000L1 | Crucial P310 1TB |
| flandre | 192.168.90.120 | SAMSUNG MZALQ256HAJD-000L1 | Crucial P310 1TB |

All three are control planes with scheduling enabled. Storage moved to
`ceph-block` (RBD, ext4, `size: 3`, `failureDomain: host`).

Sequence: final VolSync sync of every app and fresh CNPG base backups →
suspend Flux → merge → `just talos reset-node` on sakuya (`--graceful=false`,
a lone etcd member can't leave gracefully) → wipe the Phison partition table
(the label wipe leaves GPT entries and ceph-volume refuses partitioned disks)
→ `just bootstrap` on all three nodes from maintenance mode.

Data came back through the paths already wired into the manifests: VolSync
`restore-once` ReplicationDestinations for app PVCs, and CNPG
`bootstrap.recovery` from barman-cloud on Garage for Postgres.

## What held up

- **Postgres.** pg-matrix, pg-danbooru and pg-miniflux recovered with real data.
  The base backups had to be taken with `kubectl cnpg backup --method plugin
  --plugin-name barman-cloud.cloudnative-pg.io`; without `--method plugin` the
  command prints a Backup name but writes nothing.
- **Backups outside the cluster.** The kopia repository and Garage live on the
  NAS, so destroying the cluster never put the backups at risk.
- **3-node genesis.** Bootstrapping all three nodes at once avoided the
  single-OSD-host state where `min_size 2` pools hang PVCs.

## What went wrong

- **ext4 `Bad message` (EBADMSG) on restored volumes.** autobrr, jellyseerr,
  pinchflat, jellyfin, vaultwarden, kavita, forgejo, matrix-synapse media and
  the paper MC server. Repaired with offline `e2fsck -fD`. Root cause traced to
  kernel RBD device reuse after the short-lived VolSync cache PVC; see
  [the incident record](../incidents/ext4-directory-checksum-corruption.md).
- **Malformed SQLite in Forgejo and Kavita.** A separate problem: the final
  sync ran on `local-hostpath`, which can't take atomic snapshots, so VolSync
  file-copied live WAL-mode databases and captured them torn. Fixed by using an
  earlier pre-migration copy. It can't recur on Ceph, where backups start
  from an atomic RBD snapshot. Postgres was unaffected because barman takes
  database-aware backups.
- **Spegel stale advertisements.** A node advertised image layers it no longer
  had, and pulls failed with `not found` on varying digests
  (`element-admin` in the matrix release). Fixed by restarting the Spegel
  DaemonSet.
- **OIDC build-time deadlock on a cold cluster.** Apps that substitute
  pocket-id client credentials at kustomize build time can't build until the
  credentials Secret exists, but the client that mints it is in the same
  build. Unblocked by applying the `PocketIDOIDCClient` manifest by hand.
- **First Talos upgrade after migration (2026-07-09).** Single-instance CNPG
  PDBs blocked tuppr's node drain and left a node cordoned. Fixed with
  `enablePDB: false` on those clusters.

## Lessons for next time

- Suspend Flux *before* merging a storage-backend change; otherwise the live
  cluster prunes the old CSI under mounted PVCs.
- `talosctl bootstrap` must target only `endpoints[0]`; list the genesis node
  first in `talosconfig`.
- Never file-copy a live embedded database. Use an atomic snapshot, the
  database's own online backup, or stop the app first.
- Run one disposable restore through the full restore path before a mass
  restore, and keep kernel logs across reboots. Most of the ext4 forensics
  were lost because only container logs were shipped.

## What followed

- 2026-07-12: Postgres consolidated onto the shared CNPG `database/postgres`
  cluster; the per-app clusters have since been retired.
- 2026-07-15: VolSync cache moved from a Ceph PVC to `emptyDir`.
- 2026-07-22/23: VolSync replaced by kopiur; see
  [volsync-to-kopiur.md](volsync-to-kopiur.md).
