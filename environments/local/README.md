# environments/local

## Abstract

The repo's local, single-node reference composition — currently just the
`pitchfork`-supervised OpenBao/Transit signing backend the
digest-as-source-of-truth pipeline's approval gate uses
(`modules/secret-openbao-local`). Named `local` (not just left at repo
root) so `environments/production/` can slot in later for real
`secret-openbao`/`cluster-k0sctl` infra with zero rename — see
`docs/designs/digest-as-source-of-truth.md`'s File Layout for the full
reasoning.

`pitchfork.toml` itself stays at the **repo root**, not here — pitchfork
only discovers the nearest `pitchfork.toml` searching *upward* from the
current directory, never into subdirectories, so it has to live somewhere
reachable from wherever `mise` tasks run (repo root). Its daemon's
`dir = "environments/local"` points the actual `bao server` process here.

## Bootstrap

```
mise run openbao-bootstrap
```

Renders `openbao/openbao.hcl`, starts the daemon via `pitchfork start
openbao`, initializes + unseals OpenBao (first run only), provisions the
Transit engine + keys, and stores the root token via `fnox` (OS keychain)
so future sessions don't need a manual `export VAULT_TOKEN=...` —
`eval "$(fnox activate zsh)"` (or bash) picks it up automatically.

**The printed unseal key is the one thing this script never stores
anywhere** — copy it to a password manager immediately. Keeping it
out-of-band is the actual security property (CLAUDE.md § Zero Trust); if
it lived in the same keychain as the root token, compromising one machine
would compromise both bootstrap secrets at once.

Verify:
```
bao secrets list                              # shows transit/
bao read transit/keys/approval-key             # shows type=ecdsa-p256, exportable=false
bao status                                     # Storage Type: raft, HA Mode: active
pitchfork status openbao                       # daemon running
```

## Reset

```
mise run openbao-reset
```

Wipes `openbao/data/` and the fnox-held root token together — never do
these separately; a stale root token surviving a data wipe produces a
confusing auth failure on the next `tofu apply` instead of a clean
"needs bootstrap" state.

## Manual bootstrap (what the script above actually does)

Useful for debugging, or if `mise run openbao-bootstrap` fails partway:

1. `tofu init && tofu apply` from this directory — **errors** (`no vault
   token set on Client`), expected: `local_file` resources (rendered
   `openbao.hcl`, the `openbao/data/` placeholder) still get created
   despite the Transit resources failing. Confirm: `ls openbao/openbao.hcl`.
2. `pitchfork start openbao` (from repo root, or anywhere — pitchfork.toml
   is discoverable from any subdirectory of the repo).
3. First run only — initialize and capture the unseal key + root token
   out-of-band:
   ```
   export VAULT_ADDR=http://127.0.0.1:8200
   bao operator init -key-shares=1 -key-threshold=1
   ```
   Single-share Shamir is deliberate: solo-operator local dev daemon, not
   a multi-party production unseal ceremony.
4. Unseal (needed again after every OpenBao process restart — raft
   storage persists the encrypted data, not the unseal state):
   ```
   bao operator unseal <unseal key from step 3>
   ```
5. Store the token and provision Transit:
   ```
   echo "<root token from step 3>" | fnox set VAULT_TOKEN --provider keychain
   export VAULT_TOKEN="<root token from step 3>"
   tofu apply
   ```
   (Never `fnox set VAULT_TOKEN "<token>"` as an argument — that puts the
   token in shell history. Pipe it in, or let the interactive prompt
   `fnox set VAULT_TOKEN` with no value ask for hidden input instead.)

## Notes

- **Backup** (T6 in `docs/designs/digest-as-source-of-truth.md`, not yet
  built) uses `bao operator raft snapshot save`/`restore` — not a raw
  directory copy, which can grab raft's bolt store mid-write.
- **Not the production `secret-openbao` module.** That module is deferred
  until a real k0s cluster exists (see TODOS.md); `modules/
  secret-openbao-local` is what this reference deployment actually runs
  today.
- `openbao/data/` is git-ignored — local runtime state, never committed.
