# pve-gigabyte: guest memory + ARC exceed the host

The hypervisor is committed to more memory than it has once ZFS ARC is counted.
Nothing is currently failing *because* of this — but the Woodpecker CI outage
(`todo/woodpecker-postgres-and-sizing.md`) was a symptom of it, and the fix for
that one made this one slightly worse by removing a balloon donor.

Split out of the Woodpecker todo on 2026-08-06 because it is not a CI problem
and will resurface on a different VM.

## The arithmetic

`free -m` on `pve-gigabyte`, 2026-08-06:

```
               total        used        free      shared  buff/cache   available
Mem:           64156       48540       12875         210        4227       15615
Swap:           8191           0        8191
```

Configured memory across **running** guests (`qm list`): **54272 MB = 53.0 GiB**
on a **62.6 GiB** host.

| VMID | name | MB | note |
|---|---|---|---|
| 4345 | development | 12288 | largest guest by 4 GB |
| 180 | backup-server | 8192 | PBS |
| 4344 | jellyfin | 4096 | |
| 4348 | woodpecker | 4096 | **pinned, no longer a balloon donor** |
| 4328 | containers | 3584 | |
| 4338 | fleet | 3072 | |
| 4327 | unifi | 2560 | |
| 208 / 4334 / 4347 | homeassistant, hermes, scratchpad | 2048 ea. | |
| 4323 / 4325 / 4333 / 4339 / 4341 | database, otel, mcp, harbor, forgejo | 1536 ea. | |
| 4340 | cache | 1024 | |
| 4326 / 4337 | dns, ca | 768 ea. | |
| 201 | xfce | 4098 | **stopped** |
| 4346 | zeroclaw | 768 | **stopped** |

Add ZFS ARC and it stops fitting:

```
53.0 GiB guests + 8 GiB ARC = 61.0 GiB on a 62.6 GiB host  (~97%)
```

The 8 GiB figure is the `zfs_arc_max` raised from 3 GiB on 2026-07-28 to help the
two-HDD `zfs_pool`. **Unverified** — confirm before acting on it:
`grep -E "^size|^c_max" /proc/spl/kstat/zfs/arcstats`. On PVE, ARC counts as
`used`, not `buff/cache`, so it competes with guests directly rather than being
reclaimable cache.

Starting both stopped VMs would take the commitment to 57.7 GiB + ARC = **65.7
GiB, past the host total.**

## Why it bites

`pvestatd` starts deflating balloon-enabled guests when host usage crosses ~80%.
At 48540/64156 the host sits at **75.7%** — just under, so it oscillates across
the line as `development` and the CI VM do real work. The result is not a clean
failure but a slow squeeze on whichever guest is most elastic, showing up as
unexplained swap and I/O latency inside that guest rather than as anything
visible on the host.

Timeline fits: ARC raised 2026-07-28, Woodpecker pipelines began dying
2026-08-05. That is suggestive, not proven — see the metrics gap below.

## The metrics gap that hid it

The `pve-node` Prometheus job was **down from 2026-08-05 ~14:00 CEST**, target
`pve-gigabyte.local:9100`, error `lookup pve-gigabyte.local: no such host` —
`.local` is mDNS-reserved and never reached unbound's local-data record. So
there is **no host memory history for the entire window** in which the CI
failures were diagnosed, and the guests' own `MemTotal` was the only evidence
available.

Fixed on 2026-08-06 (`hosts/dns/configuration.nix` A+PTR for
`pve-gigabyte.homelab.local`, `hosts/otel/configuration.nix:564` retargeted).
Needs a deploy of both `dns` and `otel` to take effect — **do this first**, since
every task below wants host memory history that does not exist yet.

## Tasks

- [ ] **Deploy dns + otel, confirm `up{job="pve-node"} == 1`.** Then let it run a
  few days: nothing else here should be decided on a single `free -m`.
- [ ] **Verify the ARC ceiling.** If it really is 8 GiB, decide consciously
  whether the two-HDD pool needs it more than the guests do. Do not lower it
  reflexively — it was raised for a reason and the pool is the cluster-wide
  bottleneck (~78 IOPS).
- [ ] **Right-size `development` (12288 MB).** Biggest single lever, 4 GB clear
  of the next guest. Check what it actually resides at before cutting.
- [ ] **Decide about the two stopped VMs.** `xfce` (4098) and `zeroclaw` (768)
  contribute nothing while stopped but are 4.8 GB of latent commitment. If they
  are dead, delete them; if they are not, they belong in the budget.
- [ ] **Consider a real memory budget in `iac/main.tf`.** Per-VM `memory` blocks
  are currently set independently, with no place where the total is visible
  against 62.6 GiB. That is why this went unnoticed.

## Verification

- `node_memory_MemAvailable_bytes{instance="pve-gigabyte"}` should stop
  approaching the 80% reclaim line under normal load.
- No guest's `node_memory_MemTotal_bytes` should drift downward over hours —
  that drift *is* the balloon reclaiming, and it is the signal that the host is
  short regardless of what the host's own numbers say.
- Guest `node_memory_SwapUsed_bytes` near zero across the fleet. Swap on
  `zfs_pool` is where a memory problem becomes an I/O problem.

## Related

- `todo/woodpecker-postgres-and-sizing.md` — the failure this was extracted from.
- `todo/ssd-tier-for-vm-storage.md` — an SSD tier would blunt the consequences
  (swap and fsync stop being catastrophic) without fixing the arithmetic.
