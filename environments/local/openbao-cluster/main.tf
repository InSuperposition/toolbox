# T7c Increment 4a — Phase A ONLY: the tofu-owned OpenBao Helm release.
#
# OpenBao in-cluster is WHOLLY OpenTofu-owned substrate (docs/adr/0015,
# plan § B5): a `helm_release` resource IS tofu owning the release lifecycle
# (create / upgrade via a chart_version + openbao-cluster.lock bump / destroy,
# all tracked in state). It is deliberately NOT a Flux HelmRelease — putting
# the secret store behind the reconcile loop that later depends on it for
# SOPS is a dependency inversion.
#
# Phase B (first `bao operator init`) and Phase C (transit keys, k8s-auth,
# policies — a `provider "vault"` + vault_*/kubernetes_* resources) land in
# Increments 4b/4c. This file stays Phase A until then.
#
# NOT applied by `mise run check` — the bootstrap bridge (Increment 4b) is
# the only thing that applies it against a real cluster. `tofu test` here is
# mock_provider only (tests/helm_values.tftest.hcl); the offline structural
# check is openbao-cluster-verify.sh.

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
      # ClusterIP listener (plan § B4). false flips the chart's port names to
      # https* ; the readiness probe is `exec: bao status -tls-skip-verify`
      # so no probe-scheme override is needed.
      tlsDisable = false
    }
    server = {
      # tag@digest — the digest is what kubelet pins, the tag stays readable
      # in `kubectl describe` (same form as flux-operator.lock). The digest
      # is also recorded in openbao-cluster.lock; a bump changes both.
      image = {
        tag = var.server_image_ref
      }

      # The chart renders podAntiAffinity whenever server.ha.enabled, NOT
      # gated on replicas > 1 — an empty string clears it so the single
      # replica schedules on OrbStack's one node (plan confirm #1).
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
        # there is no quorum to protect (plan confirm #1 / § Topology).
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
      # daemon's file:// shape exactly (plan § B1). `volumes`/`volumeMounts`
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
  # by digest (hashicorp/terraform-provider-helm#1596). openbao-cluster.lock
  # records the digest; openbao-cluster-verify.sh and the bridge both assert
  # `crane digest <repo>/<name>:<chart_version>` == that digest and fail
  # closed before any apply.
  version = var.chart_version

  # A failed first install rolls back instead of leaving a half-applied
  # StatefulSet the bridge then has to reason about.
  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 600

  values = [local.helm_values]
}
