set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

kubernetes_dir := justfile_dir() + '/kubernetes'

[private]
default:
    just -l kube

# ------
# Kubernetes
# ------
[doc('Browse a PVC')]
browse-pvc ns claim:
    kubectl run -n {{ ns }} browse-pvc-{{ claim }} -it --rm --restart=Never \
        --image=mirror.gcr.io/alpine:latest \
        --overrides='{"spec":{"containers":[{"name":"browse-pvc-{{ claim }}","image":"mirror.gcr.io/alpine:latest","stdin":true,"tty":true,"command":["/bin/sh"],"workingDir":"/mnt","volumeMounts":[{"mountPath":"/mnt","name":"data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"{{ claim }}"}}]}}'

[doc('Open a shell on a node')]
[script]
node-shell node:
    trap 'kubectl delete pod -n default -l app.kubernetes.io/managed-by=kubectl-debug --field-selector spec.nodeName={{ node }} --ignore-not-found --wait=false' EXIT
    kubectl debug node/{{ node }} -n default -it --image="mirror.gcr.io/alpine:latest" --profile sysadmin

[doc('Prune pods in Failed, Pending, or Succeeded state')]
[script]
prune-pods:
    for phase in Failed Pending Succeeded; do
        kubectl delete pods -A --field-selector status.phase="$phase" --ignore-not-found=true
    done

# ------
# Flux
# ------
[doc('Apply local Flux Kustomization')]
apply-ks ns ks:
    just kube render-local-ks "{{ ns }}" "{{ ks }}" | kubectl apply --server-side --force-conflicts --field-manager=kustomize-controller -f /dev/stdin

[doc('Delete local Flux Kustomization')]
delete-ks ns ks:
    just kube render-local-ks "{{ ns }}" "{{ ks }}" | kubectl delete -f /dev/stdin

[doc('Sync single Flux HelmRelease')]
[script]
sync-hr ns name:
    ts=$(date +%s)
    kubectl -n "{{ ns }}" annotate --field-manager flux-client-side-apply --overwrite hr "{{ name }}" reconcile.fluxcd.io/requestedAt="$ts" reconcile.fluxcd.io/forceAt="$ts"

[doc('Sync single Flux Kustomizations')]
sync-ks ns name:
    kubectl -n "{{ ns }}" annotate --field-manager flux-client-side-apply --overwrite ks "{{ name }}" reconcile.fluxcd.io/requestedAt="$(date +%s)"

[doc('Sync all Flux HelmReleases')]
[script]
sync-all-hr:
    kubectl get hr --no-headers -A | while read -r ns name _; do
        just kube sync-hr "${ns}" "${name}"
    done

[doc('Sync all Flux GitRepositories')]
[script]
sync-all-git:
    kubectl get gitrepo --no-headers -A | while read -r ns name _; do
        kubectl -n "$ns" annotate --field-manager flux-client-side-apply --overwrite gitrepo "$name" reconcile.fluxcd.io/requestedAt="$(date +%s)"
    done

[doc('Sync all Flux Kustomizations')]
[script]
sync-all-ks:
    kubectl get ks --no-headers -A | while read -r ns name _; do
        just kube sync-ks "${ns}" "${name}"
    done

[doc('Sync all Flux OCIRepositories')]
[script]
sync-all-oci:
    kubectl get ocirepo --no-headers -A | while read -r ns name _; do
        kubectl -n "$ns" annotate --field-manager flux-client-side-apply --overwrite ocirepo "$name" reconcile.fluxcd.io/requestedAt="$(date +%s)"
    done

[private]
render-local-ks ns ks:
    flate build ks -n "{{ ns }}" --path "{{ kubernetes_dir }}/flux/cluster" "{{ ks }}" --allow-missing-secrets

# ------
# ESO
# ------
[doc('Sync single ExternalSecret')]
sync-es ns name:
    kubectl -n "{{ ns }}" annotate --field-manager flux-client-side-apply --overwrite es "{{ name }}" force-sync="$(date +%s)"

[doc('Sync all ExternalSecrets')]
[script]
sync-all-es:
    kubectl get es --no-headers -A | while read -r ns name _; do
        just kube sync-es "$ns" "$name"
    done

[doc('View a secret')]
view-secret ns secret:
    kubectl view-secret -n "{{ ns }}" "{{ secret }}"

# ------
# Kopiur
# ------
[arg('state', pattern='suspend|resume')]
[doc('Suspend or resume Kopiur')]
kopiur state:
    flux -n kopiur-system {{ state }} kustomization kopiur
    flux -n kopiur-system {{ state }} helmrelease kopiur
    kubectl -n kopiur-system scale deployment kopiur-controller --replicas {{ if state != "suspend" { "1" } else { "0" } }}

[doc('Trigger Kopiur Snapshotpolicy')]
snapshot ns name:
    kubectl kopiur -n "{{ ns }}" snapshot now --policy "{{ name }}"

[doc('Trigger all Kopiur Snapshotpolicies')]
[script]
snapshot-all:
    kubectl get snapshotpolicies --no-headers -A | while read -r ns name _; do
        just kube snapshot "$ns" "$name"
    done

# ------
# CNPG
# ------
[arg('state', pattern='suspend|resume')]
[doc('Suspend or resume CNPG clusters')]
[script]
cnpg state:
    kubectl get clusters --no-headers -A | while read -r ns name _; do
        kubectl -n "$ns" patch cluster "$name" --type merge \
            -p '{"spec":{"nodeMaintenanceWindow":{"inProgress":{{ if state == "suspend" { "true" } else { "false" } }},"reusePVC":true}}}'
    done

# ------
# HPA
# ------
[arg('state', pattern='suspend|resume')]
[doc('Suspend or resume nfs-scaler HPAs')]
[script]
nfs-scalers state:
    # HPAs have no pause annotation: freeze both directions via selectPolicy, and
    # opt the object out of Flux so drift correction doesn't revert it. Resume
    # restores the component's selectPolicy (kubernetes/components/nfs-scaler).
    kubectl get hpa -A -l app.kubernetes.io/part-of=nfs-scalers --no-headers | while read -r ns name _; do
        kubectl -n "$ns" patch hpa "$name" --type=merge -p '{{ if state == "suspend" { '{"metadata":{"annotations":{"kustomize.toolkit.fluxcd.io/reconcile":"disabled"}},"spec":{"behavior":{"scaleUp":{"selectPolicy":"Disabled"},"scaleDown":{"selectPolicy":"Disabled"}}}}' } else { '{"metadata":{"annotations":{"kustomize.toolkit.fluxcd.io/reconcile":null}},"spec":{"behavior":{"scaleUp":{"selectPolicy":"Max"},"scaleDown":{"selectPolicy":"Max"}}}}' } }}'
    done
