talos_nodes = {
  "ctrl-00" = {
    host_node     = "pve"
    machine_type  = "controlplane"
    ip            = "192.168.1.100"
    mac_address   = "BC:24:11:2E:C8:00"
    vm_id         = 800
    cpu           = 4
    ram_dedicated = 1024 * 7
    update        = false
  }
  "work-00" = {
    host_node     = "pve"
    machine_type  = "worker"
    ip            = "192.168.1.110"
    mac_address   = "BC:24:11:2E:08:00"
    vm_id         = 810
    cpu           = 10
    ram_dedicated = 1024 * 24
    igpu          = true
    disk_size     = 40
    datastore = {
      size        = 50
    }
    update        = false
  }
}
