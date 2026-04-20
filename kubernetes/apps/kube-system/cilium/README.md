# Cilium

## Old (BIRD2)

```conf
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
