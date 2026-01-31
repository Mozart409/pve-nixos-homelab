terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.91.0"
    }
  }
}
# Set the variable value in *.tfvars file
variable "endpoint" {
  sensitive = false
}
variable "username" {
  sensitive = true
}

variable "password" {
  sensitive = true
}
provider "proxmox" {
  # Configuration options
  endpoint = var.endpoint
  username = var.username
  password = var.password
  ssh {
    agent = true
  }
}


# Debian 12 Cloud Image Download (raw format for ZFS compatibility)
resource "proxmox_virtual_environment_download_file" "debian_cloud_image" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = "pve-gigabyte"

  url = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.raw"

  file_name          = "debian-12-generic-amd64.img"
  overwrite          = false
  checksum           = "b5666c8d22e6422a641c08c897617f0b31c413d309711ad62203887501fb7d62eaf4763f54874ff00f7e32a5588fe532ec0b114a4a265aaa1c78e94b12d2e72e"
  checksum_algorithm = "sha512"
}


# PostgreSQL Database VM
resource "proxmox_virtual_environment_vm" "database_vm" {
  name        = "database"
  description = "Database - Debian base for NixOS installation via nixos-anywhere"
  tags        = ["terraform", "debian", "nixos-target", "database"]

  node_name = "pve-gigabyte"
  vm_id     = 4323

  bios = "seabios"

  keyboard_layout = "de"

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 4096
    floating  = 4096
  }

  disk {
    datastore_id = "zfs_pool"
    file_id      = proxmox_virtual_environment_download_file.debian_cloud_image.id
    interface    = "scsi0"
    size         = 64
  }

  network_device {
    bridge = "vmbr0"
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = "local-lvm"

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      username = "amadeus"
      keys     = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHv1USrKf6yIjg8dZolm37xGysGfj18ol1KUKqsVuQHa amadeus@wotan"]
    }
  }

  serial_device {}

  # Enable QEMU Guest Agent
  agent {
    enabled = true
    timeout = "60s"
  }

  started = true

  on_boot = false
}

# OpenTelemetry Collector VM
resource "proxmox_virtual_environment_vm" "otel_vm" {
  name        = "otel"
  description = "OpenTelemetry Collector - Debian base for NixOS installation via nixos-anywhere"
  tags        = ["terraform", "debian", "nixos-target", "monitoring"]

  node_name = "pve-gigabyte"
  vm_id     = 4325

  bios = "seabios"

  keyboard_layout = "de"

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 2048
    floating  = 2048
  }

  disk {
    datastore_id = "zfs_pool"
    file_id      = proxmox_virtual_environment_download_file.debian_cloud_image.id
    interface    = "scsi0"
    size         = 32
  }

  network_device {
    bridge = "vmbr0"
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = "local-lvm"

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      username = "amadeus"
      keys     = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHv1USrKf6yIjg8dZolm37xGysGfj18ol1KUKqsVuQHa amadeus@wotan"]
    }
  }

  serial_device {}

  # Enable QEMU Guest Agent
  agent {
    enabled = true
    timeout = "60s"
  }

  started = true

  on_boot = false
}

# DNS Server VM (Unbound)
resource "proxmox_virtual_environment_vm" "dns_vm" {
  name        = "dns"
  description = "DNS Server (Unbound) - Debian base for NixOS installation via nixos-anywhere"
  tags        = ["terraform", "debian", "nixos-target", "dns"]

  node_name = "pve-gigabyte"
  vm_id     = 4326

  bios = "seabios"

  keyboard_layout = "de"

  cpu {
    cores = 1
    type  = "host"
  }

  memory {
    dedicated = 1024
    floating  = 1024
  }

  disk {
    datastore_id = "zfs_pool"
    file_id      = proxmox_virtual_environment_download_file.debian_cloud_image.id
    interface    = "scsi0"
    size         = 16
  }

  network_device {
    bridge = "vmbr0"
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = "local-lvm"

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      username = "amadeus"
      keys     = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHv1USrKf6yIjg8dZolm37xGysGfj18ol1KUKqsVuQHa amadeus@wotan"]
    }
  }

  serial_device {}

  # Enable QEMU Guest Agent
  agent {
    enabled = true
    timeout = "60s"
  }

  started = true

  on_boot = false
}

# UniFi Network Controller VM
resource "proxmox_virtual_environment_vm" "unifi_vm" {
  name        = "unifi"
  description = "UniFi Network Controller - Debian base for NixOS installation via nixos-anywhere"
  tags        = ["terraform", "debian", "nixos-target", "unifi"]

  node_name = "pve-gigabyte"
  vm_id     = 4327

  bios = "seabios"

  keyboard_layout = "de"

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 2048
    floating  = 2048
  }

  disk {
    datastore_id = "zfs_pool"
    file_id      = proxmox_virtual_environment_download_file.debian_cloud_image.id
    interface    = "scsi0"
    size         = 32
  }

  network_device {
    bridge = "vmbr0"
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = "local-lvm"

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      username = "amadeus"
      keys     = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHv1USrKf6yIjg8dZolm37xGysGfj18ol1KUKqsVuQHa amadeus@wotan"]
    }
  }

  serial_device {}

  # Enable QEMU Guest Agent
  agent {
    enabled = true
    timeout = "60s"
  }

  started = true

  on_boot = false
}

output "vm_ipv4_addresses" {
  description = "Primary IPv4 addresses per VM"
  value = {
    database = proxmox_virtual_environment_vm.database_vm.ipv4_addresses
    otel     = proxmox_virtual_environment_vm.otel_vm.ipv4_addresses
    dns      = proxmox_virtual_environment_vm.dns_vm.ipv4_addresses
    unifi    = proxmox_virtual_environment_vm.unifi_vm.ipv4_addresses
  }
}
