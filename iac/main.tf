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
  sensitive =false 
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


# NixOS VM Configuration
resource "proxmox_virtual_environment_file" "nixos_iso" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = "nixos"

  source_file {
    path = "latest-nixos-minimal-x86_64-linux.iso"
  }
}

resource "proxmox_virtual_environment_vm" "nixos_vm" {
  name        = "nixos-vm"
  description = "NixOS VM - Managed by Terraform"
  tags        = ["terraform", "nixos"]

  node_name = "nixos"
  vm_id     = 4322

  # Boot from ISO
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
    size         = 64
    interface    = "scsi0"
  }

  network_device {
    bridge = "vmbr0"
  }

  cdrom {
    enabled = true
    file_id = proxmox_virtual_environment_file.nixos_iso.id
  }

  operating_system {
    type = "l26"
  }

  initialization {
    user_account {
      username = "amadeus"
      keys     = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHv1USrKf6yIjg8dZolm37xGysGfj18ol1KUKqsVuQHa amadeus@wotan"]
    }
  }

  serial_device {}

  # Don't start on boot initially (manual installation required)
  on_boot = false
}

