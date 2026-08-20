# FUTO Notes secrets are empty placeholders

Filled in 2026-08-20: `agenix -d futo-notes-db-password.age` and
`agenix -d futo-notes-env.age` decrypt to **nothing**. Both `.age` files were
committed as placeholders in `4190486 feat(containers): add placeholder agenix
files for FUTO Notes secrets`; the later `chore(agenix): reencrypt` only rotated
recipients, not content. The container and DB role are therefore configured with
empty credentials.

**Status — not started.**

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

- [ ] **1** Fill both secrets with `agenix -e` (above).
- [ ] **2** Re-key to current recipients: `just reencrypt` (run from repo root).
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
- [ ] **5** Commit the re-encrypted `.age` blobs and remove the placeholder
      files if any separate `*.txt`/notes were left beside them.