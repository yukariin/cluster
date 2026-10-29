---
name: cluster-validation
description: "Validate manifest, HelmRelease, Kustomize, YAML, and Forgejo workflow changes in the cluster homelab repository using its actual CI checks. Use before reporting infrastructure edits as validated or when diagnosing Flate CI failures."
---

# Cluster Validation

Work from the cluster repository root and follow [project guidance](../../../AGENTS.md).
Choose checks according to changed files; documentation-only edits need link and
diff review rather than a cluster render.

- For YAML, use `yamlfmt` on changed files and `yamllint --config-file .yamllint.yaml`
  on those files. Inspect formatter changes; avoid repository-wide rewrites.
- For HelmRelease or other Kubernetes changes, read
  [Flate validation](references/flate.md) and run the CI-equivalent render/schema
  checks. Plain `kustomize build` or Flux build is useful but does not replace
  Helm values-schema validation.
- For `.forgejo/workflows` changes, use actionlint with
  `.forgejo/actionlint.yaml` as configured in `.forgejo/workflows/lint.yaml`.
- For Just recipes, follow `.lefthook.toml` formatting and inspect `just --list` or
  recipe parsing without executing operational commands as a syntax check.

Read `.forgejo/workflows/flate.yaml`, `.forgejo/workflows/lint.yaml`, and
`.lefthook.toml` when their checks are relevant; these files are the maintained
source for CI behavior. Do not change Git configuration or disable schema
validation merely to obtain a passing result.

Review `git diff --check` and the final diff. State which revision and local edits
were checked, distinguish render checks from live behavior, and report missing
secrets or tool failures as validation gaps. Do not deploy changes to validate a
review-only task.
