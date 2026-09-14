# Jellyfin: prune stale devices / access tokens on a schedule

Every login — and with SSO, every Pocket ID round-trip — leaves a row under
Dashboard → Devices holding a **never-expiring access token**. Nothing removes
them. After the 10.11.11 → 12.0 upgrade (2026-09-14, `4420e32`) the question
was whether a plugin exists to clean these up. Research below; short answer is
no, and the fitting fix for this repo is a small declarative timer, not a
plugin.

**Status — researched 2026-09-14, not started.** Parked by choice ("not
today"); everything needed to build it is recorded here.

## Terminology (this matters for the design)

- **Sessions** (`GET /Sessions`) are in-memory. They vanish on every restart —
  the 12.0 upgrade wiped all of them. Nothing to clean.
- **Devices** (`GET /Devices`) are persisted, one per login, each with its own
  token. This is what accumulates and what a cleanup must target. Deleting a
  device revokes its token, i.e. logs that client out.

## Research: no plugin for 12

- **Official plugin repo** (`https://repo.jellyfin.org/files/plugin/manifest.json`):
  nothing matching session/device/cleanup/prune/inactive.
- **Jellyfin 12.0 itself**: no built-in auto-cleanup. The only related change
  is `Have device deletion take list of ids` (PR #12834) — the API now deletes
  several devices in one call.
- **`elvisfalmeida/JellySessionGuard`** (only GitHub hit): single commit
  2026-07-25, 0 stars, `targetAbi 10.11.0.0`, .NET 9. Will not load on 12
  (plugins must be rebuilt on .NET 10 against 12.0.0.0 — see
  `hosts/jellyfin/sso-plugin.nix` for the same lockstep rule). Not a candidate
  even if it did: a one-commit dependency whose ABI we'd have to chase on
  every Jellyfin bump, for ~40 lines of curl+jq.
- **SSO plugin (K0lin 5.1.1)**: no session/device management features.

## The API (verified against the live 12.0 OpenAPI spec on the host)

Read the spec any time: `curl -s http://localhost:8096/api-docs/openapi.json`
(pipe to a file first — zsh's `echo` mangles the JSON's backslashes).

| Call | Notes |
| --- | --- |
| `GET /Devices` | `Items[]` with `Id`, `Name`, `AppName`, `AppVersion`, `LastUserName`, `LastUserId`, `DateLastActivity`, `AccessToken`, `CustomName`. Optional `?userId=`. |
| `GET /Sessions?activeWithinSeconds=N` | live sessions; each has `DeviceId`. Use it to never delete a device that is streaming right now, whatever its `DateLastActivity` says. |
| `DELETE /Devices?id=A&id=B` | `id` is an **array** (repeat the param). Policy `RequiresElevation` → needs an admin API key. |
| Auth | header `Authorization: MediaBrowser Token="<api-key>"`. 12.0 **disabled legacy auth**: `X-Emby-Authorization` and `api_key=` are ignored (only `ApiKey=` casing survives as a query param). Use the header. |

## Plan: `hosts/jellyfin/device-cleanup.nix`

A oneshot + daily timer on the jellyfin host, loopback only, secret via agenix.
Same shape as the other repo timers (`modules/nix-gc.nix`,
`hosts/hermes/...hermes-repo-sync`).

1. **API key** — Dashboard → API Keys → new key named `device-cleanup`. This
   is Jellyfin mutable state (like the SSO plugin config): it must be recreated
   after a reprovision. Store it as `secrets/jellyfin-api-key.age`, recipients
   = the jellyfin host key + `users` (see `secrets/secrets.nix`; run `agenix`
   from inside `secrets/`). Consumed via `age.secrets.jellyfin-api-key.owner =
   "jellyfin"` so the unit can run as the `jellyfin` user.
2. **Script** (`curl` + `jq` + `coreutils`), roughly:

   ```sh
   api() { curl -fsS -H "Authorization: MediaBrowser Token=\"$(cat "$CREDENTIALS_DIRECTORY/api-key")\"" "$@"; }
   base=http://localhost:8096
   cutoff=$(date -u -d "-${MAX_AGE_DAYS:-30} days" +%Y-%m-%dT%H:%M:%SZ)

   # devices with a live session are never candidates, regardless of age
   live=$(api "$base/Sessions?activeWithinSeconds=900" | jq -r '.[].DeviceId')

   stale=$(api "$base/Devices" \
     | jq -r --arg cutoff "$cutoff" --argjson live "$(printf '%s\n' "$live" | jq -R . | jq -s .)" '
         .Items[]
         | select(.DateLastActivity < $cutoff)
         | select(.Id as $id | $live | index($id) | not)
         | [.Id, .AppName, .LastUserName, .DateLastActivity] | @tsv')

   [ -z "$stale" ] && { echo "nothing older than $cutoff"; exit 0; }

   # one journal line per device so it lands in Loki via services.loki-logs
   printf '%s\n' "$stale" | while IFS=$'\t' read -r id app user last; do
     echo "pruning device $id ($app, last user $user, last activity $last)"
   done

   if [ "${DRY_RUN:-0}" = 1 ]; then echo "dry run, not deleting"; exit 0; fi
   query=$(printf '%s\n' "$stale" | cut -f1 | sed 's/^/id=/' | paste -sd'&')
   api -X DELETE "$base/Devices?$query"
   ```

3. **Unit**:
   - `systemd.services.jellyfin-device-cleanup`: `Type=oneshot`,
     `User=jellyfin`, `LoadCredential=api-key:${config.age.secrets.jellyfin-api-key.path}`,
     `Environment=MAX_AGE_DAYS=30`, `after`/`requires` `jellyfin.service`,
     plus the usual hardening (`ProtectSystem=strict`, `PrivateTmp`,
     `NoNewPrivileges`, `IPAddressAllow=localhost`).
   - `systemd.timers.jellyfin-device-cleanup`: `OnCalendar=daily`,
     `RandomizedDelaySec=1h`, `Persistent=true`.
   - Add `jellyfin-device-cleanup.service` to `services.loki-logs.units` in
     `hosts/jellyfin/configuration.nix` so the prune lines are queryable.
   - Import from `hosts/jellyfin/configuration.nix` next to `./sso-plugin.nix`.

4. **First run in dry-run**: `sudo systemctl set-environment DRY_RUN=1` is not
   how NixOS units work — instead ship `DRY_RUN` as a module option defaulting
   to `true` for the first deploy, check the journal, flip it to `false`.

## Decisions still open

- **Threshold.** 30 days is the placeholder. The phone / TV apps re-auth
  silently on their next use so a too-short threshold just costs a re-login;
  a too-long one defeats the point. Pick by looking at the current device
  list's `DateLastActivity` spread first (`GET /Devices` with the new key).
- **Exempt list?** `AppName`/`CustomName` match for things that should never
  be logged out (e.g. a TV that is rarely used but painful to re-pair).
  Probably unnecessary; add only if the first real run bites.
- **`jellyfin-mpv-shim` on wotan** (per the same-day discussion): it logs in
  with username/password and shows up as its own device. It will be pruned
  like anything else if idle past the threshold — fine, it re-logs-in.

## Verify (after deploy)

- `systemctl list-timers jellyfin-device-cleanup` — next run scheduled.
- `sudo systemctl start jellyfin-device-cleanup` in dry-run → journal lists
  candidates, deletes nothing, Dashboard → Devices unchanged.
- Flip dry-run off, run once → candidates gone from Dashboard → Devices; the
  browser session you are using is **not** among them (it is in `/Sessions`).
- Loki: `{unit="jellyfin-device-cleanup.service"} |= "pruning device"`.
- After a Jellyfin bump: re-read `/api-docs/openapi.json` for `/Devices`
  changes — there is no plugin ABI here, but the endpoint shape is the
  contract.
