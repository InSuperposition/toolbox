# deploy/cv-frontend — Phase 1 OpenBao Transit bootstrap (T3)

## Abstract

Provisions the OpenBao Transit engine + `approval-key` that the
digest-as-source-of-truth pipeline's `approve.sh`/`mise run consume` (T5)
sign and verify approval attestations with. OpenBao itself runs as a
`pitchfork`-supervised **local dev process** — not the deferred production
`secret-openbao` module (see `TODOS.md`, `CLAUDE.md` § Tool Boundaries).

## Goals

- `bao secrets list` shows `transit/`.
- `approval-key` exists in that engine, type `ecdsa-p256`, never exportable.
- `pitchfork` autostarts the OpenBao process on entering this directory.

## Constraints

- Zero plaintext secret in this repo: the OpenBao root/unseal material is
  out-of-band, human-held, same as this repo's existing OpenBao precedent
  (CLAUDE.md § Zero Trust).
- File storage, not `-dev` mode: state survives a process restart on disk,
  but the server still starts **sealed** every time (see Bootstrap below).

## Bootstrap (one-time)

1. Enter this directory (or run `pitchfork start openbao` directly) —
   `pitchfork.toml` autostarts the `bao server` daemon on `127.0.0.1:8200`.
2. **First run only** — initialize and capture the unseal key + root token
   somewhere out-of-band (a password manager, not this repo):
   ```
   export VAULT_ADDR=http://127.0.0.1:8200
   bao operator init -key-shares=1 -key-threshold=1
   ```
   Single-share Shamir is deliberate here: this is a solo-operator local
   dev daemon, not a multi-party production unseal ceremony.
3. Unseal (needed again after every OpenBao process restart — file storage
   persists the encrypted data, not the unseal state):
   ```
   bao operator unseal <unseal key from step 2>
   ```
4. Provision the Transit engine + key:
   ```
   export VAULT_TOKEN=<root token from step 2>
   tofu init
   tofu apply
   ```
5. Verify:
   ```
   bao secrets list                              # shows transit/
   bao read transit/keys/approval-key             # shows type=ecdsa-p256, exportable=false
   pitchfork status openbao                       # daemon running
   ```

## Notes

- **Backup is not yet built** (T6, tracked separately) — losing
  `openbao/data/` loses the signing key material. Don't treat this local
  process as durable until T6 lands.
- **Not the production `secret-openbao` module.** That module is deferred
  until a real k0s cluster exists to run OpenBao against (see TODOS.md);
  this directory is the Phase 1 CI/approval wedge only.
- `openbao/data/` is git-ignored — it's local runtime state, not something
  to commit.
