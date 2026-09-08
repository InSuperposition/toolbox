# environments/local

## Abstract

The repo's local, single-node reference composition. Today: the local
OpenBao / Transit signing backend the digest-as-source-of-truth pipeline's
approval gate uses, plus the interim **Tekton Pipelines** install the
`ci/` concern's build TaskRun needs (`§ Tekton` below). This environment
**owns** the OpenBao unit (`./openbao/`, `module "secret_openbao_local"`)
and the scripts that bring it up (`scripts/openbao-*.sh`) — ADR 0012 — and
owns vendored-upstream installs like Tekton's controller (never `ci/`,
same split as OpenBao). Named `local` (not left at repo root) so
`environments/production/` can slot in later for real `secret-openbao` /
`cluster-k0sctl` infra with zero rename.

The OpenBao daemon is **machine-global** (one per developer machine, not
one per git worktree — ADR 0010): a pitchfork *global* daemon
(`~/.config/pitchfork/config.toml`, `--boot-start`), with its raft store,
rendered config, secret files and tofu state under
`$OPENBAO_STATE_DIR` = `${XDG_STATE_HOME:-~/.local/state}/toolbox/openbao/`.

All of its secrets are `0600` files in that directory (ADR 0011): no
keychain, no `fnox`.

| file | role |
|---|---|
| `seal.key` | static-seal key — the daemon auto-unseals from it every start (`file://`) |
| `root.token` | root token — `mise [env]` injects it as `VAULT_TOKEN` (no shell hook) |
| `recovery.key` | break-glass only — `bao operator generate-root` if `root.token` is lost |
| `data/` | raft store (encrypted by `seal.key`) |
| `openbao.hcl` | rendered config |
| `tofu.tfstate` | provisioning state |
| `snapshots/` | restore bundles — kept across `local:openbao:reset` |

## Bootstrap (once per machine)

```
mise run local:openbao:bootstrap
```

Renders `openbao.hcl`, generates `seal.key`, registers + starts the global
pitchfork daemon, `bao operator init` (auto-unseals via the static seal —
**no `bao operator unseal` step, ever**), writes `root.token` +
`recovery.key`, provisions the Transit engine + `approval-key`, and calls
`mise run attestation:export-pubkey` to write
`attestation/cosign-approval.pub` (it never writes across the boundary
itself — ADR 0013).

`VAULT_TOKEN` reaches every `mise run` task and the interactive shell
through one `mise.toml` line (`{{ exec(command='cat ".../root.token"') }}`).
If your current shell was activated before the first bootstrap and shows an
empty `VAULT_TOKEN`, open a new shell or run `mise env`.

Verify:
```
bao status                       # Seal Type: static, Sealed: false, Storage: raft
bao secrets list                 # transit/
bao read transit/keys/approval-key
pitchfork list | grep openbao    # global/openbao   running
```

After a reboot the daemon boot-starts and auto-unseals. If it is stopped:
`mise run local:openbao:start`.

## Reset (machine-wide)

```
mise run local:openbao:reset
```

Stops + unregisters the global daemon (**waiting until it has actually
exited** — a `rm -rf data/` against a live raft node corrupts the bolt
store), then wipes `data/`, `openbao.hcl`, `seal.key`, `root.token`,
`recovery.key` and the tofu state. `snapshots/` is **kept** — it is the
restore bundle. Confirms unless `TOOLBOX_OPENBAO_RESET_YES=1`.

Reset rotates the Transit `approval-key`. Nothing about a credential-storage
problem needs a reset — a lost/corrupt `root.token` is recovered with
`recovery.key` (below), not by resetting.

## Backup + restore

OpenBao community has no snapshot scheduler
([openbao#795](https://github.com/openbao/openbao/issues/795)) — backup is
**on demand**, before anything risky (key rotation, OS upgrade, reset):

```
mise run local:openbao:snapshot
```

Writes a **complete bundle** to `$OPENBAO_STATE_DIR/snapshots/`:
`latest.snap` + a copy of `seal.key` + a copy of `root.token`. A bare
`.snap` cannot be restored — the three travel together. Copy the whole
`snapshots/` directory somewhere durable (or off-machine) for real
disaster recovery.

Losing `data/` does **not** invalidate past approvals —
`attestation-verify.sh` / `mise run attestation:verify` check against the
committed `attestation/cosign-approval.pub`, not OpenBao. A snapshot lets
you resume *signing* without minting a new `approval-key`.

### Roll back a change (daemon up)

```
mise run local:openbao:snapshot-restore -- "$OPENBAO_STATE_DIR/snapshots/latest.snap"
```
Same `seal.key`, so the daemon auto-unseals straight after — no manual step.

### Disaster restore (data directory lost)

`bao operator raft snapshot restore` replaces *all* data including the seal
config and token store, so after a `-force` restore the instance is sealed
by the snapshot's **original** seal key and only its **original** root token
is valid. That is why the bundle carries them.

```
mise run local:openbao:reset                                   # keeps snapshots/
mise run local:openbao:bootstrap                               # fresh instance (its keys are throwaway)
bao operator raft snapshot restore -force "$OPENBAO_STATE_DIR/snapshots/latest.snap"
cp -f "$OPENBAO_STATE_DIR/snapshots/seal.key"  "$OPENBAO_STATE_DIR/seal.key"
pitchfork restart global/openbao                         # re-reads the original seal.key -> auto-unseal
# VAULT_TOKEN is now stale in your shell -> use the bundle's token:
export VAULT_TOKEN="$(cat "$OPENBAO_STATE_DIR/snapshots/root.token")"
```

`-force` is required (cluster ID / seal config won't match the fresh
instance). `restore` prints `Error properly closing policy file: … file
already closed` on success — cosmetic, exits 0. `snapshot.bats` exercises
this exact path. Prefix `VAULT_CLIENT_TIMEOUT=120s` for a large store.

### Corrupt `root.token`, daemon healthy

Re-running bootstrap does **not** help (an initialised instance skips the
init that would rewrite the token). Use the recovery key:

```
bao operator generate-root -init
# follow the OTP prompts, supplying $OPENBAO_STATE_DIR/recovery.key as the
# recovery-key share; write the new token:
printf '%s' "<new root token>" > "$OPENBAO_STATE_DIR/root.token" && chmod 600 "$_"
```

## Tekton (interim — replaced by Flux in T7c)

The `ci/` concern's `buildkit-build` Task runs on `orb start k8s` and needs
the Tekton Pipelines controller installed once per cluster:

```
mise run local:tekton:install          # kubectl apply --server-side, pinned v1.6.0
```

**Keeping `orb start k8s` up (optional DX).** One OrbStack k8s cluster per
machine, shared across worktrees — so, like the OpenBao daemon (ADR 0010),
it belongs in the **machine-global** pitchfork config, not the repo
`pitchfork.toml`. Add to `~/.config/pitchfork/config.toml`:

```toml
[daemons.orb-k8s]
run = "orb start k8s"
auto = ["start"]
```

`orb start k8s` is idempotent and returns once the cluster is up; it does
**not** keep k8s healthy (Codex #8). So `ci/scripts/tekton-taskrun.sh` and
`chainsaw-test.sh` always run their own `kubectl` readiness check and fail /
skip with a clear message — the daemon is a convenience, not a guarantee.

Pinned to **Tekton Pipelines v1.6.0**. `previous/v1.6.0/release.yaml` has
sha256 `d0f6dc1dc7afe7f8725075ee07f6bf8eb01dd246f41ea404ed32e9ab023425ba`
(GCS bucket path uses the pipeline COMPONENT version, not the GitHub
release-train tag — `previous/v1.15.1/` 404s). Verify before the first
apply:

```
curl -sSL https://storage.googleapis.com/tekton-releases/pipeline/previous/v1.6.0/release.yaml | shasum -a 256
```

This is **interim**: T7c moves it to a Flux `OCIRepository` /
`Kustomization` under `environments/local/tekton/`, and the
`local:tekton:install` task is retired then (`TODOS.md` T7, ADR 0014). The
`ci/` kubeconform gate validates against Tekton v1 CRD schemas vendored
from this same version at `ci/tests/crd-schemas/` — refresh both together
on a version bump.

## Notes

- **Not the production `secret-openbao` module.** That module is deferred
  until a real k0s cluster exists (`TODOS.md`); the `./openbao/` unit is
  what this reference deployment runs today. The production module keeps
  its own out-of-band requirement (ADR 0012).
- Test seams on the scripts: `TOOLBOX_OPENBAO_{STATE_DIR,DAEMON,LISTEN,
  SUPERVISOR}` — `SUPERVISOR=none` runs a plain tracked `bao server` +
  pidfile instead of pitchfork, so bats never writes the real
  `~/.config/pitchfork/config.toml`.
