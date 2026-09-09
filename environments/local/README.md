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

## Tekton (controller install — a Flux prerequisite)

The `ci/` concern's `buildkit-build` Task runs on `orb start k8s` and needs
the Tekton Pipelines controller installed once per cluster:

```
mise run local:tekton:install          # checksum-verified, then kubectl apply --server-side
```

`environments/local/scripts/tekton-install.sh` downloads the pinned
`release.yaml`, verifies its SHA-256 against
`environments/local/tekton/release.lock`, and only then applies the
**verified local file**. `kubectl apply -f <url>` is never used — the
checksum is the trust boundary (ADR 0001); a mismatch is a hard refusal.

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

Pinned in `environments/local/tekton/release.lock` (`version` + `sha256`) to
**Tekton Pipelines v1.6.0**. The GCS bucket path uses the pipeline COMPONENT
version, not the GitHub release-train tag (`previous/v1.15.1/` 404s). To
re-pin on a bump, recompute and update both lines:

```
curl -sSfL https://storage.googleapis.com/tekton-releases/pipeline/previous/<v>/release.yaml | shasum -a 256
```

**T7c scope:** T7c moves the reusable Task/Pipeline **defs** (`ci/tasks`,
`ci/pipelines`) and `ci/runtime` to Flux `Kustomization`s — **not** this
controller install. Flux cannot install an absent Tekton, so
`local:tekton:install` stays a **named prerequisite** for the T7c
`ci-runtime` Flux Kustomization (its `tasks.tekton.dev` /
`pipelines.tekton.dev` CRD health checks depend on this having run).
Moving the controller itself to Flux is revisited at the ADR-0014 OCI-bundle
distribution phase, if a Tekton OCI artifact exists by then.

The `ci/` kubeconform gate validates against Tekton v1 CRD schemas vendored
from this same version at `ci/tests/crd-schemas/` — refresh both together
on a version bump.

## Flux (the GitOps reconciler)

Flux reconciles this environment's platform manifests from git. One
**imperative bridge** installs it; everything after is declarative.

```
mise run local:flux:bootstrap   # once per cluster — idempotent
mise run local:flux:status      # FluxInstance + every source/Kustomization/HelmRelease
```

`environments/local/scripts/flux-bootstrap.sh`:

1. `cosign verify`s the **pinned** flux-operator chart digest
   (`environments/local/flux/flux-operator.lock`, keyless — Fulcio/Rekor, the
   GitHub OIDC identity). No `--insecure-ignore-tlog` fallback.
2. `helm upgrade --install`s **that digest** (never a tag — ADR 0001).
3. waits for the operator + its CRD, applies `flux-instance.yaml`, waits Ready.

From then on **helm-controller owns the operator** (`flux-operator-helmrelease.yaml`
— an `OCIRepository` with `spec.verify: cosign` + a `HelmRelease` that adopts
the bridge's release). An operator or Flux upgrade is a digest bump in
`flux-operator.lock` + the committed YAML — no more shell.

| file | role |
|---|---|
| `flux/flux-operator.lock` | the three pinned + verified digests (chart, operator image, distribution manifests) |
| `flux/flux-instance.yaml` | the one `FluxInstance` — Flux 2.9.5, `source`+`kustomize`+`helm` controllers, syncs `environments/local/flux/` from `main` |
| `flux/flux-operator-helmrelease.yaml` | operator self-management (`OCIRepository` + `HelmRelease`) |
| `flux/zot-sync.yaml` | the Flux `Kustomization` that reconciles `environments/local/zot/` |
| `flux/tests/crd-schemas/*.json` | v1/v2 CRD schemas vendored from Flux 2.9.5 + flux-operator v0.59.0 for the `kubeconform-flux` gate — **regenerate on a bump** (`crane digest` + `cosign verify` per the lock-file header; CRDs from `github.com/fluxcd/flux2/releases/download/v2.9.5/manifests.tar.gz` and `controlplaneio-fluxcd/flux-operator` tag `v0.59.0`) |
| `tests/flux/chainsaw-test.yaml` | `[k8s]`-gated server-side check (`flux-chainsaw.sh` — skips in CI and until `local:flux:bootstrap` has run): the operator accepted the FluxInstance, source-controller fetched an artifact from git, the OCIRepository is cosign-verified, the HelmRelease self-manages, the zot Kustomization applied. Asserts running state; does not bootstrap or tear down. |

**Lifecycle trace** (CLAUDE.md § planning gate): bootstrap = one `helm upgrade
--install` from the bridge task, needs a reachable cluster first (`orb start
k8s` — a human step, or the optional machine-global pitchfork daemon, § Tekton).
Pod restart / reboot: k8s restarts the controllers; source artifacts live in
`emptyDir` and are re-fetched (seconds). Cluster rebuild: re-run
`local:flux:bootstrap`, then `local:tekton:install` (Flux cannot install an
absent Tekton), then Flux reconciles the rest. Operator/Flux upgrade: a
reviewed digest bump in git — a recurring **decision**, not a manual apply.
Disaster (disk loss): recover the checkout + re-bootstrap; zot data and
OpenBao signing state are separate recovery problems. No memorized secret (the
repo is public — anonymous HTTPS sync, no pull Secret).

## zot (interim — install reconciled by Flux)

The T7b pipeline builds, scans and attaches evidence **against a local
registry**, not GHCR (`TODOS.md` T7b0, `~/.claude/plans/t7b-pipeline-recut.md`).
A loopback zot removes the per-run `gh auth token` push Secret entirely and
gives a native OCI-1.1 Referrers API.

Installed by Flux — `environments/local/flux/zot-sync.yaml` reconciles
`environments/local/zot/zot.yaml` (`mise run local:flux:bootstrap` brings Flux
up; Flux does the rest). `mise run local:zot:wait` still blocks until the
Deployment is Available.

Manifests: `environments/local/zot/zot.yaml` (one multi-doc file, applied in
order — Namespace → PVC → ConfigMap → Deployment → Service). `zot-manifests.bats`
guards the digest pin, the absence of an auth block, `gc: false`, and
NodePort-only exposure. `kubeconform` validates the manifests in `mise run
check`.

**Credential-free, by design.** No `auth` block; HTTP only. On the single-user
OrbStack VM every cluster workload is the operator's, so "all cluster writers
trusted" is the stated threat model. A second operator, a shared cluster, or
`environments/production/` needs real auth — the **P2 "zot registry auth"**
planning session (`TODOS.md`).

**GC is OFF.** Nothing is ever deleted from the interim store, which subsumes
`deleteUntagged: false` (Codex #7 — a digest-only push must not be
garbage-collected). Production revisits retention.

Reachable two ways — same registry, two names:

| From | Address | Used by |
|---|---|---|
| in-cluster pods | `zot.zot.svc.cluster.local:5000` | the build / scan / attach TaskRun steps (T7b1+) |
| the host | `localhost:30500` (NodePort) | the operator's `oras` / `docker` in the consume demo |

### Verify (once, after install — the real clients)

`kubeconform` + `zot-manifests.bats` are static. Prove the running registry
by hand (the in-cluster build proof rides with T7b1, exactly as T7a proved
buildkit in a spike):

```
# 1. Deployment healthy
kubectl --context orbstack -n zot get deploy,pod,svc

# 2. host reach + a real push/pull round-trip via the NodePort
oras push --plain-http localhost:30500/smoke:v1 --artifact-type application/vnd.test ./README.md:text/plain
oras pull --plain-http localhost:30500/smoke:v1 -o /tmp/zot-smoke && rm -rf /tmp/zot-smoke

# 3. native Referrers API (a fallback-tag response means it is NOT native)
oras attach --plain-http --artifact-type application/vnd.test.note \
  localhost:30500/smoke:v1 ./README.md:text/plain
oras discover --plain-http --format tree localhost:30500/smoke:v1

# 4. in-cluster reach (a throwaway pod)
kubectl --context orbstack -n zot run smoke --rm -it --restart=Never \
  --image=ghcr.io/oras-project/oras:v1.3.4 -- \
  push --plain-http zot.zot.svc.cluster.local:5000/incluster:v1 /etc/hostname:text/plain

# 5. exposure boundary — NodePort only, no LoadBalancer / Ingress
kubectl --context orbstack -n zot get svc,ingress

# cleanup
oras manifest delete --plain-http --force localhost:30500/smoke:v1 || true
```

If OrbStack does not surface the NodePort on `localhost:30500`, switch the
Service `type` to `LoadBalancer` (OrbStack maps those to `localhost` too) and
update `zot-manifests.bats` + this doc.

### Uninstall

Flux won't do it — the Namespace + PVC are annotated
`kustomize.toolkit.fluxcd.io/prune: disabled` and `zot-sync.yaml` is
`deletionPolicy: Orphan`. A deliberate teardown is manual:

```
kubectl --context orbstack delete -f ./environments/local/zot/zot.yaml
```

Regenerate the image digest on a version bump:
`oras resolve ghcr.io/project-zot/zot-linux-arm64:v<VERSION>`.

## Notes

- **Not the production `secret-openbao` module.** That module is deferred
  until a real k0s cluster exists (`TODOS.md`); the `./openbao/` unit is
  what this reference deployment runs today. The production module keeps
  its own out-of-band requirement (ADR 0012).
- Test seams on the scripts: `TOOLBOX_OPENBAO_{STATE_DIR,DAEMON,LISTEN,
  SUPERVISOR}` — `SUPERVISOR=none` runs a plain tracked `bao server` +
  pidfile instead of pitchfork, so bats never writes the real
  `~/.config/pitchfork/config.toml`.
