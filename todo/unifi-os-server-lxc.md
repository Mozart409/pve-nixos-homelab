# Migrate UniFi from the NixOS controller VM to UniFi OS Server LXC

Replace the deprecated NixOS-hosted UniFi Network Application on `unifi`
(`192.168.2.142`) with UniFi OS Server, installed by the Proxmox Community
Scripts `unifi-os-server` script in a Debian 13 LXC. UniFi OS Server is a
multi-service appliance stack; keep it in its supported Docker environment
rather than trying to model the whole stack as NixOS services.

The current `hosts/unifi/configuration.nix` runs the legacy Network Application
(`pkgs.unifi`). This migration is for the newer UniFi OS Server, not a
repackaging of that NixOS service.

## Status

**Not started — planning only.** Keep the current controller available until
the new server has imported its backup, devices are adopted, and monitoring and
access paths have been checked.

## Target and decisions

- Community Scripts currently lists Debian 13, 2 CPU, 4096 MB RAM, 20 GB disk,
  and UI port `11443` as its default profile. Check the live script/profile and
  available Proxmox resources at provisioning time; these are defaults, not a
  fixed sizing requirement.
- The project `lemker/unifi-os-server` runs UniFi OS Server in Docker. The
  Community Script creates the LXC and installs the stack. Docker-in-LXC needs
  the container configuration the script provides (including nesting/cgroup
  requirements); don't hand-build a more restrictive CT without validating it.
- The bpg Proxmox provider supports
  `proxmox_virtual_environment_container`. Decide whether to declare the CT in
  `iac/main.tf` and run the app installer inside it, or use the Community Script
  for CT creation as well. In either case, document the app installation/update
  path because the UniFi OS payload is managed inside the container.
- Prefer retaining `192.168.2.142` and `unifi.homelab.local` for the new
  controller if the existing VM is decommissioned. This keeps existing DNS
  consumers stable; coordinate the address handoff to avoid a collision.
- New UI port is `11443` (the current NixOS proxy targets `8443`). Device
  communication remains TCP `8080`, STUN remains UDP `3478`, and discovery is
  UDP `10003` for UniFi OS Server. Confirm required ports against the upstream
  documentation and only expose the features in use.
- NixOS host integrations do not carry over automatically: Tailscale, Caddy,
  node exporter, osquery, step-ca trust, and the current host firewall are all
  configured by `hosts/unifi/configuration.nix`.

## Phase 0 — Inventory and prepare

- [ ] Confirm the UniFi OS Server prerequisites and current Community Script
  behavior from its source before running it. Record CT ID, storage, network
  mode, CPU/RAM/disk, privilege mode, and required LXC features.
- [ ] Check Proxmox memory/storage headroom. The default profile is 4 GB RAM,
  compared with the existing VM's 2560 MB; see
  [`pve-gigabyte-memory-oversubscription.md`](./pve-gigabyte-memory-oversubscription.md).
- [ ] Take and verify a current backup of the existing UniFi Network
  Application, and record its version, site/device counts, current inform host,
  and any non-default settings.
- [ ] Decide how to retain the old controller as a rollback until the new
  controller and device adoption have been verified.
- [ ] Decide which host integrations are still needed on the LXC: Tailscale,
  node metrics, osquery, and a trusted HTTPS UI endpoint. Choose a monitoring
  approach if the Debian guest will not provide the existing NixOS exporters.

## Phase 1 — Provision and install

- [ ] Create the Debian 13 LXC on Proxmox using the Community Script, or declare
  the container in `iac/main.tf` and use the script's supported install path.
  Preserve a stable address/name for the controller where practical.
- [ ] Install UniFi OS Server and confirm its services survive an LXC restart.
- [ ] Configure the network/firewall path for the required UI, adoption,
  discovery, and STUN ports. Do not assume the old NixOS firewall list is a
  complete or correct list for the new server.
- [ ] Confirm the UI is reachable at `https://<host>:11443` from the intended
  LAN/tailnet clients. Decide whether to put Caddy on another NixOS host in
  front of it for `unifi.homelab.local` and step-ca TLS.

## Phase 2 — Restore and cut over

- [ ] Import/restore the UniFi Network Application backup into UniFi OS Server;
  confirm sites, settings, and device inventory before changing the old host.
- [ ] Point devices at the new controller. Keep the old controller available
  during adoption and confirm representative access points/switches reconnect
  and remain manageable.
- [ ] If reusing `192.168.2.142`, stop the old VM before assigning that address
  to the LXC. Verify there is no duplicate IP and that DNS resolves to the new
  guest.
- [ ] Verify the UI through the final hostname/reverse-proxy path, and confirm
  required adoption, STUN, and discovery traffic works from the device network.
- [ ] Verify backup/restore and the documented UniFi OS Server update procedure.

## Phase 3 — Remove obsolete NixOS host configuration

Only after the new server has been stable and rollback is no longer needed:

- [ ] Remove the `unifi` entries from `flake.nix` (`hostAddrs`,
  `nixosConfigurations`, and `colmenaHive`) and delete `hosts/unifi/`.
- [ ] Remove `unifi_vm` and its output from `iac/main.tf`, or replace the VM
  resource with the chosen LXC resource. Reconcile state before destroying the
  old VM; do not let Terraform/OpenTofu recreate or destroy the wrong guest.
- [ ] Remove the UniFi A/PTR records from `hosts/dns/configuration.nix` only if
  the new deployment uses different names/addresses. Otherwise retain/update
  them for the LXC.
- [ ] Remove or replace the `unifi-node` scrape job in
  `hosts/otel/configuration.nix` and the UniFi blackbox target in
  `hosts/otel/blackbox.nix`; verify uptime-forge continues checking the final
  UI endpoint in `hosts/containers/uptime-forge/forge.toml`.
- [ ] Remove the old `hostUnifi` SSH recipient from `secrets/secrets.nix` and
  run `just reencrypt` if it is no longer needed by any secret.
- [ ] Update the host inventory in `README.md`, the UniFi dashboard link in
  `hosts/containers/homelab-dashboard/default.nix`, and the host list in
  `hosts/hermes/souls/user.md` if their references still describe the retired
  NixOS VM.
- [ ] Run `just fmt` and the appropriate Nix/IaC validation after repository
  changes. Remove the old VM only after the migrated controller is confirmed
  healthy and recoverable.

## Verification

- UniFi OS Server UI works at the final URL with the expected TLS behavior.
- Existing sites and representative devices are present and online; devices
  remain manageable after a controller/LXC restart.
- Required ports work from the appropriate LAN segments, and unused ports are
  not exposed.
- Chosen monitoring and PBS backup paths cover the new LXC, and a restore path
  is documented.
- DNS, dashboard, and uptime checks target the new endpoint; no remaining
  monitoring reports the removed NixOS VM as down.
