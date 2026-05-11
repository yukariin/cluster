#!/usr/bin/env -S just --justfile

set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']

mod bootstrap "bootstrap"
mod talos "talos"
mod kube "kubernetes"

[private]
default:
    just -l

[doc('Verify all required tools are present')]
doctor:
    #!/usr/bin/env bash
    missing=()
    for tool in just kubectl flux talosctl helm kustomize minijinja-cli gum flux-local envconsul; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        echo "All tools present"
    else
        echo "Missing: ${missing[*]}"
        echo "Hint: run 'mise install' for mise-managed tools (e.g. flux-local)"
        exit 1
    fi

[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}

[private]
template context file *args:
    envconsul -secret="homelab/{{ context }}" -once -no-prefix minijinja-cli --strict "{{ file }}" {{ args }}
