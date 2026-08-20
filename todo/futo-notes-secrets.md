# FUTO Notes secrets are empty placeholders

Filled in 2026-08-20: `agenix -d futo-notes-db-password.age` and
`agenix -d futo-notes-env.age` decrypt to **nothing**. Both `.age` files were
committed as placeholders in `4190486 feat(containers): add placeholder agenix
files for FUTO Notes secrets`; the later `chore(agenix): reencrypt` only rotated
recipients, not content. The container and DB role are therefore configured with
empty credentials.

**Status — steps 1, 2, and the commit half of step 5 done (2026-08-20). Deploy
(3) and verify (4) still open.**

## What must be set

Both secrets are edited from inside `secrets/` (agenix resolves `./secrets.nix`
relative to cwd):

```bash
cd secrets
agenix -e futo-notes-db-password.age   # DB password, no trailing newline
agenix -e futo-notes-env.age           # plain KEY=value: FUTO_NOTES_PASSWORD=<...>
```

- `futo-notes-db-password.age` is the **shared** password consumed by two
  hosts — it must be one value that satisfies both:
  - `database` host: `postgresql-futo-notes-password` unit runs
    `ALTER ROLE futo_notes … PASSWORD` (hosts/database/configuration.nix:423).
  - `containers` host: `generateDbEnv` bakes it into the `DATABASE_URL`
    (hosts/containers/futo-notes/default.nix:16).
- `futo-notes-env.age` is loaded via the container's `environmentFiles`, so it
  must be raw `KEY=value` — no `export`, no quotes. The server reads
  `FUTO_NOTES_PASSWORD` (AUTH_MODE=password).

## Steps

- [x] **1** Fill both secrets — done. An agent-generated random value was set
      first as a stopgap (via a scripted `EDITOR=cp <tmpfile>` trick, since
      piping straight into `agenix -e`'s stdin-editor path hit a BSD-`cp`
      `/dev/stdin` bug on macOS and silently produced no file), then
      **overwritten with the real chosen values by hand** via plain
      `agenix -e futo-notes-db-password.age` / `agenix -e futo-notes-env.age`.
      Retrieve either with `agenix -d <file>` if you need the literal value
      (e.g. to log into the app).
- [x] **2** Re-key to current recipients — done, `06955da "chore(reencrypt):
      added futo secrets"`. Note for next time: `just reencrypt` alone
      (`justfile:131`, `agenix -r -i ~/.config/age/keys.txt`) was not enough on
      its own — a 2026-08-19 partial rekey (`fd6fdf7 "chore(tools): partial
      rekey should be enough"`) had left every secret alphabetically after
      `dashboard-env.age` still encrypted to the pre-`amadeusAge` recipient set,
      so the plain recipe died on the first one it hit with `no identity
      matched any of the recipients`. Fixed by also passing the MacBook SSH
      identity: `agenix -r -i ~/.config/age/keys.txt -i ~/.ssh/id_ed25519`.
- [ ] **3** Deploy both consumers — the DB role password must land before/with
      the container or login/auth breaks:
      - `just colmena-apply-host database`
      - `just colmena-apply-host containers` (generated `db.env` /
        `futo-notes-env` change the unit `environmentFiles`, so the futo-notes
        container restarts on its own).
- [ ] **4** Verify:
      - `agenix -d futo-notes-db-password.age` prints the value (no
        `no identity matched` on a key the MacBook holds).
      - `ssh containers.homelab.local 'sudo podman exec futo-notes printenv DATABASE_URL FUTO_NOTES_PASSWORD'`
      - Log in to the FUTO Notes app against `https://notes.homelab.local`.
- [x] **5** Commit the re-encrypted `.age` blobs — done, part of `06955da`. No
      stray placeholder files existed beside them; nothing else to remove.