terraform {
  backend "pg" {}

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
  # Proxmox's own web cert on :8006 is self-signed; true regardless of
  # whether endpoint is the LAN IP or the Tailscale MagicDNS name.
  insecure = true
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

# Fedora 44 Cloud Base (Generic) Image Download
resource "proxmox_virtual_environment_download_file" "fedora_cloud_image" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = "pve-gigabyte"

  url = "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2"

  file_name          = "fedora-44-generic-amd64.img"
  overwrite          = false
  checksum           = "28680fe5b371a5a82ebf43a31926e086a168e59949d03969c5093e7071f90b7f"
  checksum_algorithm = "sha256"
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
    dedicated = 1536
    floating  = 768
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

  on_boot = true
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
    dedicated = 1536
    floating  = 1024
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

  on_boot = true
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
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 1536
    floating  = 768
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

  on_boot = true
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
    cores = 4
    type  = "host"
  }

  memory {
    dedicated = 2560
    floating  = 1280
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

  on_boot = true
}
# Harbor Registry VM
resource "proxmox_virtual_environment_vm" "harbor_vm" {
  name        = "harbor"
  description = "Harbor Container Registry - Debian base for NixOS installation via nixos-anywhere"
  tags        = ["terraform", "debian", "nixos-target", "registry", "harbor"]

  node_name = "pve-gigabyte"
  vm_id     = 4339

  bios = "seabios"

  keyboard_layout = "de"

  cpu {
    cores = 2
    type  = "host"
  }

  # Ballooning shrank this VM to its 768 MiB floating floor under host memory
  # pressure (pve-gigabyte is oversubscribed), starving colmena activation:
  # load spiked to 21, systemd-logind's connection to systemd wedged, and every
  # deploy failed with "Unable to list users with logind" (exit 4). Locking
  # floating = dedicated keeps the guaranteed 2 GiB and prevents the wedge.
  memory {
    dedicated = 2048
    floating  = 2048
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
        address = "192.168.2.166/24"
        gateway = "192.168.2.1"
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

  on_boot = true
}

# Container VM
resource "proxmox_virtual_environment_vm" "containers_vm" {
  name        = "containers"
  description = "Containers"
  tags        = ["terraform", "debian", "nixos-target", "oci"]

  node_name = "pve-gigabyte"
  vm_id     = 4328

  bios = "seabios"

  keyboard_layout = "de"

  cpu {
    cores = 4
    type  = "host"
  }

  memory {
    dedicated = 3584
    floating  = 1792
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

  on_boot = true
}
# MCP VM
resource "proxmox_virtual_environment_vm" "mcp_vm" {
  name        = "mcp"
  description = "mcp vm"
  tags        = ["terraform", "debian", "nixos-target", "oci"]

  node_name = "pve-gigabyte"
  vm_id     = 4333

  bios = "seabios"

  keyboard_layout = "de"

  cpu {
    cores = 4
    type  = "host"
  }

  memory {
    dedicated = 1536
    floating  = 768
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

  on_boot = true
}

# Hermes Agent VM
resource "proxmox_virtual_environment_vm" "hermes_vm" {
  name        = "hermes"
  description = "Hermes AI Agent - NixOS with hermes-agent for homelab automation"
  tags        = ["terraform", "debian", "nixos-target", "ai", "hermes"]

  node_name = "pve-gigabyte"
  vm_id     = 4334

  bios = "seabios"

  keyboard_layout = "de"

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 2048
    floating  = 1024
  }

  disk {
    datastore_id = "zfs_pool"
    file_id      = proxmox_virtual_environment_download_file.debian_cloud_image.id
    interface    = "scsi0"
    size         = 256
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

  on_boot = true
}

# Fleet (osquery management) VM
resource "proxmox_virtual_environment_vm" "fleet_vm" {
  name        = "fleet"
  description = "Fleet osquery management server - Debian base for NixOS installation via nixos-anywhere"
  tags        = ["terraform", "debian", "nixos-target", "security", "fleet"]

  node_name = "pve-gigabyte"
  vm_id     = 4338

  bios = "seabios"

  keyboard_layout = "de"

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 3072
    floating  = 1536
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
        address = "192.168.2.164/24"
        gateway = "192.168.2.1"
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

  on_boot = true
}

# Certificate Authority (step-ca) VM
resource "proxmox_virtual_environment_vm" "ca_vm" {
  name        = "ca"
  description = "Certificate Authority (step-ca) - Debian base for NixOS installation via nixos-anywhere"
  tags        = ["terraform", "debian", "nixos-target", "security", "ca"]

  node_name = "pve-gigabyte"
  vm_id     = 4337

  bios = "seabios"

  keyboard_layout = "de"

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 768
    floating  = 384
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
        address = "192.168.2.160/24"
        gateway = "192.168.2.1"
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

  on_boot = true
}

# Forgejo VM (Git forge - uses external Postgres on database host)
resource "proxmox_virtual_environment_vm" "forgejo_vm" {
  name        = "forgejo"
  description = "Forgejo Git Forge - Debian base for NixOS installation via nixos-anywhere"
  tags        = ["terraform", "debian", "nixos-target", "forgejo", "git"]

  node_name = "pve-gigabyte"
  vm_id     = 4341

  bios = "seabios"

  keyboard_layout = "de"

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 1536
    floating  = 768
  }

  disk {
    datastore_id = "zfs_pool"
    file_id      = proxmox_virtual_environment_download_file.debian_cloud_image.id
    interface    = "scsi0"
    size         = 40
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

  agent {
    enabled = true
    timeout = "60s"
  }

  started = true

  on_boot = true
}

# Cache VM (Garage S3 + Attic Nix Binary Cache)
resource "proxmox_virtual_environment_vm" "cache_vm" {
  name        = "cache"
  description = "Garage S3 + Attic Nix Binary Cache - Debian base for NixOS installation via nixos-anywhere"
  tags        = ["terraform", "debian", "nixos-target", "cache", "s3", "nix"]

  node_name = "pve-gigabyte"
  vm_id     = 4340

  bios = "seabios"

  keyboard_layout = "de"

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 1024
    floating  = 512
  }

  disk {
    # Moved from zfs_pool to ssd_pool on 2026-08-19 (manual `qm move-disk`,
    # outside tofu) — the shared 2-HDD zfs_pool caps out around ~78 IOPS
    # cluster-wide and was the root cause of attic's earlier SQLite lock
    # contention (see hosts/cache/attic/default.nix). datastore_id here just
    # documents where the disk now lives; it does not itself trigger a move.
    datastore_id = "ssd_pool"
    file_id      = proxmox_virtual_environment_download_file.debian_cloud_image.id
    interface    = "scsi0"
    size         = 200
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
        address = "192.168.2.175/24"
        gateway = "192.168.2.1"
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

  on_boot = true
}

# Jellyfin Media Server VM
resource "proxmox_virtual_environment_vm" "jellyfin_vm" {
  name        = "jellyfin"
  description = "Jellyfin Media Server - Debian base for NixOS installation via nixos-anywhere"
  tags        = ["terraform", "debian", "nixos-target", "media", "jellyfin"]

  node_name = "pve-gigabyte"
  vm_id     = 4344

  bios = "seabios"

  keyboard_layout = "de"

  cpu {
    cores = 4
    type  = "host"
  }

  memory {
    dedicated = 4096
    floating  = 2048
  }

  # OS disk (scsi0 -> /dev/sda): btrfs root via disko-jellyfin.nix
  disk {
    datastore_id = "zfs_pool"
    file_id      = proxmox_virtual_environment_download_file.debian_cloud_image.id
    interface    = "scsi0"
    size         = 32
  }

  # Media storage disk (scsi1 -> /dev/sdb): ZFS "mediapool" via disko-jellyfin.nix
  disk {
    datastore_id = "zfs_pool"
    interface    = "scsi1"
    size         = 768
    file_format  = "raw"
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
        address = "192.168.2.180/24"
        gateway = "192.168.2.1"
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

  on_boot = true
}

# Agent Development VM
resource "proxmox_virtual_environment_vm" "development_vm" {
  name        = "development"
  description = "Agent Development - Debian base for NixOS installation via nixos-anywhere - experimental VM for LLM agent use"
  tags        = ["terraform", "debian", "nixos-target", "development", "experiment"]

  node_name = "pve-gigabyte"
  vm_id     = 4345

  bios = "seabios"

  keyboard_layout = "de"

  # Several agent sessions routinely realise a flake devShell at the same time.
  # Nix evaluation is single-threaded per eval, so concurrent cold devShells
  # queue on cores rather than sharing them: 4 parallel evals on 2 vCPU drove
  # load to 12.9. Sized for ~4-6 concurrent sessions with room for the agents.
  cpu {
    cores = 6
    type  = "host"
  }

  # Sized against the hand-built reference host running the same harness:
  # opencode peaked at 570 MB RSS with Claude Code not yet running, and /nix
  # alone consumed 21 GB. Claude Code (node) plus the bun-hosted opencode
  # plugins land here too, hence the headroom over that box's 2 GB.
  #
  # Raised from 4096 after concurrent devShell realisation pushed the working
  # set to ~6.7 GB and exhausted all 4 GB of swap. Swap here is the btrfs
  # swapfile from modules/disko-config.nix, backed by the 2-HDD zfs_pool, so
  # swapping costs ~78 IOPS shared with every other VM - this host must have
  # enough RAM to never reach for it. floating lets it balloon back down to
  # 4 GB when the sessions are idle.
  memory {
    dedicated = 12288
    floating  = 8192
  }

  disk {
    datastore_id = "zfs_pool"
    file_id      = proxmox_virtual_environment_download_file.debian_cloud_image.id
    interface    = "scsi0"
    size         = 256
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
        address = "192.168.2.184/24"
        gateway = "192.168.2.1"
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
  on_boot = true
}

resource "proxmox_virtual_environment_vm" "zeroclaw_vm" {
  name        = "zeroclaw"
  description = "ZeroClaw AI Agent - Debian base for NixOS installation via nixos-anywhere"
  tags        = ["terraform", "debian", "nixos-target", "zeroclaw", "ai"]

  node_name = "pve-gigabyte"
  vm_id     = 4346

  bios = "seabios"

  keyboard_layout = "de"

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 768
    floating  = 384
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
        address = "192.168.2.183/24"
        gateway = "192.168.2.1"
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

  started = false
  on_boot = false
}

# Woodpecker CI VM (Woodpecker server + agent, podman step containers)
resource "proxmox_virtual_environment_vm" "woodpecker_vm" {
  name        = "woodpecker"
  description = "Woodpecker CI server + agent - Debian base for NixOS installation via nixos-anywhere"
  tags        = ["terraform", "debian", "nixos-target", "woodpecker", "ci"]

  node_name = "pve-gigabyte"
  vm_id     = 4348

  bios = "seabios"

  keyboard_layout = "de"

  # CI is bursty and this VM exists so pipelines never contend with the git
  # forge. The agent now runs ONE workflow at a time (WOODPECKER_MAX_WORKFLOWS,
  # lowered so a nix eval gets the whole memory budget), so 4 cores gives that
  # single workflow its CPU quota with headroom left for the server, Caddy and
  # sshd, keeping the UI responsive mid-build.
  cpu {
    cores = 4
    type  = "host"
  }

  # 2 workflows x 1 GB step limit = 2 GB, plus ~700 MB for server/Caddy/system,
  # leaving real headroom rather than relying on swap.
  #
  # That arithmetic was still fiction, in a second way: a workflow is not one
  # container. internal-dashboard runs a `checks` step and a `postgres` service
  # side by side, each capped at LIMIT_MEM, so 2 workflows is 4 GB of containers
  # and not 2 -- already over this guest before the system takes its share. On
  # top of that 1 GB never fit the step itself: `nix develop` there pulls the
  # rust/llvm toolchain and then `cargo test --all-targets` links it, which is
  # comfortably a multi-GB peak. Every pipeline in that repo has been killed
  # mid-download since CI was introduced, with the server expiring the workflow
  # exactly as it did for #11-#25 above.
  #
  # 8192 sizes for one workflow with room to breathe: ~4 GB checks + 1 GB
  # postgres + ~700 MB system. It is deliberately not sized for two -- the agent
  # must drop to WOODPECKER_MAX_WORKFLOWS=1 and raise LIMIT_MEM to ~3-4 GB, both
  # of which live in the NixOS config for this host, not here. Raising this
  # without that change buys nothing, since the 1 GB cgroup cap is what OOMs.
  #
  # floating == dedicated PINS the memory: the balloon device stays present (so
  # the PVE UI still gets guest memory stats) but pvestatd has nothing to
  # reclaim. It used to be 1024, and that arithmetic above was fiction --
  # node_memory_MemTotal_bytes on this guest swung between 845 MB and 3917 MB
  # over 2026-08-05 as the balloon chased the host across its 80% reclaim
  # threshold. Under 1 GB the guest swapped, and its 4 GB of swap lived on
  # zfs_pool (two spinning disks, ~78 IOPS shared cluster-wide), so fsync
  # latency exploded, sqlite writers timed out, and the server dropped running
  # workflows as expired -- pipelines #11-#25 all died that way, reported as
  # "Canceled" with a green step log. See todo/woodpecker-postgres-and-sizing.md.
  #
  # The disk below moved to ssd_pool (2026-08-15), which drops the swap-latency
  # half of that finding -- ssd_pool is still ZFS (so the double-CoW reasoning
  # in disko-xfs.nix still holds), just not two spinning disks. Memory stays
  # pinned regardless: ballooning-induced instability was never only about
  # where swap lived, and the CI database is moving off this guest entirely
  # (todo/woodpecker-postgres-and-sizing.md), so there is no reason to relax
  # this and re-invite it.
  #
  # This VM is now a non-donor: the host is committed to ~53 GiB of guests plus
  # ZFS ARC on 62.6 GiB, so pressure that used to land here lands elsewhere
  # instead. That oversubscription is tracked in todo/pve-gigabyte-memory-oversubscription.md.
  memory {
    dedicated = 8192
    floating  = 8192
  }

  # Sized generously up front because growing it later is a manual guest-side
  # operation (growpart + xfs_growfs, and XFS grows but never shrinks), not
  # something `tofu apply` does. Pipeline step images accumulate fast; autoPrune
  # reaps them weekly.
  #
  # NEW VMs: copy this disk block. Every new host installs from `.#minimal`,
  # which now lays down XFS (modules/disko-xfs.nix), and that module enables a
  # weekly services.fstrim. `discard = "on"` is what makes those TRIMs reach ZFS
  # -- without it the guest frees blocks, the zvol never learns, and it stays
  # inflated on a pool that is only two spinning disks. The existing btrfs VMs
  # below predate this and are deliberately left alone: adding it there would
  # rewrite every VM resource for a benefit they are not currently claiming.
  # ssd_pool, not zfs_pool. Confirmed via `tofu plan` (2026-08-15): the bpg
  # provider updates datastore_id IN PLACE, not by replacing the resource --
  # no `# forces replacement` annotation, `0 to destroy`. It calls Proxmox's
  # online move-disk API, so this relocates the existing zvol's data to
  # ssd_pool rather than discarding it; the guest keeps its NixOS install and
  # SSH host key, no nixos-anywhere reinstall needed. (This guest's data was
  # disposable anyway -- CI history, nix store cache, podman layers, see
  # todo/woodpecker-postgres-and-sizing.md -- but turns out that never mattered.)
  disk {
    datastore_id = "ssd_pool"
    file_id      = proxmox_virtual_environment_download_file.debian_cloud_image.id
    interface    = "scsi0"
    size         = 100
    discard      = "on"
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
        address = "192.168.2.182/24"
        gateway = "192.168.2.1"
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

  on_boot = true
}

# Scratchpad VM (Fedora cloud image, ad-hoc testing)
resource "proxmox_virtual_environment_vm" "scratchpad_vm" {
  name        = "scratchpad"
  description = "Scratchpad - Fedora cloud VM for ad-hoc testing"
  tags        = ["terraform", "fedora", "scratchpad"]

  node_name = "pve-gigabyte"
  vm_id     = 4347

  bios = "seabios"

  keyboard_layout = "de"

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 2048
    floating  = 1024
  }

  disk {
    datastore_id = "zfs_pool"
    file_id      = proxmox_virtual_environment_download_file.fedora_cloud_image.id
    interface    = "scsi0"
    size         = 256
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
        address = "192.168.2.185/24"
        gateway = "192.168.2.1"
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

  on_boot = true
}

# K3s Control Plane VM (cluster-init, embedded etcd -- see
# modules/k3s-control-plane.nix)
resource "proxmox_virtual_environment_vm" "k3s_cntrl_1_vm" {
  name        = "k3s-cntrl-1"
  description = "K3s Control Plane - Debian base for NixOS installation via nixos-anywhere"
  tags        = ["terraform", "debian", "nixos-target", "kubernetes", "k3s"]

  node_name = "pve-gigabyte"
  vm_id     = 4349

  bios = "seabios"

  keyboard_layout = "de"

  cpu {
    cores = 4
    type  = "host"
  }

  # See the harbor_vm comment above: locking floating = dedicated avoids
  # ballooning starving the control plane (etcd/kube-apiserver) under host
  # memory pressure. Kept small (2 GiB, k3s' own recommended floor for a
  # single-node control plane) because pve-gigabyte is already oversubscribed
  # -- see todo/pve-gigabyte-memory-oversubscription.md. A pinned guest is a
  # balloon non-donor, so every MiB here is a MiB permanently unavailable to
  # the rest of the fleet; do not raise this without addressing that doc first.
  memory {
    dedicated = 2048
    floating  = 2048
  }

  disk {
    # etcd and the k3s API server are latency-sensitive; ssd_pool avoids the
    # ~78 IOPS zfs_pool HDD bottleneck shared by most other VMs.
    datastore_id = "ssd_pool"
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
        address = "192.168.2.186/24"
        gateway = "192.168.2.1"
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

  on_boot = true
}

# # K3s Server (Control Plane) VM
# resource "proxmox_virtual_environment_vm" "k3s_server_1_vm" {
#   name        = "k3s-server-1"
#   description = "K3s Server (Control Plane) - NixOS"
#   tags        = ["terraform", "debian", "nixos-target", "kubernetes", "k3s"]
#
#   node_name = "pve-gigabyte"
#   vm_id     = 4335
#
#   bios = "seabios"
#
#   keyboard_layout = "de"
#
#   cpu {
#     cores = 4
#     type  = "host"
#   }
#
#   memory {
#     dedicated = 4096
#     floating  = 4096
#   }
#
#   disk {
#     datastore_id = "zfs_pool"
#     file_id      = proxmox_virtual_environment_download_file.debian_cloud_image.id
#     interface    = "scsi0"
#     size         = 64
#   }
#
#   # Storage disk for Longhorn/Ceph
#   disk {
#     datastore_id = "zfs_pool"
#     interface    = "scsi1"
#     size         = 100
#     file_format  = "raw"
#   }
#
#   network_device {
#     bridge = "vmbr0"
#   }
#
#   operating_system {
#     type = "l26"
#   }
#
#   initialization {
#     datastore_id = "local-lvm"
#
#     ip_config {
#       ipv4 {
#         address = "dhcp"
#       }
#     }
#
#     user_account {
#       username = "amadeus"
#       keys     = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHv1USrKf6yIjg8dZolm37xGysGfj18ol1KUKqsVuQHa amadeus@wotan"]
#     }
#   }
#
#   serial_device {}
#
#   # Enable QEMU Guest Agent
#   agent {
#     enabled = true
#     timeout = "60s"
#   }
#
#   started = true
#
#   on_boot = true
# }
#
# # K3s Agent (Worker) VM
# resource "proxmox_virtual_environment_vm" "k3s_agent_1_vm" {
#   name        = "k3s-agent-1"
#   description = "K3s Agent (Worker Node) - NixOS"
#   tags        = ["terraform", "debian", "nixos-target", "kubernetes", "k3s"]
#
#   node_name = "pve-gigabyte"
#   vm_id     = 4336
#
#   bios = "seabios"
#
#   keyboard_layout = "de"
#
#   cpu {
#     cores = 4
#     type  = "host"
#   }
#
#   memory {
#     dedicated = 4096
#     floating  = 4096
#   }
#
#   disk {
#     datastore_id = "zfs_pool"
#     file_id      = proxmox_virtual_environment_download_file.debian_cloud_image.id
#     interface    = "scsi0"
#     size         = 64
#   }
#
#   # Storage disk for Longhorn/Ceph
#   disk {
#     datastore_id = "zfs_pool"
#     interface    = "scsi1"
#     size         = 100
#     file_format  = "raw"
#   }
#
#   network_device {
#     bridge = "vmbr0"
#   }
#
#   operating_system {
#     type = "l26"
#   }
#
#   initialization {
#     datastore_id = "local-lvm"
#
#     ip_config {
#       ipv4 {
#         address = "dhcp"
#       }
#     }
#
#     user_account {
#       username = "amadeus"
#       keys     = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHv1USrKf6yIjg8dZolm37xGysGfj18ol1KUKqsVuQHa amadeus@wotan"]
#     }
#   }
#
#   serial_device {}
#
#   # Enable QEMU Guest Agent
#   agent {
#     enabled = true
#     timeout = "60s"
#   }
#
#   started = true
#
#   on_boot = true
# }

output "vm_ipv4_addresses" {
  description = "Primary IPv4 addresses per VM"
  value = {
    database    = proxmox_virtual_environment_vm.database_vm.ipv4_addresses
    otel        = proxmox_virtual_environment_vm.otel_vm.ipv4_addresses
    dns         = proxmox_virtual_environment_vm.dns_vm.ipv4_addresses
    unifi       = proxmox_virtual_environment_vm.unifi_vm.ipv4_addresses
    container   = proxmox_virtual_environment_vm.containers_vm.ipv4_addresses
    mcp         = proxmox_virtual_environment_vm.mcp_vm.ipv4_addresses
    hermes      = proxmox_virtual_environment_vm.hermes_vm.ipv4_addresses
    ca          = proxmox_virtual_environment_vm.ca_vm.ipv4_addresses
    fleet       = proxmox_virtual_environment_vm.fleet_vm.ipv4_addresses
    harbor      = proxmox_virtual_environment_vm.harbor_vm.ipv4_addresses
    cache       = proxmox_virtual_environment_vm.cache_vm.ipv4_addresses
    forgejo     = proxmox_virtual_environment_vm.forgejo_vm.ipv4_addresses
    development = proxmox_virtual_environment_vm.development_vm.ipv4_addresses
    jellyfin    = proxmox_virtual_environment_vm.jellyfin_vm.ipv4_addresses
    zeroclaw    = proxmox_virtual_environment_vm.zeroclaw_vm.ipv4_addresses
    scratchpad  = proxmox_virtual_environment_vm.scratchpad_vm.ipv4_addresses
    woodpecker  = proxmox_virtual_environment_vm.woodpecker_vm.ipv4_addresses
    k3s_cntrl_1 = proxmox_virtual_environment_vm.k3s_cntrl_1_vm.ipv4_addresses
    # k3s_server_1 = proxmox_virtual_environment_vm.k3s_server_1_vm.ipv4_addresses
    # k3s_agent_1  = proxmox_virtual_environment_vm.k3s_agent_1_vm.ipv4_addresses
  }
}

