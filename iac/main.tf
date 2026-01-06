terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.91.0"
    }
  }
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
  bios = "ovmf"

  cpu {
    cores = 2
    type  = "x86-64-v3-AES"
  }

  memory {
    dedicated = 4096
    floating  = 4096
  }

  disk {
    datastore_id = "local-lvm"
    size         = 32
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

  # EFI disk for UEFI boot
  efi_disk {
    datastore_id = "local-lvm"
    type         = "4m"
  }

  serial_device {}

  # Don't start on boot initially (manual installation required)
  on_boot = false
}

