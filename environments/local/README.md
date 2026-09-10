# environments/local

## Abstract

The repo's local, single-node reference composition. Today: the in-cluster
**OpenBao / Transit** signing backend the digest-as-source-of-truth
pipeline's approval gate uses (`./openbao/`, ADR 0016), plus the interim
**Tekton Pipelines** install the `ci/` concern's build TaskRun needs
(`§ Tekton` below) and the **Flux** GitOps loop (`§ Flux`). This environment
**owns** the OpenBao unit and the scripts that bring it up
(`scripts/openbao-*.sh`) and owns vendored-upstream installs like Tekton's
controller (never `ci/`). Named `local` (not left at repo root) so
`environments/production/` can slot in later for real `secret-openbao` /
`cluster-k0sctl` infra with zero rename.

## OpenBao (in-cluster — ADR 0016)

OpenBao runs in the OrbStack cluster as a single-replica tofu-owned raft
StatefulSet in ns `openbao`, reached over TLS at
`https://openbao.openbao.svc.cluster.local:8200` (OrbStack routes the Mac
host into the cluster network, so the ClusterIP DNS name resolves from the
host directly). The pod auto-unseals from a mounted `openbao-seal` Secret —
**no `bao operator unseal` step, ever**. cert-manager issues the TLS server
cert (`§ Flux`). It is **not** a Flux `HelmRelease` — the secret store must
not sit behind the reconcile loop that later depends on it for SOPS
(ADR 0015).

`$OPENBAO_STATE_DIR` = `${XDG_STATE_HOME:-~/.local/state}/toolbox/openbao/`
holds the on-machine side, written by the bridge on every successful run
(`0600`, no keychain, no `fnox` — ADR 0011):

| path | role |
|---|---|
| `snapshots/{latest.snap,seal.key,root.token}` | the restore bundle — the disaster / genesis source. Copy off-machine. |
| `root.token` | the bundle's original root token — `mise [env]` → `VAULT_TOKEN` |
| `seal.key` | the bundle's seal key — the on-machine copy for a re-run |
| `tls/ca.crt` | the live cert-manager dev CA — `mise [env]` → `VAULT_CACERT` (public) |
| `openbao.tfstate` | Phase-A/C provisioning state (backed up in `snapshots/`; the bridge migrates a legacy `openbao-cluster.tfstate` in place) |

### Bootstrap / recover (once per cluster — disaster-re-runnable)

```
mise run local:openbao:bootstrap
```

`openbao-bootstrap.sh` — the one-time acyclic bridge (model
`flux-bootstrap.sh`). It picks a **source**:

| Condition | Action |
|---|---|
| a live init+unsealed host daemon at `$TOOLBOX_OPENBAO_HOST_ADDR` | snapshot it, migrate from it |
| no host, but a valid `snapshots/` bundle | restore from the bundle |
| no host, no bundle | exit — the disaster case (restore an off-machine bundle, or the "resume signing" runbook) |

then: create ns `openbao` + the seal Secret, wait for the cert-manager
`openbao-tls` cert + read its CA, `tofu apply` the `helm_release`, run
`bao operator init` once (throwaway tokens), do the key-preserving
`bao operator raft snapshot restore -force`, **hard-fail** unless the
in-cluster `approval-key` public half is byte-identical to
`attestation/cosign-approval.pub`, then `tofu apply` Phase C (the `sops`
`aes256-gcm96` key, a decrypt-only `flux_sops_decrypt` policy, the
Kubernetes ServiceAccount auth method + a `flux_sops` role bound to
`kustomize-controller`/`flux-system`). `approval-key` + the `transit` mount
are **never** tofu-managed — restore-managed; `openbao-verify.sh` greps the
`.tf` and fails closed. Finally it refreshes the `snapshots/` bundle from
the now-authoritative cluster and repairs the `$STATE_DIR` client creds.

Verify:
```
bao status                              # Seal Type: static, Sealed: false, Storage: raft
bao secrets list                        # transit/
bao list transit/keys                   # approval-key (preserved) + sops
kubectl --context orbstack -n openbao get statefulset,pod,svc,certificate
```

A pod restart or cluster return needs **no action** — the pod auto-unseals
from the Secret. Cluster return = `orb start k8s` (a pre-existing human
step, or the optional machine-global `orb-k8s` pitchfork daemon — § Tekton).

### Backup

```
mise run local:openbao:snapshot
```

Writes a **complete bundle** (`latest.snap` + `seal.key` + `root.token`) to
`$OPENBAO_STATE_DIR/snapshots/` from the in-cluster instance. The three
travel together — a bare `.snap` cannot be restored. Copy the whole
`snapshots/` directory off-machine: after the host daemon's retirement it is
the **only** genesis path (ADR 0016). Losing `data` does not invalidate past
approvals — `attestation-verify.sh` checks against the committed
`attestation/cosign-approval.pub`, not OpenBao; a snapshot lets you resume
*signing* without minting a new `approval-key`.

### Disaster: lost bundle + no host daemon

`approval-key` is unrecoverable. Past approvals still verify (the pubkey is
committed), so it is a **"resume signing"** problem, not a verification
outage: fresh `bao operator init` → `mise run attestation:export-pubkey` +
commit → re-sign the current image → `mise run frontend:deploy <image@digest>
<attestation-digest>`. Blast radius: future signing only.

### The retired host daemon

The machine-global `pitchfork` OpenBao daemon (ADR 0010) is retired. Any
machine that still has it registered removes it once, out of band:

```
pitchfork stop global/openbao && pitchfork daemons remove --global openbao
```

This touches only the daemon registration — never `seal.key` / `root.token`
/ `snapshots/`, which the in-cluster instance needs.

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

**What Flux reconciles** (the `flux-system` Kustomization applies
`environments/local/flux/kustomization.yaml`'s inventory — `flux-instance.yaml`
is excluded, it is the bridge-owned acyclic anchor):

- `zot-sync.yaml` → `environments/local/zot/` — the interim local registry.
- `ci-runtime.yaml` → `ci/runtime/` — the `ci` namespace + `buildkitd-mirror`
  ConfigMap. `wait: false` with `healthChecks` on the two Tekton CRDs + the
  controller/webhook Deployments (usable Tekton, not just types registered);
  `deletionPolicy: Orphan`.
- `ci-defs.yaml` → `ci/tasks/` + `ci/pipelines/` (two Kustomizations,
  `targetNamespace: ci`, `dependsOn: [ci-runtime]`, `ci-pipelines` also
  `[ci-tasks]`) — the reusable Task + Pipeline defs.

`ci/` owns those manifests + their per-path `kustomization.yaml` inventories;
`environments/local/` owns the deployment policy (the Flux `Kustomization` CRs
here). ADR 0015; `docs/designs/repo-structure.md` § deployment-composition
edge. **Tekton-absent:** `ci-runtime` goes NotReady (the CRD/Deployment health
checks), `ci-defs` stays blocked on `dependsOn` and retries — no notification
(no notification-controller); fix is `mise run local:tekton:install`.

| file | role |
|---|---|
| `flux/flux-operator.lock` | the three pinned + verified digests (chart, operator image, distribution manifests) |
| `flux/flux-instance.yaml` | the one `FluxInstance` — Flux 2.9.5, `source`+`kustomize`+`helm` controllers, syncs `environments/local/flux/` from `main` |
| `flux/flux-operator-helmrelease.yaml` | operator self-management (`OCIRepository` + `HelmRelease`) |
| `flux/kustomization.yaml` | the explicit inventory for the generated `flux-system` Kustomization (excludes `flux-instance.yaml`) |
| `flux/zot-sync.yaml` | the Flux `Kustomization` that reconciles `environments/local/zot/` |
| `flux/ci-runtime.yaml` | Flux `Kustomization` `ci-runtime` → `ci/runtime/` (T7c Increment 2, ADR 0015) |
| `flux/ci-defs.yaml` | Flux `Kustomization`s `ci-tasks` + `ci-pipelines` → `ci/tasks/` + `ci/pipelines/` (T7c Increment 2) |
| `flux/cert-manager.lock` | pinned cert-manager chart + 4 image digests + the authoring-time `cosign verify --key` record (static-key signature, not keyless) — T7c Increment 4a |
| `flux/cert-manager-helmrelease.yaml` | `OCIRepository` (digest pin, **no** `spec.verify` — the digest is the trust boundary, ADR 0001) + `HelmRelease` into ns `cert-manager` — installs cert-manager + its CRDs. In the flux-system Kustomization (always-known kinds). |
| `flux/cert-manager-pki.yaml` | a Flux `Kustomization` CR (`cert-manager-pki`) → `./environments/local/cert-manager`. **Separate** from flux-system because the Issuer CRs are cert-manager.io/v1 custom kinds and a whole-Kustomization dry-run fails on an unknown CRD — keeping them in flux-system deadlocked it against the HelmRelease that installs those CRDs. `healthChecks` on the cert-manager Deployments; `retryInterval: 30s`. |
| `../cert-manager/issuers.yaml` | selfSigned root `ClusterIssuer` → CA `Certificate` (key in-cluster) → CA `ClusterIssuer` → the `openbao-tls` leaf `Certificate` (ns `openbao`, applied once `openbao-bootstrap.sh` creates the namespace). Dev limitation: selfSigned root; production swaps it, CA + leaves unchanged. |
| `../cert-manager/tests/crd-schemas/*.json` | vendored cert-manager `Certificate`/`ClusterIssuer` v1 schemas for the `kubeconform-cert-manager` gate (from `github.com/cert-manager/cert-manager/releases/download/v1.21.1/cert-manager.crds.yaml`) |
| `flux/tests/crd-schemas/*.json` | v1/v2 CRD schemas vendored from Flux 2.9.5 + flux-operator v0.59.0 for the `kubeconform-flux` gate — **regenerate on a bump** (`crane digest` + `cosign verify` per the lock-file header; CRDs from `github.com/fluxcd/flux2/releases/download/v2.9.5/manifests.tar.gz`) |
| `tests/flux/flux-reconcile/chainsaw-test.yaml` | `[k8s]`-gated server-side check (`flux-chainsaw.sh` — skips in CI and until `local:flux:bootstrap` has run): the operator accepted the FluxInstance, source-controller fetched an artifact from git, the OCIRepository is cosign-verified, the HelmRelease self-manages, the zot Kustomization applied. Asserts running state; does not bootstrap or tear down. |
| `tests/flux/ci-reconcile/chainsaw-test.yaml` | `[k8s]`-gated (T7c Increment 2): the `ci-runtime` / `ci-tasks` / `ci-pipelines` Kustomizations are Ready, ns `ci` + the Tekton defs reconciled and Flux-owned, `ci/tests/**` not slurped. `flux-chainsaw.sh` runs it only once the CRs are on the synced ref (probe: `kustomization ci-runtime`). |

**Lifecycle trace** (CLAUDE.md § planning gate): bootstrap = one `helm upgrade
--install` from the bridge task, needs a reachable cluster first (`orb start
k8s` — a human step, or the optional machine-global pitchfork daemon, § Tekton).
Pod restart / reboot: k8s restarts the controllers; source artifacts live in
`emptyDir` and are re-fetched (seconds). The `zot` / `ci-runtime` / `ci-tasks`
/ `ci-pipelines` Kustomization CRs persist in etcd and re-reconcile with no
manual step. Cluster rebuild: re-run `local:flux:bootstrap`, then
`local:tekton:install` (Flux cannot install an absent Tekton — it is the named
prerequisite for `ci-runtime`'s health checks), then Flux reconciles `zot` +
`ci/**` in dependency order, then reseed the registry (`mise run
frontend:seed`). Operator/Flux upgrade: a reviewed digest bump in git — a
recurring **decision**, not a manual apply. Disaster (disk loss): recover the
checkout + re-bootstrap; zot data and OpenBao signing state are separate
recovery problems. No memorized secret (the repo is public — anonymous HTTPS
sync, no pull Secret).

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
