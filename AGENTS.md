# Agent Guidelines for pve-nixos-homelab

This repository contains the NixOS configurations and Infrastructure as Code (OpenTofu) for a Proxmox-based homelab. It currently manages the `database` and `otel` hosts using Nix Flakes, Colmena, and Disko.

## 1. Build, Lint, and Test Commands

The project uses `just` as a command runner. Always prefer `just` commands over raw `nix` or `colmena` commands when available.

### Core Commands
- **Check Configuration**: `just nixos-check`
  - Runs `nix flake check` to verify the validity of all configurations.
- **Format Code**: `just fmt`
  - Uses `alejandra` to format Nix files.
  - Ensure all Nix files are formatted before committing.

### Building
- **Build All Hosts**: `just nixos-build-all`
- **Build otel**: `just nixos-build-otel`
- **Colmena Build**: `just colmena-build` or `just colmena-build-host <host>`
  - Builds configurations using Colmena (useful for deployment checks).

### Testing & Verification
- **Dry Run**: `just nixos-test <host>`
  - Performs a dry-run build for a specific host.
  - Example: `just nixos-test ferron`
- **Colmena Diff**: `just colmena-diff` or `just colmena-diff-host <host>`
  - Shows what changes would be applied to the running systems.

- **Initial Install**: `just deploy-<host> <ip>`
  - Uses `nixos-anywhere` to install NixOS on a fresh machine.
  - Example: `just deploy-otel 192.168.2.134`
- **Update/Apply**: `just colmena-apply` or `just colmena-apply-host <host>`
  - Uses `colmena` to push updates to running hosts.

### Infrastructure as Code (OpenTofu)
The `iac/` directory contains OpenTofu configurations for provisioning Proxmox VMs.
- **Initialize**: `tofu init` (inside `iac/` directory)
- **Plan**: `tofu plan`
- **Apply**: `tofu apply`
- **Format**: `tofu fmt` (run via `nix develop -c tofu fmt` to ensure the tool is available)

## 2. Code Style & Conventions

### Nix / NixOS
- **Formatting**: Strict adherence to `alejandra`. Run `just fmt` to ensure compliance.
- **Structure**:
  - `flake.nix`: Entry point. Defines inputs, outputs, and host configurations.
  - `hosts/<hostname>/`: Contains host-specific configurations (`configuration.nix`).
  - `modules/`: Shared NixOS modules (if any).
- **Naming**:
  - Use `camelCase` for variable names and attributes.
  - Hostnames are lowercase (e.g., `ferron`, `caddy`).
- **Imports**:
  - Use relative paths for local imports (e.g., `./hardware-configuration.nix`).
  - Prefer importing modules from `inputs` where applicable.
- **Flake Inputs**:
  - `nixpkgs`: Follows `nixos-unstable`.
  - `disko`: Used for disk partitioning.
  - `colmena`: Used for deployment.

### OpenTofu (IaC)
- **Directory**: `iac/`
- **Formatting**: Use `tofu fmt` to maintain standard HCL formatting.
- **Naming**:
  - Resources: `snake_case` (e.g., `proxmox_virtual_environment_vm`).
  - Variables: Descriptive `snake_case` names (e.g., `proxmox_api_token`).
- **Providers**:
  - Uses `bpg/proxmox` provider.
- **Resources**:
  - `proxmox_virtual_environment_vm` for VMs.
  - `proxmox_virtual_environment_download_file` for downloading ISOs/images.
- **Best Practices**:
  - Use `variables` for sensitive data or reusable values.
  - Keep `main.tf` clean; split into `variables.tf` or `providers.tf` if it grows too large (currently unified in `main.tf`).

### General Development
- **Dev Environment**:
  - Use `nix develop` (or the automatic direnv integration if available) to enter the development shell.
  - The shell provides: `just`, `kics`, `tofu-ls`, `opentofu`, `rust-analyzer`, etc.
- **Secrets**:
  - **NEVER** commit secrets to the repository.
  - Use `terraform.tfvars` (ignored by git) for IaC secrets.
  - Use `sops-nix` or similar (if configured) for NixOS secrets (not currently seen, but standard practice).

## 3. Workflow for Agents

1.  **Exploration**:
    -   Read `flake.nix` to understand the current inputs and host definitions.
    -   Read `justfile` to understand available task runners.
    -   Check `hosts/` for existing host configurations.
    -   If `context7` or `grep` MCP servers are available, use them for documentation and code search.

2.  **Making Changes**:
    -   **NixOS**: Edit `hosts/<host>/configuration.nix` or associated files.
        -   Verify syntax with `just nixos-check`.
        -   Format with `just fmt`.
    -   **IaC**: Edit `iac/main.tf`.
        -   Verify with `tofu validate` (if inside `iac/`).

3.  **Verification**:
    -   Always run `just nixos-check` after modifying Nix files.
    -   If modifying `flake.nix`, ensure `nix flake check` passes.
    -   For extensive changes, try a dry-run build (`just nixos-test <host>`).

4.  **Formatting**:
    -   Always run `just fmt` before finishing a task involving Nix files.

## 4. Key Technologies
-   **NixOS**: Operating System.
-   **Flakes**: Project structure and dependency management.
-   **Colmena**: Deployment tool (push-based).
-   **NixOS-Anywhere**: Initial installation tool.
-   **Disko**: Declarative disk partitioning.
-   **OpenTofu**: Infrastructure provisioning (fork of Terraform).
-   **Proxmox**: Virtualization platform target.
