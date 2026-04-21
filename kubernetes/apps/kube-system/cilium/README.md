# Cilium

## UniFi (FRR)

```shell
router bgp 64512
  bgp router-id 192.168.1.1 # UDM Pro's BGP router ID (its LAN IP)
  no bgp ebgp-requires-policy # Standard practice for eBGP

  neighbor k8s peer-group # Using a peer-group for organization
  neighbor k8s remote-as 64513 # ASN of the Cilium BGP (must match localASN in CiliumBGPClusterConfig)

  neighbor 192.168.1.100 peer-group k8s # control-lane
  neighbor 192.168.1.110 peer-group k8s # worker

  address-family ipv4 unicast
    neighbor k8s next-hop-self # Important: UDM advertises itself as the next hop
    neighbor k8s soft-reconfiguration inbound # Allows policy changes without session reset
  exit-address-family
exit
```

## Old (BIRD2)

```shell
log syslog all;
log stderr all;

router id 192.168.1.1;

protocol kernel {
    learn;             # Learn routes added by the OS manually
    persist;           # Keep routes active in Linux even if BIRD restarts
    graceful restart;  # Minimize flapping during reloads

    ipv4 {
        export all;    # Actually insert routes into the kernel routing table
        import none;
    };

    # Configure ECMP
    merge paths on;
}

protocol device {
    scan time 10;
}

protocol direct {
    ipv4;
    interface "br-lan.1";
}

protocol bgp k8s_cluster {
    local 192.168.1.1 as 64512;
    neighbor range 192.168.1.0/24 as 64513;

    passive;
    graceful restart;

    ipv4 {
        import all;
        export none;
    };
}
```
