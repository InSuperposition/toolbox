# toolbox

See `CLAUDE.md` for the full design (goals, tool boundaries, GitOps flow).
This file currently covers only the root composition's OpenBao bootstrap —
extend it as the reference deployment grows.

## OpenBao bootstrap (one-time)

The root composition (`main.tf`) provisions a local, `pitchfork`-supervised
OpenBao Transit engine via `modules/secret-openbao-local` — the signing
backend the digest-as-source-of-truth pipeline's approval gate uses.

**First run is a two-step apply** — the module renders `openbao.hcl`
*and* provisions Transit keys in the same `main.tf`, but Transit needs
OpenBao already running+unsealed, which needs `openbao.hcl` to already
exist. Chicken-and-egg, resolved by running `tofu apply` once before
OpenBao is even up:

1. `tofu init && tofu apply` — this **errors** (`no vault token set on
   Client`), which is expected: the independent `local_file` resources
   (the rendered `openbao.hcl` and the `openbao/data/` placeholder) still
   get created despite the Transit resources failing. Confirm:
   `ls openbao/openbao.hcl`.
2. Enter this directory (or run `pitchfork start openbao` directly) —
   `pitchfork.toml` now has a config to start `bao server` against, on
   `127.0.0.1:8200`.
3. **First run only** — initialize and capture the unseal key + root token
   somewhere out-of-band (a password manager, not this repo):
   ```
   export VAULT_ADDR=http://127.0.0.1:8200
   bao operator init -key-shares=1 -key-threshold=1
   ```
   Single-share Shamir is deliberate: this is a solo-operator local dev
   daemon, not a multi-party production unseal ceremony.
4. Unseal (needed again after every OpenBao process restart — raft
   storage persists the encrypted data, not the unseal state):
   ```
   bao operator unseal <unseal key from step 3>
   ```
5. Provision the Transit engine + keys for real:
   ```
   export VAULT_TOKEN=<root token from step 3>
   tofu apply
   ```
6. Verify:
   ```
   bao secrets list                              # shows transit/
   bao read transit/keys/approval-key             # shows type=ecdsa-p256, exportable=false
   bao status                                     # Storage Type: raft, HA Mode: active
   pitchfork status openbao                       # daemon running
   ```

## Notes

- **Backup is not yet built** (T6 in `docs/designs/digest-as-source-of-
  truth.md`, tracked separately) — losing `openbao/data/` loses the
  signing key material. Don't treat this local process as durable until
  T6 lands.
- **Not the production `secret-openbao` module.** That module is deferred
  until a real k0s cluster exists to run OpenBao against (see TODOS.md);
  `modules/secret-openbao-local` is the local dev daemon this reference
  deployment actually runs today.
- `openbao/data/` is git-ignored — it's local runtime state, not something
  to commit.
