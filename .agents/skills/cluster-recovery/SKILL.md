---
name: cluster-recovery
description: "Plan or perform explicitly requested CNPG, Kopiur/PVC, and SQLite backup/restore work in the cluster homelab repository. Use for restore drills, data migrations, and recovery diagnosis; ordinary application restarts do not require this skill."
---

# Cluster Recovery

Work from the cluster repository root and follow [project guidance](../../../AGENTS.md).
Establish the requested target, restore point, available backup, and whether the
task authorizes a drill, an isolated restore, or a production cutover.

- For CNPG, read [CNPG recovery](references/cnpg.md), then inspect the current
  Cluster, ObjectStore, plugin versions, and backup catalog.
- For Kopiur, PVC population, or SQLite consistency, read
  [volume recovery](references/volumes.md). Follow the canonical repository
  migration/incident documents linked there for detailed procedures.

Prefer an isolated target when the user asks to verify recoverability. A scratch
restore must not archive back into the production archive. Inspect generated
resources before applying them; establish secret handling and cleanup scope.
Planning authorization does not authorize deleting PVCs/Restore objects,
overwriting production data, changing retention, or switching traffic.

Before a requested cutover, make Flux/operator behavior and rollback constraints
explicit in the concrete plan. Carry out already-authorized actions without
asking for duplicate approval. Stop at any genuinely unapproved destructive step.

Verify the restored data and application, not only resource readiness: backup
identity and timestamp, data integrity/freshness, ownership, read/write behavior,
and application health as relevant. Report what was restored, where, which backup
was used, and remaining uncertainty. Retain failed targets for investigation
unless cleanup is authorized; clean only resources created for the requested drill.
