# CNPG recovery

A restore drill on 2026-08-04 took ~2 minutes for ~135 MB. That timing and the
timeline numbers below are historical measurements, not current recovery guarantees.

Read `kubernetes/apps/database/cloudnative-pg/cluster/cluster.yaml` and its
ObjectStore configuration first. As checked in Git on 2026-10-29, the production
cluster has two instances, uses the barman-cloud plugin, and its recovery
bootstrap has no fixed `recoveryTarget`.

The August drill failed when `targetTLI: "1"` selected a timeline with no retained
base backup. Omitting a recovery target restored through the available history
to the latest recoverable point. Select PITR/timeline settings from the requested
recovery objective and current catalog, not a remembered timeline number.

For an authorized scratch restore:

- Use a separate namespace and a separately named Cluster/ObjectStore. Inspect
  the archive source identity (`serverName`) and required credentials privately.
- Configure recovery from the real archive as a source; do not enable
  `spec.plugins` WAL archiving on the scratch cluster. Confirm current plugin
  semantics before applying so it cannot write into the production archive.
- A single-instance scratch cluster may need `enablePDB: false` to avoid blocking
  node drains. Check the current operator schema before using it.
- Verify timeline and promotion (`pg_is_in_recovery()`), database contents, and
  application timestamps against the intended restore point. Pod readiness alone
  does not prove that the required data was restored.

Database-native recovery and volume recovery are different workflows; do not
substitute a PVC restore for verified CNPG recovery.
