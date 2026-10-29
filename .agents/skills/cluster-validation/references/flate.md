# Flate validation

Workflow commands were checked against `.forgejo/workflows/flate.yaml` on
2026-10-29. The go-git workaround was last recorded on 2026-10-06 and has not been
retested since.

## Checks matching CI

From the repository root, after ensuring `main` represents the intended base:

```sh
export FLATE_PATH=./kubernetes/flux/cluster
flate test all --base main --allow-missing-secrets
flate diff all --allow-missing-secrets
```

Check `flate test --help` / `flate diff --help` for the installed version when
selecting revisions. Verify that the output includes the intended local changes;
a check of committed HEAD alone does not validate uncommitted edits.

Flate performs Helm values-schema validation that a plain Flux/Kustomize build
does not. A recorded app-template schema rejected
`env.X.valueFrom.secretKeyRef.optional` despite Kubernetes allowing that field.
Read the schema for the pinned chart; do not assume the old limitation persists.

`--allow-missing-secrets` matches CI but leaves runtime secret resolution
unverified. Review the relevant Secret/ExternalSecret/client references without
printing secret values. Render output can itself contain sensitive values; do not
dump it wholesale into conversation or public comments.

## Historical local Git compatibility issue

If Flate reports `core.repositoryformatversion does not support extension:
worktreeconfig`, go-git may not support the checkout's Git extension. Retry in a
disposable, independent `git clone --no-local` rather than altering the user's
repository configuration. A worktree of the original repo can retain the issue.

For uncommitted edits, copy only the task's intended changed files into the clone,
including additions and deletions, and compare its diff with the original. Do not
copy kubeconfig, talosconfig, `.secrets.env`, local agent settings, or private notes.
If the installed Flate requires committed revisions, honor the project's commit
authorization rule; use an already-authorized temporary commit in the disposable
clone or report this validation gap. Do not push the clone. Retain the command,
checked revisions, and pass/failure summary.

## Render limits

Flate success does not test migrations, app login flows, data access, or restored
volumes. CRDs shipped outside chart templates also require separate comparison
during upgrades; see the PR review skill's
[upgrade blind spots](../../cluster-pr-review/references/upgrade-blind-spots.md).
