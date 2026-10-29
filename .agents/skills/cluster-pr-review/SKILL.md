---
name: cluster-pr-review
description: "Review PRs and pending dependency or infrastructure changes in the cluster homelab repository, especially Renovate chart/image bumps and merge-safety questions. Use for review, not routine incident diagnosis."
---

# Cluster PR Review

Work from the cluster repository root and follow [project guidance](../../../AGENTS.md).
Produce a merge assessment backed by the actual deployment changes.

1. Identify the PR head and current target revision. Read the PR body, diff, CI
   results, and render comment. For Forgejo access, digest inspection, and upstream
   source comparisons, use [review mechanics](references/review-mechanics.md).
2. Read the affected manifests and shared components. Trace chart version,
   appVersion, pinned image, environment, persistence, and auth paths that matter
   to this deployment. A chart bump can change the app even without an image edit.
3. Check upstream changes between the deployed and proposed versions. For charts
   carrying CRDs, inspect CRD schemas separately and find affected consumers.
   Read [upgrade blind spots](references/upgrade-blind-spots.md) when reviewing
   charts, operators, or database migrations.
4. Run relevant repository validation using
   [cluster validation](../cluster-validation/SKILL.md). Treat an old render comment
   as historical output; regenerate against the current target when necessary.
5. Report actionable findings with file locations, triggers, and consequences.
   State the reviewed revisions, checks completed, remaining uncertainty, and any
   irreversible migration or rollback limitation. If there are no findings, say
   so and identify material validation gaps.

Review authorization does not authorize merging, committing, pushing, reconciling,
or modifying live application data. Follow existing explicit authorization if the
user has requested those actions too.
