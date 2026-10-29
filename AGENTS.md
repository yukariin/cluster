# Project guidance

This is a live homelab GitOps repository. Read `README.md` for architecture and
`.justfile` / `*/mod.just` for operational recipes.

## Working agreement

- Review and diagnosis requests authorize inspection. Commit or push only when
  explicitly requested; pushes can deploy changes. Existing authorization in the
  conversation carries forward.
- Make lasting configuration changes in Git. Use live mutations when the task
  authorizes them, and account for Flux reconciliation and any resulting drift.
- Preserve unrelated working-tree changes. Keep edits scoped to the request.
- This repository is publicly mirrored. Keep credentials, private incident notes,
  corporate network details, and ISP information out of tracked files and output.

## Cluster access and deployment

- Non-interactive shells may miss mise's environment. From the repository root,
  explicitly set `KUBECONFIG="$PWD/kubeconfig"` for kubectl/Flux and
  `TALOSCONFIG="$PWD/talosconfig"` for Talos. Check the selected context and endpoint
  before diagnosing connectivity failures; do not print credential contents.
- Forgejo is the source of truth; Flux pulls its GitHub push mirror. For changes
  that have not deployed, compare Forgejo HEAD, mirror HEAD, and Flux's artifact
  revision before forcing reconciliations.
- Apps live under `kubernetes/apps/<namespace>/<app>`; distinguish Flux `ks.yaml`
  resources from Kustomize `kustomization.yaml` files. Reuse
  `kubernetes/components` and follow neighboring apps' conventions.
- Use `.mise.toml` for tool configuration and `just -l` to discover recipes. Read
  a recipe before running it: some apply, force reconciliation, or delete data.

## Task-specific guidance

- [PR review](.agents/skills/cluster-pr-review/SKILL.md): dependency and deployment
  reviews, including changes hidden from rendered diffs.
- [Validation](.agents/skills/cluster-validation/SKILL.md): local checks matching
  Forgejo CI and known tool limitations.
- [Recovery](.agents/skills/cluster-recovery/SKILL.md): CNPG, Kopiur, and SQLite
  recovery planning and verification.
- Private troubleshooting context, when installed, is in the local
  `cluster-troubleshooting` skill. Load only relevant references.

Treat incident findings as dated evidence. Verify current versions, manifests,
and live state before reusing a workaround. Keep canonical runbooks in `docs/`;
link to them rather than maintaining duplicate procedures.
