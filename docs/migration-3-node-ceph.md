# Migration: single-node → 3-node + democratic-csi → Rook-Ceph

Plan for cutting the single-node Talos cluster over to a 3-node cluster and
switching storage from democratic-csi (local-hostpath) to Rook-Ceph. Only
`sakuya` (192.168.90.100) is up; the two other nodes now have RAM installed and
are waiting on their OSD disks (2× Crucial P310 1TB).

## What this migration actually is

A **full destroy-and-restore**, not an in-place node addition. `sakuya`'s single
data disk (Phison) is being repurposed as a Ceph OSD, so there's no clean
in-place path. We reset the node, bootstrap a fresh 3-node cluster, and restore
all data from backups.

This is safe because backups and Garage (S3) live on the **NAS**, outside the
cluster, and the full-bootstrap path has been exercised before.

Restores are already wired:
- **volsync** — `components/volsync/pvc/pvc.yaml` creates each PVC with
  `dataSourceRef → ReplicationDestination ${APP}-dst` (`trigger: restore-once`),
  so every volsync app pulls its data back from the kopia repo on first boot.
- **CloudNativePG** — pgclusters run `bootstrap.recovery` from the `barman-cloud`
  object store (not `initdb`), so Postgres recovers from Garage.

## Nodes

| IP             | Hostname | Role         | OS disk                    | Ceph disk (data)                          |
|----------------|----------|--------------|----------------------------|-------------------------------------------|
| 192.168.90.100 | sakuya   | controlplane | Micron MTFDKCD256TFK       | Phison 1TB ESR01TBTCCZ-27J-2MS            |
| 192.168.90.110 | remilia  | controlplane | SAMSUNG MZALQ256HAJD-000L1 | Crucial P310 1TB (CT1000P310SSD8) — _verify on arrival_ |
| 192.168.90.120 | flandre  | controlplane | SAMSUNG MZALQ256HAJD-000L1 | Crucial P310 1TB (CT1000P310SSD8) — _verify on arrival_ |

All three are control planes; `allowSchedulingOnControlPlanes: true`.

---

## Phase 1 — Bring up the two new nodes (non-destructive)

1. **Rack both nodes**, install RAM + SSDs, PXE-boot them into **maintenance mode**.

2. **Verify the committed disk selectors against reality** (maintenance mode, `--insecure`):
   ```bash
   talosctl -n 192.168.90.110 --insecure get disks
   talosctl -n 192.168.90.110 --insecure get disks -o yaml   # model + serial + symlinks
   talosctl -n 192.168.90.120 --insecure get disks
   talosctl -n 192.168.90.120 --insecure get disks -o yaml
   ```
   The selectors are already committed, based on the ordered hardware — confirm
   before bootstrapping:
   - OS disk → node patches expect `model: SAMSUNG MZALQ256HAJD-000L1`
     (`talos/nodes/192.168.90.110.yaml.j2`, `talos/nodes/192.168.90.120.yaml.j2`).
   - Ceph disk → the cluster helmrelease expects the by-id symlink to match the
     regex `/dev/disk/by-id/nvme-CT1000P310SSD8_.*`. The `symlinks:` field in the
     `get disks -o yaml` output shows the actual `/dev/disk/by-id/*` paths even in
     maintenance mode — check it, and fix
     `kubernetes/apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml` if it differs.
     A wrong filter is non-destructive: it just yields zero OSDs on that node
     until fixed and reconciled.

3. **Add the nodes to `talosconfig`.** The bootstrap tasks derive their targets
   from this file — `bootstrap talos` applies to every entry in `nodes`, and
   `bootstrap kube` runs `talosctl bootstrap` against `endpoints[0]` only.
   These commands **replace** the lists (not append), so list all three, with
   the intended etcd-genesis node **first**:
   ```bash
   talosctl config endpoint 192.168.90.100 192.168.90.110 192.168.90.120
   talosctl config node     192.168.90.100 192.168.90.110 192.168.90.120
   ```
   > `endpoints[0]` = sakuya/.100 → the single node etcd is bootstrapped on.
   > Never bootstrap more than one node (split-brain); the task already only
   > touches `endpoints[0]`, so this ordering is all that matters.

---

## Phase 2 — Pre-flight (before touching sakuya)

Order matters here: **final backups → suspend Flux → merge → destroy**. Merging
while Flux still reconciles `main` on the live cluster would prune
democratic-csi under mounted PVCs, fail on immutable `storageClassName` changes
(PVCs, CNPG), and deploy ceph against the still-occupied Phison.

- [ ] Confirm Garage / NAS is reachable and healthy.
- [ ] **Force a final volsync sync of every app** — scheduled runs may be hours
      old. Trigger all ReplicationSources, then wait for completion:
      ```bash
      kubectl get replicationsources -A --no-headers | while read -r ns app _; do
        kubectl -n "$ns" patch replicationsource "$app" --type merge \
          -p '{"spec":{"trigger":{"manual":"pre-migration"}}}'
      done
      # done when every line shows pre-migration:
      kubectl get replicationsources -A \
        -o custom-columns='NS:.metadata.namespace,APP:.metadata.name,SYNCED:.status.lastManualSync'
      ```
- [ ] **Take a fresh CNPG base backup** for **all** pgclusters
      (matrix, danbooru, miniflux) and confirm each completes — a missing base
      backup = empty DB on recovery. These clusters back up via the
      **barman-cloud plugin** (`spec.plugins`), not the legacy in-tree
      `spec.backup.barmanObjectStore`, so `kubectl cnpg backup` must be told to
      use `--method plugin` — otherwise it defaults to `barmanObjectStore` and
      fails with `cannot proceed with the backup as the cluster has no backup
      section` (it still prints a Backup name, but writes no data):
      ```bash
      kubectl cnpg backup pg-matrix   -n comms --method plugin --plugin-name barman-cloud.cloudnative-pg.io
      kubectl cnpg backup pg-danbooru -n image --method plugin --plugin-name barman-cloud.cloudnative-pg.io
      kubectl cnpg backup pg-miniflux -n rss   --method plugin --plugin-name barman-cloud.cloudnative-pg.io
      ```
      Confirm each reaches `PHASE: completed` (not just that a name was printed):
      ```bash
      kubectl get backup -A
      ```
- [ ] `ClusterSecretStore` backing store reachable and its bootstrap secret
      present (volsync RDs and CNPG recovery both fetch creds via external-secrets;
      on a cold cluster these must resolve or restores block).
- [ ] **Suspend Flux**, then merge the branch:
      ```bash
      flux suspend source git flux-system
      ```
      From this point the old cluster is frozen; nothing reconciles the merge.
      Do **not** resume Flux on the old cluster, and do not reconcile ceph
      against a lone sakuya anyway (pools are `size: 3`, `min_size 2`; a single
      OSD host = PVCs hang pending). A 3-node genesis avoids this naturally.

---

## Phase 3 — Cutover (destructive)

1. **Reset sakuya**:
   ```bash
   just talos reset-node 192.168.90.100
   ```
   The task passes `--graceful=false` — required, not a shortcut: a lone etcd
   member can't leave its own cluster gracefully. It also passes
   `--system-labels-to-wipe u-local-hostpath`, wiping the old data volume.
   Note: `wipe: true` in the node `.j2` only wipes the **Micron install disk**,
   not the Phison.

2. **Wipe the Phison** (unconditional). The label wipe erases the filesystem
   signature but leaves the GPT partition entry, and ceph-volume refuses disks
   with partitions. With sakuya back in maintenance mode:
   ```bash
   talosctl -n 192.168.90.100 --insecure get disks            # find the Phison dev name
   talosctl -n 192.168.90.100 --insecure wipe disk <dev>      # e.g. nvme0n1
   talosctl -n 192.168.90.100 --insecure get disks -o yaml    # verify: no partitions/fs
   ```
   While at it, confirm the Phison's `symlinks:` still match the committed
   `devicePathFilter` regex (`nvme-Phison_1TB_ESR01TBTCCZ-27J-2MS_.*`).

3. **All three nodes now in maintenance mode.** Run the full bootstrap:
   ```bash
   just bootstrap
   ```
   Stages: apply Talos config to all three (`--insecure`) → `talosctl bootstrap`
   on `.100` → fetch kubeconfig → wait for nodes → namespaces → resources → CRDs
   → helmfile apps → Flux takes over.

---

## Phase 4 — Verify

- [ ] `talosctl health` / all three nodes `Ready`.
- [ ] Ceph reaches `HEALTH_OK` and pools are `active+clean` (needs all 3 OSDs).
      Flux and tuppr both tolerate `HEALTH_WARN`, so watch the actual toolbox
      status: `kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status`
- [ ] `ceph-block` is the sole default StorageClass; `csi-ceph-blockpool`
      VolumeSnapshotClass exists (name must match volsync's default — was a typo,
      now fixed).
- [ ] volsync `restore-once` completed per app; spot-check real data in a few.
- [ ] Each Postgres DB (matrix, danbooru, miniflux) recovered with real data,
      not empty.
- [ ] Flux fully reconciled: `flux get ks -A` / `flux get hr -A` all Ready.

---

## Notes / gotchas

- **Ceph won't serve I/O until ≥2 OSD hosts** (`min_size 2`), and won't be
  `active+clean` until 3 (`size: 3`, `failureDomain: host`). Bootstrapping all
  three at once sidesteps this.
- **Refine the ceph `devicePathFilter` after first boot** if the `by-id` guess
  from model+serial doesn't match; re-apply and the `rook-ceph-cluster` HR
  reconcile picks it up.
- **TPM disk encryption** (`systemDiskEncryption`, slot 0) seals per-node — disks
  aren't portable between machines. Not a concern for a fresh bootstrap.
- **spegel** is now enabled and relies on the containerd
  `discard_unpacked_layers = false` drop-in already present in
  `talos/machineconfig.yaml.j2`.
