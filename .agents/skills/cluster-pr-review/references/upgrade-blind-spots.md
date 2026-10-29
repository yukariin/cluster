# Upgrade blind spots

## CRDs outside the render diff

A short Flate render diff does not establish that a chart upgrade is structurally
small. Compare the old/new chart `crds/` directories as well as rendered templates.
Look for removed properties, new required fields, defaults, enums, and tightened
validation. Search the repository for affected custom resources.

`kubernetes/flux/cluster/ks.yaml` currently supplies `crds: CreateReplace` defaults
for HelmRelease installs/upgrades. Check the effective configuration and dependency
ordering. `bootstrap/helmfile.d/00-crds.yaml` serves bootstrap; do not assume a
manual bootstrap run is required for a normal chart upgrade.

The September 2026 Dragonfly upgrade removed `spec.networkPolicyEnabled`.
Server-side apply rejected manifests still containing it even when kubectl's
client validation was relaxed. Coordinate schema and consumer changes; removing
a field early can also activate the old operator's default behavior.

## Chart version is not app version

Renovate release text has historically matched an app changelog heading to a
chart version number incorrectly. Establish both charts' actual appVersions and
rendered images before interpreting release notes. Check upstream heading dates
and compare both rendered resource names and contents.

The recorded barman example was chart `0.7.1 -> 0.8.0` but app
`0.14.0 -> 0.15.0`; release notes for app `0.8.0` described a different change.
Use this as a failure pattern, not a claim about current releases.

## Persistent state

Image rollback can be unsafe after a database or on-disk configuration migration.
Inspect migration behavior and backups for the affected application. A successful
render validates configuration shape, not application compatibility or recovery.
