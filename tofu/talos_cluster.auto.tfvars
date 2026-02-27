talos_cluster_config = {
  name = "talos"

  # Only use a VIP if the nodes share a layer 2 network
  # Ref: https://www.talos.dev/v1.9/talos-guides/network/vip/#requirements
  vip     = "192.168.1.99"
  gateway = "192.168.1.1"

  proxmox_cluster    = "homelab"

  cilium = {
    bootstrap_manifest_path = "talos/inline-manifests/cilium-install.yaml"
    values_file_path        = "talos/inline-manifests/cilium-values.yaml"
  }

  gateway_api_version = "v1.5.0" # renovate: github-releases=kubernetes-sigs/gateway-api
  extra_manifests     = []

  kubelet             = <<-EOT
    extraArgs:
      # Needed for Netbird agent https://kubernetes.io/docs/tasks/administer-cluster/sysctl-cluster/#enabling-unsafe-sysctls
      allowed-unsafe-sysctls: net.ipv4.conf.all.src_valid_mark
  EOT

  api_server          = <<-EOT
    extraArgs:
      oidc-issuer-url: https://authentik.mistelinn.org/application/o/kubectl/
      oidc-client-id: kubectl
      oidc-groups-claim: groups
      oidc-groups-prefix: "oidc:"
  EOT
}
