#!/usr/bin/env -S just --justfile

set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']

# bootstrap new cluster from scratch
mod bootstrap "bootstrap"
# manage talos cluster
mod talos "talos"
# manage kubernetes cluster
mod kube "kubernetes"

[private]
default:
    just -l

[doc('Verify all required tools are present')]
doctor:
    #!/usr/bin/env bash
    missing=()
    for tool in just kubectl flux talosctl helm helmfile kustomize minijinja-cli op gum flux-local yq jq curl; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        echo "All tools present"
    else
        echo "Missing: ${missing[*]}"
        echo "Hint: run 'mise install' for mise-managed tools; install op separately with 1Password CLI"
        exit 1
    fi

[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}

[private]
template file *args:
    minijinja-cli "{{ file }}" {{ args }} | op inject
