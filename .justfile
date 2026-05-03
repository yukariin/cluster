#!/usr/bin/env -S just --justfile

set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']

mod bootstrap "bootstrap"
mod talos "talos"
mod kube "kubernetes"

[private]
default:
    just -l

[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}

[private]
template context file *args:
    envconsul -secret="homelab/{{ context }}" -once -no-prefix minijinja-cli --strict "{{ file }}" {{ args }}
