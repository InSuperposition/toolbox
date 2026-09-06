# The local OpenBao is one machine-global daemon that auto-unseals from a static seal key

The local dev OpenBao is a single **pitchfork *global* daemon** (one per
developer machine, `~/.config/pitchfork/config.toml`, `--boot-start`), with
its raft store / rendered config / snapshots / tofu state under
`~/.local/state/toolbox/openbao/`. It **auto-unseals on every start** via a
`seal "static"` stanza keyed by a 32-byte `file://` key at
`<state_dir>/seal.key` (0600). `bao operator init` yields a recovery key
(break-glass only) — the root token and recovery key are also `0600` files
in `<state_dir>` (ADR 0011). There is no `bao operator unseal` step anywhere
in normal operation.

Why machine-global, not per-worktree: `pitchfork` namespaces project
daemons by directory, so a daemon in the repo's `pitchfork.toml` starts a
second `bao server` per git worktree and the two lock-conflict on the
shared raft store (this is the failure that prompted the change). A unix
socket would isolate per worktree without a port, but the `opentofu/vault`
provider has no `unix://` transport (verified) and `environments/local`
needs it to provision Transit. One daemon per machine removes the collision
category rather than guarding against it.

Why a `file://` key on disk, not a hand-copied Shamir key: the daemon
`--boot-start`s, possibly before the login keychain unlocks, so it must read
the key from a file. `seal.key` sits beside `vault.db`, which already holds
everything the key protects — no additional exposure. Routine restart and
machine reboot are now zero-step. The one remaining manual case is the
disaster `-force` snapshot restore, which needs the snapshot's *own*
`seal.key` + `root.token` — `mise run openbao-snapshot` writes them together
as a bundle (ADR 0011, `environments/local/README.md`).

Why static seal, not Transit auto-unseal: Transit needs a second OpenBao
instance (the unsealer), which itself needs unsealing or runs in dev mode.
Wrong shape for a single-operator local box; it stays a candidate for the
deferred production `secret-openbao` module, which keeps its out-of-band
requirement.

Status: accepted. Closes the "Local OpenBao unseal-key storage" item in
CLAUDE.md § Deferred.
