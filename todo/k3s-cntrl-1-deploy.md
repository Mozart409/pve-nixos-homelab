# k3s-cntrl-1 — remaining work before deploy

Config landed directly on `main` (commits `fc7fef5` "feat(k3s): add
k3s-cntrl-1 control plane host" and `3f2ad21` "fix(iac): shrink k3s-cntrl-1
memory to 2GiB, host already oversubscribed"). This file is the plan, not a
record — nothing below has been done yet, and **the host cannot activate
until step 1 is complete** (it will still build/eval fine).

`services.k3s` (native NixOS module, `modules/k3s-control-plane.nix`), role
`server`, `clusterInit = true` — bootstraps its own embedded etcd datastore so
future `k3s-cntrl-2`/worker nodes can join it later to form an HA control
plane instead of k3s' default single-node SQLite backend.

## 1. agenix secret — BLOCKING, activation fails without this

`secrets/k3s-server-token.age` already exists (left over from an earlier,
abandoned k3s draft — `hostK3sServer1`/`hostK3sWorker1` were removed from
`secrets/secrets.nix` as part of the k3s-cntrl-1 work, since those were stale
host keys for hosts that were never actually built). It is currently
encrypted to **admin keys only** (`amadeus`, `amadeusAge`, `amadeusMacbook`),
which is enough for `k3s-cntrl-1` to build and eval, but `age.secrets` will
fail to decrypt at activation time with "no identity matched any of the
recipients" until the real host key is added — see the "Reprovisioned Host"
pitfall in `AGENTS.md`.

This is a **new host**, so its SSH host key must exist first — nixos-anywhere
generates a fresh one on install. So this step happens *after* step 3's
install, not before:

```bash
just get-host-key 192.168.2.186
```

Add the key to `secrets/secrets.nix` as `hostK3sCntrl1` in the `let` block,
add it to the `users` list (the recipient set for `tailscale-auth-key.age`,
which every host needs), and add it to `k3s-server-token.age`'s
`publicKeys` in the `keep-sorted` block:

```nix
"k3s-server-token.age".publicKeys = [amadeus amadeusAge amadeusMacbook hostK3sCntrl1];
```

Then re-key so the new host can actually read it:

```bash
just reencrypt   # agenix -r: re-encrypts every secret to current recipients
```

No manual external setup needed beyond this (unlike e.g. Woodpecker's Forgejo
OAuth app) — the token is just a shared cluster-join secret, already
generated.

## 2. DNS + Prometheus — already done

- `hosts/dns/configuration.nix`: A + PTR for `k3s-cntrl-1.homelab.local` /
  `.internal` at `192.168.2.186`.
- `hosts/otel/configuration.nix`: `k3s-cntrl-1-node` scrape job for node
  metrics on `:9100`.

Nothing to do here — both already landed on `main`.

## 3. Deploy sequence

This is a **new host with a static IP**, so per the "Hosts With Extra Disks /
a Static IP" pitfall in `AGENTS.md`, it needs the full nixos-anywhere path
directly — not `deploy-minimal` + colmena (minimal uses DHCP, and
`colmena-apply-host` targets the static IP from `hostAddrs`, which it
wouldn't be on yet).

```bash
# 1. Provision the VM. State is in the Postgres backend (tofu init needed
#    if this is a fresh checkout / .terraform was wiped).
cd iac && tofu init && cd ..
just iac-plan            # expect ONLY k3s_cntrl_1_vm to be created
just iac-apply

# 2. Install NixOS. DESTRUCTIVE: disko wipes the disk. Use the DHCP address
#    the fresh VM comes up on; it reboots onto 192.168.2.186.
ssh amadeus@<dhcp-ip> lsblk        # sanity-check disk targeting first
just deploy k3s-cntrl-1 <dhcp-ip>

# 3. Now do step 1 of this file (host key -> secrets.nix -> reencrypt).

# 4. Full gates, then the home-manager/nixvim layer + secrets.
just fmt
just colmena-build-host k3s-cntrl-1   # already verified clean before commit
just colmena-apply-host k3s-cntrl-1
```

`just nixos-check` evaluates every host (~16), which has previously been
OOM-killed on smaller boxes — `colmena-build-host` is the gate that actually
matters here (it exercises the home-manager/nixvim layer `colmena apply`
builds) and was already run clean during development.

## 4. Post-deploy verification

- [ ] `systemctl status k3s` — active, and `journalctl -u k3s -b` shows no
      repeated etcd/tokenFile errors
- [ ] `kubectl get nodes` (from the host itself, or via `KUBECONFIG` copied
      out of `/etc/rancher/k3s/k3s.yaml`) shows `k3s-cntrl-1` `Ready`
- [ ] `kubectl get pods -A` — coredns, local-path-provisioner, traefik,
      svclb all `Running` (the bundled k3s addons; none were disabled)
- [ ] `curl -k https://192.168.2.186:6443/healthz` → `ok`
- [ ] `up{job="k3s-cntrl-1-node"} == 1` in Prometheus (otel)
- [ ] `dig k3s-cntrl-1.homelab.local` / `.internal` resolve to `192.168.2.186`
      from another homelab host

## 5. Not done / deliberately deferred

- **No dashboard tile.** `hosts/containers/homelab-dashboard/default.nix`
  lists HTTP(S) health-check links; the k3s API on :6443 is mTLS, not a
  browsable web UI, so it doesn't fit that pattern the way e.g. Harbor or
  Grafana do. Revisit if/when something HTTP-facing runs *on* the cluster
  (an ingress-fronted app) rather than the control plane API itself.
- **Traefik/servicelb left at defaults** (not disabled). If a workload later
  needs the host's own Caddy + step-ca setup instead of k3s' bundled
  ingress, revisit `modules/k3s-control-plane.nix`.
- **Memory sizing (2 GiB, pinned `floating = dedicated`) is a starting
  point**, deliberately kept small because `pve-gigabyte` was already at
  ~80% host memory before this VM existed — see
  `todo/pve-gigabyte-memory-oversubscription.md`. Watch actual usage after a
  few days under real workload load before raising it.
- **No `k3s-cntrl-2` / worker nodes yet.** `clusterInit = true` only
  bootstraps a single-node HA-capable etcd; joining additional servers means
  a new host importing the same module with `role = "server"` and
  `serverAddr = "https://k3s-cntrl-1.homelab.local:6443"` (no `clusterInit`
  on joiners), or `role = "agent"` for a pure worker.
