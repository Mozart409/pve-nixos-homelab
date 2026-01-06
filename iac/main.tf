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
  checksum           = "dada9511e307fcdb9503f3bee6eef19286ff0868ce7fadfa9c7f6fbc126e0b18cc87b671cd10f57688059690ef68a6bb6de24c1c0c365ce64b551c3c029267a5"
  checksum_algorithm = "sha512"
}

resource "proxmox_virtual_environment_vm" "ferron_vm" {
  name        = "ferron"
  description = "Ferron - Debian base for NixOS installation via nixos-anywhere"
  tags        = ["terraform", "debian", "nixos-target"]

  node_name = "pve-gigabyte"
  vm_id     = 4322

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

  # Start VM after creation - it will boot Debian with SSH access
  started = true

  on_boot = false
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

  started = true

  on_boot = false
}

# Caddy Web Server VM
resource "proxmox_virtual_environment_vm" "caddy_vm" {
  name        = "caddy"
  description = "Caddy - Debian base for NixOS installation via nixos-anywhere"
  tags        = ["terraform", "debian", "nixos-target", "webserver"]

  node_name = "pve-gigabyte"
  vm_id     = 4324

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

  started = true

  on_boot = false
}

