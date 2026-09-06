# environments/local

## Abstract

The repo's local, single-node reference composition — currently just the
`pitchfork`-supervised OpenBao/Transit signing backend the
digest-as-source-of-truth pipeline's approval gate uses
(`modules/secret-openbao-local`). Named `local` (not just left at repo
root) so `environments/production/` can slot in later for real
`secret-openbao`/`cluster-k0sctl` infra with zero rename — see
`docs/designs/digest-as-source-of-truth.md` § File layout for the full
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

**The printed unseal key is not stored anywhere by this script** — copy it
somewhere safe. You need it on every daemon restart (raft persists the
encrypted data, not the unseal state) and for a disaster `-force` snapshot
restore.

> ⚠️ Needing a hand-copied key on every restart is a **known friction
> flaw**, not a deliberate property for this single-operator local daemon —
> the machine is already the trust boundary and the root token lives in its
> keychain. Fix (machine-side storage + auto-unseal) is a planning task:
> CLAUDE.md § Deferred, "Local OpenBao unseal-key storage".

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

Wipes `openbao/data/` + the rendered `openbao.hcl` + the fnox-held root
token together — never do these separately; a stale root token surviving a
data wipe produces a confusing auth failure on the next `tofu apply`
instead of a clean "needs bootstrap" state. **`openbao/snapshots/` is
kept** — a reset is usually the first step of restoring from one.

## Backup + restore (T6)

OpenBao's community edition has no built-in snapshot scheduler
([openbao#795](https://github.com/openbao/openbao/issues/795)), so backup
here is **on demand** — run it before anything risky (a key rotation, an
OS upgrade, `mise run openbao-reset`):

```
mise run openbao-snapshot
```

Writes `environments/local/openbao/snapshots/latest.snap` (a real
`bao operator raft snapshot save` — never a raw copy of `openbao/data/`,
which can grab raft's bolt store mid-write). The file is git-ignored;
**copy it somewhere durable yourself** if you want more than the last one.

Losing `openbao/data/` does **not** invalidate past approvals —
`verify-approval.sh` / `mise run consume` check against the committed
`deploy/frontend/cosign-approval.pub`, not OpenBao. A snapshot lets you
resume *signing* without minting a new `approval-key` (which would
invalidate that committed key and every consumer pin).

### Restore into the running daemon (roll back)

Daemon up and unsealed, want to undo a recent change:

```
mise run openbao-snapshot-restore -- environments/local/openbao/snapshots/latest.snap
```

### Restore after losing the data directory (disaster)

You need **three** things kept together — the snapshot is useless without
the other two:

1. `latest.snap`
2. the **unseal key** from the bootstrap that created it
3. the **root token** from that same bootstrap

`bao operator raft snapshot restore` replaces *all* data, including the
seal config and the token store — so after a restore the instance is
sealed with the original seal and only the original root token is valid.
This is why the unseal key must live *with* the snapshots, not just
"somewhere".

```
mise run openbao-reset          # keeps snapshots/
mise run openbao-bootstrap      # fresh instance — its new unseal key + token are throwaway
mise run openbao-snapshot-restore -- -force environments/local/openbao/snapshots/latest.snap
bao operator unseal <ORIGINAL unseal key>
echo "<ORIGINAL root token>" | fnox set VAULT_TOKEN --provider keychain
```

`-force` is required: the snapshot's cluster ID / seal config won't match
the fresh instance's. `snapshot.bats` exercises this exact path.

`bao operator raft snapshot restore` prints `Error properly closing policy
file: ... file already closed` on success — it is **cosmetic** (the command
still exits 0), not a failure.

If a save or restore times out on a larger store, prefix with
`VAULT_CLIENT_TIMEOUT=120s`.

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

- **Backup** — see "Backup + restore (T6)" above. On-demand
  `mise run openbao-snapshot`; no scheduler (OpenBao community has none).
- **Not the production `secret-openbao` module.** That module is deferred
  until a real k0s cluster exists (see TODOS.md); `modules/
  secret-openbao-local` is what this reference deployment actually runs
  today.
- `openbao/data/` is git-ignored — local runtime state, never committed.
