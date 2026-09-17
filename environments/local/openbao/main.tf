# The in-cluster local OpenBao — a single-replica, OpenTofu-owned raft
# StatefulSet moved here from a machine-global pitchfork daemon without
# rotating approval-key. Two phases share this file:
#
#   Phase A — `helm_release.openbao`, the tofu-owned OpenBao Helm release.
#     WHOLLY OpenTofu-owned substrate: a `helm_release`
#     resource IS tofu owning the release lifecycle (create / upgrade via a
#     chart_version + openbao.lock bump / destroy, all tracked in state). It
#     is deliberately NOT a Flux HelmRelease — putting the secret store
#     behind the reconcile loop that later depends on it for SOPS is a
#     dependency inversion.
#
#   Phase C — `provider "vault"` (provider.tf) + the `vault_*` API config,
#     applied by the bootstrap bridge AFTER the key-preserving snapshot
#     restore (Phase B, in the bridge script, not `.tf`).
#
# NOT applied by `mise run check` — the bootstrap bridge is the only thing
# that applies it against a real cluster. `tofu test` here is mock_provider
# only (tests/*.tftest.hcl); the offline structural check is
# openbao-verify.sh.

locals {
  # The chart writes this to a ConfigMap and the server runs
  # `bao server -config=/openbao/config`. Rendered from a .tftpl (lintable,
  # readable) rather than an inline heredoc — same pattern as the host unit.
  server_config = templatefile("${path.module}/templates/openbao.hcl.tftpl", {
    static_seal_key_id = var.static_seal_key_id
  })

  # One YAML values doc, built structurally (yamlencode) — no heredoc YAML.
  helm_values = yamlencode({
    global = {
      # The loopback-only justification for tls_disable dies on the move to a
      # ClusterIP listener. false flips the chart's port names to
      # https* ; the readiness probe is `exec: bao status -tls-skip-verify`
      # so no probe-scheme override is needed.
      tlsDisable = false
    }
    server = {
      # tag@digest — the digest is what kubelet pins, the tag stays readable
      # in `kubectl describe` (same form as flux-operator.lock). The digest
      # is also recorded in openbao.lock; a bump changes both.
      image = {
        tag = var.server_image_ref
      }

      # The chart renders podAntiAffinity whenever server.ha.enabled, NOT
      # gated on replicas > 1 — an empty string clears it so the single
      # replica schedules on OrbStack's one node.
      affinity = ""

      ha = {
        enabled  = true
        replicas = 1

        raft = {
          enabled   = true
          setNodeId = true # node id = pod name — a stable single raft voter
          config    = local.server_config
        }

        # One voter: a PodDisruptionBudget would block its own drain, and
        # a single-voter raft has no quorum to protect.
        disruptionBudget = {
          enabled = false
        }
      }

      # Durable raft store on OrbStack's default StorageClass — the whole
      # point of the move (a Transit key that survives a pod restart).
      dataStorage = {
        enabled      = true
        size         = var.data_storage_size
        storageClass = null
      }
      auditStorage = {
        enabled = false
      }

      # Deliver both Secrets as read-only file mounts — matches the host
      # daemon's file:// shape exactly. `volumes`/`volumeMounts`
      # pass through verbatim (toYaml), unlike the deprecated `extraVolumes`.
      # Neither Secret is created here: the seal Secret is the bridge's (4b),
      # the TLS Secret is cert-manager's.
      volumes = [
        { name = "seal", secret = { secretName = var.seal_secret_name } },
        { name = "tls", secret = { secretName = var.tls_secret_name } },
      ]
      volumeMounts = [
        { name = "seal", mountPath = "/openbao/seal", readOnly = true },
        { name = "tls", mountPath = "/openbao/tls", readOnly = true },
      ]
    }

    # Negative space — the smallest thing that stores the Transit key
    # durably. No agent-injector, no CSI provider (it would need OpenBao
    # already running — circular), no UI.
    injector = { enabled = false }
    csi      = { enabled = false }
  })
}

resource "helm_release" "openbao" {
  name      = var.release_name
  namespace = var.namespace
  # The bootstrap bridge (4b) creates the namespace (kubectl, idempotent)
  # BEFORE this applies — tofu never owns a namespace another actor manages.
  create_namespace = false

  repository = var.chart_repository
  chart      = var.chart_name
  # A tag, not a digest — the OpenTofu helm provider cannot pin an OCI chart
  # by digest (hashicorp/terraform-provider-helm#1596). openbao.lock
  # records the digest; openbao-verify.sh and the bridge both assert
  # `oras resolve <repo>/<name>:<chart_version>` == that digest and fail
  # closed before any apply.
  version = var.chart_version

  # The bridge polls readiness itself (pod phase, then `bao operator init` /
  # auto-unseal). `wait = true` cannot be used here: the chart's readiness
  # probe is `bao status`, which only passes once the raft store is
  # initialised AND unsealed — never true for a fresh PVC at Phase A (a
  # bundle-only recovery), so `wait`+`atomic` would deadlock for
  # `timeout` then roll the release back. `cleanup_on_fail` still purges a
  # genuinely failed install (bad manifest, image pull).
  atomic          = false
  cleanup_on_fail = true
  wait            = false
  timeout         = 600

  values = [local.helm_values]
}

# ─── Phase C — API config against the RESTORED instance ──────────────────
#
# Applied by the bootstrap bridge's final `tofu apply`, AFTER the
# key-preserving snapshot restore — so the `transit` mount + `approval-key`
# already exist (restore-managed) and VAULT_TOKEN is the bundle's original
# root token. Everything here is NEW: the `sops` key, the decrypt policy,
# the k8s-ServiceAccount auth method. Nothing here touches `approval-key`.
#
# The chart already ships the `system:auth-delegator` ClusterRoleBinding for
# the `openbao` ServiceAccount (server.authDelegator.enabled default true),
# so there is NO `kubernetes_cluster_role_binding` here.

# The Flux SOPS AES key — approval-key (ecdsa-p256, signing) cannot serve
# AES decryption. Non-exportable, undeletable (same invariant as the host
# unit's keys).
resource "vault_transit_secret_backend_key" "sops" {
  backend          = "transit" # the pre-existing restore-managed mount, by literal path
  name             = var.sops_key_name
  type             = "aes256-gcm96"
  exportable       = false
  deletion_allowed = false

  depends_on = [helm_release.openbao]
}

# The extension point — future consumers (a chains-provenance key for
# signing build provenance, a crossplane-system key) add entries to
# var.transit_keys. approval-key is
# rejected by the variable's validation.
resource "vault_transit_secret_backend_key" "extra" {
  for_each = { for k in var.transit_keys : k.name => k }

  backend          = "transit"
  name             = each.value.name
  type             = each.value.type
  exportable       = false
  deletion_allowed = false

  depends_on = [helm_release.openbao]
}

# Decrypt-only. Encryption (transit/encrypt/sops) is granted separately to
# whatever identity seals secrets — not here, not needed until a secret
# exists.
resource "vault_policy" "flux_sops_decrypt" {
  name = "flux_sops_decrypt"

  policy = <<-HCL
    path "transit/decrypt/${var.sops_key_name}" {
      capabilities = ["update"]
    }
  HCL

  depends_on = [helm_release.openbao]
}

# k8s-ServiceAccount auth — no static BAO_TOKEN for cluster workloads.
resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"

  depends_on = [helm_release.openbao]
}

# Same-cluster shortcut: kubernetes_host only. OpenBao reads its own pod SA
# token + CA from /var/run/secrets/... so token_reviewer_jwt and
# kubernetes_ca_cert are omitted (verified against the Kubernetes auth
# method's own upstream behavior).
resource "vault_kubernetes_auth_backend_config" "this" {
  backend         = vault_auth_backend.kubernetes.path
  kubernetes_host = var.kubernetes_host
}

resource "vault_kubernetes_auth_backend_role" "flux_sops" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "flux_sops"
  bound_service_account_names      = [var.sops_auth.service_account_name]
  bound_service_account_namespaces = [var.sops_auth.service_account_namespace]
  audience                         = var.openbao_endpoint
  token_policies                   = [vault_policy.flux_sops_decrypt.name]
  token_ttl                        = var.sops_auth.token_ttl_seconds
}

# Build provenance signing. Sign AND read — `sign` alone omits the
# pubkey-read path cosign's hashivault KMS client needs just to run at all
# (sigstore/sigstore v1.10.8 pkg/signature/kms/hashivault/client.go). Never
# `approval-key` — this is a separate key,
# `vault_transit_secret_backend_key.extra["chains-provenance-key"]`, not
# the restore-managed one.
#
# The `sign` path needs a trailing `*` with no slash before it — a
# Vault/OpenBao PREFIX match, covering the bare path (star matches empty)
# and any suffixed variant. cosign's hashivault client actually calls
# `transit/sign/chains-provenance-key/<hash-algo>` (e.g. `/sha2-256`, the
# API's optional hash-algorithm URL segment); an exact-match path with no
# glob denies every real sign attempt with 403, even with a valid token
# and the right role.
resource "vault_policy" "chains_provenance_sign" {
  name = "chains_provenance_sign"

  policy = <<-HCL
    path "transit/sign/chains-provenance-key*" {
      capabilities = ["update"]
    }
    path "transit/keys/chains-provenance-key" {
      capabilities = ["read"]
    }
  HCL

  depends_on = [helm_release.openbao]
}

resource "vault_kubernetes_auth_backend_role" "chains_provenance" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "chains_provenance"
  bound_service_account_names      = [var.chains_auth.service_account_name]
  bound_service_account_namespaces = [var.chains_auth.service_account_namespace]
  audience                         = var.openbao_endpoint
  token_policies                   = [vault_policy.chains_provenance_sign.name]
  token_ttl                        = var.chains_auth.token_ttl_seconds
}

# ─── PKI mount — SPIRE's upstream authority ─────────────────────────────
#
# FIRST use of OpenBao's PKI engine in this repo. Unlike `transit`, this
# mount is NOT restore-managed — nothing else creates or seeds it — so it
# carries no key-preservation constraint and is an ordinary tofu-owned
# resource, same footing as `vault_auth_backend "kubernetes"` above.
# Keeps OpenBao the one root of trust: no third independent CA alongside
# `toolbox-dev-ca` and OpenBao's own listener cert.
#
# No consumer yet — the future `environments/local/spire/` unit's
# spire-server reaches this at RUNTIME via its own vault upstreamAuthority
# plugin (k8s-auth login -> pki/root/sign-intermediate), never via
# tofu-to-tofu state sharing. This unit creates only the OpenBao-side half
# of that contract.

resource "vault_mount" "pki" {
  path                  = "pki"
  type                  = "pki"
  max_lease_ttl_seconds = 315360000 # 10y — dev-scale root

  depends_on = [helm_release.openbao]
}

resource "vault_pki_secret_backend_root_cert" "spire_root" {
  backend     = vault_mount.pki.path
  type        = "internal" # private key never leaves OpenBao
  common_name = "toolbox-dev SPIRE Root CA"
  ttl         = "315360000"
  key_type    = "ec"
  key_bits    = 256

  depends_on = [vault_mount.pki]
}

# Scoped to exactly the one call SPIRE's vault upstreamAuthority plugin
# makes (doc/plugin_server_upstreamauthority_vault.md, spiffe/spire) —
# `pki/root/sign-intermediate`, never `pki/root/generate` or `pki/issue/*`.
resource "vault_policy" "spire_sign_intermediate" {
  name = "spire_sign_intermediate"

  policy = <<-HCL
    path "pki/root/sign-intermediate" {
      capabilities = ["update"]
    }
  HCL

  depends_on = [helm_release.openbao]
}

# Bound to the ServiceAccount name/namespace the future spire-server Helm
# release will create (that release lands in a later change, not this
# unit) — referenced here by plain string, not a live lookup, since that
# chart doesn't exist yet.
resource "vault_kubernetes_auth_backend_role" "spire_server" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "spire_server"
  bound_service_account_names      = [var.spire_auth.service_account_name]
  bound_service_account_namespaces = [var.spire_auth.service_account_namespace]
  audience                         = var.openbao_endpoint
  token_policies                   = [vault_policy.spire_sign_intermediate.name]
  token_ttl                        = var.spire_auth.token_ttl_seconds
}
