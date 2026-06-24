set lazy
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

talos_dir := justfile_dir() + '/talos'
controller := `talosctl config info -o yaml 2>/dev/null | yq -e '.endpoints[0]' 2>/dev/null || true`

[private]
default:
    just -l talos

[doc('Apply Talos config to a node')]
apply-node node *args:
    just talos render-config "{{ node }}" | talosctl -n "{{ node }}" apply-config -f /dev/stdin {{ args }}

[doc('Download Talos machine image')]
download-image version schematic:
    gum spin --title "Downloading Talos {{ version }} ..." -- \
    curl -sfL --remove-on-error --retry 5 --retry-delay 5 --retry-all-errors \
        -o "{{ talos_dir }}/talos-{{ version }}-{{ replace_regex(schematic, '^(.{8}).*', '$1') }}.iso" \
        "https://factory.talos.dev/image/{{ schematic }}/{{ version }}/metal-amd64-secureboot.iso"
    just log info "Downloaded Talos" version "{{ version }}" schematic "{{ schematic }}"

[doc('Generate schematic ID from Talos schematic')]
gen-schematic-id:
    curl -sX POST --data-binary @<(just template talos "{{ talos_dir }}/schematic.yaml.j2") "https://factory.talos.dev/schematics" | jq -r '.id'

[doc('Reboot a node')]
[script]
reboot-node node:
    if gum confirm "Reboot node {{ node }}?" --default="No"; then
        talosctl -n {{ node }} reboot -m powercycle
    fi

[doc('Render Talos config for a node')]
[script]
render-config node:
    IS_CONTROLLER="$(just talos machine-controller {{ node }})"
    export IS_CONTROLLER
    talosctl machineconfig patch <(just template talos "{{ talos_dir }}/machineconfig.yaml.j2") \
        -p @<(just template talos "{{ talos_dir }}/nodes/{{ node }}.yaml.j2")

[doc('Reset a node')]
[script]
reset-node node *args:
    if gum confirm "Reset node {{ node }}?" --default="No"; then
        talosctl -n "{{ node }}" reset --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL --system-labels-to-wipe u-local-hostpath --graceful=false {{ args }}
    fi

[doc('Shutdown a node')]
[script]
shutdown-node node *args:
    if gum confirm "Shutdown node {{ node }}?" --default="No"; then
        talosctl -n "{{ node }}" shutdown --force {{ args }}
    fi

[doc('Upgrade Kubernetes version on the cluster')]
upgrade-k8s version:
    talosctl -n "{{ controller }}" upgrade-k8s --to {{ version }}

[doc('Upgrade Talos version on a node')]
[script]
upgrade-node node *args:
    IS_CONTROLLER="$(just talos machine-controller {{ node }})"
    export IS_CONTROLLER
    talosctl -n "{{ node }}" upgrade -i "$(just talos machine-image)" -m powercycle --timeout=10m {{ args }}

[private]
machine-controller node:
    just template talos "{{ talos_dir }}/nodes/{{ node }}.yaml.j2" | yq -e 'select(.machine) | (.machine.type == "controlplane") // ""'

[private]
machine-image:
    just template talos "{{ talos_dir }}/machineconfig.yaml.j2" | yq -e 'select(.machine) | .machine.install.image'
