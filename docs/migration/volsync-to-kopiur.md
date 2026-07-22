# Migrating backups from VolSync (kopia fork) to Kopiur

Cutover plan for `feature/kopiur`: replace the VolSync kopia fork
(`volsync-perfectra1n`) with [Kopiur](https://kopiur.home-operations.com/) as
the backup operator for all 23 apps using the `components/volsync` flux
component. The kopia repository on the NAS is **adopted in place** — no data is
copied, re-uploaded, or re-initialized, and all existing snapshot history stays
restorable.

This is a GitOps cutover: merging the branch *is* the migration. The steps
below order the reconciles so the window where neither operator owns backups
stays short, and verify snapshot-lineage continuity before trusting the result.

## Why this is safe (the invariants)

| | VolSync fork | Kopiur |
|---|---|---|
| kopia repo | `nas.internal:/mnt/data_pool/kopia` (NFS) | same, via `ClusterRepository/kopia-nas` |
| repo password | vault key `kopia` → per-app secrets | vault key `kopia` → `kopiur-nas-secret` |
| snapshot identity | `<app>@<namespace>:/data` | same — default username/hostname + `sourcePathOverride: /data` |
| schedule | `15 */8 * * *` per RS | `H */8 * * *` per SnapshotSchedule |
| retention | hourly 24, daily 7 | hourly 24, daily 7, weekly 4, latest 3 (GFS) |

Because the identity is pinned to exactly what the fork wrote, the next kopiur
snapshot **continues the same history** — retention sees old and new snapshots
as one series, and restores resolve fork-era snapshots. This is the
load-bearing invariant; step 5 verifies it before anything else is trusted.

The app PVCs themselves are never touched: `spec.dataSourceRef` is immutable
and the kopiur PVC manifest carries `kustomize.toolkit.fluxcd.io/ssa:
IfNotPresent`, so flux skips existing PVCs entirely. Only the backup CRs around
them change.

## Prerequisites

```sh
export KUBECONFIG=$(git rev-parse --show-toplevel)/kubeconfig
```

Optional but recommended — the `kubectl kopiur` plugin (used for verification;
everything has a raw-kubectl fallback):

```sh
kubectl krew index add kopiur https://github.com/home-operations/kopiur.git
kubectl krew install kopiur/kopiur
# or: brew install home-operations/tap/kopiur   (installs standalone `kopiur`)
```

## 1. Pre-flight (read-only, before merging)

Everything renders and only known failures remain:

```sh
flate test all
flate diff all --base main   # review the full change set one last time
```

No VolSync backup is in flight (the fork fires at :15 past 00/08/16 cluster
time — avoid merging right at those marks):

```sh
kubectl get replicationsource -A -o json \
  | jq -r '.items[] | select(any(.status.conditions[]?; .type=="Synchronizing" and .status=="True"))
           | "\(.metadata.namespace)/\(.metadata.name)"'
# expect: no output
```

Snapshot the current state for the post-cutover comparison:

```sh
kubectl get replicationsource -A --no-headers | awk '{print $1"/"$2}' | sort > /tmp/volsync-apps.txt
wc -l /tmp/volsync-apps.txt   # expect 23
```

## 2. Merge and let flux pick it up

```sh
git checkout main && git merge --ff-only feature/kopiur && git push
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization cluster-apps -n flux-system
```

`cluster-apps` creates the `kopiur-system` namespace and its Kustomizations.
App Kustomizations reconcile on the new revision too and will briefly fail
applying `SnapshotPolicy`/`Restore` CRs until the operator's CRDs and admission
webhook are up — that's expected and self-heals; step 4 speeds it up.

## 3. Bring up the operator, then the repository

Order matters: operator (CRDs + webhook) → ClusterRepository (adoption).

```sh
flux reconcile kustomization kopiur -n kopiur-system              # waits: HR + webhook Ready
flux reconcile kustomization kopiur-repository -n kopiur-system   # waits: ClusterRepository Ready
kubectl get clusterrepositories.kopiur.home-operations.com kopia-nas
```

The repository must go `Ready` **without initializing anything** (adoption in
place — the manifest has no `create` block, so a missing/unreachable repo fails
loudly instead of silently creating an empty one). Fork-era snapshots then
surface in the catalog as `origin: discovered`:

```sh
kubectl kopiur snapshots list --origin discovered -n media
# fallback: kubectl get snapshots.kopiur.home-operations.com -n media
```

## 4. Converge the apps

Each app Kustomization applies its SnapshotPolicy/SnapshotSchedule/Restore and
prunes its ReplicationSource/ReplicationDestination/`*-volsync` secret. Kick
any that failed while the operator was still coming up:

```sh
kubectl get kustomization -A -o json \
  | jq -r '.items[] | select(any(.status.conditions[]?; .type=="Ready" and .status=="False"))
           | "\(.metadata.namespace) \(.metadata.name)"' \
  | while read -r ns name; do flux reconcile kustomization "$name" -n "$ns"; done
```

Done when the fork objects are gone and every app has a policy:

```sh
kubectl get replicationsource,replicationdestination -A --no-headers | wc -l   # expect 0
kubectl get snapshotpolicies.kopiur.home-operations.com -A --no-headers | wc -l # expect 23 (+ diff vs /tmp/volsync-apps.txt)
```

## 5. Verify lineage continuity (do not skip)

The resolved identity must match what the fork wrote, for every app:

```sh
kubectl get snapshotpolicies.kopiur.home-operations.com -A -o json \
  | jq -r '.items[] | "\(.status.resolved.identity // "UNRESOLVED")  \(.metadata.namespace)/\(.metadata.name)"'
# every line: <app>@<namespace>:/data — anything else, STOP and fix before a snapshot runs
```

An identity mismatch is only cheap to fix **before** the first kopiur snapshot;
after one exists, the admission webhook requires an explicit
`kopiur.home-operations.com/allow-identity-change` annotation and the interim
lineage is orphaned.

Prove continuity end-to-end on one app — new snapshot, same series:

```sh
kubectl kopiur snapshot now --policy qbittorrent -n media --wait
kubectl kopiur snapshots list -n media
# the new snapshot and the discovered fork-era ones list under qbittorrent@media:/data
```

Overall health:

```sh
kubectl kopiur doctor
```

The remaining apps take their first snapshot on schedule (`H */8` — within 8
hours). Kopiur takes over kopia maintenance ownership on its first maintenance
run; the fork's `KopiaMaintenance` was removed in the same merge, so there is
nothing to fight it.

## Rollback

Cheap until the decommission step: the VolSync operator is still installed and
the PVCs were never modified.

```sh
git revert <migration-merge-commit> && git push
flux reconcile source git flux-system -n flux-system
```

Apps re-apply their RS/RD, which resume the same `<app>@<namespace>:/data`
lineage — kopiur snapshots taken in the interim are just extra entries in it.
Re-add the fork `KopiaMaintenance` and note it must re-take maintenance
ownership from kopiur on its next run.

## 6. Decommission VolSync (separate push, after a soak)

Wait until at least one full scheduled kopiur snapshot cycle has succeeded for
every app (`kubectl kopiur snapshots list -A --origin scheduled`, or check the
Grafana kopiur dashboard). Then:

1. Delete `kubernetes/apps/volsync-system/` and `kubernetes/components/volsync/`
   from git and push. Flux prunes the Kustomizations and helm-uninstalls the
   operator.
2. The namespace carries `prune: disabled`; remove it and the leftover CRDs by
   hand (helm uninstall never deletes CRDs):

   ```sh
   kubectl delete namespace volsync-system
   kubectl get crd -o name | grep volsync.backube | xargs kubectl delete
   ```

3. **Keep the vault `kopia` key** — it is the repository password kopiur uses.

## Behavior changes to remember afterwards

- **PVC capacity**: `KOPIUR_CAPACITY` bumps no longer auto-expand existing
  PVCs (the `ssa: IfNotPresent` label makes flux skip them). Expand manually:
  `kubectl patch pvc <app> -n <ns> --type merge -p '{"spec":{"resources":{"requests":{"storage":"<size>"}}}}'`.
- **Rebuilding a PVC**: a populator `Restore` pins its snapshot when first
  admitted, not at populate time. When deleting a PVC to have it re-provisioned
  from backup, delete the app's `Restore` CR too, so flux recreates it and it
  re-resolves to the *latest* snapshot:
  `kubectl delete restores.kopiur.home-operations.com <app>-restore -n <ns>`.
- **Deploy-or-restore is fail-open**: `onMissingSnapshot: Continue` means a new
  app (or a mistyped identity) provisions an **empty** volume instead of
  erroring. When a restore was expected, check
  `kubectl get restores.kopiur.home-operations.com <app>-restore -n <ns> -o yaml`
  for `reason: NoSnapshotContinue` before blaming the repo.
- **Browsing backups**: `kubectl kopiur ls|cat|download|browse` reads snapshot
  contents without a restore; the kopia web viewer now lives in `kopiur-system`.
